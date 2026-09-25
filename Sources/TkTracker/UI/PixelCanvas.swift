import CoreGraphics
import Foundation
import simd

/// One pixel-art colour. Stored straight (not premultiplied) while drawing.
struct PixelColor: Hashable, Sendable {
    var r: UInt8, g: UInt8, b: UInt8, a: UInt8

    init(_ hex: UInt32, alpha: UInt8 = 255) {
        r = UInt8((hex >> 16) & 0xFF); g = UInt8((hex >> 8) & 0xFF); b = UInt8(hex & 0xFF); a = alpha
    }
    init(r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255) { self.r = r; self.g = g; self.b = b; self.a = a }

    static let clear = PixelColor(0, alpha: 0)

    func alpha(_ value: UInt8) -> PixelColor { var c = self; c.a = value; return c }
    func mixed(with other: PixelColor, _ t: Double) -> PixelColor {
        func m(_ x: UInt8, _ y: UInt8) -> UInt8 { UInt8(max(0, min(255, (Double(x) * (1 - t) + Double(y) * t).rounded()))) }
        return PixelColor(r: m(r, other.r), g: m(g, other.g), b: m(b, other.b), a: a)
    }
    /// Per-channel multiply; used to pre-compensate colours for the night overlay.
    func divided(by f: SIMD3<Double>) -> PixelColor {
        func d(_ x: UInt8, _ k: Double) -> UInt8 { UInt8(max(0, min(255, (Double(x) / k).rounded()))) }
        return PixelColor(r: d(r, f.x), g: d(g, f.y), b: d(b, f.z), a: a)
    }
}

/// A material's light-to-dark steps. Shadows lean violet and highlights warm,
/// rather than only going darker or lighter.
struct PixelRamp: Hashable, Sendable {
    var light: PixelColor, base: PixelColor, shade: PixelColor, deep: PixelColor
    init(_ light: UInt32, _ base: UInt32, _ shade: UInt32, _ deep: UInt32) {
        self.light = PixelColor(light); self.base = PixelColor(base); self.shade = PixelColor(shade); self.deep = PixelColor(deep)
    }
}

/// 2:1 isometric projection: a tile is 32×16 art pixels. +i runs to the lower
/// right, +j to the lower left, k is height in pixels.
struct Iso {
    var ox: Double
    var oy: Double
    static let tileW: Double = 32, tileH: Double = 16
    func p(_ i: Double, _ j: Double, _ k: Double = 0) -> SIMD2<Double> { [ox + (i - j) * 16, oy + (i + j) * 8 - k] }
    /// Inverse at floor level.
    func tile(at point: SIMD2<Double>) -> SIMD2<Double> {
        let a = (point.x - ox) / 16, b = (point.y - oy) / 8
        return [(a + b) / 2, (b - a) / 2]
    }
}

/// A small software canvas. Polygons are scanline-filled without anti-aliasing,
/// so shared edges round identically and nothing blurs when scaled up.
struct PixelCanvas {
    let width: Int
    let height: Int
    private(set) var pixels: [PixelColor]

    init(width: Int, height: Int) {
        self.width = max(1, width); self.height = max(1, height)
        pixels = Array(repeating: .clear, count: self.width * self.height)
    }

    subscript(x: Int, y: Int) -> PixelColor {
        guard x >= 0, y >= 0, x < width, y < height else { return .clear }
        return pixels[y * width + x]
    }

    mutating func plot(_ x: Int, _ y: Int, _ c: PixelColor) {
        guard x >= 0, y >= 0, x < width, y < height, c.a > 0 else { return }
        let index = y * width + x
        if c.a == 255 { pixels[index] = c; return }
        let d = pixels[index]
        let sa = Double(c.a) / 255, da = Double(d.a) / 255
        let oa = sa + da * (1 - sa)
        guard oa > 0 else { return }
        func ch(_ s: UInt8, _ t: UInt8) -> UInt8 { UInt8(max(0, min(255, ((Double(s) * sa + Double(t) * da * (1 - sa)) / oa).rounded()))) }
        pixels[index] = PixelColor(r: ch(c.r, d.r), g: ch(c.g, d.g), b: ch(c.b, d.b), a: UInt8((oa * 255).rounded()))
    }

    mutating func rect(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ c: PixelColor) {
        guard w > 0, h > 0 else { return }
        for yy in y..<(y + h) { for xx in x..<(x + w) { plot(xx, yy, c) } }
    }

