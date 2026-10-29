import Foundation
import TabProtocol

/// Pull requests through the GitHub CLI (`gh`). Every command names the
/// repository explicitly and runs without prompts.
final class GitHub: @unchecked Sendable {
    static let fields = "number,url,title,author,headRefName,headRefOid,baseRefName,state,isDraft,updatedAt,"
        + "mergeable,mergeStateStatus,isCrossRepository"
    static let timeout: TimeInterval = 60

    private let lookup: ExecutableLookup
    /// Runs this executable instead of the installed `gh` (tests).
    var executable: String?
    private let defaultBranches = DefaultBranchCache()

    init(lookup: ExecutableLookup) {
        self.lookup = lookup
    }

    // MARK: - Running gh

    private func run(_ repository: GitRepository, _ arguments: [String], truncate: Int? = nil) throws -> ProcessOutput {
        guard let gh = executable ?? lookup("gh") else {
            throw gitError("GitHub CLI: gh isn't installed. Install it and run gh auth login.")
        }
        var environment = GitCommand.environment()
        environment.removeValue(forKey: "GH_REPO")
        environment["GH_PROMPT_DISABLED"] = "1"
        environment["GH_PAGER"] = "cat"
        environment["NO_COLOR"] = "1"
        let output: ProcessOutput
        do {
            output = try ProcessRunner.run(gh, arguments, directory: repository.path, environment: environment,
                                           timeout: Self.timeout, truncateStdout: truncate)
        } catch {
            throw gitError("GitHub CLI: \(error)")
        }
        if output.truncated || output.succeeded { return output }
        throw gitError("GitHub CLI: \(GitCommand.failure(output).message)")
    }

    private func json(_ repository: GitRepository, _ arguments: [String]) throws -> Any {
        let output = try run(repository, arguments)
        do {
            return try JSONSerialization.jsonObject(with: output.stdout)
        } catch {
            throw gitError("GitHub CLI returned invalid data")
        }
    }

    private func identity(_ repository: GitRepository) throws -> String {
        guard let value = try json(repository, ["repo", "view", "--json", "url"]) as? [String: Any],
              let url = value["url"] as? String else { throw gitError("Missing GitHub repository URL") }
        let parts = url.hasPrefix("https://") ? url.dropFirst(8).split(separator: "/", omittingEmptySubsequences: false) : []
        guard parts.count == 3, parts.allSatisfy({ Self.validSegment(String($0)) }) else {
            throw gitError("Invalid GitHub repository URL")
        }
        return url
    }

    // MARK: - Actions

    func apply(_ action: GitPullRequestAction, in repository: GitRepository) throws -> GitReply {
        let identity = try identity(repository)
        switch action {
        case .info:
            return .pullRequest(try current(repository, identity: identity))
        case .number:
            let value = try lookupCurrent(repository, identity: identity,
                                          fields: "number,headRefName,headRefOid,state,isCrossRepository")
            guard let value else { return .pullRequestNumber(nil) }
            guard let number = Self.unsigned(value["number"]), number > 0 else {
                throw gitError("Invalid pull request number")
            }
            return .pullRequestNumber(number)
        case .list(let filter, let limit, let checks):
            let output = try json(repository, ["pr", "list", "--repo", identity, "--state", filter.rawValue,
                                               "--limit", String(limit), "--json", Self.fields(checks: checks)])
            guard let values = output as? [[String: Any]] else { throw gitError("Invalid pull request data") }
            if values.count > Int(limit) { throw gitError("Too many pull requests") }
            return .pullRequests(try values.map(Self.parse))
        case .diff(let number, let lineLimit):
            let output = try run(repository, ["pr", "diff", String(number), "--repo", identity, "--color", "never"],
                                 truncate: GitCommand.diffLimit)
            return .rawDiff(GitParsing.bounded(output.stdout, truncated: output.truncated, lineLimit: lineLimit))
        case .create(let title, let body, let baseBranch, let draft):
            return try create(repository, identity: identity, title: title, body: body, baseBranch: baseBranch,
                              draft: draft)
        case .merge(let number, let method, let deleteBranch, let expectedHead):
            var arguments = ["pr", "merge", String(number), "--repo", identity, "--\(method.rawValue)"]
            if deleteBranch { arguments.append("--delete-branch") }
            if let expectedHead { arguments += ["--match-head-commit", expectedHead] }
            _ = try run(repository, arguments)
            return .done
        case .close(let number):
            _ = try run(repository, ["pr", "close", String(number), "--repo", identity])
            return .done
        case .checkout(let number):
            let branch = try prepareCheckout(repository, identity: identity, number: number)
            try repository.git.run(repository.path, ["switch", "--", branch])
            return .done
        case .updateBranch(let number, let expectedHead):
            try updateBranch(repository, identity: identity, number: number, expectedHead: expectedHead)
            return .done
        }
    }

