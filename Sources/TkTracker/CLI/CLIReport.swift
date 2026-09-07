import Foundation

/// `tktracker report [--json] [--range today|week|month|quarter|all] [--source claude|codex|all]`
/// Terminal companion to the menu bar app; shares the same scan caches.
enum CLIReport {
    /// Outcome of collecting digests across the requested sources.
    enum ScanOutcome {
        case success(digests: [FileDigest], notes: [String])
        case failure(message: String, code: Int32)
    }

    /// Scan the requested sources, sharing the app's caches and archives.
    /// Extracted so `report`, `--watch` and the Shortcuts intents all agree about
    /// what "current usage" means.
    /// - Parameter persist: whether to write back the scan cache and archive.
    ///   `false` makes this a pure read — used by the Shortcuts intents, which
    ///   should answer a question without taking ownership of cache state the
    ///   running app also writes.
    /// - Parameter pipelines: overrides the default per-source roots and cache
    ///   locations. Injectable so this can be tested against a temporary tree
    ///   instead of the user's real data and Application Support directory.
    static func scan(
        sources wanted: Set<UsageSource>,
        explicitSource: UsageSource? = nil,
        includeHistory: Bool = true,
        persist: Bool = true,
        pipelines: [(core: ScanCore, archive: HistoryArchive)]? = nil
    ) -> ScanOutcome {
        var all: [FileDigest] = []
        var scannedRoots: [String] = []
        var missingRoots: [String] = []
        let available = pipelines ?? UsageEngine.defaultPipelines()
        for pipeline in available where wanted.contains(pipeline.core.source) {
            let source = pipeline.core.source
            let core = pipeline.core
            let hasRoot = FileManager.default.fileExists(atPath: core.root.path)
            if !hasRoot {
                missingRoots.append("no \(source.displayName) data at \(core.root.path); retained history is included")
            }
            scannedRoots.append(core.root.path)
            let cache = core.loadCache()
            let archive = pipeline.archive
            let archiveCache = archive.load()
            var seededDigests = cache.digests
            var seededClaims = cache.claims
            HistoryArchive.seed(archive: archiveCache, intoDigests: &seededDigests, claims: &seededClaims)
            let result = core.refreshed(digests: seededDigests, claims: seededClaims)
            if persist {
                // A migrated cache is rewritten even when nothing else changed,
                // so the upgrade converts once instead of on every invocation.
                if result.changed || cache.wasMigrated {
                    core.saveCache(digests: result.digests, claims: result.claims)
                }
                if let updated = HistoryArchive.updated(archiveCache, digests: result.digests, claims: result.claims) {
                    archive.save(updated)
                } else if archiveCache.wasMigrated {
                    archive.save(archiveCache)
                }
            }
            all += result.digests.values.map { digest in
                var d = digest
                d.profileId = core.profileId ?? source.rawValue
                return d
            }
        }
        guard !scannedRoots.isEmpty, !all.isEmpty || missingRoots.isEmpty else {
            return .failure(
                message: "no session data found:\n  \(missingRoots.joined(separator: "\n  "))\n",
                code: 1
            )
        }
        if wanted.contains(.claude), includeHistory {
            let profiles = available.map { SourceProfile(id: $0.core.profileId ?? $0.core.source.rawValue, name: "", source: $0.core.source, rootPath: $0.core.root.path) }
            all += StatsCacheImport.historyDigests(profiles: profiles, transcriptDigests: all)
        }
        return .success(digests: all, notes: missingRoots)
    }

