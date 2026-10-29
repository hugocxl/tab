import Foundation
import XCTest
@testable import TabCore

/// A temporary folder removed when the test ends.
final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("tab-core-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func file(_ name: String) -> URL { url.appendingPathComponent(name) }

    @discardableResult
    func write(_ name: String, _ text: String) throws -> URL {
        let file = file(name)
        try text.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    func read(_ name: String) throws -> String {
        try String(contentsOf: file(name), encoding: .utf8)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

func roundTrip<T: Codable>(_ value: T) throws -> T {
    try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
}

func jsonObject<T: Encodable>(_ value: T) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
}

func decodeState(_ object: Any) throws -> AppState {
    try AppStateStore.decode(JSONSerialization.data(withJSONObject: object))
}

func assertClose(_ actual: Double, _ expected: Double, accuracy: Double = 1e-5, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(actual, expected, accuracy: accuracy, message, file: file, line: line)
}

extension AppState {
    var activePane: PaneId? { window.activePane }
}
