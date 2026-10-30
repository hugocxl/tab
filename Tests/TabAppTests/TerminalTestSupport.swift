import AppKit
import Darwin
import TabClient
import TabCore
import TabProtocol
@testable import TabApp

enum TerminalFixtures {
    static func run(_ text: String, width: Int? = nil, fg: Color = .default, bg: Color = .default) -> Run {
        var style = Style()
        style.fg = fg
        style.bg = bg
        return Run(text: text, width: UInt16(width ?? text.count), style: style)
    }

    static func grid(_ rows: [[Run]], cols: UInt16 = 20, history: [[Run]] = [], cursor: Cursor = Cursor(),
                     prompts: [UInt16] = [], historyTotal: UInt64? = nil) -> RunGrid {
        let size = Size(cols: cols, rows: UInt16(rows.count))
        let screen = rows.enumerated().map { Row(index: UInt16($0.offset), runs: $0.element) }
        let older = history.map { Row(index: 0, runs: $0) }
        return RunGrid(snapshot: AttachSnapshot(
            channel: ChannelId(1), size: size, rows: screen, cursor: cursor, directory: "/tmp", prompts: prompts,
            history: older, historyTotal: historyTotal ?? UInt64(history.count)))
    }

    static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }

    static func output(_ label: String, cols: Int = 200) -> Run {
        let text = String((label + " " + String(repeating: "terminal output ", count: cols / 10 + 1)).prefix(cols))
        return run(text)
    }

    static func settings() -> TerminalSettings {
        var settings = TerminalSettings()
        settings.fontFamilies = ["Menlo"]
        settings.fontSize = 13
        return settings
    }
}

/// Records what a terminal view asks of its session.
@MainActor final class RecordingHost: TerminalViewHost {
    var isLive = true
    var isRemote = false
    var linkDirectory: String? = "/tmp"
    var inputs: [TerminalInput] = []
    var commands: [TerminalCommand] = []
    var scrolls: [Int] = []
    var drops: [[String]] = []

    func terminalView(_ view: TerminalView, send input: TerminalInput) { inputs.append(input) }
    func terminalView(_ view: TerminalView, scrollBy rows: Int) { scrolls.append(rows) }
    func terminalView(_ view: TerminalView, scrollTo offset: Int) {}
    func terminalView(_ view: TerminalView, perform command: TerminalCommand, at point: TerminalPoint?) {
        commands.append(command)
    }
    func terminalView(_ view: TerminalView, dropFiles paths: [String]) { drops.append(paths) }
    func terminalView(_ view: TerminalView, pasteImage png: Data) {}
    func terminalView(_ view: TerminalView, didChangeViewport viewport: Size) {}
    func terminalView(_ view: TerminalView, didChangeFocus focused: Bool) {}
}