    static func run(arguments: [String]) -> Int32 {
        let json = arguments.contains("--json")
        var all: [FileDigest] = []

        /// A flag present without a value is an error the caller must surface
        /// (silently ignoring it would print a report the user explicitly
        /// tried to restrict).
        enum FlagValue { case absent, missingValue, value(String) }
        func value(of flag: String) -> FlagValue {
            guard let idx = arguments.firstIndex(of: flag) else { return .absent }
            guard idx + 1 < arguments.count else { return .missingValue }
            return .value(arguments[idx + 1])
        }

        var range: StatsRange? = nil
        switch value(of: "--range") {
        case .absent:
            break
        case .missingValue:
            FileHandle.standardError.write(Data("missing value for --range — use today|week|month|quarter|all\n".utf8))
            return 2
        case .value(let raw):
            guard let parsed = StatsRange(rawValue: raw) else {
                FileHandle.standardError.write(Data("unknown range '\(raw)' — use today|week|month|quarter|all\n".utf8))
                return 2
            }
            range = parsed
        }

        var wanted = Set(UsageSource.allCases)
        var explicitSource: UsageSource? = nil
        switch value(of: "--source") {
        case .absent:
            break
        case .missingValue:
            FileHandle.standardError.write(Data("missing value for --source — use claude|codex|all\n".utf8))
            return 2
        case .value(let raw):
            if raw != "all" {
                guard let source = UsageSource(rawValue: raw) else {
                    FileHandle.standardError.write(Data("unknown source '\(raw)' — use claude|codex|all\n".utf8))
                    return 2
                }
                wanted = [source]
                explicitSource = source
            }
        }

        var filter = ReportFilter()
        filter.calendarMonth = arguments.contains("--calendar-month")
        for flag in ["--project", "--model", "--view", "--from", "--to"] {
            switch value(of: flag) {
            case .absent: continue
            case .missingValue:
                FileHandle.standardError.write(Data("missing value for \(flag)\n".utf8)); return 2
            case .value(let raw):
                if flag == "--project" { filter.project = raw }
                else if flag == "--model" { filter.model = raw }
                else if flag == "--view" {
                    let defaults = UserDefaults(suiteName: "com.clementmalige.tktracker") ?? .standard
                    let views = defaults.data(forKey: "savedFilters").flatMap { try? JSONDecoder().decode([ReportFilter].self, from: $0) } ?? []
                    guard let saved = views.first(where: { $0.name == raw || $0.id == raw }) else {
                        FileHandle.standardError.write(Data("unknown saved view: \(raw)\n".utf8)); return 2
                    }
                    filter = saved
                } else {
                    let df = DateFormatter()
                    df.calendar = Calendar(identifier: .gregorian)
                    df.locale = Locale(identifier: "en_US_POSIX")
                    df.dateFormat = "yyyy-MM-dd"; df.isLenient = false
                    guard let date = df.date(from: raw), df.string(from: date) == raw else {
                        FileHandle.standardError.write(Data("\(flag) requires YYYY-MM-DD\n".utf8)); return 2
                    }
                    filter.calendarMonth = false
                    if flag == "--from" { filter.start = date }
                    else { filter.end = Calendar.current.date(byAdding: .day, value: 1, to: date) }
                }
            }
        }
        if filter.start != nil || filter.end != nil {
            guard let a = filter.start, let b = filter.end, b > a else {
                FileHandle.standardError.write(Data("provide --from and --to with a valid inclusive date range\n".utf8)); return 2
            }
        }

        // Dispatched before the one-shot scan below: --watch keeps its own
        // incremental state, so scanning here first would do the whole job twice
        // (and write the cache twice) before the first frame.
        if arguments.contains("--watch") {
            // --watch drives a human-readable live view; combining it with a
            // machine format silently ignored the format and wrote ANSI escapes
            // into what the caller expected to be parseable output.
            if json || arguments.contains("--csv") {
                FileHandle.standardError.write(Data(
                    "--watch cannot be combined with --json or --csv (it redraws a human-readable view)\n".utf8
                ))
                return 2
            }
            return runWatch(
                sources: wanted,
                explicitSource: explicitSource,
                includeHistory: !arguments.contains("--transcripts-only"),
                range: range, filter: filter
            )
        }

        let scan = Self.scan(
            sources: wanted,
            explicitSource: explicitSource,
            includeHistory: !arguments.contains("--transcripts-only")
        )
        switch scan {
        case .failure(let message, let code):
            FileHandle.standardError.write(Data(message.utf8))
            return code
        case .success(let digests, let notes):
            // One root present, the other absent: report what's being skipped
            // (stderr, so --json/--csv stdout stays clean).
            for note in notes {
                FileHandle.standardError.write(Data("note: \(note)\n".utf8))
            }
            all = digests
        }

        if arguments.contains("--csv") {
            print(CSVExport.dailyByModel(digests: all, range: range ?? .all, filter: filter), terminator: "")
            return 0
        }

        if json {
            // Same plan and same encoder as the GUI export, so the two documents
            // are genuinely interchangeable rather than only claimed to be.
            let stats = StatsBuilder.build(digests: all, range: range ?? .all, plan: appPlan(), filter: filter, profiles: SourceProfile.load())
            do {
                print(try stats.jsonDocument())
                return 0
            } catch {
                FileHandle.standardError.write(Data("could not encode stats: \(error)\n".utf8))
                return 1
            }
        }

        printReport(digests: all, focus: range, filter: filter)
        return 0
    }

