import XCTest
@testable import TabProtocol

final class ValidationTests: XCTestCase {
    private func code(_ body: () throws -> Void) -> ErrorCode? {
        do {
            try body()
            return nil
        } catch let error as ErrorCode {
            return error
        } catch {
            XCTFail("validation threw \(error)")
            return nil
        }
    }

    func testServerPathRules() throws {
        XCTAssertNil(code { try ServerPath("/Users/me").validateAbsolute() })
        XCTAssertEqual(code { try ServerPath("relative").validateAbsolute() }, .badPath)
        XCTAssertEqual(code { try ServerPath("").validateAbsolute() }, .badPath)
        XCTAssertEqual(code { try ServerPath("/a\u{0}b").validateAbsolute() }, .badPath)
        XCTAssertEqual(code { try ServerPath("/" + String(repeating: "a", count: 4096)).validateAbsolute() }, .badPath)
        XCTAssertNil(code { try ServerPath("/" + String(repeating: "a", count: 4095)).validateAbsolute() })
        XCTAssertThrowsError(try ServerPath(absolute: "tmp"))
        XCTAssertEqual(try ServerPath(absolute: "/tmp").rawValue, "/tmp")

        XCTAssertNil(code { try ServerPath("").validateRelative() })
        XCTAssertNil(code { try ServerPath("src/a.swift").validateRelative() })
        XCTAssertEqual(code { try ServerPath("/etc/passwd").validateRelative() }, .badPath)

        for bad in ["", ".", "..", "a/b", "a\u{0}"] {
            XCTAssertEqual(code { try ServerPath(bad).validateComponent() }, .badPath, bad)
        }
        XCTAssertNil(code { try ServerPath("..a").validateComponent() })

        XCTAssertEqual(code { try ServerPath("").validate() }, .badPath)
        XCTAssertEqual(ServerPath("/Users/me/src/").lastComponent, "src")
        XCTAssertEqual(ServerPath("/").lastComponent, "/")
    }

    func testEverySampleIsValid() {
        for body in Samples.requests { XCTAssertNil(code { try body.validate() }, "\(body)") }
        for body in Samples.replies { XCTAssertNil(code { try body.validate() }, "\(body)") }
        for body in Samples.events { XCTAssertNil(code { try body.validate() }, "\(body)") }
        for message in Samples.sessionMessages { XCTAssertNil(code { try message.validate() }, "\(message)") }
        for action in Samples.gitActions {
            XCTAssertNil(code { try GitRequest(project: Samples.project, action: action).validate() }, "\(action)")
        }
        for action in Samples.filesActions {
            XCTAssertNil(code { try FilesRequest(project: Samples.project, action: action).validate() }, "\(action)")
        }
        for reply in Samples.filesReplies { XCTAssertNil(code { try reply.validate() }, "\(reply)") }
    }

    func testSessionRequests() {
        XCTAssertEqual(code { try RequestBody.attach(session: Samples.session, size: Size(cols: 0, rows: 1)).validate() },
                       .badSize)
        XCTAssertEqual(code { try RequestBody.attach(session: Samples.session, size: Size(cols: 4097, rows: 1)).validate() },
                       .badSize)
        XCTAssertEqual(code { try RequestBody.clearScreen(.control).validate() }, .unknownChannel)
        XCTAssertEqual(code { try RequestBody.historyPage(channel: .control, before: nil, maxRows: 10).validate() },
                       .unknownChannel)
        XCTAssertEqual(code { try RequestBody.historyPage(channel: ChannelId(1), before: nil, maxRows: 501).validate() },
                       .badRequest)
        XCTAssertEqual(code {
            try RequestBody.searchHistory(source: .live(.control), query: "a", ignoreCase: true, before: nil,
                                          maxResults: 1).validate()
        }, .unknownChannel)
        XCTAssertEqual(code {
            try RequestBody.searchHistory(source: .saved(Samples.session), query: String(repeating: "a", count: 257),
                                          ignoreCase: true, before: nil, maxResults: 1).validate()
        }, .badRequest)
        XCTAssertEqual(code {
            try RequestBody.writeInput(session: Samples.session, bytes: Data(count: Limits.maxInput + 1)).validate()
        }, .badRequest)
        XCTAssertEqual(code { try RequestBody.hello(Hello(versions: [], client: .cli)).validate() }, .badRequest)
    }

    func testEnvironmentRules() {
        XCTAssertNil(code { try Validation.environment(["A": "1"]) })
        XCTAssertEqual(code { try Validation.environment(["": "1"]) }, .badRequest)
        XCTAssertEqual(code { try Validation.environment(["A=B": "1"]) }, .badRequest)
        XCTAssertEqual(code { try Validation.environment(["A": "\u{0}"]) }, .badRequest)
        XCTAssertEqual(code { try Validation.environment(["A": String(repeating: "x", count: 64 * 1024)]) }, .badRequest)
        let many = Dictionary(uniqueKeysWithValues: (0 ... 128).map { ("K\($0)", "") })
        XCTAssertEqual(code { try Validation.environment(many) }, .badRequest)
    }

