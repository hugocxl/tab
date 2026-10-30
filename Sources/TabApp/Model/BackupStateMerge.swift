import Foundation
import TabCore

/// How a backup's `state.json` meets the current one: the backup holds this
/// computer's projects with their layouts but no sessions. Existing projects
/// stay; a backed-up project whose folder is already one gets the backup's
/// layout; the rest are added.
enum BackupStateMerge {
    static func merge(imported: Data, current: Data?) throws -> Data {
        let current = try current ?? AppStateStore.encode(AppState.bootstrap())
        guard var target = try JSONSerialization.jsonObject(with: current) as? [String: Any],
              let source = try JSONSerialization.jsonObject(with: imported) as? [String: Any]
        else { return current }
        var projects = target["projects"] as? [[String: Any]] ?? []
        let incoming = source["projects"] as? [[String: Any]] ?? []
        let local = ServerId.local.description
        var projectIds: [String: String] = [:]
        var added = Set<String>()
        var fontSizes = target["terminalFontSizes"] as? [String: Double] ?? [:]
        let importedSizes = source["terminalFontSizes"] as? [String: Double] ?? [:]
        for var project in incoming where (project["serverId"] as? String) == local {
            project["tabs"] = restoredTabs(project["tabs"] as? [[String: Any]] ?? [], sizes: importedSizes, into: &fontSizes)
            let directory = project["directory"] as? String
            if let index = projects.firstIndex(where: {
                guard ($0["serverId"] as? String) == local else { return false }
                if (project["home"] as? Bool) == true { return ($0["home"] as? Bool) == true }
                return ($0["home"] as? Bool) != true && ($0["directory"] as? String) == directory
            }) {
                if let old = project["id"] as? String, let matched = projects[index]["id"] as? String {
                    projectIds[old] = matched
                }
                if let imported = project["tabs"] { projects[index]["tabs"] = imported }
                continue
            }
            let id = project["id"] as? String
            guard !projects.contains(where: { ($0["id"] as? String) == id }) else { continue }
            projects.append(project)
            if let id {
                projectIds[id] = id
                added.insert(id)
            }
        }
        for index in projects.indices {
            guard let id = projects[index]["id"] as? String, projectIds[id] == id,
                  let parent = projects[index]["parentId"] as? String, let mapped = projectIds[parent] else { continue }
            projects[index]["parentId"] = mapped
        }
        var servers = target["servers"] as? [String: Any] ?? [:]
        var server = servers[local] as? [String: Any] ?? [:]
        var intents = server["projectIntents"] as? [[String: Any]] ?? []
        for project in projects where (project["id"] as? String).map(added.contains) == true {
            let descriptor = try JSONDecoder().decode(ProjectDescriptor.self, from: JSONSerialization.data(withJSONObject: project))
            let intent = ProjectIntent(mutation: .create(descriptor))
            let encoded = try JSONEncoder().encode(intent)
            if let value = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] { intents.append(value) }
        }
        guard intents.count <= AppState.maximumProjectIntents else {
            throw AppError.invalidState("too many restored projects; reconnect before importing more projects")
        }
        server["projectIntents"] = intents
        servers[local] = server
        target["servers"] = servers
        target["projects"] = projects
        target["terminalFontSizes"] = fontSizes
        var workspaces = target["workspaces"] as? [[String: Any]] ?? []
        for var workspace in source["workspaces"] as? [[String: Any]] ?? [] {
            let members = workspace["projects"] as? [String] ?? []
            workspace["projects"] = members.compactMap { projectIds[$0] }
            let id = workspace["id"] as? String
            if let index = workspaces.firstIndex(where: { ($0["id"] as? String) == id }) {
                let remoteIds = Set(projects.filter { ($0["serverId"] as? String) != local }.compactMap { $0["id"] as? String })
                let remote = (workspaces[index]["projects"] as? [String] ?? []).filter(remoteIds.contains)
                workspace["projects"] = (workspace["projects"] as? [String] ?? []) + remote
                workspaces[index] = workspace
            } else {
                workspaces.append(workspace)
            }
        }
        if !workspaces.isEmpty { target["workspaces"] = workspaces }
        let data = try JSONSerialization.data(withJSONObject: target, options: [.sortedKeys])
        _ = try AppStateStore.decode(data)
        return data
    }

    /// Restored terminals get new creation tokens, so the server cannot replay
    /// an old creation receipt and bring a live session into a backup layout.
    private static func restoredTabs(_ tabs: [[String: Any]], sizes: [String: Double],
                                     into restoredSizes: inout [String: Double]) -> [[String: Any]] {
        tabs.map { original in
            var tab = original
            tab["id"] = TabId().description
            var ids: [String: String] = [:]
            tab["panes"] = (original["panes"] as? [[String: Any]] ?? []).map { original in
                var pane = original
                if let id = pane["id"] as? String {
                    let replacement = PaneId().description
                    ids[id] = replacement
                    pane["id"] = replacement
                    if let size = sizes[id] { restoredSizes[replacement] = size }
                }
                if var content = pane["content"] as? [String: Any] {
                    content["session"] = nil
                    pane["content"] = content
                }
                pane["proxy"] = nil
                return pane
            }
            if let layout = tab["layout"] as? [String: Any] { tab["layout"] = remapLayout(layout, ids: ids) }
            if let zoomed = tab["zoomed"] as? String { tab["zoomed"] = ids[zoomed] }
            return tab
        }
    }

    private static func remapLayout(_ original: [String: Any], ids: [String: String]) -> [String: Any] {
        var layout = original
        if let leaf = layout["leaf"] as? String { layout["leaf"] = ids[leaf] ?? leaf }
        if var split = layout["split"] as? [String: Any] {
            for branch in ["first", "second"] {
                if let child = split[branch] as? [String: Any] { split[branch] = remapLayout(child, ids: ids) }
            }
            layout["split"] = split
        }
        return layout
    }

    /// This computer's projects with their layouts and the workspaces, as a
    /// backup keeps them: no sessions, no remote projects, no pending work.
    static func backup(_ state: AppState, terminalFontSizes: [String: Double] = [:]) throws -> Data {
        let encoded = try AppStateStore.encode(state)
        guard var root = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else { return encoded }
        let local = ServerId.local.description
        var projects = (root["projects"] as? [[String: Any]] ?? []).filter { ($0["serverId"] as? String) == local }
        for index in projects.indices {
            guard var tabs = projects[index]["tabs"] as? [[String: Any]] else { continue }
            for tab in tabs.indices {
                guard var panes = tabs[tab]["panes"] as? [[String: Any]] else { continue }
                for pane in panes.indices {
                    panes[pane]["proxy"] = nil
                    guard var content = panes[pane]["content"] as? [String: Any] else { continue }
                    content["session"] = nil
                    panes[pane]["content"] = content
                }
                tabs[tab]["panes"] = panes
            }
            projects[index]["tabs"] = tabs
        }
        root["projects"] = projects
        let panes = Set(projects.flatMap { $0["tabs"] as? [[String: Any]] ?? [] }.flatMap { $0["panes"] as? [[String: Any]] ?? [] }.compactMap { $0["id"] as? String })
        root["terminalFontSizes"] = terminalFontSizes.filter { panes.contains($0.key) }
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
