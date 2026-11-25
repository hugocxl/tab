import Foundation

// Agents drive a simulator with `simulatorDrive`: a list of steps run in
// order, then optionally a wait for the screen to settle, a snapshot of its
// accessibility tree with refs such as `e3`, a screenshot, its apps or its
// logs. Points are the screen's points (pixels over its scale) from the top
// left of the screen as the user sees it, the same as snapshot frames.

/// What a step acts on.
public enum SimulatorTarget: Hashable, Codable, Sendable, CustomStringConvertible {
    /// A point on the upright screen, in points from its top left.
    case point(x: Double, y: Double)
    /// An element of the last snapshot, such as `e3`.
    case ref(String)
    /// The first element whose label is the text, else contains it.
    case label(String)
    /// The first element with this accessibility identifier.
    case identifier(String)
    case unknown(String)

    public init(from decoder: Decoder) throws {
        let c = try TaggedDecoding(decoder)
        switch c.type {
        case "point": self = .point(x: try c("x"), y: try c("y"))
        case "ref": self = .ref(try c("ref"))
        case "label": self = .label(try c("label"))
        case "identifier": self = .identifier(try c("identifier"))
        default: self = .unknown(c.type)
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .point(let x, let y):
            var c = try TaggedEncoding(encoder, "point")
            try c(x, "x")
            try c(y, "y")
        case .ref(let ref):
            var c = try TaggedEncoding(encoder, "ref")
            try c(ref, "ref")
        case .label(let label):
            var c = try TaggedEncoding(encoder, "label")
            try c(label, "label")
        case .identifier(let identifier):
            var c = try TaggedEncoding(encoder, "identifier")
            try c(identifier, "identifier")
        case .unknown(let type): try TaggedEncoding(encoder, type)
        }
    }

    public var description: String {
        switch self {
        case .point(let x, let y): "\(Self.number(x)),\(Self.number(y))"
        case .ref(let ref): "@\(ref)"
        case .label(let label): "label \"\(label)\""
        case .identifier(let identifier): "id \"\(identifier)\""
        case .unknown(let type): type
        }
    }

    public static func number(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }
}

/// Which way content moves into view: `down` shows what is below, so the
/// finger moves up.
public enum SimulatorDirection: String, Hashable, Codable, Sendable, CaseIterable {
    case up, down, left, right
}

/// One thing to do on a simulator.
public enum SimulatorStep: Hashable, Codable, Sendable {
    /// Taps `count` times, holding each `hold` seconds; a long hold is a long press.
    case tap(SimulatorTarget, count: Int, hold: Double)
    /// Drags one finger from one point to another over `duration` seconds.
    case swipe(from: SimulatorTarget, to: SimulatorTarget, duration: Double)
    /// Scrolls the screen, or the element `within`, by a fraction of its size.
    case scroll(SimulatorDirection, distance: Double, within: SimulatorTarget?)
    /// Types text into the focused field.
    case type(String)
    /// Taps a field, selects what it holds and types over it.
    case fill(SimulatorTarget, text: String)
    /// Presses a key or a chord, such as `return`, `backspace` or `cmd+a`.
    case key(String)
    case button(SimulatorButton)
    case wait(seconds: Double)
    /// Waits until an element appears, or with `gone` until it goes.
    case waitFor(SimulatorTarget, gone: Bool, timeout: Double)
    case launch(app: String)
    case terminate(app: String)
    /// Installs an app from a path on the server.
    case install(path: String)
    case uninstall(app: String)
    case openURL(String)
    case location(latitude: Double, longitude: Double)
    case unknown(String)

