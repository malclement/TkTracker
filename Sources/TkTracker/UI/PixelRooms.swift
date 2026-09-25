import Foundation
import simd

/// A drawn piece plus the canvas pixel that sits on its world anchor point
/// (the floor-level top corner of its footprint, or its feet).
struct PixelPiece {
    var canvas: PixelCanvas
    var origin: SIMD2<Double>
}

/// Furniture, rooms and the neighbourhood around them, all drawn in code.
enum PixelRooms {
    // MARK: Palette

    static let wood = PixelRamp(0xF2C18D, 0xD99A5F, 0xA8683F, 0x6E3F2C)
    static let darkWood = PixelRamp(0xC08A5A, 0x8D5B34, 0x633B27, 0x3D2320)
    static let monitor = PixelRamp(0x6A7494, 0x3D4560, 0x2A2F47, 0x1A1D30)
    static let metal = PixelRamp(0xC4C8D8, 0x8A92AE, 0x5A6280, 0x3E4460)
    static let pot = PixelRamp(0xF0A070, 0xC0673F, 0x8A4430, 0x5A2A24)
    static let leaf = PixelRamp(0x9BE68A, 0x4FB05A, 0x2F7A4A, 0x1D4A3A)
    static let chairRamp = PixelRamp(0x9A86C8, 0x6A5690, 0x4B3A6B, 0x2D2440)
    static let couches = [PixelRamp(0xFFB09A, 0xE8735A, 0xB8503F, 0x7A3030), PixelRamp(0x8FE0D8, 0x3FA8A0, 0x2A7470, 0x1A4A4A),
                          PixelRamp(0xFFE08A, 0xE0A840, 0xA87428, 0x6E4A1E)]
    static let screenOn = PixelColor(0x5FE3BF), screenLine = PixelColor(0xDFFFF4), screenOff = PixelColor(0x243240)
    static let grass = PixelRamp(0xA6E07A, 0x7CC860, 0x5AA852, 0x3E8048)
    static let wallpapers: [(base: UInt32, stripe: UInt32)] = [
        (0xF4E4CC, 0xEBCFB4), (0xF8DCC6, 0xF0C4A6), (0xEEE8CC, 0xDED4AC), // warm: Claude Code
        (0xDDE8F6, 0xC8D8EE), (0xDCEFE6, 0xC4E2D4), (0xE6E0F4, 0xD4CCEC), // cool: Codex
    ]
    /// Two tones and a joint colour; wood is laid as planks, the rest as tiles.
    static let floors: [(PixelColor, PixelColor, PixelColor, planks: Bool)] = [
        (PixelColor(0xE6B47C), PixelColor(0xDAA46A), PixelColor(0xBE8A56), true), (PixelColor(0xF2EADA), PixelColor(0xD8CEBC), PixelColor(0xC4B8A4), false),
        (PixelColor(0x8296D2), PixelColor(0x788CC8), PixelColor(0x6A7CB8), false), (PixelColor(0xB67E52), PixelColor(0xA87248), PixelColor(0x8E5E3C), true),
    ]
    static let rugs: [(PixelColor, PixelColor)] = [
        (PixelColor(0xD8768E), PixelColor(0xB4546E)), (PixelColor(0x62A8C2), PixelColor(0x3F7F9A)),
        (PixelColor(0xEAC468), PixelColor(0xC49C44)), (PixelColor(0xA28CD6), PixelColor(0x7C68B4)),
    ]
    static let bookColors: [PixelColor] = ([0xE8645A, 0x4FA3E0, 0xF0B43C, 0x9B6EE0, 0x3FBF9A, 0xF6EFE0, 0xF08AA8] as [UInt32]).map { PixelColor($0) }

    /// A canvas sized for a footprint w×d up to `height` pixels tall, with the
    /// iso origin at the footprint's top corner.
    private static func canvas(w: Double, d: Double, height: Double, margin: Double = 3) -> (PixelCanvas, Iso) {
        let ox = d * 16 + margin, oy = height + margin
        let c = PixelCanvas(width: Int((ox + w * 16 + margin).rounded(.up)), height: Int((oy + (w + d) * 8 + margin).rounded(.up)))
        return (c, Iso(ox: ox, oy: oy))
    }

    // MARK: Furniture