    func testGitRules() {
        func git(_ action: GitAction) -> ErrorCode? {
            code { try GitRequest(project: Samples.project, action: action).validate() }
        }
        XCTAssertEqual(git(.switchBranch("-rf")), .badRequest)
        XCTAssertEqual(git(.switchBranch("")), .badRequest)
        XCTAssertEqual(git(.checkout("xyz")), .badRequest)
        XCTAssertEqual(git(.checkout(String(repeating: "a", count: 65))), .badRequest)
        XCTAssertEqual(git(.commit(message: "  ", stageAll: false, amend: false)), .badRequest)
        XCTAssertNil(git(.commit(message: "", stageAll: false, amend: true)))
        XCTAssertEqual(git(.log(maxCount: 1001, skip: 0)), .badRequest)
        XCTAssertEqual(git(.diff(GitDiffRequest(path: nil))), .badRequest)
        XCTAssertEqual(git(.diff(GitDiffRequest(path: "a", lineLimit: 0))), .badRequest)
        XCTAssertEqual(git(.stage(["a\u{0}"])), .badPath)
        XCTAssertEqual(git(.pullRequest(.list(filter: .open, limit: 201, checks: false))), .badRequest)
        XCTAssertEqual(git(.pullRequest(.close(number: 0))), .badRequest)
        XCTAssertEqual(git(.pullRequest(.create(title: "t", body: "", baseBranch: "-x", draft: false))), .badRequest)
        let register = WorktreeIntent(action: .register(project: Samples.project, directory: "/w"),
                                      options: WorktreeOptions(hooks: []))
        XCTAssertEqual(git(.worktree(register)), .badRequest)
        let named = WorktreeIntent(action: .register(project: Samples.project, directory: "/w"),
                                   options: WorktreeOptions(name: "x"))
        XCTAssertEqual(git(.worktree(named)), .badRequest)
    }

    func testFilesRules() {
        func files(_ action: FilesAction) -> ErrorCode? {
            code { try FilesRequest(project: Samples.project, action: action).validate() }
        }
        XCTAssertEqual(files(.read("/etc/passwd")), .badPath)
        XCTAssertEqual(files(.rename(path: "a", name: "../b")), .badPath)
        XCTAssertEqual(files(.write(path: "a", content: String(repeating: "x", count: Limits.maxFileBytes + 1))),
                       .badRequest)
        XCTAssertEqual(files(.delete(Array(repeating: "a", count: 4097))), .badRequest)
        XCTAssertEqual(files(.searchContent(ContentSearchQuery(query: ""))), .badRequest)
        XCTAssertEqual(files(.searchContent(ContentSearchQuery(query: "a", maxMatchesPerFile: 201))), .badRequest)
        XCTAssertEqual(code { try FilesReply.content(FileContent(path: "a", content: "abc", size: 2)).validate() },
                       .badRequest)
        XCTAssertEqual(code { try FileChanges(paths: ["a"], rescan: true).validate() }, .badRequest)
    }

    func testExecAndUploadRules() {
        let valid = ExecRequest(job: 1, project: Samples.project, argv: ["ls"])
        XCTAssertNil(code { try valid.validate() })
        var both = valid
        both.shell = "ls"
        XCTAssertEqual(code { try both.validate() }, .badRequest)
        var neither = valid
        neither.argv = []
        XCTAssertEqual(code { try neither.validate() }, .badRequest)
        var slow = valid
        slow.timeoutMs = Limits.maxExecTimeoutMs + 1
        XCTAssertEqual(code { try slow.validate() }, .badRequest)
        var noJob = valid
        noJob.job = 0
        XCTAssertEqual(code { try noJob.validate() }, .badRequest)

        let chunk = UploadChunk(session: Samples.session, upload: Samples.operation, name: "a", offset: .max,
                                bytes: Data([1]), last: false)
        XCTAssertEqual(code { try chunk.validate() }, .badRequest)
        let tooFar = UploadChunk(session: Samples.session, upload: Samples.operation, name: "a",
                                 offset: Limits.maxUploadBytes, bytes: Data([1]), last: true)
        XCTAssertEqual(code { try tooFar.validate() }, .badRequest)
        XCTAssertEqual(code { try ReplyBody.uploaded("relative").validate() }, .badPath)
    }

