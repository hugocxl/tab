import Foundation
import TabProtocol

/// A provider's JSON-RPC request ID as sent: numbers and strings are different IDs.
enum AgentProviderRequestID: Hashable, Sendable {
    case number(String)
    case string(String)

    init(_ wire: Any) {
        if let string = wire as? String { self = .string(string) } else { self = .number(agentRuntimeID(wire)) }
    }

    var text: String {
        switch self { case .number(let value), .string(let value): value }
    }

    var isNumber: Bool { if case .number = self { true } else { false } }
}

/// Normalizes provider approval and elicitation requests into what the card shows, and
/// turns the decision the user chose back into the provider's own response. Shapes are
/// from `codex app-server generate-json-schema --experimental` (codex-cli 0.169.0) and
/// Claude Code 2.1.311's `can_use_tool` control request.
enum AgentProviderRequests {
    /// A decision a provider takes back exactly as it offered it.
    struct Offered {
        var decision: AgentApprovalDecision
        /// The provider's value: a decision string or object, a permission scope, or an elicitation action.
        var value: Any
    }

    struct Presented {
        var request: AgentApprovalRequest
        var offered: [String: Any]
        var form: AgentQuestionnaire?
        /// Elicitation fields by question ID: how to turn answers back into content.
        var fields: [String: ElicitationField] = [:]
    }

    struct ElicitationField {
        enum Kind { case string, number, integer, boolean, single([String: String]), multiple([String: String]) }
        var kind: Kind
    }

    struct Unsupported: LocalizedError {
        var reason: String
        var errorDescription: String? { reason }
    }

    // MARK: Codex command and file approvals

    static func codexCommandOrFile(_ method: String, params: [String: Any], origin: AgentRequestOrigin) -> Presented {
        let fileChange = method == "item/fileChange/requestApproval"
        var requested: [AgentApprovalRequest.Field] = []
        if let command = params["command"] as? String { requested.append(.init(label: "Command", value: command)) }
        if let cwd = params["cwd"] as? String { requested.append(.init(label: "Folder", value: cwd)) }
        if let root = params["grantRoot"] as? String { requested.append(.init(label: "Write access under", value: root)) }
        if let network = params["networkApprovalContext"] as? [String: Any], let host = network["host"] as? String {
            requested.append(.init(label: "Network", value: ((network["protocol"] as? String).map { $0 + "://" } ?? "") + host))
        }
        requested += permissionFields(params["additionalPermissions"] as? [String: Any])
        let available = (params["availableDecisions"] as? [Any]) ?? ["accept", "acceptForSession", "decline", "cancel"]
        var decisions: [AgentApprovalDecision] = []
        var offered: [String: Any] = [:]
        for value in available {
            guard let decision = codexDecision(value, fileChange: fileChange), offered[decision.id] == nil else { continue }
            decisions.append(decision)
            offered[decision.id] = value
        }
        let request = AgentApprovalRequest(kind: fileChange ? "file-change" : "command",
                                           summary: params["reason"] as? String, requested: requested,
                                           decisions: decisions, origin: origin)
        return Presented(request: request, offered: offered)
    }

    private static func codexDecision(_ value: Any, fileChange: Bool) -> AgentApprovalDecision? {
        let subject = fileChange ? "these changes" : "this command"
        if let name = value as? String {
            switch name {
            case "accept":
                return .init(id: name, kind: .allowOnce, title: "Allow once", consequence: "Codex runs \(subject) this time only.")
            case "acceptForSession":
                return .init(id: name, kind: .allowForSession, title: "Allow for this session",
                             consequence: fileChange ? "Codex changes these files without asking again this session."
                                 : "Codex runs matching commands without asking again this session.")
            case "decline":
                return .init(id: name, kind: .decline, title: "Decline", consequence: "Codex skips \(subject) and carries on.")
            case "cancel":
                return .init(id: name, kind: .cancel, title: "Decline and stop", consequence: "Codex skips \(subject) and stops the response.")
            default:
                return nil
            }
        }
        guard let object = value as? [String: Any], object.count == 1, let key = object.keys.first else { return nil }
        switch key {
        case "acceptWithExecpolicyAmendment":
            let prefix = ((object[key] as? [String: Any])?["execpolicy_amendment"] as? [String])?.joined(separator: " ") ?? ""
            return .init(id: key, kind: .allowAlways, title: prefix.isEmpty ? "Always allow" : "Always allow “\(prefix)”",
                         consequence: "Codex adds a rule so matching commands run without asking.")
        case "applyNetworkPolicyAmendment":
            let amendment = (object[key] as? [String: Any])?["network_policy_amendment"] as? [String: Any]
            let host = amendment?["host"] as? String ?? "this host"
            let allow = amendment?["action"] as? String == "allow"
            return .init(id: key, kind: allow ? .allowAlways : .decline,
                         title: allow ? "Always allow \(host)" : "Always block \(host)",
                         consequence: "Codex keeps this network rule for \(host).")
        default:
            return nil
        }
    }