    public init(from decoder: Decoder) throws {
        let c = try TaggedDecoding(decoder)
        switch c.type {
        case "tap": self = .tap(try c("target"), count: try c("count", default: 1), hold: try c("hold", default: 0))
        case "swipe": self = .swipe(from: try c("from"), to: try c("to"), duration: try c("duration", default: 0.3))
        case "scroll":
            self = .scroll(try c("direction"), distance: try c("distance", default: 0.5),
                           within: try c("within", default: nil))
        case "type": self = .type(try c("text"))
        case "fill": self = .fill(try c("target"), text: try c("text"))
        case "key": self = .key(try c("key"))
        case "button": self = .button(try c("button"))
        case "wait": self = .wait(seconds: try c("seconds"))
        case "waitFor":
            self = .waitFor(try c("target"), gone: try c("gone", default: false), timeout: try c("timeout", default: 5))
        case "launch": self = .launch(app: try c("app"))
        case "terminate": self = .terminate(app: try c("app"))
        case "install": self = .install(path: try c("path"))
        case "uninstall": self = .uninstall(app: try c("app"))
        case "openURL": self = .openURL(try c("url"))
        case "location": self = .location(latitude: try c("latitude"), longitude: try c("longitude"))
        default: self = .unknown(c.type)
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .tap(let target, let count, let hold):
            var c = try TaggedEncoding(encoder, "tap")
            try c(target, "target")
            try c(count, "count")
            try c(hold, "hold")
        case .swipe(let from, let to, let duration):
            var c = try TaggedEncoding(encoder, "swipe")
            try c(from, "from")
            try c(to, "to")
            try c(duration, "duration")
        case .scroll(let direction, let distance, let within):
            var c = try TaggedEncoding(encoder, "scroll")
            try c(direction, "direction")
            try c(distance, "distance")
            try c(within, "within")
        case .type(let text):
            var c = try TaggedEncoding(encoder, "type")
            try c(text, "text")
        case .fill(let target, let text):
            var c = try TaggedEncoding(encoder, "fill")
            try c(target, "target")
            try c(text, "text")
        case .key(let key):
            var c = try TaggedEncoding(encoder, "key")
            try c(key, "key")
        case .button(let button):
            var c = try TaggedEncoding(encoder, "button")
            try c(button, "button")
        case .wait(let seconds):
            var c = try TaggedEncoding(encoder, "wait")
            try c(seconds, "seconds")
        case .waitFor(let target, let gone, let timeout):
            var c = try TaggedEncoding(encoder, "waitFor")
            try c(target, "target")
            try c(gone, "gone")
            try c(timeout, "timeout")
        case .launch(let app):
            var c = try TaggedEncoding(encoder, "launch")
            try c(app, "app")
        case .terminate(let app):
            var c = try TaggedEncoding(encoder, "terminate")
            try c(app, "app")
        case .install(let path):
            var c = try TaggedEncoding(encoder, "install")
            try c(path, "path")
        case .uninstall(let app):
            var c = try TaggedEncoding(encoder, "uninstall")
            try c(app, "app")
        case .openURL(let url):
            var c = try TaggedEncoding(encoder, "openURL")
            try c(url, "url")
        case .location(let latitude, let longitude):
            var c = try TaggedEncoding(encoder, "location")
            try c(latitude, "latitude")
            try c(longitude, "longitude")
        case .unknown(let type): try TaggedEncoding(encoder, type)
        }
    }
}

/// What a snapshot includes.
public struct SimulatorSnapshotOptions: Hashable, Codable, Sendable {
    /// Only elements an agent acts on, such as buttons and fields.
    public var interactiveOnly: Bool

    public init(interactiveOnly: Bool = false) {
        self.interactiveOnly = interactiveOnly
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        interactiveOnly = try container.decodeIfPresent(Bool.self, forKey: .interactiveOnly) ?? false
    }
}

public enum SimulatorImageFormat: String, Hashable, Codable, Sendable {
    case png, jpeg
}

/// How a screenshot is taken. By default it is upright, one pixel per
/// point, so its pixels are the points taps take.
public struct SimulatorScreenshotOptions: Hashable, Codable, Sendable {
    public var format: SimulatorImageFormat
    /// JPEG quality from 1 to 100.
    public var quality: Int
    /// Keeps the screen's own pixels instead of one per point.
    public var fullResolution: Bool

    public init(format: SimulatorImageFormat = .png, quality: Int = 80, fullResolution: Bool = false) {
        self.format = format
        self.quality = quality
        self.fullResolution = fullResolution
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        format = (try? container.decodeIfPresent(SimulatorImageFormat.self, forKey: .format)) ?? .png
        quality = try container.decodeIfPresent(Int.self, forKey: .quality) ?? 80
        fullResolution = try container.decodeIfPresent(Bool.self, forKey: .fullResolution) ?? false
    }
}

/// Which log lines to read.
public struct SimulatorLogOptions: Hashable, Codable, Sendable {
    /// Only this app's lines: a bundle ID or Android package.
    public var app: String?
    /// How far back to read.
    public var seconds: Double
    /// The most lines to return, the latest kept.
    public var lines: Int

    public init(app: String? = nil, seconds: Double = 60, lines: Int = 200) {
        self.app = app
        self.seconds = seconds
        self.lines = lines
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        app = try container.decodeIfPresent(String.self, forKey: .app)
        seconds = try container.decodeIfPresent(Double.self, forKey: .seconds) ?? 60
        lines = try container.decodeIfPresent(Int.self, forKey: .lines) ?? 200
    }
}