    func testScreenReplies() {
        var snapshot = Samples.snapshot
        snapshot.prompts = [2, 1]
        XCTAssertEqual(code { try ReplyBody.attached(snapshot: snapshot, process: nil).validate() }, .badRequest)
        var screen = Samples.savedScreen
        screen.cursor.row = screen.size.rows
        XCTAssertEqual(code { try screen.validate() }, .badRequest)
        let ascending = SearchPage(matches: [SearchMatch(row: 1, start: 0, end: 1), SearchMatch(row: 2, start: 0, end: 1)],
                                   totalRows: 5, scannedRows: 5)
        XCTAssertEqual(code { try ascending.validate() }, .badRequest)
        let zeroCursor = SearchPage(matches: [], next: HistoryCursor(0), totalRows: 5, scannedRows: 5)
        XCTAssertEqual(code { try zeroCursor.validate() }, .badRequest)
    }

    func testGraphicsRules() {
        var graphics = Samples.graphics
        XCTAssertNil(code { try graphics.validate() })
        graphics.images[0].rgba = Data(count: 3)
        XCTAssertEqual(code { try graphics.validate() }, .badRequest)
        graphics = Samples.graphics
        graphics.placements[0].source = (x: 0, y: 1, width: 1, height: 2)
        XCTAssertEqual(code { try graphics.validate() }, .badRequest)
        graphics = Samples.graphics
        graphics.placements[0].source = (x: .max, y: 0, width: 2, height: 1)
        XCTAssertEqual(code { try graphics.validate() }, .badRequest)
        graphics = Samples.graphics
        graphics.placements[0].image = 99
        XCTAssertEqual(code { try graphics.validate() }, .badRequest)
        graphics = Samples.graphics
        graphics.images.append(graphics.images[0])
        XCTAssertEqual(code { try graphics.validate() }, .badRequest)
    }

    func testInputRules() {
        XCTAssertEqual(code { try KeyEvent(key: "a\u{1b}").validate() }, .badRequest)
        XCTAssertEqual(code { try KeyEvent(key: "a", text: "\u{f700}").validate() }, .badRequest)
        XCTAssertEqual(code { try KeyEvent(key: "a", unshiftedCodepoint: 0xD800).validate() }, .badRequest)
        XCTAssertEqual(code { try MouseEvent(action: .press, col: 0, row: 0).validate() }, .badRequest)
        XCTAssertEqual(code { try MouseEvent(action: .scroll, button: .left, scroll: .up, col: 0, row: 0).validate() },
                       .badRequest)
        XCTAssertEqual(code { try MetadataEvent.clipboardWrite("").validate() }, .badRequest)
        XCTAssertEqual(code { try SessionMessage.cellSize(CellSize(width: 0, height: 1)).validate() }, .badSize)
        XCTAssertEqual(code {
            try MetadataEvent.links(seq: 1, rows: [LinkRow(row: 0, spans: [LinkSpan(start: 2, end: 1, uri: "x")])]).validate()
        }, .badRequest)
    }

    func testCatalogRules() {
        let home = ProjectDescriptor.home(directory: "/Users/me")
        let page = CatalogPage(server: Samples.server, home: Samples.project, revision: 1, projects: [home])
        XCTAssertEqual(code { try page.validate() }, .badRequest, "a home that isn't the page's home")
        XCTAssertEqual(code { try ProjectMutation.create(home).validate() }, .badRequest)
        let orphan = ProjectDescriptor(directory: "/a", name: "a", kind: .worktree)
        XCTAssertEqual(code { try orphan.validate() }, .badRequest)
        XCTAssertEqual(code { try ProjectMutation.rename(project: Samples.project, name: "  ").validate() }, .badRequest)
        XCTAssertEqual(code { try ProjectMutation.create(ProjectDescriptor(directory: "/a", name: "a",
                                                                           kind: .unknown("x"), parentId: Samples.parent))
                .validate() }, .badRequest)
    }

    func testPairingLinkRoundTripsAndRejectsTampering() throws {
        let invite = Samples.invite
        XCTAssertTrue(invite.link.hasPrefix("tab://pair?v=1&h=mac.local&p=7419&f="))
        XCTAssertEqual(try PairingInvite(link: invite.link), invite)
        for bad in [
            invite.link.replacingOccurrences(of: "v=1", with: "v=2"),
            invite.link.replacingOccurrences(of: "p=7419", with: "p=80"),
            invite.link.replacingOccurrences(of: "p=7419", with: "p=+7419"),
            invite.link + "&x=1",
            invite.link + "&p=7419",
            invite.link.replacingOccurrences(of: "h=mac.local", with: "h=mac.local:22"),
            "codesh://pair?v=1",
        ] {
            XCTAssertThrowsError(try PairingInvite(link: bad), bad)
        }
        XCTAssertEqual(code { try Validation.pairingHosts(Array(repeating: "a", count: 9)) }, .badRequest)
        XCTAssertEqual(code { try Validation.deviceName("Phone\n") }, .badRequest)
        XCTAssertEqual(code { try RemoteAccessSettings(enabled: true, port: 80).validate() }, .badRequest)
    }
}