    mutating func poly(_ pts: [SIMD2<Double>], _ c: PixelColor) {
        guard pts.count >= 3 else { return }
        let minY = Int(pts.map(\.y).min()!.rounded(.down)), maxY = Int(pts.map(\.y).max()!.rounded(.up))
        for y in minY..<maxY {
            let yc = Double(y) + 0.5
            var xs: [Double] = []
            for n in 0..<pts.count {
                let a = pts[n], b = pts[(n + 1) % pts.count]
                if (a.y <= yc && b.y > yc) || (b.y <= yc && a.y > yc) { xs.append(a.x + (yc - a.y) * (b.x - a.x) / (b.y - a.y)) }
            }
            xs.sort()
            var k = 0
            while k + 1 < xs.count {
                let x0 = Int(xs[k].rounded()), x1 = Int(xs[k + 1].rounded())
                if x1 > x0 { for x in x0..<x1 { plot(x, y, c) } }
                k += 2
            }
        }
    }

    /// Pixel grid where each character names a palette entry and "." is empty.
    mutating func grid(_ rows: [String], x: Int, y: Int, _ palette: [Character: PixelColor], mirrored: Bool = false) {
        for (r, row) in rows.enumerated() {
            let chars = Array(row)
            for (q, ch) in chars.enumerated() where ch != "." {
                guard let c = palette[ch] else { continue }
                plot(x + (mirrored ? chars.count - 1 - q : q), y + r, c)
            }
        }
    }

    mutating func draw(_ other: PixelCanvas, x: Int, y: Int, mirrored: Bool = false) {
        for yy in 0..<other.height {
            for xx in 0..<other.width {
                let c = other[xx, yy]
                if c.a > 0 { plot(x + (mirrored ? other.width - 1 - xx : xx), y + yy, c) }
            }
        }
    }

    /// Selective outline: every empty pixel touching the sprite takes a dark,
    /// violet-leaning version of its neighbour's colour.
    mutating func outline(strength: Double = 0.62) {
        let ink = PixelColor(0x1C1030)
        var result = pixels
        for y in 0..<height {
            for x in 0..<width where self[x, y].a == 0 {
                let neighbours = [self[x - 1, y], self[x + 1, y], self[x, y - 1], self[x, y + 1]].filter { $0.a == 255 }
                if let n = neighbours.first { result[y * width + x] = n.mixed(with: ink, strength) }
            }
        }
        pixels = result
    }

    /// Shear columns vertically: y += x * slope. Turns a lying figure into one
    /// lying along an isometric axis.
    func sheared(slope: Double) -> PixelCanvas {
        let extra = Int((Double(width) * abs(slope)).rounded(.up))
        var out = PixelCanvas(width: width, height: height + extra)
        for x in 0..<width {
            let dy = Int((Double(x) * slope).rounded()) + (slope < 0 ? extra : 0)
            for y in 0..<height { out.plot(x, y + dy, self[x, y]) }
        }
        return out
    }

