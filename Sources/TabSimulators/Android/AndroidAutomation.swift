import Foundation
import TabProtocol

extension AndroidSession: SimulatorAutomation {
    public var surfaceIsUpright: Bool { true }

    /// Android's points are density-independent pixels: 160 per inch.
    public func pointScale() async throws -> Double {
        if let density { return density }
        let output = try await AndroidEmulators.adb(try running(), ["shell", "wm", "density"])
        let scale = AndroidUIAutomator.density(output) ?? 1
        density = scale
        return scale
    }

    public func elements() async throws -> [SimulatorElement] {
        let emulator = try running()
        let scale = try await pointScale()
        let xml = try await AndroidEmulators.adb(emulator, ["exec-out", "uiautomator", "dump", "--compressed", "/dev/tty"])
        return AndroidUIAutomator.elements(xml, scale: scale)
    }

    public func launch(_ app: String) async throws {
        _ = try await AndroidEmulators.adb(try running(), ["shell", "monkey", "-p", AndroidEmulators.shellQuoted(app),
                                                           "-c", "android.intent.category.LAUNCHER", "1"])
    }

    public func terminate(_ app: String) async throws {
        _ = try await AndroidEmulators.adb(try running(), ["shell", "am", "force-stop", AndroidEmulators.shellQuoted(app)])
    }

    public func install(_ path: String) async throws {
        _ = try await AndroidEmulators.adb(try running(), ["install", "-r", (path as NSString).expandingTildeInPath])
    }

    public func uninstall(_ app: String) async throws {
        _ = try await AndroidEmulators.adb(try running(), ["uninstall", app])
    }

    public func apps() async throws -> [SimulatorApp] {
        let output = try await AndroidEmulators.adb(try running(), ["shell", "pm", "list", "packages", "-3"])
        return output.split(whereSeparator: \.isNewline).compactMap { line in
            guard line.hasPrefix("package:") else { return nil }
            return SimulatorApp(id: String(line.dropFirst("package:".count)).trimmingCharacters(in: .whitespaces))
        }.sorted { $0.id < $1.id }
    }

    public func logs(_ options: SimulatorLogOptions) async throws -> String {
        let emulator = try running()
        var arguments = ["logcat", "-d", "-v", "time", "-T", AndroidUIAutomator.logcatSince(seconds: options.seconds)]
        if let app = options.app {
            let pid = try await AndroidEmulators.adb(emulator, ["shell", "pidof", AndroidEmulators.shellQuoted(app)])
                .trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").first
            guard let pid else { return "" }
            arguments += ["--pid", String(pid)]
        }
        let output = try await AndroidEmulators.adb(emulator, arguments)
        return IOSSimulatorControl.lastLines(output, options.lines)
    }

    public func setLocation(latitude: Double, longitude: Double) async throws {
        // The console takes longitude first.
        _ = try await AndroidEmulators.adb(try running(), ["emu", "geo", "fix", "\(longitude)", "\(latitude)"])
    }

    public func setPasteboard(_ text: String) async throws {
        throw AndroidError.failed("Android emulators type only what a US keyboard can")
    }
}

/// Reads `uiautomator dump` output.
enum AndroidUIAutomator {
    /// Pixels per density-independent pixel from `wm density` output, which
    /// names the override when one is set.
    static func density(_ output: String) -> Double? {
        let values = output.split(whereSeparator: \.isNewline).compactMap { line -> Double? in
            guard let colon = line.lastIndex(of: ":") else { return nil }
            return Double(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }
        guard let dpi = values.last, dpi > 0 else { return nil }
        return dpi / 160
    }

    /// `logcat -T` takes a time; `MM-dd HH:mm:ss.000` of `seconds` ago here.
    static func logcatSince(seconds: Double, now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM-dd HH:mm:ss.000"
        return formatter.string(from: now.addingTimeInterval(-seconds))
    }

    /// The hierarchy's nodes as elements in points, depth first.
    static func elements(_ xml: String, scale: Double) -> [SimulatorElement] {
        guard let start = xml.range(of: "<?xml") ?? xml.range(of: "<hierarchy"),
              let end = xml.range(of: "</hierarchy>", options: .backwards) else { return [] }
        let document = Data(xml[start.lowerBound ..< end.upperBound].utf8)
        let reader = Reader(scale: scale > 0 ? scale : 1)
        let parser = XMLParser(data: document)
        parser.delegate = reader
        parser.parse()
        return reader.elements
    }

    private final class Reader: NSObject, XMLParserDelegate {
        let scale: Double
        var elements: [SimulatorElement] = []
        private var depth = -1

        init(scale: Double) {
            self.scale = scale
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            guard name == "node" else { return }
            depth += 1
            guard let bounds = AndroidUIAutomator.bounds(attributes["bounds"] ?? "") else { return }
            let className = attributes["class"] ?? ""
            let clickable = attributes["clickable"] == "true" || attributes["long-clickable"] == "true"
            let checkable = attributes["checkable"] == "true"
            let editable = className.hasSuffix("EditText")
            let role = AndroidUIAutomator.role(className, clickable: clickable, checkable: checkable)
            let text = attributes["text"].flatMap { $0.isEmpty ? nil : $0 }
            let description = attributes["content-desc"].flatMap { $0.isEmpty ? nil : $0 }
            var value: String?
            if checkable { value = attributes["checked"] == "true" ? "1" : "0" }
            if editable { value = text }
            let resource = attributes["resource-id"].flatMap { $0.isEmpty ? nil : $0 }
            elements.append(SimulatorElement(
                role: role, label: editable ? (description ?? attributes["hint"]) : (text ?? description),
                identifier: resource, value: value,
                x: bounds.minX / scale, y: bounds.minY / scale, width: bounds.width / scale, height: bounds.height / scale,
                enabled: attributes["enabled"] != "false",
                interactive: clickable || checkable || editable,
                depth: max(depth, 0)
            ))
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "node" { depth -= 1 }
        }
    }

    /// `[x1,y1][x2,y2]` in pixels.
    static func bounds(_ text: String) -> CGRect? {
        let numbers = text.split(whereSeparator: { "[],".contains($0) }).compactMap { Double($0) }
        guard numbers.count == 4, numbers[2] >= numbers[0], numbers[3] >= numbers[1] else { return nil }
        return CGRect(x: numbers[0], y: numbers[1], width: numbers[2] - numbers[0], height: numbers[3] - numbers[1])
    }

    static func role(_ className: String, clickable: Bool, checkable: Bool) -> String {
        let name = className.split(separator: ".").last.map(String.init) ?? className
        switch name {
        case "Button", "ImageButton", "FloatingActionButton", "MaterialButton": return "button"
        case "EditText", "AutoCompleteTextView", "TextInputEditText": return "text-field"
        case "TextView": return clickable ? "button" : "text"
        case "ImageView": return clickable ? "button" : "image"
        case "CheckBox": return "checkbox"
        case "Switch", "SwitchCompat", "SwitchMaterial", "ToggleButton": return "switch"
        case "RadioButton": return "radio"
        case "SeekBar": return "slider"
        case "Spinner": return "pop-up-button"
        case "ProgressBar": return "progress"
        case "RecyclerView", "ListView", "ScrollView", "HorizontalScrollView", "NestedScrollView": return "list"
        case "WebView": return "web-view"
        case "TabWidget", "TabLayout": return "tab-bar"
        default:
            if checkable { return "switch" }
            return clickable ? "button" : "group"
        }
    }
}
