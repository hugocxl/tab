import AppKit
import Foundation
import ObjectiveC
import TabCore
import TabProtocol

/// Reads a simulator's accessibility tree through macOS's private
/// AccessibilityPlatformTranslation framework, which turns the simulator's
/// iOS accessibility into Mac accessibility elements, the way Xcode's
/// Accessibility Inspector does. Each attribute read is one request to the
/// simulator, answered over CoreSimulator; reads wait for those answers, so
/// they run on `queue`, never the main one.
final class IOSSimulatorAccessibility: NSObject, @unchecked Sendable {
    static let shared = IOSSimulatorAccessibility()

    /// Serializes reads: the translator is one shared object.
    let queue = DispatchQueue(label: "com.hugocorta.tab.simulator.accessibility", qos: .userInitiated)
    /// Where the simulator's answers arrive while `queue` waits for them.
    private let answers = DispatchQueue(label: "com.hugocorta.tab.simulator.accessibility.answers", qos: .userInitiated,
                                        attributes: .concurrent)
    private var translator: NSObject?
    /// The simulator each translation token reads. On `queue`, and read by
    /// the translator's callbacks while `queue` waits.
    private let lock = NSLock()
    private var simulators: [String: AnyObject] = [:]
    private var tokens: [String: String] = [:]

    /// One element as read, before refs are given.
    struct Node {
        var role: String
        var label: String?
        var identifier: String?
        var value: String?
        var frame: CGRect
        var enabled: Bool
        var depth: Int
    }

    /// The front app's elements on `simulator`, depth first, in points.
    /// Tries a few times: the first read after a boot or an app launch can
    /// find no app while the simulator turns its accessibility on.
    func read(_ simulator: AnyObject, udid: String, maxNodes: Int = 1500) throws -> [Node] {
        dispatchPrecondition(condition: .onQueue(queue))
        // After the app changes screens, a translator that read it before
        // answers with an empty, zero-sized app for seconds, while a new one
        // reads the new screen at once. So an empty answer replaces the
        // translator; a new one can still find none while the simulator
        // turns its accessibility on after a boot.
        var nodes: [Node] = []
        let deadline = Date().addingTimeInterval(10)
        for attempt in 0 ..< 6 where Date() < deadline {
            if attempt > 1 { Thread.sleep(forTimeInterval: 0.15 * Double(attempt - 1)) }
            let translator = try loadTranslator(fresh: attempt > 0)
            let token = token(for: simulator, udid: udid)
            guard let root = frontmostApplication(translator, token: token) else { continue }
            nodes = []
            walk(root, token: token, depth: 0, into: &nodes, limit: maxNodes, deadline: deadline)
            // An app still launching reads as one without elements.
            if let app = nodes.first, app.frame.width > 0, app.frame.height > 0, nodes.count > 1 { return nodes }
        }
        guard !nodes.isEmpty else {
            throw IOSSimulatorError.unavailable("The simulator's accessibility didn't answer; try again once its screen has loaded")
        }
        return nodes
    }

    private func walk(_ object: NSObject, token: NSString, depth: Int, into nodes: inout [Node], limit: Int, deadline: Date) {
        guard nodes.count < limit, depth < 64, Date() < deadline else { return }
        (object.value(forKey: "translation") as? NSObject)?.setValue(token, forKey: "bridgeDelegateToken")
        guard let element = object as? NSAccessibilityElement else { return }
        nodes.append(Node(
            role: element.accessibilityRole()?.rawValue ?? "",
            label: Self.text(element.accessibilityLabel()),
            identifier: Self.text(element.accessibilityIdentifier()),
            value: Self.text(element.accessibilityValue().map { "\($0)" }),
            frame: element.accessibilityFrame(),
            enabled: element.isAccessibilityEnabled(),
            depth: depth
        ))
        for child in element.accessibilityChildren() ?? [] {
            guard let child = child as? NSObject else { continue }
            walk(child, token: token, depth: depth + 1, into: &nodes, limit: limit, deadline: deadline)
        }
    }

