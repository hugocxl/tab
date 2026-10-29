import Darwin
import Foundation
import TabProtocol

extension ProjectRoot {
    func list(_ path: String, ignored: (String, [String]) -> Set<String>) throws -> [FileEntry] {
        let target = try resolve(path)
        let directory = try target.openDirectory()
        var entries: [FileEntry] = []
        var size = 0
        for name in try Self.names(in: directory) where name != ".git" {
            let components = target.components + [name]
            let relative = components.joined(separator: "/")
            size += relative.utf8.count + name.utf8.count
            if entries.count == Limits.maxFileEntries || size > Limits.maxFilePathBytes {
                throw ServiceError(.badRequest, "This folder has too many entries to list")
            }
            var info = Darwin.stat()
            guard fstatat(directory.fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                if errno == ENOENT { continue }
                throw FilesFailure.system(relative)
            }
            var isDirectory = info.st_mode & S_IFMT == S_IFDIR
            if info.st_mode & S_IFMT == S_IFLNK {
                isDirectory = (try? resolve(relative).stat()).map { $0.st_mode & S_IFMT == S_IFDIR } ?? false
            }
            entries.append(FileEntry(name: ServerPath(name), path: ServerPath(relative), isDirectory: isDirectory))
        }
        let folder = target.components.isEmpty ? self.path : self.path + "/" + target.relative
        let ignoredNames = entries.isEmpty ? [] : ignored(folder, entries.map(\.name.rawValue))
        for index in entries.indices where ignoredNames.contains(entries[index].name.rawValue) {
            entries[index].isIgnored = true
        }
        return entries
            .map { (entry: $0, key: $0.name.rawValue.lowercased()) }
            .sorted { lhs, rhs in
                if lhs.entry.isDirectory != rhs.entry.isDirectory { return lhs.entry.isDirectory }
                if lhs.key != rhs.key { return lhs.key < rhs.key }
                return lhs.entry.name.rawValue < rhs.entry.name.rawValue
            }
            .map(\.entry)
    }

    func read(_ path: String) throws -> FileContent {
        let file = try readBytes(path)
        if file.bytes.contains(0) {
            throw ServiceError(.badRequest, "\(file.path.lastComponent) is a binary file and can't be opened as text")
        }
        let content = String(decoding: file.bytes, as: UTF8.self)
        guard content.utf8.elementsEqual(file.bytes) else {
            throw ServiceError(.badRequest, "\(file.path.lastComponent) isn't UTF-8 text and can't be opened")
        }
        return FileContent(path: file.path, content: content, size: UInt64(file.bytes.count))
    }

