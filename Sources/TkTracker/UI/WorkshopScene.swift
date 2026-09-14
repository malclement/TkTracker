import SwiftUI
import AppKit
import RealityKit
import Combine
import simd

extension WorkshopState {
    var tint: Color { Color(nsColor: ink) }
    var ink: NSColor {
        let pair: (UInt32, UInt32)
        switch self {
        case .working, .usingTool: pair = (0x167463, 0x77CBB4)
        case .needsInput: pair = (0x92551D, 0xE4B166)
        case .waitingForAgents: pair = (0x7560AD, 0xBBA7E4)
        case .completed: pair = (0x377842, 0x8ACB92)
        case .interrupted: pair = (0xA34C46, 0xE3A09A)
        case .idle, .unavailable: return .secondaryLabelColor
        }
        return NSColor(name: nil) { appearance in
            NSColor(hex: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? pair.1 : pair.0)
        }
    }
}

/// RealityKit's native macOS view gives us camera projection and hit testing
/// while all navigation and agent details remain ordinary SwiftUI controls.
struct WorkshopScene: NSViewRepresentable {
    var islands: [WorkshopIsland]
    var selectedID: String?
    var zoom: Double
    var cameraReset: Int
    var presentationID: String
    var reducedMotion: Bool
    var dark: Bool
    var onSelect: (String) -> Void

    func makeNSView(context: Context) -> WorkshopViewport { WorkshopViewport(frame: .zero) }
    func updateNSView(_ view: WorkshopViewport, context: Context) {
        view.select = onSelect
        view.update(islands: islands, selectedID: selectedID, zoom: Float(zoom), cameraReset: cameraReset, presentationID: presentationID, reducedMotion: reducedMotion, dark: dark)
    }
    static func dismantleNSView(_ view: WorkshopViewport, coordinator: ()) { view.stop() }
}

@MainActor
final class WorkshopViewport: NSView, NSGestureRecognizerDelegate {
    private let renderView = ARView(frame: .zero)
    private let world = AnchorEntity(world: .zero)
    private let camera = PerspectiveCamera()
    private var subscription: (any Cancellable)?
    private var islands: [String: IslandNode] = [:]
    private var labels: [String: IslandLabel] = [:]
    private var slots: [String: Int] = [:]
    private var labelAnchors: [String: Entity] = [:]
    private var cameraReset = 0
    private var presentationID: String?
    private var azimuth: Float = 0.28
    private var elevation: Float = 0.48
    private var dragOrigin = SIMD2<Float>(0.28, 0.48)
    private var selectedID: String?
    private var zoom: Float = 1
    private var reducedMotion = false
    private var dark: Bool?
    private var clock: Double = 0
    private var accumulated: Double = 0
    private var islandCount = 0
    private let clouds = Entity()
    var select: (String) -> Void = { _ in }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        addSubview(renderView)
        renderView.scene.addAnchor(world)
        camera.camera.fieldOfViewInDegrees = 34
        world.addChild(camera)

        let sunlight = DirectionalLight()
        sunlight.light = DirectionalLightComponent(color: NSColor(hex: 0xFFF0D5), intensity: 1500)
        sunlight.look(at: [0, 0, 0], from: [-5, 9, 6], relativeTo: nil)
        sunlight.shadow = DirectionalLightComponent.Shadow()
        world.addChild(sunlight)
        let fill = DirectionalLight()
        fill.light = DirectionalLightComponent(color: NSColor(hex: 0xD4E7FF), intensity: 750)
        fill.look(at: .zero, from: [6, 4, -4], relativeTo: nil)
        world.addChild(fill)
        let front = DirectionalLight()
        front.light = DirectionalLightComponent(color: .white, intensity: 350)
        front.look(at: .zero, from: [0, 2, 8], relativeTo: nil)
        world.addChild(front)
        world.addChild(clouds)

