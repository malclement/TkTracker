import Foundation
import simd

/// A drawn sprite plus the pixel that should sit on its world position
/// (the feet for a standing Sim, the centre for one lying down).
struct PixelSprite {
    var canvas: PixelCanvas
    var anchor: SIMD2<Double>
}

/// The Sims themselves: a paper doll assembled per pose from head, hair,
/// torso, arms and legs, then given a selective outline. Two facings are
/// drawn (face and back); the other two are mirror images.
enum PixelSims {
    static let width = 22, height = 36
    /// Feet rest on the bottom edge of row 34.
    static let feet = SIMD2<Double>(11, 35)

    static let skins = [
        PixelRamp(0xFFE3C8, 0xF6C9A3, 0xD9A07E, 0xA8705C), PixelRamp(0xF9D2AC, 0xE8B48A, 0xC4886A, 0x925A4C),
        PixelRamp(0xE6AE7E, 0xC98A5C, 0xA06448, 0x70403A), PixelRamp(0xBE8254, 0x9A6040, 0x764530, 0x4E2C28),
        PixelRamp(0x946244, 0x70462E, 0x523226, 0x34201E), PixelRamp(0xFCE6D8, 0xF0CBB8, 0xCF9F90, 0xA07076),
    ]
    static let hairs = [
        PixelRamp(0x7A5644, 0x4A3228, 0x2E1E1C, 0x1C1216), PixelRamp(0x585A70, 0x2C2C3A, 0x1A1A26, 0x0E0E18),
        PixelRamp(0xFFE8A8, 0xE8B858, 0xB8843A, 0x805428), PixelRamp(0xF08A5A, 0xC0502E, 0x8A3424, 0x5A2020),
        PixelRamp(0xFFFFFF, 0xCED0DE, 0x9A9CB2, 0x6A6C86), PixelRamp(0xFFC4DC, 0xE87AA8, 0xB0507E, 0x7A3060),
        PixelRamp(0xA8CCFF, 0x5A84E0, 0x3A58A8, 0x243878),
    ]
    static let shirts = [
        PixelRamp(0xFFA898, 0xE8645A, 0xB04442, 0x782E3A), PixelRamp(0x9ADAFF, 0x4FA3E0, 0x2F72B0, 0x204C80),
        PixelRamp(0xFFDC84, 0xF0B43C, 0xC08424, 0x86561E), PixelRamp(0xD4B8FF, 0x9B6EE0, 0x6E48B0, 0x48307E),
        PixelRamp(0x9CF4D0, 0x3FBF9A, 0x248A72, 0x165E54), PixelRamp(0xFFC6D6, 0xF08AA8, 0xC05A80, 0x843C5E),
        PixelRamp(0xFFFFFF, 0xE2E6F0, 0xAAB0C6, 0x767C9A), PixelRamp(0x92D086, 0x4A9A52, 0x2E6A3E, 0x1E4630),
    ]
    static let trousers = [
        PixelRamp(0x6A7AAA, 0x3A4466, 0x262C48, 0x181C32), PixelRamp(0x7A7A8A, 0x4A4A58, 0x30303C, 0x1E1E28),
        PixelRamp(0x7AAAE0, 0x4A72A8, 0x324E7A, 0x223456), PixelRamp(0xE6CE9E, 0xB89C68, 0x8A7248, 0x5E4C34),
        PixelRamp(0x9A7AAA, 0x5E4470, 0x3E2C4C, 0x281C34),
    ]
    static let shoe = PixelRamp(0x5A5068, 0x3A3440, 0x24202A, 0x141018)
    static let eye = PixelColor(0x2A1E2A)
    static let mouth = PixelColor(0xB0605A)
    static let blush = PixelColor(0xFF9A9A)

    struct Look {
        var skin: PixelRamp, hair: PixelRamp, style: Int, shirt: PixelRamp, trousers: PixelRamp
        init(_ look: WorkshopLook) {
            skin = PixelSims.skins[look.skin % PixelSims.skins.count]
            hair = PixelSims.hairs[look.hair % PixelSims.hairs.count]
            style = look.hairStyle
            shirt = PixelSims.shirts[look.shirt % PixelSims.shirts.count]
            trousers = PixelSims.trousers[look.trousersColor % PixelSims.trousers.count]
        }
    }

