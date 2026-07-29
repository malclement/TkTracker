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
    static func scan(
        sources wanted: Set<UsageSource>,
        explicitSource: UsageSource? = nil,
        includeHistory: Bool = true
    ) -> ScanOutcome {
        var all: [FileDigest] = []
        var scannedRoots: [String] = []
        var missingRoots: [String] = []
        for source in UsageSource.allCases where wanted.contains(source) {
            let core = ScanCore(
                source: source,
                root: ScanCore.defaultRoot(for: source),
                cacheURL: ScanCore.defaultCacheURL(for: source)
            )
            guard FileManager.default.fileExists(atPath: core.root.path) else {
                // A source the user explicitly asked for must not be skipped quietly.
                if explicitSource == source {
                    return .failure(
                        message: "no \(source.displayName) data at \(core.root.path)\n",
                        code: 1
                    )
                }
                missingRoots.append("no \(source.displayName) data at \(core.root.path)")
                continue
            }
            scannedRoots.append(core.root.path)
            let cache = core.loadCache()
            let archive = HistoryArchive(source: source, url: HistoryArchive.defaultURL(for: source))
            let archiveCache = archive.load()
            var seededDigests = cache.digests
            var seededClaims = cache.claims
            HistoryArchive.seed(archive: archiveCache, intoDigests: &seededDigests, claims: &seededClaims)
            let result = core.refreshed(digests: seededDigests, claims: seededClaims)
            // A migrated cache is rewritten even when nothing else changed, so
            // the upgrade converts once instead of on every invocation.
            if result.changed || cache.wasMigrated {
                core.saveCache(digests: result.digests, claims: result.claims)
            }
            if let updated = HistoryArchive.updated(archiveCache, digests: result.digests, claims: result.claims) {
                archive.save(updated)
            } else if archiveCache.wasMigrated {
                archive.save(archiveCache)
            }
            all += result.digests.values
        }
        guard !scannedRoots.isEmpty else {
            return .failure(
                message: "no session data found:\n  \(missingRoots.joined(separator: "\n  "))\n",
                code: 1
            )
        }
        if wanted.contains(.claude), includeHistory,
           let history = StatsCacheImport.historyDigest(
               transcriptDigests: all.filter { $0.source == .claude }
           ) {
            all.append(history)
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

        if arguments.contains("--watch") {
            return runWatch(
                sources: wanted,
                explicitSource: explicitSource,
                includeHistory: !arguments.contains("--transcripts-only"),
                range: range
            )
        }

        if arguments.contains("--csv") {
            print(CSVExport.dailyByModel(digests: all, range: range ?? .all), terminator: "")
            return 0
        }

        if json {
            let stats = StatsBuilder.build(digests: all, range: range ?? .all)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode(stats), let s = String(data: data, encoding: .utf8) {
                print(s)
                return 0
            }
            return 1
        }

        printReport(digests: all, focus: range)
        return 0
    }

    /// Live terminal view: redraw the report every few seconds until interrupted.
    ///
    /// Uses the alternate screen buffer so the scrollback the user had before
    /// running it is restored on exit, and hides the cursor while drawing. Both
    /// are undone on SIGINT — leaving a terminal with a hidden cursor is a
    /// genuinely annoying thing to do to someone.
    private static func runWatch(
        sources: Set<UsageSource>,
        explicitSource: UsageSource?,
        includeHistory: Bool,
        range: StatsRange?
    ) -> Int32 {
        let enterAlternate = "\u{1B}[?1049h\u{1B}[?25l"
        let leaveAlternate = "\u{1B}[?25h\u{1B}[?1049l"
        let home = "\u{1B}[H\u{1B}[2J"

        func restore() {
            FileHandle.standardOutput.write(Data(leaveAlternate.utf8))
        }

        // Trap interrupts so the terminal is always handed back intact.
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        source.setEventHandler {
            restore()
            exit(0)
        }
        signal(SIGINT, SIG_IGN)
        source.resume()

        FileHandle.standardOutput.write(Data(enterAlternate.utf8))
        defer { restore() }

        while true {
            let outcome = Self.scan(
                sources: sources,
                explicitSource: explicitSource,
                includeHistory: includeHistory
            )
            FileHandle.standardOutput.write(Data(home.utf8))
            switch outcome {
            case .failure(let message, let code):
                restore()
                FileHandle.standardError.write(Data(message.utf8))
                return code
            case .success(let digests, _):
                printReport(digests: digests, focus: range)
                print("  watching — ctrl-c to stop")
            }
            Thread.sleep(forTimeInterval: 3)
        }
    }

    private static func printReport(digests: [FileDigest], focus: StatsRange?) {
        let now = Date()
        let ranges: [StatsRange] = focus.map { [$0] } ?? [.today, .week, .month, .all]
        let stats = ranges.map { StatsBuilder.build(digests: digests, range: $0, now: now) }

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