    // MARK: Codex permission requests

    static func codexPermissions(_ params: [String: Any], origin: AgentRequestOrigin) throws -> Presented {
        guard let permissions = params["permissions"] as? [String: Any] else {
            throw Unsupported(reason: "Codex asked for permissions without saying which.")
        }
        var requested: [AgentApprovalRequest.Field] = []
        if let cwd = params["cwd"] as? String { requested.append(.init(label: "Folder", value: cwd)) }
        requested += permissionFields(permissions)
        guard requested.contains(where: { $0.label != "Folder" }) else {
            throw Unsupported(reason: "Codex asked for a permission Tab can't describe.")
        }
        let decisions: [AgentApprovalDecision] = [
            .init(id: "turn", kind: .allowOnce, title: "Allow for this turn",
                  consequence: "Codex gets this access until the current response ends."),
            .init(id: "session", kind: .allowForSession, title: "Allow for this session",
                  consequence: "Codex keeps this access for the rest of this session."),
            .init(id: "decline", kind: .decline, title: "Decline", consequence: "Codex carries on without the extra access."),
        ]
        let request = AgentApprovalRequest(kind: "permissions", summary: params["reason"] as? String,
                                           requested: requested, decisions: decisions, origin: origin)
        return Presented(request: request, offered: ["turn": permissions, "session": permissions, "decline": [String: Any]()])
    }

    /// The response a permission decision sends: everything asked for, or nothing.
    static func codexPermissionsResponse(decision: String, offered: Any) -> [String: Any] {
        guard decision != "decline" else { return ["permissions": [String: Any]()] }
        return ["permissions": offered, "scope": decision]
    }

    private static func permissionFields(_ permissions: [String: Any]?) -> [AgentApprovalRequest.Field] {
        guard let permissions else { return [] }
        var fields: [AgentApprovalRequest.Field] = []
        if let files = permissions["fileSystem"] as? [String: Any] {
            if let read = files["read"] as? [String], !read.isEmpty { fields.append(.init(label: "Read", value: read.joined(separator: "\n"))) }
            if let write = files["write"] as? [String], !write.isEmpty { fields.append(.init(label: "Write", value: write.joined(separator: "\n"))) }
            for entry in files["entries"] as? [[String: Any]] ?? [] {
                guard let access = entry["access"] as? String, let path = entry["path"] as? [String: Any] else { continue }
                let label = access == "write" ? "Write" : access == "deny" ? "Deny" : "Read"
                let target: String
                switch path["type"] as? String {
                case "path": target = path["path"] as? String ?? "a path"
                case "glob_pattern": target = path["pattern"] as? String ?? "a pattern"
                case "special":
                    let special = path["value"] as? [String: Any]
                    let kind = special?["kind"] as? String ?? "special"
                    target = [kind == "project_roots" ? "project folders" : kind == "tmpdir" ? "the temporary folder"
                              : kind == "slash_tmp" ? "/tmp" : kind == "root" ? "the whole disk" : kind,
                              special?["subpath"] as? String ?? special?["path"] as? String].compactMap { $0 }.joined(separator: " ")
                default: target = "a path"
                }
                fields.append(.init(label: label, value: target))
            }
        }
        if let network = permissions["network"] as? [String: Any], network["enabled"] as? Bool == true {
            fields.append(.init(label: "Network", value: "Internet access"))
        }
        return fields
    }

    // MARK: MCP elicitation

