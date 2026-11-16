import XCTest
@testable import TabProtocol

final class AgentSlashCommandTests: XCTestCase {
    func testCommandArgumentsAndPathsRemainDistinct() throws {
        let command = try XCTUnwrap(AgentSlashCommand(text: "  /skill:plugin.review  check tests\n"))
        XCTAssertEqual(command.name, "skill:plugin.review")
        XCTAssertEqual(command.arguments, "check tests")
        for path in ["/Users/me/App.swift crashes", "/tmp/log", "/ hello"] { XCTAssertNil(AgentSlashCommand(text: path)) }
        XCTAssertEqual(AgentSlashCommand(text: "/tmp is full")?.isPath, true)
    }

    func testRecognizedCommandsNeverFallThroughWithArguments() throws {
        for text in ["/compact instructions", "/review main", "/model opus", "/clear named", "/unknown argument", "/heapdump"] {
            let command = try XCTUnwrap(AgentSlashCommand(text: text))
            XCTAssertNotNil(command.validationError(provider: .codex, commands: ["compact", "review"]), text)
        }
        for text in ["/compact", "/review", "/review branch main", "/review commit abc123"] {
            let command = try XCTUnwrap(AgentSlashCommand(text: text))
            XCTAssertNil(command.validationError(provider: .codex, commands: ["compact", "review"]), text)
            XCTAssertNotNil(command.validationError(provider: .codex, commands: ["compact", "review"], hasAttachments: true), text)
        }
        XCTAssertNil(AgentSlashCommand(text: "/compact preserve decisions")?.validationError(provider: .claude, commands: ["compact"]))
    }

    func testProviderAliasesCannotBypassUnavailableOrLocalCommands() throws {
        let descriptors: [AgentCommandDescriptor] = [
            .init(name: "config", description: "Settings", aliases: ["settings", "preferences"]),
            .init(name: "clear", description: "Reset", aliases: ["reset", "fresh"]),
            .init(name: "code-review", description: "Review code", aliases: ["review"])
        ]
        for text in ["/settings theme dark", "/preferences theme dark", "/reset", "/fresh"] {
            XCTAssertNotNil(try XCTUnwrap(AgentSlashCommand(text: text)).validationError(provider: .claude,
                commands: descriptors.flatMap(\.names), descriptors: descriptors))
        }
        XCTAssertNil(try XCTUnwrap(AgentSlashCommand(text: "/review change")).validationError(provider: .claude,
            commands: descriptors.flatMap(\.names), descriptors: descriptors))
    }
}
