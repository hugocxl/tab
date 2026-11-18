import Foundation

/// A fenced code block's opening line: its marker (`` ` `` or `~`), how many, its info
/// string and indentation. The Markdown parser and the streaming tail filter both read
/// fences through this type, so they agree on where a code block starts and ends.
struct AgentMarkdownFence: Equatable {
    let marker: Character
    let count: Int
    let info: String
    let indent: Int

    /// The fence `line` opens, if any: three or more of one marker, indented by less than
    /// `maximumIndent` columns. A backtick fence's info string can't contain a backtick.
    static func opening(_ line: String, maximumIndent: Int = 4) -> AgentMarkdownFence? {
        let indent = indentation(line)
        guard indent < maximumIndent else { return nil }
        let text = line.drop { $0 == " " || $0 == "\t" }
        guard let first = text.first, first == "`" || first == "~" else { return nil }
        let count = text.prefix { $0 == first }.count
        guard count >= 3 else { return nil }
        let info = String(text.dropFirst(count)).trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
        guard first != "`" || !info.contains("`") else { return nil }
        return AgentMarkdownFence(marker: first, count: count, info: info, indent: indent)
    }

    /// Whether `line` closes this fence: at least as many of the same marker, and nothing
    /// after them but spaces. A shorter run or the other marker is code.
    func isClosed(by line: String, maximumIndent: Int = 4) -> Bool {
        guard Self.indentation(line) < maximumIndent else { return false }
        let text = line.drop { $0 == " " || $0 == "\t" }
        let run = text.prefix { $0 == marker }.count
        return run >= count && text.dropFirst(run).allSatisfy { $0 == " " || $0 == "\t" }
    }

    /// The fence still open after `lines`, read in order, or nil when every fence closed.
    /// Without a container the lines are top-level Markdown, read exactly as the parser
    /// reads them. `inContainers` also finds fences nested in list items, at any
    /// indentation, each closed by a line indented less than four columns past it, as the
    /// parser reads a list item's content once its indentation is removed.
    static func openFence<Lines: Sequence>(after lines: Lines, inContainers: Bool = false) -> AgentMarkdownFence?
        where Lines.Element: StringProtocol {
        var open: AgentMarkdownFence?
        for line in lines {
            let text = String(line)
            if let fence = open {
                if fence.isClosed(by: text, maximumIndent: inContainers ? fence.indent + 4 : 4) { open = nil }
            } else {
                open = opening(text, maximumIndent: inContainers ? .max : 4)
            }
        }
        return open
    }

    /// Leading whitespace in columns, tabs to the next multiple of four.
    static func indentation(_ line: String) -> Int {
        line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 - $0 % 4 : 1) }
    }
}
