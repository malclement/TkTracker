import SpriteKit
import AppKit
import simd

/// Global draw layers. Objects inside rooms sort by isometric depth × 10
/// (0…~400); everything that must stay bright at night sits above the overlay.
private enum Layer {
    static let ground: CGFloat = -8_000
    static let shell: CGFloat = -7_000
    static let floorMarks: CGFloat = -6_000
    static let night: CGFloat = 1_000
    static let glow: CGFloat = 1_100
    static let signals: CGFloat = 1_200
}

/// Cached textures, drawn once per key and scaled with nearest-neighbour.
@MainActor
final class PixelTextures {
    static let shared = PixelTextures()
    private var textures: [String: SKTexture] = [:]
    private var origins: [String: SIMD2<Double>] = [:]

    func texture(_ key: String, _ make: () -> PixelCanvas) -> SKTexture {
        if let cached = textures[key] { return cached }
        if textures.count > 4_000 { textures.removeAll(); origins.removeAll() }
        let texture = SKTexture(cgImage: make().cgImage())
        texture.filteringMode = .nearest
        textures[key] = texture
        return texture
    }
    func piece(_ key: String, _ make: () -> PixelPiece) -> (SKTexture, SIMD2<Double>) {
        if let cached = textures[key], let origin = origins[key] { return (cached, origin) }
        var origin = SIMD2<Double>.zero
        let texture = self.texture(key) { let piece = make(); origin = piece.origin; return piece.canvas }
        origins[key] = origin
        return (texture, origin)
    }
    func sim(_ look: WorkshopLook, _ pose: WorkshopPose, face: Bool, frame: Int, blink: Bool) -> (SKTexture, SIMD2<Double>) {
        piece("sim|\(look.key)|\(pose.rawValue)|\(face)|\(frame)|\(blink)") {
            let sprite = PixelSims.sprite(look: look, pose: pose, face: face, frame: frame, blink: blink)
            return PixelPiece(canvas: sprite.canvas, origin: sprite.anchor)
        }
    }
}

private extension SKSpriteNode {
    /// Place a piece so its origin pixel sits on this node's position.
    func show(_ piece: (SKTexture, SIMD2<Double>)) {
        let (texture, origin) = piece
        if self.texture !== texture { self.texture = texture }
        let size = texture.size()
        if self.size != size { self.size = size }
        anchorPoint = CGPoint(x: origin.x / size.width, y: (size.height - origin.y) / size.height)
    }
}

/// Lot coordinates: tile (0, 0) at the art origin; scene y points up.
private let lotIso = Iso(ox: 0, oy: 0)
private func scenePoint(_ i: Double, _ j: Double, _ k: Double = 0) -> CGPoint {
    let p = lotIso.p(i, j, k)
    return CGPoint(x: p.x.rounded(), y: -p.y.rounded())
}

/// The pixel workshop: one room per session on a lot in a quiet neighbourhood.
@MainActor
final class PixelWorkshopScene: SKScene {
    struct Model {
        var islands: [WorkshopIsland] = []
        var selectedID: String?
        var dark = true
        var reducedMotion = false
        var tokens: [String: Int] = [:]
        var presentationID = ""
        var zoomStep = 0
        var cameraReset = 0
    }

    var onSelect: (String) -> Void = { _ in }
    /// Points of the view hidden by SwiftUI chrome, so the lot centres in the rest.
    var insets = NSEdgeInsets(top: 64, left: 0, bottom: 76, right: 0)
    var backingScale: CGFloat = 2

    private(set) var model = Model()
    private let world = SKNode()
    private let cam = SKCameraNode()
    private let overlay = SKSpriteNode(color: .white, size: .zero)
    private let groundNode = SKSpriteNode()
    private var groundKey = ""
    /// The lot including its one-tile lawn margin, and the street's first column.
    private var lawn = (lower: WorkshopTile(i: -1, j: -1), upper: WorkshopTile(i: 8, j: 7))
    private var streetI = 8
    private var scenery: [SKSpriteNode] = []
    private var lampGlows: [SKSpriteNode] = []
    private var rooms: [String: RoomNode] = [:]
    private var departingRooms: [RoomNode] = []
    private var slots: [String: Int] = [:]
    private let ring = SKSpriteNode()
    private var clock: Double = 0
    private var lastTime: TimeInterval?
    private var pan = CGPoint.zero
    private var dragStart: CGPoint?
    private var dragOrigin = CGPoint.zero
    private var dragged = false
    private var builtDark: Bool?
    private var appliedReset = 0

    override init(size: CGSize) {
        super.init(size: size)
        scaleMode = .resizeFill
        backgroundColor = Self.grass
        anchorPoint = CGPoint(x: 0.5, y: 0.5)
        addChild(world)
        addChild(cam)
        camera = cam
        overlay.zPosition = Layer.night
        overlay.blendMode = .multiply
        let m = PixelWorkshopNight.multiply
        overlay.color = NSColor(srgbRed: m.x, green: m.y, blue: m.z, alpha: 1)
        cam.addChild(overlay)
        groundNode.zPosition = Layer.ground
        world.addChild(groundNode)
        ring.zPosition = Layer.floorMarks
        ring.show(PixelTextures.shared.piece("ring") { PixelPiece(canvas: PixelSims.selectionRing(), origin: [13, 6.5]) })
        ring.isHidden = true
        world.addChild(ring)
    }
    required init?(coder: NSCoder) { nil }

    override func didChangeSize(_ oldSize: CGSize) {
        super.didChangeSize(oldSize)
        layoutBackdrop()
        fitCamera()
    }

