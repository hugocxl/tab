import AppKit
import TabCore
import TabProtocol

extension AppModel {
    /// The project's icon, once found; starts looking on first use. Local
    /// folders are searched on disk, others through the side connection.
    public func projectIcon(_ project: ProjectId) -> NSImage? {
        if let target = state.project(project), target.serverId.isLocal {
            guard !target.home, target.status == .available else { return nil }
            return iconCache.icon(for: target.directory.rawValue)
        }
        if let cached = projectIcons[project] { return cached }
        guard !iconSearches.contains(project), let target = state.project(project),
              target.status == .available, !target.home else { return nil }
        let side = sideClient(for: project)
        guard target.serverId.isLocal || side != nil else { return nil }
        iconSearches.insert(project)
        let root = target.directory.rawValue
        let local = target.serverId.isLocal
        Task {
            let icon: NSImage?
            if local {
                icon = await Task.detached(priority: .utility) { await ProjectIconFinder.findLocal(root: URL(fileURLWithPath: root)) }.value
            } else if let side {
                icon = await ProjectIconFinder.find(
                    list: { directory in
                        let reply = try? await side.files(FilesRequest(project: project, action: .list(ServerPath(directory))))
                        guard case .entries(let entries)? = reply else { return [] }
                        return entries.map {
                            ProjectIconEntry(name: $0.name.rawValue, path: $0.path.rawValue, isDirectory: $0.isDirectory, isIgnored: $0.isIgnored)
                        }
                    },
                    read: { path in
                        let reply = try? await side.files(FilesRequest(project: project, action: .readBytes(ServerPath(path))))
                        guard case .bytes(let file)? = reply else { return nil }
                        return file.bytes
                    }
                )
            } else {
                icon = nil
            }
            projectIcons[project] = .some(icon)
            notify(.activity)
        }
        return nil
    }
}