    private static func text(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: Translator

    /// The translator that finds the front app: the shared one, or with
    /// `fresh` a new one. Elements read their attributes through the shared
    /// one whichever found them, so it is always set up first.
    private func loadTranslator(fresh: Bool = false) throws -> NSObject {
        if let translator, !fresh { return translator }
        let path = "/System/Library/PrivateFrameworks/AccessibilityPlatformTranslation.framework/AccessibilityPlatformTranslation"
        guard dlopen(path, RTLD_NOW) != nil, let base = NSClassFromString("AXPTranslator") as? NSObject.Type,
              let shared = (base as AnyObject).perform(NSSelectorFromString("sharedInstance"))?.takeUnretainedValue() as? NSObject
        else {
            throw IOSSimulatorError.unavailable("macOS can't read simulator accessibility")
        }
        configure(shared)
        var chosen = shared
        if fresh, let type = (NSClassFromString("AXPTranslator_iOS") ?? base) as? NSObject.Type {
            chosen = type.init()
            configure(chosen)
        }
        translator = chosen
        return chosen
    }

    private func configure(_ translator: NSObject) {
        translator.setValue(self, forKey: "bridgeTokenDelegate")
        translator.setValue(true, forKey: "supportsDelegateTokens")
        translator.setValue(true, forKey: "accessibilityEnabled")
    }

    /// The token that names `simulator` to the translator.
    private func token(for simulator: AnyObject, udid: String) -> NSString {
        lock.withLock {
            let token = tokens[udid] ?? UUID().uuidString
            tokens[udid] = token
            simulators[token] = simulator
            return token as NSString
        }
    }

    private func frontmostApplication(_ translator: NSObject, token: NSString) -> NSObject? {
        let selector = NSSelectorFromString("frontmostApplicationWithDisplayId:bridgeDelegateToken:")
        guard translator.responds(to: selector), let method = class_getMethodImplementation(type(of: translator), selector) else {
            return nil
        }
        typealias Function = @convention(c) (AnyObject, Selector, UInt32, NSString) -> AnyObject?
        guard let translation = unsafeBitCast(method, to: Function.self)(translator, selector, 0, token) as? NSObject else {
            return nil
        }
        translation.setValue(token, forKey: "bridgeDelegateToken")
        let platform = NSSelectorFromString("macPlatformElementFromTranslation:")
        guard translator.responds(to: platform) else { return nil }
        return translator.perform(platform, with: translation)?.takeUnretainedValue() as? NSObject
    }

    // MARK: Translator delegate

    /// The translator asks for a function that sends one request to the
    /// simulator a token names and waits for its answer.
    @objc(accessibilityTranslationDelegateBridgeCallbackWithToken:)
    func bridgeCallback(token: NSString) -> Any {
        let simulator = lock.withLock { simulators[token as String] }
        let answers = answers
        let callback: @convention(block) (AnyObject?) -> AnyObject? = { request in
            guard let simulator, let request else { return nil }
            let selector = NSSelectorFromString("sendAccessibilityRequestAsync:completionQueue:completionHandler:")
            guard simulator.responds(to: selector), let method = class_getMethodImplementation(type(of: simulator), selector) else {
                return nil
            }
            typealias Function = @convention(c) (AnyObject, Selector, AnyObject, DispatchQueue,
                                                 @escaping @convention(block) (AnyObject?) -> Void) -> Void
            let answered = DispatchSemaphore(value: 0)
            let box = AnswerBox()
            unsafeBitCast(method, to: Function.self)(simulator, selector, request, answers) { response in
                box.response = response
                answered.signal()
            }
            guard answered.wait(timeout: .now() + 2) == .success else { return nil }
            return box.response
        }
        return callback as AnyObject
    }

    @objc(accessibilityTranslationConvertPlatformFrameToSystem:withToken:)
    func convertFrame(_ frame: CGRect, token: NSString) -> CGRect { frame }

    @objc(accessibilityTranslationRootParentWithToken:)
    func rootParent(token: NSString) -> AnyObject? { nil }

    private final class AnswerBox: @unchecked Sendable {
        var response: AnyObject?
    }
}

extension IOSSimulatorAccessibility.Node {
    /// Mac accessibility roles as the short names agents read.
    static let roles: [String: String] = [
        "AXApplication": "app", "AXButton": "button", "AXStaticText": "text", "AXTextField": "text-field",
        "AXSecureTextField": "secure-text-field", "AXTextArea": "text-view", "AXSearchField": "search-field",
        "AXImage": "image", "AXHeading": "heading", "AXLink": "link", "AXCheckBox": "switch", "AXSwitch": "switch",
        "AXToggle": "switch", "AXSlider": "slider", "AXIncrementor": "stepper", "AXPopUpButton": "pop-up-button",
        "AXMenuButton": "menu-button", "AXMenuItem": "menu-item", "AXRadioButton": "tab", "AXTabGroup": "tab-bar",
        "AXCell": "cell", "AXRow": "cell", "AXTable": "list", "AXOutline": "list", "AXList": "list",
        "AXCollection": "collection", "AXScrollArea": "scroll-view", "AXGroup": "group", "AXToolbar": "toolbar",
        "AXProgressIndicator": "progress", "AXBusyIndicator": "activity", "AXComboBox": "combo-box",
        "AXSegmentedControl": "segmented-control", "AXDisclosureTriangle": "disclosure", "AXWebArea": "web-view",
        "AXKeyboardKey": "key", "AXDateTimeArea": "date-picker", "AXPicker": "picker", "AXGenericElement": "element",
    ]

    static let interactiveRoles: Set<String> = [
        "button", "text-field", "secure-text-field", "text-view", "search-field", "link", "switch", "slider",
        "stepper", "pop-up-button", "menu-button", "menu-item", "tab", "cell", "combo-box", "segmented-control",
        "disclosure", "key", "date-picker", "picker",
    ]

    var element: SimulatorElement {
        let short = Self.roles[role] ?? (role.hasPrefix("AX") ? String(role.dropFirst(2)).lowercased() : role.lowercased())
        return SimulatorElement(role: short.isEmpty ? "element" : short, label: label, identifier: identifier,
                                value: value, x: frame.origin.x, y: frame.origin.y, width: frame.width,
                                height: frame.height, enabled: enabled,
                                interactive: Self.interactiveRoles.contains(short), depth: depth)
    }
}