    // MARK: Model

    func apply(_ next: Model, animate: Bool) {
        let rebuild = next.presentationID != model.presentationID
        if next.cameraReset != appliedReset { appliedReset = next.cameraReset; pan = .zero }
        if rebuild {
            for room in rooms.values { room.removeFromParent() }
            for room in departingRooms { room.removeFromParent() }
            rooms.removeAll(); departingRooms.removeAll(); slots.removeAll(); pan = .zero
        }
        let animateChanges = animate && !rebuild && !next.reducedMotion
        model = next
        if builtDark != next.dark { builtDark = next.dark; layoutBackdrop() }

        let islands = Array(next.islands.prefix(WorkshopLotPlan.slotOrigins.count))
        slots = WorkshopLotPlan.assignSlots(previous: slots, ids: islands.map(\.id))
        let occupied = Set(islands.compactMap { slots[$0.id] })
        for (id, room) in rooms where !islands.contains(where: { $0.id == id }) {
            rooms.removeValue(forKey: id)
            if animateChanges { room.depart(clock: clock); departingRooms.append(room) } else { room.removeFromParent() }
        }
        for island in islands {
            guard let slot = slots[island.id] else { continue }
            let room: RoomNode
            if let existing = rooms[island.id], existing.slot == slot {
                room = existing
            } else {
                rooms[island.id]?.removeFromParent()
                room = RoomNode(islandID: island.id, slot: slot)
                rooms[island.id] = room
                world.addChild(room)
                if animateChanges { room.arrive() }
            }
            let walls = WorkshopLotPlan.wallHeights(slot: slot, occupied: occupied)
            room.update(island: island, walls: walls, model: next, clock: clock, animate: animateChanges)
        }
        updateGround(occupied: occupied)
        updateSelection()
        fitCamera()
        tick(delta: 0)
    }

    /// Beyond the drawn field the view shows this same grass, so edges never show.
    static let grass = NSColor(hex: 0x88BF6A)

