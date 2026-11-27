import Foundation
import TabProtocol

/// Runs `git` (and `gh`) for one repository folder with a scrubbed
/// environment, bounded output and timeouts. Failures carry Git's message.
struct GitCommand: Sendable {
    static let localTimeout: TimeInterval = 20
    static let networkTimeout: TimeInterval = 60
    /// Diffs stop reading after this many bytes and report truncation.
    static let diffLimit = 1024 * 1024

    let lookup: ExecutableLookup

    init(lookup: ExecutableLookup = .system) {
        self.lookup = lookup
    }

    var git: String { lookup("git") ?? "/usr/bin/git" }

    /// The environment children inherit: Git variables that would redirect
    /// the repository are removed, prompts and editors are disabled.
    static func environment(extra: [String: String] = [:]) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment.filter { key, _ in
            !key.hasPrefix("GIT_") || ["GIT_SSH", "GIT_SSH_COMMAND", "GIT_SSH_VARIANT", "GIT_ASKPASS"].contains(key)
        }
        environment["LC_ALL"] = "C"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_EDITOR"] = "true"
        environment["GIT_MERGE_AUTOEDIT"] = "no"
        if environment["PATH"] == nil { environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin" }
        for (key, value) in extra { environment[key] = value }
        return environment
    }

    /// Runs `git` and returns its standard output, or throws its message.
    @discardableResult
    func run(_ directory: String, _ arguments: [String], environment extra: [String: String] = [:],
             input: Data? = nil, timeout: TimeInterval = localTimeout) throws -> Data {
        let output = try launch(directory, arguments, extra: extra, input: input, timeout: timeout, truncate: nil)
        guard output.succeeded else { throw Self.failure(output) }
        return output.stdout
    }

    /// `run` with the output as text without its trailing newline.
    func text(_ directory: String, _ arguments: [String], environment extra: [String: String] = [:]) throws -> String {
        Self.trimmed(try run(directory, arguments, environment: extra))
    }

    /// `run` that returns `nil` instead of throwing, for probes such as
    /// `rev-parse --verify HEAD`.
    func optionalText(_ directory: String, _ arguments: [String]) -> String? {
        guard let output = try? launch(directory, arguments, extra: [:], input: nil, timeout: Self.localTimeout,
                                       truncate: nil),
            output.succeeded else { return nil }
        return Self.trimmed(output.stdout)
    }

    /// Commands that talk to remotes: a longer timeout and `gh` as GitHub's
    /// credential helper when it is installed.
    @discardableResult
    func network(_ directory: String, _ arguments: [String]) throws -> Data {
        var prefixed: [String] = []
        if let gh = lookup("gh") {
            prefixed = ["-c", "credential.https://github.com.helper=!'\(gh.replacingOccurrences(of: "'", with: "'\\''"))' auth git-credential"]
        }
        return try run(directory, prefixed + arguments, timeout: Self.networkTimeout)
    }

    /// A diff cut at `diffLimit` bytes. With `noIndex`, exit status 1 (files
    /// differ) is success.
    func diff(_ directory: String, _ arguments: [String], noIndex: Bool) throws -> (Data, Bool) {
        let output = try launch(directory, arguments, extra: [:], input: nil, timeout: Self.localTimeout,
                                truncate: Self.diffLimit)
        if output.truncated { return (output.stdout, true) }
        guard output.succeeded || (noIndex && output.status == 1) else { throw Self.failure(output) }
        return (output.stdout, false)
    }

    private func launch(_ directory: String, _ arguments: [String], extra: [String: String], input: Data?,
                        timeout: TimeInterval, truncate: Int?) throws -> ProcessOutput {
        do {
            return try ProcessRunner.run(git, ["--no-pager", "--literal-pathspecs"] + arguments, directory: directory,
                                         environment: Self.environment(extra: extra), input: input,
                                         timeout: timeout, truncateStdout: truncate)
        } catch let failure as ProcessFailure {
            switch failure {
            case .timedOut: throw ServiceError(.badRequest, "Git command timed out; refresh before retrying")
            case .outputTooLarge: throw ServiceError(.badRequest, "Git output exceeds the limit")
            case .launch: throw ServiceError(.badRequest, "Git isn't available: \(failure)")
            }
        }
    }

    static func failure(_ output: ProcessOutput) -> ServiceError {
        let message = output.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.isEmpty {
            let fallback = output.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
            return ServiceError(.badRequest, fallback.isEmpty ? "Command failed with exit status \(output.status)" : fallback)
        }
        return ServiceError(.badRequest, message)
    }

    static func trimmed(_ data: Data) -> String {
        var text = String(decoding: data, as: UTF8.self)
        while text.hasSuffix("\n") { text.removeLast() }
        return text
    }
}

func gitError(_ message: String) -> ServiceError {
    ServiceError(.badRequest, message)
}