    /// The branch a pull request worktree checks out, fetched and tracking
    /// the pull request's head.
    func prepareWorktree(_ repository: GitRepository, number: UInt64) throws -> String {
        try prepareCheckout(repository, identity: try identity(repository), number: number)
    }

    /// The repository's default branch: the remote's, else GitHub's, cached
    /// while the remotes stay the same.
    func defaultBranch(_ repository: GitRepository) -> String? {
        let remotes = repository.git.optionalText(repository.path, ["config", "--get-regexp", "^remote\\..*\\.url$"]) ?? ""
        return defaultBranches.resolve(canonical(repository.path), remotes: remotes) {
            if let branch = repository.remoteDefaultBranch() { return branch }
            guard let value = try? self.json(repository, ["repo", "view", "--json", "defaultBranchRef"]) as? [String: Any],
                  let reference = value["defaultBranchRef"] as? [String: Any],
                  let branch = reference["name"] as? String,
                  (try? repository.validateBranch(branch)) != nil else { return nil }
            return branch
        }
    }

    // MARK: - Current branch lookup

    func current(_ repository: GitRepository, identity: String) throws -> GitPullRequest? {
        try lookupCurrent(repository, identity: identity, fields: Self.fields(checks: true)).map(Self.parse)
    }

    private struct CurrentBranch {
        var branch: String
        var head: String
        var configuredNumber: UInt64?

        func matchesHead(_ value: [String: Any]) -> Bool {
            value["headRefName"] as? String == branch
                && (value["headRefOid"] as? String)?.caseInsensitiveCompare(head) == .orderedSame
        }

        func matchesView(_ value: [String: Any]) -> Bool {
            GitHub.isOpen(value) && value["headRefName"] as? String == branch
                && ((value["isCrossRepository"] as? Bool) == false || matchesHead(value))
        }
    }

    private func lookupCurrent(_ repository: GitRepository, identity: String, fields: String) throws -> [String: Any]? {
        let summary = try repository.summary()
        guard let branch = summary.branch, let head = summary.head else { return nil }
        let configured = repository.config(GitRepository.pullRequestKey(branch)).flatMap(UInt64.init).flatMap { $0 > 0 ? $0 : nil }
        let current = CurrentBranch(branch: branch, head: head, configuredNumber: configured)
        var firstError: ServiceError?

        func view(_ arguments: [String], accept: ([String: Any]) -> Bool) throws -> [String: Any]? {
            do {
                guard let value = try json(repository, arguments) as? [String: Any] else {
                    throw gitError("Invalid pull request data")
                }
                return accept(value) ? value : nil
            } catch let error as ServiceError {
                if Self.noPullRequest(error) { return nil }
                if error.message.hasPrefix("GitHub CLI returned invalid data") || error.message == "Invalid pull request data" {
                    throw error
                }
                if firstError == nil { firstError = error }
                return nil
            }
        }

        if let number = current.configuredNumber,
           let value = try view(["pr", "view", String(number), "--repo", identity, "--json", fields], accept: Self.isOpen) {
            return value
        }
        if let value = try view(["pr", "view", "--json", fields], accept: current.matchesView) {
            return value
        }
        if UInt64(current.branch) == nil,
           let value = try view(["pr", "view", current.branch, "--repo", identity, "--json", fields],
                                accept: current.matchesView) {
            return value
        }
        let listed: Any
        do {
            listed = try json(repository, ["pr", "list", "--repo", identity, "--head", current.branch, "--state", "open",
                                           "--limit", "100", "--json", fields])
        } catch let error as ServiceError where Self.noPullRequest(error) {
            if let firstError { throw firstError }
            return nil
        }
        guard let values = listed as? [[String: Any]] else { throw gitError("Invalid pull request data") }
        if let match = values.first(where: { Self.isOpen($0) && current.matchesHead($0) }) { return match }
        if let firstError { throw firstError }
        return nil
    }

    // MARK: - Mutations

