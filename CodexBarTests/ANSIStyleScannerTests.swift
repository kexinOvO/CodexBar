//
//  ANSIStyleScannerTests.swift
//  CodexBarTests
//

import XCTest
@testable import CodexBar

final class ANSIStyleScannerTests: XCTestCase {

    /// CRLF is a single grapheme cluster in Swift; a scanner that only tests
    /// for "\n" drops every line of PTY output. Regression guard.
    func testSplitsCRLFIntoLines() {
        let raw = "A\u{1B}[38;2;1;2;3mB\u{1B}[39mC\r\nD\rE\nF"
        let lines = ANSIStyleScanner.styledLines(from: raw)
        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(ANSIStyleScanner.plainText(of: lines[0]), "ABC")
        XCTAssertEqual(ANSIStyleScanner.plainText(of: lines[1]), "D")
        XCTAssertEqual(ANSIStyleScanner.plainText(of: lines[2]), "E")
        XCTAssertEqual(ANSIStyleScanner.plainText(of: lines[3]), "F")
    }

    func testTracks24BitForeground() {
        let raw = "A\u{1B}[38;2;1;2;3mB\u{1B}[39mC"
        let line = ANSIStyleScanner.styledLines(from: raw)[0]
        XCTAssertNil(line[0].color)
        XCTAssertEqual(line[1].color, ANSIRGB(red: 1, green: 2, blue: 3))
        XCTAssertNil(line[2].color, "SGR 39 must restore the terminal default")
    }

    func testTracksDimAttribute() {
        let raw = "\u{1B}[2m□\u{1B}[22m■"
        let line = ANSIStyleScanner.styledLines(from: raw)[0]
        XCTAssertEqual(line.count, 2)
        XCTAssertTrue(line[0].isDim)
        XCTAssertFalse(line[1].isDim)
    }

    func testResolves256ColourPalette() {
        // 38;5;3 is the ANSI yellow slot; 38;5;196 the first cube red;
        // 38;5;240 the dark end of the grey ramp.
        let line = ANSIStyleScanner.styledLines(
            from: "\u{1B}[38;5;3mA\u{1B}[38;5;196mB\u{1B}[38;5;240mC")[0]
        XCTAssertEqual(line[0].color, ANSIRGB(red: 0x80, green: 0x80, blue: 0x00))
        XCTAssertEqual(line[1].color, ANSIRGB(red: 255, green: 0, blue: 0))
        XCTAssertEqual(line[2].color, ANSIRGB(red: 88, green: 88, blue: 88))
    }

    /// Cursor moves, erases, OSC hyperlinks and charset shifts must still be
    /// dropped so the heatmap glyphs stay adjacent.
    func testDropsNonSGRSequences() {
        let raw = "\u{1B}[2;5H\u{1B}[K\u{1B}]8;;https://example.com\u{07}X\u{1B}]8;;\u{07}"
            + "\u{1B}(B■\u{07}Y"
        let line = ANSIStyleScanner.styledLines(from: raw)[0]
        XCTAssertEqual(ANSIStyleScanner.plainText(of: line), "X■Y")
    }
}