    private func updateGround(occupied: Set<Int>) {
        let (lower, upper) = WorkshopLotPlan.bounds(occupied: occupied)
        let lawnLower = WorkshopTile(i: lower.i - 1, j: lower.j - 1), lawnUpper = WorkshopTile(i: upper.i + 1, j: upper.j + 1)
        let street = lawnUpper.i
        // The street runs well past the view in both directions, so its ends never show.
        let field = (WorkshopTile(i: lawnLower.i - 14, j: lawnLower.j - 30), WorkshopTile(i: street + 16, j: lawnUpper.j + 30))
        // Paths from each door to the sidewalk. Rooms with a neighbour to the
        // east go round it, down the garden path between the columns.
        var paths = Set<WorkshopTile>()
        for slot in occupied {
            let origin = WorkshopLotPlan.slotOrigins[slot]
            let doorJ = origin.j + WorkshopRoomTemplate.door.j
            let east = origin.i + WorkshopRoomTemplate.width
            if slot % 2 == 0 && occupied.contains(slot + 1) {
                let gap = east + 1
                paths.insert(WorkshopTile(i: east, j: doorJ))
                for j in doorJ..<upper.j { paths.insert(WorkshopTile(i: gap, j: j)) }
                for i in gap..<street { paths.insert(WorkshopTile(i: i, j: upper.j)) }
            } else {
                for i in east..<street { paths.insert(WorkshopTile(i: i, j: doorJ)) }
            }
        }
        /// True when a spot is clear of every path tile, with `margin` tiles to spare.
        func clearOfPaths(_ i: Double, _ j: Double, margin: Double = 0.7) -> Bool {
            !paths.contains { Double($0.i) - margin < i && i < Double($0.i + 1) + margin && Double($0.j) - margin < j && j < Double($0.j + 1) + margin }
        }
        // Gardens fill the empty slots inside the lot. Only low planting: a
        // tree here would hide the room behind it.
        let emptySlots = (0..<WorkshopLotPlan.slotOrigins.count).filter { slot in
            let o = WorkshopLotPlan.slotOrigins[slot]
            return !occupied.contains(slot) && o.i >= lower.i && o.j >= lower.j && o.i < upper.i && o.j < upper.j
        }
        var beds: [WorkshopTile] = []
        var gardenPieces: [(key: String, spot: SIMD2<Double>)] = []
        for slot in emptySlots {
            let o = WorkshopLotPlan.slotOrigins[slot]
            let (oi, oj) = (Double(o.i), Double(o.j))
            let bedRow = [1, 4].first { r in (0..<2).allSatisfy { dj in (1..<6).allSatisfy { di in
                !paths.contains(WorkshopTile(i: o.i + di, j: o.j + r + dj)) } } }
            if let bedRow {
                beds.append(WorkshopTile(i: o.i + 1, j: o.j + bedRow))
                gardenPieces.append(("bench", [oi + 4.4, Double(o.j + bedRow) + 0.5]))
            }
            for (n, spot) in [SIMD2<Double>(oi + 0.8, oj + 0.9), [oi + 6.2, oj + 0.9], [oi + 0.9, oj + 5.4], [oi + 6.3, oj + 5.3]].enumerated()
                where clearOfPaths(spot.x, spot.y, margin: 0.3) {
                gardenPieces.append(("bush|\(n % 2)", spot))
            }
        }
        let rooms = occupied.sorted().map { WorkshopLotPlan.slotOrigins[$0] }
        let key = "ground|\(field.0.i),\(field.0.j),\(field.1.i),\(field.1.j)|\(occupied.sorted())"
        guard key != groundKey else { return }
        groundKey = key
        lawn = (lawnLower, lawnUpper)
        streetI = street
        groundNode.show(PixelTextures.shared.piece(key) {
            PixelRooms.ground(field: field, lawn: (lawnLower, lawnUpper), streetI: street, paths: paths, rooms: rooms, beds: beds, seed: workshopHash(key))
        })
        groundNode.position = scenePoint(Double(field.0.i), Double(field.0.j))

        for node in scenery { node.removeFromParent() }
        for node in lampGlows { node.removeFromParent() }
        scenery.removeAll(); lampGlows.removeAll()
        func add(_ key: String, at spot: SIMD2<Double>, _ make: () -> PixelPiece) {
            let node = SKSpriteNode()
            node.show(PixelTextures.shared.piece(key, make))
            node.position = scenePoint(spot.x, spot.y)
            // Anything behind the lot sits under the room shells, so back walls hide it.
            let behind = spot.x < Double(lower.i) || spot.y < Double(lower.j)
            node.zPosition = behind ? Layer.shell - 500 + CGFloat(spot.x + spot.y) : CGFloat(spot.x + spot.y) * 10
            world.addChild(node)
            scenery.append(node)
        }
        func piece(_ key: String) -> PixelPiece {
            if key == "bench" { return PixelRooms.bench() }
            let variant = Int(key.split(separator: "|").last ?? "") ?? 0
            return key.hasPrefix("bush") ? PixelRooms.bush(variant) : PixelRooms.tree(variant)
        }
        func free(_ i: Double, _ j: Double) -> Bool {
            let onLot = i > Double(lawnLower.i) - 1 && j > Double(lawnLower.j) - 1 && i < Double(lawnUpper.i) && j < Double(lawnUpper.j) + 0.5
            let onStreet = i > Double(street) - 0.8 && i < Double(street) + 4.6
            return !onLot && !onStreet
        }
        // A hedge along the lot's back edges marks where the lot ends.
        var k = Double(lawnLower.i) + 0.6
        while k < Double(lawnUpper.i) - 0.4 { add("bush|\(Int(k) % 3)", at: [k, Double(lawnLower.j) + 0.45]) { PixelRooms.bush(Int(k) % 3) }; k += 1.1 }
        k = Double(lawnLower.j) + 1.7
        while k < Double(lawnUpper.j) - 0.4 { add("bush|\(Int(k) % 3)", at: [Double(lawnLower.i) + 0.45, k]) { PixelRooms.bush(Int(k) % 3) }; k += 1.1 }
        // A picket fence along the front edge, open where it meets the sidewalk.
        for i in lawnLower.i..<lawnUpper.i {
            add("fence", at: [Double(i), Double(lawnUpper.j) - 0.1]) { PixelRooms.fence() }
        }
        for garden in gardenPieces { add(garden.key, at: garden.spot) { piece(garden.key) } }
        // Trees round the neighbourhood on a jittered grid, so they never pile up.
        let spacing = 2.6
        var gi = Double(field.0.i) + 1
        while gi < Double(field.1.i) - 1 {
            var gj = Double(field.0.j) + 1
            while gj < Double(field.1.j) - 1 {
                let h = workshopHash("\(key)-tree-\(Int(gi * 10)),\(Int(gj * 10))")
                let i = gi + Double(h % 100) / 100 * spacing * 0.8, j = gj + Double((h >> 8) % 100) / 100 * spacing * 0.8
                gj += spacing
                // Thin near the lot so it stays the subject; fuller further out.
                let distance = max(Double(lawnLower.i) - i, i - Double(street + 4), Double(lawnLower.j) - j, j - Double(lawnUpper.j), 0)
                let keep = min(0.42, 0.08 + distance * 0.045)
                guard Double((h >> 16) % 1000) / 1000 < keep, free(i, j) else { continue }
                let kind = (h >> 28) % 7
                let name = kind < 2 ? "bush|\(kind)" : "tree|\(kind % 3)"
                add(name, at: [i, j]) { piece(name) }
            }
            gi += spacing
        }
        // Streetlamps on the far sidewalk, so they never stand in front of a room.
        var j = Double(field.0.j) + 2.5
        while j < Double(field.1.j) {
            add("streetlamp", at: [Double(street) + 3.75, j]) { PixelRooms.streetlamp(lit: true) }
            let glow = SKSpriteNode()
            glow.show(PixelTextures.shared.piece("glow-street") { PixelPiece(canvas: PixelSims.glow(width: 80, height: 44, color: PixelColor(0xFFCF78)), origin: [40, 22]) })
            glow.blendMode = .add
            glow.zPosition = Layer.glow
            glow.position = scenePoint(Double(street) + 3.2, j, 2) // a pool of light on the ground
            glow.isHidden = !model.dark
            world.addChild(glow)
            lampGlows.append(glow)
            j += 5
        }
        if let first = occupied.min() {
            let origin = WorkshopLotPlan.slotOrigins[first]
            add("mailbox", at: [Double(street) - 0.15, Double(origin.j + WorkshopRoomTemplate.door.j) + 3.0]) { PixelRooms.mailbox() }
        }
    }

    private func updateSelection() {
        ring.isHidden = true
        for room in rooms.values { room.selectedID = model.selectedID }
    }

    // MARK: Backdrop

    private func layoutBackdrop() {
        overlay.isHidden = !model.dark
        for glow in lampGlows { glow.isHidden = !model.dark }
        layoutBackdropSize()
    }

    // MARK: Camera