        let click = NSClickGestureRecognizer(target: self, action: #selector(clicked(_:)))
        renderView.addGestureRecognizer(click)
        let drag = NSPanGestureRecognizer(target: self, action: #selector(dragged(_:)))
        renderView.addGestureRecognizer(drag)
        click.delegate = self
        subscription = renderView.scene.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            self?.tick(event.deltaTime)
        }
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        renderView.frame = bounds
        positionCamera()
        positionLabels()
    }
    func stop() {
        subscription?.cancel(); subscription = nil
        renderView.scene.anchors.removeAll()
        renderView.isHidden = true
    }

    func update(islands input: [WorkshopIsland], selectedID: String?, zoom: Float, cameraReset: Int, presentationID: String, reducedMotion: Bool, dark: Bool) {
        self.selectedID = selectedID; self.zoom = zoom; self.reducedMotion = reducedMotion
        let switchedView = self.presentationID != presentationID
        if switchedView {
            // Changing focus is navigation, not a session closing and reopening.
            for node in islands.values { node.entity.removeFromParent() }
            islands.removeAll(); slots.removeAll()
            self.presentationID = presentationID
        }
        if self.cameraReset != cameraReset {
            self.cameraReset = cameraReset; azimuth = 0.28; elevation = 0.48
        }
        if self.dark != dark {
            self.dark = dark
            if let sky = WorkshopGeometry.sky(dark: dark) {
                renderView.environment.background = .skybox(sky)
            } else {
                renderView.environment.background = .color(NSColor(hex: dark ? 0x111D30 : 0xE5EDF7))
            }
            clouds.children.removeAll()
            let cloudColor: UInt32 = dark ? 0x23354D : 0xF6FAFF
            let clusters: [SIMD3<Float>] = [[-6.7, -1.8, -3.8], [6.4, -1.9, -2.4], [-5.6, -2.0, 4.7], [4.9, -2.1, 5.3]]
            for center in clusters {
                for i in 0..<4 {
                    let offset = SIMD3<Float>(Float(i) * 0.65 - 1, Float(i % 2) * 0.14, Float(i % 3) * 0.20)
                    clouds.addChild(WorkshopGeometry.sphere(scale: [0.85, 0.42 + Float(i % 2) * 0.16, 0.65], color: cloudColor, at: center + offset, unlit: true))
                }
            }
        }
        labelAnchors.removeAll()
        let ids = Set(input.map(\.id))
        for (id, node) in islands where !ids.contains(id) && node.departedAt == nil {
            node.departedAt = clock
            labels[id]?.removeFromSuperview(); labels.removeValue(forKey: id)
            if reducedMotion || window?.occlusionState.contains(.visible) != true {
                node.entity.removeFromParent(); islands.removeValue(forKey: id); slots.removeValue(forKey: id)
            }
        }
        for island in input {
            let node: IslandNode
            if let existing = islands[island.id] {
                node = existing; node.departedAt = nil
            } else {
                let used = Set(slots.values)
                let slot = (0..<max(4, used.count + 1)).first { !used.contains($0) } ?? used.count
                slots[island.id] = slot
                // A background window still needs a complete first frame. Only
                // animate arrivals once the scene is actually visible.
                node = IslandNode(agent: island.lead, bornAt: clock - (!switchedView && window?.occlusionState.contains(.visible) == true ? 0 : 1))
                node.slot = slot
                islands[island.id] = node
                world.addChild(node.entity)
            }
            node.update(island, selectedID: selectedID)
            node.halo.isEnabled = island.lead.id == selectedID
            configureLabel(island.lead, anchor: node.entity, dark: dark)
        }
        for id in Array(labels.keys) where labelAnchors[id] == nil {
            labels.removeValue(forKey: id)?.removeFromSuperview()
        }
        islandCount = input.count
        positionCamera()
        tick(0, force: true)
    }

    private func configureLabel(_ agent: WorkshopAgent, anchor: Entity, dark: Bool) {
        if labels[agent.id] == nil {
            let label = IslandLabel()
            label.clicked = { [weak self] in self?.select(agent.id) }
            labels[agent.id] = label; addSubview(label)
        }
        labelAnchors[agent.id] = anchor
        labels[agent.id]?.configure(title: agent.title, subtitle: agent.state.label,
                                   dark: dark, selected: agent.id == selectedID)
    }

