import CryptoKit
import Darwin
import Foundation
import TabProtocol

extension ProjectRoot {
    /// Opens through the same component-by-component confined resolver as other file reads.
    /// The open descriptor and pre/post revision checks prevent a range from mixing file versions.
    func readRange(_ path: String, offset: UInt64, length: UInt32, expectedRevision: String?) throws -> FileByteRange {
        guard length > 0, length <= UInt32(FileByteRange.maximumChunkBytes),
              offset <= UInt64(Int64.max) - UInt64(length) else {
            throw ServiceError(.badRequest, "Invalid media byte range")
        }
        let target = try resolve(path)
        let raw = openat(target.parent.fd, target.name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard raw >= 0 else { throw FilesFailure.system(target.relative) }
        let file = Descriptor(raw)
        func metadata() throws -> Darwin.stat {
            var info = Darwin.stat()
            guard fstat(file.fd, &info) == 0 else { throw FilesFailure.system(target.relative) }
            guard info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else {
                throw FilesFailure.path("Only regular files can be read")
            }
            return info
        }
        let before = try metadata()
        let revision = Self.mediaRevision(before)
        guard expectedRevision == nil || expectedRevision == revision else {
            throw ServiceError(.badRequest, "The media file changed; refresh its preview")
        }
        let size = UInt64(before.st_size)
        let count = Int(min(UInt64(length), size - min(offset, size)))
        var bytes = Data(count: count)
        var readCount = 0
        try bytes.withUnsafeMutableBytes { buffer in
            guard count > 0 else { return }
            guard let baseAddress = buffer.baseAddress else { throw ServiceError(.badRequest, "The media range buffer is unavailable") }
            while readCount < count {
                let result = pread(file.fd, baseAddress.advanced(by: readCount), count - readCount, off_t(offset + UInt64(readCount)))
                if result < 0 {
                    if errno == EINTR { continue }
                    throw FilesFailure.system(target.relative)
                }
                if result == 0 { break }
                readCount += result
            }
        }
        guard readCount == count, Self.mediaRevision(try metadata()) == revision else {
            throw ServiceError(.badRequest, "The media file changed while it was read; refresh its preview")
        }
        return FileByteRange(path: target.serverPath, offset: offset, totalSize: size, revision: revision, bytes: bytes)
    }

    private static func mediaRevision(_ info: Darwin.stat) -> String {
        let fields = "\(info.st_dev):\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
        return SHA256.hash(data: Data(fields.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
