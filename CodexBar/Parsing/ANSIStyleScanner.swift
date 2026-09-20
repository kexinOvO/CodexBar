//
//  ANSIStyleScanner.swift
//  CodexBar
//

import Foundation

// MARK: - Colour

/// A 24-bit RGB colour, as emitted by SGR `38;2;r;g;b` or resolved from an
/// xterm-256 palette index (`38;5;n`).
struct ANSIRGB: Hashable {
    var red: Int
    var green: Int
    var blue: Int

    /// Squared euclidean distance in RGB. Good enough to rank the CLI's
    /// heatmap ramp: its steps are wide and evenly spaced.
    func distanceSquared(to other: ANSIRGB) -> Int {
        let dr = red - other.red
        let dg = green - other.green
        let db = blue - other.blue
        return dr * dr + dg * dg + db * db
    }

    /// Perceived brightness (ITU-R BT.601). Used to rank colours by shade
    /// when the CLI doesn't give us a legend to calibrate against.
    var luminance: Int { (299 * red + 587 * green + 114 * blue) / 1000 }
}

// MARK: - Styled character

/// One printable character plus the SGR attributes in effect when the CLI
/// drew it.
///
/// Colour matters: the Codex CLI paints the *same* block glyph (`■`) for
/// every non-empty heatmap cell and carries the intensity level purely in the
/// foreground colour. Stripping ANSI before parsing therefore throws the
/// intensity away — see `UsageParser.parseHeatmap`.
struct StyledCharacter {
    var character: Character
    /// `nil` means the terminal default foreground (SGR 39).
    var color: ANSIRGB?
    /// SGR 2 (dim), cleared by SGR 22. The CLI marks "no activity" cells dim.
    var isDim: Bool = false
}

// MARK: - Scanner

/// Splits raw PTY output into lines of `StyledCharacter`s.
///
/// Everything `ANSITextCleaner` throws away (cursor moves, erases, OSC
/// hyperlinks, charset shifts, C0 controls) is still dropped here, but SGR
/// state is tracked and resolved per character instead of being deleted.
enum ANSIStyleScanner {

    static func styledLines(from raw: String) -> [[StyledCharacter]] {
        var lines: [[StyledCharacter]] = [[]]
        var state = State()
        let chars = Array(raw)
        var i = 0

        while i < chars.count {
            let c = chars[i]

            if c == "\u{1B}" {
                i = consumeEscape(chars, from: i, state: &state)
                continue
            }
            if c == "\n" || c == "\r\n" {
                // CRLF is a single grapheme cluster in Swift, so it has to be
                // matched as its own case — otherwise it falls through to the
                // control-character filter below and every line is dropped.
                lines.append([])
                i += 1
                continue
            }
            if c == "\r" {
                // Bare CR (in-place redraw) starts a new line just like the
                // plain cleaner does.
                lines.append([])
                i += 1
                continue
            }
            if let scalar = c.unicodeScalars.first, scalar.value < 0x20 || scalar.value == 0x7F {
                i += 1
                continue
            }

            lines[lines.count - 1].append(StyledCharacter(character: c,
                                                           color: state.color,
                                                           isDim: state.isDim))
            i += 1
        }
        return lines
    }

    /// Convenience: the plain text of a styled line.
    static func plainText(of line: [StyledCharacter]) -> String {
        String(line.map(\.character))
    }

    /// Convenience: the plain text of a styled document.
    static func plainText(of lines: [[StyledCharacter]]) -> String {
        lines.map(plainText(of:)).joined(separator: "\n")
    }

    // MARK: - Escape handling

    private struct State {
        var color: ANSIRGB?
        var isDim = false
    }

    /// Consumes one escape sequence starting at `index`; returns the index
    /// just past it.
    private static func consumeEscape(_ chars: [Character],
                                      from index: Int,
                                      state: inout State) -> Int {
        let next = index + 1
        guard next < chars.count else { return next }

        switch chars[next] {
        case "[":
            return consumeCSI(chars, from: next + 1, state: &state)
        case "]":
            return consumeOSC(chars, from: next + 1)
        case "(", ")", "*", "+":
            return min(next + 2, chars.count)
        default:
            // Two-character escapes: ESC >, ESC =, ESC 7, ESC M, ESC D…
            return next + 1
        }
    }