    /// A desk, oriented so the monitor faces +j, or +i when `facesI`.
    static func desk(facesI: Bool, screen: Bool, frame: Int, sheets: Int, lamp: Bool) -> PixelPiece {
        let (lu, lv) = (2.0, 1.0)
        var (c, iso) = canvas(w: facesI ? lv : lu, d: facesI ? lu : lv, height: 30)
        // u runs along the desk, v toward its front (where the Sim sits).
        func box(_ u: Double, _ v: Double, _ k: Double, _ su: Double, _ sv: Double, _ h: Double, _ ramp: PixelRamp) {
            if facesI { c.box(iso, i: v, j: u, k: k, w: sv, d: su, h: h, ramp: ramp) }
            else { c.box(iso, i: u, j: v, k: k, w: su, d: sv, h: h, ramp: ramp) }
        }
        func front(_ u0: Double, _ u1: Double, _ v: Double, _ k0: Double, _ k1: Double, _ color: PixelColor) {
            if facesI { c.faceI(iso, i: v, j0: u0, j1: u1, k0: k0, k1: k1, color) }
            else { c.faceJ(iso, i0: u0, i1: u1, j: v, k0: k0, k1: k1, color) }
        }
        c.shadow(iso, i: 0.05, j: 0.05, w: facesI ? lv - 0.1 : lu - 0.1, d: facesI ? lu - 0.1 : lv - 0.1)
        box(0.05, 0.08, 0, 1.9, 0.86, 12, wood)
        front(0.4, 1.6, 0.94, 0, 9, darkWood.deep.mixed(with: wood.shade, 0.35))
        if sheets > 0 {
            box(0.14, 0.3, 12, 0.32, 0.34, Double(sheets), PixelRamp(0xFFFFFF, 0xFFFAF0, 0xE8E0D0, 0xC8C0B0))
            for s in stride(from: 1, to: sheets, by: 2) { front(0.14, 0.46, 0.64, 12 + Double(s), 12 + Double(s) + 1, PixelColor(0xDCD2C0)) }
        }
        box(0.62, 0.62, 12, 0.76, 0.2, 1, PixelRamp(0xF4F4F8, 0xDADCE6, 0xB4B8C8, 0x8A8EA0)) // keyboard
        box(0.92, 0.26, 12, 0.16, 0.14, 3, monitor)
        box(0.46, 0.2, 15, 1.08, 0.18, 13, monitor)
        front(0.53, 1.47, 0.38, 16.5, 26.5, screen ? screenOn : screenOff)
        if screen {
            for (n, k) in [24.5, 22.5, 20.5, 18.5].enumerated() {
                let length = 0.18 + Double((frame * 3 + n * 5) % 6) * 0.08
                let indent = n % 2 == 1 ? 0.1 : 0
                front(0.6 + indent, 0.6 + indent + length, 0.38, k, k + 1, screenLine)
            }
        } else {
            front(0.6, 0.8, 0.38, 24.5, 25.5, PixelColor(0x34465A)) // a glint on the dark glass
        }
        // Desk lamp: arm, and a shade that is lit while its owner works.
        box(1.68, 0.2, 12, 0.18, 0.16, 1, metal)
        box(1.74, 0.24, 13, 0.06, 0.06, 10, metal)
        box(1.6, 0.16, 22, 0.3, 0.26, 4, lamp ? PixelRamp(0xFFF6D0, 0xFFE9A8, 0xE8C070, 0xB08A40) : metal)
        return PixelPiece(canvas: c, origin: [iso.ox, iso.oy])
    }

    /// Office chair seen from behind; the Sim sits in front of it.
    static func chair() -> PixelPiece {
        // Low backrest, so the Sim's shirt and elbows show above it.
        var c = PixelCanvas(width: 22, height: 11)
        c.rect(7, 0, 8, 3, chairRamp.base); c.rect(7, 0, 8, 1, chairRamp.light); c.rect(13, 1, 2, 2, chairRamp.shade)
        c.rect(5, 3, 12, 2, chairRamp.shade); c.rect(5, 3, 12, 1, chairRamp.base)
        c.rect(10, 5, 2, 2, metal.shade)
        c.rect(6, 7, 10, 2, metal.base); c.rect(6, 7, 10, 1, metal.light)
        for x in [6, 10, 15] { c.plot(x, 9, PixelColor(0x2A2440)) }
        return PixelPiece(canvas: c, origin: [11, 10])
    }

    static func plant() -> PixelPiece {
        var (c, iso) = canvas(w: 1, d: 1, height: 34)
        c.shadow(iso, i: 0.2, j: 0.2, w: 0.6, d: 0.6)
        c.box(iso, i: 0.28, j: 0.28, k: 0, w: 0.44, d: 0.44, h: 9, ramp: pot)
        c.flat(iso, i: 0.32, j: 0.32, w: 0.36, d: 0.36, k: 9, PixelColor(0x5A3A2A))
        let top = iso.p(0.5, 0.5, 9)
        let leaves: [(Int, Int)] = [(0, -6), (-4, -9), (4, -9), (-2, -14), (3, -15), (-6, -14), (6, -13), (0, -19), (-3, -22), (3, -23), (0, -27)]
        for (n, (dx, dy)) in leaves.enumerated() {
            let x = Int(top.x) + dx - 2, y = Int(top.y) + dy
            c.rect(x, y, 5, 4, n % 3 == 2 ? leaf.shade : leaf.base)
            c.rect(x + 1, y - 1, 3, 1, leaf.base)
            c.rect(x, y, 2, 1, leaf.light)
            c.rect(x + 3, y + 3, 2, 1, leaf.deep)
        }
        return PixelPiece(canvas: c, origin: [iso.ox, iso.oy])
    }

