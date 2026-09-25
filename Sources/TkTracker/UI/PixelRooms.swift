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
    static let floors: [(PixelColor, PixelColor, PixelColor)] = [
        (PixelColor(0xE6B47C), PixelColor(0xDAA46A), PixelColor(0xBE8A56)), (PixelColor(0xF2EADA), PixelColor(0xD8CEBC), PixelColor(0xC4B8A4)),
        (PixelColor(0x8296D2), PixelColor(0x788CC8), PixelColor(0x6A7CB8)), (PixelColor(0xB67E52), PixelColor(0xA87248), PixelColor(0x8E5E3C)),
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
    static func shell(decor: WorkshopDecor, backRight: Int, backLeft: Int) -> PixelPiece {
        let W = Double(WorkshopRoomTemplate.width), D = Double(WorkshopRoomTemplate.height)
        let ox = D * 16 + 6, oy = Double(WorkshopLotPlan.fullWall) + 6
        var c = PixelCanvas(width: Int(ox + W * 16 + 8), height: Int(oy + (W + D) * 8 + 4))
        let iso = Iso(ox: ox, oy: oy)
        let floor = floors[decor.floor % floors.count]
        for i in 0..<Int(W) {
            for j in 0..<Int(D) {
                let a = (i + j) % 2 == 0 ? floor.0 : floor.1
                c.flat(iso, i: Double(i), j: Double(j), w: 1, d: 1, a)
                if decor.floor % 2 == 0 { // planks
                    c.flat(iso, i: Double(i), j: Double(j) + 0.48, w: 1, d: 0.05, floor.2)
                }
            }
        }
        let rug = rugs[decor.rug % rugs.count]
        c.flat(iso, i: 2.2, j: 2.1, w: 2.8, d: 2.2, rug.1)
        c.flat(iso, i: 2.35, j: 2.25, w: 2.5, d: 1.9, rug.0)
        c.flat(iso, i: 2.6, j: 2.5, w: 2.0, d: 1.4, rug.0.mixed(with: PixelColor(0xFFFFFF), 0.18))
        // Contact shadow where floor meets wall.
        c.flat(iso, i: 0, j: 0, w: W, d: 0.14, PixelColor(0x1C1030, alpha: 50))
        c.flat(iso, i: 0, j: 0, w: 0.14, d: D, PixelColor(0x1C1030, alpha: 50))

        let paper = wallpapers[decor.wallpaper % wallpapers.count]
        let base = PixelColor(paper.base), stripe = PixelColor(paper.stripe)
        let shaded = base.mixed(with: PixelColor(0x6A5A9A), 0.14), shadedStripe = stripe.mixed(with: PixelColor(0x6A5A9A), 0.14)
        let cap = PixelColor(0xFFF6EA), board = PixelColor(0xB08A64)
        // Back-right wall (plane j = 0), facing +j.
        let hr = Double(backRight), hl = Double(backLeft)
        c.box(iso, i: 0, j: -0.25, k: 0, w: W, d: 0.25, h: hr, top: cap, left: base, right: base.mixed(with: PixelColor(0x6A5A9A), 0.3))
        var s = 0.25
        while s < W - 0.1 { c.faceJ(iso, i0: s, i1: s + 0.12, j: 0, k0: 4, k1: hr - 2, stripe); s += 0.5 }
        c.faceJ(iso, i0: 0, i1: W, j: 0, k0: 0, k1: 3, board)
        // Back-left wall (plane i = 0), facing +i.
        c.box(iso, i: -0.25, j: -0.25, k: 0, w: 0.25, d: D + 0.25, h: hl, top: cap, left: shaded.mixed(with: PixelColor(0x6A5A9A), 0.3), right: shaded)
        s = 0.25
        while s < D - 0.1 { c.faceI(iso, i: 0, j0: s, j1: s + 0.12, k0: 4, k1: hl - 2, shadedStripe); s += 0.5 }
        c.faceI(iso, i: 0, j0: 0, j1: D, k0: 0, k1: 3, board.mixed(with: PixelColor(0x6A5A9A), 0.14))
        if backRight >= WorkshopLotPlan.fullWall {
            window(&c, iso, alongI: true, from: 4.4, to: 5.8, k0: 18, k1: 32)
            // The whiteboard a waiting lead studies when there is nobody to watch.
            c.faceJ(iso, i0: 1.3, i1: 3.1, j: 0, k0: 20, k1: 33, PixelColor(0x8A92AE))
            c.faceJ(iso, i0: 1.38, i1: 3.02, j: 0, k0: 21, k1: 32, PixelColor(0xFBFCFF))
            for (n, k) in [29.0, 26.5, 24.0].enumerated() {
                c.faceJ(iso, i0: 1.55, i1: 1.55 + 0.5 + Double(n % 2) * 0.5, j: 0, k0: k, k1: k + 1, [PixelColor(0x4FA3E0), PixelColor(0xE8645A), PixelColor(0x3FBF9A)][n])
            }
        }
        if backLeft >= WorkshopLotPlan.fullWall { window(&c, iso, alongI: false, from: 3.9, to: 5.2, k0: 16, k1: 30) }
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

    static let grassBase = PixelColor(0x78C45E)
    static let asphalt = PixelRamp(0x7A7E90, 0x5E6274, 0x4A4E60, 0x363A4A)
    static let pavement = PixelRamp(0xE8E2D4, 0xD4CCBA, 0xB8AE9C, 0x8E8676)

    /// The ground around the lot: a mowed lawn under the rooms, plain grass
    /// beyond it, and a street with sidewalks along the side the doors face.
    /// `field` is the whole drawn area; `lawn` the lot itself; the street runs
    /// along j at `streetI` (sidewalk, two lanes, sidewalk).
    static func ground(field: (WorkshopTile, WorkshopTile), lawn: (WorkshopTile, WorkshopTile), streetI: Int,
                       paths: Set<WorkshopTile>, seed: UInt64) -> PixelPiece {
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
                    let lawnTile = onLawn(i, j)
                    c.flat(iso, i: x, j: y, w: 1, d: 1, lawnTile && (i + j) % 2 == 0 ? PixelColor(0x84CC66) : grassBase)
                }
            }
        }
        // Tufts and flowers, never on the street.
        for n in 0..<Int(W * D * 1.3) {
            let h = workshopHash("\(seed)-tuft-\(n)")
            let fi = Double(h % 1000) / 1000 * W, fj = Double((h >> 12) % 1000) / 1000 * D
            let street = Int(fi) + lower.i - streetI
            guard street < 0 || street > 3 else { continue }
            let p = iso.p(fi, fj)
            let flower = n % 11 == 0
            c.plot(Int(p.x), Int(p.y), flower ? [PixelColor(0xFFF1A8), PixelColor(0xFFB0C8), PixelColor(0xFFFFFF)][n % 3] : grass.shade)
            if !flower { c.plot(Int(p.x) + 1, Int(p.y) - 1, grass.light) }
        }
        for tile in paths {
            let i = Double(tile.i - lower.i), j = Double(tile.j - lower.j)
            c.flat(iso, i: i + 0.22, j: j + 0.26, w: 0.56, d: 0.48, PixelColor(0xB8AE9E))
            c.flat(iso, i: i + 0.26, j: j + 0.28, w: 0.48, d: 0.38, PixelColor(0xD8D0C0))
        }
        return PixelPiece(canvas: c, origin: [ox, oy])
    }

    /// A streetlamp; the light itself is a separate glow sprite at night.
    static func streetlamp(lit: Bool) -> PixelPiece {
        var c = PixelCanvas(width: 12, height: 44)
        let post = PixelRamp(0x6A7090, 0x4A5070, 0x343A56, 0x22263A)
        c.rect(4, 41, 5, 2, post.shade)
        c.rect(5, 8, 2, 34, post.base); c.rect(5, 8, 1, 34, post.light)
        c.rect(2, 4, 8, 3, post.shade); c.rect(3, 3, 6, 1, post.base)
        c.rect(3, 7, 6, 2, lit ? PixelColor(0xFFF0B8) : PixelColor(0xB8BCCE))
        c.outline(strength: 0.5)
        return PixelPiece(canvas: c, origin: [6, 43])
    }

    static func bush(_ variant: Int) -> PixelPiece {
        var c = PixelCanvas(width: 22, height: 16)
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
        return PixelPiece(canvas: c, origin: [11, 14])
    }

    static func mailbox() -> PixelPiece {
        var c = PixelCanvas(width: 10, height: 18)
        c.rect(4, 7, 2, 10, darkWood.base)
        c.rect(1, 1, 8, 6, PixelColor(0x3F6FD0)); c.rect(1, 1, 8, 1, PixelColor(0x7AA0F0))
        c.rect(8, 1, 1, 3, PixelColor(0xE8645A))
        c.outline(strength: 0.5)
        return PixelPiece(canvas: c, origin: [5, 17])
    }

    static func tree(_ variant: Int) -> PixelPiece {
        var c = PixelCanvas(width: 34, height: 48)
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
        return PixelPiece(canvas: c, origin: [17, 46])
    }
}

/// The night look is a multiply over the whole world. Anything that should
/// read as its true colour at night is drawn pre-divided by this.
enum PixelWorkshopNight {
    static let multiply = SIMD3<Double>(0.52, 0.56, 0.82)
}