    private var zoomLevels: [CGFloat] {
        let steps: [CGFloat] = [0.5, 1, 1.5, 2, 2.5, 3, 3.5, 4, 5, 6]
        // Only zooms where one art pixel is a whole number of device pixels.
        return steps.filter { ($0 * backingScale).rounded() == $0 * backingScale && $0 * backingScale >= 1 }
    }

    /// Art-pixel bounds of the lot and its street, in scene coordinates.
    private var lotFrame: CGRect {
        let (from, to) = lawn
        let streetEnd = Double(streetI + 4)
        let left = scenePoint(Double(from.i), Double(to.j)).x, right = scenePoint(streetEnd, Double(from.j)).x
        let top = scenePoint(Double(from.i), Double(from.j)).y + 46
        let bottom = scenePoint(streetEnd, Double(to.j)).y
        return CGRect(x: left, y: bottom, width: right - left, height: top - bottom)
    }

    private(set) var zoom: CGFloat = 1

    private func fitCamera() {
        guard size.width > 0, size.height > 0 else { return }
        let frame = lotFrame
        let availW = max(80, size.width - insets.left - insets.right - 24)
        let availH = max(80, size.height - insets.top - insets.bottom - 16)
        let levels = zoomLevels
        let fit = levels.lastIndex { frame.width * $0 <= availW && frame.height * $0 <= availH } ?? 0
        let index = min(levels.count - 1, max(0, fit + model.zoomStep))
        zoom = levels[index]
        cam.setScale(1 / zoom)
        let shift = CGPoint(x: (insets.right - insets.left) / 2 / zoom, y: (insets.bottom - insets.top) / 2 / zoom)
        var position = CGPoint(x: frame.midX + pan.x + shift.x, y: frame.midY + pan.y - shift.y)
        let grid = 1 / (zoom * backingScale)
        position.x = (position.x / grid).rounded() * grid
        position.y = (position.y / grid).rounded() * grid
        cam.position = position
        layoutBackdropSize()
    }

    private func layoutBackdropSize() {
        // Camera children are drawn in view points, unaffected by the camera's scale.
        overlay.size = CGSize(width: size.width + 4, height: size.height + 4)
    }

    // MARK: Frame loop

    override func update(_ currentTime: TimeInterval) {
        // Clamped both ways: a paused view or a restarted clock must not jump or rewind.
        let delta = lastTime.map { max(0, min(0.1, currentTime - $0)) } ?? 0
        lastTime = currentTime
        tick(delta: delta)
    }

    private func tick(delta: Double) {
        clock += delta
        let reduced = model.reducedMotion
        for room in rooms.values { room.tick(clock: clock, delta: delta, reduced: reduced) }
        departingRooms.removeAll { room in
            room.tick(clock: clock, delta: delta, reduced: reduced)
            if room.finished(clock: clock) { room.removeFromParent(); return true }
            return false
        }
        if let selected = model.selectedID, let point = rooms.values.lazy.compactMap({ $0.floorPoint(of: selected) }).first {
            ring.isHidden = false
            ring.position = point
        } else {
            ring.isHidden = true
        }
    }

    // MARK: Input

    override func mouseDown(with event: NSEvent) {
        dragStart = viewPoint(event)
        dragOrigin = pan
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let now = viewPoint(event) else { return }
        if hypot(now.x - start.x, now.y - start.y) > 4 { dragged = true }
        guard dragged else { return }
        pan = CGPoint(x: dragOrigin.x - (now.x - start.x) / zoom, y: dragOrigin.y - (now.y - start.y) / zoom)
        let frame = lotFrame
        pan.x = min(frame.width / 2, max(-frame.width / 2, pan.x))
        pan.y = min(frame.height / 2, max(-frame.height / 2, pan.y))
        fitCamera()
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil }
        guard !dragged else { return }
        let point = event.location(in: self)
        if let id = agentID(at: point) { onSelect(id) }
    }

    private func viewPoint(_ event: NSEvent) -> CGPoint? {
        view.map { $0.convert(event.locationInWindow, from: nil) }
    }

    func agentID(at point: CGPoint) -> String? {
        for node in nodes(at: point).sorted(by: { $0.zPosition > $1.zPosition }) {
            var current: SKNode? = node
            while let candidate = current {
                if let name = candidate.name, name.hasPrefix("agent:") { return String(name.dropFirst(6)) }
                current = candidate.parent
            }
        }
        // A click on a room's floor selects its lead.
        let tile = lotIso.tile(at: [Double(point.x), Double(-point.y)])
        for (id, room) in rooms {
            let o = WorkshopLotPlan.slotOrigins[room.slot]
            if tile.x >= Double(o.i), tile.y >= Double(o.j), tile.x < Double(o.i + WorkshopRoomTemplate.width), tile.y < Double(o.j + WorkshopRoomTemplate.height) {
                return model.islands.first { $0.id == id }?.lead.id
            }
        }
        return nil
    }
}

// MARK: - Room

/// One session's room: shell, furniture, cut-away walls, sign and its team.
@MainActor
private final class RoomNode: SKNode {
    let islandID: String
    let slot: Int
    var selectedID: String?
    private let origin: WorkshopTile
    private let shell = SKSpriteNode()
    private var shellKey = ""
    private var furniture: [String: SKSpriteNode] = [:]
    private var deskKeys: [Int: String] = [:]
    private var glows: [String: SKSpriteNode] = [:]
    private var stubs: [SKSpriteNode] = []
    private let sign = SKSpriteNode()
    private let overflowNode = SKSpriteNode()
    /// Warm ceiling light at night, on while anyone in the room is at work.
    private let roomLight = SKSpriteNode()
    private var signText = ""
    private var sims: [String: SimNode] = [:]
    private var leaving: [SimNode] = []
    private var template = WorkshopRoomTemplate(deskCount: 1)
    private var departedAt: Double?
    private var dark = true