    private func create(_ repository: GitRepository, identity: String, title: String, body: String,
                        baseBranch: String?, draft: Bool) throws -> GitReply {
        guard let branch = try repository.summary().branch else {
            throw gitError("Cannot create a PR from detached HEAD")
        }
        let base = baseBranch ?? defaultBranch(repository) ?? "main"
        try repository.validateBranch(base)
        guard let destination = try repository.destination(branch: branch) else {
            throw gitError("No remote to push the pull request branch to")
        }
        try repository.publish(branch: branch, expected: destination)
        var arguments = ["pr", "create", "--repo", identity, "--head", destination.branch, "--base", base,
                         "--title", title.trimmingCharacters(in: .whitespacesAndNewlines), "--body", body]
        if draft { arguments.append("--draft") }
        let created = GitCommand.trimmed(try run(repository, arguments).stdout)
        guard let url = created.split(whereSeparator: \.isWhitespace).first(where: { $0.hasPrefix("https://") }) else {
            throw gitError("Pull request created, but its URL was not returned; refresh before retrying")
        }
        guard let number = url.split(separator: "/").last.flatMap({ UInt64($0) }), number > 0 else {
            throw gitError("Pull request created at \(url), but its number could not be read")
        }
        do {
            guard let value = try json(repository, ["pr", "view", String(number), "--repo", identity, "--json",
                                                    Self.fields(checks: true)]) as? [String: Any] else {
                throw gitError("Invalid pull request data")
            }
            return .pullRequest(try Self.parse(value))
        } catch let error as ServiceError {
            throw gitError("Pull request created at \(url), but readback failed: \(error.message)")
        }
    }

    private func updateBranch(_ repository: GitRepository, identity: String, number: UInt64,
                              expectedHead: String) throws {
        guard let pullRequest = try current(repository, identity: identity), pullRequest.number == number else {
            throw gitError("This branch no longer has that pull request; refresh and try again")
        }
        if pullRequest.state != "OPEN" { throw gitError("The pull request is no longer open") }
        if pullRequest.headOid != expectedHead {
            throw gitError("The pull request changed on GitHub; refresh and try again")
        }
        if pullRequest.crossRepository { throw gitError("Pull requests from forks can't be updated here") }
        try repository.validateBranch(pullRequest.baseBranch)
        let summary = try repository.summary()
        guard let branch = summary.branch,
              branch == pullRequest.headBranch
              || repository.config(GitRepository.pullRequestKey(branch)) == String(number) else {
            throw gitError("Switch to \(pullRequest.headBranch) before updating the pull request")
        }
        if summary.head != expectedHead {
            throw gitError("This branch isn't at the pull request's head commit; pull or push it first")
        }
        if summary.changed > summary.untracked {
            throw gitError("Commit or stash your changes before updating the branch")
        }
        guard let destination = try repository.destination(branch: branch) else {
            throw gitError("No remote to push the updated branch to")
        }
        try repository.git.network(repository.path, ["fetch", "origin", pullRequest.baseBranch])
        do {
            try repository.git.run(repository.path, ["merge", "--no-edit", "refs/remotes/origin/\(pullRequest.baseBranch)"])
        } catch let cause as ServiceError {
            _ = try? repository.git.run(repository.path, ["merge", "--abort"])
            throw gitError("Couldn't merge origin/\(pullRequest.baseBranch), so the merge was aborted: \(cause.message)")
        }
        do {
            try repository.publish(branch: branch, expected: destination)
        } catch let cause as ServiceError {
            throw gitError("Merged origin/\(pullRequest.baseBranch) into \(branch) locally, but couldn't push it: "
                + "\(cause.message). Push the branch to finish.")
        }
    }

    private func prepareCheckout(_ repository: GitRepository, identity: String, number: UInt64) throws -> String {
        guard let value = try json(repository, ["pr", "view", String(number), "--repo", identity, "--json",
                                                "headRefName,headRepository,headRepositoryOwner"]) as? [String: Any],
            let head = value["headRefName"] as? String else { throw gitError("Missing PR branch") }
        guard let name = (value["headRepository"] as? [String: Any])?["name"] as? String else {
            throw gitError("PR head repository was deleted")
        }
        guard let owner = (value["headRepositoryOwner"] as? [String: Any])?["login"] as? String else {
            throw gitError("Missing PR owner")
        }
        try repository.validateBranch(head)
        guard Self.validSegment(name), Self.validSegment(owner) else { throw gitError("Invalid PR repository") }
        guard let host = identity.dropFirst(8).split(separator: "/").first else { throw gitError("Invalid GitHub host") }
        let remote = "pr-\(number)-\(owner)-\(name)"
        let url = "https://\(host)/\(owner)/\(name).git"
        if let existing = repository.git.optionalText(repository.path, ["config", "--get", "remote.\(remote).url"]) {
            if existing != url { throw gitError("PR remote points to a different repository") }
        } else {
            try repository.git.run(repository.path, ["remote", "add", remote, url])
        }
        try repository.git.network(repository.path, ["fetch", remote, "refs/heads/\(head):refs/remotes/\(remote)/\(head)"])
        let branch = "pr/\(number)/\(Self.safeComponent(head))"
        let upstream = "\(remote)/\(head)"
        if repository.git.optionalText(repository.path, ["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"]) != nil {
            try repository.git.run(repository.path, ["branch", "--set-upstream-to=\(upstream)", branch])
        } else {
            try repository.git.run(repository.path, ["branch", "--track", branch, "refs/remotes/\(upstream)"])
        }
        try repository.git.run(repository.path, ["config", GitRepository.pullRequestKey(branch), String(number)])
        return branch
    }

