import Foundation
import TabProtocol

/// A shell Claude left running in the background writes its output to a file it names
/// in the tool's result. Its one step is the command with the end of that file, so a
/// click on its row shows what it's doing now.
enum AgentBackgroundShell {
    /// How much of the output's end a step carries.
    static let tailBytes = 64 * 1024

    /// The output file the tool's result names, when it is the task's own.
    static func outputFile(in output: String?, task: String) -> URL? {
        guard let output, let marker = output.range(of: "Output is being written to: ")
                ?? output.range(of: "Output was written to: ") else { return nil }
        let rest = output[marker.upperBound...]
        let path = String(rest.prefix { !$0.isWhitespace && !$0.isNewline })
        let trimmed = path.hasSuffix(".") ? String(path.dropLast()) : path
        let url = URL(fileURLWithPath: trimmed)
        guard trimmed.hasPrefix("/"), url.lastPathComponent == task + ".output",
              url.deletingLastPathComponent().lastPathComponent == "tasks" else { return nil }
        return url
    }

    /// The shell's tool item with the end of its output file in place of its result.
    static func step(_ item: AgentChatItem, task: AgentSubagent) -> AgentChatItem {
        guard let file = outputFile(in: item.tool?.output, task: task.id), let tail = try? readTail(file) else { return item }
        var item = item
        var tool = item.tool ?? AgentToolActivity(name: "Bash")
        tool.output = tail.isEmpty ? "No output yet." : tail
        tool.outputIsJSON = false
        tool.fullOutputBytes = nil
        switch task.status {
        case .running: tool.status = .running
        case .completed: tool.status = .completed
        case .failed: tool.status = .failed
        case .stopped: tool.status = .interrupted
        }
        item.tool = tool
        item.detail = tool.output
        item.isComplete = task.status != .running
        return item
    }

    /// The file's last `tailBytes`, starting at a whole line when it was cut.
    static func readTail(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try handle.seek(toOffset: start)
        var data = try handle.readToEnd() ?? Data()
        if start > 0, let newline = data.firstIndex(of: UInt8(ascii: "\n")) {
            data = data[data.index(after: newline)...]
        }
        let text = String(decoding: data, as: UTF8.self)
        return start > 0 ? "[Earlier output omitted]\n" + text : text
    }
}
