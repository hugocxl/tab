import Foundation
import TabProtocol

internal func agentUpdateClaudeFileChange(_ activity: inout AgentToolActivity, result: Any?) {
    guard activity.presentation == .fileChange, var details = activity.fileChangeDetails else { return }
    guard let record = result as? [String: Any], let patches = record["structuredPatch"] as? [[String: Any]],
          let path = record["filePath"] as? String else {
        details.diff = activity.output
        activity.fileChangeDetails = details
        return
    }
    var hunks = patches
    var oldPath = path
    if hunks.isEmpty, record["type"] as? String == "create", let content = record["content"] as? String, !content.isEmpty {
        var lines = content.components(separatedBy: "\n")
        if content.hasSuffix("\n") { lines.removeLast() }
        let count = lines.count
        lines = lines.map { "+" + $0 }
        if !content.hasSuffix("\n") { lines.append("\\ No newline at end of file") }
        hunks = [["oldStart": 1, "oldLines": 0, "newStart": 1, "newLines": count, "lines": lines]]
        oldPath = "/dev/null"
    }
    func quoted(_ path: String) -> String {
        guard path.utf8.contains(where: { $0 < 32 || $0 > 126 || $0 == 34 || $0 == 92 }) else { return path }
        let escapes: [UInt8: String] = [7: "\\a", 8: "\\b", 9: "\\t", 10: "\\n", 11: "\\v", 12: "\\f", 13: "\\r", 34: "\\\"", 92: "\\\\"]
        return "\"" + path.utf8.map { byte in
            escapes[byte] ?? ((32...126).contains(byte) ? String(UnicodeScalar(byte)) : String(format: "\\%03o", byte))
        }.joined() + "\""
    }
    var lines = ["--- " + quoted(oldPath), "+++ " + quoted(path)]
    for hunk in hunks {
        guard let oldStart = hunk["oldStart"] as? Int, let oldCount = hunk["oldLines"] as? Int,
              let newStart = hunk["newStart"] as? Int, let newCount = hunk["newLines"] as? Int,
              let content = hunk["lines"] as? [String], oldStart >= 0, newStart >= 0, oldCount >= 0, newCount >= 0 else { continue }
        lines.append("@@ -\(oldCount == 0 ? oldStart - 1 : oldStart),\(oldCount) +\(newCount == 0 ? newStart - 1 : newStart),\(newCount) @@")
        lines += content
    }
    details.diff = hunks.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    activity.fileChangeDetails = details
    if let diff = details.diff, !diff.isEmpty {
        activity.fileChanges = [.init(path: details.fileName, diff: diff, kind: record["type"] as? String)]
    }
}
