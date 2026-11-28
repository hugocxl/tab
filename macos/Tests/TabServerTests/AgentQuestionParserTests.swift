import XCTest
import TabProtocol
@testable import TabServer

final class AgentQuestionParserTests: XCTestCase {
    /// A header the form can't show is dropped; it never rejects the provider's questions.
    func testHeaderIsKeptOrDroppedWithoutFailingTheForm() throws {
        let form = try AgentQuestionParser.parse(["questions": [
            ["question": "Which auth?", "header": " Auth method ", "options": [["label": "OAuth"]]],
            ["question": "Blank header?", "header": "   "],
            ["question": "Long header?", "header": String(repeating: "x", count: 300)],
            ["question": "No header?"],
        ]], claude: true)
        XCTAssertEqual(form.questions.map(\.header), ["Auth method", nil, nil, nil])
        // Builds that predate headers still read the form.
        let legacy = try JSONDecoder().decode(AgentQuestionnaire.self, from: Data(#"{"questions":[{"id":"a","title":"T","options":[],"multiple":false,"secret":false,"required":true}]}"#.utf8))
        XCTAssertNil(legacy.questions.first?.header)
    }
}
