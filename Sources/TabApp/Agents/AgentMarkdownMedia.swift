import AppKit
import UniformTypeIdentifiers

/// One image, video or audio reference of an assistant message: a Markdown image
/// (`![alt](src)`) or a bare media URL or file path on a line of its own.
struct AgentMarkdownMedia: Hashable {
    enum Kind: Hashable { case image, video, audio }

    /// The destination as written: an http(s) URL, a `data:` URI or a file path.
    var source: String
    /// The alternative text; empty for bare links.
    var alt: String
    var kind: Kind

    init(source: String, alt: String = "", kind: Kind) {
        self.source = source
        self.alt = alt
        self.kind = kind
    }

    /// The tooltip and accessibility label: the alt text, else the file name.
    var name: String {
        let alt = alt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !alt.isEmpty { return alt }
        switch AgentMediaSource(source) {
        case .data?: return kind == .image ? "Image" : kind == .video ? "Video" : "Audio"
        case .remote(let url)?:
            let last = url.lastPathComponent
            return last.isEmpty || last == "/" ? (url.host ?? url.absoluteString) : last
        case .file(let path)?: return (path as NSString).lastPathComponent
        case nil: return source
        }
    }

    /// The file name Save Image suggests.
    var fileName: String {
        switch AgentMediaSource(source) {
        case .remote(let url)? where !url.lastPathComponent.isEmpty && url.lastPathComponent != "/": return url.lastPathComponent
        case .file(let path)?: return (path as NSString).lastPathComponent
        default:
            let suffix = UTType(mimeType: mimeType)?.preferredFilenameExtension ?? "png"
            return (kind == .image ? "image" : kind == .video ? "video" : "audio") + "." + suffix
        }
    }

    /// The MIME type the source most likely has, from its `data:` header or extension.
    var mimeType: String {
        if case .data(let raw)? = AgentMediaSource(source), let mime = AgentMediaSource.dataMIMEType(raw) { return mime }
        let path = AgentMediaSource(source)?.path ?? source
        let suffix = (path as NSString).pathExtension.lowercased()
        return UTType(filenameExtension: suffix)?.preferredMIMEType ?? (kind == .image ? "image/png" : "application/octet-stream")
    }

    /// The link Copy Link and Open Link act on; nil for inline `data:` payloads.
    var link: String? {
        switch AgentMediaSource(source) {
        case .remote(let url)?: return url.absoluteString
        case .file(let path)?: return path
        default: return nil
        }
    }