    private func positionCamera() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let active = islands.values.filter { $0.departedAt == nil }
        guard !active.isEmpty else { return }
        var lower = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var upper = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for node in active {
            let box = node.framingBounds
            lower = simd_min(lower, box.0 + location(slot: node.slot))
            upper = simd_max(upper, box.1 + location(slot: node.slot))
        }
        let frame = WorkshopCameraFrame.fit(minimum: lower, maximum: upper,
            aspect: Float(bounds.width / bounds.height), fieldOfView: 34,
            azimuth: azimuth, elevation: elevation, zoom: zoom)
        camera.look(at: frame.target, from: frame.position, relativeTo: nil)
    }

    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldRequireFailureOf otherGestureRecognizer: NSGestureRecognizer) -> Bool {
        gestureRecognizer is NSClickGestureRecognizer && otherGestureRecognizer is NSPanGestureRecognizer
    }

    @objc private func dragged(_ recognizer: NSPanGestureRecognizer) {
        if recognizer.state == .began { dragOrigin = [azimuth, elevation] }
        let translation = recognizer.translation(in: renderView)
        azimuth = dragOrigin.x - Float(translation.x) * 0.006
        elevation = min(1.0, max(0.18, dragOrigin.y + Float(translation.y) * 0.004))
        positionCamera(); positionLabels()
    }
    private func location(slot: Int) -> SIMD3<Float> {
        let locations: [SIMD3<Float>] = [[-3.5, 0.3, -2.0], [3.0, 0.7, -2.5], [-3.2, -0.15, 3.0], [3.3, 0.1, 2.7]]
        return locations[slot % locations.count]
    }

    private func tick(_ delta: TimeInterval, force: Bool = false) {
        guard force || (window?.occlusionState.contains(.visible) == true && !isHidden) else { return }
        accumulated += delta
        guard force || accumulated >= 1.0 / 30 else { return }
        clock += accumulated; accumulated = 0
        for (id, node) in islands {
            if let departure = node.departedAt, reducedMotion || clock - departure > 0.65 {
                node.entity.removeFromParent(); islands.removeValue(forKey: id); slots.removeValue(forKey: id)
                continue
            }
            let age = min(1, Float(clock - node.bornAt) / 0.75)
            let enter = reducedMotion ? 1 : 1 - pow(1 - age, 3)
            let leave = node.departedAt.map { reducedMotion ? Float(1) : min(1, Float(clock - $0) / 0.65) } ?? 0
            let lift = reducedMotion ? 0 : sin(Float(clock) * 0.7 + Float(node.slot) * 1.8) * 0.045
            node.entity.position = location(slot: node.slot) + [0, lift - (1 - enter) * 2 - leave * 2.5, 0]
            node.entity.scale = SIMD3(repeating: max(0.001, enter * (1 - leave)))
            node.animate(time: Float(clock), reducedMotion: reducedMotion)
        }
        positionLabels()
    }

    private func positionLabels() {
        var occupied: [CGRect] = []
        for id in labels.keys.sorted() {
            guard let anchor = labelAnchors[id], let label = labels[id],
                  let point = renderView.project(anchor.convert(position: [0, -1.45, 0], to: nil)) else { continue }
            let width: CGFloat = min(id == selectedID ? 230 : 180, max(130, bounds.width / 3))
            // ARView projection on macOS uses the NSView's bottom-left origin.
            var rect = CGRect(x: point.x - width / 2, y: point.y - 44, width: width, height: 46)
            rect.origin.x = min(max(8, rect.minX), max(8, bounds.width - width - 8))
            rect.origin.y = min(max(8, rect.minY), max(8, bounds.height - 54))
            for other in occupied where other.intersects(rect) { rect.origin.y = max(8, other.minY - 50) }
            label.frame = rect
            occupied.append(rect)
        }
    }
    @objc private func clicked(_ recognizer: NSClickGestureRecognizer) {
        var hit = renderView.entity(at: recognizer.location(in: renderView))
        while let entity = hit {
            if entity.name.hasPrefix("agent:") { select(String(entity.name.dropFirst(6))); return }
            hit = entity.parent
        }
    }
}