    static func coffee() -> PixelPiece {
        var (c, iso) = canvas(w: 1, d: 1, height: 30)
        c.shadow(iso, i: 0.1, j: 0.1, w: 0.8, d: 0.8)
        c.box(iso, i: 0.1, j: 0.15, k: 0, w: 0.8, d: 0.7, h: 11, ramp: darkWood)
        c.box(iso, i: 0.2, j: 0.22, k: 11, w: 0.56, d: 0.5, h: 16, ramp: metal)
        c.faceJ(iso, i0: 0.32, i1: 0.64, j: 0.72, k0: 13, k1: 19, PixelColor(0x2A2F47))
        c.box(iso, i: 0.42, j: 0.5, k: 13, w: 0.14, d: 0.14, h: 3, ramp: PixelRamp(0xFFFFFF, 0xF4EEE4, 0xD8D0C4, 0xA89C90))
        c.faceJ(iso, i0: 0.62, i1: 0.7, j: 0.72, k0: 23, k1: 25, PixelColor(0xFF5A4A))
        return PixelPiece(canvas: c, origin: [iso.ox, iso.oy])
    }

    static func couch(_ variant: Int) -> PixelPiece {
        let ramp = couches[variant % couches.count]
        var (c, iso) = canvas(w: 3, d: 1, height: 20)
        c.shadow(iso, i: 0, j: 0.05, w: 3, d: 0.95)
        c.box(iso, i: 0.05, j: 0.06, k: 0, w: 2.9, d: 0.26, h: 17, ramp: ramp)
        c.box(iso, i: 0.3, j: 0.3, k: 0, w: 2.4, d: 0.64, h: 7, ramp: ramp)
        for x in [1.1, 1.9] { c.flat(iso, i: x, j: 0.32, w: 0.05, d: 0.6, k: 7, ramp.shade) }
        c.box(iso, i: 0.02, j: 0.06, k: 0, w: 0.3, d: 0.9, h: 11, ramp: ramp)
        c.box(iso, i: 2.68, j: 0.06, k: 0, w: 0.3, d: 0.9, h: 11, ramp: ramp)
        return PixelPiece(canvas: c, origin: [iso.ox, iso.oy])
    }

    static func bookshelf() -> PixelPiece {
        var (c, iso) = canvas(w: 1, d: 1, height: 36)
        c.box(iso, i: 0, j: 0.05, k: 0, w: 0.45, d: 0.9, h: 32, top: darkWood.light, left: darkWood.base, right: darkWood.base)
        for shelf in 0..<3 {
            let k = 2.0 + Double(shelf) * 10
            c.faceI(iso, i: 0.45, j0: 0.1, j1: 0.9, k0: k - 1, k1: k, darkWood.deep)
            var j = 0.12
            var n = shelf * 3
            while j < 0.86 {
                let w = 0.09 + Double(n % 3) * 0.02
                c.faceI(iso, i: 0.45, j0: j, j1: min(0.88, j + w), k0: k, k1: k + 6 + Double(n % 2) * 1.5, bookColors[n % bookColors.count])
                j += w + 0.02; n += 1
            }
        }
        return PixelPiece(canvas: c, origin: [iso.ox, iso.oy])
    }

    // MARK: Room