    /// CSI: parameters then one final byte in 0x40...0x7E. Only `m` (SGR) is
    /// interpreted; cursor moves / erases are dropped.
    private static func consumeCSI(_ chars: [Character],
                                   from index: Int,
                                   state: inout State) -> Int {
        var i = index
        var params = ""
        while i < chars.count {
            let c = chars[i]
            guard let scalar = c.unicodeScalars.first else { break }
            if scalar.value >= 0x40 && scalar.value <= 0x7E {
                if c == "m" { applySGR(params, state: &state) }
                return i + 1
            }
            params.append(c)
            i += 1
        }
        return i
    }

    /// OSC: `ESC ] … BEL` or `ESC ] … ESC \`.
    private static func consumeOSC(_ chars: [Character], from index: Int) -> Int {
        var i = index
        while i < chars.count {
            if chars[i] == "\u{07}" { return i + 1 }
            if chars[i] == "\u{1B}" {
                return i + 2 <= chars.count ? i + 2 : chars.count
            }
            i += 1
        }
        return i
    }

    // MARK: - SGR

    private static func applySGR(_ params: String, state: inout State) {
        // An empty parameter string means SGR 0.
        let parts = params.isEmpty ? ["0"] : params.split(separator: ";", omittingEmptySubsequences: false)
            .map(String.init)

        var i = 0
        while i < parts.count {
            let part = parts[i]
            let code = Int(part) ?? 0

            switch code {
            case 0:
                state.color = nil
                state.isDim = false
            case 2:
                state.isDim = true
            case 22:
                state.isDim = false
            case 38:
                // 38;5;n  or  38;2;r;g;b
                if i + 1 < parts.count, let mode = Int(parts[i + 1]) {
                    if mode == 5, i + 2 < parts.count, let index = Int(parts[i + 2]) {
                        state.color = xterm256(index)
                        i += 2
                    } else if mode == 2, i + 4 < parts.count,
                              let r = Int(parts[i + 2]),
                              let g = Int(parts[i + 3]),
                              let b = Int(parts[i + 4]) {
                        state.color = ANSIRGB(red: r & 0xFF, green: g & 0xFF, blue: b & 0xFF)
                        i += 4
                    }
                }
            case 39:
                state.color = nil
            case 30...37:
                state.color = basicPalette[code - 30]
            case 90...97:
                state.color = basicPalette[code - 90 + 8]
            default:
                break
            }
            i += 1
        }
    }

    /// The 16 ANSI palette slots. Terminals may remap these; they're only a
    /// fallback for CLIs that don't use 24-bit colour.
    private static let basicPalette: [ANSIRGB] = [
        ANSIRGB(red: 0x00, green: 0x00, blue: 0x00),
        ANSIRGB(red: 0x80, green: 0x00, blue: 0x00),
        ANSIRGB(red: 0x00, green: 0x80, blue: 0x00),
        ANSIRGB(red: 0x80, green: 0x80, blue: 0x00),
        ANSIRGB(red: 0x00, green: 0x00, blue: 0x80),
        ANSIRGB(red: 0x80, green: 0x00, blue: 0x80),
        ANSIRGB(red: 0x00, green: 0x80, blue: 0x80),
        ANSIRGB(red: 0xC0, green: 0xC0, blue: 0xC0),
        ANSIRGB(red: 0x80, green: 0x80, blue: 0x80),
        ANSIRGB(red: 0xFF, green: 0x00, blue: 0x00),
        ANSIRGB(red: 0x00, green: 0xFF, blue: 0x00),
        ANSIRGB(red: 0xFF, green: 0xFF, blue: 0x00),
        ANSIRGB(red: 0x00, green: 0x00, blue: 0xFF),
        ANSIRGB(red: 0xFF, green: 0x00, blue: 0xFF),
        ANSIRGB(red: 0x00, green: 0xFF, blue: 0xFF),
        ANSIRGB(red: 0xFF, green: 0xFF, blue: 0xFF),
    ]

    static func xterm256(_ index: Int) -> ANSIRGB {
        if index < 16 { return basicPalette[max(0, index)] }
        if index < 232 {
            let n = index - 16
            let steps = [0, 95, 135, 175, 215, 255]
            return ANSIRGB(red: steps[n / 36],
                           green: steps[(n / 6) % 6],
                           blue: steps[n % 6])
        }
        let level = 8 + (min(index, 255) - 232) * 10
        return ANSIRGB(red: level, green: level, blue: level)
    }
}