    // MARK: Parsing

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "tif", "tiff", "heic", "heif", "avif", "ico", "svg"]
    static let videoExtensions: Set<String> = ["mp4", "m4v", "mov", "webm", "ogv"]
    static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "oga", "ogg", "flac", "opus"]

    /// The media kind a path extension names, if any.
    static func kind(extension value: String) -> Kind? {
        let value = value.lowercased()
        if imageExtensions.contains(value) { return .image }
        if videoExtensions.contains(value) { return .video }
        if audioExtensions.contains(value) { return .audio }
        return nil
    }

    /// The media of a paragraph made only of images (`![alt](src)`, separated by
    /// whitespace) and bare media links; nil when anything else, including an
    /// unfinished image still being typed, is part of the paragraph.
    static func paragraph(_ content: String) -> [AgentMarkdownMedia]? {
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 32 * 1024 * 1024 else { return nil }
        var result: [AgentMarkdownMedia] = []
        var index = text.startIndex
        while index < text.endIndex {
            if text[index].isWhitespace { index = text.index(after: index); continue }
            if let image = image(in: text, at: index) {
                result.append(image.media)
                index = image.end
                continue
            }
            let end = text[index...].firstIndex(where: \.isWhitespace) ?? text.endIndex
            guard let bare = bare(String(text[index..<end])) else { return nil }
            result.append(bare)
            index = end
        }
        return result.isEmpty ? nil : result
    }

    /// A bare http(s) URL, `<autolink>` or file path whose extension names media.
    static func bare(_ token: String) -> AgentMarkdownMedia? {
        var token = token
        if token.hasPrefix("<"), token.hasSuffix(">"), token.count > 2 { token = String(token.dropFirst().dropLast()) }
        guard !token.isEmpty, token.rangeOfCharacter(from: CharacterSet(charactersIn: "`*[]()<>\"'|\\")) == nil else { return nil }
        let lower = token.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            guard case .remote(let url)? = AgentMediaSource(token), let kind = kind(extension: url.pathExtension) else { return nil }
            return AgentMarkdownMedia(source: token, kind: kind)
        }
        guard !token.contains(":"), !token.hasPrefix("~"), let kind = kind(extension: (token as NSString).pathExtension),
              !(token as NSString).deletingPathExtension.hasSuffix("/"), (token as NSString).lastPathComponent.count > 1 + (token as NSString).pathExtension.count else { return nil }
        return AgentMarkdownMedia(source: token, kind: kind)
    }

    /// `![alt](destination "title")` starting at `start`, with the index after it.
    private static func image(in text: String, at start: String.Index) -> (media: AgentMarkdownMedia, end: String.Index)? {
        guard text[start...].hasPrefix("![") else { return nil }
        var index = text.index(start, offsetBy: 2)
        var alt = ""
        var depth = 0
        while index < text.endIndex {
            let character = text[index]
            if character == "\\", text.index(after: index) < text.endIndex {
                index = text.index(after: index)
                alt.append(text[index])
                index = text.index(after: index)
                continue
            }
            if character == "[" { depth += 1 }
            if character == "]" {
                if depth == 0 { break }
                depth -= 1
            }
            alt.append(character)
            index = text.index(after: index)
        }
        guard index < text.endIndex else { return nil }
        index = text.index(after: index)
        guard index < text.endIndex, text[index] == "(" else { return nil }
        index = text.index(after: index)
        while index < text.endIndex, text[index] == " " || text[index] == "\t" { index = text.index(after: index) }
        guard index < text.endIndex else { return nil }
        var destination = ""
        if text[index] == "<" {
            guard let close = text[index...].firstIndex(of: ">") else { return nil }
            destination = String(text[text.index(after: index)..<close])
            guard !destination.contains("\n") else { return nil }
            index = text.index(after: close)
        } else {
            var parentheses = 0
            while index < text.endIndex {
                let character = text[index]
                if character.isWhitespace { break }
                if character == "(" { parentheses += 1 }
                if character == ")" {
                    if parentheses == 0 { break }
                    parentheses -= 1
                }
                destination.append(character)
                index = text.index(after: index)
            }
        }
        while index < text.endIndex, text[index] == " " || text[index] == "\t" { index = text.index(after: index) }
        guard index < text.endIndex else { return nil }
        if let quote = text[index] == "\"" ? Character("\"") : text[index] == "'" ? Character("'") : nil {
            guard let close = text[text.index(after: index)...].firstIndex(of: quote) else { return nil }
            index = text.index(after: close)
            while index < text.endIndex, text[index] == " " || text[index] == "\t" { index = text.index(after: index) }
        }
        guard index < text.endIndex, text[index] == ")", let source = AgentMediaSource(destination) else { return nil }
        let kind: Kind
        switch source {
        case .data(let raw):
            let mime = AgentMediaSource.dataMIMEType(raw) ?? ""
            kind = mime.hasPrefix("video/") ? .video : mime.hasPrefix("audio/") ? .audio : .image
        default: kind = Self.kind(extension: (source.path as NSString).pathExtension).flatMap { $0 == .image ? nil : $0 } ?? .image
        }
        let media = AgentMarkdownMedia(source: destination, alt: alt.trimmingCharacters(in: .whitespacesAndNewlines), kind: kind)
        return (media, text.index(after: index))
    }
}

/// Where a media reference's bytes come from. Other schemes, such as `javascript:`
/// or `mailto:`, are not media and stay ordinary text.
enum AgentMediaSource: Hashable {
    /// A complete `data:` URI.
    case data(String)
    case remote(URL)
    /// A project file path, absolute or relative to the project folder.
    case file(String)

    init?(_ raw: String) {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains("\0") else { return nil }
        let lower = value.prefix(8).lowercased()
        if lower.hasPrefix("data:") {
            guard let mime = Self.dataMIMEType(value), mime.hasPrefix("image/") || mime.hasPrefix("video/") || mime.hasPrefix("audio/") else { return nil }
            self = .data(value)
            return
        }
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            guard let url = URL(string: value), url.host?.isEmpty == false else { return nil }
            self = .remote(url)
            return
        }
        if lower.hasPrefix("file://") {
            guard let url = URL(string: value), url.isFileURL, !url.path.isEmpty else { return nil }
            self = .file(url.path)
            return
        }
        if value.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*:"#, options: .regularExpression) != nil { return nil }
        self = .file(value.removingPercentEncoding ?? value)
    }

    /// The path component the media kind is inferred from.
    var path: String {
        switch self {
        case .data: return ""
        case .remote(let url): return url.path
        case .file(let path): return path
        }
    }

    /// The MIME type of a `data:` URI's header, lowercased.
    static func dataMIMEType(_ raw: String) -> String? {
        guard raw.prefix(5).lowercased() == "data:", let comma = raw.prefix(512).firstIndex(of: ",") else { return nil }
        let header = raw[raw.index(raw.startIndex, offsetBy: 5)..<comma]
        let mime = header.split(separator: ";", maxSplits: 1).first.map { String($0).lowercased() } ?? ""
        return mime.isEmpty ? "text/plain" : mime
    }
}

extension NSAttributedString.Key {
    /// The raw destination of an inline Markdown image, on its alternative text.
    static let agentInlineMediaSource = NSAttributedString.Key("TabAgentInlineMediaSource")
    /// The `AgentMarkdownMedia` an inline thumbnail attachment shows.
    static let agentInlineMedia = NSAttributedString.Key("TabAgentInlineMedia")
}