    // MARK: - Parsing

    static func fields(checks: Bool) -> String {
        checks ? fields + ",statusCheckRollup" : fields
    }

    static func isOpen(_ value: [String: Any]) -> Bool {
        value["state"] as? String == "OPEN"
    }

    static func noPullRequest(_ error: ServiceError) -> Bool {
        let message = error.message.lowercased()
        return message.contains("no pull requests found") || message.contains("no pull request found")
            || message.contains("could not resolve") || message.contains("no commits between")
    }

    static func validSegment(_ value: String) -> Bool {
        !["", ".", ".."].contains(value)
            && value.unicodeScalars.allSatisfy { ($0.isASCII && ($0.properties.isAlphabetic || ("0" ... "9").contains($0)))
                || "-_.".unicodeScalars.contains($0) }
    }

    /// A branch name component made only of letters, digits, `_` and single dashes.
    static func safeComponent(_ value: String) -> String {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false).map { part -> String in
            let mapped = String(part.map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "-" })
            return mapped.split(separator: "-").joined(separator: "-")
        }.filter { !$0.isEmpty }
        return parts.isEmpty ? "head" : parts.joined(separator: "/")
    }

    static func unsigned(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double >= 0, double == double.rounded(), double < 1.8e19 else { return nil }
        return number.uint64Value
    }

    static func parse(_ value: [String: Any]) throws -> GitPullRequest {
        guard let number = unsigned(value["number"]), number > 0,
              let url = value["url"] as? String, url.hasPrefix("https://"),
              let title = value["title"] as? String,
              let headBranch = value["headRefName"] as? String, !headBranch.isEmpty,
              let headOid = value["headRefOid"] as? String,
              let baseBranch = value["baseRefName"] as? String, !baseBranch.isEmpty,
              let state = value["state"] as? String,
              let draft = value["isDraft"] as? Bool,
              let crossRepository = value["isCrossRepository"] as? Bool else {
            throw gitError("Invalid pull request data")
        }
        let mergeable: Bool? = switch value["mergeable"] as? String {
        case "MERGEABLE": true
        case "CONFLICTING": false
        default: nil
        }
        return GitPullRequest(number: number, url: url, title: title,
                              author: (value["author"] as? [String: Any])?["login"] as? String ?? "",
                              headBranch: headBranch, headOid: headOid, baseBranch: baseBranch, state: state,
                              draft: draft, updatedAt: value["updatedAt"] as? String, mergeable: mergeable,
                              mergeState: value["mergeStateStatus"] as? String ?? "UNKNOWN",
                              crossRepository: crossRepository, checks: try checks(value["statusCheckRollup"]))
    }

    static func checks(_ value: Any?) throws -> GitChecks {
        var checks = GitChecks()
        guard let value, !(value is NSNull) else { return checks }
        guard let entries = value as? [Any] else { throw gitError("Invalid PR checks") }
        for entry in entries {
            guard let object = entry as? [String: Any] else { throw gitError("Invalid PR check") }
            let outcome: String
            if object["__typename"] as? String == "CheckRun" {
                outcome = object["status"] as? String == "COMPLETED" ? object["conclusion"] as? String ?? "PENDING" : "PENDING"
            } else {
                outcome = object["state"] as? String ?? "PENDING"
            }
            switch outcome.uppercased() {
            case "SUCCESS", "NEUTRAL", "SKIPPED": checks.passing += 1
            case "FAILURE", "ERROR", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE": checks.failing += 1
            default: checks.pending += 1
            }
        }
        return checks
    }
}

/// Default branches per repository, kept five minutes while its remotes
/// stay the same, so status reads don't ask the remote every time.
final class DefaultBranchCache: @unchecked Sendable {
    private struct Entry {
        var remotes: String
        var branch: String
        var stored: Date
    }

    private static let lifetime: TimeInterval = 300
    private static let capacity = 128
    private var entries: [String: Entry] = [:]
    private let lock = NSLock()

    func resolve(_ repository: String, remotes: String, resolve: () -> String?) -> String? {
        lock.lock()
        let now = Date()
        entries = entries.filter { now.timeIntervalSince($0.value.stored) < Self.lifetime }
        if let entry = entries[repository], entry.remotes == remotes {
            lock.unlock()
            return entry.branch
        }
        lock.unlock()
        guard let branch = resolve() else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if entries.count >= Self.capacity, let oldest = entries.min(by: { $0.value.stored < $1.value.stored })?.key {
            entries.removeValue(forKey: oldest)
        }
        entries[repository] = Entry(remotes: remotes, branch: branch, stored: Date())
        return branch
    }
}
