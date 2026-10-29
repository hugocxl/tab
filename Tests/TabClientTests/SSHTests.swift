import Foundation
import TabProtocol
import XCTest
@testable import TabClient

final class SSHTests: XCTestCase {
    private let bridge = Bridge.command(.ifNeeded)

    private func optionPairs(_ arguments: [String]) -> [String] {
        stride(from: 0, to: arguments.count - 1, by: 1).compactMap { arguments[$0] == "-o" ? arguments[$0 + 1] : nil }
    }

    func testDestinationsBecomeOneArgumentAfterTheOptions() throws {
        let alias = try SSHTarget(destination: "devbox")
        let arguments = alias.arguments(remote: bridge)
        XCTAssertEqual(arguments.first, "-T")
        XCTAssertEqual(Array(arguments.suffix(3)), ["--", "devbox", bridge])
        XCTAssertTrue(optionPairs(arguments).contains("BatchMode=yes"))
        for option in SSHTarget.options { XCTAssertTrue(optionPairs(arguments).contains(option), option) }
        XCTAssertFalse(arguments.contains("-p"))
        XCTAssertFalse(arguments.contains("-i"))
        XCTAssertTrue(alias.environment().isEmpty)

        let full = try SSHTarget(destination: "box.example.com", user: "dev", port: 2222, identity: "/keys/id_ed25519")
        let fullArguments = full.arguments(remote: bridge)
        let tail = Array(fullArguments.suffix(11))
        XCTAssertEqual(tail, ["-p", "2222", "-l", "dev", "-i", "/keys/id_ed25519", "-o", "IdentitiesOnly=yes", "--",
                              "box.example.com", bridge])
        XCTAssertEqual(try SSHTarget(destination: "ssh://dev@box:2222").arguments(remote: "x").suffix(3),
                       ["--", "ssh://dev@box:2222", "x"])
    }

    func testDestinationsSSHCouldMisreadAreRefused() {
        for accepted in ["box", "dev@box", "dev@10.0.0.4", "ssh://dev@box.example.com:2222", "dev@[::1]"] {
            XCTAssertNoThrow(try SSHTarget(destination: accepted), accepted)
        }
        for refused in ["", "-oProxyCommand=evil", "-", "my box", "box\n", "box\t", "box\u{0}", "\u{7}box", "box\u{a0}"] {
            XCTAssertThrowsError(try SSHTarget(destination: refused), refused.debugDescription)
        }
        XCTAssertThrowsError(try SSHTarget(destination: "box", user: "-oevil"))
        XCTAssertThrowsError(try SSHTarget(destination: "box", user: "a b"))
    }

    func testPasswordLoginAllowsOnePromptThroughAskpass() throws {
        var target = try SSHTarget(destination: "box")
        target.askpass = Askpass(program: "/Applications/Tab.app/Contents/MacOS/Tab",
                                 environment: ["TAB_ASKPASS_SOCKET": "/tmp/a.sock", "TAB_ASKPASS_TOKEN": "t"])
        let options = optionPairs(target.arguments(remote: bridge))
        XCTAssertTrue(options.contains("BatchMode=no"))
        XCTAssertTrue(options.contains("NumberOfPasswordPrompts=1"))
        XCTAssertFalse(options.contains("BatchMode=yes"))
        XCTAssertEqual(target.environment(), [
            "SSH_ASKPASS": "/Applications/Tab.app/Contents/MacOS/Tab", "SSH_ASKPASS_REQUIRE": "force",
            "TAB_ASKPASS_SOCKET": "/tmp/a.sock", "TAB_ASKPASS_TOKEN": "t",
        ])
    }