    func cgImage() -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for (n, c) in pixels.enumerated() {
            let a = Double(c.a) / 255
            bytes[n * 4] = UInt8((Double(c.r) * a).rounded())
            bytes[n * 4 + 1] = UInt8((Double(c.g) * a).rounded())
            bytes[n * 4 + 2] = UInt8((Double(c.b) * a).rounded())
            bytes[n * 4 + 3] = c.a
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
}

// MARK: - Isometric shapes

extension PixelCanvas {
    /// A box with a lit top, a mid left face (+j) and a shaded right face (+i).
    mutating func box(_ iso: Iso, i: Double, j: Double, k: Double, w: Double, d: Double, h: Double,
                      top: PixelColor, left: PixelColor, right: PixelColor) {
        let p = iso.p
        poly([p(i, j + d, k + h), p(i + w, j + d, k + h), p(i + w, j + d, k), p(i, j + d, k)], left)
        poly([p(i + w, j, k + h), p(i + w, j + d, k + h), p(i + w, j + d, k), p(i + w, j, k)], right)
        poly([p(i, j, k + h), p(i + w, j, k + h), p(i + w, j + d, k + h), p(i, j + d, k + h)], top)
    }
    mutating func box(_ iso: Iso, i: Double, j: Double, k: Double, w: Double, d: Double, h: Double, ramp: PixelRamp) {
        box(iso, i: i, j: j, k: k, w: w, d: d, h: h, top: ramp.light, left: ramp.base, right: ramp.shade)
    }
    mutating func flat(_ iso: Iso, i: Double, j: Double, w: Double, d: Double, k: Double = 0, _ c: PixelColor) {
        poly([iso.p(i, j, k), iso.p(i + w, j, k), iso.p(i + w, j + d, k), iso.p(i, j + d, k)], c)
    }
    /// A patch on a face that looks toward +j (plane j), spanning i and height.
    mutating func faceJ(_ iso: Iso, i0: Double, i1: Double, j: Double, k0: Double, k1: Double, _ c: PixelColor) {
        poly([iso.p(i0, j, k1), iso.p(i1, j, k1), iso.p(i1, j, k0), iso.p(i0, j, k0)], c)
    }
    /// A patch on a face that looks toward +i (plane i), spanning j and height.
    mutating func faceI(_ iso: Iso, i: Double, j0: Double, j1: Double, k0: Double, k1: Double, _ c: PixelColor) {
        poly([iso.p(i, j0, k1), iso.p(i, j1, k1), iso.p(i, j1, k0), iso.p(i, j0, k0)], c)
    }
    /// A flat oval shadow where something stands on the ground.
    mutating func groundShadow(cx: Double, cy: Double, rx: Double, ry: Double, alpha: UInt8 = 64) {
        for y in Int(cy - ry)...Int(cy + ry) {
            for x in Int(cx - rx)...Int(cx + rx) where pow((Double(x) + 0.5 - cx) / rx, 2) + pow((Double(y) + 0.5 - cy) / ry, 2) <= 1 {
                plot(x, y, PixelColor(0x1C1030, alpha: alpha))
            }
        }
    }
    /// A soft contact shadow under furniture.
    mutating func shadow(_ iso: Iso, i: Double, j: Double, w: Double, d: Double) {
        flat(iso, i: i - 0.06, j: j - 0.02, w: w + 0.16, d: d + 0.16, PixelColor(0x1C1030, alpha: 60))
    }
}

// MARK: - 3×5 pixel font for signage

enum PixelFont {
    private static let glyphs: [Character: String] = [
        "A": ".x.x.xxxxx.xx.x", "B": "xx.x.xxx.x.xxx.", "C": ".xxx..x..x...xx", "D": "xx.x.xx.xx.xxx.", "E": "xxxx..xx.x..xxx",
        "F": "xxxx..xx.x..x..", "G": ".xxx..x.xx.x.xx", "H": "x.xx.xxxxx.xx.x", "I": "xxx.x..x..x.xxx", "J": "..x..x..xx.x.x.",
        "K": "x.xxx.x..xx.x.x", "L": "x..x..x..x..xxx", "M": "x.xxxxxxxx.xx.x", "N": "xx.x.xx.xx.xx.x", "O": ".x.x.xx.xx.x.x.",
        "P": "xx.x.xxx.x..x..", "Q": ".x.x.xx.xxx..xx", "R": "xx.x.xxx.x.xx.x", "S": ".xxx...x...xxx.", "T": "xxx.x..x..x..x.",
        "U": "x.xx.xx.xx.xxxx", "V": "x.xx.xx.xx.x.x.", "W": "x.xx.xxxxxxxx.x", "X": "x.xx.x.x.x.xx.x", "Y": "x.xx.x.x..x..x.",
        "Z": "xxx..x.x.x..xxx", "0": "xxxx.xx.xx.xxxx", "1": ".x.xx..x..x.xxx", "2": "xx...x.x.x..xxx", "3": "xx...x.x...xxx.",
        "4": "x.xx.xxxx..x..x", "5": "xxxx..xx...xxx.", "6": ".xxx..xxxx.xxxx", "7": "xxx..x.x..x..x.", "8": "xxxx.xxxxx.xxxx",
        "9": "xxxx.xxxx..xxx.", "-": "......xxx......", "+": "....x.xxx.x....", ".": ".............x.", "_": "............xxx",
        "!": ".x..x..x.....x.", "?": "xx...x.x.....x.", "·": ".......x.......", " ": "...............",
    ]

    static func sanitized(_ text: String, limit: Int = 16) -> String {
        let upper = text.uppercased().map { glyphs[$0] == nil ? " " : $0 }
        let trimmed = String(upper).trimmingCharacters(in: .whitespaces)
        return trimmed.count > limit ? String(trimmed.prefix(limit - 1)) + "." : trimmed
    }
    static func width(_ text: String) -> Int { max(0, text.count * 4 - 1) }

    static func draw(_ text: String, into canvas: inout PixelCanvas, x: Int, y: Int, color: PixelColor) {
        var cx = x
        for ch in text {
            if let g = glyphs[ch] { for (n, bit) in g.enumerated() where bit == "x" { canvas.plot(cx + n % 3, y + n / 3, color) } }
            cx += 4
        }
    }
}