@MainActor
private final class IslandLabel: NSView {
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    var clicked: () -> Void = {}
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        subtitle.font = .systemFont(ofSize: 10.5, weight: .medium)
        for field in [title, subtitle] {
            field.alignment = .center
            field.lineBreakMode = .byTruncatingTail
            field.maximumNumberOfLines = 1
            field.isSelectable = false
            addSubview(field)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        title.frame = NSRect(x: 8, y: 24, width: bounds.width - 16, height: 16)
        subtitle.frame = NSRect(x: 8, y: 7, width: bounds.width - 16, height: 14)
    }
    func configure(title text: String, subtitle detail: String, dark: Bool, selected: Bool) {
        title.stringValue = text; subtitle.stringValue = detail
        title.textColor = NSColor(hex: dark ? 0xEFF4FF : 0x20334B)
        subtitle.textColor = NSColor(hex: dark ? 0xA9BED7 : 0x576C83)
        layer?.backgroundColor = NSColor(hex: dark ? 0x1C2C43 : 0xFFFFFF).withAlphaComponent(0.96).cgColor
        layer?.borderWidth = selected ? 1.5 : 0
        layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.75).cgColor
        setAccessibilityLabel("\(text), \(detail)")
        toolTip = "Select \(text)"
    }
    override func mouseDown(with event: NSEvent) { clicked() }
    override func accessibilityPerformPress() -> Bool { clicked(); return true }
}

@MainActor
private final class IslandNode {
    let entity = Entity()
    let halo: ModelEntity
    let robot: WorkshopRobot
    let screen: ModelEntity
    var bornAt: Double
    var departedAt: Double?
    var slot = 0
    private var agent: WorkshopAgent
    private var children: [String: IslandNode] = [:]
    private var childSlots: [String: Int] = [:]
    private var bridges: [String: Entity] = [:]
    private var stateChangedAt: Float = 0
    private var lastState: WorkshopState?

