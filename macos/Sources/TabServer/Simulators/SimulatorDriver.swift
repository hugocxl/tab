import Foundation
import IOSurface
import TabProtocol
import TabSimulators

/// What agents driving one simulator last saw: the refs of its last
/// snapshot and how its screen is held.
@MainActor
final class SimulatorDriver {
    var refs = SimulatorRefs()
    /// How the simulator is held; `nil` until read, and after it turns.
    var orientation: SimulatorOrientation?
    /// Whether the front app draws in landscape, from its last snapshot.
    /// An app that only draws in portrait stays portrait, and frames its
    /// elements so, when the simulator is held sideways.
    var interfaceIsLandscape: Bool?
}

/// The screen as agents address it: upright as the front app draws it, the
/// same as its elements' frames.
private struct ScreenGeometry {
    /// The screen's size in points.
    var size: CGSize
    /// Pixels per point.
    var scale: Double
    /// How the app's drawing turns against the panel.
    var orientation: SimulatorOrientation
    var surfaceIsUpright: Bool

    var screen: SimulatorScreen { SimulatorScreen(width: size.width, height: size.height, scale: scale) }

    /// A touch at `point` on the upright screen, as input fractions.
    func touch(_ point: CGPoint, down: Bool) -> SimulatorInput {
        let upright = CGPoint(x: point.x / max(size.width, 1), y: point.y / max(size.height, 1))
        let panel = surfaceIsUpright ? upright : orientation.panelPoint(upright)
        return .touch(x: panel.x, y: panel.y, down: down)
    }
}

extension SimulatorService {
    /// Runs `drive`'s steps on `simulator`, then reads back what it asks for.
    func drive(_ drive: SimulatorDrive, on simulator: SimulatorRef) async throws -> SimulatorDriveResult {
        try await run(drive, on: simulator)
    }

    @MainActor
    private func run(_ drive: SimulatorDrive, on simulator: SimulatorRef) async throws -> SimulatorDriveResult {
        let source = try await source(simulator)
        guard let automation = source.session as? SimulatorAutomation else {
            if source.isIdle { close(source) }
            throw ServiceError(.unsupported, "This simulator can't be driven")
        }
        return try await withScreen(simulator) { source, surface in
            defer { linger(source) }
            let driver = drivers[simulator] ?? SimulatorDriver()
            drivers[simulator] = driver
            let run = DriveRun(service: self, source: source, automation: automation, driver: driver)
            for step in drive.steps {
                try await run.perform(step)
            }
            var result = SimulatorDriveResult(notes: run.notes)
            if drive.settle { await run.settle() }
            if drive.snapshot != nil || drive.settle {
                let elements = try await run.readElements()
                let hadSnapshot = !driver.refs.isEmpty
                let (assigned, changes) = driver.refs.update(elements)
                // A new screen keeps little of the last: its snapshot says more than a diff.
                let kept = changes.unchanged + changes.changed.count
                let newScreen = kept * 4 < assigned.count
                if let options = drive.snapshot {
                    result.elements = options.interactiveOnly ? assigned.filter(\.interactive) : assigned
                } else if hadSnapshot, !newScreen {
                    result.added = changes.added
                    result.removed = changes.removed
                    result.changed = changes.changed
                    result.unchanged = changes.unchanged
                } else {
                    result.elements = assigned
                }
                result.screen = try? await run.geometry().screen
            }
            if let options = drive.screenshot {
                let geometry = try await run.geometry()
                let current = source.session.surface ?? surface
                let turns = geometry.surfaceIsUpright ? 0 : geometry.orientation.quarterTurns
                let scale = options.fullResolution ? 1 : 1 / max(geometry.scale, 1)
                guard let image = LocalSimulators.image(current, turns: turns, scale: scale, format: options.format,
                                                        quality: options.quality) else {
                    throw ServiceError(.badRequest, "The screen couldn't be read")
                }
                result.image = image
                result.imageFormat = options.format
                result.screen = geometry.screen
            }
            if drive.apps { result.apps = try await automation.apps() }
            if let options = drive.logs { result.logs = try await automation.logs(options) }
            result.notes = run.notes
            return result
        }
    }
}

/// One drive request's steps, on the main actor.
@MainActor
private final class DriveRun {
    let service: SimulatorService
    let source: SimulatorService.Source
    let automation: SimulatorAutomation
    let driver: SimulatorDriver
    var notes: [String] = []
    private var cachedGeometry: ScreenGeometry?

    init(service: SimulatorService, source: SimulatorService.Source, automation: SimulatorAutomation, driver: SimulatorDriver) {
        self.service = service
        self.source = source
        self.automation = automation
        self.driver = driver
    }

    /// The front app's elements, compacted, noting which way it draws.
    func readElements() async throws -> [SimulatorElement] {
        let elements = try await automation.elements()
        if let app = elements.first, app.width > 0, app.height > 0 {
            let landscape = app.width > app.height
            if driver.interfaceIsLandscape != landscape { cachedGeometry = nil }
            driver.interfaceIsLandscape = landscape
        }
        return SimulatorRefs.compact(elements)
    }

