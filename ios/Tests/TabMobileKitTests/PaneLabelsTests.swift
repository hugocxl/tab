import TabProtocol
import XCTest
@testable import TabMobileKit

final class PaneLabelsTests: XCTestCase {
    private func pane(_ kind: PaneSummary.Kind, _ title: String) -> PaneSummary {
        PaneSummary(id: PaneId(), kind: kind, title: title)
    }

    /// Pane titles are often an agent's whole first message; the segmented
    /// control needs a word or two, and two agents must stay apart.
    func testLabelsAreShortAndDistinct() {
        let labels = PaneSummary.shortLabels([
            pane(.agent(.claude), "im not enjoying that much that new layout."),
            pane(.terminal, "npm run dev"),
            pane(.agent(.claude), "in this mobile would it be possible"),
            pane(.other, "A very long browser page title"),
        ])
        XCTAssertEqual(labels, ["Claude 1", "npm", "Claude 2", "A very long b…"])
    }
}
