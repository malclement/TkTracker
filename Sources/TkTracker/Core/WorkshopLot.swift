import Foundation

// The pure half of the pixel workshop: where rooms sit on the lot, where each
// piece of furniture stands, and where each agent walks for its state. Nothing
// here draws, so layout and behaviour are testable without SpriteKit.

struct WorkshopTile: Hashable, Sendable {
    var i: Int
    var j: Int
    var center: SIMD2<Double> { [Double(i) + 0.5, Double(j) + 0.5] }
}

/// Isometric facings. +i runs toward the lower right of the screen, +j toward
/// the lower left, so the two "south" facings show the Sim's face.
enum WorkshopFacing: Int, Sendable, CaseIterable {
    case southEast, southWest, northEast, northWest

    var showsFace: Bool { self == .southEast || self == .southWest }
    /// Only two facings are drawn; the other two are mirror images.
    var mirrored: Bool { self == .southWest || self == .northWest }

    static func toward(_ delta: SIMD2<Double>) -> Self {
        if abs(delta.x) >= abs(delta.y) { return delta.x >= 0 ? .southEast : .northWest }
        return delta.y >= 0 ? .southWest : .northEast
    }
}

enum WorkshopPose: String, Sendable, CaseIterable {
    case stand, walk, type, sit, sleep, wave, cheer, wait, slump
}

struct WorkshopStation: Equatable, Sendable {
    /// Where the walk ends on the grid.
    var tile: WorkshopTile
    /// Where the Sim finally rests, in room tile units. May sit between tiles
    /// or on furniture (a seat, the couch).
    var point: SIMD2<Double>
    var facing: WorkshopFacing
    var pose: WorkshopPose
}

enum WorkshopFurnitureKind: Equatable, Sendable {
    case desk(Int), plant, coffee, couch, bookshelf
}

struct WorkshopFurniture: Equatable, Sendable {
    var kind: WorkshopFurnitureKind
    var i: Int, j: Int, w: Int, d: Int
    var tiles: [WorkshopTile] { (i..<(i + w)).flatMap { x in (j..<(j + d)).map { WorkshopTile(i: x, j: $0) } } }
    /// Painter's order: the footprint's centre, summed along both axes.
    var depth: Double { Double(i) + Double(w) / 2 + Double(j) + Double(d) / 2 }
}

/// One room, one session. The layout is hand-placed and the same for every
/// team size: desks are added in a fixed order, so a subagent joining never
/// moves anyone else's desk.
struct WorkshopRoomTemplate: Sendable {
    static let width = 7
    static let height = 6
    static let maxDesks = 4
    static let door = WorkshopTile(i: 6, j: 3)
    /// Just outside the doorway, where arrivals appear and departures fade.
    static let outside: SIMD2<Double> = [7.4, 3.5]

    let deskCount: Int

    init(deskCount: Int) { self.deskCount = min(Self.maxDesks, max(1, deskCount)) }

    /// Desk footprints and which way the monitor faces (+j or +i).
    static let desks: [(i: Int, j: Int, w: Int, d: Int, screenFacesI: Bool)] = [
        (1, 0, 2, 1, false), (4, 0, 2, 1, false), (0, 2, 1, 2, true), (4, 3, 2, 1, false),
    ]

    var furniture: [WorkshopFurniture] {
        var items = [
            WorkshopFurniture(kind: .plant, i: 0, j: 0, w: 1, d: 1),
            WorkshopFurniture(kind: .bookshelf, i: 0, j: 1, w: 1, d: 1),
            WorkshopFurniture(kind: .coffee, i: 6, j: 0, w: 1, d: 1),
            WorkshopFurniture(kind: .couch, i: 0, j: 5, w: 3, d: 1),
        ]
        for (n, desk) in Self.desks.prefix(deskCount).enumerated() {
            items.append(WorkshopFurniture(kind: .desk(n), i: desk.i, j: desk.j, w: desk.w, d: desk.d))
        }
        return items
    }

    var blocked: Set<WorkshopTile> { Set(furniture.flatMap(\.tiles)) }

    func seat(desk: Int) -> WorkshopStation {
        switch desk {
        case 0: return WorkshopStation(tile: .init(i: 2, j: 1), point: [2.0, 1.3], facing: .northEast, pose: .type)
        case 1: return WorkshopStation(tile: .init(i: 5, j: 1), point: [5.0, 1.3], facing: .northEast, pose: .type)
        case 2: return WorkshopStation(tile: .init(i: 1, j: 3), point: [1.3, 3.0], facing: .northWest, pose: .type)
        default: return WorkshopStation(tile: .init(i: 5, j: 4), point: [5.0, 4.3], facing: .northEast, pose: .type)
        }
    }

    /// Where a waiting agent stands to watch someone else's desk.
    func hover(desk: Int) -> WorkshopStation {
        switch desk {
        case 0: return WorkshopStation(tile: .init(i: 3, j: 2), point: [3.4, 2.4], facing: .northWest, pose: .wait)
        case 1: return WorkshopStation(tile: .init(i: 4, j: 2), point: [4.5, 2.5], facing: .northEast, pose: .wait)
        case 2: return WorkshopStation(tile: .init(i: 2, j: 2), point: [2.5, 2.6], facing: .northWest, pose: .wait)
        default: return WorkshopStation(tile: .init(i: 3, j: 4), point: [3.5, 4.5], facing: .southEast, pose: .wait)
        }
    }

