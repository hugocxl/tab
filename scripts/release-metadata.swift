// Writes the schema-1 feed from the final DMG and its bundled build metadata.
// Usage: swift scripts/release-metadata.swift <app> <dmg> <team-id|-> <output>
import CryptoKit
import Foundation

func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw NSError(domain: "TabRelease", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

func buildInfo(_ app: URL, _ name: String) throws -> NSDictionary {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = app.appendingPathComponent("Contents/MacOS/\(name)")
    process.arguments = ["--build-info"]
    process.standardOutput = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    try require(process.terminationStatus == 0, "\(name) --build-info failed")
    guard let info = try JSONSerialization.jsonObject(with: data) as? NSDictionary else {
        throw NSError(domain: "TabRelease", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid build metadata from \(name)"])
    }
    return info
}

do {
    try require(CommandLine.arguments.count == 5, "Expected <app> <dmg> <team-id|-> <output>")
    let app = URL(fileURLWithPath: CommandLine.arguments[1])
    let dmg = URL(fileURLWithPath: CommandLine.arguments[2])
    let team = CommandLine.arguments[3]
    let info = try PropertyListSerialization.propertyList(
        from: Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")), format: nil) as! [String: Any]
    guard let version = info["CFBundleShortVersionString"] as? String,
          let minimum = info["LSMinimumSystemVersion"] as? String else {
        throw NSError(domain: "TabRelease", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing bundle version or minimum macOS"])
    }
    try require(version.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil,
                "The updater needs an X.Y.Z release version")
    try require(dmg.lastPathComponent == "Tab-\(version)-arm64.dmg", "Unexpected DMG filename")
    try require(team == "-" || team.range(of: #"^[A-Z0-9]{10}$"#, options: .regularExpression) != nil,
                "Invalid Apple team identifier")
    let server = try buildInfo(app, "tabd")
    let client = try buildInfo(app, "tab")
    try require(client == server && server["version"] as? String == version,
                "The bundled client and server must match the release version and build info")
    guard let versions = server["protocol"] as? [Int], !versions.isEmpty,
          versions.allSatisfy({ (1...65535).contains($0) }), server["compatibility"] as? Int != nil else {
        throw NSError(domain: "TabRelease", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid protocol build info"])
    }
    let size = try dmg.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    try require(size > 0 && size <= 2 * 1024 * 1024 * 1024, "Invalid DMG size")
    let file = try FileHandle(forReadingFrom: dmg)
    defer { try? file.close() }
    var hash = SHA256()
    while let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
    let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
    let asset: [String: Any] = [
        "url": "https://github.com/hugocxl/tab/releases/download/v\(version)/\(dmg.lastPathComponent)",
        "sha256": digest, "size": size,
    ]
    let manifest: [String: Any] = [
        "schema": 1, "version": version, "platforms": ["macos-aarch64": asset],
        "buildInfo": server, "protocolVersions": versions,
        "teamID": team == "-" ? NSNull() : team as Any,
        "minimumSystemVersion": minimum,
    ]
    var data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    data.append(0x0a)
    try data.write(to: URL(fileURLWithPath: CommandLine.arguments[4]), options: .atomic)
} catch {
    FileHandle.standardError.write(Data("release metadata: \(error.localizedDescription)\n".utf8))
    exit(1)
}
