import AppKit
import TabCore
import TabProtocol

extension AppModel {
    /// The project's icon: the one remembered from the last launch at once,
    /// then the one found now. Local folders are searched on disk, others
    /// through the side connection.
    public func projectIcon(_ project: ProjectId) -> NSImage? {
        guard let target = state.project(project), !target.home else { return nil }
        if target.serverId.isLocal {
            let key = target.directory.rawValue
            guard target.status == .available else { return iconCache.knownIcon(for: key) }
            return iconCache.icon(for: key)
        }
        let key = project.description
        guard target.status == .available, sideClient(for: project) != nil else { return remoteIconCache.knownIcon(for: key) }
        return remoteIconCache.icon(for: key)
    }

    /// The key each listed project's icon goes by.
    func projectIconKeys() -> (local: Set<String>, remote: Set<String>) {
        var local: Set<String> = []
        var remote: Set<String> = []
        for project in state.projects where !project.home {
            if project.serverId.isLocal {
                local.insert(project.directory.rawValue)
            } else {
                remote.insert(project.id.description)
            }
        }
        return (local, remote)
    }

    /// Looks up `server`'s project icons again once it reconnects.
    func refreshProjectIcons(server: ServerId) {
        guard !server.isLocal else { return }
        for project in state.projects where project.serverId == server && !project.home {
            remoteIconCache.invalidate(project.id.description)
        }
    }

    /// Searches a remote project's files for its icon.
    nonisolated static func findRemoteIcon(side: ServerAPI, project: ProjectId) async -> ProjectIconLookup {
        var failed = false
        let icon = await ProjectIconFinder.find(
            list: { directory in
                do {
                    let reply = try await side.files(FilesRequest(project: project, action: .list(ServerPath(directory))))
                    guard case .entries(let entries) = reply else { return [] }
                    return entries.map {
                        ProjectIconEntry(name: $0.name.rawValue, path: $0.path.rawValue, isDirectory: $0.isDirectory, isIgnored: $0.isIgnored)
                    }
                } catch {
                    failed = true
                    return []
                }
            },
            read: { path in
                let reply = try? await side.files(FilesRequest(project: project, action: .readBytes(ServerPath(path))))
                guard case .bytes(let file)? = reply else { return nil }
                return file.bytes
            }
        )
        if let icon { return .found(icon) }
        return failed ? .unavailable : .none
    }
}