    enum Eyes { case open, closed, side }

    // MARK: Body parts. `c` is the canvas, `dy` lowers the whole upper body.

    private static func head(_ c: inout PixelCanvas, _ l: Look, face: Bool, top: Int, eyes: Eyes) {
        let rows: [(Int, Int)] = [(7, 14), (6, 15), (5, 16), (5, 16), (5, 16), (5, 16), (5, 16), (5, 16), (5, 16), (6, 15), (7, 14)]
        for (r, span) in rows.enumerated() {
            c.rect(span.0, top + r, span.1 - span.0 + 1, 1, l.skin.base)
            c.plot(span.1, top + r, l.skin.shade)
        }
        c.rect(9, top + 11, 4, 1, l.skin.shade) // neck
        guard face else { return }
        let y = top + 5
        switch eyes {
        case .open: for x in [8, 13] { c.rect(x, y, 1, 2, eye) }
        case .side: for x in [9, 14] { c.rect(x, y, 1, 2, eye) }
        case .closed: for x in [7, 12] { c.rect(x, y + 1, 2, 1, eye) }
        }
        c.plot(7, top + 7, blush.mixed(with: l.skin.base, 0.35)); c.plot(14, top + 7, blush.mixed(with: l.skin.base, 0.35))
        c.rect(10, top + 8, 2, 1, mouth)
    }

    /// Hair that sits behind the body (long styles), drawn before the torso.
    private static func hairBack(_ c: inout PixelCanvas, _ l: Look, face: Bool, top: Int) {
        guard l.style == 1 else { return }
        let bottom = top + (face ? 14 : 16)
        c.rect(4, top + 3, 2, bottom - top - 2, l.hair.shade)
        c.rect(16, top + 3, 2, bottom - top - 2, l.hair.deep)
        if !face { c.rect(6, top + 10, 10, bottom - top - 9, l.hair.base) }
    }

    private static func hair(_ c: inout PixelCanvas, _ l: Look, face: Bool, top: Int) {
        let h = l.hair
        let t = top - 2
        if l.style == 3 {
            for x in [7, 10, 13] { c.rect(x, t - 1, 2, 1, h.base) }
            c.rect(5, t, 12, 1, h.base)
            c.rect(4, t + 1, 14, face ? 5 : 11, h.base)
            if face { c.rect(4, t + 6, 3, 3, h.base); c.rect(15, t + 6, 3, 3, h.shade); c.rect(6, t + 6, 10, 1, h.base) }
            c.rect(6, t + 1, 4, 1, h.light); c.rect(5, t + 2, 2, 1, h.light)
            c.rect(16, t + 1, 2, face ? 5 : 11, h.shade)
            return
        }
        c.rect(8, t, 6, 1, h.base)
        c.rect(6, t + 1, 10, 1, h.base)
        c.rect(5, t + 2, 12, 3, h.base)
        if face {
            c.rect(5, t + 5, 2, 2, h.base); c.rect(15, t + 5, 2, 2, h.shade)
            c.rect(7, t + 5, 4, 1, h.base) // side-parted fringe
            c.plot(5, t + 7, h.shade); c.plot(16, t + 7, h.deep)
        } else {
            c.rect(5, t + 5, 12, 7, h.base)
            c.rect(6, t + 12, 10, 1, h.base)
            c.rect(15, t + 3, 2, 9, h.shade)
        }
        c.rect(8, t + 1, 3, 1, h.light); c.rect(7, t + 2, 2, 1, h.light)
        c.rect(15, t + 2, 2, 3, h.shade)
        if l.style == 2 {
            c.rect(9, t - 3, 4, 1, h.base); c.rect(8, t - 2, 6, 2, h.base); c.rect(9, t - 2, 2, 1, h.light)
        }
    }

