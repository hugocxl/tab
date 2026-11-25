@testable import TabSimulators
import TabProtocol
import XCTest

final class SimulatorAutomationTests: XCTestCase {
    private func element(_ role: String, _ label: String?, id: String? = nil, value: String? = nil, y: Double = 0,
                         depth: Int = 1, interactive: Bool = true) -> SimulatorElement {
        SimulatorElement(role: role, label: label, identifier: id, value: value, x: 0, y: y, width: 100, height: 40,
                         interactive: interactive, depth: depth)
    }

    func testRefsSurviveMovesAndAreNeverReused() {
        var refs = SimulatorRefs()
        let first = refs.update([element("button", "General", y: 100), element("button", "About", y: 140)]).elements
        XCTAssertEqual(first.map(\.ref), ["e1", "e2"])

        // Scrolling moves both and brings a new one: the old keep their refs.
        let (second, changes) = refs.update([element("button", "About", y: 40), element("button", "General", y: 0),
                                             element("button", "Keyboard", y: 80)])
        XCTAssertEqual(second.map(\.ref), ["e2", "e1", "e3"])
        XCTAssertEqual(changes.added.map(\.ref), ["e3"])
        XCTAssertEqual(changes.changed, [], "a move alone isn't a change")
        XCTAssertEqual(changes.unchanged, 2)
        XCTAssertEqual(refs.element("e1")?.y, 0, "a ref acts where its element is now")
        XCTAssertEqual(refs.element("@e3")?.label, "Keyboard")

        // A gone element's ref isn't given to the next new one.
        let (third, gone) = refs.update([element("button", "Keyboard", y: 80), element("button", "Fonts", y: 120)])
        XCTAssertEqual(gone.removed.map(\.ref).sorted(), ["e1", "e2"])
        XCTAssertEqual(third.map(\.ref), ["e3", "e4"])
        XCTAssertNil(refs.element("e1"), "a ref from an earlier screen doesn't resolve")
    }

    func testDuplicateLabelsKeepTheirOrderAndValueChangesShow() {
        var refs = SimulatorRefs()
        refs.update([element("button", "Delete", y: 0), element("button", "Delete", y: 50),
                     element("switch", "Wi-Fi", value: "1", y: 100)])
        let (elements, changes) = refs.update([element("button", "Delete", y: 0), element("button", "Delete", y: 50),
                                               element("switch", "Wi-Fi", value: "0", y: 100)])
        XCTAssertEqual(elements.map(\.ref), ["e1", "e2", "e3"])
        XCTAssertEqual(changes.unchanged, 2)
        XCTAssertEqual(changes.changed.map(\.ref), ["e3"])
        XCTAssertEqual(changes.changed.first?.value, "0")
    }

    func testCompactDropsUnnamedGroupsAndKeepsNesting() {
        let tree = [
            element("app", "Settings", depth: 0, interactive: false),
            element("group", nil, depth: 1, interactive: false),
            element("group", nil, depth: 2, interactive: false),
            element("button", "General", depth: 3),
            element("group", nil, id: "list", depth: 1, interactive: false),
            element("cell", "Row", depth: 2),
            SimulatorElement(role: "image", label: "zero", x: 0, y: 0, width: 0, height: 0, depth: 1),
            element("text", "Footer", depth: 1, interactive: false),
        ]
        let compact = SimulatorRefs.compact(tree)
        XCTAssertEqual(compact.map { $0.label ?? $0.identifier ?? "" }, ["Settings", "General", "list", "Row", "Footer"])
        XCTAssertEqual(compact.map(\.depth), [0, 1, 1, 2, 1])
    }

    func testFindPrefersExactInteractiveLabels() {
        let elements = [element("text", "General", interactive: false), element("button", "General settings"),
                        element("button", "general"), element("cell", "Wi-Fi", id: "wifi", value: "Home")]
        XCTAssertEqual(SimulatorRefs.find(label: "General", in: elements)?.role, "button")
        XCTAssertEqual(SimulatorRefs.find(label: "General", in: elements)?.label, "general")
        XCTAssertEqual(SimulatorRefs.find(label: "home", in: elements)?.identifier, "wifi", "values match too")
        XCTAssertEqual(SimulatorRefs.find(identifier: "wifi", in: elements)?.label, "Wi-Fi")
        XCTAssertNil(SimulatorRefs.find(label: "Bluetooth", in: elements))
    }

