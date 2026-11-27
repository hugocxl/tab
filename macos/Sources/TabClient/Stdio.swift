import Foundation
import TabProtocol

/// `tab stdio`: the bridge a client on another computer runs over ssh. It
/// joins this process's stdin and stdout to the local server's socket and
/// relays bytes both ways, unchanged and unbuffered, until either side closes.
public enum StdioBridge {
    /// Connects (starting the server if `start` allows), writes the ready
    /// line, then relays until either side closes.
    public static func serve(_ server: LocalServer, start: BridgeStart) throws {
        let socket: ByteStream = switch start {
        case .ifNeeded: try server.listeningStream()
        case .never: try server.runningStream()
        }
        let local = try FileDescriptorStream(readDescriptor: STDIN_FILENO, writeDescriptor: STDOUT_FILENO,
                                             ownsDescriptors: false)
        try local.write(Bridge.readyLine)
        relay(local, socket)
    }

    /// Copies `a` to `b` and `b` to `a` until one side ends, then closes both.
    public static func relay(_ a: ByteStream, _ b: ByteStream) {
        let finished = DispatchSemaphore(value: 0)
        let group = DispatchGroup()
        for (source, destination) in [(a, b), (b, a)] {
            group.enter()
            let thread = Thread {
                pump(from: source, to: destination)
                finished.signal()
                group.leave()
            }
            thread.name = "TabClient.stdio"
            thread.start()
        }
        finished.wait()
        a.close()
        b.close()
        group.wait()
    }

    private static func pump(from source: ByteStream, to destination: ByteStream) {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            guard let count = try? chunk.withUnsafeMutableBytes({ try source.read(into: $0) }), count > 0 else { return }
            do {
                try destination.write(Data(chunk[0 ..< count]))
            } catch {
                return
            }
        }
    }
}