    init(agent: WorkshopAgent, bornAt: Double) {
        self.agent = agent; self.bornAt = bornAt
        entity.name = "agent:" + agent.id
        let accent = Self.accent(agent.id)
        entity.addChild(WorkshopGeometry.rock())
        let grass = WorkshopGeometry.cylinder(radius: 1.23, height: 0.13, color: 0x76A99A, at: [0, 0.035, 0])
        entity.addChild(grass)
        let rim = WorkshopGeometry.cylinder(radius: 1.25, height: 0.06, color: 0xA3CABD, at: [0, -0.06, 0])
        entity.addChild(rim)
        halo = WorkshopGeometry.cylinder(radius: 1.30, height: 0.018, color: 0xEAC779, at: [0, 0.065, 0], unlit: true)
        entity.addChild(halo)
        halo.isEnabled = false
        // Wood platform, workbench, keyboard, and monitor.
        entity.addChild(WorkshopGeometry.box([1.38, 0.045, 1.05], color: 0xBFA886, at: [0.1, 0.12, 0.12], radius: 0.035))
        for i in 0..<8 {
            entity.addChild(WorkshopGeometry.box([0.158, 0.012, 1.02], color: i % 2 == 0 ? 0xD8BF97 : 0xCDB18C,
                                                 at: [-0.50 + Float(i) * 0.17, 0.149, 0.12], radius: 0.006))
        }
        // A little workshop backdrop gives the desk a recognisable silhouette.
        for x: Float in [-0.30, 0.83] {
            entity.addChild(WorkshopGeometry.box([0.06, 1.28, 0.06], color: 0x8F795E, at: [x, 0.78, -0.65], radius: 0.012))
        }
        entity.addChild(WorkshopGeometry.box([1.30, 0.07, 0.40], color: accent, at: [0.265, 1.44, -0.59], radius: 0.025))
        entity.addChild(WorkshopGeometry.box([1.1, 0.035, 0.22], color: 0xCBA77C, at: [0.26, 0.96, -0.66], radius: 0.012))
        for i in 0..<4 {
            entity.addChild(WorkshopGeometry.box([0.065, 0.16 + Float(i % 2) * 0.04, 0.12], color: [0xDFB87E, 0x6FAEA8, 0x9B9AC8, 0xDB947E][i],
                                                 at: [0.49 + Float(i) * 0.072, 1.06, -0.66], radius: 0.008))
        }
        for i in 0..<9 {
            let a = Float(i) * 2 * .pi / 9
            entity.addChild(WorkshopGeometry.sphere(scale: [0.024, 0.03, 0.024], color: 0xFFE4AD,
                at: [cos(a) * 1.17, 0.15, sin(a) * 1.17], unlit: true))
        }
        entity.addChild(WorkshopGeometry.box([0.90, 0.09, 0.47], color: 0xC5996B, at: [0.22, 0.67, -0.26], radius: 0.035))
        for x: Float in [-0.12, 0.57] {
            entity.addChild(WorkshopGeometry.box([0.065, 0.50, 0.065], color: 0x756E61, at: [x, 0.39, -0.26]))
        }
        entity.addChild(WorkshopGeometry.box([0.09, 0.19, 0.07], color: 0x566C6D, at: [0.30, 0.8, -0.38]))
        entity.addChild(WorkshopGeometry.box([0.57, 0.36, 0.07], color: 0x354C54, at: [0.30, 1.01, -0.38], radius: 0.035))
        screen = WorkshopGeometry.box([0.49, 0.28, 0.012], color: 0x89D9BB, at: [0.30, 1.01, -0.336], radius: 0.02, unlit: true)
        entity.addChild(screen)
        for row in 0..<3 {
            entity.addChild(WorkshopGeometry.box([0.18 + Float(row % 2) * 0.13, 0.015, 0.008], color: 0xE0FFF1, at: [0.22, 1.085 - Float(row) * 0.057, -0.326], unlit: true))
        }
        entity.addChild(WorkshopGeometry.box([0.36, 0.025, 0.14], color: 0xECE5D3, at: [0.21, 0.737, -0.09], radius: 0.012))
        // Robot next to the desk, clearly visible from the overview camera.
        robot = WorkshopRobot(accent: accent)
        robot.entity.position = [-0.36, 0.17, 0.41]
        robot.entity.orientation = simd_quatf(angle: -0.25, axis: [0, 1, 0])
        entity.addChild(robot.entity)
        // Miniature tree, stepping stones, mug and a warm desk lamp.
        entity.addChild(WorkshopGeometry.cylinder(radius: 0.045, height: 0.48, color: 0x8A785E, at: [-0.83, 0.35, -0.38]))
        for (position, scale) in [(SIMD3<Float>(-0.84, 0.80, -0.38), SIMD3<Float>(0.34, 0.40, 0.33)), (SIMD3<Float>(-0.65, 0.67, -0.36), SIMD3<Float>(0.25, 0.27, 0.25))] {
            entity.addChild(WorkshopGeometry.sphere(scale: scale, color: 0x527E62, at: position))
        }
        for i in 0..<3 { entity.addChild(WorkshopGeometry.box([0.22, 0.035, 0.16], color: 0xD8D6BF, at: [0.22 + Float(i) * 0.24, 0.13, 0.72], radius: 0.05)) }
        entity.addChild(WorkshopGeometry.cylinder(radius: 0.047, height: 0.10, color: 0xEAD9BD, at: [0.57, 0.765, -0.11]))
        entity.addChild(WorkshopGeometry.cylinder(radius: 0.022, height: 0.75, color: 0x727C6B, at: [0.88, 0.5, -0.12]))
        entity.addChild(WorkshopGeometry.sphere(scale: [0.10, 0.11, 0.10], color: 0xFFE0A4, at: [0.88, 0.9, -0.12], unlit: true))
        // Clickable island and robot; decorative geometry inherits the agent ID.
        entity.components.set(CollisionComponent(shapes: [.generateBox(size: [2.5, 2.7, 2.5]).offsetBy(translation: [0, 0.1, 0])]))
    }

