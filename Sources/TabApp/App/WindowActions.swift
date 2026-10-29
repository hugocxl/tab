import AppKit
import TabCore

/// The pages the command palette can open on.
public enum PalettePage: Hashable, Sendable {
    case root
    /// Go to File.
    case files
    /// Find in Files.
    case find
    case branches(ProjectId)
    case newBranch(ProjectId)
    case changes(ProjectId)
    case worktrees(ProjectId)
    /// Existing Terminals of a project.
    case terminals(ProjectId)
    case projects
    case workspaces
    /// New Terminal in Project.
    case newTerminal
    case themes
    /// Open Project on this computer or another one.
    case addProject(ServerId)
    case commands
}

/// UI the sidebar, menus and palette open in the main window.
@MainActor
public protocol WindowActions: AnyObject {
    func openPalette(_ page: PalettePage)
    /// The New Worktree dialog for a repository.
    func newWorktree(parent: ProjectId)
    /// Renames a project or worktree in a small editor near `anchor`.
    func rename(project: ProjectId, anchor: NSView?)
    func newWorkspace(adding project: ProjectId?, anchor: NSView?)
    func renameWorkspace(_ id: WorkspaceId, anchor: NSView?)
    /// Add Project: the Open Project page, or a Local/Remote choice.
    func addProject(anchor: NSView?)
    func showSettings()
}
