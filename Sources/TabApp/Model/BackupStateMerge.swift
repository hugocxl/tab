import Foundation
import TabCore

/// How a backup's `state.json` meets the current one: the backup holds this
/// computer's projects with their layouts but no sessions. Existing projects
/// stay; a backed-up project whose folder is already one gets the backup's
/// layout when it has none; the rest are added.
enum BackupStateMerge {
    static func merge(imported: Data, current: Data?) throws -> Data {
        guard let current else { return imported }
        guard var target = try JSONSerialization.jsonObject(with: current) as? [String: Any],
              let source = try JSONSerialization.jsonObject(with: imported) as? [String: Any]
        else { return current }
        var projects = target["projects"] as? [[String: Any]] ?? []
        let incoming = source["projects"] as? [[String: Any]] ?? []
        let local = ServerId.local.description
        for project in incoming where (project["home"] as? Bool) != true && (project["serverId"] as? String) == local {
            let directory = project["directory"] as? String
            if let index = projects.firstIndex(where: {
                ($0["serverId"] as? String) == local && ($0["directory"] as? String) == directory
            }) {
                let tabs = projects[index]["tabs"] as? [Any] ?? []
                if tabs.isEmpty, let imported = project["tabs"] { projects[index]["tabs"] = imported }
                continue
            }
            let id = project["id"] as? String
            guard !projects.contains(where: { ($0["id"] as? String) == id }) else { continue }
            projects.append(project)
        }
        target["projects"] = projects
        var workspaces = target["workspaces"] as? [[String: Any]] ?? []
        for workspace in source["workspaces"] as? [[String: Any]] ?? [] {
            let id = workspace["id"] as? String
            if !workspaces.contains(where: { ($0["id"] as? String) == id }) { workspaces.append(workspace) }
        }
        if !workspaces.isEmpty { target["workspaces"] = workspaces }
        let data = try JSONSerialization.data(withJSONObject: target, options: [.sortedKeys])
        _ = try AppStateStore.decode(data)
        return data
    }

    /// This computer's projects with their layouts and the workspaces, as a
    /// backup keeps them: no sessions, no remote projects, no pending work.
    static func backup(_ state: AppState) throws -> Data {
        let encoded = try AppStateStore.encode(state)
        guard var root = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else { return encoded }
        let local = ServerId.local.description
        var projects = (root["projects"] as? [[String: Any]] ?? []).filter { ($0["serverId"] as? String) == local }
        for index in projects.indices {
            guard var tabs = projects[index]["tabs"] as? [[String: Any]] else { continue }
            for tab in tabs.indices {
                guard var panes = tabs[tab]["panes"] as? [[String: Any]] else { continue }
                for pane in panes.indices {
                    guard var content = panes[pane]["content"] as? [String: Any] else { continue }
                    content["session"] = nil
                    panes[pane]["content"] = content
                }
                tabs[tab]["panes"] = panes
            }
            projects[index]["tabs"] = tabs
        }
        root["projects"] = projects
        root["servers"] = [String: Any]()
        root["startingDirectories"] = [String: Any]()
        root["startupCommands"] = nil
        var window = root["window"] as? [String: Any] ?? [:]
        window["currentProject"] = state.home.id.description
        window["activePane"] = nil
        window["focusHistory"] = [Any]()
        window["selectedTab"] = [String: Any]()
        window["remoteServers"] = false
        root["window"] = window
        let ids = Set(projects.compactMap { $0["id"] as? String })
        if var workspaces = root["workspaces"] as? [[String: Any]] {
            for index in workspaces.indices {
                let members = workspaces[index]["projects"] as? [String] ?? []
                workspaces[index]["projects"] = members.filter(ids.contains)
            }
            root["workspaces"] = workspaces
        }
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .prettyPrinted])
    }
}
