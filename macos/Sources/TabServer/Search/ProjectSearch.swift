import Foundation
import TabProtocol

/// Go to File and Find in Files for a project folder, with `rg`, falling
/// back to `git ls-files` for file lists when `rg` isn't installed.
struct ProjectSearch: Sendable {
    /// Matches kept across all files before the result is marked truncated.
    static let maxTotalMatches = 10_000
    /// Characters of a matching line kept as its preview.
    static let maxPreviewCharacters = 1_000
    static let maxOutput = 64 * 1024 * 1024

    var lookup: ExecutableLookup

    /// Every file in `directory`, relative to it, sorted.
    func files(in directory: String, limit: Int) throws -> FileList {
        let listed = rgFiles(in: directory) ?? gitFiles(in: directory) ?? ([], false)
        var paths = Array(Set(listed.paths)).sorted()
        var truncated = listed.truncated
        if paths.count > limit {
            paths.removeSubrange(limit...)
            truncated = true
        }
        return FileList(paths: paths, truncated: truncated)
    }

    private func rgFiles(in directory: String) -> (paths: [String], truncated: Bool)? {
        guard let rg = lookup("rg") else { return nil }
        return listed(rg, ["--files", "--hidden", "--null", "--glob", "!.git"], directory: directory)
    }

    private func gitFiles(in directory: String) -> (paths: [String], truncated: Bool)? {
        guard let git = lookup("git") else { return nil }
        return listed(git, ["ls-files", "-z", "--cached", "--others", "--exclude-standard"], directory: directory,
                      environment: GitCommand.environment())
    }

    private func listed(_ program: String, _ arguments: [String], directory: String,
                        environment: [String: String] = ProcessInfo.processInfo.environment)
        -> (paths: [String], truncated: Bool)? {
        guard let output = try? ProcessRunner.run(program, arguments, directory: directory, environment: environment,
                                                   timeout: 30, outputLimit: Self.maxOutput,
                                                   truncateStdout: Self.maxOutput),
              output.succeeded || output.truncated else { return nil }
        var records = output.stdout.split(separator: 0, omittingEmptySubsequences: true)
        if output.truncated, !records.isEmpty { records.removeLast() }
        let paths = records.map { record -> String in
            let path = String(decoding: record, as: UTF8.self)
            return path.hasPrefix("./") ? String(path.dropFirst(2)) : path
        }
        return (paths.filter { !$0.isEmpty }, output.truncated)
    }

    /// Find in Files.
    func content(in directory: String, query: ContentSearchQuery) throws -> ContentSearchResult {
        guard let rg = lookup("rg") else {
            throw ServiceError(.badRequest, "Find in Files needs ripgrep (rg). Install it with `brew install ripgrep`.")
        }
        let perFile = Int(min(query.maxMatchesPerFile, UInt32(Limits.maxMatchesPerFile)))
        var arguments = ["--json", "--hidden", "--glob", "!.git", "--max-count", String(perFile)]
        if !query.caseSensitive { arguments.append("--ignore-case") }
        if !query.regex { arguments.append("--fixed-strings") }
        arguments += ["-e", query.query]
        let output = try ProcessRunner.run(rg, arguments, directory: directory, timeout: 60,
                                           outputLimit: Self.maxOutput, truncateStdout: Self.maxOutput)
        if output.status == 2, !output.truncated, output.stdout.isEmpty {
            let message = output.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ServiceError(.badRequest, message.isEmpty ? "ripgrep failed" : message)
        }
        var result = Self.parse(output.stdout, maxMatchesPerFile: perFile)
        if output.truncated { result.truncated = true }
        return result
    }