    /// The app on screen may have changed, and the way it draws with it.
    private func appMayHaveChanged() {
        driver.interfaceIsLandscape = nil
        cachedGeometry = nil
    }

    func geometry() async throws -> ScreenGeometry {
        if let cachedGeometry { return cachedGeometry }
        guard let surface = source.session.surface else { throw ServiceError(.badRequest, "The simulator's screen didn't appear") }
        let scale = try await automation.pointScale()
        let upright = automation.surfaceIsUpright
        var orientation: SimulatorOrientation
        if upright {
            orientation = .portrait
        } else if let known = driver.orientation {
            orientation = known
        } else {
            orientation = (try? await source.session.orientation()) ?? .portrait
            driver.orientation = orientation
        }
        if orientation.isLandscape, !upright {
            if driver.interfaceIsLandscape == nil { _ = try? await readElements() }
            if driver.interfaceIsLandscape == false { orientation = .portrait }
        }
        let pixels = CGSize(width: Double(surface.width), height: Double(surface.height))
        let points = CGSize(width: pixels.width / scale, height: pixels.height / scale)
        let size = !upright && orientation.isLandscape ? CGSize(width: points.height, height: points.width) : points
        let geometry = ScreenGeometry(size: size, scale: scale, orientation: orientation, surfaceIsUpright: upright)
        cachedGeometry = geometry
        return geometry
    }

    // MARK: Steps

    func perform(_ step: SimulatorStep) async throws {
        switch step {
        case .tap(let target, let count, let hold):
            let point = try await locate(target)
            let geometry = try await geometry()
            for index in 0 ..< count {
                if index > 0 { try await pause(0.08) }
                send([geometry.touch(point, down: true)])
                try await pause(hold > 0 ? hold : 0.03)
                send([geometry.touch(point, down: false)])
            }
        case .swipe(let from, let to, let duration):
            let start = try await locate(from)
            let end = try await locate(to)
            try await drag(from: start, to: end, duration: duration)
        case .scroll(let direction, let distance, let within):
            let geometry = try await geometry()
            var area = CGRect(origin: .zero, size: geometry.size)
            if let within { area = try await frame(within) }
            area = area.intersection(CGRect(origin: .zero, size: geometry.size))
            guard !area.isNull, area.width > 4, area.height > 4 else {
                throw ServiceError(.badRequest, "\(within.map(\.description) ?? "The screen") has no room to scroll")
            }
            let center = CGPoint(x: area.midX, y: area.midY)
            let dx = area.width * distance / 2
            let dy = area.height * distance / 2
            // Content moving down into view means the finger moves up.
            let (start, end): (CGPoint, CGPoint) = switch direction {
            case .down: (CGPoint(x: center.x, y: center.y + dy), CGPoint(x: center.x, y: center.y - dy))
            case .up: (CGPoint(x: center.x, y: center.y - dy), CGPoint(x: center.x, y: center.y + dy))
            case .right: (CGPoint(x: center.x + dx, y: center.y), CGPoint(x: center.x - dx, y: center.y))
            case .left: (CGPoint(x: center.x - dx, y: center.y), CGPoint(x: center.x + dx, y: center.y))
            }
            try await drag(from: start, to: end, duration: 0.35)
        case .type(let text):
            try await type(text)
        case .fill(let target, let text):
            let point = try await locate(target)
            let geometry = try await geometry()
            send([geometry.touch(point, down: true)])
            try await pause(0.03)
            send([geometry.touch(point, down: false)])
            try await pause(0.35)
            let selectAll = source.simulator.platform == .android ? "ctrl+a" : "cmd+a"
            send(SimulatorKeyboard.chord(selectAll) ?? [])
            try await pause(0.1)
            if text.isEmpty {
                send(SimulatorKeyboard.chord("backspace") ?? [])
            } else {
                try await type(text)
            }
        case .key(let name):
            guard let input = SimulatorKeyboard.chord(name) else {
                throw ServiceError(.badRequest, "Unknown key \(name); keys are names such as return, backspace, tab, up or cmd+a")
            }
            send(input)
        case .button(let button):
            guard source.session.buttons.contains(button) else {
                throw ServiceError(.badRequest, "This simulator has no \(button.rawValue) button")
            }
            send([.button(button)])
            appMayHaveChanged()
        case .wait(let seconds):
            try await pause(seconds)
        case .waitFor(let target, let gone, let timeout):
            try await waitFor(target, gone: gone, timeout: timeout)
        case .launch(let app):
            try await automation.launch(app)
            appMayHaveChanged()
        case .terminate(let app):
            try await automation.terminate(app)
            appMayHaveChanged()
        case .install(let path):
            try await automation.install(path)
        case .uninstall(let app):
            try await automation.uninstall(app)
        case .openURL(let url):
            try await LocalSimulators.openURL(url, on: source.simulator)
            appMayHaveChanged()
        case .location(let latitude, let longitude):
            try await automation.setLocation(latitude: latitude, longitude: longitude)
        case .unknown(let type):
            throw ServiceError(.unsupported, "This server can't run the step \(type); update Tab on it")
        }
    }

