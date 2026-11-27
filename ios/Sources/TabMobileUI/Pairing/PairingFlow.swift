import TabMobileKit
import UIKit
import VisionKit

/// Pairs with a Mac from a scanned code, a pasted link or an opened
/// `tab://pair` link, showing progress and errors over `presenter`.
@MainActor
final class PairingFlow: NSObject, DataScannerViewControllerDelegate {
    private let app: AppModel
    private weak var presenter: UIViewController?
    private var scanner: DataScannerViewController?
    private var pairing = false
    var onPaired: ((ServerModel) -> Void)?

    init(app: AppModel, presenter: UIViewController) {
        self.app = app
        self.presenter = presenter
    }

    /// Opens the camera to scan the code Tab shows in Settings → Mobile.
    func scan() {
        guard DataScannerViewController.isSupported, DataScannerViewController.isAvailable else {
            askForLink(message: "This device can't scan codes. On your Mac, choose Copy Link under the code and paste it here.")
            return
        }
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                                qualityLevel: .balanced, isHighlightingEnabled: true)
        scanner.delegate = self
        let close = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in
            self?.scanner?.dismiss(animated: true)
        })
        scanner.navigationItem.leftBarButtonItem = close
        scanner.navigationItem.title = "Scan Pairing Code"
        let paste = UIBarButtonItem(title: "Paste Link", primaryAction: UIAction { [weak self] _ in
            self?.scanner?.dismiss(animated: true) { self?.askForLink(message: nil) }
        })
        scanner.navigationItem.rightBarButtonItem = paste
        let navigation = UINavigationController(rootViewController: scanner)
        navigation.modalPresentationStyle = .fullScreen
        self.scanner = scanner
        presenter?.present(navigation, animated: true) {
            try? scanner.startScanning()
        }
    }

    /// Asks for a `tab://pair` link, filled from the clipboard when it holds one.
    func askForLink(message: String?) {
        let alert = UIAlertController(title: "Paste Pairing Link",
                                      message: message ?? "On your Mac, open Tab Settings → Mobile, show the code, and choose Copy Link.",
                                      preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "tab://pair?…"
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            if let text = UIPasteboard.general.string, text.hasPrefix("tab://pair") { field.text = text }
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        let pair = UIAlertAction(title: "Pair", style: .default) { [weak self, weak alert] _ in
            self?.pair(link: alert?.textFields?.first?.text ?? "")
        }
        alert.addAction(pair)
        alert.preferredAction = pair
        presenter?.present(alert, animated: true)
    }

    /// Pairs with the Mac `link` names.
    func pair(link: String) {
        guard !pairing else { return }
        pairing = true
        let progress = UIAlertController(title: "Pairing…", message: "Connecting to your Mac.", preferredStyle: .alert)
        presenter?.present(progress, animated: true)
        Task {
            defer { pairing = false }
            do {
                let server = try await app.pair(link: link, deviceName: UIDevice.current.name)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                progress.dismiss(animated: true) { self.onPaired?(server) }
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                progress.dismiss(animated: true) {
                    let alert = UIAlertController(title: "Couldn't Pair", message: error.localizedDescription,
                                                  preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "OK", style: .default))
                    self.presenter?.present(alert, animated: true)
                }
            }
        }
    }

    // MARK: DataScannerViewControllerDelegate

    nonisolated func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem],
                                 allItems: [RecognizedItem]) {
        MainActor.assumeIsolated {
            for item in addedItems {
                guard case .barcode(let barcode) = item, let payload = barcode.payloadStringValue,
                      payload.hasPrefix("tab://pair") else { continue }
                dataScanner.stopScanning()
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                dataScanner.dismiss(animated: true) { self.pair(link: payload) }
                return
            }
        }
    }
}
