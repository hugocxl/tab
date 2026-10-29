import Foundation
import TabProtocol

/// Text for pastes and drops.
public enum TerminalPaste {
    /// Absolute paths quoted for a shell and joined with spaces: single
    /// quotes, or `$'…'` with escapes when a path holds control characters.
    /// `nil` when a path is relative or holds a NUL.
    public static func quotedPaths(_ paths: [String]) -> String? {
        var text = ""
        for path in paths {
            guard path.hasPrefix("/"), !path.utf8.contains(0) else { return nil }
            if !text.isEmpty { text += " " }
            let ansi = path.unicodeScalars.contains { $0.isASCII && ($0.value < 0x20 || $0.value == 0x7F) }
            text += ansi ? "$'" : "'"
            for scalar in path.unicodeScalars {
                switch (ansi, scalar) {
                case (true, _) where scalar.isASCII && (scalar.value < 0x20 || scalar.value == 0x7F):
                    text += String(format: "\\x%02x", scalar.value)
                case (true, "'"), (true, "\\"):
                    text += "\\" + String(scalar)
                case (false, "'"):
                    text += "'\\''"
                default:
                    text.unicodeScalars.append(scalar)
                }
            }
            text += "'"
        }
        return text
    }

    /// Splits a paste into chunks the protocol accepts, never inside a UTF-8
    /// sequence or a CRLF pair, so each chunk is a complete paste.
    public static func chunks(_ text: String, limit: Int = Limits.maxInput) -> [String] {
        let bytes = Array(text.utf8)
        guard bytes.count > limit else { return text.isEmpty ? [] : [text] }
        var result: [String] = []
        var start = 0
        while start < bytes.count {
            var end = min(bytes.count, start + limit)
            if end < bytes.count {
                while end > start, bytes[end] & 0xC0 == 0x80 { end -= 1 }
                if end > start + 1, bytes[end - 1] == 0x0D, bytes[end] == 0x0A { end -= 1 }
                if end == start { end = min(bytes.count, start + limit) }
            }
            result.append(String(decoding: bytes[start..<end], as: UTF8.self))
            start = end
        }
        return result
    }
}
