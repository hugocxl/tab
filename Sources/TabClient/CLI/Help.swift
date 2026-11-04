/// Usage text of the `tab` command line tool, made from `CLICommands`.
public enum CLIHelp {
    public static let root: String = {
        func section(_ title: String, _ section: CLIGroup.Section, extra: [(String, String)] = []) -> String {
            let rows = extra + CLICommands.groups.filter { $0.section == section && !$0.hidden }.map { ($0.name, $0.summary) }
            return ([title] + rows.map { name, summary in
                "  " + name.padding(toLength: 14, withPad: " ", startingAt: 0) + summary
            }).joined(separator: "\n")
        }
        return """
        Tab: terminals that keep running on a server, and the app that shows them

        Usage: tab [--host DESTINATION] <command> ...

        \(section("On the server; --host DESTINATION uses another computer's over SSH", .server))

        \(section("In the app on this Mac", .app, extra: [("<folder>", "Open a folder as a project")]))

        \(section("On this Mac", .local))

        Run tab <command> --help, or tab help <command>, for its commands.

        A session is a terminal on the server; it runs whether or not the app shows
        it. A tab is a card in the app's sidebar, and a pane is one terminal, agent or
        browser in a tab's layout.
        Projects are named by ID, unique name or folder; sessions by ID, a unique
        start of one, or a name such as wispy-cedar. Inside a Tab terminal or agent,
        a missing session means yours, a missing project yours, and new panes open
        beside yours.
        Commands that print data take --json. Put -- before words that start with a
        dash. Use ./NAME to open a folder named like a command.
        DESTINATION is user@host, an ssh_config alias or ssh://user@host:port; Tab
        must be installed there, and folders are absolute paths on that computer.
        TAB_DIR selects the profile folder.
        """
    }()

    /// The usage of a group, or of one of its commands, for `tab help ...`.
    static func topic(_ words: [String]) throws -> String {
        guard let first = words.first else { return root }
        guard let group = CLICommands.group(first) else { throw CLIError("unknown command \(first); run tab --help") }
        let rest = Array(words.dropFirst())
        guard !rest.isEmpty else { return self.group(group) }
        let (spec, consumed) = group.command(for: rest)
        guard let spec, consumed == rest.count else {
            throw CLIError("unknown command tab \(words.joined(separator: " ")); run tab \(first) --help")
        }
        return command(spec, in: group)
    }

    /// Every command of the group, then what they share.
    static func group(_ group: CLIGroup) -> String {
        let list = group.commands.map { spec in
            (usage(spec).map { "  " + $0 } + ["      " + spec.summary]).joined(separator: "\n")
        }.joined(separator: "\n")
        return "tab \(group.name): \(group.summary)\n\n\(list)\n\n\(group.notes)"
    }

    /// One command, then what its group's commands share. A group that is
    /// one command, such as `git`, has one help.
    static func command(_ spec: CLICommandSpec, in group: CLIGroup) -> String {
        guard spec.path.count > 1 else { return self.group(group) }
        let lines = usage(spec)
        let usage = (["Usage: tab " + lines[0]] + lines.dropFirst().map { "   or: tab " + $0 }).joined(separator: "\n")
        return "\(usage)\n\n\(spec.summary).\n\n\(group.notes)"
    }

    /// The command's forms, with `--json` where it takes it.
    private static func usage(_ spec: CLICommandSpec) -> [String] {
        spec.usage.map { form in
            guard spec.json else { return [spec.name, form].filter { !$0.isEmpty }.joined(separator: " ") }
            // --json goes before the words after --, which are taken as given.
            let parts = form.components(separatedBy: " [-- ")
            let options = parts[0].components(separatedBy: " -- ")
            let head = [options[0], "[--json]"].filter { !$0.isEmpty }.joined(separator: " ")
            let literal = parts.count > 1 ? " [-- " + parts[1] : options.count > 1 ? " -- " + options[1] : ""
            return "\(spec.name) \(head)\(literal)"
        }
    }
}
