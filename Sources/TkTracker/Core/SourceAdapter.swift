import Foundation

/// One contract for every supported transcript adapter. Adding a source requires
/// verified fixtures for replay, compaction and token semantics before discovery
/// is enabled; unsupported logs never enter an existing source's totals.
protocol SourceAdapter: Sendable {
    func scan(_ file: ScanCore.FileMeta, previous: FileDigest?, claims: ClaimTable) -> FileDigest
}
struct ClaudeSourceAdapter: SourceAdapter {
    func scan(_ file: ScanCore.FileMeta, previous: FileDigest?, claims: ClaimTable) -> FileDigest {
        JSONLParser.scan(url: file.url, previous: previous, projectDir: file.projectDir,
            size: file.size, mtime: file.mtime, claims: claims)
    }
}
struct CodexSourceAdapter: SourceAdapter {
    func scan(_ file: ScanCore.FileMeta, previous: FileDigest?, claims: ClaimTable) -> FileDigest {
        CodexParser.scan(url: file.url, previous: previous, size: file.size, mtime: file.mtime)
    }
}
extension UsageSource {
    var adapter: any SourceAdapter {
        switch self { case .claude: return ClaudeSourceAdapter(); case .codex: return CodexSourceAdapter() }
    }
}
