import Foundation
import TabProtocol

/// How a provider's CLI was installed, which decides how it updates: Homebrew and the
/// JavaScript package managers update their own copy, and some CLIs update themselves.
/// Mirrors the provider source's maintenance resolver, which reads ownership from the
/// executable's real path rather than asking every package manager.
enum AgentProviderInstallation: Equatable, Sendable {
    case homebrew(name: String, cask: Bool, brew: String)
    case npm(package: String, npm: String)
    case bun(package: String, bun: String)
    case pnpm(package: String, pnpm: String)
    /// The CLI updates itself with these arguments.
    case selfUpdating(executable: String, arguments: [String])
    /// Read-only, such as the Nix store, or installed some other way.
    case manual

    /// Who installed it, as the app names it.
    var label: String? {
        switch self {
        case .homebrew: "Homebrew"
        case .npm: "npm"
        case .bun: "Bun"
        case .pnpm: "pnpm"
        case .selfUpdating: "its own installer"
        case .manual: nil
        }
    }

    /// The program and arguments that update it.
    var update: (executable: String, arguments: [String])? {
        switch self {
        case let .homebrew(name, cask, brew): (brew, ["upgrade"] + (cask ? ["--cask"] : []) + [name])
        case let .npm(package, npm): (npm, ["install", "-g", package + "@latest"])
        case let .bun(package, bun): (bun, ["add", "-g", package + "@latest"])
        case let .pnpm(package, pnpm): (pnpm, ["add", "-g", package + "@latest"])
        case let .selfUpdating(executable, arguments): (executable, arguments)
        case .manual: nil
        }
    }

    /// Runs of tools that share a package store wait for each other.
    var lockKey: String {
        switch self {
        case .homebrew: "brew"
        case let .npm(_, npm): "npm:" + npm
        case .bun: "bun"
        case .pnpm: "pnpm"
        case let .selfUpdating(executable, _): "self:" + executable
        case .manual: "manual"
        }
    }

    /// Where the latest release is looked up.
    func latestSource(_ spec: AgentProviderSpec) -> AgentProviderLatestSource? {
        switch self {
        case let .homebrew(name, cask, brew): .homebrew(name: name, cask: cask, brew: brew)
        case let .npm(package, _), let .bun(package, _), let .pnpm(package, _): .npm(package)
        case .selfUpdating, .manual:
            spec.releaseManifest.flatMap(AgentProviderRelease.manifestURL).map(AgentProviderLatestSource.manifest)
                ?? spec.npmPackage.map(AgentProviderLatestSource.npm)
        }
    }

    /// Who owns `executable`, from its real path.
    static func detect(_ executable: URL, spec: AgentProviderSpec, environment: [String: String]) -> AgentProviderInstallation {
        let resolved = executable.resolvingSymlinksInPath().path
        if resolved.hasPrefix("/nix/store/") { return .manual }
        if let range = resolved.range(of: #"/(Cellar|Caskroom)/[^/]+/"#, options: .regularExpression),
           let brew = locate("brew", environment: environment, fallback: ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]) {
            let match = resolved[range].split(separator: "/")
            if match.count == 2 { return .homebrew(name: String(match[1]), cask: match[0] == "Caskroom", brew: brew) }
        }
        if let package = nodePackage(resolved) {
            if resolved.contains("/.bun/install/global/node_modules/"),
               let bun = locate("bun", environment: environment, fallback: [NSHomeDirectory() + "/.bun/bin/bun"]) {
                return .bun(package: package, bun: bun)
            }
            if resolved.contains("/pnpm/global/") || resolved.contains("/Library/pnpm/"),
               let pnpm = locate("pnpm", environment: environment, fallback: []) {
                return .pnpm(package: package, pnpm: pnpm)
            }
            if let prefix = resolved.range(of: "/lib/node_modules/").map({ String(resolved[..<$0.lowerBound]) }) {
                // The npm next to the package's own Node owns its prefix; another npm would
                // install into a different one and leave this copy as it was.
                let own = prefix + "/bin/npm"
                if FileManager.default.isExecutableFile(atPath: own) { return .npm(package: package, npm: own) }
                if let npm = locate("npm", environment: environment, fallback: []) { return .npm(package: package, npm: npm) }
            }
        }
        if let arguments = spec.selfUpdateArguments { return .selfUpdating(executable: executable.path, arguments: arguments) }
        return .manual
    }

    /// The package `path` runs from inside a `node_modules` folder, scoped or not.
    static func nodePackage(_ path: String) -> String? {
        guard let range = path.range(of: "/node_modules/", options: .backwards) else { return nil }
        let parts = path[range.upperBound...].split(separator: "/")
        guard let first = parts.first else { return nil }
        if first.hasPrefix("@") {
            guard parts.count > 1 else { return nil }
            return "\(first)/\(parts[1])"
        }
        return String(first)
    }