    var framingBounds: (SIMD3<Float>, SIMD3<Float>) {
        var lower = SIMD3<Float>(-1.4, -1.6, -1.4)
        var upper = SIMD3<Float>(1.4, 1.65, 1.4)
        for child in children.values {
            lower = simd_min(lower, child.entity.position + [-0.72, -0.85, -0.72])
            upper = simd_max(upper, child.entity.position + [0.72, 0.85, 0.72])
        }
        return (lower, upper)
    }

    func update(_ island: WorkshopIsland, selectedID: String?) {
        agent = island.lead
        let retained = island.subagents.filter { children[$0.id] != nil }.sorted { (childSlots[$0.id] ?? 0) < (childSlots[$1.id] ?? 0) }
        let newcomers = island.subagents.filter { children[$0.id] == nil }
        let displayed = Array((retained + newcomers).prefix(3))
        let ids = Set(displayed.map(\.id))
        for (id, node) in children where !ids.contains(id) {
            node.entity.removeFromParent(); children.removeValue(forKey: id)
            childSlots.removeValue(forKey: id)
            bridges[id]?.removeFromParent(); bridges.removeValue(forKey: id)
        }
        for child in displayed {
            let used = Set(childSlots.values)
            let index = childSlots[child.id] ?? (0..<3).first { !used.contains($0) } ?? 0
            childSlots[child.id] = index
            let node = children[child.id] ?? IslandNode(agent: child, bornAt: bornAt)
            node.agent = child
            node.halo.isEnabled = child.id == selectedID
            let positions: [SIMD3<Float>] = [[2.3, 0.20, -0.85], [2.05, -0.08, 1.5], [-2.15, 0.1, -1.25]]
            node.entity.position = positions[index]
            node.entity.scale = SIMD3(repeating: 0.55)
            if children[child.id] == nil {
                children[child.id] = node; entity.addChild(node.entity)
                let bridge = WorkshopGeometry.bridge(to: positions[index])
                entity.addChild(bridge); bridges[child.id] = bridge
            }
        }
    }
    func animate(time: Float, reducedMotion: Bool) {
        if lastState != agent.state { stateChangedAt = time; lastState = agent.state }
        robot.pose(state: agent.state, time: time, stateAge: time - stateChangedAt, reducedMotion: reducedMotion)
        robot.entity.orientation = simd_quatf(angle: agent.state.isWorking ? 1.55 : -0.25, axis: [0, 1, 0])
        let bright = agent.state.isWorking || agent.state == .needsInput || agent.state == .waitingForAgents
        if lastBrightness != bright {
            screen.model?.materials = [UnlitMaterial(color: NSColor(hex: bright ? 0x84CFB5 : 0x557375), applyPostProcessToneMap: false)]
            lastBrightness = bright
        }
        for node in children.values { node.animate(time: time, reducedMotion: reducedMotion) }
    }
    private static func accent(_ id: String) -> UInt32 {
        let palette: [UInt32] = [0x559F99, 0xD3A064, 0x9382BB, 0x799BC0, 0xC88379]
        let seed = id.utf8.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1) }
        return palette[Int(seed % UInt64(palette.count))]
    }
    private var lastBrightness: Bool?
}

@MainActor
private final class WorkshopRobot {
    let entity = Entity()
    private let head = Entity()
    private let leftArm = Entity()
    private let rightArm = Entity()
    private let signal: ModelEntity