    /// Floor, rug and back walls. Everything in the room stands in front of this.
    static func shell(decor: WorkshopDecor, depth: Int, length: Int, backRight: Int, backLeft: Int) -> PixelPiece {
        let W = Double(depth), D = Double(length)
        let ox = D * 16 + 6, oy = Double(WorkshopLotPlan.fullWall) + 6
        var c = PixelCanvas(width: Int(ox + W * 16 + 8), height: Int(oy + (W + D) * 8 + 4))
        let iso = Iso(ox: ox, oy: oy)
        let floor = floors[decor.floor % floors.count]
        if floor.planks {
            // Planks run toward the street, three to a tile, with staggered joints.
            let strips = length * 3
            for s in 0..<strips {
                let j0 = Double(s) / 3
                var i0 = -Double((s * 5) % 3) * 0.66
                var n = 0
                while i0 < W {
                    let a = max(0, i0), b = min(W, i0 + 2.4)
                    let h = workshopHash("plank-\(s)-\(n)")
                    let tone = [floor.0, floor.1, floor.0.mixed(with: floor.1, 0.5)][Int(h % 3)]
                    c.flat(iso, i: a, j: j0, w: b - a, d: 1.0 / 3, tone)
                    if i0 > 0 { c.flat(iso, i: a, j: j0, w: 0.06, d: 1.0 / 3, floor.2) }
                    i0 += 2.4; n += 1
                }
                c.flat(iso, i: 0, j: j0, w: W, d: 0.04, floor.2)
            }
        } else {
            // Square tiles with a fine grout line.
            for i in 0..<depth {
                for j in 0..<length {
                    let a = (i + j) % 2 == 0 ? floor.0 : floor.0.mixed(with: floor.1, 0.6)
                    c.flat(iso, i: Double(i), j: Double(j), w: 1, d: 1, floor.2)
                    c.flat(iso, i: Double(i) + 0.05, j: Double(j) + 0.05, w: 0.92, d: 0.92, a)
                }
            }
        }
        // The lounge rug, in front of the couch.
        let rug = rugs[decor.rug % rugs.count]
        c.flat(iso, i: 3.0, j: 1.0, w: 2.9, d: 1.8, rug.1)
        c.flat(iso, i: 3.12, j: 1.12, w: 2.66, d: 1.56, rug.0)
        c.flat(iso, i: 3.4, j: 1.4, w: 2.1, d: 1.0, rug.0.mixed(with: PixelColor(0xFFFFFF), 0.18))
        // Contact shadow where floor meets wall.
        c.flat(iso, i: 0, j: 0, w: W, d: 0.14, PixelColor(0x1C1030, alpha: 50))
        c.flat(iso, i: 0, j: 0, w: 0.14, d: D, PixelColor(0x1C1030, alpha: 50))

        let paper = wallpapers[decor.wallpaper % wallpapers.count]
        let base = PixelColor(paper.base), stripe = PixelColor(paper.stripe)
        let shaded = base.mixed(with: PixelColor(0x6A5A9A), 0.14), shadedStripe = stripe.mixed(with: PixelColor(0x6A5A9A), 0.14)
        let cap = PixelColor(0xFFF6EA), board = PixelColor(0xB08A64)
        // Side wall (plane j = 0) behind the lounge, facing +j.
        let hr = Double(backRight), hl = Double(backLeft)
        c.box(iso, i: 0, j: -0.25, k: 0, w: W, d: 0.25, h: hr, top: cap, left: base, right: base.mixed(with: PixelColor(0x6A5A9A), 0.3))
        var s = 0.25
        while s < W - 0.1 { c.faceJ(iso, i0: s, i1: s + 0.12, j: 0, k0: 4, k1: hr - 2, stripe); s += 0.5 }
        c.faceJ(iso, i0: 0, i1: W, j: 0, k0: 0, k1: 3, board)
        // Back wall (plane i = 0) along the whole room, facing +i.
        c.box(iso, i: -0.25, j: -0.25, k: 0, w: 0.25, d: D + 0.25, h: hl, top: cap, left: shaded.mixed(with: PixelColor(0x6A5A9A), 0.3), right: shaded)
        s = 0.25
        while s < D - 0.1 { c.faceI(iso, i: 0, j0: s, j1: s + 0.12, k0: 4, k1: hl - 2, shadedStripe); s += 0.5 }
        c.faceI(iso, i: 0, j0: 0, j1: D, k0: 0, k1: 3, board.mixed(with: PixelColor(0x6A5A9A), 0.14))
        // A window above the couch, where the side wall stands full height.
        if backRight >= WorkshopLotPlan.fullWall { window(&c, iso, alongI: true, from: 3.8, to: 5.6, k0: 21, k1: 34) }
        if backLeft >= WorkshopLotPlan.fullWall {
            // The whiteboard a waiting lead studies when there is nobody to watch.
            c.faceI(iso, i: 0, j0: 0.9, j1: 2.7, k0: 14, k1: 30, PixelColor(0x8A92AE))
            c.faceI(iso, i: 0, j0: 0.98, j1: 2.62, k0: 15, k1: 29, PixelColor(0xFBFCFF))
            for (n, k) in [26.0, 23.5, 21.0, 18.5].enumerated() {
                let colour = [PixelColor(0x4FA3E0), PixelColor(0xE8645A), PixelColor(0x3FBF9A), PixelColor(0x9B6EE0)][n]
                c.faceI(iso, i: 0, j0: 1.15, j1: 1.15 + 0.5 + Double(n % 2) * 0.55, k0: k, k1: k + 1, colour)
            }
            c.faceI(iso, i: 0, j0: 1.0, j1: 2.6, k0: 13, k1: 14, PixelColor(0xB4B8C8)) // marker tray
            // Framed prints between the desks, above the monitors.
            var j = Double(WorkshopRoomTemplate.loungeLength) + 1.75
            var n = 0
            while j < D - 1.2 {
                let art = [PixelColor(0xF0B43C), PixelColor(0x62A8C2), PixelColor(0xD8768E)][n % 3]
                c.faceI(iso, i: 0, j0: j, j1: j + 0.5, k0: 30, k1: 37, PixelColor(0x6E3F2C))
                c.faceI(iso, i: 0, j0: j + 0.06, j1: j + 0.44, k0: 31, k1: 36, art)
                j += Double(WorkshopRoomTemplate.bayLength) * 2; n += 1
            }
        }
        return PixelPiece(canvas: c, origin: [ox, oy])
    }

    private static func window(_ c: inout PixelCanvas, _ iso: Iso, alongI: Bool, from a: Double, to b: Double, k0: Double, k1: Double) {
        let frame = PixelColor(0xFFF8EE), glass = PixelColor(0x9FD8FF), shine = PixelColor(0xD2F0FF)
        func patch(_ u0: Double, _ u1: Double, _ q0: Double, _ q1: Double, _ color: PixelColor) {
            if alongI { c.faceJ(iso, i0: u0, i1: u1, j: 0, k0: q0, k1: q1, color) } else { c.faceI(iso, i: 0, j0: u0, j1: u1, k0: q0, k1: q1, color) }
        }
        patch(a - 0.08, b + 0.08, k0 - 1.5, k1 + 1.5, frame)
        patch(a, b, k0, k1, glass)
        patch(a + 0.08, a + (b - a) * 0.4, k0 + 3, k1 - 1, shine)
        patch((a + b) / 2 - 0.05, (a + b) / 2 + 0.05, k0, k1, frame)
        patch(a, b, (k0 + k1) / 2 - 0.6, (k0 + k1) / 2 + 0.6, frame)
        patch(a - 0.14, b + 0.14, k0 - 3, k0 - 1.5, PixelColor(0xE6D8C4)) // sill
    }