    /// How Tab would install a missing CLI of `spec`: its vendor's verified release, else
    /// Homebrew, else npm.
    static func install(_ spec: AgentProviderSpec, environment: [String: String]) -> AgentProviderMaintenanceStep? {
        if spec.releaseManifest != nil { return .release(spec) }
        if let name = spec.homebrew,
           let brew = locate("brew", environment: environment, fallback: ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]) {
            return .command(brew, ["install"] + (spec.homebrewIsCask ? ["--cask"] : []) + [name])
        }
        if let package = spec.npmPackage, let npm = locate("npm", environment: environment, fallback: []) {
            return .command(npm, ["install", "-g", package])
        }
        return nil
    }

    static func locate(_ name: String, environment: [String: String], fallback: [String]) -> String? {
        if let found = try? AgentProcess.resolve(name, environment: environment) { return found.path }
        return fallback.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// A command line as a user would type it.
    static func commandLine(_ executable: String, _ arguments: [String]) -> String {
        ([(executable as NSString).lastPathComponent] + arguments).map { argument in
            argument.allSatisfy({ $0.isLetter || $0.isNumber || "-_./@=:".contains($0) }) ? argument : "'\(argument)'"
        }.joined(separator: " ")
    }
}

/// One install or update: a command to run, or a vendor release Tab downloads and checks itself.
enum AgentProviderMaintenanceStep: Sendable {
    case command(String, [String])
    case release(AgentProviderSpec)

    /// What the app shows the step as.
    var line: String {
        switch self {
        case let .command(executable, arguments): AgentProviderInstallation.commandLine(executable, arguments)
        case .release(let spec): "Download \(spec.name) from \(spec.vendor ?? "its vendor") and check its SHA-512"
        }
    }
}

/// Where a provider's latest release is published.
enum AgentProviderLatestSource: Hashable, Sendable {
    case npm(String)
    case homebrew(name: String, cask: Bool, brew: String)
    /// A vendor manifest, `{version, url, sha512}`.
    case manifest(URL)

    var cacheKey: String {
        switch self {
        case .npm(let package): "npm:" + package
        case let .homebrew(name, cask, _): (cask ? "cask:" : "brew:") + name
        case .manifest(let url): "manifest:" + url.absoluteString
        }
    }
}

/// Latest releases, looked up at most hourly per package and retried a minute after
/// one couldn't be found, as the provider source's ProviderLatestVersions does.
actor AgentProviderLatestVersions {
    static let foundLifetime: TimeInterval = 3600
    static let missingLifetime: TimeInterval = 60

    private var entries: [String: (expires: Date, version: String?)] = [:]
    private var running: [String: Task<String?, Never>] = [:]
    private let now: @Sendable () -> Date
    private let lookup: @Sendable (AgentProviderLatestSource) async -> String?

    init(now: @escaping @Sendable () -> Date = { Date() },
         lookup: @escaping @Sendable (AgentProviderLatestSource) async -> String? = { await AgentProviderLatestVersions.fetch($0) }) {
        self.now = now
        self.lookup = lookup
    }

    func latest(_ source: AgentProviderLatestSource, fresh: Bool = false) async -> String? {
        let key = source.cacheKey
        if !fresh, let entry = entries[key], entry.expires > now() { return entry.version }
        if let task = running[key] { return await task.value }
        let lookup = lookup
        let task = Task { await lookup(source) }
        running[key] = task
        let version = await task.value
        running[key] = nil
        entries[key] = (now().addingTimeInterval(version == nil ? Self.missingLifetime : Self.foundLifetime), version)
        return version
    }

    func invalidate() { entries = [:] }

    static func fetch(_ source: AgentProviderLatestSource) async -> String? {
        switch source {
        case .npm(let package):
            let name = package.replacingOccurrences(of: "/", with: "%2F")
            guard let url = URL(string: "https://registry.npmjs.org/\(name)/latest") else { return nil }
            var request = URLRequest(url: url, timeoutInterval: 4)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let version = json["version"] as? String else { return nil }
            return AgentProviderVersion.find(in: version)
        case let .homebrew(name, cask, brew):
            // Homebrew's own metadata says what `brew upgrade` would install.
            let arguments = ["info", "--json=v2"] + (cask ? ["--cask"] : []) + [name]
            guard let output = try? await runBlocking({
                try ProcessRunner.run(brew, arguments, environment: ["HOMEBREW_NO_AUTO_UPDATE": "1", "PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()],
                                      timeout: 15)
            }), output.succeeded else { return nil }
            return homebrewVersion(output.stdout, cask: cask)
        case .manifest(let url):
            return try? await AgentProviderRelease.manifest(url).version
        }
    }

    static func homebrewVersion(_ data: Data, cask: Bool) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if cask {
            return ((json["casks"] as? [[String: Any]])?.first?["version"] as? String).flatMap(AgentProviderVersion.find)
        }
        let versions = (json["formulae"] as? [[String: Any]])?.first?["versions"] as? [String: Any]
        return (versions?["stable"] as? String).flatMap(AgentProviderVersion.find)
    }
}
