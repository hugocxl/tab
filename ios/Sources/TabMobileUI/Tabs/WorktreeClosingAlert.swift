import TabMobileKit
import TabProtocol
import UIKit

/// Closing the last panes of a worktree, as the desktop does: the worktree is
/// inspected, then an alert says what removing it would lose and offers to
/// remove it, to keep it, or to keep the panes open. Files never go without
/// asking.
@MainActor
enum WorktreeClosingAlert {
    /// Closes `tab`, asking about its worktree first when it holds the last panes.
    static func closeTab(_ tab: TabId, on server: ServerModel, from presenter: UIViewController) {
        guard let worktree = server.worktreeClosed(byClosing: tab) else {
            try? server.closeTab(tab)
            return
        }
        ask(about: worktree, on: server, from: presenter) { try? server.closeTab(tab) }
    }

    /// Closes `pane`, asking about its worktree first when it is the last pane.
    static func closePane(_ pane: PaneId, on server: ServerModel, from presenter: UIViewController) {
        guard let worktree = server.worktreeClosed(by: [pane]) else {
            try? server.closePane(pane)
            return
        }
        ask(about: worktree, on: server, from: presenter) { try? server.closePane(pane) }
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
