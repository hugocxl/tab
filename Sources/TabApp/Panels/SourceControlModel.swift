import Foundation
import TabProtocol

/// The Source Control panel's state without views: the working tree status
/// grouped as the panel shows it, which groups are collapsed, and whether a
/// commit can be made.
public struct SourceControlModel: Sendable {
    /// A group of changed files, in the order the panel shows them.
    public enum Group: Int, CaseIterable, Sendable {
        case conflicts, staged, changes, untracked

        public var title: String {
            switch self {
            case .conflicts: return "Conflicts"
            case .staged: return "Staged Changes"
            case .changes: return "Changes"
            case .untracked: return "Untracked"
            }
        }

        /// The group's bulk action.
        public var bulkTitle: String { self == .staged ? "Unstage All" : "Stage All" }
    }

    public enum Row: Equatable, Sendable {
        case header(Group)
        /// A file of a group, by its index in `status.files`.
        case file(Group, Int)
    }

    public private(set) var status: GitStatus?
    public private(set) var groups: [Group: [Int]] = [:]
    public private(set) var rows: [Row] = []
    public private(set) var collapsed: Set<Group> = []

    public init() {}

    public mutating func setStatus(_ status: GitStatus) {
        self.status = status
        groups = Self.group(status.files.map(\.file))
        rebuild()
    }

    /// Files by group, as indices into `files`. A conflicted file is only a
    /// conflict; a partly staged file is in both Staged Changes and Changes.
    public static func group(_ files: [GitFile]) -> [Group: [Int]] {
        var groups: [Group: [Int]] = [:]
        for (index, file) in files.enumerated() {
            if file.isConflicted {
                groups[.conflicts, default: []].append(index)
            } else if file.isUntracked {
                groups[.untracked, default: []].append(index)
            } else {
                if file.isStaged { groups[.staged, default: []].append(index) }
                if file.isUnstaged { groups[.changes, default: []].append(index) }
            }
        }
        return groups
    }

    public func files(in group: Group) -> [Int] { groups[group] ?? [] }

    public func file(_ index: Int) -> GitFileStatus? {
        guard let files = status?.files, files.indices.contains(index) else { return nil }
        return files[index]
    }

    /// The paths of a group, for Stage All and Unstage All.
    public func paths(in group: Group) -> [String] {
        files(in: group).compactMap { file($0)?.file.path.rawValue }
    }

    public mutating func toggle(_ group: Group) {
        if collapsed.contains(group) { collapsed.remove(group) } else { collapsed.insert(group) }
        rebuild()
    }

    private mutating func rebuild() {
        rows = []
        for group in Group.allCases {
            let indices = files(in: group)
            guard !indices.isEmpty else { continue }
            rows.append(.header(group))
            if !collapsed.contains(group) {
                rows.append(contentsOf: indices.map { .file(group, $0) })
            }
        }
    }

    /// Whether Commit is enabled: no conflicts and not busy, and either
    /// amending or a message with something staged.
    public static func canCommit(message: String, amend: Bool, busy: Bool, staged: Int, conflicts: Int) -> Bool {
        !busy && conflicts == 0 && (amend || (!message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && staged > 0))
    }

    public func canCommit(message: String, amend: Bool, busy: Bool) -> Bool {
        status != nil && Self.canCommit(
            message: message, amend: amend, busy: busy,
            staged: files(in: .staged).count, conflicts: files(in: .conflicts).count
        )
    }

    /// The status letter a file shows in a group: `U` for conflicts and
    /// untracked files, else its index or worktree code.
    public static func letter(_ file: GitFile, in group: Group) -> Character {
        switch group {
        case .conflicts, .untracked: return "U"
        case .staged: return file.index.porcelain
        case .changes: return file.worktree.porcelain
        }
    }

    /// What the letter's color means.
    public enum Tone: Equatable, Sendable {
        case conflict, added, deleted, renamed, modified
    }

    public static func tone(_ letter: Character, in group: Group) -> Tone {
        switch letter {
        case "U" where group == .conflicts: return .conflict
        case "A", "?", "U": return .added
        case "D": return .deleted
        case "R", "C": return .renamed
        default: return .modified
        }
    }

    /// The question asked before discarding `paths`.
    public static func discardMessage(_ paths: [String]) -> String {
        let tail = "Untracked files will be permanently deleted; staged changes are preserved."
        if paths.count == 1, let path = paths.first { return "Discard changes to “\(path)”? \(tail)" }
        return "Discard changes to \(paths.count) files? \(tail)"
    }
}
