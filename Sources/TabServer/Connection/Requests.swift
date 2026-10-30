import Foundation
import TabProtocol

extension ClientConnection {
    /// Routes a control request. Pings answer at once; Git, files and exec
    /// run concurrently; everything else runs in order on the worker.
    func request(_ id: RequestId, _ body: RequestBody) {
        do {
            try body.validate()
            try permit(body)
        } catch {
            reply(id, .error(errorReply(error)))
            return
        }
        switch body {
        case .ping:
            reply(id, .pong)
        case .hello:
            reply(id, .error(ErrorReply(code: .badRequest, message: "The connection already said hello")))
        case .unknown:
            reply(id, .error(errorReply(ServiceError.unsupportedRequest)))
        case .authenticate, .pair:
            reply(id, .error(ErrorReply(code: .badRequest,
                                        message: "Authentication is only the first request of a phone's connection")))
        case .git(let request):
            guard let git = server.services.git else { return unavailable(id, "Git") }
            let client = self.client.id
            Task { [self] in
                reply(id, await asyncResult { .git(try await git.handle(request, client: client)) })
            }
        case .files(let request):
            guard let files = server.services.files else { return unavailable(id, "Files") }
            let client = self.client.id
            Task { [self] in
                reply(id, await asyncResult { .files(try await files.handle(request, client: client)) })
            }
        case .agentChat(let request):
            Task { [self] in
                reply(id, await asyncResult { .agentChat(try await server.agents.handle(request)) })
            }
        case .exec(let request):
            do {
                let root = try server.projectPath(request.project)
                try jobs.start(request, root: root, disconnected: { [weak self] in self?.isClosed ?? true }) {
                    [weak self] result in
                    self?.reply(id, result.map { ReplyBody.exec($0) })
                }
            } catch {
                reply(id, .error(errorReply(error)))
            }
        case .cancelExec(let job):
            jobs.cancel(job)
            reply(id, .execCancelled)
        default:
            worker.async { [self] in
                guard !isClosed else { return }
                do {
                    if let body = try ordered(id, body) { reply(id, body) }
                } catch {
                    reply(id, .error(errorReply(error)))
                }
            }
        }
    }

    private func unavailable(_ id: RequestId, _ service: String) {
        reply(id, .error(ErrorReply(code: .unsupported, message: "\(service) is not available on this server")))
    }

    /// Phones can reach a shell already, so the limits guard the server's
    /// lifecycle, settings, commands and access management, not data.
    func permit(_ body: RequestBody) throws {
        guard case .mobile = origin else { return }
        switch body {
        case .stopServer, .stopServerIfIdle, .restartServer, .writeServerSettings, .exec, .cancelExec,
             .readRemoteAccess, .writeRemoteAccess, .startPairing, .cancelPairing, .revokeDevice:
            throw ServiceError(.unauthorized, "Not available to paired devices")
        case .identifyClient(let kind) where kind != .mobile:
            throw ServiceError(.unauthorized, "Not available to paired devices")
        default:
            return
        }
    }

