import Foundation

/// `tktracker report [--json] [--range today|week|month|quarter|all]`
/// Terminal companion to the menu bar app; shares the same scan cache.
enum CLIReport {
    static func run(arguments: [String]) -> Int32 {
        let json = arguments.contains("--json")
        var range: StatsRange? = nil
        if let idx = arguments.firstIndex(of: "--range"), idx + 1 < arguments.count {
            range = StatsRange(rawValue: arguments[idx + 1])
            if range == nil {
                FileHandle.standardError.write(Data("unknown range '\(arguments[idx + 1])' — use today|week|month|quarter|all\n".utf8))
                return 2
            }
        }

        let core = ScanCore(root: ScanCore.defaultRoot(), cacheURL: ScanCore.defaultCacheURL())
        guard FileManager.default.fileExists(atPath: core.root.path) else {
            FileHandle.standardError.write(Data("no Claude Code data at \(core.root.path)\n".utf8))
            return 1
        }
        let cache = core.loadCache()
        let archive = HistoryArchive(url: HistoryArchive.defaultURL())
        let archiveCache = archive.load()
        var seededDigests = cache.digests
        var seededClaims = cache.claims
        HistoryArchive.seed(archive: archiveCache, intoDigests: &seededDigests, claims: &seededClaims)
        let result = core.refreshed(digests: seededDigests, claims: seededClaims)
        if result.changed { core.saveCache(digests: result.digests, claims: result.claims) }
        if let updated = HistoryArchive.updated(archiveCache, digests: result.digests, claims: result.claims) {
            archive.save(updated)
        }
        var all = Array(result.digests.values)
        if !arguments.contains("--transcripts-only"),
           let history = StatsCacheImport.historyDigest(transcriptDigests: all) {
            all.append(history)
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

    private static func printReport(digests: [FileDigest], focus: StatsRange?) {
        let now = Date()
        let ranges: [StatsRange] = focus.map { [$0] } ?? [.today, .week, .month, .all]
        let stats = ranges.map { StatsBuilder.build(digests: digests, range: $0, now: now) }

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        print("TkTracker — Claude Code usage".padded(52) + df.string(from: now))
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
