import Foundation
import TabProtocol

/// The editor's decisions without views: what a file read means, what to do
/// when the file changes on disk, indentation and line positions.
public enum EditorModel {
    /// What the editor shows after reading its file.
    public enum Loaded: Equatable, Sendable {
        case text(String)
        /// Why the file can't be edited here.
        case message(String)
    }

    public static let binaryMessage = "This file is binary, so it can't be shown here."
    public static let tooLargeMessage = "This file is larger than 5 MB, so it can't be opened here."

    /// The editor's content for a read's reply.
    public static func loaded(_ reply: FilesReply) -> Loaded? {
        guard case .content(let file) = reply else { return nil }
        if file.content.contains("\0") { return .message(binaryMessage) }
        return .text(file.content)
    }

    /// The editor's message for a read that failed.
    public static func loadFailure(_ error: String) -> String {
        if error.contains("UTF-8") { return binaryMessage }
        if error.contains("5 MiB") || error.contains("5 MB") { return tooLargeMessage }
        return NativeErrors.friendly(error, folder: false)
    }

    /// What to do when the file on disk now holds `disk`.
    public enum DiskChange: Equatable, Sendable {
        /// Nothing new: it is what the editor last read or wrote.
        case ignore
        /// No unsaved changes: show the disk's text.
        case reload
        /// Unsaved changes: offer the disk's version or keeping yours.
        case offer
    }

    public static func diskChange(saved: String?, disk: String, dirty: Bool) -> DiskChange {
        if saved == disk { return .ignore }
        return dirty ? .offer : .reload
    }

    /// The indent width: the smallest run of leading spaces, 4 when none, 1–8.
    public static func indentWidth(_ text: String) -> Int {
        var smallest: Int?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let count = line.prefix { $0 == " " }.count
            if count > 0 { smallest = min(smallest ?? count, count) }
        }
        return min(max(smallest ?? 4, 1), 8)
    }

    /// Text inserted for Return after `prefix` (the line up to the caret):
    /// the line break, the line's leading whitespace, and one more indent
    /// after an opening bracket.
    public static func newline(after prefix: String, indent: Int, lineBreak: String = "\n") -> String {
        let leading = String(prefix.prefix { $0 == " " || $0 == "\t" })
        let trimmed = prefix.trimmingCharacters(in: .whitespaces)
        let extra = trimmed.hasSuffix("{") || trimmed.hasSuffix("[") || trimmed.hasSuffix("(") ? String(repeating: " ", count: indent) : ""
        return lineBreak + leading + extra
    }

    /// Spaces Tab inserts to reach the next indent stop from `column`.
    public static func tabSpaces(column: Int, indent: Int) -> String {
        String(repeating: " ", count: indent - column % max(indent, 1))
    }

    /// The UTF-16 offset of a one-based `line` and `column` in `text`,
    /// clamped to the text.
    public static func offset(line: Int, column: Int, in text: String) -> Int {
        let units = text.utf16
        var currentLine = 1
        var index = units.startIndex
        while currentLine < line, let newline = units[index...].firstIndex(of: 0x0A) {
            index = units.index(after: newline)
            currentLine += 1
        }
        let lineEnd = units[index...].firstIndex(of: 0x0A) ?? units.endIndex
        let lineText = String(text[index..<lineEnd])
        let characters = min(max(column - 1, 0), lineText.count)
        let prefix = lineText.prefix(characters)
        return units.distance(from: units.startIndex, to: index) + prefix.utf16.count
    }

    /// The pane title, marked while there are unsaved changes.
    public static func title(path: String, dirty: Bool) -> String {
        dirty ? "• \(NativePath.basename(path))" : NativePath.basename(path)
    }
}
