// Generates the app icon set: three ascending token bars in the model-family
// palette on a deep indigo squircle. Usage: swift Scripts/MakeIcon.swift <out.iconset>
import AppKit

func color(_ hex: UInt32) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: 1
    )
}

func draw(size s: CGFloat) {
    let inset = s * 0.085 // margin so the squircle sits on the macOS icon grid
    let box = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let radius = box.width * 0.225
    let squircle = NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius)
    NSGradient(colors: [color(0x2A2358), color(0x161129)])!
        .draw(in: squircle, angle: -90)

    // Faint baseline the bars grow from.
    let baselineY = box.minY + box.height * 0.22
    let baseline = NSBezierPath()
    baseline.move(to: NSPoint(x: box.minX + box.width * 0.18, y: baselineY))
    baseline.line(to: NSPoint(x: box.maxX - box.width * 0.18, y: baselineY))
    baseline.lineWidth = max(1, s * 0.012)
    color(0x4B4573).withAlphaComponent(0.9).setStroke()
    baseline.stroke()

    // Ascending bars: sonnet aqua, opus blue, fable violet (dark-surface palette).
    let bars: [(UInt32, CGFloat)] = [(0x199E70, 0.26), (0x3987E5, 0.42), (0x9085E9, 0.60)]
    let barWidth = box.width * 0.155
    let gap = box.width * 0.075
    let totalWidth = barWidth * 3 + gap * 2
    var x = box.midX - totalWidth / 2
    for (hex, height) in bars {
        let rect = NSRect(x: x, y: baselineY, width: barWidth, height: box.height * height)
        let bar = NSBezierPath()
        let r = barWidth * 0.32
        // Rounded top, square base.
        bar.move(to: NSPoint(x: rect.minX, y: rect.minY))
        bar.line(to: NSPoint(x: rect.minX, y: rect.maxY - r))
        bar.appendArc(
            withCenter: NSPoint(x: rect.minX + r, y: rect.maxY - r),
            radius: r, startAngle: 180, endAngle: 90, clockwise: true
        )
        bar.line(to: NSPoint(x: rect.maxX - r, y: rect.maxY))
        bar.appendArc(
            withCenter: NSPoint(x: rect.maxX - r, y: rect.maxY - r),
            radius: r, startAngle: 90, endAngle: 0, clockwise: true
        )
        bar.line(to: NSPoint(x: rect.maxX, y: rect.minY))
        bar.close()
        color(hex).setFill()
        bar.fill()
        x += barWidth + gap
    }
}

func renderPNG(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(size: CGFloat(pixels))
    NSGraphicsContext.current?.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

guard CommandLine.arguments.count > 1 else {
    FileHandle.standardError.write(Data("usage: MakeIcon.swift <out.iconset>\n".utf8))
    exit(2)
}
let outDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    try renderPNG(pixels: base)
        .write(to: outDir.appendingPathComponent("icon_\(base)x\(base).png"))
    try renderPNG(pixels: base * 2)
        .write(to: outDir.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
print("wrote iconset to \(outDir.path)")
