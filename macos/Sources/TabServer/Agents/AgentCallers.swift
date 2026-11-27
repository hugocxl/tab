import Darwin
import Foundation
import TabProtocol

/// Which agent conversation a local client runs under, from the kernel's process tree
/// rather than anything the client says about itself.
///
/// Every process Tab starts for a conversation is registered here: its provider process
/// (`AgentProcess` with `TAB_AGENT_ID`), and the terminals and commands that conversation
/// asks the server to run. A client whose socket peer descends from one of them, below this
/// server, is that conversation. Clearing `TAB_AGENT_ID` or forging it changes nothing.
/// Each registration holds its process's start time, so a PID the kernel reused for an
/// unrelated process never inherits it.
///
/// What it can't see: a process that left the tree, such as a daemon whose parent exited
/// so launchd adopted it. It connects as the user. In Ask and Auto, the user approves the
/// commands that could do that, as they approve any command; the ceiling `AgentLineage`
/// keeps is about what Tab itself grants agents, not a sandbox.
final class AgentCallers: @unchecked Sendable {
    static let shared = AgentCallers()

    /// Ancestors followed before giving up; real trees are a handful deep.
    static let maxDepth = 64

    /// A process as the kernel describes it: its parent and when it started.
    struct Process: Equatable {
        var parent: pid_t
        var started: timeval

        static func == (a: Process, b: Process) -> Bool {
            a.parent == b.parent && a.started.tv_sec == b.started.tv_sec && a.started.tv_usec == b.started.tv_usec
        }
    }

    private struct Owner {
        var agent: SessionId
        /// Nil when the kernel couldn't say, as in tests; the PID alone then decides.
        var started: timeval?
    }

    private let lock = NSLock()
    private var owners: [pid_t: Owner] = [:]
    private let describe: (pid_t) -> Process?

    init(describe: @escaping (pid_t) -> Process? = AgentCallers.process) {
        self.describe = describe
    }

    func register(_ pid: pid_t, agent: SessionId) {
        guard pid > 1 else { return }
        let started = describe(pid)?.started
        lock.withLock { owners[pid] = Owner(agent: agent, started: started) }
    }

    /// Forgets `pid` if it still belongs to `agent`, so a reused PID registered since stays.
    func unregister(_ pid: pid_t, agent: SessionId) {
        lock.withLock { if owners[pid]?.agent == agent { owners[pid] = nil } }
    }

    /// The conversation `pid` runs under: the nearest registered process among it and its
    /// ancestors, stopping at `server`, above which nothing belongs to this server's agents.
    func agent(for pid: pid_t, below server: pid_t = getpid()) -> SessionId? {
        var current = pid
        for _ in 0..<Self.maxDepth {
            guard current > 1, current != server, let process = describe(current) else { return nil }
            if let owner = lock.withLock({ owners[current] }) {
                // A registration from before the PID was reused is someone else's.
                if owner.started.map({ $0.tv_sec == process.started.tv_sec && $0.tv_usec == process.started.tv_usec }) ?? true {
                    return owner.agent
                }
            }
            guard process.parent != current else { return nil }
            current = process.parent
        }
        return nil
    }

    /// `pid`'s parent and start time, from the kernel.
    static func process(_ pid: pid_t) -> Process? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, u_int(name.count), &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else {
            return nil
        }
        return Process(parent: info.kp_eproc.e_ppid, started: info.kp_proc.p_starttime)
    }

    /// The process on the other end of a connected local socket.
    static func peer(of socket: Int32) -> pid_t? {
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(socket, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0, pid > 0 else { return nil }
        return pid
    }
}