    private static func torso(_ c: inout PixelCanvas, _ l: Look, face: Bool, top: Int) {
        c.rect(8, top, 6, 1, l.shirt.base)
        c.rect(7, top + 1, 8, 6, l.shirt.base)
        c.rect(7, top + 1, 1, 6, l.shirt.light)
        c.rect(13, top + 1, 2, 6, l.shirt.shade)
        if face { c.rect(10, top, 2, 1, l.skin.shade) }
        c.rect(7, top + 7, 8, 1, l.trousers.base) // waistband
        c.rect(13, top + 7, 2, 1, l.trousers.shade)
    }

    enum Arm { case down, forward, back, up, upHigh, hip, bent, bentUp }

    private static func arm(_ c: inout PixelCanvas, _ l: Look, right: Bool, _ kind: Arm, shoulder: Int) {
        let x = right ? 15 : 5
        let sleeve = right ? l.shirt.shade : l.shirt.base
        let skin = right ? l.skin.shade : l.skin.base
        switch kind {
        case .down, .forward, .back:
            let extra = kind == .forward ? 1 : kind == .back ? -1 : 0
            c.rect(x, shoulder + 1, 2, 2, sleeve)
            c.rect(x, shoulder + 3, 2, 3 + extra, skin)
            c.rect(x, shoulder + 6 + extra, 2, 1, l.skin.base)
        case .up, .upHigh:
            let ax = right ? (kind == .upHigh ? 18 : 17) : 3
            c.rect(right ? 15 : 5, shoulder, 2, 2, sleeve)
            c.rect(right ? min(ax, 16) : 4, shoulder - 1, 2, 2, sleeve)
            c.rect(ax, shoulder - 9, 2, 8, skin)
            c.rect(ax, shoulder - 11, 2, 2, l.skin.light)
        case .hip:
            c.rect(x, shoulder + 1, 2, 2, sleeve)
            c.rect(right ? 17 : 3, shoulder + 3, 2, 2, skin)
            c.rect(right ? 15 : 5, shoulder + 5, 2, 1, skin)
        case .bent, .bentUp:
            let lift = kind == .bentUp ? 1 : 0
            c.rect(x, shoulder + 1 - lift, 2, 2, sleeve)
            c.rect(right ? 16 : 4, shoulder + 3 - lift, 2, 2, skin)
        }
    }

    private static func legs(_ c: inout PixelCanvas, _ l: Look, top: Int, stride: Int, tap: Bool) {
        let p = l.trousers
        // stride: 0 standing, 1 left leg forward, -1 right leg forward.
        let leftDrop = stride == 1 ? 1 : 0, rightDrop = stride == -1 ? 1 : 0
        let leftLift = stride == -1 ? 1 : 0, rightLift = (stride == 1 || tap) ? 1 : 0
        c.rect(7, top, 8, 1, p.base)
        c.rect(7, top + 1, 3, 5 + leftDrop - leftLift, p.base)
        c.rect(12, top + 1, 3, 5 + rightDrop - rightLift, p.shade)
        c.rect(7, top + 1, 1, 5 + leftDrop - leftLift, p.light)
        c.rect(6, top + 6 + leftDrop - leftLift, 4, 2, shoe.base); c.rect(6, top + 6 + leftDrop - leftLift, 4, 1, shoe.light)
        c.rect(12, top + 6 + rightDrop - rightLift, 4, 2, shoe.shade); c.rect(12, top + 6 + rightDrop - rightLift, 4, 1, shoe.base)
    }

    private static func sittingLegs(_ c: inout PixelCanvas, _ l: Look, top: Int) {
        c.rect(6, top, 10, 2, l.trousers.base)
        c.rect(6, top, 10, 1, l.trousers.light)
        c.rect(7, top + 2, 3, 2, l.trousers.shade); c.rect(12, top + 2, 3, 2, l.trousers.shade)
        c.rect(6, top + 4, 4, 1, shoe.base); c.rect(12, top + 4, 4, 1, shoe.shade)
    }

    // MARK: Assembly

