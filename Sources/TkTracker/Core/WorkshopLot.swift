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

/// One building per project, shared by every session open on it. The room is
/// a fixed-depth open office that grows along the street: a lounge at the
/// street corner, then bays of two desks (one against the back wall, one in the
/// middle row), then a walkway. Desk n always sits in the same place, so a
/// room grows by adding bays at the far end and nobody's desk ever moves.
///
/// Axes: i runs from the back wall (0) toward the street; j runs along the
/// street from the lounge end. The walls at i = 0 and j = 0 are drawn; the
/// street side and the far end are cut away.
struct WorkshopRoomTemplate: Sendable {
    /// Depth from the back wall to the street side, in tiles.
    static let width = 7
    static let loungeLength = 3
    static let bayLength = 2
    static let maxBays = 6
    static let maxDesks = maxBays * 2
    static let door = WorkshopTile(i: 6, j: 2)
    /// Just outside the doorway, where arrivals appear and departures fade.
    static let outside: SIMD2<Double> = [7.4, 2.5]

    /// Desks shown (one per displayed member), and the bays that hold them.
    let deskCount: Int
    let bays: Int

    init(deskCount: Int) {
        self.deskCount = min(Self.maxDesks, max(1, deskCount))
        bays = (self.deskCount + 1) / 2
    }

    /// The room's length along the street.
    var length: Int { Self.length(bays: bays) }
    static func length(bays: Int) -> Int { loungeLength + bays * bayLength + 1 }

    /// Desk n: bay n / 2, back-wall row for even n and middle row for odd n.
    /// Every desk is two tiles long and faces the street (+i).
    static func desk(_ n: Int) -> (i: Int, j: Int, w: Int, d: Int) {
        (n % 2 == 0 ? 0 : 3, loungeLength + (n / 2) * bayLength, 1, bayLength)
    }

    var furniture: [WorkshopFurniture] {
        var items = [
            WorkshopFurniture(kind: .plant, i: 0, j: 0, w: 1, d: 1),
            WorkshopFurniture(kind: .coffee, i: 1, j: 0, w: 1, d: 1),
            WorkshopFurniture(kind: .couch, i: 3, j: 0, w: 3, d: 1),
            WorkshopFurniture(kind: .plant, i: 6, j: 0, w: 1, d: 1),
            WorkshopFurniture(kind: .bookshelf, i: 0, j: length - 1, w: 1, d: 1),
        ]
        for n in 0..<deskCount {
            let desk = Self.desk(n)
            items.append(WorkshopFurniture(kind: .desk(n), i: desk.i, j: desk.j, w: desk.w, d: desk.d))
        }
        return items
    }

    var blocked: Set<WorkshopTile> { Set(furniture.flatMap(\.tiles)) }

    /// Sitting at desk n, facing its monitor (toward the back wall).
    func seat(desk n: Int) -> WorkshopStation {
        let desk = Self.desk(n)
        return WorkshopStation(tile: .init(i: desk.i + 1, j: desk.j + 1), point: [Double(desk.i) + 1.3, Double(desk.j) + 1.0],
                               facing: .northWest, pose: .type)
    }

    /// Where a waiting agent stands to watch someone at desk n: just behind them.
    func hover(desk n: Int) -> WorkshopStation {
        let desk = Self.desk(n)
        return WorkshopStation(tile: .init(i: desk.i + 2, j: desk.j + 1), point: [Double(desk.i) + 2.4, Double(desk.j) + 1.5],
                               facing: .northWest, pose: .wait)
    }

    /// Needing you: at the open far end of the room, facing out.
    var frontSpots: [WorkshopStation] {
        [4, 5, 6, 2].map { i in WorkshopStation(tile: .init(i: i, j: length - 1), point: [Double(i) + 0.5, Double(length) - 0.5], facing: .southWest, pose: .wave) }
    }