    init(islandID: String, slot: Int) {
        self.islandID = islandID
        self.slot = slot
        origin = WorkshopLotPlan.slotOrigins[slot]
        super.init()
        shell.zPosition = Layer.shell + CGFloat(origin.i + origin.j)
        shell.position = point(0, 0)
        addChild(shell)
        for n in 0..<WorkshopRoomTemplate.width {
            stubs.append(stub(alongI: true, i: Double(n), j: Double(WorkshopRoomTemplate.height)))
        }
        for n in 0..<WorkshopRoomTemplate.height where n != WorkshopRoomTemplate.door.j {
            stubs.append(stub(alongI: false, i: Double(WorkshopRoomTemplate.width), j: Double(n)))
        }
        let mat = SKSpriteNode()
        mat.show(PixelTextures.shared.piece("doormat") { PixelRooms.doormat() })
        mat.position = point(Double(WorkshopRoomTemplate.width) + 0.25, Double(WorkshopRoomTemplate.door.j))
        mat.zPosition = Layer.floorMarks
        addChild(mat)
        addChild(sign)
        addChild(overflowNode)
        roomLight.show(PixelTextures.shared.piece("glow-room") {
            PixelPiece(canvas: PixelSims.glow(width: 196, height: 98, color: PixelColor(0xFFC070), intensity: 0.85), origin: [98, 49])
        })
        roomLight.blendMode = .add
        roomLight.zPosition = Layer.glow - 1
        roomLight.position = point(Double(WorkshopRoomTemplate.width) / 2, Double(WorkshopRoomTemplate.height) / 2, 6)
        roomLight.isHidden = true
        addChild(roomLight)
    }
    required init?(coder: NSCoder) { nil }

    private func stub(alongI: Bool, i: Double, j: Double) -> SKSpriteNode {
        let node = SKSpriteNode()
        node.show(PixelTextures.shared.piece("stub|\(alongI)") { PixelRooms.stub(alongI: alongI) })
        node.position = point(i, j)
        node.zPosition = depth(i + (alongI ? 0.5 : 0.25), j + (alongI ? 0.25 : 0.5)) + 8
        addChild(node)
        return node
    }

    func point(_ i: Double, _ j: Double, _ k: Double = 0) -> CGPoint {
        scenePoint(Double(origin.i) + i, Double(origin.j) + j, k)
    }
    func depth(_ i: Double, _ j: Double) -> CGFloat { CGFloat(Double(origin.i + origin.j) + i + j) * 10 }

    func arrive() {
        alpha = 0
        position.y = 18
        run(.group([.fadeIn(withDuration: 0.45), .moveTo(y: 0, duration: 0.45)]))
        puff(at: point(3.5, 3))
    }

    func depart(clock: Double) {
        departedAt = clock
        for sim in sims.values { sim.leave(template: template, clock: clock) }
        run(.sequence([.wait(forDuration: 1.4), .fadeOut(withDuration: 0.5)]))
        run(.sequence([.wait(forDuration: 1.5), .run { [weak self] in guard let self else { return }; self.puff(at: self.point(3.5, 3)) }]))
    }
    func finished(clock: Double) -> Bool { departedAt.map { clock - $0 > 2.2 } ?? false }

    private func puff(at p: CGPoint) {
        guard let parent = parent else { return }
        let frames = (0..<3).map { f in PixelTextures.shared.texture("dust|\(f)") { PixelSims.dust(frame: f) } }
        let node = SKSpriteNode(texture: frames[0])
        node.position = CGPoint(x: p.x + position.x, y: p.y + position.y)
        node.zPosition = Layer.signals
        parent.addChild(node)
        node.run(.sequence([.animate(with: frames, timePerFrame: 0.12), .removeFromParent()]))
    }