    static func sprite(look workshopLook: WorkshopLook, pose: WorkshopPose, face: Bool, frame: Int, blink: Bool = false) -> PixelSprite {
        let l = Look(workshopLook)
        if pose == .sleep { return lying(l) }
        var c = PixelCanvas(width: width, height: height)
        var drop = 0
        var eyes: Eyes = blink ? .closed : .open
        var leftArm = Arm.down, rightArm = Arm.down
        var stride = 0, tap = false, seated = false, sitting = false
        switch pose {
        case .stand: drop = frame % 2
        case .walk:
            stride = frame % 2 == 0 ? 1 : -1
            leftArm = stride == 1 ? .back : .forward; rightArm = stride == 1 ? .forward : .back
            drop = 0
        case .type:
            seated = true; drop = 4
            leftArm = frame % 2 == 0 ? .bentUp : .bent; rightArm = frame % 2 == 0 ? .bent : .bentUp
        case .sit:
            sitting = true; drop = 3; eyes = .closed
        case .wave:
            rightArm = frame % 2 == 0 ? .up : .upHigh
        case .cheer:
            leftArm = .up; rightArm = .up; drop = frame % 2 == 0 ? -2 : 0
        case .wait:
            leftArm = .hip; rightArm = .hip; tap = frame % 2 == 1; eyes = blink ? .closed : .side
        case .slump:
            eyes = .closed; drop = 1
        case .sleep: break
        }
        let headTop = 8 + drop + (pose == .slump ? 2 : 0)
        let torsoTop = 19 + drop
        hairBack(&c, l, face: face, top: headTop)
        torso(&c, l, face: face, top: torsoTop)
        if sitting { sittingLegs(&c, l, top: torsoTop + 8) }
        else if !seated { legs(&c, l, top: 27 + max(0, drop), stride: stride, tap: tap) }
        arm(&c, l, right: false, leftArm, shoulder: torsoTop)
        arm(&c, l, right: true, rightArm, shoulder: torsoTop)
        head(&c, l, face: face, top: headTop, eyes: eyes)
        hair(&c, l, face: face, top: headTop)
        c.outline()
        return PixelSprite(canvas: c, anchor: feet)
    }

    /// Lying down, drawn flat, then sheared to lie along the couch.
    private static func lying(_ l: Look) -> PixelSprite {
        var c = PixelCanvas(width: 36, height: 14)
        c.rect(3, 3, 8, 8, l.skin.base); c.rect(4, 2, 6, 10, l.skin.base); c.rect(10, 4, 1, 6, l.skin.shade)
        c.rect(2, 3, 3, 8, l.hair.base); c.rect(3, 2, 4, 1, l.hair.base); c.rect(3, 11, 4, 1, l.hair.shade); c.rect(2, 4, 1, 3, l.hair.light)
        c.rect(7, 6, 2, 1, eye); c.rect(8, 8, 1, 1, mouth)
        c.rect(11, 3, 11, 9, l.shirt.base); c.rect(11, 3, 11, 1, l.shirt.light); c.rect(11, 11, 11, 1, l.shirt.shade)
        c.rect(13, 7, 7, 1, l.skin.base)
        c.rect(22, 4, 9, 7, l.trousers.base); c.rect(22, 7, 9, 1, l.trousers.shade)
        c.rect(31, 3, 3, 8, shoe.base); c.rect(31, 3, 3, 1, shoe.light)
        let sheared = c.sheared(slope: 0.5)
        var out = PixelCanvas(width: sheared.width + 2, height: sheared.height + 2)
        out.draw(sheared, x: 1, y: 1)
        out.outline()
        return PixelSprite(canvas: out, anchor: [19, 20])
    }

    /// Head and shoulders for SwiftUI portraits.
    static func portrait(look: WorkshopLook) -> PixelCanvas {
        let body = sprite(look: look, pose: .stand, face: true, frame: 0).canvas
        var out = PixelCanvas(width: 22, height: 22)
        for y in 0..<22 { for x in 0..<22 { out.plot(x, y, body[x, y + 3]) } }
        return out
    }

    // MARK: State signals