    func readBytes(_ path: String) throws -> FileBytes {
        let target = try resolve(path)
        let fd = openat(target.parent.fd, target.name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw FilesFailure.system(target.relative) }
        let file = Descriptor(fd)
        var info = Darwin.stat()
        guard fstat(file.fd, &info) == 0 else { throw FilesFailure.system(target.relative) }
        guard info.st_mode & S_IFMT == S_IFREG else {
            throw FilesFailure.path("Only regular files can be read")
        }
        if info.st_size > Limits.maxFileBytes { throw Self.tooLarge(target) }
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = Darwin.read(file.fd, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw FilesFailure.system(target.relative)
            }
            if count == 0 { break }
            bytes.append(contentsOf: buffer[0 ..< count])
            if bytes.count > Limits.maxFileBytes { throw Self.tooLarge(target) }
        }
        return FileBytes(path: target.serverPath, bytes: bytes)
    }

    private static func tooLarge(_ target: Target) -> ServiceError {
        ServiceError(.badRequest, "\(target.components.last ?? "The file") is larger than 5 MiB and can't be opened")
    }

    /// Replaces the file atomically, keeping an existing file's permissions.
    func write(_ path: String, _ content: Data) throws -> ServerPath {
        if content.count > Limits.maxFileBytes {
            throw ServiceError(.badRequest, "Content exceeds the 5 MiB limit")
        }
        let target = try mutation(path)
        var info = Darwin.stat()
        var mode: mode_t?
        if fstatat(target.parent.fd, target.name, &info, AT_SYMLINK_NOFOLLOW) == 0 {
            guard info.st_mode & S_IFMT == S_IFREG else {
                throw FilesFailure.path("Only regular files can be overwritten")
            }
            mode = info.st_mode & 0o7777
        } else if errno != ENOENT {
            throw FilesFailure.system(target.relative)
        }
        let temporary = ".tab-write-\(UUID().uuidString.lowercased())"
        let fd = openat(target.parent.fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o666)
        guard fd >= 0 else { throw FilesFailure.system(target.relative) }
        var closed = false
        do {
            try Self.writeAll(content, to: fd, name: target.relative)
            if let mode, fchmod(fd, mode) != 0 { throw FilesFailure.system(target.relative) }
            if fsync(fd) != 0 { throw FilesFailure.system(target.relative) }
            close(fd)
            closed = true
            guard renameat(target.parent.fd, temporary, target.parent.fd, target.name) == 0 else {
                throw FilesFailure.system(target.relative)
            }
        } catch {
            if !closed { close(fd) }
            unlinkat(target.parent.fd, temporary, 0)
            throw error
        }
        return target.serverPath
    }

    /// Creates a folder, numbering the name when it's taken.
    func mkdir(_ path: String) throws -> ServerPath {
        let target = try mutation(path)
        let name = try Self.sanitized(target.name)
        for number in 1 ... 10_000 {
            let candidate = Self.uniqueName(name, number)
            if mkdirat(target.parent.fd, candidate, 0o777) == 0 {
                return ServerPath((target.components.dropLast() + [candidate]).joined(separator: "/"))
            }
            if errno != EEXIST { throw FilesFailure.system(target.relative) }
        }
        throw FilesFailure.path("Can't find an available folder name")
    }

    func rename(_ path: String, to newName: String) throws -> ServerPath {
        let source = try mutation(path)
        _ = try source.stat()
        let name = try Self.sanitized(newName)
        if source.name == name { return source.serverPath }
        guard renameatx_np(source.parent.fd, source.name, source.parent.fd, name, UInt32(RENAME_EXCL)) == 0 else {
            throw FilesFailure.system(source.relative)
        }
        return ServerPath((source.components.dropLast() + [name]).joined(separator: "/"))
    }

    /// Resolves every path before anything changes, refusing overlaps.
    func selected(_ paths: [ServerPath]) throws -> [Target] {
        let sources = try paths.map { path -> Target in
            let target = try mutation(path.rawValue)
            _ = try target.stat()
            return target
        }
        for (index, source) in sources.enumerated() {
            for other in sources[..<index] where Self.isPrefix(source.components, of: other.components)
                || Self.isPrefix(other.components, of: source.components) {
                throw FilesFailure.path("The selection contains duplicate or overlapping paths")
            }
        }
        return sources
    }

    /// Moves into a folder, numbering names that are taken.
    func move(_ paths: [ServerPath], into: String) throws -> [ServerPath] {
        let destination = try resolve(into)
        let directory = try destination.openDirectory()
        let sources = try selected(paths)
        for source in sources where Self.isPrefix(source.components, of: destination.components) {
            throw FilesFailure.path("A folder can't be moved into itself")
        }
        var moved: [ServerPath] = []
        for source in sources {
            if Array(source.components.dropLast()) == destination.components {
                moved.append(source.serverPath)
                continue
            }
            var result: ServerPath?
            for number in 1 ... 10_000 {
                let name = Self.uniqueName(source.name, number)
                if renameatx_np(source.parent.fd, source.name, directory.fd, name, UInt32(RENAME_EXCL)) == 0 {
                    result = ServerPath((destination.components + [name]).joined(separator: "/"))
                    break
                }
                if errno != EEXIST { throw FilesFailure.system(source.relative) }
            }
            guard let result else { throw FilesFailure.path("Can't find an available destination name") }
            moved.append(result)
        }
        return moved
    }

    /// Deletes files and folders recursively. A link inside the project is
    /// removed itself, not what it points to.
    func delete(_ paths: [ServerPath]) throws {
        let sources = try selected(paths).enumerated().map { index, target in
            try linkItself(paths[index].rawValue) ?? target
        }
        for source in sources {
            try Self.removeTree(parent: source.parent, name: source.name, relative: source.relative)
        }
    }

    /// The link that `path` names, when its last component is one.
    private func linkItself(_ path: String) throws -> Target? {
        let components = Self.components(path)
        guard let last = components.last, last != ".", last != ".." else { return nil }
        let parent = try resolve(components.dropLast().joined(separator: "/"))
        let folder = parent.name == "." ? parent.parent : try parent.openDirectory()
        var info = Darwin.stat()
        guard fstatat(folder.fd, last, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFLNK else {
            return nil
        }
        return Target(parent: folder, name: last, components: parent.components + [last])
    }

    private static func removeTree(parent: Descriptor, name: String, relative: String) throws {
        var info = Darwin.stat()
        guard fstatat(parent.fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return }
            throw FilesFailure.system(relative)
        }
        if info.st_mode & S_IFMT == S_IFDIR {
            let fd = openat(parent.fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw FilesFailure.system(relative) }
            let folder = Descriptor(fd)
            for child in try names(in: folder) {
                try removeTree(parent: folder, name: child, relative: relative + "/" + child)
            }
            guard unlinkat(parent.fd, name, AT_REMOVEDIR) == 0 || errno == ENOENT else {
                throw FilesFailure.system(relative)
            }
            return
        }
        guard unlinkat(parent.fd, name, 0) == 0 || errno == ENOENT else { throw FilesFailure.system(relative) }
    }

    /// The entries of an open folder, without `.` and `..`.
    static func names(in directory: Descriptor) throws -> [String] {
        let copy = dup(directory.fd)
        guard copy >= 0, let stream = fdopendir(copy) else {
            if copy >= 0 { close(copy) }
            throw FilesFailure.system("Listing the folder")
        }
        defer { closedir(stream) }
        rewinddir(stream)
        var names: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            names.append(name)
        }
        return names
    }

    private static func writeAll(_ data: Data, to fd: Int32, name: String) throws {
        try data.withUnsafeBytes { buffer in
            guard var pointer = buffer.baseAddress else { return }
            var remaining = buffer.count
            while remaining > 0 {
                let written = Darwin.write(fd, pointer, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw FilesFailure.system(name)
                }
                remaining -= written
                pointer += written
            }
        }
    }

    static func sanitized(_ name: String) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == "." || name == ".." || name.contains("/") || name.utf8.contains(0) {
            throw FilesFailure.path("Invalid file name")
        }
        return name
    }

    /// `name`, then `name 2.ext`, `name 3.ext`, …
    static func uniqueName(_ name: String, _ number: Int) -> String {
        if number == 1 { return name }
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        if ext.isEmpty || stem.isEmpty { return "\(name) \(number)" }
        return "\(stem) \(number).\(ext)"
    }

    static func isPrefix(_ prefix: [String], of path: [String]) -> Bool {
        prefix.count <= path.count && Array(path[0 ..< prefix.count]) == prefix
    }
}