    func update(island: WorkshopIsland, walls: (backRight: Int, backLeft: Int), model: PixelWorkshopScene.Model, clock: Double, animate: Bool) {
        dark = model.dark
        let shown = Array(island.subagents.prefix(WorkshopRoomTemplate.maxDesks - 1))
        let members = [island.lead] + shown
        let previousDesks = template.deskCount
        template = WorkshopRoomTemplate(deskCount: members.count)
        let decor = WorkshopDecor(projectPath: island.lead.projectPath, source: island.lead.source)

        let key = "shell|\(decor.wallpaper).\(decor.floor).\(decor.rug)|\(walls.backRight).\(walls.backLeft)"
        if key != shellKey {
            shellKey = key
            shell.show(PixelTextures.shared.piece(key) { PixelRooms.shell(decor: decor, backRight: walls.backRight, backLeft: walls.backLeft) })
        }

        // Fixed furniture.
        place("plant", i: 0, j: 0, depthAt: [0.5, 0.5]) { PixelRooms.plant() }
        place("bookshelf", i: 0, j: 1, depthAt: [0.3, 1.5]) { PixelRooms.bookshelf() }
        place("coffee", i: 6, j: 0, depthAt: [6.5, 0.5]) { PixelRooms.coffee() }
        place("couch|\(decor.couch)", i: 0, j: 5, depthAt: [1.5, 5.5], name: "couch") { PixelRooms.couch(decor.couch) }

        // Desks, one per member, in a fixed order.
        for n in 0..<WorkshopRoomTemplate.maxDesks {
            let deskName = "desk\(n)", chairName = "chair\(n)"
            guard n < members.count else {
                for name in [deskName, chairName] { furniture.removeValue(forKey: name)?.run(.sequence([.fadeOut(withDuration: 0.3), .removeFromParent()])) }
                glows.removeValue(forKey: deskName)?.removeFromParent()
                glows.removeValue(forKey: deskName + "-screen")?.removeFromParent()
                deskKeys[n] = nil
                continue
            }
            let owner = members[n]
            let spec = WorkshopRoomTemplate.desks[n]
            let working = owner.state.isWorking || owner.state == .needsInput || owner.state == .waitingForAgents
            let atDesk = owner.state.isWorking
            let sheets = WorkshopPaperStack.sheets(tokens: model.tokens[owner.id])
            let deskKey = "desk|\(spec.screenFacesI)|\(working)|\(sheets)|\(atDesk)"
            let isNew = furniture[deskName] == nil
            let desk = furniture[deskName] ?? SKSpriteNode()
            if isNew { addChild(desk); furniture[deskName] = desk }
            desk.position = point(Double(spec.i), Double(spec.j))
            desk.zPosition = depth(Double(spec.i) + Double(spec.w) / 2, Double(spec.j) + Double(spec.d) / 2)
            if deskKeys[n] != deskKey {
                deskKeys[n] = deskKey
                let frames = (0..<(working ? 3 : 1)).map { f in
                    PixelTextures.shared.piece("\(deskKey)|\(f)") {
                        PixelRooms.desk(facesI: spec.screenFacesI, screen: working, frame: f, sheets: sheets, lamp: atDesk)
                    }
                }
                desk.removeAction(forKey: "screen")
                desk.show(frames[0])
                if working && !model.reducedMotion {
                    desk.run(.repeatForever(.animate(with: frames.map(\.0), timePerFrame: 0.4)), withKey: "screen")
                }
            }
            if isNew && animate && n >= previousDesks {
                desk.alpha = 0
                desk.position.y += 20
                desk.run(.group([.fadeIn(withDuration: 0.3), .moveBy(x: 0, y: -20, duration: 0.3)]))
                puff(at: desk.position)
            }
            let seat = template.seat(desk: n)
            let chair = furniture[chairName] ?? SKSpriteNode()
            if furniture[chairName] == nil { addChild(chair); furniture[chairName] = chair }
            chair.show(PixelTextures.shared.piece("chair") { PixelRooms.chair() })
            chair.position = point(seat.point.x, seat.point.y)
            chair.zPosition = depth(seat.point.x, seat.point.y) + 6
            // Desk lamp light at night, only while its owner works.
            let lamp = spec.screenFacesI ? SIMD2<Double>(Double(spec.i) + 0.3, Double(spec.j) + 1.75) : SIMD2<Double>(Double(spec.i) + 1.75, Double(spec.j) + 0.3)
            let glow = glows[deskName] ?? SKSpriteNode()
            if glows[deskName] == nil {
                glow.show(PixelTextures.shared.piece("glow") { PixelPiece(canvas: PixelSims.glow(width: 64, height: 34, color: PixelColor(0xFFD98A)), origin: [32, 20]) })
                glow.blendMode = .add
                glow.zPosition = Layer.glow
                addChild(glow); glows[deskName] = glow
            }
            glow.position = point(lamp.x, lamp.y, 18)
            glow.isHidden = !(dark && atDesk)
            let screenName = deskName + "-screen"
            let screenGlow = glows[screenName] ?? SKSpriteNode()
            if glows[screenName] == nil {
                screenGlow.show(PixelTextures.shared.piece("glow-screen") { PixelPiece(canvas: PixelSims.glow(width: 34, height: 20, color: PixelColor(0x7FF5D6)), origin: [17, 10]) })
                screenGlow.blendMode = .add
                screenGlow.zPosition = Layer.glow
                addChild(screenGlow); glows[screenName] = screenGlow
            }
            let monitor = spec.screenFacesI ? SIMD2<Double>(Double(spec.i) + 0.4, Double(spec.j) + 1.0) : SIMD2<Double>(Double(spec.i) + 1.0, Double(spec.j) + 0.4)
            screenGlow.position = point(monitor.x, monitor.y, 21)
            screenGlow.isHidden = !(dark && working)
        }

        roomLight.isHidden = !(dark && members.contains { $0.state.isWorking || $0.state == .needsInput || $0.state == .waitingForAgents })

        // Signage.
        let title = island.lead.projectName
        if title != signText {
            signText = title
            sign.show(PixelTextures.shared.piece("sign|\(PixelFont.sanitized(title))") { PixelRooms.nameplate(title) })
        }
        // Beside the door, where the path from the street arrives.
        sign.position = point(Double(WorkshopRoomTemplate.width) + 0.55, Double(WorkshopRoomTemplate.door.j) + 1.9)
        sign.zPosition = depth(Double(WorkshopRoomTemplate.width) + 0.55, Double(WorkshopRoomTemplate.door.j) + 1.9) + 9
        let hidden = island.subagents.count - shown.count
        overflowNode.isHidden = hidden <= 0
        if hidden > 0 {
            overflowNode.show(PixelTextures.shared.piece("overflow|\(hidden)") { PixelRooms.overflow(hidden) })
            overflowNode.position = point(6.6, 4.9, 34)
            overflowNode.zPosition = Layer.signals
        }

        // The team.
        let stations = WorkshopStationPlanner.stations(for: members, template: template)
        let ids = Set(members.map(\.id))
        for (id, sim) in sims where !ids.contains(id) {
            sims.removeValue(forKey: id)
            if animate { sim.leave(template: template, clock: clock); leaving.append(sim) } else { sim.removeFromParent() }
        }
        for agent in members {
            guard let station = stations[agent.id] else { continue }
            if let sim = sims[agent.id] {
                sim.update(agent: agent, station: station, template: template, clock: clock, animate: animate)
            } else {
                let sim = SimNode(agent: agent, room: self)
                sims[agent.id] = sim
                addChild(sim)
                sim.enter(agent: agent, station: station, template: template, clock: clock, animate: animate)
            }
        }
    }