    static let whiteboard = WorkshopStation(tile: .init(i: 3, j: 1), point: [3.5, 1.5], facing: .northEast, pose: .wait)
    static let coffeeSpots = [
        WorkshopStation(tile: .init(i: 6, j: 1), point: [6.5, 1.5], facing: .northEast, pose: .stand),
        WorkshopStation(tile: .init(i: 6, j: 2), point: [6.5, 2.5], facing: .northEast, pose: .stand),
    ]
    static let couchSpots = [
        WorkshopStation(tile: .init(i: 1, j: 4), point: [1.5, 5.45], facing: .southWest, pose: .sit),
        WorkshopStation(tile: .init(i: 0, j: 4), point: [0.6, 5.45], facing: .southWest, pose: .sit),
        WorkshopStation(tile: .init(i: 2, j: 4), point: [2.4, 5.45], facing: .southWest, pose: .sit),
    ]
    static let frontSpots = [
        WorkshopStation(tile: .init(i: 4, j: 5), point: [4.5, 5.5], facing: .southWest, pose: .wave),
        WorkshopStation(tile: .init(i: 5, j: 5), point: [5.5, 5.5], facing: .southWest, pose: .wave),
        WorkshopStation(tile: .init(i: 6, j: 5), point: [6.5, 5.5], facing: .southWest, pose: .wave),
    ]
}

/// Where each member of a team goes for its current state. Members are the
/// lead followed by the displayed subagents; member n owns desk n.
enum WorkshopStationPlanner {
    static func stations(for members: [WorkshopAgent], template: WorkshopRoomTemplate) -> [String: WorkshopStation] {
        var result: [String: WorkshopStation] = [:]
        var front = WorkshopRoomTemplate.frontSpots[...]
        var coffee = WorkshopRoomTemplate.coffeeSpots[...]
        let idle = members.filter { $0.state == .idle }
        var couch = WorkshopRoomTemplate.couchSpots[...]
        var watched = Set<Int>()
        var whiteboardTaken = false

        for (desk, agent) in members.enumerated() {
            let seat = template.seat(desk: min(desk, template.deskCount - 1))
            let standing = WorkshopStation(tile: seat.tile, point: seat.tile.center, facing: .southWest, pose: .stand)
            switch agent.state {
            case .working, .usingTool:
                result[agent.id] = seat
            case .needsInput:
                result[agent.id] = front.popFirst() ?? WorkshopStation(tile: seat.tile, point: seat.tile.center, facing: .southWest, pose: .wave)
            case .completed:
                result[agent.id] = coffee.popFirst() ?? standing
            case .idle:
                if var spot = couch.popFirst() {
                    // Alone on the couch, stretch out; otherwise everyone dozes sitting up.
                    if idle.count == 1 { spot.pose = .sleep }
                    result[agent.id] = spot
                } else {
                    result[agent.id] = standing
                }
            case .waitingForAgents:
                let target = members.enumerated().first { index, other in
                    index != desk && other.state.isWorking && !watched.contains(index)
                }?.offset
                if let target {
                    watched.insert(target)
                    result[agent.id] = template.hover(desk: min(target, template.deskCount - 1))
                } else if !whiteboardTaken {
                    whiteboardTaken = true
                    result[agent.id] = WorkshopRoomTemplate.whiteboard
                } else {
                    result[agent.id] = WorkshopStation(tile: seat.tile, point: seat.tile.center, facing: .southWest, pose: .wait)
                }
            case .interrupted:
                result[agent.id] = WorkshopStation(tile: seat.tile, point: seat.tile.center, facing: .southWest, pose: .slump)
            case .unavailable:
                result[agent.id] = standing
            }
        }
        return result
    }
}

/// 4-neighbour A* on a room grid. Unreachable goals fall back to a direct
/// step, so a Sim can never get stuck out of sight.
enum WorkshopPathfinder {
    static func path(from start: WorkshopTile, to goal: WorkshopTile, blocked: Set<WorkshopTile>,
                     width: Int = WorkshopRoomTemplate.width, height: Int = WorkshopRoomTemplate.height) -> [WorkshopTile] {
        guard start != goal else { return [goal] }
        func inside(_ t: WorkshopTile) -> Bool { t.i >= 0 && t.j >= 0 && t.i < width && t.j < height }
        guard inside(goal), !blocked.contains(goal) else { return [start, goal] }
        func cost(_ t: WorkshopTile) -> Int { abs(t.i - goal.i) + abs(t.j - goal.j) }
        var open: Set<WorkshopTile> = [start]
        var came: [WorkshopTile: WorkshopTile] = [:]
        var g: [WorkshopTile: Int] = [start: 0]
        while !open.isEmpty {
            // Ties break on grid order so paths are deterministic.
            let current = open.min { a, b in
                let fa = g[a, default: .max] + cost(a), fb = g[b, default: .max] + cost(b)
                return fa != fb ? fa < fb : (a.j, a.i) < (b.j, b.i)
            }!
            if current == goal {
                var route = [goal]
                var step = goal
                while let previous = came[step] { route.append(previous); step = previous }
                return route.reversed()
            }
            open.remove(current)
            for (di, dj) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                let next = WorkshopTile(i: current.i + di, j: current.j + dj)
                guard inside(next), !blocked.contains(next) || next == goal else { continue }
                let score = g[current, default: .max] + 1
                if score < g[next, default: .max] {
                    came[next] = current; g[next] = score; open.insert(next)
                }
            }
        }
        return [start, goal]
    }
}

