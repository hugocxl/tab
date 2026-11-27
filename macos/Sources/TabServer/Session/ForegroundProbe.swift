import Darwin
import Foundation
import TabProtocol

/// What runs in the foreground of a PTY, read from the kernel.
enum ForegroundProbe {
    static let shells: Set<String> = ["sh", "bash", "zsh", "fish", "dash", "ksh", "tcsh", "csh", "nu", "elvish", "xonsh"]

    struct Observation: Equatable {
        var group: pid_t
        var process: ForegroundProcess
        /// The foreground program's working directory.
        var directory: String?
    }

    /// The foreground process group of the terminal whose master is
    /// `master`, its leader's name and directory.
    static func observe(master: Int32, shell: pid_t) -> Observation? {
        let group = tcgetpgrp(master)
        guard group > 0 else { return nil }
        let member = name(group).map { (group, $0) } ?? firstMember(of: group)
        let name = member?.1 ?? ""
        return Observation(group: group, process: ForegroundProcess(name: name, isShell: group == shell),
                           directory: member.flatMap { directory(of: $0.0) })
    }

    static func name(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXCOMLEN) * 2 + 1)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func directory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        return path.hasPrefix("/") ? path : nil
    }

    private static func firstMember(of group: pid_t) -> (pid_t, String)? {
        members(of: group).lazy.compactMap { pid in name(pid).map { (pid, $0) } }.first
    }

    /// A directory the shell reported (`/path` or `file://host/path`, percent-encoded).
    static func terminalDirectory(_ value: String) -> String? {
        if value.hasPrefix("/") { return value.contains("\0") ? nil : value }
        guard value.hasPrefix("file://") else { return nil }
        let rest = value.dropFirst("file://".count)
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        guard let path = String(rest[slash...]).removingPercentEncoding, !path.contains("\0") else { return nil }
        return path
    }

    /// The agent among the first members of a process group, by executable
    /// and, for interpreters, script.
    static func agentProvider(group: pid_t) -> AgentProvider? {
        members(of: group).prefix(128).lazy.compactMap { pid -> AgentProvider? in
            guard let name = name(pid) else { return nil }
            return AgentDetector.identify(name: name, arguments: arguments(of: pid))
        }.first
    }

    private static func members(of group: pid_t) -> [pid_t] {
        let count = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(group), nil, 0)
        guard count > 0 else { return [group] }
        var pids = [pid_t](repeating: 0, count: Int(count) / MemoryLayout<pid_t>.size + 8)
        let filled = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(group), &pids,
                                   Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return [group] }
        return pids.prefix(Int(filled) / MemoryLayout<pid_t>.size).filter { $0 > 0 }.sorted()
    }

    /// A process's arguments (`KERN_PROCARGS2`), at most 64.
    static func arguments(of pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var length = 64 * 1024
        var bytes = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, 3, &bytes, &length, nil, 0) == 0, length > 4 else { return [] }
        let count = Int(Int32(bytes[0]) | Int32(bytes[1]) << 8 | Int32(bytes[2]) << 16 | Int32(bytes[3]) << 24)
        var rest = bytes[4..<length]
        guard let executableEnd = rest.firstIndex(of: 0) else { return [] }
        rest = rest[executableEnd...]
        guard let start = rest.firstIndex(where: { $0 != 0 }) else { return [] }
        return rest[start...].split(separator: 0, omittingEmptySubsequences: false)
            .prefix(min(max(count, 0), 64)).map { String(decoding: $0, as: UTF8.self) }
    }
}