    /// One tile of cut-away front wall. Split per tile so a Sim in the front
    /// row is hidden only by the segment actually in front of it.
    static func stub(alongI: Bool) -> PixelPiece {
        let siding = PixelRamp(0xFFF8EC, 0xF0E6D6, 0xD4C6B2, 0xA89A88)
        let h = 5.0
        var (c, iso) = canvas(w: alongI ? 1 : 0.25, d: alongI ? 0.25 : 1, height: h)
        c.box(iso, i: 0, j: 0, k: 0, w: alongI ? 1 : 0.25, d: alongI ? 0.25 : 1, h: h, top: siding.light, left: siding.base, right: siding.shade)
        return PixelPiece(canvas: c, origin: [iso.ox, iso.oy])
    }

    static func doormat() -> PixelPiece {
        var (c, iso) = canvas(w: 0.7, d: 1, height: 0)
        c.flat(iso, i: 0, j: 0.1, w: 0.6, d: 0.8, PixelColor(0x8A5A3C))
        c.flat(iso, i: 0.06, j: 0.16, w: 0.48, d: 0.68, PixelColor(0xB07A4E))
        return PixelPiece(canvas: c, origin: [iso.ox, iso.oy])
    }

    /// A wooden sign with the project name, planted in front of the room.
    static func nameplate(_ text: String) -> PixelPiece {
        let label = PixelFont.sanitized(text)
        let w = PixelFont.width(label) + 8
        var c = PixelCanvas(width: w + 2, height: 16)
        c.rect(w / 2, 10, 2, 6, darkWood.shade)
        c.rect(1, 0, w, 11, darkWood.deep)
        c.rect(2, 1, w - 2, 9, wood.base)
        c.rect(2, 1, w - 2, 1, wood.light)
        c.rect(2, 9, w - 2, 1, wood.shade)
        PixelFont.draw(label, into: &c, x: 5, y: 3, color: PixelColor(0x3A2616))
        return PixelPiece(canvas: c, origin: [Double(w / 2 + 1), 16])
    }

    /// "+2" plaque for subagents beyond the desks shown.
    static func overflow(_ count: Int) -> PixelPiece {
        let label = "+\(count)"
        let w = PixelFont.width(label) + 6
        var c = PixelCanvas(width: w, height: 9)
        c.rect(0, 0, w, 9, PixelColor(0x241D3D))
        PixelFont.draw(label, into: &c, x: 3, y: 2, color: PixelColor(0xF5E9C9))
        return PixelPiece(canvas: c, origin: [Double(w / 2), 9])
    }

    // MARK: Neighbourhood

    /// Meadow beyond the lot. `base` is also the scene's background colour.
    static let meadow = PixelRamp(0xA2D284, 0x88BF6A, 0x7BB262, 0x6AA35A)
    static let grassBase = meadow.base
    /// Mowed stripes on the lot itself, a touch brighter than the meadow.
    static let mowed = (PixelColor(0x96CB74), PixelColor(0x8CC46C))
    static let gravel = PixelRamp(0xEAE2D0, 0xDDD2BC, 0xC4B79E, 0xA69880)
    static let asphalt = PixelRamp(0x7A7E90, 0x5E6274, 0x4A4E60, 0x363A4A)
    static let pavement = PixelRamp(0xE8E2D4, 0xD4CCBA, 0xB8AE9C, 0x8E8676)
    private static let groundShadow = PixelColor(0x1C1030, alpha: 38)