    func testHostKeyPromptsKeepVerificationAndDisableSharedConnections() throws {
        var target = try SSHTarget(destination: "ssh://dev@box:2222")
        target.hostKeyPrompt = true
        let options = optionPairs(target.arguments(remote: bridge))
        for option in ["StrictHostKeyChecking=ask", "FingerprintHash=sha256", "ControlPath=none"] {
            XCTAssertTrue(options.contains(option), option)
        }
        XCTAssertFalse(options.contains { $0 == "StrictHostKeyChecking=no" || $0 == "StrictHostKeyChecking=accept-new" })
    }

    func testCustomCommandsAreSplitLikeAShellAndGetNoSSHArgumentsOrCredentials() throws {
        var target = try SSHTarget.customCommand(#"vm ssh 'dev box' "a \"b\"" c\ d --"#)
        target.identity = "/private/key"
        target.hostKeyPrompt = true
        target.askpass = Askpass(program: "/private/askpass", environment: ["TOKEN": "secret"])
        target.proxy = ProxyCommand(program: "/usr/bin/nc")
        XCTAssertTrue(target.isCustomCommand)
        XCTAssertEqual(target.program, "vm")
        XCTAssertEqual(target.arguments(remote: bridge), ["ssh", "dev box", #"a "b""#, "c d", "--", bridge])
        XCTAssertTrue(target.environment().isEmpty)
        XCTAssertEqual(target.description, #"vm ssh 'dev box' "a \"b\"" c\ d --"#)
        XCTAssertThrowsError(try target.login())
        XCTAssertThrowsError(try target.defaultIdentity())
        for broken in ["", "   ", "vm 'open", "vm \\", "\u{7}vm"] {
            XCTAssertThrowsError(try SSHTarget.customCommand(broken), broken.debugDescription)
        }
    }

    func testCustomCommandArgumentsAreNotEvaluatedByALocalShell() throws {
        let target = try SSHTarget.customCommand(#"/usr/bin/printf '%s\n' '$(exit 91)' '$HOME' '*' '; exit 92'"#)
        let remote = #"sh -c 'printf "%s" "$HOME"'; exit 93"#
        let process = try target.process(remote: remote)
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "$(exit 91)\n$HOME\n*\n; exit 92\n\(remote)\n")
    }

    /// Expands the line as ssh does, then runs it the way ssh runs it.
    func testTheProxyLineSurvivesSSHExpansionAndTheShell() throws {
        let proxy = ProxyCommand(program: "/usr/bin/printf", arguments: ["%s|", "it's"], environment: ["P": "1"])
        XCTAssertEqual(proxy.option, #"ProxyCommand='/usr/bin/printf' '%%s|' 'it'\''s' %h %p"#)
        let line = proxy.option.dropFirst("ProxyCommand=".count)
            .replacingOccurrences(of: "%h", with: "box.example").replacingOccurrences(of: "%p", with: "22")
            .replacingOccurrences(of: "%%", with: "%")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "exec \(line)"]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "it's|box.example|22|")
        var target = try SSHTarget(destination: "box")
        target.proxy = proxy
        XCTAssertTrue(target.arguments(remote: "x", proxy: proxy).contains(proxy.option))
        XCTAssertEqual(target.environment(proxy: proxy), ["P": "1"])
    }

    func testSSHConfigOutputIsRead() {
        XCTAssertTrue(SSHTarget.route(fromConfig: "user me\nproxyjump bastion.example\nport 22\n"))
        XCTAssertTrue(SSHTarget.route(fromConfig: "proxycommand nc -X 5 %h %p\n"))
        XCTAssertFalse(SSHTarget.route(fromConfig: "user me\nproxycommand none\nport 22\n"))
        XCTAssertEqual(SSHTarget.login(fromConfig: "user dev\nhostname box.example\n"), "dev@box.example")
        XCTAssertEqual(SSHTarget.login(fromConfig: "user dev\nhostname 10.0.0.4\nhostkeyalias box\n"), "dev@box")
        XCTAssertNil(SSHTarget.login(fromConfig: "hostname box\n"))
    }

    func testTheRemoteCommandLooksBesideTheInstallerAndTheApp() {
        XCTAssertTrue(bridge.hasPrefix("sh -lc '"))
        XCTAssertTrue(bridge.contains("$HOME/.local/bin"))
        XCTAssertTrue(bridge.hasSuffix("exec tab stdio'"))
        XCTAssertTrue(Bridge.command(.never).hasSuffix("exec tab stdio --no-start'"))
    }

    // MARK: Bridge

    private func scan(_ chunks: [String]) -> Result<[UInt8], Bridge.NotReadyError> {
        var line = Bridge.ReadyLine()
        for chunk in chunks {
            if let outcome = line.push(Array(chunk.utf8)) { return outcome }
        }
        return .failure(Bridge.NotReadyError(line.ended))
    }

    func testTheReadyLineIsFoundAfterAnyNoiseAndKeepsLaterBytes() {
        XCTAssertEqual(try scan(["TAB-STDIO/1\n"]).get(), [])
        XCTAssertEqual(try scan(["Welcome!\nlast login\n", "TAB-STDIO/1\nhello"]).get(), Array("hello".utf8))
        XCTAssertEqual(try scan(["no newline", "TAB-STDIO/1\n"]).get(), [])
        XCTAssertEqual(try scan(["noise TAB-", "ST", "DIO/", "1", "\nrest"]).get(), Array("rest".utf8))
        XCTAssertEqual(scan(["TAB-STDIO/2\n"]), .failure(Bridge.NotReadyError(.version(Array("2".utf8)))))
        XCTAssertEqual(scan(["motd only"]), .failure(Bridge.NotReadyError(.ended(Array("motd only".utf8)))))
        guard case .failure(let error) = scan([String(repeating: "x", count: Bridge.maxNoise + 20)]),
              case .noisy = error.reason else { return XCTFail("noise past the limit is refused") }
    }

    func testSSHFailuresAreToldApartByItsOwnWords() {
        func ssh(_ stderr: String) -> (RemoteReason, String) {
            Bridge.explain(Bridge.Exit(status: 255, stderr: stderr), printed: [])
        }
        XCTAssertEqual(ssh("@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @\nHost key verification failed.\n").0,
                       .hostKeyChanged)
        XCTAssertEqual(ssh("Host key verification failed.\r\n").0, .hostKeyUnknown)
        XCTAssertEqual(ssh("No ED25519 host key is known for box and you have requested strict checking.\n").0,
                       .hostKeyUnknown)
        XCTAssertEqual(ssh("dev@box: Permission denied (publickey).\r\n").0, .authenticationFailed)
        XCTAssertEqual(ssh("dev@box: Permission denied (publickey).\r\n").1, "dev@box: Permission denied (publickey).")
        for unreachable in ["ssh: Could not resolve hostname box: nodename nor servname provided\n",
                            "ssh: connect to host box port 22: Connection refused\n"] {
            XCTAssertEqual(ssh(unreachable).0, .unreachable)
        }
        XCTAssertEqual(Bridge.explain(Bridge.Exit(status: 127, stderr: "sh: tab: command not found\n"), printed: []).0,
                       .notInstalled)
        XCTAssertEqual(Bridge.explain(Bridge.Exit(status: 1, stderr: "tab: unknown command\n"), printed: []).0,
                       .incompatible)
        XCTAssertEqual(Bridge.explain(Bridge.Exit(status: 1, stderr: "tab: the server isn't running\n"), printed: []).0,
                       .notRunning)
        XCTAssertEqual(Bridge.explain(Bridge.Exit(status: 0, stderr: ""), printed: Array("Welcome\n".utf8)).0,
                       .unexpectedOutput)
        XCTAssertEqual(Bridge.explain(Bridge.Exit(status: nil, stderr: "oops\n"), printed: []).0, .bridgeFailed)
        XCTAssertFalse(RemoteReason.authenticationFailed.recoverable)
        XCTAssertFalse(RemoteReason.hostKeyChanged.recoverable)
        XCTAssertTrue(RemoteReason.unreachable.recoverable)
    }

    /// A fake ssh: a custom command whose program prints what a real failure prints.
    private func connect(_ script: String) async -> ClientError? {
        do {
            let target = try SSHTarget.customCommand("/bin/sh -c '\(script)' fake-ssh")
            let client = try await RemoteServer.connect(target, kind: .cli, readyTimeout: 5)
            client.close()
            return nil
        } catch {
            return error as? ClientError
        }
    }

    private func reason(_ error: ClientError?) -> RemoteReason? {
        if case .remote(let failure)? = error { return failure.reason }
        return nil
    }

    func testRemoteFailuresBecomeTypedErrors() async throws {
        let cases: [(String, RemoteReason)] = [
            ("echo \"sh: tab: command not found\" >&2; exit 127", .notInstalled),
            ("echo \"dev@box: Permission denied (publickey).\" >&2; exit 255", .authenticationFailed),
            ("echo \"Host key verification failed.\" >&2; exit 255", .hostKeyUnknown),
            ("echo Welcome to the box; exit 0", .unexpectedOutput),
            ("printf \"TAB-STDIO/9\\n\"; sleep 1", .incompatible),
        ]
        for (script, expected) in cases {
            let error = await connect(script)
            XCTAssertEqual(reason(error), expected, script)
        }
        let missing = try SSHTarget.customCommand("/nonexistent/vm ssh box")
        do {
            _ = try await RemoteServer.connect(missing, kind: .cli)
            XCTFail("a missing program can't connect")
        } catch ClientError.remote(let failure) {
            XCTAssertEqual(failure.reason, .sshMissing)
            XCTAssertTrue(failure.detail.hasSuffix("vm"))
        }
    }

    func testABridgeThatNeverAnswersTimesOut() async throws {
        let target = try SSHTarget.customCommand("/bin/sh -c 'sleep 30' fake-ssh")
        let started = Date()
        do {
            _ = try await RemoteServer.connect(target, kind: .cli, readyTimeout: 0.5)
            XCTFail("nothing answered")
        } catch ClientError.remote(let failure) {
            XCTAssertEqual(failure.reason, .timeout)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    // MARK: Remote install

    func testTheInstallerComesFromTheMatchingReleaseAndFailsOnAFailedDownload() throws {
        let command = try RemoteInstall.command(version: "1.4.0")
        XCTAssertTrue(command.contains("https://github.com/hugocxl/tab/releases/download/v1.4.0/install-tab.sh"))
        XCTAssertTrue(command.contains("--proto =https"))
        XCTAssertTrue(command.contains("--version 1.4.0"))
        XCTAssertFalse(command.contains("--replace"))
        XCTAssertTrue(try RemoteInstall.command(version: "1.4.0-beta.12", replace: true).contains("--replace"))
        XCTAssertThrowsError(try RemoteInstall.command(version: "0.1.0-dev"))
        XCTAssertThrowsError(try RemoteInstall.command(version: "1.4.0; rm -rf ~"))
        // The quoting survives the remote shell: the script runs with `set -eu`.
        XCTAssertTrue(command.hasPrefix("sh -c 'set -eu; "))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-n", "-c", String(command.dropFirst("sh -c ".count))]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "the command parses")
    }
}

final class AskpassTests: XCTestCase {
    private static let hostPrompt = """
    The authenticity of host 'box (192.0.2.1)' can't be established.
    ED25519 key fingerprint is SHA256:original.
    Are you sure you want to continue connecting (yes/no/[fingerprint])? 
    """

    private func socket() -> URL {
        URL(fileURLWithPath: "/tmp/tab-ask-\(UUID().uuidString.prefix(8)).sock")
    }

    private func ask(_ server: AskpassServer, _ askpass: Askpass, _ prompt: String) throws -> String {
        try AskpassServer.ask(socket: server.socket.path, token: askpass.environment[AskpassServer.tokenVariable] ?? "",
                              prompt: prompt)
    }

    func testPasswordsTypedThisSessionAnswerOnlyTheDestinationsOwnPrompts() throws {
        let server = AskpassServer(socket: socket(), program: "/Applications/Tab.app/Contents/MacOS/Tab")
        let askpass = server.askpass(for: "server-1", login: "dev@box")
        XCTAssertEqual(askpass.program, "/Applications/Tab.app/Contents/MacOS/Tab")
        XCTAssertEqual(askpass.environment[AskpassServer.socketVariable], server.socket.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: server.socket.path), "nothing listens before a password")
        XCTAssertFalse(server.hasPassword(for: "server-1"))
        try server.setPassword("hunter2", for: "server-1")
        XCTAssertTrue(server.hasPassword(for: "server-1"))
        let attributes = try FileManager.default.attributesOfItem(atPath: server.socket.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        for prompt in ["dev@box's password: ", "(dev@box) Password: ",
                       "Enter passphrase for key '/Users/dev/.ssh/id_ed25519': "] {
            XCTAssertEqual(try ask(server, askpass, prompt), "hunter2", prompt)
        }
        for prompt in ["dev@box-jump's password: ", "otherdev@box's password: ", "(jump@gateway) dev@box's password: ",
                       "(dev@box) Verification code: ", "Enter dev@box's new password: ",
                       "Are you sure you want to continue connecting (yes/no/[fingerprint])? "] {
            XCTAssertEqual(try ask(server, askpass, prompt), "", prompt)
        }
        XCTAssertEqual(try AskpassServer.ask(socket: server.socket.path, token: "someone else", prompt: "Password: "), "")
        server.forgetPassword(for: "server-1")
        XCTAssertEqual(try ask(server, askpass, "dev@box's password: "), "")
    }

    func testHostKeysNeedApprovalOfTheExactPromptAndOnlyOnce() throws {
        let server = AskpassServer(socket: socket())
        var askpass = try server.askpassWithHostKey(for: "s", login: "dev@box", approved: nil)
        XCTAssertEqual(try ask(server, askpass, Self.hostPrompt), "")
        XCTAssertEqual(server.offeredHostKey(for: "s"), Self.hostPrompt)
        askpass = try server.askpassWithHostKey(for: "s", login: nil, approved: Self.hostPrompt)
        let changed = Self.hostPrompt.replacingOccurrences(of: "SHA256:original", with: "SHA256:other")
        XCTAssertEqual(try ask(server, askpass, changed), "")
        XCTAssertEqual(try ask(server, askpass, Self.hostPrompt), "yes")
        XCTAssertEqual(try ask(server, askpass, Self.hostPrompt), "", "approval is used once")
    }

    func testOnlyCompleteNewHostPromptsAreOffered() {
        XCTAssertTrue(AskpassServer.isHostKeyPrompt(Self.hostPrompt))
        XCTAssertTrue(AskpassServer.isHostKeyPrompt(Self.hostPrompt.replacingOccurrences(of: "fingerprint is ",
                                                                                       with: "fingerprint is: ")))
        for prompt in ["Are you sure you want to continue connecting (yes/no)? ",
                       "WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!", "(dev@box) Enter your password: ",
                       "The authenticity of host 'box' can't be established."] {
            XCTAssertFalse(AskpassServer.isHostKeyPrompt(prompt), prompt)
        }
    }

    func testAskpassModeRunsOnlyWithItsSocket() {
        XCTAssertNil(AskpassServer.runIfRequested(arguments: ["tab", "x"], environment: [:]))
        XCTAssertEqual(AskpassServer.runIfRequested(arguments: ["tab", "dev@box's password: "],
                                                    environment: [AskpassServer.socketVariable: "/tmp/tab-none.sock"]),
                       1, "no answer fails, so ssh doesn't send an empty password")
    }
}
