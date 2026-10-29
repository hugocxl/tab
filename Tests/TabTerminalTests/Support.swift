import Foundation
import TabProtocol
@testable import TabTerminal

func makeTerminal(cols: UInt16 = 20, rows: UInt16 = 6, budget: Int = 1 << 20) throws -> Terminal {
    try Terminal(size: Size(cols: cols, rows: rows), historyBudgetBytes: budget)
}

func text(_ runs: [Run]) -> String {
    runs.map(\.text).joined()
}

func lines(_ rows: [Row]) -> [String] {
    rows.map { text($0.runs) }
}

extension Terminal {
    func feed(_ text: String) {
        feed(Data(text.utf8))
    }

    func screenLines() throws -> [String] {
        lines(try fullRender())
    }
}

func numbered(_ terminal: Terminal, _ range: ClosedRange<Int>) {
    terminal.feed(range.map { "\($0)\r\n" }.joined())
}
