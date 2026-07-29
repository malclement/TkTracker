import Foundation

/// Global `(messageId:requestId)` → owning session file, stored with the owner
/// paths interned.
///
/// Session resumes and forks copy history lines into new files, so spend is only
/// counted once by making the first file to see an event its owner. That means
/// one entry per assistant message, for as long as history is retained — a claim
/// can only be dropped once its message can no longer reappear in a new file, and
/// a resume may copy arbitrarily old lines, so entries are never pruned.
///
/// The naive shape (`[String: String]`) repeats a full absolute session path as
/// the *value* of every entry — ~110 bytes each, and every message of a session
/// repeats the same one. On a real 22k-claim table that was 4.8 MB of a 6.9 MB
/// cache file, re-encoded in full on every save. Interning the paths into an
/// array and storing a 4-byte index collapses that to roughly a third with no
/// change in meaning: `owner(of:)` resolves back to the identical string.
///
/// `ids` is the reverse lookup used while claiming; it is derived from `paths`
/// and so is rebuilt on decode rather than persisted.
struct ClaimMap: Sendable {
    /// Interned owner paths. Index-stable: entries are only ever appended, since
    /// `owners` stores positions into this array.
    private(set) var paths: [String] = []
    /// Claim key → index into `paths`.
    private(set) var owners: [String: Int32] = [:]
    private var ids: [String: Int32] = [:]

    init() {}

    /// Rebuilds the reverse lookup; used by decoding and by the v2 migration.
    init(paths: [String], owners: [String: Int32]) {
        self.paths = paths
        self.owners = owners
        var ids = [String: Int32](minimumCapacity: paths.count)
        for (index, path) in paths.enumerated() { ids[path] = Int32(index) }
        self.ids = ids
    }

    /// Migration from the pre-1.5 `[String: String]` shape.
    init(legacy: [String: String]) {
        var paths: [String] = []
        var ids = [String: Int32]()
        var owners = [String: Int32](minimumCapacity: legacy.count)
        for (key, owner) in legacy {
            let id: Int32
            if let existing = ids[owner] {
                id = existing
            } else {
                id = Int32(paths.count)
                paths.append(owner)
                ids[owner] = id
            }
            owners[key] = id
        }
        self.paths = paths
        self.owners = owners
        self.ids = ids
    }

    var count: Int { owners.count }
    var isEmpty: Bool { owners.isEmpty }

    /// The file that owns `key`, or nil if unclaimed.
    func owner(of key: String) -> String? {
        guard let id = owners[key] else { return nil }
        let index = Int(id)
        guard paths.indices.contains(index) else { return nil }
        return paths[index]
    }

    subscript(key: String) -> String? { owner(of: key) }

    private mutating func id(for path: String) -> Int32 {
        if let existing = ids[path] { return existing }
        let id = Int32(paths.count)
        paths.append(path)
        ids[path] = id
        return id
    }

    mutating func set(_ key: String, owner: String) {
        owners[key] = id(for: owner)
    }

    /// True if `owner` may count this event — a fresh claim, or a re-parse by the
    /// file that already owns it.
    mutating func claim(_ key: String, owner: String) -> Bool {
        let ownerId = id(for: owner)
        if let existing = owners[key] { return existing == ownerId }
        owners[key] = ownerId
        return true
    }

    /// Restore archived claims without disturbing live ones: an entry already in
    /// this map is fresher than its archived copy and keeps its owner.
    mutating func seed(from other: ClaimMap) {
        for (key, id) in other.owners where owners[key] == nil {
            let index = Int(id)
            guard other.paths.indices.contains(index) else { continue }
            set(key, owner: other.paths[index])
        }
    }

    /// The pre-1.5 `[claimKey: ownerPath]` shape, for writing files that older
    /// builds still have to read.
    var legacyDictionary: [String: String] {
        var out = [String: String](minimumCapacity: owners.count)
        for (key, id) in owners {
            let index = Int(id)
            guard paths.indices.contains(index) else { continue }
            out[key] = paths[index]
        }
        return out
    }

    /// Entries owned by any of `wanted`, resolved back to paths. Callers never
    /// see indices; interning stays an encoding detail.
    func entries(ownedByAnyOf wanted: Set<String>) -> [(key: String, owner: String)] {
        let wantedIds = Set(wanted.compactMap { ids[$0] })
        guard !wantedIds.isEmpty else { return [] }
        return owners.compactMap { key, id in
            guard wantedIds.contains(id) else { return nil }
            return (key, paths[Int(id)])
        }
    }
}

/// Dictionary-literal construction keeps call sites (and the test suite) reading
/// as if this were still a plain `[key: ownerPath]` map.
extension ClaimMap: ExpressibleByDictionaryLiteral {
    init(dictionaryLiteral elements: (String, String)...) {
        self.init(legacy: Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

extension ClaimMap: Equatable {
    /// Compared by meaning, not by interning layout: two maps that resolve every
    /// key to the same owner are equal even if their `paths` arrays differ in
    /// order (which they will, since `paths` order follows insertion).
    static func == (lhs: ClaimMap, rhs: ClaimMap) -> Bool {
        guard lhs.owners.count == rhs.owners.count else { return false }
        for (key, id) in lhs.owners {
            guard let rhsId = rhs.owners[key] else { return false }
            let lhsIndex = Int(id), rhsIndex = Int(rhsId)
            guard lhs.paths.indices.contains(lhsIndex), rhs.paths.indices.contains(rhsIndex),
                  lhs.paths[lhsIndex] == rhs.paths[rhsIndex]
            else { return false }
        }
        return true
    }
}

/// Thread-safe ownership registry used during a parallel scan. The first file to
/// claim a key owns it; copies of the same event in other files are skipped.
final class ClaimTable: @unchecked Sendable {
    private var map: ClaimMap
    private let lock = NSLock()

    init(_ map: ClaimMap = ClaimMap()) {
        self.map = map
    }

    /// True if `owner` may count this event (fresh claim, or re-parse by the owner).
    func claim(_ key: String, owner: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return map.claim(key, owner: owner)
    }

    var snapshot: ClaimMap {
        lock.lock()
        defer { lock.unlock() }
        return map
    }
}