    static func plumbobColors(_ state: WorkshopState) -> (dark: PixelColor, base: PixelColor, light: PixelColor) {
        switch state {
        case .working, .usingTool: return (PixelColor(0x1F9F82), PixelColor(0x36D6B0), PixelColor(0xA6F5E0))
        case .waitingForAgents: return (PixelColor(0x6E52CC), PixelColor(0xA98BFF), PixelColor(0xDCCFFF))
        case .needsInput: return (PixelColor(0xC47A10), PixelColor(0xFFB13B), PixelColor(0xFFE2A6))
        case .idle: return (PixelColor(0x6A7288), PixelColor(0x9AA3B8), PixelColor(0xDDE1EA))
        case .completed: return (PixelColor(0x4F9E2A), PixelColor(0x8EE05A), PixelColor(0xD4F7B8))
        case .interrupted: return (PixelColor(0xC0443A), PixelColor(0xFF6F61), PixelColor(0xFFC3BC))
        case .unavailable: return (PixelColor(0x6A7288), PixelColor(0x7A8298), PixelColor(0x9AA3B8))
        }
    }

    /// The plumbob spins: four frames of an elongated octahedron turning.
    static func plumbob(_ state: WorkshopState, frame: Int) -> PixelCanvas {
        let colors = plumbobColors(state)
        let halfWidths = [0, 1, 2, 3, 3, 3, 2, 2, 1, 1, 0, 0]
        let scale = [1.0, 0.67, 0.34, 0.67][frame % 4]
        let swapped = frame % 4 == 3
        var c = PixelCanvas(width: 9, height: 14)
        for (r, hw) in halfWidths.enumerated() {
            let w = Int((Double(hw) * scale).rounded())
            let top = r < 4
            for dx in -w...w {
                let x = 4 + dx, y = r + 1
                if state == .unavailable {
                    if abs(dx) == w || r == 0 || r == halfWidths.count - 1 { c.plot(x, y, colors.light) }
                    continue
                }
                let leftSide = swapped ? dx > 0 : dx < 0
                var color = dx == 0 ? colors.base : leftSide ? colors.light : colors.dark
                if top && dx == 0 { color = colors.light }
                if !top && leftSide { color = colors.base }
                c.plot(x, y, color)
            }
        }
        if state != .unavailable { c.outline(strength: 0.7) }
        return c
    }

    enum Icon: String, CaseIterable {
        case attention, check, sleep, question, team, search, read, edit, run, delegate, tool
    }

    static func icon(for agent: WorkshopAgent) -> Icon? {
        switch agent.state {
        case .needsInput: return .attention
        case .completed: return .check
        case .waitingForAgents: return .team
        case .unavailable: return .question
        case .usingTool:
            switch agent.tool ?? .other {
            case .search: return .search
            case .read: return .read
            case .edit: return .edit
            case .run: return .run
            case .delegate: return .delegate
            case .other: return .tool
            }
        default: return nil
        }
    }

    private static let iconGrids: [Icon: [String]] = [
        .attention: ["...xxx...", "...xxx...", "...xxx...", "...xxx...", "....x....", "....x....", ".........", "...xxx...", "...xxx..."],
        .check: [".........", "........x", ".......xx", "......xx.", "x....xx..", "xx..xx...", ".xxxx....", "..xx.....", "........."],
        .sleep: ["xxxxx....", "...x.....", "..x......", ".x.......", "xxxxx....", ".....xxxx", ".......x.", "......x..", ".....xxxx"],
        .question: ["..xxxx...", ".xx..xx..", ".....xx..", "....xx...", "...xx....", "...xx....", ".........", "...xx....", "...xx...."],
        .team: ["..x...x..", ".xxx.xxx.", ".xxx.xxx.", "..x...x..", ".........", "xxxx.xxxx", "xxxx.xxxx", "xxxx.xxxx", "........."],
        .search: [".xxxx....", "x....x...", "x....x...", "x....x...", "x....x...", ".xxxxx...", ".....xx..", "......xx.", ".......xx"],
        .read: [".........", "xxxx.xxxx", "x..x.x..x", "x.xx.xx.x", "x..x.x..x", "x.xx.xx.x", "x..x.x..x", "xxxxxxxxx", "....x...."],
        .edit: [".......xx", "......x.x", ".....x.x.", "....x.x..", "...x.x...", "..x.x....", ".xxx.....", ".xx......", "x........"],
        .run: ["xxxxxxxxx", "x.......x", "x.x.....x", "x..x....x", "x.x..xx.x", "x.......x", "xxxxxxxxx", ".........", "........."],
        .delegate: ["....x....", "....xx...", "xxxxxxx..", "xxxxxxxx.", "xxxxxxx..", "....xx...", "....x....", ".........", "........."],
        .tool: ["......xx.", ".....x..x", ".....x.x.", "....x.x..", "...x.x...", "..x.x....", ".x.x.....", "x.x......", ".x......."],
    ]