    static func codexElicitation(_ params: [String: Any], origin: AgentRequestOrigin) throws -> Presented {
        let server = params["serverName"] as? String ?? "An MCP server"
        let message = params["message"] as? String
        var requested: [AgentApprovalRequest.Field] = [.init(label: "Server", value: server)]
        let decline = AgentApprovalDecision(id: "decline", kind: .decline, title: "Decline",
                                            consequence: "\(server) is told you declined.")
        let cancel = AgentApprovalDecision(id: "cancel", kind: .cancel, title: "Dismiss",
                                           consequence: "\(server) is told you dismissed the request without answering.")
        switch params["mode"] as? String {
        case "form":
            guard let schema = params["requestedSchema"] as? [String: Any] else {
                throw Unsupported(reason: "\(server) sent a form without a schema.")
            }
            let (form, fields) = try elicitationForm(schema, message: message ?? "\(server) asks for information")
            let submit = AgentApprovalDecision(id: "accept", kind: .submit, title: "Submit",
                                               consequence: "\(server) receives your answers.")
            let request = AgentApprovalRequest(kind: "elicitation", summary: message, requested: requested,
                                               decisions: [submit, decline, cancel], origin: origin)
            return Presented(request: request, offered: ["accept": "accept", "decline": "decline", "cancel": "cancel"],
                             form: form, fields: fields)
        case "url":
            guard let url = params["url"] as? String, let parsed = URL(string: url), ["https", "http"].contains(parsed.scheme?.lowercased() ?? "") else {
                throw Unsupported(reason: "\(server) sent a link Tab won't open.")
            }
            requested.append(.init(label: "Link", value: url))
            let accept = AgentApprovalDecision(id: "accept", kind: .allowOnce, title: "Done",
                                               consequence: "Tell \(server) you finished at the link.")
            let request = AgentApprovalRequest(kind: "elicitation", summary: message, requested: requested,
                                               decisions: [accept, decline, cancel], origin: origin)
            return Presented(request: request, offered: ["accept": "accept", "decline": "decline", "cancel": "cancel"])
        case let mode:
            throw Unsupported(reason: "\(server) asked for \(mode.map { "a “\($0)” response" } ?? "a response") Tab doesn't support.")
        }
    }

    /// The MCP form schema as questions; anything but flat strings, numbers, booleans and
    /// enums is refused rather than half shown.
    static func elicitationForm(_ schema: [String: Any], message: String) throws -> (AgentQuestionnaire, [String: ElicitationField]) {
        guard schema["type"] as? String == "object", let properties = schema["properties"] as? [String: Any], !properties.isEmpty else {
            throw Unsupported(reason: "The form has no fields Tab can show.")
        }
        let required = Set(schema["required"] as? [String] ?? [])
        var questions: [AgentQuestionnaire.Question] = []
        var fields: [String: ElicitationField] = [:]
        for name in properties.keys.sorted() {
            guard let property = properties[name] as? [String: Any] else { throw Unsupported(reason: "The field \(name) has no schema.") }
            let title = [property["title"] as? String ?? name, property["description"] as? String].compactMap { $0 }.joined(separator: " — ")
            let isRequired = required.contains(name)
            switch property["type"] as? String {
            case "string":
                if let options = titledOptions(property["oneOf"]) ?? plainOptions(property["enum"], names: property["enumNames"]) {
                    questions.append(.init(id: name, title: title, options: options.map { .init(label: $0.title) }, required: isRequired))
                    fields[name] = .init(kind: .single(Dictionary(options.map { ($0.title, $0.value) }, uniquingKeysWith: { first, _ in first })))
                } else {
                    questions.append(.init(id: name, title: title, required: isRequired))
                    fields[name] = .init(kind: .string)
                }
            case "number", "integer":
                questions.append(.init(id: name, title: title, required: isRequired))
                fields[name] = .init(kind: property["type"] as? String == "integer" ? .integer : .number)
            case "boolean":
                questions.append(.init(id: name, title: title, options: [.init(label: "Yes"), .init(label: "No")], required: isRequired))
                fields[name] = .init(kind: .boolean)
            case "array":
                let items = property["items"] as? [String: Any]
                guard let options = titledOptions(items?["anyOf"]) ?? plainOptions(items?["enum"], names: nil) else {
                    throw Unsupported(reason: "The field \(name) is a list Tab can't show.")
                }
                questions.append(.init(id: name, title: title, options: options.map { .init(label: $0.title) }, multiple: true, required: isRequired))
                fields[name] = .init(kind: .multiple(Dictionary(options.map { ($0.title, $0.value) }, uniquingKeysWith: { first, _ in first })))
            default:
                throw Unsupported(reason: "The field \(name) has a type Tab can't show.")
            }
        }
        guard questions.count <= 12 else { throw Unsupported(reason: "The form has more fields than Tab shows.") }
        let form = AgentQuestionnaire(questions: questions)
        do { try form.validate() } catch { throw Unsupported(reason: "The form is too large or repeats a choice.") }
        _ = message
        return (form, fields)
    }

