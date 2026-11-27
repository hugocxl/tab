import Foundation
import TabProtocol

/// A branch, tag or HEAD label shown before a commit's subject.
public struct GraphRefLabel: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// The checked-out branch.
        case current
        /// A local branch; `synced` when its remote branch points here too.
        case local(synced: Bool)
        case remote
        case tag
        /// A detached HEAD.
        case head
    }

    public var name: String
    public var kind: Kind

    public init(name: String, kind: Kind) {
        self.name = name
        self.kind = kind
    }

    /// A commit's labels, most important first: the checked-out branch,
    /// local branches (absorbing their remote twins), remote branches,
    /// tags, then a detached HEAD. Remote `HEAD` aliases are left out.
    public static func labels(for refs: [GitRef], currentBranch: String?) -> [GraphRefLabel] {
        guard !refs.isEmpty else { return [] }
        let locals = refs.filter { $0.kind == .localBranch }.map(\.name)
        let localSet = Set(locals)
        var syncedLocals: Set<String> = []
        var remotes: [String] = []
        for ref in refs where ref.kind == .remoteBranch {
            if ref.name.hasSuffix("/HEAD") { continue }
            if let slash = ref.name.firstIndex(of: "/") {
                let branch = String(ref.name[ref.name.index(after: slash)...])
                if localSet.contains(branch) {
                    syncedLocals.insert(branch)
                    continue
                }
            }
            remotes.append(ref.name)
        }
        let detached = refs.contains { $0.kind == .head } && currentBranch == nil
        var labels: [GraphRefLabel] = []
        if let currentBranch, localSet.contains(currentBranch) {
            labels.append(GraphRefLabel(name: currentBranch, kind: .current))
        }
        for name in locals where name != currentBranch {
            labels.append(GraphRefLabel(name: name, kind: .local(synced: syncedLocals.contains(name))))
        }
        labels += remotes.map { GraphRefLabel(name: $0, kind: .remote) }
        labels += refs.filter { $0.kind == .tag }.map { GraphRefLabel(name: $0.name, kind: .tag) }
        if detached { labels.append(GraphRefLabel(name: "HEAD", kind: .head)) }
        return labels
    }
}

/// The Git Graph panel's state without views: the commits loaded so far,
/// their lanes, and a work-in-progress row on top while the working tree
/// has changes.
public struct GitGraphModel: Sendable {
    /// What a row of the graph shows.
    public enum Row: Equatable, Sendable {
        /// Uncommitted changes on top of HEAD, with how many files changed.
        case workInProgress(changed: Int)
        /// A commit, by its index in `commits`.
        case commit(Int)
    }

    /// The hash the work-in-progress row uses in the layout.
    static let workInProgressHash = "\u{0}wip"

    public private(set) var commits: [GitCommit] = []
    public private(set) var layout = GitGraphLayout()
    public private(set) var summary: GitSummary?
    /// Whether the last page came back short, so nothing more is left.
    public private(set) var exhausted = false
    private var indices: [String: Int] = [:]
    private var hasWorkInProgress = false

    public init() {}

    public var rowCount: Int { layout.count }

    /// The current branch, `nil` when HEAD is detached.
    public var currentBranch: String? { summary?.branch }

    public func row(_ index: Int) -> Row {
        if hasWorkInProgress {
            return index == 0 ? .workInProgress(changed: Int(summary?.changed ?? 0)) : .commit(index - 1)
        }
        return .commit(index)
    }

    public func commit(at row: Int) -> GitCommit? {
        guard case .commit(let index) = self.row(row), commits.indices.contains(index) else { return nil }
        return commits[index]
    }

    /// The row showing `hash`, if loaded.
    public func row(of hash: String) -> Int? {
        indices[hash].map { $0 + (hasWorkInProgress ? 1 : 0) }
    }

    /// The row of HEAD's commit, or the work-in-progress row above it.
    public var headRow: Int? {
        if hasWorkInProgress { return 0 }
        return summary?.head.flatMap { row(of: $0) }
    }

    /// Starts over with the first page of history.
    public mutating func reset(summary: GitSummary?, commits page: [GitCommit], requested: Int) {
        self.summary = summary
        commits = []
        indices = [:]
        layout = GitGraphLayout()
        exhausted = false
        hasWorkInProgress = false
        if let summary, summary.changed > 0 {
            hasWorkInProgress = true
            layout.append(hash: Self.workInProgressHash, parents: summary.head.map { [$0] } ?? [])
        }
        append(page, requested: requested)
    }

    /// Adds the next page of history, skipping commits already shown in
    /// case the history moved between pages.
    public mutating func append(_ page: [GitCommit], requested: Int) {
        if page.count < requested { exhausted = true }
        commits.reserveCapacity(commits.count + page.count)
        for commit in page where indices[commit.hash] == nil {
            indices[commit.hash] = commits.count
            commits.append(commit)
            layout.append(hash: commit.hash, parents: commit.parentHashes)
        }
    }

    /// Whether a fresh first page and summary show the same history as
    /// what is loaded, so a refresh keeps the rows and only takes the new
    /// summary, such as another count of changed files.
    public mutating func keep(summary: GitSummary?, firstPage: [GitCommit]) -> Bool {
        guard summary?.head == self.summary?.head, summary?.branch == self.summary?.branch,
              ((summary?.changed ?? 0) > 0) == hasWorkInProgress,
              firstPage.count <= commits.count,
              zip(firstPage, commits).allSatisfy({ $0 == $1 }) else { return false }
        self.summary = summary
        return true
    }
}

/// Short relative dates for narrow rows: "now", "5m", "3h", "2d", "3w",
/// "4mo", "2y".
public enum GraphDate {
    nonisolated(unsafe) private static let parser = ISO8601DateFormatter()

    public static func parse(_ iso: String) -> Date? { parser.date(from: iso) }

    public static func relative(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        let minute = 60.0, hour = 3600.0, day = 86_400.0
        switch seconds {
        case ..<minute: return "now"
        case ..<hour: return "\(Int(seconds / minute))m"
        case ..<day: return "\(Int(seconds / hour))h"
        case ..<(day * 7): return "\(Int(seconds / day))d"
        case ..<(day * 30): return "\(Int(seconds / (day * 7)))w"
        case ..<(day * 365): return "\(Int(seconds / (day * 30)))mo"
        default: return "\(Int(seconds / (day * 365)))y"
        }
    }
}