    /// Parses `rg --json` output into matches grouped by file, one match per
    /// line with every submatch's range, columns in characters.
    static func parse(_ output: Data, maxMatchesPerFile: Int = Limits.maxMatchesPerFile,
                      maxTotal: Int = maxTotalMatches) -> ContentSearchResult {
        var files: [FileMatches] = []
        var indexByPath: [String: Int] = [:]
        var total = 0
        var truncated = false
        for record in output.split(separator: UInt8(ascii: "\n")) {
            guard let object = try? JSONSerialization.jsonObject(with: record) as? [String: Any],
                  object["type"] as? String == "match",
                  let data = object["data"] as? [String: Any],
                  let pathBytes = (data["path"] as? [String: Any]).flatMap(field),
                  let lines = (data["lines"] as? [String: Any]).flatMap(field),
                  let firstLine = (data["line_number"] as? NSNumber)?.uint32Value,
                  let submatches = data["submatches"] as? [[String: Any]] else { continue }
            let path = String(decoding: pathBytes, as: UTF8.self)
            let found = matches(lines: [UInt8](lines), firstLine: firstLine, submatches: submatches)
            guard !found.isEmpty else { continue }
            let index: Int
            if let existing = indexByPath[path] {
                index = existing
            } else {
                index = files.count
                indexByPath[path] = index
                files.append(FileMatches(path: path, matches: []))
            }
            for match in found {
                if files[index].matches.count >= maxMatchesPerFile || total >= maxTotal {
                    truncated = true
                    break
                }
                if let last = files[index].matches.last, last.line == match.line {
                    files[index].matches[files[index].matches.count - 1].ranges += match.ranges
                    continue
                }
                files[index].matches.append(match)
                total += 1
            }
        }
        return ContentSearchResult(files: files.filter { !$0.matches.isEmpty }, truncated: truncated)
    }

    /// One match per submatch, on the line of the multi-line block it starts in.
    private static func matches(lines: [UInt8], firstLine: UInt32, submatches: [[String: Any]]) -> [ContentMatch] {
        var lineStarts = [0]
        for (index, byte) in lines.enumerated() where byte == UInt8(ascii: "\n") { lineStarts.append(index + 1) }
        var result: [ContentMatch] = []
        for submatch in submatches {
            guard let start = (submatch["start"] as? NSNumber)?.intValue, start >= 0, start <= lines.count else {
                continue
            }
            let end = min(max((submatch["end"] as? NSNumber)?.intValue ?? start, start), lines.count)
            let lineIndex = (lineStarts.lastIndex { $0 <= start }) ?? 0
            let lineStart = lineStarts[lineIndex]
            var lineEnd = lineIndex + 1 < lineStarts.count ? lineStarts[lineIndex + 1] - 1 : lines.count
            if lineEnd > lineStart, lines[lineEnd - 1] == UInt8(ascii: "\r") { lineEnd -= 1 }
            let lineBytes = Array(lines[lineStart ..< max(lineStart, lineEnd)])
            let startColumn = characters(lineBytes, upTo: start - lineStart)
            let endColumn = characters(lineBytes, upTo: min(end, lineEnd) - lineStart)
            var preview = String(decoding: lineBytes, as: UTF8.self)
            let previewCount = preview.unicodeScalars.count
            if previewCount > maxPreviewCharacters {
                preview = String(String.UnicodeScalarView(preview.unicodeScalars.prefix(maxPreviewCharacters)))
            }
            let limit = min(previewCount, maxPreviewCharacters)
            let rangeStart = min(startColumn, limit)
            let ranges = rangeStart < limit
                ? [MatchRange(start: UInt32(rangeStart), end: UInt32(min(max(endColumn, rangeStart), limit)))] : []
            result.append(ContentMatch(line: firstLine + UInt32(lineIndex), column: UInt32(startColumn + 1),
                                       preview: preview, ranges: ranges))
        }
        return result
    }

    /// Unicode scalars in the first `bytes` bytes of a UTF-8 line.
    static func characters(_ line: [UInt8], upTo bytes: Int) -> Int {
        guard bytes > 0 else { return 0 }
        return String(decoding: line[0 ..< min(bytes, line.count)], as: UTF8.self).unicodeScalars.count
    }

    /// ripgrep sends text as `text`, or non-UTF-8 bytes base64 encoded in `bytes`.
    private static func field(_ value: [String: Any]) -> Data? {
        if let text = value["text"] as? String { return Data(text.utf8) }
        guard let encoded = value["bytes"] as? String else { return nil }
        return Data(base64Encoded: encoded)
    }

    /// The names among `names` in `directory` that Git ignores; empty
    /// outside a repository or without `git`.
    func ignoredNames(in directory: String, _ names: [String]) -> Set<String> {
        guard !names.isEmpty, let git = lookup("git") else { return [] }
        var input = Data()
        for name in names {
            input.append(contentsOf: name.utf8)
            input.append(0)
        }
        guard let output = try? ProcessRunner.run(
            git, ["--no-pager", "--no-literal-pathspecs", "check-ignore", "-z", "--stdin"], directory: directory,
            environment: GitCommand.environment(), input: input
        ), output.status == 0 || output.status == 1 else { return [] }
        return Set(output.stdout.split(separator: 0).map { String(decoding: $0, as: UTF8.self) })
    }
}