    static func bubble(_ icon: Icon) -> PixelCanvas {
        var c = PixelCanvas(width: 20, height: 18)
        let ink = PixelColor(0x2A2440), paper = PixelColor(0xFFFDF5)
        c.rect(4, 0, 13, 1, ink); c.rect(4, 12, 13, 1, ink); c.rect(3, 1, 1, 11, ink); c.rect(17, 1, 1, 11, ink)
        c.rect(4, 1, 13, 11, paper)
        c.plot(4, 1, ink); c.plot(16, 1, ink); c.plot(4, 11, ink); c.plot(16, 11, ink)
        c.rect(2, 13, 2, 2, ink); c.plot(2, 13, paper)
        c.plot(0, 16, ink)
        let color: PixelColor
        switch icon {
        case .attention: color = PixelColor(0xD06A00)
        case .check: color = PixelColor(0x3F8A1E)
        case .run: color = PixelColor(0x1F7F6A)
        default: color = PixelColor(0x3A3060)
        }
        if let rows = iconGrids[icon] { c.grid(rows, x: 6, y: 2, ["x": color]) }
        return c
    }

    static func zGlyph() -> PixelCanvas {
        var c = PixelCanvas(width: 5, height: 7)
        PixelFont.draw("Z", into: &c, x: 1, y: 1, color: PixelColor(0xEEF2FF))
        c.outline(strength: 0.8)
        return c
    }

    static func rainCloud(frame: Int) -> PixelCanvas {
        var c = PixelCanvas(width: 16, height: 15)
        let grey = PixelRamp(0xB8BCCE, 0x8A90A6, 0x6C7288, 0x4A4E62)
        c.rect(4, 1, 7, 2, grey.light); c.rect(2, 3, 12, 3, grey.base); c.rect(3, 6, 10, 1, grey.shade)
        c.rect(5, 1, 3, 1, PixelColor(0xDADDEA))
        for n in 0..<3 {
            let y = 8 + (frame + n) % 2 * 3
            c.rect(4 + n * 3, y, 1, 2, PixelColor(0x9FC7FF))
        }
        return c
    }

    static func dust(frame: Int) -> PixelCanvas {
        var c = PixelCanvas(width: 30, height: 14)
        let color = PixelColor(0xF4EEE2)
        let r = 5.0 + Double(frame) * 4.5
        for n in 0..<12 {
            let a = Double(n) / 12 * 2 * .pi
            let x = 15 + Int((cos(a) * r).rounded()), y = 7 + Int((sin(a) * r / 2).rounded())
            let s = frame < 2 ? 2 : 1
            c.rect(x, y, s, s, color.alpha(frame == 2 ? 170 : 255))
        }
        return c
    }

    static func selectionRing() -> PixelCanvas {
        var c = PixelCanvas(width: 26, height: 13)
        let color = PixelColor(0xFFF1A8)
        for n in 0..<48 {
            let a = Double(n) / 48 * 2 * .pi
            c.plot(13 + Int((cos(a) * 11).rounded()), 6 + Int((sin(a) * 5).rounded()), color)
        }
        return c
    }

    /// A warm pool of light, stepped rather than smooth.
    static func glow(width w: Int, height h: Int, color: PixelColor, intensity: Double = 1) -> PixelCanvas {
        var c = PixelCanvas(width: w, height: h)
        let cx = Double(w) / 2, cy = Double(h) / 2
        for y in 0..<h {
            for x in 0..<w {
                let d = sqrt(pow((Double(x) + 0.5 - cx) / cx, 2) + pow((Double(y) + 0.5 - cy) / cy, 2))
                let alpha = UInt8((Double(d < 0.35 ? 64 : d < 0.65 ? 38 : d < 1 ? 16 : 0) * intensity).rounded())
                if alpha > 0 { c.plot(x, y, color.alpha(alpha)) }
            }
        }
        return c
    }
}