/// Up to four rooms on one lot, in a 2×2 grid with a garden path between them.
enum WorkshopLotPlan {
    static let slotOrigins = [WorkshopTile(i: 0, j: 0), WorkshopTile(i: 9, j: 0), WorkshopTile(i: 0, j: 8), WorkshopTile(i: 9, j: 8)]
    static let fullWall = 40
    static let lowWall = 16

    /// Existing rooms keep their slot; newcomers take the first free one.
    static func assignSlots(previous: [String: Int], ids: [String]) -> [String: Int] {
        var result = previous.filter { ids.contains($0.key) && $0.value < slotOrigins.count }
        for id in ids where result[id] == nil {
            guard let free = (0..<slotOrigins.count).first(where: { !result.values.contains($0) }) else { break }
            result[id] = free
        }
        return result
    }

    /// Back walls stand full height unless a room sits behind them, where they
    /// would hide that room. Cut-away walls are the Sims convention.
    static func wallHeights(slot: Int, occupied: Set<Int>) -> (backRight: Int, backLeft: Int) {
        let behind = slot >= 2 ? slot - 2 : nil
        let left = slot % 2 == 1 ? slot - 1 : nil
        return (behind.map { occupied.contains($0) } == true ? lowWall : fullWall,
                left.map { occupied.contains($0) } == true ? lowWall : fullWall)
    }

    /// Tile bounds of the occupied slots: (minimum, maximum exclusive).
    static func bounds(occupied: Set<Int>) -> (WorkshopTile, WorkshopTile) {
        let origins = occupied.sorted().map { slotOrigins[$0] }
        guard !origins.isEmpty else { return (.init(i: 0, j: 0), .init(i: WorkshopRoomTemplate.width, j: WorkshopRoomTemplate.height)) }
        return (.init(i: origins.map(\.i).min()!, j: origins.map(\.j).min()!),
                .init(i: origins.map(\.i).max()! + WorkshopRoomTemplate.width, j: origins.map(\.j).max()! + WorkshopRoomTemplate.height))
    }
}

/// Stable string hash; `String.hashValue` changes between launches.
func workshopHash(_ text: String) -> UInt64 {
    var h: UInt64 = 1469598103934665603
    for byte in text.utf8 { h = (h ^ UInt64(byte)) &* 1099511628211 }
    return h
}

/// A Sim's appearance, chosen by the agent id, so a resumed session looks the same.
struct WorkshopLook: Hashable, Sendable {
    static let skins = 6, hairColors = 7, hairStyles = 4, shirts = 8, trousers = 5
    var skin: Int, hair: Int, hairStyle: Int, shirt: Int, trousersColor: Int

    init(agentID: String) {
        let h = workshopHash(agentID)
        skin = Int(h % UInt64(Self.skins))
        hair = Int((h >> 8) % UInt64(Self.hairColors))
        hairStyle = Int((h >> 16) % UInt64(Self.hairStyles))
        shirt = Int((h >> 24) % UInt64(Self.shirts))
        trousersColor = Int((h >> 32) % UInt64(Self.trousers))
    }
    var key: String { "\(skin).\(hair).\(hairStyle).\(shirt).\(trousersColor)" }
}

/// A project's room decor. The same project gets the same room every day;
/// Claude Code rooms lean warm, Codex rooms cool.
struct WorkshopDecor: Hashable, Sendable {
    static let wallpapersPerFamily = 3, floors = 4, rugs = 4, couches = 3
    var wallpaper: Int, floor: Int, rug: Int, couch: Int

    init(projectPath: String, source: UsageSource) {
        let h = workshopHash(projectPath)
        wallpaper = Int(h % UInt64(Self.wallpapersPerFamily)) + (source == .codex ? Self.wallpapersPerFamily : 0)
        floor = Int((h >> 12) % UInt64(Self.floors))
        rug = Int((h >> 24) % UInt64(Self.rugs))
        couch = Int((h >> 36) % UInt64(Self.couches))
    }
}

enum WorkshopPaperStack {
    /// Sheets of paper on a desk: one per third of a decade of recorded tokens,
    /// from 1k tokens up, capped so a long session doesn't hit the ceiling.
    static func sheets(tokens: Int?) -> Int {
        guard let tokens, tokens >= 1_000 else { return 0 }
        return min(12, max(1, Int(((log10(Double(tokens)) - 3) * 3).rounded())))
    }
}