    private func place(_ key: String, i: Int, j: Int, depthAt center: SIMD2<Double>, name: String? = nil, make: () -> PixelPiece) {
        let slotName = name ?? key
        let node = furniture[slotName] ?? SKSpriteNode()
        if furniture[slotName] == nil { addChild(node); furniture[slotName] = node }
        node.show(PixelTextures.shared.piece(key, make))
        node.position = point(Double(i), Double(j))
        node.zPosition = depth(center.x, center.y)
    }

    var couchDepth: CGFloat { depth(1.5, 5.5) }

    func tick(clock: Double, delta: Double, reduced: Bool) {
        for sim in sims.values { sim.tick(clock: clock, delta: delta, reduced: reduced, selected: sim.agentID == selectedID) }
        leaving.removeAll { sim in
            sim.tick(clock: clock, delta: delta, reduced: reduced, selected: false)
            if sim.gone { sim.removeFromParent(); return true }
            return false
        }
    }

    func floorPoint(of id: String) -> CGPoint? {
        guard let sim = sims[id], departedAt == nil else { return nil }
        return CGPoint(x: sim.position.x + position.x, y: sim.position.y + position.y)
    }
}

// MARK: - Sim

/// One agent: walks between stations, poses for its state, and carries its
/// plumbob, thought bubble and effects.
@MainActor
private final class SimNode: SKNode {
    let agentID: String
    private unowned let room: RoomNode
    private let look: WorkshopLook
    private let body = SKSpriteNode()
    private let plumbob = SKSpriteNode()
    private let bubble = SKSpriteNode()
    private let effects = SKNode()
    private var agent: WorkshopAgent
    private var station: WorkshopStation
    private var local: SIMD2<Double> = WorkshopRoomTemplate.outside
    private var waypoints: [SIMD2<Double>] = []
    private var facing: WorkshopFacing = .southWest
    private var celebrateUntil: Double?
    private var pendingWalk: (() -> Void)?
    private var leavingAt: Double?
    private var effectKind = ""
    private var bubbleKey = ""
    private let seed: Double
    private(set) var gone = false

    init(agent: WorkshopAgent, room: RoomNode) {
        agentID = agent.id
        self.room = room
        self.agent = agent
        look = WorkshopLook(agentID: agent.id)
        station = WorkshopStation(tile: WorkshopRoomTemplate.door, point: WorkshopRoomTemplate.door.center, facing: .southWest, pose: .stand)
        seed = Double(workshopHash(agent.id) % 1000) / 1000
        super.init()
        name = "agent:" + agent.id
        body.name = name
        addChild(body)
        plumbob.anchorPoint = CGPoint(x: 0.5, y: 0)
        addChild(plumbob)
        bubble.anchorPoint = .zero
        addChild(bubble)
        addChild(effects)
    }
    required init?(coder: NSCoder) { nil }

    private var tile: WorkshopTile { WorkshopTile(i: Int(local.x.rounded(.down)), j: Int(local.y.rounded(.down))) }

    func enter(agent: WorkshopAgent, station: WorkshopStation, template: WorkshopRoomTemplate, clock: Double, animate: Bool) {
        self.agent = agent
        self.station = station
        if animate {
            local = WorkshopRoomTemplate.outside
            alpha = 0
            run(.fadeIn(withDuration: 0.35))
            walk(from: WorkshopRoomTemplate.door, template: template, prefix: [WorkshopRoomTemplate.door.center])
        } else {
            local = station.point
            facing = station.facing
        }
        refreshSignals(clock: clock)
    }

    func update(agent next: WorkshopAgent, station next2: WorkshopStation, template: WorkshopRoomTemplate, clock: Double, animate: Bool) {
        let previousState = agent.state
        agent = next
        let moved = next2 != station
        station = next2
        if !animate {
            waypoints.removeAll(); celebrateUntil = nil; pendingWalk = nil
            local = station.point; facing = station.facing
        } else if previousState != .completed && next.state == .completed {
            // A little cheer where they stand, then off for a coffee.
            celebrateUntil = clock + 1.6
            waypoints.removeAll()
            pendingWalk = { [weak self] in self?.walk(from: self?.tile ?? template.seat(desk: 0).tile, template: template) }
        } else if moved {
            celebrateUntil = nil; pendingWalk = nil
            walk(from: tile, template: template)
        }
        refreshSignals(clock: clock)
    }

    func leave(template: WorkshopRoomTemplate, clock: Double) {
        leavingAt = clock
        celebrateUntil = nil
        pendingWalk = nil
        let route = WorkshopPathfinder.path(from: tile, to: WorkshopRoomTemplate.door, blocked: template.blocked)
        waypoints = route.dropFirst().map(\.center) + [WorkshopRoomTemplate.outside]
        plumbob.isHidden = true; bubble.isHidden = true; effects.removeAllChildren()
    }

    private func walk(from start: WorkshopTile, template: WorkshopRoomTemplate, prefix: [SIMD2<Double>] = []) {
        let route = WorkshopPathfinder.path(from: start, to: station.tile, blocked: template.blocked)
        waypoints = prefix + route.dropFirst().map(\.center) + [station.point]
    }