    /// The ground around the lot: a mowed lawn under the rooms, meadow beyond
    /// it, and a street with sidewalks along the side the doors face.
    /// `field` is the whole drawn area; `lawn` the lot itself; the street runs
    /// along j at `streetI` (sidewalk, two lanes, sidewalk). `rooms` are the
    /// occupied room origins, which cast a shadow on the grass.
    static func ground(field: (WorkshopTile, WorkshopTile), lawn: (WorkshopTile, WorkshopTile), streetI: Int,
                       paths: Set<WorkshopTile>, rooms: [(origin: WorkshopTile, depth: Int, length: Int)], beds: [WorkshopTile], seed: UInt64) -> PixelPiece {
        let (lower, upper) = field
        let W = Double(upper.i - lower.i), D = Double(upper.j - lower.j)
        let ox = D * 16 + 2, oy = 2.0
        var c = PixelCanvas(width: Int(ox + W * 16 + 2), height: Int(oy + (W + D) * 8 + 2))
        let iso = Iso(ox: ox, oy: oy)
        func onLawn(_ i: Int, _ j: Int) -> Bool { i >= lawn.0.i && j >= lawn.0.j && i < lawn.1.i && j < lawn.1.j }
        for i in lower.i..<upper.i {
            for j in lower.j..<upper.j {
                let x = Double(i - lower.i), y = Double(j - lower.j)
                let street = i - streetI
                switch street {
                case 0, 3:
                    c.flat(iso, i: x, j: y, w: 1, d: 1, pavement.base)
                    c.flat(iso, i: x, j: y, w: 1, d: 0.06, pavement.shade)
                    c.flat(iso, i: street == 0 ? x + 0.92 : x, j: y, w: 0.08, d: 1, pavement.deep) // kerb
                case 1, 2:
                    c.flat(iso, i: x, j: y, w: 1, d: 1, j % 2 == 0 ? asphalt.base : asphalt.base.mixed(with: asphalt.shade, 0.25))
                    if street == 1 && j % 2 == 0 { c.flat(iso, i: x + 0.95, j: y + 0.2, w: 0.1, d: 0.6, PixelColor(0xF0D36A)) }
                default:
                    if onLawn(i, j) {
                        // Stripes run parallel to the street, like a mower's passes.
                        c.flat(iso, i: x, j: y, w: 1, d: 1, i % 2 == 0 ? mowed.0 : mowed.1)
                        continue
                    }
                    // Meadow: soft patches a few tiles across, fading to plain
                    // grass near the edge so the field meets the background.
                    let edge = min(x, y, W - x - 1, D - y - 1)
                    let weight = max(0, min(1, (edge - 1) / 4))
                    for (du, dv) in [(0.0, 0.0), (0.5, 0.0), (0.0, 0.5), (0.5, 0.5)] {
                        let n = 0.5 + (patchNoise(Double(i) + du, Double(j) + dv, seed: seed) - 0.5) * weight
                        let color = n < 0.36 ? meadow.base.mixed(with: meadow.shade, 0.55) : n > 0.66 ? meadow.base.mixed(with: meadow.light, 0.28) : meadow.base
                        c.flat(iso, i: x + du, j: y + dv, w: 0.5, d: 0.5, color)
                    }
                }
            }
        }
        // A crisp mown edge around the lot, on the sides that meet the meadow.
        let lx = Double(lawn.0.i - lower.i), ly = Double(lawn.0.j - lower.j)
        let lw = Double(lawn.1.i - lawn.0.i), ld = Double(lawn.1.j - lawn.0.j)
        c.flat(iso, i: lx, j: ly, w: lw, d: 0.06, meadow.deep)
        c.flat(iso, i: lx, j: ly, w: 0.06, d: ld, meadow.deep)
        c.flat(iso, i: lx, j: ly + ld - 0.06, w: lw, d: 0.06, meadow.deep)
        // Tufts and flowers, never on the street or the mowed lot.
        for n in 0..<Int(W * D * 1.1) {
            let h = workshopHash("\(seed)-tuft-\(n)")
            let fi = Double(h % 1000) / 1000 * W, fj = Double((h >> 12) % 1000) / 1000 * D
            let ti = Int(fi) + lower.i, tj = Int(fj) + lower.j
            let street = ti - streetI
            guard street < 0 || street > 3 else { continue }
            let p = iso.p(fi, fj)
            let flower = n % 9 == 0
            if onLawn(ti, tj) && !flower { continue }
            c.plot(Int(p.x), Int(p.y), flower ? [PixelColor(0xFFF1A8), PixelColor(0xFFB0C8), PixelColor(0xFFFFFF), PixelColor(0xC8B8FF)][n % 4] : meadow.deep)
            if !flower { c.plot(Int(p.x) + 1, Int(p.y) - 1, meadow.light) }
        }
        // Rooms cast a short shadow down and to the right of their footprint.
        for (room, depth, length) in rooms {
            let rw = Double(depth), rd = Double(length)
            let x = Double(room.i - lower.i), y = Double(room.j - lower.j)
            let (dx, dy) = (0.42, 0.3)
            c.poly([iso.p(x + rw, y + dy), iso.p(x + rw + dx, y + dy), iso.p(x + rw + dx, y + rd + dy),
                    iso.p(x + dx, y + rd + dy), iso.p(x + dx, y + rd), iso.p(x + rw, y + rd)], groundShadow)
        }
        // Flower beds in the gardens: soil edged in brick, dotted with blooms.
        for (n, bed) in beds.enumerated() {
            let x = Double(bed.i - lower.i), y = Double(bed.j - lower.j) + 0.3
            c.flat(iso, i: x, j: y, w: 3, d: 1.4, PixelColor(0xC98A62))
            c.flat(iso, i: x + 0.1, j: y + 0.1, w: 2.8, d: 1.2, PixelColor(0x8A5E40))
            c.flat(iso, i: x + 0.18, j: y + 0.18, w: 2.64, d: 1.04, leaf.base.mixed(with: leaf.shade, 0.4))
            let blooms = [PixelColor(0xFFB0C8), PixelColor(0xFFF1A8), PixelColor(0xFFFFFF), PixelColor(0xF08A7A), PixelColor(0xC8B8FF)]
            for k in 0..<46 {
                let h = workshopHash("bed-\(n)-\(k)")
                let p = iso.p(x + 0.3 + Double(h % 100) / 100 * 2.4, y + 0.3 + Double((h >> 8) % 100) / 100 * 0.8)
                c.plot(Int(p.x), Int(p.y) + 1, leaf.shade)
                c.plot(Int(p.x), Int(p.y), blooms[k % blooms.count])
                c.plot(Int(p.x) + 1, Int(p.y), blooms[k % blooms.count].mixed(with: PixelColor(0x6A3A5A), 0.25))
            }
        }
        // Gravel paths: one continuous strip, edged only where it meets grass.
        for tile in paths {
            let i = Double(tile.i - lower.i), j = Double(tile.j - lower.j)
            func open(_ di: Int, _ dj: Int) -> Bool { !paths.contains(WorkshopTile(i: tile.i + di, j: tile.j + dj)) }
            let (w0, w1, d0, d1) = (open(-1, 0) ? 0.14 : 0, open(1, 0) ? 0.14 : 0, open(0, -1) ? 0.14 : 0, open(0, 1) ? 0.14 : 0)
            c.flat(iso, i: i + w0, j: j + d0, w: 1 - w0 - w1, d: 1 - d0 - d1, gravel.shade)
            c.flat(iso, i: i + w0 * 1.5, j: j + d0 * 1.5, w: 1 - (w0 + w1) * 1.5, d: 1 - (d0 + d1) * 1.5, gravel.base)
            for k in 0..<5 {
                let h = workshopHash("gravel-\(tile.i)-\(tile.j)-\(k)")
                let p = iso.p(i + 0.25 + Double(h % 100) / 200, j + 0.25 + Double((h >> 8) % 100) / 200)
                c.plot(Int(p.x), Int(p.y), k % 2 == 0 ? gravel.deep : gravel.light)
            }
        }
        return PixelPiece(canvas: c, origin: [ox, oy])
    }

