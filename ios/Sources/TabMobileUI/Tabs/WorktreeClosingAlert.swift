import TabMobileKit
import TabProtocol
import UIKit

/// Closing panes as the desktop does. Agents still at work, or running
/// agents in the background, stop only once you say so. For the last panes
/// of a worktree, the worktree is inspected, then an alert says what removing
/// it would lose and offers to remove it, to keep it, or to keep the panes
/// open. Files never go without asking.
@MainActor
enum WorktreeClosingAlert {
    /// Closes `tab`, asking about its working agents and its worktree first.
    /// `agentsConfirmed` skips the first question, when the caller already
    /// said its agents stop.
    static func closeTab(_ tab: TabId, on server: ServerModel, from presenter: UIViewController,
                         agentsConfirmed: Bool = false) {
        let panes = Set(server.tab(tab)?.tab.panes.map(\.id) ?? [])
        confirmStopping(agentsConfirmed ? (0, 0) : server.workStopped(byClosing: panes), closing: "Tab",
                        from: presenter) {
            guard let worktree = server.worktreeClosed(byClosing: tab) else {
                try? server.closeTab(tab)
                return
            }
            ask(about: worktree, on: server, from: presenter) { try? server.closeTab(tab) }
        }
    }

    /// Closes `pane`, asking about its working agent and its worktree first.
    static func closePane(_ pane: PaneId, on server: ServerModel, from presenter: UIViewController) {
        confirmStopping(server.workStopped(byClosing: [pane]), closing: "Pane", from: presenter) {
            guard let worktree = server.worktreeClosed(by: [pane]) else {
                try? server.closePane(pane)
                return
            }
            ask(about: worktree, on: server, from: presenter) { try? server.closePane(pane) }
        }
    }

    /// Asks before closing stops agents at work or in the background.
    private static func confirmStopping(_ work: (agents: Int, background: Int), closing noun: String,
                                        from presenter: UIViewController, close: @escaping () -> Void) {
        guard work.agents > 0 || work.background > 0 else {
            close()
            return
        }
        var parts: [String] = []
        if work.agents > 0 { parts.append(work.agents == 1 ? "an agent that is working" : "\(work.agents) agents that are working") }
        if work.background > 0 {
            parts.append(work.background == 1 ? "1 agent running in the background" : "\(work.background) agents running in the background")
        }
        let alert = UIAlertController(title: "Stop the Agents?",
                                      message: "Closing stops \(parts.joined(separator: " and ")), on every device.",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Close \(noun)", style: .destructive) { _ in close() })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, from: presenter)
    }

    private static func ask(about worktree: ProjectDescriptor, on server: ServerModel, from presenter: UIViewController,
                            close: @escaping () -> Void) {
        Task {
            let closing: WorktreeClosing
            do {
                closing = try await server.inspectWorktreeClosing(worktree)
            } catch {
                let alert = UIAlertController(
                    title: "Couldn't Check the Worktree",
                    message: "\(error.localizedDescription)\n\nYou can close it and keep “\(worktree.name)” and its files.",
                    preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "Close and Keep Worktree", style: .default) { _ in close() })
                alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
                present(alert, from: presenter)
                return
            }
            let alert = UIAlertController(title: "Close Worktree?", message: closing.message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Close and Remove", style: .destructive) { _ in
                remove(closing, on: server, from: presenter, close: close)
            })
            alert.addAction(UIAlertAction(title: "Close and Keep Worktree", style: .default) { _ in close() })
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            present(alert, from: presenter)
        }
    }

    /// Removes the worktree, then closes what was asked; when the server
    /// refuses, everything stays open.
    private static func remove(_ closing: WorktreeClosing, on server: ServerModel, from presenter: UIViewController,
                               close: @escaping () -> Void) {
        Task {
            do {
                try await server.removeWorktree(closing)
                // The server closes the worktree's tabs too; this shows it at once.
                close()
            } catch {
                let alert = UIAlertController(title: "The Worktree Stays on Disk", message: error.localizedDescription,
                                              preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .cancel))
                present(alert, from: presenter)
            }
        }
    }

    private static func present(_ alert: UIAlertController, from presenter: UIViewController) {
        var top = presenter.view.window?.rootViewController ?? presenter
        while let presented = top.presentedViewController, !presented.isBeingDismissed { top = presented }
        top.present(alert, animated: true)
    }
}