    private var pose: WorkshopPose {
        if let until = celebrateUntil, until > 0 { return .cheer }
        if !waypoints.isEmpty { return .walk }
        return station.pose
    }

    func tick(clock: Double, delta: Double, reduced: Bool, selected: Bool) {
        if let until = celebrateUntil, clock >= until {
            celebrateUntil = nil
            let next = pendingWalk; pendingWalk = nil
            next?()
        }
        if reduced && leavingAt == nil, !waypoints.isEmpty {
            local = station.point; waypoints.removeAll()
        }
        if let target = waypoints.first {
            let step = 2.4 * delta
            let offset = target - local
            let distance = simd_length(offset)
            if distance > 0.001 { facing = WorkshopFacing.toward(offset) }
            if distance <= step { local = target; waypoints.removeFirst() } else { local += offset / distance * step }
            if waypoints.isEmpty {
                if leavingAt != nil { run(.sequence([.fadeOut(withDuration: 0.3), .run { [weak self] in self?.gone = true }])) }
                else { facing = station.facing }
            }
        }
        render(clock: clock, reduced: reduced)
    }

    private func render(clock: Double, reduced: Bool) {
        let pose = self.pose
        position = room.point(local.x, local.y)
        let seated = waypoints.isEmpty && (pose == .sit || pose == .sleep)
        zPosition = seated ? room.couchDepth + 7 : room.depth(local.x, local.y) + 5
        let fps: Double
        switch pose {
        case .walk: fps = 6
        case .type: fps = 5
        case .wave, .cheer: fps = 4
        case .wait: fps = 2.5
        case .stand: fps = 0.8
        default: fps = 0
        }
        let frame = reduced ? 0 : Int((clock + seed * 3) * fps) % 2
        let face = pose == .sleep ? true : facing.showsFace
        let blinkPhase = (clock + seed * 7).truncatingRemainder(dividingBy: 4.3)
        let blink = !reduced && face && blinkPhase < 0.14 && [.stand, .wave, .walk].contains(pose)
        body.show(PixelTextures.shared.sim(look, pose, face: face, frame: frame, blink: blink))
        body.xScale = facing.mirrored && pose != .sleep ? -1 : 1
        body.alpha = agent.state == .unavailable ? 0.5 : 1

        // Signals stay bright above the night overlay.
        let signalZ = Layer.signals + zPosition / 10 - zPosition
        let head: CGFloat
        switch pose {
        case .sleep: head = 18
        case .type: head = 26
        case .sit: head = 27
        case .cheer: head = 34
        default: head = 30
        }
        guard leavingAt == nil else { return }
        let spin = reduced ? 0 : Int(clock * 6 + seed * 4) % 4
        plumbob.texture = PixelTextures.shared.texture("plumbob|\(agent.state.rawValue)|\(spin)") { PixelSims.plumbob(agent.state, frame: spin) }
        plumbob.size = CGSize(width: 9, height: 14)
        let bob = reduced ? 0 : (sin(clock * 2.4 + seed * 6) * 1.5).rounded()
        plumbob.position = CGPoint(x: pose == .sleep ? -2 : 0, y: head + 5 + CGFloat(bob))
        plumbob.zPosition = signalZ + 1
        bubble.position = CGPoint(x: pose == .sleep ? 6 : 6, y: head + 8)
        bubble.zPosition = signalZ + 2
        effects.position = CGPoint(x: pose == .sleep ? 4 : 2, y: head + 2)
        effects.zPosition = signalZ
    }

    private func refreshSignals(clock: Double) {
        let icon = PixelSims.icon(for: agent)
        let key = icon?.rawValue ?? ""
        if key != bubbleKey {
            bubbleKey = key
            bubble.isHidden = icon == nil
            if let icon {
                bubble.texture = PixelTextures.shared.texture("bubble|\(icon.rawValue)") { PixelSims.bubble(icon) }
                bubble.size = CGSize(width: 20, height: 18)
                bubble.setScale(1)
            }
        }
        let kind = agent.state == .idle ? "z" : agent.state == .interrupted ? "rain" : ""
        guard kind != effectKind else { return }
        effectKind = kind
        effects.removeAllChildren()
        let reduced = (scene as? PixelWorkshopScene)?.model.reducedMotion ?? false
        if kind == "z" {
            let texture = PixelTextures.shared.texture("zglyph") { PixelSims.zGlyph() }
            if reduced {
                let z = SKSpriteNode(texture: texture); z.position = CGPoint(x: 8, y: 6); effects.addChild(z)
            } else {
                effects.run(.repeatForever(.sequence([
                    .run { [weak effects] in
                        let z = SKSpriteNode(texture: texture)
                        z.position = CGPoint(x: 4, y: 0)
                        effects?.addChild(z)
                        z.run(.sequence([.group([.moveBy(x: 6, y: 14, duration: 1.8), .sequence([.wait(forDuration: 1.0), .fadeOut(withDuration: 0.8)])]), .removeFromParent()]))
                    },
                    .wait(forDuration: 1.1),
                ])))
            }
        } else if kind == "rain" {
            let frames = (0..<2).map { f in PixelTextures.shared.texture("rain|\(f)") { PixelSims.rainCloud(frame: f) } }
            let cloud = SKSpriteNode(texture: frames[0])
            cloud.anchorPoint = CGPoint(x: 0.5, y: 0)
            cloud.position = CGPoint(x: -2, y: 8)
            if !reduced { cloud.run(.repeatForever(.animate(with: frames, timePerFrame: 0.25))) }
            effects.addChild(cloud)
        }
    }
}
