//
//  ANSITextCleaner.swift
//  CodexBar
//

import Foundation

/// Strips terminal control sequences from raw PTY output so parsing works
/// on plain text regardless of ANSI styling changes in future CLI versions.
enum ANSITextCleaner {

    /// Remove ANSI/VT escapes (CSI, OSC, DEC private modes, charset shifts,
    /// DECSCUSR `\x1b[N q`), then normalize line endings.
    static func clean(_ raw: String) -> String {
        var s = raw

        // OSC sequences: ESC ] ... BEL  or  ESC ] ... ESC \
        s = s.replacingOccurrences(
            of: "\u{1B}\\][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\\\)",
            with: "",
            options: .regularExpression)

        // DECSCUSR / cursor style: ESC [ N SP q  (the lone "q" trap)
        s = s.replacingOccurrences(
            of: "\u{1B}\\[[0-9;?]*[ ]?[a-zA-Z]",
            with: "",
            options: .regularExpression)

        // Charset designation and mode switches: ESC ( B, ESC >, ESC =, ESC 7/8/M/D...
        s = s.replacingOccurrences(
            of: "\u{1B}[()][0-9A-Za-z]|\u{1B}[=>78MD]",
            with: "",
            options: .regularExpression)

        // Bracketed paste / focus markers
        s = s.replacingOccurrences(of: "\u{1B}\\[\\?2004[hl]", with: "", options: .regularExpression)

        // Remaining lone ESC followed by a printable char
        s = s.replacingOccurrences(of: "\u{1B}[A-Za-z]", with: "", options: .regularExpression)

        // BEL and other C0 controls except \n and \r
        s = String(s.unicodeScalars.filter { scalar in
            scalar == "\n" || scalar == "\r" || scalar.value > 0x08
        })

        s = s.replacingOccurrences(of: "\r\n", with: "\n")
        s = s.replacingOccurrences(of: "\r", with: "\n")
        return s
    }

    /// Splits cleaned text into non-empty, trimmed lines.
    static func lines(_ cleaned: String) -> [String] {
        cleaned
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Removes box-drawing borders (lines made mostly of │ or ╭╰─ etc.)
    /// but keeps the content between │ delimiters.
    static func unwrapBoxes(_ line: String) -> [String] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // Pure border lines like ╭────╮ or │ (empty)
        if trimmed.hasPrefix("╭") || trimmed.hasPrefix("╰") || trimmed.hasPrefix("├")
            || trimmed.hasPrefix("┤") {
            return []
        }
        if trimmed.hasPrefix("│"), trimmed.count >= 2 {
            var inner = String(trimmed.dropFirst())
            if inner.hasSuffix("│") { inner = String(inner.dropLast()) }
            let content = inner.trimmingCharacters(in: .whitespaces)
            return content.isEmpty ? [] : [content]
        }
        return trimmed.isEmpty ? [] : [trimmed]
    }
}
