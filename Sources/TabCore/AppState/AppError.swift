import Foundation

/// Why an app-state change or load was refused.
public enum AppError: Error, CustomStringConvertible, LocalizedError {
    case homeDirectoryUnavailable
    /// A different Tab server now answers for this entry; its saved state is kept.
    case serverChanged(ServerId)
    /// The server answering for `server` is already listed as `existing`.
    case duplicateServer(server: ServerId, existing: ServerId)
    case unknownProject(ProjectId)
    case unknownTab(project: ProjectId, tab: TabId)
    case unknownPane(PaneId)
    case notTerminal(PaneId)
    case invalidTabIndex(index: Int, count: Int)
    case unsupportedVersion(Int)
    case invalidState(String)
    case io(path: String, message: String)
    case json(path: String, message: String)

    public var description: String {
        switch self {
        case .homeDirectoryUnavailable:
            return "the home folder is unavailable"
        case .serverChanged:
            return "invalid app state: server identity changed; original app state preserved"
        case .duplicateServer:
            return "invalid app state: this server is already listed under another name; original app state preserved"
        case .unknownProject(let id):
            return "project \(id) does not exist"
        case let .unknownTab(project, tab):
            return "tab \(tab) does not belong to project \(project)"
        case .unknownPane(let id):
            return "pane \(id) does not exist"
        case .notTerminal(let id):
            return "pane \(id) is not a terminal"
        case let .invalidTabIndex(index, count):
            return "tab index \(index) is out of range for \(count) tabs"
        case .unsupportedVersion(let version):
            return "unsupported app state version \(version)"
        case .invalidState(let message):
            return "invalid app state: \(message)"
        case let .io(path, message), let .json(path, message):
            return "\(path): \(message)"
        }
    }

    public var errorDescription: String? { description }
}
