import SwiftUI
import SpriteKit
import Metal
import ImageIO
import QuartzCore

/// SpriteKit in a native view. Navigation and details stay in SwiftUI.
struct PixelWorkshop: NSViewRepresentable {
    var projects: [WorkshopProject]
    var selectedID: String?
    var zoomStep: Int
    var cameraReset: Int
    var presentationID: String
    var reducedMotion: Bool
    var dark: Bool
    var tokens: [String: Int]
    var onSelect: (String) -> Void

    func makeNSView(context: Context) -> PixelWorkshopView { PixelWorkshopView() }
    func updateNSView(_ view: PixelWorkshopView, context: Context) {
        view.workshop.onSelect = onSelect
        view.apply(PixelWorkshopScene.Model(projects: projects, selectedID: selectedID, dark: dark, reducedMotion: reducedMotion,
                                            tokens: tokens, presentationID: presentationID, zoomStep: zoomStep, cameraReset: cameraReset))
    }
    static func dismantleNSView(_ view: PixelWorkshopView, coordinator: ()) { view.stop() }
}

@MainActor
final class PixelWorkshopView: SKView {
    let workshop = PixelWorkshopScene(size: CGSize(width: 800, height: 600))
    private var occlusion: NSObjectProtocol?

    init() {
        super.init(frame: .zero)
        ignoresSiblingOrder = true
        preferredFramesPerSecond = 30
        shouldCullNonVisibleNodes = true
        presentScene(workshop)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }

    private var visible: Bool { window?.occlusionState.contains(.visible) == true && !isHidden }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusion { NotificationCenter.default.removeObserver(occlusion) }
        occlusion = nil
        guard let window else { return }
        workshop.backingScale = window.backingScaleFactor
        occlusion = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isPaused = !(self?.visible ?? false) }
        }
        isPaused = !visible
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        workshop.backingScale = window?.backingScaleFactor ?? 2
    }

    func apply(_ model: PixelWorkshopScene.Model) {
        // A background window still gets a complete frame; only a visible one animates.
        workshop.apply(model, animate: visible)
    }

    func stop() {
        if let occlusion { NotificationCenter.default.removeObserver(occlusion) }
        occlusion = nil
        isPaused = true
        presentScene(nil)
    }
}

/// Pixel portraits for SwiftUI: the same Sim as in the scene.
@MainActor
enum PixelPortraits {
    private static var cache: [String: CGImage] = [:]
    static func image(for agentID: String) -> CGImage {
        let look = WorkshopLook(agentID: agentID)
        if let cached = cache[look.key] { return cached }
        let image = PixelSims.portrait(look: look).cgImage()
        cache[look.key] = image
        return image
    }
}

/// The scene's plumbobs, for the legend: the same pixels, not a redrawn symbol.
@MainActor
enum PixelLegend {
    private static var cache: [WorkshopState: CGImage] = [:]
    static func plumbob(_ state: WorkshopState) -> CGImage {
        if let cached = cache[state] { return cached }
        let image = PixelSims.plumbob(state, frame: 0).cgImage()
        cache[state] = image
        return image
    }
}

struct WorkshopPortrait: View {
    var agent: WorkshopAgent
    var size: CGFloat
    var ring = true

    var body: some View {
        Image(decorative: PixelPortraits.image(for: agent.id), scale: 1)
            .interpolation(.none)
            .resizable()
            .frame(width: size, height: size)
            .background(Color(nsColor: NSColor(hex: 0x1C2442)))
            .clipShape(RoundedRectangle(cornerRadius: size * 0.14, style: .continuous))
            .overlay {
                if ring {
                    RoundedRectangle(cornerRadius: size * 0.14, style: .continuous)
                        .strokeBorder(agent.state.tint, lineWidth: max(1.5, size / 14))
                }
            }
            .opacity(agent.state == .unavailable ? 0.55 : 1)
    }
}