    private static func titledOptions(_ value: Any?) -> [(title: String, value: String)]? {
        guard let options = value as? [[String: Any]], !options.isEmpty else { return nil }
        let parsed = options.compactMap { option -> (String, String)? in
            guard let value = option["const"] as? String else { return nil }
            return (option["title"] as? String ?? value, value)
        }
        return parsed.count == options.count ? parsed : nil
    }

    private static func plainOptions(_ value: Any?, names: Any?) -> [(title: String, value: String)]? {
        guard let values = value as? [String], !values.isEmpty else { return nil }
        let titles = names as? [String]
        return values.enumerated().map { index, value in (titles.flatMap { $0.indices.contains(index) ? $0[index] : nil } ?? value, value) }
    }

    /// The `content` of an accepted form, typed as the schema asked.
    static func elicitationContent(_ answers: [String: [String]], fields: [String: ElicitationField]) throws -> [String: Any] {
        var content: [String: Any] = [:]
        for (name, values) in answers {
            guard let field = fields[name], let first = values.first else { continue }
            switch field.kind {
            case .string: content[name] = first
            case .number:
                guard let number = Double(first.trimmingCharacters(in: .whitespaces)) else { throw AgentRuntimeError("“\(first)” isn't a number.") }
                content[name] = number
            case .integer:
                guard let number = Int(first.trimmingCharacters(in: .whitespaces)) else { throw AgentRuntimeError("“\(first)” isn't a whole number.") }
                content[name] = number
            case .boolean:
                guard first == "Yes" || first == "No" else { throw AgentRuntimeError("Choose Yes or No.") }
                content[name] = first == "Yes"
            case .single(let options):
                guard let value = options[first] else { throw AgentRuntimeError("Choose one of the offered options.") }
                content[name] = value
            case .multiple(let options):
                let mapped = values.compactMap { options[$0] }
                guard mapped.count == values.count else { throw AgentRuntimeError("Choose only the offered options.") }
                content[name] = mapped
            }
        }
        return content
    }

    // MARK: Claude tool approvals

    static func claude(_ request: [String: Any], origin: AgentRequestOrigin) -> Presented {
        let tool = request["tool_name"] as? String ?? "Tool approval"
        let display = request["display_name"] as? String ?? tool
        var decisions: [AgentApprovalDecision] = [
            .init(id: "deny", kind: .decline, title: "Deny", consequence: "Claude doesn't run \(display) and carries on."),
        ]
        if AgentApprovalScope.canAlwaysAllow(tool) {
            decisions.append(.init(id: "allowAlways", kind: .allowAlways, title: "Always Allow",
                                   consequence: "\(display) runs without asking for the rest of this conversation."))
        }
        decisions.append(.init(id: "allow", kind: .allowOnce, title: "Allow", consequence: "Claude runs \(display) this time."))
        var requested: [AgentApprovalRequest.Field] = [.init(label: "Tool", value: display)]
        if let path = request["blocked_path"] as? String { requested.append(.init(label: "Path", value: path)) }
        let summary = (request["description"] as? String) ?? (request["decision_reason"] as? String)
        return Presented(request: AgentApprovalRequest(kind: "tool", summary: summary, requested: requested,
                                                       decisions: decisions, origin: origin),
                         offered: ["deny": "deny", "allowAlways": "allowAlways", "allow": "allow"])
    }

    /// The transcript text of a settled request.
    static func outcomeText(_ kind: AgentApprovalDecision.Kind?, title: String) -> String {
        switch kind {
        case .allowOnce?: "Approved"
        case .allowForSession?: "Approved for this session"
        case .allowAlways?: "Always allowed"
        case .decline?: "Declined"
        case .cancel?: "Declined and stopped the response"
        case .submit?: "Answered"
        default: title
        }
    }
}