    init(accent: UInt32) {
        entity.addChild(WorkshopGeometry.box([0.40, 0.38, 0.29], color: accent, at: [0, 0.49, 0], radius: 0.09))
        for x: Float in [-0.11, 0.11] {
            entity.addChild(WorkshopGeometry.box([0.13, 0.17, 0.19], color: 0x435C63, at: [x, 0.20, 0.035], radius: 0.04))
            entity.addChild(WorkshopGeometry.box([0.17, 0.10, 0.25], color: 0xE6E7D9, at: [x, 0.08, 0.075], radius: 0.035))
        }
        head.position = [0, 0.88, 0]
        head.addChild(WorkshopGeometry.box([0.50, 0.39, 0.37], color: 0xE9EBDD, at: .zero, radius: 0.13))
        head.addChild(WorkshopGeometry.box([0.37, 0.19, 0.055], color: 0x314E57, at: [0, 0.008, 0.175], radius: 0.06))
        for x: Float in [-0.09, 0.09] { head.addChild(WorkshopGeometry.sphere(scale: [0.025, 0.038, 0.015], color: 0xADF0D7, at: [x, 0.015, 0.21], unlit: true)) }
        head.addChild(WorkshopGeometry.cylinder(radius: 0.014, height: 0.12, color: 0x647675, at: [0, 0.24, 0]))
        head.addChild(WorkshopGeometry.sphere(scale: [0.039, 0.039, 0.039], color: accent, at: [0, 0.31, 0]))
        entity.addChild(head)
        for (arm, x) in [(leftArm, Float(-0.26)), (rightArm, Float(0.26))] {
            arm.position = [x, 0.62, 0]
            arm.addChild(WorkshopGeometry.box([0.12, 0.28, 0.13], color: accent, at: [0, -0.12, 0], radius: 0.045))
            arm.addChild(WorkshopGeometry.sphere(scale: [0.075, 0.075, 0.075], color: 0xE9EBDD, at: [0, -0.27, 0]))
            entity.addChild(arm)
        }
        signal = WorkshopGeometry.sphere(scale: [0.1, 0.1, 0.1], color: 0xEDB25B, at: [0.38, 1.28, 0], unlit: true)
        entity.addChild(signal)
    }
    func pose(state: WorkshopState, time: Float, stateAge: Float, reducedMotion: Bool) {
        let t = reducedMotion ? Float(0) : time
        leftArm.orientation = simd_quatf(angle: state.isWorking ? -0.7 + sin(t * 6) * 0.16 : 0.1, axis: [1, 0, 0])
        rightArm.orientation = simd_quatf(angle: state.isWorking ? -0.7 + cos(t * 6) * 0.16 : -0.1, axis: [1, 0, 0])
        head.orientation = simd_quatf(angle: state == .idle ? 0.18 : sin(t * 1.3) * (state.isWorking ? 0.045 : 0), axis: [0, 0, 1])
        signal.isEnabled = state == .needsInput || state == .interrupted || state == .waitingForAgents
        if state == .needsInput {
            rightArm.orientation = simd_quatf(angle: -2.65 + sin(t * 2.2) * 0.12, axis: [0, 0, 1])
        } else if state == .completed && (stateAge < 1.4 || reducedMotion) {
            rightArm.orientation = simd_quatf(angle: -1.9, axis: [0, 0, 1])
        } else if state == .waitingForAgents {
            head.orientation = simd_quatf(angle: 0.5, axis: [0, 1, 0])
        } else if state == .interrupted || state == .unavailable {
            head.orientation = simd_quatf(angle: 0.18, axis: [1, 0, 0])
        }
    }
}

@MainActor
private enum WorkshopGeometry {
    private static let unitSphere = MeshResource.generateSphere(radius: 1)
    private static var skies: [Bool: EnvironmentResource] = [:]

