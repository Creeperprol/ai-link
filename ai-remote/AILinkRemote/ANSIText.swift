import SwiftUI

/// Turns terminal output with ANSI escape codes (from `tmux capture-pane -e`) into colored text.
/// Handles SGR styles (bold, dim, italic, underline, inverse), 16/256/truecolor foreground and
/// background; drops every other escape sequence. Plain text passes through unchanged.
enum ANSIText {
    struct Style: Equatable {
        var fg: Color?
        var bg: Color?
        var bold = false
        var dim = false
        var italic = false
        var underline = false
        var inverse = false
    }

    static let defaultForeground = Color.white.opacity(0.92)

    static func attributed(_ input: String, fontSize: CGFloat = 11) -> AttributedString {
        var result = AttributedString()
        var style = Style()
        var buffer = ""
        let scalars = Array(input.unicodeScalars)
        var i = 0

        func flush() {
            guard !buffer.isEmpty else { return }
            var piece = AttributedString(buffer)
            var fg = style.fg ?? defaultForeground
            var bg = style.bg
            if style.inverse {
                let oldFg = fg
                fg = bg ?? Color.black
                bg = oldFg
            }
            if style.dim { fg = fg.opacity(0.6) }
            piece.foregroundColor = fg
            if let bg { piece.backgroundColor = bg }
            var font = Font.system(size: fontSize, design: .monospaced)
            if style.bold { font = font.bold() }
            if style.italic { font = font.italic() }
            piece.font = font
            if style.underline { piece.underlineStyle = .single }
            result += piece
            buffer = ""
        }

        while i < scalars.count {
            let c = scalars[i]
            guard c == "\u{1B}" else {
                buffer.unicodeScalars.append(c)
                i += 1
                continue
            }
            // ESC: work out the sequence type.
            guard i + 1 < scalars.count else { break }
            let next = scalars[i + 1]
            if next == "[" {
                // CSI: params until a final byte in 0x40...0x7E.
                var j = i + 2
                var params = ""
                while j < scalars.count, !(0x40...0x7E).contains(scalars[j].value) {
                    params.unicodeScalars.append(scalars[j])
                    j += 1
                }
                if j < scalars.count, scalars[j] == "m" {
                    flush()
                    apply(params, to: &style)
                }
                i = j + 1
            } else if next == "]" {
                // OSC (e.g. hyperlinks): skip to BEL or ESC \.
                var j = i + 2
                while j < scalars.count {
                    if scalars[j] == "\u{07}" { j += 1; break }
                    if scalars[j] == "\u{1B}", j + 1 < scalars.count, scalars[j + 1] == "\\" { j += 2; break }
                    j += 1
                }
                i = j
            } else {
                i += 2 // two-byte escape, ignore
            }
        }
        flush()
        return result
    }

    private static func apply(_ params: String, to style: inout Style) {
        let codes = params.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        var k = 0
        if codes.isEmpty { style = Style(); return }
        while k < codes.count {
            let code = codes[k]
            switch code {
            case 0: style = Style()
            case 1: style.bold = true
            case 2: style.dim = true
            case 3: style.italic = true
            case 4: style.underline = true
            case 7: style.inverse = true
            case 22: style.bold = false; style.dim = false
            case 23: style.italic = false
            case 24: style.underline = false
            case 27: style.inverse = false
            case 30...37: style.fg = palette(code - 30)
            case 39: style.fg = nil
            case 40...47: style.bg = palette(code - 40)
            case 49: style.bg = nil
            case 90...97: style.fg = palette(code - 90 + 8)
            case 100...107: style.bg = palette(code - 100 + 8)
            case 38, 48:
                var color: Color?
                if k + 2 < codes.count, codes[k + 1] == 5 {
                    color = color256(codes[k + 2]); k += 2
                } else if k + 4 < codes.count, codes[k + 1] == 2 {
                    color = rgb(codes[k + 2], codes[k + 3], codes[k + 4]); k += 4
                }
                if code == 38 { style.fg = color } else { style.bg = color }
            default: break
            }
            k += 1
        }
    }

    private static func rgb(_ r: Int, _ g: Int, _ b: Int) -> Color {
        Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
    }

    /// The 16 base colors (a bright, readable-on-black variant of the xterm palette).
    private static let base: [(Int, Int, Int)] = [
        (0, 0, 0), (222, 86, 86), (98, 200, 110), (222, 196, 90),
        (90, 140, 230), (196, 110, 220), (80, 196, 210), (204, 204, 204),
        (118, 118, 118), (255, 120, 120), (130, 230, 140), (255, 230, 120),
        (130, 170, 255), (230, 140, 255), (120, 230, 240), (255, 255, 255),
    ]

    private static func palette(_ n: Int) -> Color {
        let c = base[max(0, min(15, n))]
        return rgb(c.0, c.1, c.2)
    }

    private static func color256(_ n: Int) -> Color {
        switch n {
        case 0..<16: return palette(n)
        case 16..<232:
            let v = n - 16
            let steps = [0, 95, 135, 175, 215, 255]
            return rgb(steps[v / 36], steps[(v / 6) % 6], steps[v % 6])
        case 232...255:
            let g = 8 + (n - 232) * 10
            return rgb(g, g, g)
        default: return defaultForeground
        }
    }
}
