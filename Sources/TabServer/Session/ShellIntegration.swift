import Foundation
import TabCore
import TabProtocol

/// Shell startup hooks, installed into the profile folder so the scripts a
/// shell reads belong to this server: zsh through `ZDOTDIR`, fish through
/// `XDG_DATA_DIRS`; bash users source `$TAB_SHELL_INTEGRATION_DIR/tab.bash`.
struct ShellIntegration: Sendable {
    let directory: URL

    /// Restores the user's `ZDOTDIR` before zsh reads the rest of its startup files.
    static let zshenv = """
        # Restore the user's startup directory before zsh reads the remaining startup files.
        if [[ ${TAB_ZDOTDIR_SET-} == 1 ]]; then
            export ZDOTDIR=$TAB_ORIGINAL_ZDOTDIR
        else
            unset ZDOTDIR
        fi
        unset TAB_ZDOTDIR_SET TAB_ORIGINAL_ZDOTDIR
        [[ -r ${ZDOTDIR-$HOME}/.zshenv ]] && source "${ZDOTDIR-$HOME}/.zshenv"
        [[ -o interactive && ${TAB_SHELL_INTEGRATION-} == 1 ]] && source "$TAB_SHELL_INTEGRATION_DIR/tab.zsh"

        """

    /// Writes the scripts from the bundled `Resources/Shell` into `directory`.
    static func install(into directory: URL) throws -> ShellIntegration {
        for folder in ["", "zsh", "fish", "fish/vendor_conf.d"] {
            try PrivateFolder.ensure(folder.isEmpty ? directory : directory.appendingPathComponent(folder))
        }
        guard let resources = Bundle.module.url(forResource: "Shell", withExtension: nil) else {
            throw ServiceError(.persistenceFailed, "The shell integration scripts are missing from the build")
        }
        let files: [(String, Data)] = try [
            ("zsh/.zshenv", Data(zshenv.utf8)),
            ("tab.zsh", Data(contentsOf: resources.appendingPathComponent("tab.zsh"))),
            ("tab.bash", Data(contentsOf: resources.appendingPathComponent("tab.bash"))),
            ("fish/vendor_conf.d/tab.fish", Data(contentsOf: resources.appendingPathComponent("tab.fish"))),
        ]
        for (name, contents) in files {
            let url = directory.appendingPathComponent(name)
            if (try? Data(contentsOf: url)) == contents { continue }
            try AtomicFile.write(contents, to: url)
        }
        return ShellIntegration(directory: directory.resolvingSymlinksInPath())
    }

    /// Adds the variables that make `shell` load the hooks.
    func configure(_ environment: inout [String: String], shell: String, enabled: Bool) {
        environment["TAB_SHELL_INTEGRATION"] = enabled ? "1" : "0"
        guard enabled else { return }
        environment["TAB_SHELL_INTEGRATION_DIR"] = directory.path
        switch (shell as NSString).lastPathComponent {
        case "zsh":
            let original = environment["ZDOTDIR"]
            environment["TAB_ZDOTDIR_SET"] = original == nil ? "0" : "1"
            environment["TAB_ORIGINAL_ZDOTDIR"] = original ?? ""
            environment["ZDOTDIR"] = directory.appendingPathComponent("zsh").path
        case "fish":
            let inherited = environment["XDG_DATA_DIRS"].flatMap { $0.isEmpty ? nil : $0 }
                ?? "/usr/local/share:/usr/share"
            environment["XDG_DATA_DIRS"] = directory.path + ":" + inherited
        default:
            break
        }
    }
}