    /// Handles a request on the worker. `nil` means the reply comes later.
    private func ordered(_ id: RequestId, _ body: RequestBody) throws -> ReplyBody? {
        switch body {
        // Sessions
        case .listSessions:
            return .sessions(server.liveSessions())
        case .createSession(let request):
            return .sessionCreated(try server.createSession(request, requester: self))
        case .attach(let session, let size):
            try attach(server.attachable(session, requester: self), size: size, request: id)
            return nil
        case .attachWithoutResize(let session):
            try attach(server.attachable(session, requester: self), size: nil, request: id)
            return nil
        case .detach(let channel):
            try detach(channel)
            return .detached
        case .endSession(let session):
            guard let owner = server.owner(session) else { throw ServiceError.unknownSession(session) }
            owner.end(.ended) { [weak self] _ in self?.reply(id, .sessionEnded) }
            return nil
        case .closeSession(let session, let operation):
            try server.closeSession(session, operation: operation, requester: self)
            return .sessionClosed
        case .discardSession(let session):
            try server.discard(session)
            return .sessionDiscarded
        case .cancelCreation(let operation):
            try server.cancelCreation(operation)
            return .creationCancelled
        case .readSavedScreen(let session):
            return .savedScreen(try server.archive.readScreen(session))
        case .historyPage(let channel, let before, let maxRows):
            try owner(of: channel).historyPage(before: before, maxRows: maxRows) { [weak self] result in
                self?.reply(id, result.map { ReplyBody.historyPage($0) })
            }
            return nil
        case .savedHistoryPage(let session, let before, let maxRows):
            return .historyPage(try server.archive.historyPage(session, before: before, maxRows: maxRows))
        case .searchHistory(.live(let channel), let query, let ignoreCase, let before, let maxResults):
            try owner(of: channel).search(query: query, ignoreCase: ignoreCase, before: before,
                                          maxResults: maxResults) { [weak self] result in
                self?.reply(id, result.map { ReplyBody.searchPage($0) })
            }
            return nil
        case .searchHistory(.saved(let session), let query, let ignoreCase, let before, let maxResults):
            return .searchPage(try server.archive.search(session, query: query, ignoreCase: ignoreCase,
                                                         before: before, maxResults: maxResults))
        case .clearScreen(let channel):
            try owner(of: channel).clearScreen { [weak self] error in
                self?.reply(id, error.map { .error(errorReply($0)) } ?? .screenCleared)
            }
            return nil
        case .setTerminalColors(let colors):
            setColors(colors)
            return .terminalColorsSet
        case .syncSessionReferences(let owner, let revision, let sessions):
            server.syncReferences(requester: self, owner: owner, revision: revision, sessions: sessions)
            return .sessionReferencesSynced
        case .identifyClient(let kind):
            guard kind.isKnown else { throw ServiceError(.unsupported, "This server doesn't know the client kind") }
            return .clientIdentified(setKind(kind))
        case .writeInput(let session, let bytes):
            guard let owner = server.owner(session) else { throw ServiceError.unknownSession(session) }
            owner.writeInput(bytes) { [weak self] error in
                let failure = error.map { ServiceError(.badRequest, "The terminal didn't take the input: \($0)") }
                self?.reply(id, failure.map { .error(errorReply($0)) } ?? .inputWritten)
            }
            return nil

        // Catalog
        case .readCatalog(let after, let revision):
            watchCatalog()
            return .catalog(try server.catalog.page(after: after, revision: revision))
        case .mutateProject(let intent):
            return .projectMutated(revision: try server.mutateProject(intent))
        case .listProjectSessions(let project, let after, let revision):
            watchCatalog()
            return .projectSessions(try server.projectSessions(project, after: after, revision: revision,
                                                               requester: self))
        case .listFolders(let path):
            return .folders(try Folders.list(path))

        // Server
        case .readServerSettings:
            return .serverSettings(server.settings.settings)
        case .writeServerSettings(let settings):
            try server.settings.write(settings)
            return .serverSettingsWritten
        case .stopServer(let force):
            return server.requestStop(force: force)
        case .stopServerIfIdle:
            return server.requestStopIfIdle()
        case .restartServer:
            return server.requestRestart()

        // Uploads and activity
        case .upload(let chunk):
            guard server.catalog.record(chunk.session) != nil else { throw ServiceError.unknownSession(chunk.session) }
            return .uploaded(try server.uploads.receive(chunk))
        case .readActivity:
            watchActivity()
            return .activity(server.activity.snapshot())
        case .acknowledgeActivity(let ids):
            server.activity.acknowledge(ids)
            return .activityAcknowledged
        case .claimActivity(let ids):
            return .activityClaimed(server.claimActivity(ids, requester: self))

        // Mobile access
        case .readRemoteAccess:
            return .remoteAccess(try remote().state())
        case .writeRemoteAccess(let settings):
            let remote = try remote()
            try remote.write(settings)
            return .remoteAccess(remote.state())
        case .startPairing(let hosts):
            let offer = try remote().startPairing(hosts: hosts)
            lock.withLock { pairingCode = offer.invite.code }
            return .pairing(offer)
        case .cancelPairing:
            let remote = try remote()
            remote.cancelPairing()
            return .remoteAccess(remote.state())
        case .revokeDevice(let device):
            let remote = try remote()
            try remote.revoke(device)
            return .remoteAccess(remote.state())

        case .hello, .ping, .unknown, .authenticate, .pair, .git, .files, .exec, .cancelExec, .agentChat:
            throw ServiceError(.badRequest, "Unexpected request")
        }
    }

    private func remote() throws -> RemoteAccessProtocol {
        guard let remote = server.services.remote else {
            throw ServiceError(.unsupported, "Mobile access is not available on this server")
        }
        return remote
    }
}

/// Folder names in a directory, for remote project pickers.
enum Folders {
    static func list(_ path: ServerPath) throws -> [ServerPath] {
        guard path.isDirectory else { throw ServiceError(.badPath, "\(path.rawValue) is not a folder") }
        let url = path.url
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [])
        } catch {
            throw ServiceError(.badPath, "\(path.rawValue) can't be read: \(error.localizedDescription)")
        }
        var names: [String] = []
        var bytes = 0
        for entry in entries {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let name = entry.lastPathComponent
            guard !name.isEmpty, name != ".", name != "..", !name.contains("\0") else { continue }
            bytes += name.utf8.count
            guard names.count < Limits.maxFileEntries, bytes <= Limits.maxFilePathBytes else { break }
            names.append(name)
        }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }.map { ServerPath($0) }
    }
}

private func asyncResult(_ body: () async throws -> ReplyBody) async -> Result<ReplyBody, Error> {
    do {
        return .success(try await body())
    } catch {
        return .failure(error)
    }
}