    /// Smooth value noise in 0…1, for grass patches a few tiles across.
    private static func patchNoise(_ x: Double, _ y: Double, seed: UInt64, cell: Double = 3.2) -> Double {
        let gx = x / cell, gy = y / cell
        let x0 = gx.rounded(.down), y0 = gy.rounded(.down)
        func v(_ a: Double, _ b: Double) -> Double { Double(workshopHash("\(seed)|\(Int(a))|\(Int(b))") % 1000) / 1000 }
        let tx = gx - x0, ty = gy - y0
        let sx = tx * tx * (3 - 2 * tx), sy = ty * ty * (3 - 2 * ty)
        let top = v(x0, y0) * (1 - sx) + v(x0 + 1, y0) * sx
        let bottom = v(x0, y0 + 1) * (1 - sx) + v(x0 + 1, y0 + 1) * sx
        return top * (1 - sy) + bottom * sy
    }

    /// A streetlamp; the light itself is a separate glow sprite at night.
    static func streetlamp(lit: Bool) -> PixelPiece {
        var c = PixelCanvas(width: 16, height: 46)
        let post = PixelRamp(0x6A7090, 0x4A5070, 0x343A56, 0x22263A)
        c.rect(4, 41, 5, 2, post.shade)
        c.rect(5, 8, 2, 34, post.base); c.rect(5, 8, 1, 34, post.light)
        c.rect(2, 4, 8, 3, post.shade); c.rect(3, 3, 6, 1, post.base)
        c.rect(3, 7, 6, 2, lit ? PixelColor(0xFFF0B8) : PixelColor(0xB8BCCE))
        c.outline(strength: 0.5)
        c.groundShadow(cx: 8, cy: 43, rx: 5, ry: 2)
        return PixelPiece(canvas: c, origin: [6, 43])
    }

    static func bush(_ variant: Int) -> PixelPiece {
        var c = PixelCanvas(width: 24, height: 17)
        let foliage = variant % 2 == 0 ? leaf : PixelRamp(0xC8E888, 0x84C45A, 0x58963E, 0x3A6A30)
        for (bx, by, r) in [(7.0, 9.0, 6.0), (14.0, 8.0, 6.5), (10.5, 5.5, 5.0)] {
            for y in Int(by - r)...Int(by + r) {
                for x in Int(bx - r)...Int(bx + r) where sqrt(pow(Double(x) - bx, 2) + pow((Double(y) - by) * 1.3, 2)) <= r {
                    let lightness = (Double(x) - bx) + (Double(y) - by)
                    c.plot(x, y, lightness < -r * 0.5 ? foliage.light : lightness > r * 0.6 ? foliage.shade : foliage.base)
                }
            }
        }
        if variant % 3 == 0 { for (x, y) in [(6, 6), (12, 4), (16, 9)] { c.plot(x, y, PixelColor(0xFFB0C8)) } }
        c.outline(strength: 0.55)
        c.groundShadow(cx: 12, cy: 14.5, rx: 10, ry: 2.5, alpha: 56)
        return PixelPiece(canvas: c, origin: [11, 14])
    }

    static func mailbox() -> PixelPiece {
        var c = PixelCanvas(width: 10, height: 18)
        c.rect(4, 7, 2, 10, darkWood.base)
        c.rect(1, 1, 8, 6, PixelColor(0x3F6FD0)); c.rect(1, 1, 8, 1, PixelColor(0x7AA0F0))
        c.rect(8, 1, 1, 3, PixelColor(0xE8645A))
        c.outline(strength: 0.5)
        c.groundShadow(cx: 6, cy: 17, rx: 3.5, ry: 1.2)
        return PixelPiece(canvas: c, origin: [5, 17])
    }

