import Foundation
import TabProtocol

/// Files apps send for a session, such as an image dropped on a remote
/// terminal, kept in a private folder in the system's temporary folder (which
/// the system clears) under `<session>/`.
final class Uploads: @unchecked Sendable {
    let directory: URL
    /// The longest name kept, leaving room for a `-N` that tells copies apart.
    static let nameBytes = 240

    init(directory: URL = Uploads.systemDirectory()) {
        self.directory = directory
    }

    static func systemDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tab-uploads-\(geteuid())", isDirectory: true)
    }

    /// Appends a chunk to its file. After the last one the file takes its
    /// name, never replacing another, and its absolute path is returned.
    func receive(_ chunk: UploadChunk) throws -> ServerPath? {
        do {
            try chunk.validate()
        } catch {
            throw ServiceError(.badRequest, "The upload is too large")
        }
        let folder = directory.appendingPathComponent(chunk.session.description, isDirectory: true)
        do {
            try ownFolder(directory)
            try ownFolder(folder)
        } catch {
            throw failed(error)
        }
        let partial = folder.appendingPathComponent("\(chunk.upload).part")
        let descriptor = try open(partial, offset: chunk.offset)
        do {
            try append(chunk, to: descriptor)
            close(descriptor)
        } catch {
            close(descriptor)
            unlink(partial.path)
            throw error
        }
        guard chunk.last else { return nil }
        do {
            return ServerPath(try keep(partial, in: folder, name: Self.fileName(chunk.name)).path)
        } catch {
            unlink(partial.path)
            throw error
        }
    }

    /// Makes `url` a folder only this user can open, or checks that it is
    /// one. Other users can create names first in a shared temporary folder,
    /// so a link, a file, or someone else's folder is refused.
    private func ownFolder(_ url: URL) throws {
        if mkdir(url.path, 0o700) != 0, errno != EEXIST {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid() else {
            throw ServiceError(.persistenceFailed, "\(url.path) isn't this user's own folder")
        }
        if info.st_mode & 0o077 != 0 {
            chmod(url.path, 0o700)
        }
    }

    /// Starts the file at offset 0, otherwise continues it where it ended.
    private func open(_ partial: URL, offset: UInt64) throws -> Int32 {
        let flags = offset == 0 ? O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC : O_WRONLY | O_APPEND | O_CLOEXEC
        let descriptor = Darwin.open(partial.path, flags, 0o600)
        guard descriptor < 0 else { return descriptor }
        switch errno {
        case EEXIST: throw ServiceError(.badRequest, "The upload already started")
        case ENOENT: throw ServiceError(.badRequest, "The upload's first chunk is missing")
        default: throw failed(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
        }
    }

    private func append(_ chunk: UploadChunk, to descriptor: Int32) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw failed(POSIXError(.EIO)) }
        guard UInt64(info.st_size) == chunk.offset else {
            throw ServiceError(.badRequest, "The upload's chunks arrived out of order")
        }
        try chunk.bytes.withUnsafeBytes { buffer in
            guard var pointer = buffer.baseAddress else { return }
            var remaining = buffer.count
            while remaining > 0 {
                let written = write(descriptor, pointer, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw failed(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
                }
                pointer += written
                remaining -= written
            }
        }
    }

    /// Gives the finished file `name`, or `name-2`, `name-3`, … when taken.
    private func keep(_ partial: URL, in folder: URL, name: String) throws -> URL {
        for copy in 1...10_000 {
            let target = folder.appendingPathComponent(Self.numbered(name, copy))
            if renamex_np(partial.path, target.path, UInt32(RENAME_EXCL)) == 0 {
                return target.resolvingSymlinksInPath()
            }
            guard errno == EEXIST else { throw failed(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)) }
        }
        throw ServiceError(.badPath, "Too many uploads share this name")
    }

    /// The last component of `name`, without control characters, short
    /// enough to number. A name that would mean a folder is `upload`.
    static func fileName(_ name: String) -> String {
        let last = name.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        let cleaned = String(last.unicodeScalars.map { $0.properties.generalCategory == .control ? "_" : Character($0) })
            .trimmingCharacters(in: .whitespaces)
        if cleaned.isEmpty || cleaned == "." || cleaned == ".." { return "upload" }
        if cleaned.utf8.count <= nameBytes { return cleaned }
        let (stem, suffix) = split(cleaned)
        let kept = suffix.utf8.count <= 16 ? suffix : ""
        var shortened = ""
        for character in stem {
            if shortened.utf8.count + String(character).utf8.count + kept.utf8.count > nameBytes { break }
            shortened.append(character)
        }
        return shortened + kept
    }

    private static func numbered(_ name: String, _ copy: Int) -> String {
        guard copy > 1 else { return name }
        let (stem, suffix) = split(name)
        return "\(stem)-\(copy)\(suffix)"
    }

    /// `shot.png` is `("shot", ".png")`; `.env` and `notes` have no extension.
    private static func split(_ name: String) -> (String, String) {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return (name, "") }
        return (String(name[..<dot]), String(name[dot...]))
    }

    private func failed(_ error: Error) -> ServiceError {
        if let error = error as? ServiceError { return error }
        return ServiceError(.persistenceFailed, "Could not keep the upload: \(error.localizedDescription)")
    }
}
