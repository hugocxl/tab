import Darwin
import Foundation
import TabProtocol

extension MachineInfo {
    /// This computer, read from the kernel. Cheap enough to call per agent
    /// start, but servers read it once.
    public static func current() -> MachineInfo {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let patch = version.patchVersion == 0 ? "" : ".\(version.patchVersion)"
        return MachineInfo(
            name: Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
            chip: sysctlString("machdep.cpu.brand_string"),
            architecture: sysctlString("hw.machine"),
            cores: ProcessInfo.processInfo.processorCount,
            memoryBytes: ProcessInfo.processInfo.physicalMemory,
            system: "macOS \(version.majorVersion).\(version.minorVersion)\(patch)"
        )
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let value = String(cString: buffer).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }
}

extension Infrastructure {
    /// What `infrastructure.json` holds, or `nil` when it is missing or unreadable.
    public static func read(from url: URL) -> Infrastructure? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Infrastructure.self, from: data)
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try AtomicFile.write(try encoder.encode(self), to: url)
    }
}