    private func send(_ input: [SimulatorInput]) {
        guard !input.isEmpty else { return }
        source.session.send(input)
    }

    private func pause(_ seconds: Double) async throws {
        guard seconds > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// Moves one finger from `start` to `end`, about 60 moves a second.
    private func drag(from start: CGPoint, to end: CGPoint, duration: Double) async throws {
        let geometry = try await geometry()
        let moves = max(6, min(120, Int(duration * 60)))
        send([geometry.touch(start, down: true)])
        for index in 1 ... moves {
            try await pause(max(duration, 0.05) / Double(moves))
            let t = Double(index) / Double(moves)
            let point = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            send([geometry.touch(point, down: true)])
        }
        send([geometry.touch(end, down: false)])
    }

    private func type(_ text: String) async throws {
        if SimulatorKeyboard.canType(text) {
            send(SimulatorKeyboard.input(typing: text))
            return
        }
        // Text a US keyboard can't type goes through the pasteboard.
        do {
            try await automation.setPasteboard(text)
        } catch {
            send(SimulatorKeyboard.input(typing: text))
            notes.append("Some characters were skipped: only what a US keyboard types reaches this simulator")
            return
        }
        send(SimulatorKeyboard.chord(source.simulator.platform == .android ? "ctrl+v" : "cmd+v") ?? [])
    }

    // MARK: Targets

    /// The point a target names on the upright screen.
    private func locate(_ target: SimulatorTarget) async throws -> CGPoint {
        if case .point(let x, let y) = target {
            let size = try await geometry().size
            guard x >= 0, y >= 0, x <= size.width, y <= size.height else {
                throw ServiceError(.badRequest, "\(target) is off the screen, which is \(Int(size.width))×\(Int(size.height)) points")
            }
            return CGPoint(x: x, y: y)
        }
        let frame = try await frame(target)
        let size = try await geometry().size
        let visible = frame.intersection(CGRect(origin: .zero, size: size))
        guard !visible.isNull, visible.width >= 1, visible.height >= 1 else {
            throw ServiceError(.badRequest, "\(target) is off screen; scroll it into view first")
        }
        return CGPoint(x: visible.midX, y: visible.midY)
    }

    private func frame(_ target: SimulatorTarget) async throws -> CGRect {
        let element = try await element(target)
        return CGRect(x: element.x, y: element.y, width: element.width, height: element.height)
    }

    private func element(_ target: SimulatorTarget) async throws -> SimulatorElement {
        switch target {
        case .point(let x, let y):
            return SimulatorElement(role: "point", x: x, y: y, width: 0, height: 0)
        case .ref(let ref):
            if driver.refs.isEmpty {
                throw ServiceError(.badRequest, "No snapshot yet; run tab simulator snapshot to get refs")
            }
            guard let element = driver.refs.element(ref) else {
                throw ServiceError(.badRequest, "@\(ref.hasPrefix("@") ? String(ref.dropFirst()) : ref) isn't in the last snapshot; take a new one")
            }
            return element
        case .label, .identifier:
            if let found = try await find(target) { return found }
            throw ServiceError(.badRequest, "No element has \(target)")
        case .unknown(let type):
            throw ServiceError(.unsupported, "This server doesn't know targets of type \(type)")
        }
    }

    /// Reads the screen and finds a label or identifier on it, updating refs.
    private func find(_ target: SimulatorTarget) async throws -> SimulatorElement? {
        let elements = driver.refs.update(try await readElements()).elements
        switch target {
        case .label(let label): return SimulatorRefs.find(label: label, in: elements)
        case .identifier(let identifier): return SimulatorRefs.find(identifier: identifier, in: elements)
        case .ref(let ref): return elements.first { $0.ref == ref }
        case .point, .unknown: return nil
        }
    }

    private func waitFor(_ target: SimulatorTarget, gone: Bool, timeout: Double) async throws {
        let deadline = ContinuousClock.now + .milliseconds(Int(timeout * 1000))
        while true {
            let present = try await find(target) != nil
            if present != gone { return }
            guard ContinuousClock.now < deadline else {
                throw ServiceError(.badRequest, gone ? "\(target) was still on screen after \(SimulatorTarget.number(timeout)) s"
                    : "\(target) didn't appear within \(SimulatorTarget.number(timeout)) s")
            }
            try await pause(0.25)
        }
    }

    // MARK: Settling

    /// Waits until the screen hasn't drawn for a moment, or 3 seconds pass:
    /// a caret blinking or a spinner never settles.
    func settle() async {
        let start = ContinuousClock.now
        while ContinuousClock.now - start < .seconds(3) {
            try? await pause(0.05)
            if ContinuousClock.now - max(source.lastFrame, start) >= .milliseconds(400) { return }
        }
    }
}