#if DEBUG
/// Renders the scene offscreen with Metal, for checking the art without a
/// window or screen-recording permission:
///   swift run TkTracker --workshops-snapshot out.png [--light] [--follow] [--island N] [--step N] [--width W --height H] [--zoom STEP] [--from N] [--crowd N]
enum PixelWorkshopSnapshot {
    static func run(arguments: [String]) -> Int32 {
        guard let path = arguments.first else {
            print("usage: --workshops-snapshot out.png [--light] [--follow] [--step N] [--width W] [--height H] [--scale S] [--time T]")
            return 2
        }
        func value(_ flag: String) -> Double? { arguments.firstIndex(of: flag).flatMap { Double(arguments[safe: $0 + 1] ?? "") } }
        let dark = !arguments.contains("--light")
        let follow = arguments.contains("--follow")
        let step = Int(value("--step") ?? 0)
        let size = CGSize(width: value("--width") ?? 900, height: value("--height") ?? 620)
        let scale = CGFloat(value("--scale") ?? 2)
        let seconds = value("--time") ?? 1.0
        return MainActor.assumeIsolated {
            var agents = WorkshopDemo.agents(step: step, now: Date())
            // --crowd N: give the TrailForge lead N more subagents, to check large teams.
            if let crowd = value("--crowd"), let lead = agents.first(where: { $0.sessionID == "api" }) {
                for n in 0..<Int(crowd) {
                    var extra = lead
                    extra.id = WorkshopAgent.key(profile: "demo", source: lead.source, session: "crowd-\(n)")
                    extra.sessionID = "crowd-\(n)"; extra.parentSessionID = "api"; extra.title = "Helper \(n + 1)"
                    extra.state = [.working, .usingTool, .completed, .idle][n % 4]
                    agents.append(extra)
                }
            }
            var projects = WorkshopProject.group(WorkshopIsland.group(agents))
            if follow {
                let index = min(projects.count - 1, Int(value("--island") ?? 0))
                projects = [projects[index]]
            }
            let model = PixelWorkshopScene.Model(projects: projects, selectedID: projects.first?.lead.id, dark: dark, reducedMotion: false,
                                                 tokens: WorkshopDemo.tokens(for: agents), presentationID: follow ? "follow" : "overview",
                                                 zoomStep: Int(value("--zoom") ?? 0))
            // --from N: settle on step N first, then animate into --step, like a live update.
            var previous: PixelWorkshopScene.Model?
            if let from = value("--from") {
                let earlier = WorkshopDemo.agents(step: Int(from), now: Date())
                var before = WorkshopProject.group(WorkshopIsland.group(earlier))
                if follow { before = before.filter { $0.id == projects.first?.id } }
                previous = PixelWorkshopScene.Model(projects: before, selectedID: model.selectedID, dark: dark, reducedMotion: false,
                                                    tokens: WorkshopDemo.tokens(for: earlier), presentationID: model.presentationID, zoomStep: model.zoomStep)
            }
            guard let image = render(model: model, previous: previous, size: size, scale: scale, seconds: seconds) else { print("render failed"); return 1 }
            let url = URL(fileURLWithPath: path)
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return 1 }
            CGImageDestinationAddImage(destination, image, nil)
            return CGImageDestinationFinalize(destination) ? 0 : 1
        }
    }

    @MainActor
    static func render(model: PixelWorkshopScene.Model, previous: PixelWorkshopScene.Model? = nil, size: CGSize, scale: CGFloat, seconds: Double) -> CGImage? {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        let scene = PixelWorkshopScene(size: size)
        // Without a view, .resizeFill shrinks the scene to nothing.
        scene.scaleMode = .fill
        scene.backingScale = scale
        let renderer = SKRenderer(device: device)
        renderer.scene = scene
        let width = Int(size.width * scale), height = Int(size.height * scale)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        // SKRenderer doesn't paint the scene's background colour; clear to it.
        let background = scene.backgroundColor.usingColorSpace(.sRGB) ?? .black
        pass.colorAttachments[0].clearColor = MTLClearColor(red: Double(background.redComponent), green: Double(background.greenComponent),
                                                            blue: Double(background.blueComponent), alpha: 1)
        // SKRenderer only advances the scene when a frame is rendered, so draw every step.
        var t = 0.0
        let start = CACurrentMediaTime()
        func step() {
            // Times must continue from the media clock SKRenderer starts on, or it stops advancing.
            renderer.update(atTime: start + t)
            if let buffer = queue.makeCommandBuffer() {
                renderer.render(withViewport: CGRect(x: 0, y: 0, width: width, height: height), commandBuffer: buffer, renderPassDescriptor: pass)
                buffer.commit(); buffer.waitUntilCompleted()
            }
            t += 1.0 / 30
        }
        if let previous {
            scene.apply(previous, animate: false)
            for _ in 0..<10 { step() }
            scene.apply(model, animate: true)
        } else {
            scene.apply(model, animate: false)
        }
        let end = t + seconds
        while t <= end { step() }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
#endif