    /// The whiteboard hangs on the back wall in the lounge.
    static let whiteboard = WorkshopStation(tile: .init(i: 1, j: 2), point: [1.4, 2.0], facing: .northWest, pose: .wait)
    static let coffeeSpots = [
        WorkshopStation(tile: .init(i: 1, j: 1), point: [1.5, 1.4], facing: .northEast, pose: .stand),
        WorkshopStation(tile: .init(i: 2, j: 1), point: [2.5, 1.6], facing: .northEast, pose: .stand),
    ]
    /// Seats on the couch, which stands against the side wall facing into the room.
    static let couchSpots = [
        WorkshopStation(tile: .init(i: 4, j: 1), point: [4.5, 0.45], facing: .southWest, pose: .sit),
        WorkshopStation(tile: .init(i: 3, j: 1), point: [3.6, 0.45], facing: .southWest, pose: .sit),
        WorkshopStation(tile: .init(i: 5, j: 1), point: [5.4, 0.45], facing: .southWest, pose: .sit),
    ]
}

/// Desks are handed out like parking spaces: whoever has one keeps it, and a
/// newcomer takes the lowest free one.
enum WorkshopDeskPlan {
    static func assign(previous: [String: Int], ids: [String], capacity: Int) -> [String: Int] {
        let wanted = Set(ids)
        var result = previous.filter { wanted.contains($0.key) && $0.value < capacity }
        var taken = Set(result.values)
        for id in ids where result[id] == nil {
            guard let free = (0..<capacity).first(where: { !taken.contains($0) }) else { break }
            result[id] = free
            taken.insert(free)
        }
        return result
    }
}

/// Where each member of a building goes for its current state. `desks` maps a
/// member to its desk; without it, member n owns desk n. `teams` maps each
/// member to its session's lead, so a waiting lead watches its own subagents.
enum WorkshopStationPlanner {
    static func stations(for members: [WorkshopAgent], template: WorkshopRoomTemplate,
                         desks: [String: Int]? = nil, teams: [String: String] = [:]) -> [String: WorkshopStation] {
        let desks = desks ?? Dictionary(uniqueKeysWithValues: members.enumerated().map { ($1.id, $0) })
        var result: [String: WorkshopStation] = [:]
        var front = template.frontSpots[...]
        var coffee = WorkshopRoomTemplate.coffeeSpots[...]
        let idle = members.filter { $0.state == .idle }
        var couch = WorkshopRoomTemplate.couchSpots[...]
        var watched = Set<String>()
        var whiteboardTaken = false
        func team(_ agent: WorkshopAgent) -> String { teams[agent.id] ?? agent.parentID ?? agent.id }

        for agent in members {
            let desk = min(desks[agent.id] ?? 0, template.deskCount - 1)
            let seat = template.seat(desk: desk)
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
                // Watch a working teammate from this session first, then anyone working.
                let candidates = members.filter { $0.id != agent.id && $0.state.isWorking && !watched.contains($0.id) }
                let target = candidates.first { team($0) == team(agent) } ?? candidates.first
                if let target, let targetDesk = desks[target.id], targetDesk < template.deskCount {
                    watched.insert(target.id)
                    result[agent.id] = template.hover(desk: targetDesk)
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
                     width: Int = WorkshopRoomTemplate.width, height: Int = WorkshopRoomTemplate.length(bays: WorkshopRoomTemplate.maxBays)) -> [WorkshopTile] {
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

/// Buildings stand in a row along the street, one per project, in the order
/// their projects first opened. A building that grows pushes its neighbours
/// further down the street.
enum WorkshopLotPlan {
    static let maxBuildings = 6
    /// Lawn between neighbouring buildings.
    static let gap = 2
    static let fullWall = 40
    static let lowWall = 16

    /// Each building's origin, given the room lengths in street order.
    static func origins(lengths: [Int]) -> [WorkshopTile] {
        var j = 0
        return lengths.map { length in
            defer { j += length + gap }
            return WorkshopTile(i: 0, j: j)
        }
    }

    /// The side wall drops where another building stands behind it, so it
    /// doesn't hide that building's far end. The back wall never hides anything.
    static func wallHeights(index: Int) -> (backRight: Int, backLeft: Int) {
        (index > 0 ? lowWall : fullWall, fullWall)
    }

    /// Tile bounds of the buildings: (minimum, maximum exclusive).
    static func bounds(lengths: [Int]) -> (WorkshopTile, WorkshopTile) {
        let total = max(1, lengths.reduce(0, +) + max(0, lengths.count - 1) * gap)
        return (.init(i: 0, j: 0), .init(i: WorkshopRoomTemplate.width, j: total))
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
