import Foundation
import XCTest

/// Opens the links an rg search and Claude Code's trust prompt send, and the address gh prints as plain text,
/// through real touches on the demo. A file link shows its menu, a long press lifts a web link into its
/// context menu, and a tap opens it in Safari.
@MainActor final class PhoneLinkProof: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "app.thrush.proofs")
    private let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
    private static let wrappedPath = "Sources/Thrush/View/TerminalMetalView+Links.swift"
    private static let fileDestination = "file://devbox/home/robin/thrush/Sources/Thrush/View/TerminalMetalView+Links.swift"
    private static let page = "https://github.com/lostintangent/thrush/blob/main/\(wrappedPath)?plain=1#L176"

    func testDarkLinks() throws { try capture(appearance: "dark") }
    func testLightLinks() throws { try capture(appearance: "light") }

    private func capture(appearance: String) throws {
        continueAfterFailure = false
        XCUIDevice.shared.appearance = appearance == "dark" ? .dark : .light
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["--endpoint", try XCTUnwrap(ProcessInfo.processInfo.environment["THRUSH_CAPTURE_ENDPOINT"]),
                               "--scene", "links", "--hide-keyboard", "--capture-state"]
        app.launch()
        let guide = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH 'Security guide'")).firstMatch
        XCTAssertTrue(guide.waitForExistence(timeout: 15), app.debugDescription)
        let keyboard = app.keyboards.firstMatch
        XCTAssertFalse(keyboard.exists)
        Thread.sleep(forTimeInterval: 0.75)
        try screenshot("links-\(appearance)-rest")
        let start = Date.now.timeIntervalSince1970

        // The narrow grid wraps the file name, and a tap on its second row is a tap on the same link.
        let path = app.staticTexts[Self.wrappedPath]
        XCTAssertTrue(path.exists, app.debugDescription)
        let row = guide.frame.height
        XCTAssertEqual(path.frame.height, row * 2, accuracy: 1, "The file name should wrap onto a second row.")
        point(x: path.frame.minX + row * 0.75, y: path.frame.maxY - row / 2).tap()
        let copyPath = item("Copy Path")
        XCTAssertTrue(copyPath.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(item(Self.fileDestination).exists, "The menu's title should be the link's destination.")
        XCTAssertFalse(item("Open Link").exists, "Thrush never opens a file link.")
        XCTAssertFalse(keyboard.exists, "A tap on a link shouldn't raise the keyboard.")
        try screenshot("links-\(appearance)-file-menu")
        copyPath.tap()
        XCTAssertTrue(copyPath.waitForNonExistence(timeout: 5))

        // gh's address is plain text that opens the same way. A long press on its last row lifts the whole address.
        let page = app.staticTexts[Self.page]
        XCTAssertTrue(page.exists, app.debugDescription)
        XCTAssertGreaterThan(page.frame.height, row * 1.5, "The address should wrap.")
        let titled = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", Self.page))
        let shown = titled.count
        point(x: page.frame.minX + row * 0.75, y: page.frame.maxY - row / 2).press(forDuration: 0.8)
        let copyAddress = item("Copy Link")
        XCTAssertTrue(copyAddress.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(item("Open Link").exists)
        XCTAssertGreaterThan(titled.count, shown, "The menu's title should be the whole address.")
        try screenshot("links-\(appearance)-address-preview")
        copyAddress.tap()
        XCTAssertTrue(copyAddress.waitForNonExistence(timeout: 5))

        // A long press lifts the web link into the system context menu rather than selecting a word.
        point(x: guide.frame.minX + row * 2.5, y: guide.frame.midY).press(forDuration: 0.8)
        let copyLink = item("Copy Link")
        XCTAssertTrue(copyLink.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(item("Open Link").exists)
        XCTAssertTrue(item("Share…").exists)
        XCTAssertTrue(item("https://code.claude.com/docs/en/security").exists, app.debugDescription)
        XCTAssertFalse(app.staticTexts["Selected text"].exists, "A long press on a link shouldn't select a word.")
        try screenshot("links-\(appearance)-preview")
        copyLink.tap()
        XCTAssertTrue(copyLink.waitForNonExistence(timeout: 5))
        try finishClip("links-\(appearance)", since: start)

        // The link's target is its own cells, so a tap beside it on the same row raises the keyboard.
        point(x: guide.frame.minX + guide.frame.width * 0.75, y: guide.frame.midY).tap()
        XCTAssertTrue(keyboard.waitForExistence(timeout: 6), "A tap beside a link should raise the keyboard.")
        Thread.sleep(forTimeInterval: 0.75)
        try screenshot("links-\(appearance)-keyboard")

        // A tap opens a web link through SwiftUI's openURL, which the system hands to Safari.
        point(x: guide.frame.minX + row * 2.5, y: guide.frame.midY).tap()
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 20), "Safari should open the Security guide.")
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    }

    private func point(x: CGFloat, y: CGFloat) -> XCUICoordinate {
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y))
    }

    private func item(_ label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    private func screenshot(_ name: String) throws {
        save(XCUIScreen.main.screenshot().pngRepresentation, name: name, type: "public.png")
    }

    private func finishClip(_ name: String, since start: TimeInterval) throws {
        save(try JSONEncoder().encode([start, Date.now.timeIntervalSince1970]), name: name, type: "public.json")
    }

    private func save(_ data: Data, name: String, type: String) {
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: type)
        attachment.name = "thrush-proof__" + name + "__"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
