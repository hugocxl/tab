import Foundation
import TabProtocol

/// A bounded, conversation-free handshake for commands and provider-owned skills.
final class AgentCommandDiscovery: @unchecked Sendable {
    struct Result: Sendable {
        var commands: [AgentCommandDescriptor] = []
        var skills: [(name: String, description: String, path: String)] = []
        var disabledSkills: Set<String> = []
        var truncated = false
        var available = false
    }
    private let queue = DispatchQueue(label: "tab.agent-command-discovery")
    private var process: AgentProcess?
    private var continuation: CheckedContinuation<Result, Never>?
    private var provider: AgentChatProvider = .claude
    private var directory = ""
    private var bytes = 0

    static func descriptors(_ rows: [[String: Any]]) -> [AgentCommandDescriptor] {
        var seen = Set<String>()
        return rows.prefix(256).compactMap { row in
            guard let name = row["name"] as? String, AgentSlashCommand.validName(name), seen.insert(name).inserted else { return nil }
            return .init(name: name, description: String((row["description"] as? String ?? "").prefix(512)),
                         argumentHint: (row["argumentHint"] as? String).map { String($0.prefix(128)) }, isSkill: row["builtin"] as? Bool != true,
                         aliases: (row["aliases"] as? [String]).map { Array($0.filter(AgentSlashCommand.validName).prefix(16)) })
        }
    }

    static func discover(provider: AgentChatProvider, directory: String, environment: [String: String]) async -> Result {
        let discovery = AgentCommandDiscovery()
        discovery.provider = provider; discovery.directory = directory
        return await withCheckedContinuation { continuation in
            discovery.queue.async {
                discovery.continuation = continuation
                discovery.queue.asyncAfter(deadline: .now() + 8) { discovery.finish(Result()) }
                do {
                    var environment = environment
                    environment.removeValue(forKey: "CLAUDECODE")
                    environment.removeValue(forKey: "TAB_SESSION_ID")
                    let executable = try AgentProcess.resolve(provider == .claude ? "claude" : "codex", environment: environment)
                    let arguments = provider == .codex ? ["app-server"] : ["--print", "--verbose", "--input-format", "stream-json",
                        "--output-format", "stream-json", "--no-session-persistence", "--tools", ""]
                    discovery.process = try AgentProcess(launch: .init(executable: executable, arguments: arguments, environment: environment),
                        directory: directory, onLine: { data in discovery.queue.async { discovery.receive(data) } },
                        onExit: { _, _ in discovery.queue.async { discovery.finish(Result()) } })
                    if provider == .claude {
                        try discovery.process?.write(["type": "control_request", "request_id": "1",
                            "request": ["subtype": "initialize", "hooks": [:]]])
                    } else {
                        try discovery.process?.write(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "tab", "version": "1"]]])
                    }
                } catch { discovery.finish(Result()) }
            }
        }
    }

    private func receive(_ data: Data) {
        guard continuation != nil else { return }
        bytes += data.count
        guard bytes <= 4 * 1024 * 1024 else { finish(Result()); return }
        guard let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        do {
            if provider == .claude {
                guard message["type"] as? String == "control_response",
                      let response = message["response"] as? [String: Any], response["request_id"] as? String == "1" else { return }
                guard let body = response["response"] as? [String: Any], let rows = body["commands"] as? [[String: Any]] else {
                    finish(Result()); return
                }
                finish(Result(commands: Self.descriptors(rows), truncated: rows.count > 256, available: true))
            } else if message["id"] as? Int == 1 {
                guard message["result"] != nil else { finish(Result()); return }
                try process?.write(["method": "initialized"])
                try process?.write(["id": 2, "method": "skills/list", "params": ["cwds": [directory], "forceReload": true]])
            } else if message["id"] as? Int == 2 {
                let rows = (message["result"] as? [String: Any])?["data"] as? [[String: Any]] ?? []
                let allSkills = rows.flatMap { $0["skills"] as? [[String: Any]] ?? [] }
                let skills = allSkills.prefix(256).compactMap { row -> (String, String, String)? in
                    guard row["enabled"] as? Bool != false, let name = row["name"] as? String,
                          let path = row["path"] as? String, AgentSlashCommand.validName(name) else { return nil }
                    return (name, row["description"] as? String ?? "", path)
                }
                finish(Result(commands: [.init(name: "compact", description: "Summarize the conversation to free context"),
                    .init(name: "review", description: "Review uncommitted changes, a branch, or a commit", argumentHint: "[branch <name> | commit <sha>]")],
                    skills: skills,
                    disabledSkills: Set(allSkills.filter { $0["enabled"] as? Bool == false }.compactMap { $0["name"] as? String }),
                    truncated: allSkills.count > 256 || rows.contains { ($0["errors"] as? [Any])?.isEmpty == false },
                    available: message["error"] == nil))
            }
        } catch { finish(Result()) }
    }

    private func finish(_ result: Result) {
        guard let continuation else { return }
        self.continuation = nil
        process?.stop(); process = nil
        continuation.resume(returning: result)
    }
}
