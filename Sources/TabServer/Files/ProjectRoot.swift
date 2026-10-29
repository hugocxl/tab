import Darwin
import Foundation
import TabProtocol

/// An open file descriptor, closed when the last reference goes away.
final class Descriptor: @unchecked Sendable {
    let fd: Int32

    init(_ fd: Int32) { self.fd = fd }

    deinit { close(fd) }
}

enum FilesFailure {
    static func path(_ message: String) -> ServiceError { ServiceError(.badPath, message) }

    static func system(_ operation: String, _ code: Int32 = errno) -> ServiceError {
        switch code {
        case ENOENT: ServiceError(.badPath, "\(operation): no such file or folder")
        case EEXIST: ServiceError(.badPath, "\(operation): a file with that name already exists")
        case ENOTDIR: ServiceError(.badPath, "\(operation): not a folder")
        case EISDIR: ServiceError(.badPath, "\(operation): is a folder")
        case EACCES, EPERM: ServiceError(.badPath, "\(operation): permission denied")
        case ELOOP: ServiceError(.badPath, "Path changed during the file operation; retry")
        default: ServiceError(.badPath, "\(operation): \(String(cString: strerror(code)))")
        }
    }
}

/// A project folder opened once, through which every path is resolved one
/// component at a time with `openat` and `O_NOFOLLOW`, so neither `..` nor a
/// symbolic link (even one swapped in during the operation) reaches outside it.
final class ProjectRoot: @unchecked Sendable {
    /// The folder with symbolic links resolved.
    let path: String
    /// The folder as the catalog names it.
    let logical: String
    let directory: Descriptor

    /// A resolved path: an entry `name` inside the open folder `parent`.
    struct Target {
        var parent: Descriptor
        /// `.` when the target is `parent` itself.
        var name: String
        /// Components relative to the project folder.
        var components: [String]

        var relative: String { components.joined(separator: "/") }
        var serverPath: ServerPath { ServerPath(relative) }

        func stat() throws -> Darwin.stat {
            var info = Darwin.stat()
            guard fstatat(parent.fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw FilesFailure.system(relative.isEmpty ? "." : relative)
            }
            if info.st_mode & S_IFMT == S_IFLNK {
                throw FilesFailure.path("Path changed during the file operation; retry")
            }
            return info
        }

        func openDirectory() throws -> Descriptor {
            let fd = openat(parent.fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw FilesFailure.system(relative.isEmpty ? "." : relative) }
            return Descriptor(fd)
        }
    }

    init(path: String) throws {
        logical = path
        guard let resolved = realpath(path, nil) else {
            throw FilesFailure.system(path)
        }
        self.path = String(cString: resolved)
        free(resolved)
        let fd = open(self.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw FilesFailure.system(path) }
        directory = Descriptor(fd)
    }

    /// Resolves a path relative to the project, following links only while
    /// they stay inside it. The last component may not exist yet.
    func resolve(_ path: String) throws -> Target {
        if path.hasPrefix("/") || path.utf8.contains(0) {
            throw FilesFailure.path("Expected a path relative to the project")
        }
        var pending = ArraySlice(Self.components(path))
        var names: [String] = []
        var parents = [directory]
        var links = 0
        while let name = pending.first {
            pending = pending.dropFirst()
            if name == "." { continue }
            if name == ".." {
                guard names.popLast() != nil else { throw FilesFailure.path("Path escapes the project folder") }
                parents.removeLast()
                continue
            }
            guard let parent = parents.last else { throw FilesFailure.path("Missing project folder") }
            var info = Darwin.stat()
            let found = fstatat(parent.fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0
            let code = errno
            if found, info.st_mode & S_IFMT == S_IFLNK {
                links += 1
                if links > 64 { throw FilesFailure.path("Too many symbolic links") }
                let value = try readLink(parent: parent, name: name)
                var target: [String]
                if value.hasPrefix("/") {
                    guard let inside = relativeInside(value) else {
                        throw FilesFailure.path("Path escapes the project folder")
                    }
                    names.removeAll()
                    parents.removeSubrange(1...)
                    target = inside
                } else {
                    target = Self.components(value)
                }
                target.append(contentsOf: pending)
                pending = ArraySlice(target)
                continue
            }
            if pending.isEmpty {
                if !found, code != ENOENT { throw FilesFailure.system(name, code) }
                return Target(parent: parent, name: name, components: names + [name])
            }
            guard found else { throw FilesFailure.system((names + [name]).joined(separator: "/"), code) }
            let child = openat(parent.fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { throw FilesFailure.system((names + [name]).joined(separator: "/")) }
            names.append(name)
            parents.append(Descriptor(child))
        }
        guard let last = parents.last else { throw FilesFailure.path("Missing project folder") }
        return Target(parent: last, name: ".", components: names)
    }

    /// A target that may be changed: never the project folder itself.
    func mutation(_ path: String) throws -> Target {
        let target = try resolve(path)
        if target.components.isEmpty { throw FilesFailure.path("The project folder itself can't be changed") }
        if target.name == "." { return try resolve(target.relative) }
        return target
    }

    func info(_ target: Target) throws -> FileInfo {
        let info = try target.stat()
        let name = target.components.last ?? (path as NSString).lastPathComponent
        return FileInfo(name: ServerPath(name), path: target.serverPath,
                        isDirectory: info.st_mode & S_IFMT == S_IFDIR, size: UInt64(max(0, info.st_size)))
    }

    private func readLink(parent: Descriptor, name: String) throws -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let count = readlinkat(parent.fd, name, &buffer, Int(PATH_MAX))
        guard count >= 0 else { throw FilesFailure.system(name) }
        return String(decoding: buffer[0 ..< count].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// The components of an absolute link target inside the project, if it is.
    private func relativeInside(_ value: String) -> [String]? {
        let target = Self.components(value)
        for root in [path, logical] {
            let prefix = Self.components(root)
            if target.count >= prefix.count, Array(target[0 ..< prefix.count]) == prefix {
                return Array(target[prefix.count...])
            }
        }
        return nil
    }

    static func components(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }
}