    func testChordsPressModifiersAroundTheKey() {
        XCTAssertEqual(SimulatorKeyboard.chord("cmd+a"), [.key(usage: 0xE3, down: true), .key(usage: 0x04, down: true),
                                                          .key(usage: 0x04, down: false), .key(usage: 0xE3, down: false)])
        XCTAssertEqual(SimulatorKeyboard.chord("Return"), [.key(usage: 0x28, down: true), .key(usage: 0x28, down: false)])
        XCTAssertEqual(SimulatorKeyboard.chord("A")?.first, .key(usage: 0xE1, down: true), "a capital holds shift")
        XCTAssertNil(SimulatorKeyboard.chord("hyper+a"))
        XCTAssertNil(SimulatorKeyboard.chord("cmd+"))
        XCTAssertTrue(SimulatorKeyboard.canType("Hello, world!"))
        XCTAssertFalse(SimulatorKeyboard.canType("héllo"))
    }

    func testUIAutomatorDumpReadsInPoints() {
        let xml = """
        UI hierchary dumped to: /dev/tty<?xml version='1.0' encoding='UTF-8' standalone='yes' ?><hierarchy rotation="0">\
        <node index="0" text="" resource-id="" class="android.widget.FrameLayout" content-desc="" checkable="false" \
        checked="false" clickable="false" enabled="true" bounds="[0,0][1080,2400]">\
        <node index="0" text="Sign in" resource-id="com.example:id/login" class="android.widget.Button" content-desc="" \
        checkable="false" checked="false" clickable="true" enabled="true" bounds="[100,200][500,326]" />\
        <node index="1" text="ada@example.com" resource-id="com.example:id/email" class="android.widget.EditText" \
        content-desc="" hint="Email" checkable="false" checked="false" clickable="true" enabled="false" bounds="[0,400][1080,526]" />\
        <node index="2" text="" resource-id="" class="android.widget.Switch" content-desc="Dark mode" checkable="true" \
        checked="true" clickable="true" enabled="true" bounds="[900,600][1050,700]" /></node></hierarchy>
        """
        let elements = AndroidUIAutomator.elements(xml, scale: 2.625)
        XCTAssertEqual(elements.map(\.role), ["group", "button", "text-field", "switch"])
        let button = elements[1]
        XCTAssertEqual(button.label, "Sign in")
        XCTAssertEqual(button.identifier, "com.example:id/login")
        XCTAssertEqual(button.x, 100 / 2.625, accuracy: 0.001)
        XCTAssertEqual(button.height, 126 / 2.625, accuracy: 0.001)
        XCTAssertEqual(button.depth, 1)
        XCTAssertEqual(elements[2].label, "Email", "a field is named by its hint, its text is its value")
        XCTAssertEqual(elements[2].value, "ada@example.com")
        XCTAssertFalse(elements[2].enabled)
        XCTAssertEqual(elements[3].value, "1")
        XCTAssertEqual(AndroidUIAutomator.elements("ERROR: could not get idle state.", scale: 1), [])
    }

    func testDensityReadsTheOverride() {
        XCTAssertEqual(AndroidUIAutomator.density("Physical density: 420\n"), 2.625)
        XCTAssertEqual(AndroidUIAutomator.density("Physical density: 420\nOverride density: 320\n"), 2)
        XCTAssertNil(AndroidUIAutomator.density("error: no devices"))
    }

    func testAppsListUserAppsFirst() throws {
        let plist = try PropertyListSerialization.data(fromPropertyList: [
            "com.apple.Preferences": ["CFBundleDisplayName": "Settings", "ApplicationType": "System"],
            "com.example.app": ["CFBundleName": "Example", "ApplicationType": "User"],
        ], format: .xml, options: 0)
        XCTAssertEqual(IOSSimulatorControl.parseApps(plist), [SimulatorApp(id: "com.example.app", name: "Example"),
                                                              SimulatorApp(id: "com.apple.Preferences", name: "Settings")])
        XCTAssertEqual(IOSSimulatorControl.lastLines("a\nb\nc\n", 2), "b\nc\n")
    }
}