/// A request to drive a simulator: steps, then what to read back.
public struct SimulatorDrive: Hashable, Codable, Sendable {
    public var steps: [SimulatorStep]
    /// Waits for the screen to stop changing after the steps, then replies
    /// with what changed since the last snapshot.
    public var settle: Bool
    public var snapshot: SimulatorSnapshotOptions?
    public var screenshot: SimulatorScreenshotOptions?
    /// Lists the installed apps.
    public var apps: Bool
    public var logs: SimulatorLogOptions?

    public init(steps: [SimulatorStep] = [], settle: Bool = false, snapshot: SimulatorSnapshotOptions? = nil,
                screenshot: SimulatorScreenshotOptions? = nil, apps: Bool = false, logs: SimulatorLogOptions? = nil) {
        self.steps = steps
        self.settle = settle
        self.snapshot = snapshot
        self.screenshot = screenshot
        self.apps = apps
        self.logs = logs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        steps = try container.decodeIfPresent([SimulatorStep].self, forKey: .steps) ?? []
        settle = try container.decodeIfPresent(Bool.self, forKey: .settle) ?? false
        snapshot = try container.decodeIfPresent(SimulatorSnapshotOptions.self, forKey: .snapshot)
        screenshot = try container.decodeIfPresent(SimulatorScreenshotOptions.self, forKey: .screenshot)
        apps = try container.decodeIfPresent(Bool.self, forKey: .apps) ?? false
        logs = try container.decodeIfPresent(SimulatorLogOptions.self, forKey: .logs)
    }
}

/// One element on a simulator's screen, from its accessibility tree.
public struct SimulatorElement: Hashable, Codable, Sendable {
    /// Names it in later steps, such as `e3`; kept while it stays on screen.
    public var ref: String
    /// Such as `button`, `text`, `text-field`, `switch` or `cell`.
    public var role: String
    public var label: String?
    public var identifier: String?
    public var value: String?
    /// Its frame in points on the upright screen.
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var enabled: Bool
    /// An agent acts on it, such as a button or a field.
    public var interactive: Bool
    /// How deep it sits under the app, from 0.
    public var depth: Int

    public init(ref: String = "", role: String, label: String? = nil, identifier: String? = nil, value: String? = nil,
                x: Double, y: Double, width: Double, height: Double, enabled: Bool = true, interactive: Bool = false,
                depth: Int = 0) {
        self.ref = ref
        self.role = role
        self.label = label
        self.identifier = identifier
        self.value = value
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.enabled = enabled
        self.interactive = interactive
        self.depth = depth
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ref = try container.decodeIfPresent(String.self, forKey: .ref) ?? ""
        role = try container.decodeIfPresent(String.self, forKey: .role) ?? "element"
        label = try container.decodeIfPresent(String.self, forKey: .label)
        identifier = try container.decodeIfPresent(String.self, forKey: .identifier)
        value = try container.decodeIfPresent(String.self, forKey: .value)
        x = try container.decodeIfPresent(Double.self, forKey: .x) ?? 0
        y = try container.decodeIfPresent(Double.self, forKey: .y) ?? 0
        width = try container.decodeIfPresent(Double.self, forKey: .width) ?? 0
        height = try container.decodeIfPresent(Double.self, forKey: .height) ?? 0
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        interactive = try container.decodeIfPresent(Bool.self, forKey: .interactive) ?? false
        depth = try container.decodeIfPresent(Int.self, forKey: .depth) ?? 0
    }

    public var centerX: Double { x + width / 2 }
    public var centerY: Double { y + height / 2 }
}

/// A simulator's screen as agents address it.
public struct SimulatorScreen: Hashable, Codable, Sendable {
    /// The upright screen's size in points.
    public var width: Double
    public var height: Double
    /// Pixels per point.
    public var scale: Double

    public init(width: Double, height: Double, scale: Double) {
        self.width = width
        self.height = height
        self.scale = scale
    }
}

/// An installed app.
public struct SimulatorApp: Hashable, Codable, Sendable {
    /// Its bundle ID or Android package.
    public var id: String
    public var name: String?

    public init(id: String, name: String? = nil) {
        self.id = id
        self.name = name
    }
}

/// What driving a simulator read back.
public struct SimulatorDriveResult: Hashable, Codable, Sendable {
    public var screen: SimulatorScreen?
    /// The snapshot, when one was asked for or nothing came before a settle.
    public var elements: [SimulatorElement]?
    /// After a settle, what changed since the last snapshot.
    public var added: [SimulatorElement]?
    public var removed: [SimulatorElement]?
    /// Elements still on screen whose value or state changed.
    public var changed: [SimulatorElement]?
    public var unchanged: Int?
    public var image: Data?
    public var imageFormat: SimulatorImageFormat?
    public var apps: [SimulatorApp]?
    public var logs: String?
    /// Things the agent should know, such as a step that couldn't be checked.
    public var notes: [String]

