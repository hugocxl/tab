import Darwin
import Foundation

/// Stops processes still working inside a worktree before its files are
/// removed: SIGTERM, then SIGKILL, never touching a process that was replaced
/// by another with the same pid.
enum WorktreeProcesses {
    static func stop(in directory: String, timeout: TimeInterval = 3) throws {
        let directory = canonical(directory)
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let inside = try workingDirectories().filter { Self.isInside($0.1, directory) }
            if inside.isEmpty { return }
            if inside.contains(where: { $0.0 <= 1 || $0.0 == getpid() }) {
                throw gitError("The server is running from this worktree; files were preserved")
            }
            if Date() >= deadline {
                throw gitError("Processes are still using this worktree; files were preserved")
            }
            for (pid, _) in inside {
                guard let before = identity(pid) else { continue }
                for signal in [SIGTERM, SIGKILL] {
                    let stillHere = try workingDirectories().contains { $0.0 == pid && Self.isInside($0.1, directory) }
                    if !stillHere || identity(pid) != before { break }
                    if kill(pid, signal) != 0, errno != ESRCH, identity(pid) == before {
                        throw gitError("Couldn't stop process \(pid): \(String(cString: strerror(errno)))")
                    }
                    usleep(100_000)
                }
            }
        }
    }

    static func isInside(_ path: String, _ directory: String) -> Bool {
        path == directory || path.hasPrefix(directory.hasSuffix("/") ? directory : directory + "/")
    }

    /// Every process's working directory, from `lsof`.
    static func workingDirectories() throws -> [(pid_t, String)] {
        let output: ProcessOutput
        do {
            output = try ProcessRunner.run("/usr/sbin/lsof", ["-n", "-P", "-a", "-d", "cwd", "-Fpn0"],
                                           environment: GitCommand.environment(), timeout: 20)
        } catch {
            throw gitError("Couldn't list processes: \(error)")
        }
        // lsof exits 1 when some processes can't be inspected; its output is still complete for ours.
        var pid: pid_t?
        var result: [(pid_t, String)] = []
        for field in output.stdoutText.split(separator: "\0") {
            let record = field.hasPrefix("\n") ? field.dropFirst() : field
            if record.hasPrefix("p") { pid = pid_t(record.dropFirst()) }
            if record.hasPrefix("n"), let pid { result.append((pid, String(record.dropFirst()))) }
        }
        return result
    }

    /// The process's start time, which tells a reused pid apart.
    static func identity(_ pid: pid_t) -> String? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return "\(info.pbi_start_tvsec):\(info.pbi_start_tvusec)"
    }
}
