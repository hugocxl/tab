import Darwin
import Foundation
import TabCore

/// Starts programs that outlive this one, such as the server: a new session
/// (`setsid`), no inherited descriptors, stdin from `/dev/null`, and output
/// appended to a log file.
public enum DetachedProcess {
    /// Spawns `executable` and reaps it on a background thread when it exits
    /// while this process still runs. Returns its pid.
    ///
    /// - Parameter disclaim: make the child responsible for itself in macOS
    ///   privacy permissions, instead of this process.
    @discardableResult
    public static func spawn(_ executable: URL, arguments: [String], environment: [String: String],
                             log: URL?, disclaim: Bool = false) throws -> pid_t {
        var attributes: posix_spawnattr_t?
        try check(posix_spawnattr_init(&attributes), "posix_spawnattr_init")
        defer { posix_spawnattr_destroy(&attributes) }
        var actions: posix_spawn_file_actions_t?
        try check(posix_spawn_file_actions_init(&actions), "posix_spawn_file_actions_init")
        defer { posix_spawn_file_actions_destroy(&actions) }

        let flags = Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT)
        try check(posix_spawnattr_setflags(&attributes, flags), "posix_spawnattr_setflags")
        if disclaim { disclaimResponsibility(&attributes) }

        try check(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0), "open stdin")
        let output = log?.path ?? "/dev/null"
        if let log {
            try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
        }
        try check(posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, output, O_WRONLY | O_CREAT | O_APPEND, 0o600),
                  "open \(output)")
        try check(posix_spawn_file_actions_adddup2(&actions, STDOUT_FILENO, STDERR_FILENO), "dup2 stderr")

        let argv = [executable.path] + arguments
        let environ = environment.map { "\($0.key)=\($0.value)" }
        var pid: pid_t = 0
        let result = withCStrings(argv) { argvPointers in
            withCStrings(environ) { envPointers in
                posix_spawn(&pid, executable.path, &actions, &attributes, argvPointers, envPointers)
            }
        }
        try check(result, "launch \(executable.path)")
        let child = pid
        let reaper = Thread {
            var status: Int32 = 0
            while waitpid(child, &status, 0) == -1 && errno == EINTR {}
        }
        reaper.name = "TabClient.reaper"
        reaper.start()
        return pid
    }

    /// Makes the child responsible for itself. The call is private to macOS
    /// (Chromium and LLDB use it too), so it is looked up at run time; without
    /// it the child stays this process's responsibility.
    private static func disclaimResponsibility(_ attributes: inout posix_spawnattr_t?) {
        typealias Disclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim")
        else { return }
        let disclaim = unsafeBitCast(symbol, to: Disclaim.self)
        _ = disclaim(&attributes, 1)
    }

    private static func check(_ code: Int32, _ operation: String) throws {
        guard code == 0 else {
            throw ClientError.transport("\(operation): \(String(cString: strerror(code)))")
        }
    }

    private static func withCStrings<T>(_ strings: [String],
                                        _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> T) -> T {
        let buffer = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: strings.count + 1)
        defer {
            for index in 0 ..< strings.count { free(buffer[index]) }
            buffer.deallocate()
        }
        for (index, string) in strings.enumerated() { buffer[index] = strdup(string) }
        buffer[strings.count] = nil
        return body(buffer)
    }
}

/// The app can start the server through itself, so terminals keep the app's
/// macOS privacy permissions (such as Local Network) after the app quits:
/// macOS holds the process that started another responsible for it. The app
/// starts a disclaimed copy of itself with `ServerHost.flag`, which runs the
/// server beside it and lives as long as the server.
public enum ServerHost {
    /// The first argument of an app started as a host; the server's follow.
    public static let flag = "--server-host"

    /// Runs `tabd` beside this executable with `arguments` and returns its
    /// exit status once it exits. It never runs a program its caller names,
    /// since that program would get the app's permissions.
    public static func run(arguments: [String]) -> Int32 {
        guard let executable = Executable.currentURL() else { return 1 }
        let server = executable.deletingLastPathComponent().appendingPathComponent(Executable.server)
        let process = Process()
        process.executableURL = server
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return 1
        }
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// The app executable that can host `server`: the running one, when it
    /// is inside an app bundle and `server` is the one beside it.
    static func app(for server: URL) -> URL? {
        guard let executable = Executable.currentURL(), Executable.containingBundle(of: executable) != nil,
              executable.deletingLastPathComponent().appendingPathComponent(Executable.server).standardizedFileURL
              == server.standardizedFileURL else { return nil }
        return executable
    }
}
