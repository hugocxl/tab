import XCTest
@testable import TabProtocol

final class ScreenCodecTests: XCTestCase {
    private func frame(rows: [Row], graphics: Graphics? = nil) -> ScreenFrame {
        var modes = Modes()
        modes.applicationCursorKeys = true
        modes.bracketedPaste = true
        return ScreenFrame(size: Size(cols: 80, rows: 24), seq: .max, reset: true, rows: rows,
                           cursor: Cursor(shape: .hollow, row: 23, col: 79, visible: false), modes: modes,
                           graphics: graphics, historyRows: 123_456_789)
    }

    func testFrameRoundTripsEveryField() throws {
        let original = frame(rows: Samples.rows, graphics: Samples.graphics)
        XCTAssertEqual(try ScreenCodec.decode(ScreenCodec.encode(original)), original)
        let decoded = try ScreenCodec.decode(ScreenCodec.encode(original))
        XCTAssertEqual(decoded.graphics?.placements.first?.offset.y, 2)
        XCTAssertEqual(decoded.graphics?.placements.first?.source.height, 2)
    }

    func testEveryStyleFieldAndColorRoundTrips() throws {
        var runs: [Run] = []
        let colors: [Color] = [.default, .indexed(0), .indexed(255), .rgb(0, 0, 0), .rgb(255, 254, 253)]
        for color in colors {
            for underline in [Underline.none, .single, .double, .curly, .dotted, .dashed] {
                var style = Samples.style
                style.fg = color
                style.bg = color
                style.underlineColor = color
                style.underline = underline
                runs.append(Run(text: "x", width: 1, style: style))
            }
        }
        for flag in 0 ..< 7 {
            var style = Style()
            switch flag {
            case 0: style.bold = true
            case 1: style.italic = true
            case 2: style.invisible = true
            case 3: style.overline = true
            case 4: style.inverse = true
            case 5: style.strikethrough = true
            default: style.faint = true
            }
            runs.append(Run(text: "y", width: 1, style: style))
        }
        runs.append(Run(text: "", width: 0))
        XCTAssertEqual(try ScreenCodec.decodeRuns(ScreenCodec.encodeRuns(runs)), runs)
    }

    func testUnicodeAndWideCells() throws {
        let rows = [
            Row(index: 0, runs: [Run(text: "漢字かな", width: 8), Run(text: "👩‍👩‍👧‍👦", width: 2),
                                 Run(text: "e\u{301}", width: 1), Run(text: "\u{0}\u{7f}", width: 2)]),
            Row(index: 65535, runs: []),
        ]
        XCTAssertEqual(try ScreenCodec.decodeRows(ScreenCodec.encodeRows(rows)), rows)
        XCTAssertEqual(try ScreenCodec.decodeRow(ScreenCodec.encodeRow(rows[0])), rows[0])
    }

    func testEmptyFrame() throws {
        let empty = ScreenFrame(size: Size(cols: 1, rows: 1), seq: 0, reset: false, rows: [], cursor: Cursor())
        let data = ScreenCodec.encode(empty)
        XCTAssertEqual(try ScreenCodec.decode(data), empty)
        XCTAssertLessThan(data.count, 40)
        XCTAssertEqual(try ScreenCodec.decodeRows(ScreenCodec.encodeRows([])), [])
        let noGraphics = Graphics(cell: CellSize(width: 1, height: 1))
        XCTAssertEqual(try ScreenCodec.decodeGraphics(ScreenCodec.encodeGraphics(noGraphics)), noGraphics)
    }

    func testLargeFrame() throws {
        var generator = SeededGenerator(seed: 7)
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz 0123456789éü日本🙂")
        let rows = (0 ..< 1024).map { index in
            Row(index: UInt16(index), runs: (0 ..< 32).map { _ in
                let text = String((0 ..< 8).map { _ in alphabet.randomElement(using: &generator) ?? "a" })
                var style = Style()
                style.fg = .indexed(UInt8.random(in: 0 ... 255, using: &generator))
                style.bold = Bool.random(using: &generator)
                return Run(text: text, width: 8, style: style)
            })
        }
        let image = GraphicImage(id: 1, generation: 1, width: 256, height: 256, rgba: Data(count: 256 * 256 * 4))
        let large = frame(rows: rows, graphics: Graphics(cell: CellSize(width: 8, height: 16), images: [image]))
        let data = ScreenCodec.encode(large)
        XCTAssertEqual(try ScreenCodec.decode(data), large)
        XCTAssertLessThan(data.count, Limits.maxFrame)
    }

    func testRejectsOtherVersionsTruncationAndTrailingBytes() throws {
        var data = ScreenCodec.encode(frame(rows: Samples.rows, graphics: Samples.graphics))
        for length in 0 ..< data.count {
            XCTAssertThrowsError(try ScreenCodec.decode(data.prefix(length)), "prefix \(length)")
        }
        data.append(0)
        XCTAssertThrowsError(try ScreenCodec.decode(data)) { error in
            XCTAssertEqual(error as? ScreenCodecError, .trailingBytes)
        }
        data[0] = 2
        XCTAssertThrowsError(try ScreenCodec.decode(data)) { error in
            XCTAssertEqual(error as? ScreenCodecError, .unsupportedVersion(2))
        }
    }

    func testRandomAndMutatedBytesNeverCrashTheDecoder() {
        var generator = SeededGenerator(seed: 42)
        let valid = ScreenCodec.encode(frame(rows: Samples.rows, graphics: Samples.graphics))
        for _ in 0 ..< 5000 {
            var data: Data
            if Bool.random(using: &generator) {
                data = valid
                for _ in 0 ..< Int.random(in: 1 ... 4, using: &generator) {
                    data[Int.random(in: 0 ..< data.count, using: &generator)] = UInt8.random(in: 0 ... 255,
                                                                                         using: &generator)
                }
            } else {
                data = Data([1] + (0 ..< Int.random(in: 0 ..< 200, using: &generator)).map { _ in
                    UInt8.random(in: 0 ... 255, using: &generator)
                })
            }
            _ = try? ScreenCodec.decode(data)
            _ = try? ScreenCodec.decodeRows(data)
            _ = try? ScreenCodec.decodeGraphics(data)
        }
    }

    func testHugeCountsDoNotAllocate() {
        // Version, then a row count of 2^62 with nothing after it.
        let data = Data([1, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x40])
        XCTAssertThrowsError(try ScreenCodec.decodeRows(data))
        let overflow = Data([1] + [UInt8](repeating: 0xff, count: 10) + [1])
        XCTAssertThrowsError(try ScreenCodec.decodeRows(overflow))
    }

    func testRowsAndGraphicsTravelInJSON() throws {
        let page = HistoryPage(rows: Samples.rows, totalRows: 2)
        XCTAssertEqual(try WireJSON.decode(HistoryPage.self, from: WireJSON.encode(page)), page)
        XCTAssertThrowsError(try WireJSON.decode(HistoryPage.self, from: Data(#"{"rows":["AAAA"],"totalRows":1}"#.utf8)))
    }
}