    static func sky(dark: Bool) -> EnvironmentResource? {
        if let cached = skies[dark] { return cached }
        guard let context = CGContext(data: nil, width: 1024, height: 512, bitsPerComponent: 8,
            bytesPerRow: 4096, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let colors = (dark ? [0x091426, 0x223C58, 0x15273F] : [0xC1D2E9, 0xE7F1FB, 0xADC8E6])
            .map { NSColor(hex: UInt32($0)).cgColor }
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray,
                                        locations: [0, 0.5, 1]) else { return nil }
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: 512), options: [])
        if dark {
            for i in 0..<120 {
                let x = CGFloat((i * 137 + 59) % 1024)
                let y = CGFloat((i * 79 + 13) % 512)
                context.setFillColor(NSColor.white.withAlphaComponent(i % 3 == 0 ? 0.5 : 0.2).cgColor)
                context.fillEllipse(in: CGRect(x: x, y: y, width: 1.3, height: 1.3))
            }
        }
        guard let image = context.makeImage(), let resource = try? EnvironmentResource(equirectangular: image) else { return nil }
        skies[dark] = resource
        return resource
    }
    static func box(_ size: SIMD3<Float>, color: UInt32, at position: SIMD3<Float>, radius: Float = 0, unlit: Bool = false) -> ModelEntity {
        model(mesh: .generateBox(size: size, cornerRadius: radius), color: color, at: position, unlit: unlit)
    }
    static func sphere(scale: SIMD3<Float>, color: UInt32, at position: SIMD3<Float>, unlit: Bool = false) -> ModelEntity {
        let entity = model(mesh: unitSphere, color: color, at: position, unlit: unlit)
        entity.scale = scale
        return entity
    }
    static func cylinder(radius: Float, height: Float, color: UInt32, at position: SIMD3<Float>, unlit: Bool = false) -> ModelEntity {
        model(mesh: .generateCylinder(height: height, radius: radius), color: color, at: position, unlit: unlit)
    }
    private static func model(mesh: MeshResource, color: UInt32, at position: SIMD3<Float>, unlit: Bool) -> ModelEntity {
        let materials: [any RealityKit.Material] = unlit ? [UnlitMaterial(color: NSColor(hex: color), applyPostProcessToneMap: false)] : [SimpleMaterial(color: NSColor(hex: color), roughness: 0.88, isMetallic: false)]
        let entity = ModelEntity(mesh: mesh, materials: materials)
        entity.position = position
        return entity
    }
    static func rock() -> ModelEntity {
        var points: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        var faces: [UInt32] = []
        func triangle(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ material: UInt32) {
            let normal = simd_normalize(simd_cross(b - a, c - a))
            let start = UInt32(points.count)
            points += [a, b, c]; normals += [normal, normal, normal]
            indices += [start, start + 1, start + 2]; faces.append(material)
        }
        let count = 9
        for i in 0..<count {
            let a = Float(i) * 2 * .pi / Float(count)
            let b = Float(i + 1) * 2 * .pi / Float(count)
            let topA = SIMD3<Float>(cos(a) * 1.23, -0.08, sin(a) * 1.23)
            let topB = SIMD3<Float>(cos(b) * 1.23, -0.08, sin(b) * 1.23)
            let midA = SIMD3<Float>(cos(a + 0.15) * 0.93, -0.63 - Float(i % 3) * 0.11, sin(a + 0.15) * 0.93)
            let midB = SIMD3<Float>(cos(b + 0.15) * 0.93, -0.63 - Float((i + 1) % 3) * 0.11, sin(b + 0.15) * 0.93)
            triangle(topA, topB, midA, UInt32(i % 3))
            triangle(topB, midB, midA, UInt32((i + 1) % 3))
            triangle(midA, midB, [0.15, -1.45, -0.09], UInt32((i + 2) % 3))
        }
        var mesh = MeshDescriptor(name: "Floating rock")
        mesh.positions = MeshBuffers.Positions(points)
        mesh.normals = MeshBuffers.Normals(normals)
        mesh.primitives = .triangles(indices)
        mesh.materials = .perFace(faces)
        let resource = (try? MeshResource.generate(from: [mesh])) ?? .generateBox(size: 1)
        return ModelEntity(mesh: resource, materials: [0x526B83, 0x405770, 0x718797].map { SimpleMaterial(color: NSColor(hex: UInt32($0)), roughness: 1, isMetallic: false) })
    }
    static func bridge(to end: SIMD3<Float>) -> Entity {
        let bridge = Entity()
        let start = simd_normalize(SIMD3<Float>(end.x, 0, end.z)) * 1.03
        let finish = end * 0.77
        let distance = simd_length(finish - start)
        let count = max(3, Int(distance / 0.11))
        for i in 0..<count {
            let f = Float(i) / Float(max(1, count - 1))
            let p = simd_mix(start, finish, SIMD3(repeating: f)) + [0, 0.09 - sin(f * .pi) * 0.08, 0]
            let plank = box([0.31, 0.035, 0.085], color: 0xC4AA7D, at: p, radius: 0.008)
            plank.orientation = simd_quatf(angle: atan2(end.x, end.z), axis: [0, 1, 0])
            bridge.addChild(plank)
        }
        return bridge
    }
}