    static func tree(_ variant: Int) -> PixelPiece {
        if variant % 3 == 2 { return conifer() }
        var c = PixelCanvas(width: 38, height: 49)
        let trunk = darkWood
        c.rect(15, 32, 4, 14, trunk.base); c.rect(15, 32, 1, 14, trunk.light); c.rect(18, 32, 1, 14, trunk.shade)
        let foliage = variant % 2 == 0 ? leaf : PixelRamp(0xC8E888, 0x84C45A, 0x58963E, 0x3A6A30)
        let blobs: [(Double, Double, Double)] = [(17, 16, 11), (9, 24, 8), (25, 24, 8), (17, 27, 9), (12, 11, 6), (23, 12, 6)]
        for (bx, by, r) in blobs {
            for y in Int(by - r)...Int(by + r) {
                for x in Int(bx - r)...Int(bx + r) {
                    let d = sqrt(pow(Double(x) - bx, 2) + pow(Double(y) - by, 2))
                    guard d <= r else { continue }
                    let lightness = (Double(x) - bx) + (Double(y) - by)
                    c.plot(x, y, lightness < -r * 0.6 ? foliage.light : lightness > r * 0.7 ? foliage.shade : foliage.base)
                }
            }
        }
        for n in 0..<18 {
            let h = workshopHash("leaf-\(variant)-\(n)")
            c.plot(Int(h % 26) + 4, Int((h >> 8) % 28) + 5, foliage.deep)
        }
        c.outline(strength: 0.55)
        // The canopy's shadow falls a little to the right of the trunk.
        c.groundShadow(cx: 19.5, cy: 45.5, rx: 12, ry: 3.5)
        return PixelPiece(canvas: c, origin: [17, 46])
    }

    /// A small pine: stacked tiers, lit on the left like everything else.
    private static func conifer() -> PixelPiece {
        var c = PixelCanvas(width: 30, height: 52)
        let needles = PixelRamp(0x8CCB7A, 0x4F9A5E, 0x357250, 0x22503E)
        c.rect(13, 40, 4, 9, darkWood.base); c.rect(13, 40, 1, 9, darkWood.light)
        for (top, half, height) in [(24.0, 12.0, 18.0), (13.0, 9.5, 15.0), (3.0, 6.5, 13.0)] {
            for y in Int(top)..<Int(top + height) {
                let t = (Double(y) - top) / height
                let w = Int((half * (0.25 + 0.75 * t)).rounded())
                for x in (15 - w)...(14 + w) {
                    let side = Double(x - 15) / Double(max(1, w))
                    let color = side < -0.45 ? needles.light : side > 0.4 ? needles.shade : needles.base
                    c.plot(x, y, y == Int(top + height) - 1 ? needles.deep : color)
                }
            }
        }
        c.outline(strength: 0.55)
        c.groundShadow(cx: 17, cy: 48.5, rx: 9, ry: 3)
        return PixelPiece(canvas: c, origin: [15, 49])
    }

    /// One tile of low white picket fence along i (the plane j), for the lot's front edge.
    static func fence() -> PixelPiece {
        var (c, iso) = canvas(w: 1, d: 0.1, height: 8)
        let white = PixelRamp(0xFFFFFF, 0xEFE8DC, 0xD2C8BA, 0xA89C90)
        c.faceJ(iso, i0: 0, i1: 1, j: 0.05, k0: 3, k1: 4, white.shade)
        for u in [0.1, 0.43, 0.76] {
            c.faceJ(iso, i0: u, i1: u + 0.12, j: 0.05, k0: 0, k1: 6, white.base)
            c.faceJ(iso, i0: u, i1: u + 0.06, j: 0.05, k0: 6, k1: 7, white.light)
        }
        return PixelPiece(canvas: c, origin: [iso.ox, iso.oy])
    }

    /// A slatted garden bench, seat along i.
    static func bench() -> PixelPiece {
        var (c, iso) = canvas(w: 1.4, d: 0.5, height: 14)
        c.shadow(iso, i: 0.05, j: 0.05, w: 1.3, d: 0.42)
        for leg in [0.12, 1.18] { c.box(iso, i: leg, j: 0.1, k: 0, w: 0.1, d: 0.32, h: 5, ramp: metal) }
        c.box(iso, i: 0.05, j: 0.08, k: 5, w: 1.3, d: 0.36, h: 2, ramp: wood)
        c.box(iso, i: 0.05, j: 0.02, k: 7, w: 1.3, d: 0.08, h: 6, ramp: wood)
        c.outline(strength: 0.45)
        return PixelPiece(canvas: c, origin: [iso.ox, iso.oy])
    }
}

/// The night look is a multiply over the whole world. Anything that should
/// read as its true colour at night is drawn pre-divided by this.
enum PixelWorkshopNight {
    static let multiply = SIMD3<Double>(0.44, 0.5, 0.78)
}