    /// The plan configured in the app.
    ///
    /// Read from the app's own preferences domain rather than
    /// `UserDefaults.standard`: a bare CLI binary has no bundle identifier, so
    /// `standard` would be a different domain and `--json` would report no plan
    /// while the GUI reported one.
    static func appPlan() -> UsagePlan {
        guard let defaults = UserDefaults(suiteName: "com.clementmalige.tktracker") else {
            return .none
        }
        return UsagePlan.load(from: defaults)
    }

    /// One-bit flag shared between a signal handler and the watch loop.
    private final class InterruptFlag: @unchecked Sendable {
        private var value = false
        private let lock = NSLock()
        var isSet: Bool {
            lock.lock(); defer { lock.unlock() }
            return value
        }
        func set() {
            lock.lock(); defer { lock.unlock() }
            value = true
        }
    }

    /// Live terminal view: redraw the report every few seconds until interrupted.
    ///
    /// Uses the alternate screen buffer so the scrollback the user had before
    /// running it survives, and hides the cursor while drawing. Both must be
    /// undone on the way out — leaving someone's terminal with a hidden cursor is
    /// a genuinely rude thing to do.
    ///
    /// Signal handling is deliberately not on the main queue. `Main.main()` runs
    /// the CLI directly on the main thread with no run loop and no
    /// `dispatchMain()`, and this loop then blocks that thread — so a signal
    /// source scheduled on `.main` would never be drained and its handler would
    /// never run, while `signal(SIGINT, SIG_IGN)` had already disabled the
    /// default behaviour. The net effect was a process that ignored ctrl-C
    /// outright and, when finally killed, left the terminal in the alternate
    /// buffer with no cursor: exactly what this is supposed to prevent.
    ///
    /// So: the sources live on their own queue, they only set a flag, and the
    /// loop returns normally through `defer` so cleanup happens on one path.
    private static func runWatch(
        sources: Set<UsageSource>,
        explicitSource: UsageSource?,
        includeHistory: Bool,
        range: StatsRange?,
        filter: ReportFilter
    ) -> Int32 {
        // Only drive the terminal when there is one. Piping `--watch` into a file
        // or another process should produce plain frames, not ANSI escapes.
        let isTerminal = isatty(STDOUT_FILENO) == 1
        let enterAlternate = isTerminal ? "\u{1B}[?1049h\u{1B}[?25l" : ""
        let leaveAlternate = isTerminal ? "\u{1B}[?25h\u{1B}[?1049l" : ""
        let home = isTerminal ? "\u{1B}[H\u{1B}[2J" : "\n"

        /// Escapes must go through the same buffered stream as `print`, or they
        /// arrive out of order — stdout is block-buffered when it is not a TTY,
        /// so direct `FileHandle` writes overtook the frame they were meant to
        /// follow and the restore sequence landed before the last report.
        func emit(_ text: String) {
            guard !text.isEmpty else { return }
            print(text, terminator: "")
            fflush(stdout)
        }

        let interrupted = InterruptFlag()
        let signalQueue = DispatchQueue(label: "tktracker.watch.signals")
        var signalSources: [DispatchSourceSignal] = []
        for sig in [SIGINT, SIGTERM] {
            let source = DispatchSource.makeSignalSource(signal: sig, queue: signalQueue)
            source.setEventHandler { interrupted.set() }
            source.resume()
            signalSources.append(source)
            // Only now that a source is actually delivering can the default
            // disposition be suppressed.
            signal(sig, SIG_IGN)
        }
        defer {
            for source in signalSources { source.cancel() }
            signal(SIGINT, SIG_DFL)
            signal(SIGTERM, SIG_DFL)
        }

        emit(enterAlternate)
        defer { emit(leaveAlternate) }

        // Carry scan state across ticks. Re-reading and re-writing a multi-MB
        // cache every 3 seconds — which a stateless `Self.scan` per tick would
        // do, for as long as the user leaves this open — is not acceptable for a
        // read-only view.
        var live = WatchState(sources: sources, explicitSource: explicitSource, includeHistory: includeHistory)

        while !interrupted.isSet {
            emit(home)
            switch live.tick() {
            case .failure(let message, let code):
                FileHandle.standardError.write(Data(message.utf8))
                return code
            case .success(let digests, _):
                printReport(digests: digests, focus: range, filter: filter)
                print("  watching — ctrl-c to stop")
            }
            // Sleep in slices so ctrl-C feels immediate rather than taking up to
            // a full interval to be noticed.
            let deadline = Date().addingTimeInterval(3)
            while !interrupted.isSet, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        return 0
    }

    /// Incremental scan state for `--watch`.
    ///
    /// Holds digests and claims in memory between ticks and only persists on a
    /// throttle, mirroring what `UsageEngine` does for the app instead of
    /// re-reading and rewriting the whole cache every few seconds.
    private struct WatchState {
        let sources: Set<UsageSource>
        let explicitSource: UsageSource?
        let includeHistory: Bool

        private var pipelines: [(core: ScanCore, archive: HistoryArchive)] = []
        private var digests: [String: [String: FileDigest]] = [:]
        private var claims: [String: ClaimMap] = [:]
        private var archives: [String: DigestCache] = [:]
        private var lastSave = Date()
        private var started = false

        init(sources: Set<UsageSource>, explicitSource: UsageSource?, includeHistory: Bool) {
            self.sources = sources
            self.explicitSource = explicitSource
            self.includeHistory = includeHistory
        }

        mutating func tick() -> ScanOutcome {
            if !started {
                started = true
                let available = UsageEngine.defaultPipelines().filter { sources.contains($0.core.source) }
                for pipeline in available {
                    let core = pipeline.core
                    let archive = pipeline.archive
                    let source = core.profileId ?? core.source.rawValue
                    let cache = core.loadCache()
                    let archiveCache = archive.load()
                    var seeded = cache.digests
                    var seededClaims = cache.claims
                    HistoryArchive.seed(archive: archiveCache, intoDigests: &seeded, claims: &seededClaims)
                    pipelines.append((core, archive))
                    digests[source] = seeded
                    claims[source] = seededClaims
                    archives[source] = archiveCache
                }
                guard !pipelines.isEmpty else {
                    return .failure(message: "no session data found\n", code: 1)
                }
            }

            var all: [FileDigest] = []
            var dirty = false
            for pipeline in pipelines {
                let source = pipeline.core.profileId ?? pipeline.core.source.rawValue
                let result = pipeline.core.refreshed(
                    digests: digests[source] ?? [:],
                    claims: claims[source] ?? ClaimMap()
                )
                digests[source] = result.digests
                claims[source] = result.claims
                if result.changed { dirty = true }
                if let archive = archives[source],
                   let updated = HistoryArchive.updated(archive, digests: result.digests, claims: result.claims) {
                    archives[source] = updated
                    pipeline.archive.save(updated)
                }
                all += result.digests.values.map { digest in
                var d = digest
                d.profileId = source
                return d
            }
            }

            // Same 15s throttle the app uses, so a long-running watch does not
            // rewrite megabytes on every tick.
            if dirty, Date().timeIntervalSince(lastSave) > 15 {
                for pipeline in pipelines {
                    let source = pipeline.core.profileId ?? pipeline.core.source.rawValue
                    pipeline.core.saveCache(
                        digests: digests[source] ?? [:],
                        claims: claims[source] ?? ClaimMap()
                    )
                }
                lastSave = Date()
            }

            if sources.contains(.claude), includeHistory {
                let profiles = pipelines.map { SourceProfile(id: $0.core.profileId ?? $0.core.source.rawValue, name: "", source: $0.core.source, rootPath: $0.core.root.path) }
                all += StatsCacheImport.historyDigests(profiles: profiles, transcriptDigests: all)
            }
            return .success(digests: all, notes: [])
        }
    }

    private static func printReport(digests: [FileDigest], focus: StatsRange?, filter: ReportFilter = ReportFilter()) {
        let now = Date()
        let ranges: [StatsRange] = focus.map { [$0] } ?? [.today, .week, .month, .all]
        let stats = ranges.map { StatsBuilder.build(digests: digests, range: $0, now: now, filter: filter, profiles: SourceProfile.load()) }

        let present = Set(digests.map(\.source))
        let subject = present == [.claude] ? "Claude Code usage"
            : present == [.codex] ? "Codex usage"
            : "Claude Code + Codex usage"

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        print("TkTracker — \(subject)".padded(52) + df.string(from: now))
        print("")

        print("  " + "Range".padded(10) + "Cost".padded(11) + "Tokens".padded(10)
            + "In".padded(9) + "Out".padded(9) + "Cache r/w".padded(17) + "Msgs")
        for s in stats {
            let t = s.totals
            let cache = "\(Format.tokens(t.cacheRead)) / \(Format.tokens(t.cacheWrite))"
            print("  " + s.range.label.padded(10)
                + Format.money(s.cost).padded(11)
                + Format.tokens(t.total).padded(10)
                + Format.tokens(t.input).padded(9)
                + Format.tokens(t.output).padded(9)
                + cache.padded(17)
                + String(t.messages))
        }

        let reference = stats.last ?? StatsBuilder.build(digests: digests, range: .all, now: now)

        if !reference.coverage.note.isEmpty { print("\n  \(reference.coverage.note)") }

        if let block = reference.block, block.isActive {
            let remaining = Format.duration(block.end.timeIntervalSince(now))
            let hf = DateFormatter()
            hf.dateFormat = "HH:mm"
            print("\n  Current 5h block (ends \(hf.string(from: block.end)), \(remaining) left): "
                + "\(Format.money(block.cost)) · \(Format.tokens(block.totals.total)) tokens · \(block.totals.messages) msgs")
        }

        // Both tools in the picture: say how the range splits before the
        // per-model detail.
        let sourceLines = UsageSource.allCases.compactMap { source -> (String, TokenTotals, Double)? in
            let totals = reference.totals(for: source)
            guard !totals.isEmpty else { return nil }
            return (source.displayName, totals, reference.cost(for: source))
        }
        if sourceLines.count > 1 {
            print("\n  By source — \(reference.range.label.lowercased())")
            for (name, totals, cost) in sourceLines {
                print("    " + name.padded(14) + Format.money(cost).padded(11)
                    + Format.tokens(totals.total).padded(10) + "\(totals.messages) msgs")
            }
        }

        if !reference.models.isEmpty {
            print("\n  By model — \(reference.range.label.lowercased())")
            for m in reference.models.prefix(8) {
                let flag = m.hasPricing ? "" : "  (no pricing)"
                print("    " + m.shortName.padded(14) + Format.money(m.cost).padded(11)
                    + Format.tokens(m.totals.total).padded(10) + Format.percent(m.share) + flag)
            }
        }

        if !reference.projects.isEmpty {
            print("\n  By project — \(reference.range.label.lowercased()) (top 8)")
            for p in reference.projects.prefix(8) {
                print("    " + String(p.name.prefix(22)).padded(24) + Format.money(p.cost).padded(11)
                    + Format.tokens(p.totals.total).padded(10)
                    + "\(p.sessions) session\(p.sessions == 1 ? "" : "s")")
            }
        }

        if reference.cacheSavings > 0.01 {
            print("\n  Prompt cache: \(Format.percent(reference.cacheHitRate)) of prompt tokens served from cache, "
                + "saving ≈\(Format.money(reference.cacheSavings)) (\(reference.range.label.lowercased()))")
        }

        if let since = reference.dataSince {
            let sf = DateFormatter()
            sf.dateStyle = .medium
            sf.timeStyle = .none
            var line = "\n  History since \(sf.string(from: since))."
            if reference.hasEstimatedHistory {
                line += " Days before the oldest exact record are estimated from"
                    + "\n  Claude Code's stats cache (transcripts are pruned after ~30 days,"
                    + " but usage\n  TkTracker has already seen stays exact;"
                    + " pass --transcripts-only to exclude)."
            }
            print(line)
        }
        print("")
    }
}

private extension String {
    func padded(_ width: Int) -> String {
        count >= width ? self + " " : self + String(repeating: " ", count: width - count)
    }
}