    public init(screen: SimulatorScreen? = nil, elements: [SimulatorElement]? = nil, added: [SimulatorElement]? = nil,
                removed: [SimulatorElement]? = nil, changed: [SimulatorElement]? = nil, unchanged: Int? = nil,
                image: Data? = nil, imageFormat: SimulatorImageFormat? = nil, apps: [SimulatorApp]? = nil,
                logs: String? = nil, notes: [String] = []) {
        self.screen = screen
        self.elements = elements
        self.added = added
        self.removed = removed
        self.changed = changed
        self.unchanged = unchanged
        self.image = image
        self.imageFormat = imageFormat
        self.apps = apps
        self.logs = logs
        self.notes = notes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        screen = try container.decodeIfPresent(SimulatorScreen.self, forKey: .screen)
        elements = try container.decodeIfPresent([SimulatorElement].self, forKey: .elements)
        added = try container.decodeIfPresent([SimulatorElement].self, forKey: .added)
        removed = try container.decodeIfPresent([SimulatorElement].self, forKey: .removed)
        changed = try container.decodeIfPresent([SimulatorElement].self, forKey: .changed)
        unchanged = try container.decodeIfPresent(Int.self, forKey: .unchanged)
        image = try container.decodeIfPresent(Data.self, forKey: .image)
        imageFormat = try? container.decodeIfPresent(SimulatorImageFormat.self, forKey: .imageFormat)
        apps = try container.decodeIfPresent([SimulatorApp].self, forKey: .apps)
        logs = try container.decodeIfPresent(String.self, forKey: .logs)
        notes = try container.decodeIfPresent([String].self, forKey: .notes) ?? []
    }
}

extension SimulatorTarget {
    func validate() throws(ErrorCode) {
        switch self {
        case .point(let x, let y):
            if !x.isFinite || !y.isFinite || abs(x) > 100_000 || abs(y) > 100_000 { throw .badRequest }
        case .ref(let text), .label(let text), .identifier(let text):
            if text.isEmpty || text.utf8.count > 1024 || Validation.hasNul(text) { throw .badRequest }
        case .unknown: break
        }
    }
}

extension SimulatorStep {
    static func seconds(_ value: Double, max: Double = 60) throws(ErrorCode) {
        if !value.isFinite || value < 0 || value > max { throw .badRequest }
    }

    static func text(_ value: String, limit: Int = Limits.maxInput) throws(ErrorCode) {
        if value.utf8.count > limit || Validation.hasNul(value) { throw .badRequest }
    }

    func validate() throws(ErrorCode) {
        switch self {
        case .tap(let target, let count, let hold):
            try target.validate()
            if count < 1 || count > 10 { throw .badRequest }
            try Self.seconds(hold, max: 30)
        case .swipe(let from, let to, let duration):
            try from.validate()
            try to.validate()
            try Self.seconds(duration, max: 10)
        case .scroll(_, let distance, let within):
            try within?.validate()
            if !distance.isFinite || distance <= 0 || distance > 1 { throw .badRequest }
        case .type(let text), .key(let text): try Self.text(text)
        case .fill(let target, let text):
            try target.validate()
            try Self.text(text)
        case .wait(let seconds): try Self.seconds(seconds)
        case .waitFor(let target, _, let timeout):
            try target.validate()
            try Self.seconds(timeout, max: 120)
        case .launch(let app), .terminate(let app), .uninstall(let app):
            if app.isEmpty { throw .badRequest }
            try Self.text(app, limit: 1024)
        case .install(let path):
            if path.isEmpty { throw .badRequest }
            try Self.text(path, limit: 4096)
        case .openURL(let url):
            if url.isEmpty { throw .badRequest }
            try Self.text(url, limit: Limits.maxLinkURI)
        case .location(let latitude, let longitude):
            if !(-90 ... 90).contains(latitude) || !(-180 ... 180).contains(longitude) { throw .badRequest }
        case .button, .unknown: break
        }
    }
}

extension SimulatorDrive {
    /// The most steps one request runs.
    public static let maxSteps = 100

    func validate() throws(ErrorCode) {
        if steps.count > Self.maxSteps { throw .badRequest }
        for step in steps { try step.validate() }
        if let screenshot, !(1 ... 100).contains(screenshot.quality) { throw .badRequest }
        if let logs {
            if !logs.seconds.isFinite || logs.seconds <= 0 || logs.seconds > 86_400 || !(1 ... 10_000).contains(logs.lines) {
                throw .badRequest
            }
            if let app = logs.app { try SimulatorStep.text(app, limit: 1024) }
        }
    }
}
