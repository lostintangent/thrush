import AppKit
import XCTest

/// Opens the links an rg search and Claude Code's trust prompt send, and the address gh prints as plain text,
/// through real clicks in the packaged Mac demo. A ⌘-click opens a web link in the default browser and shows a
/// file link's menu, a plain click or a ⌘-drag away opens nothing, and a right-click adds the link's items
/// above the terminal's own.
@MainActor final class MacLinkProof: XCTestCase {
    private static let guide = "Security guide"
    private static let destination = "https://code.claude.com/docs/en/security"
    private static let file = "Sources/Thrush/View/TerminalMetalView+Links.swift"
    private static let host = "file://devbox/home/robin/thrush/"
    private static let page = "https://github.com/lostintangent/thrush/blob/main/\(file)?plain=1#L176"
    private var app: XCUIApplication!

    func testDarkLinks() throws { try capture(appearance: "dark") }
    func testLightLinks() throws { try capture(appearance: "light") }

    private func capture(appearance: String) throws {
        let env = ProcessInfo.processInfo.environment
        let opener = try XCTUnwrap(NSWorkspace.shared.urlForApplication(toOpen: URL(string: Self.destination)!))
        let browser = XCUIApplication(bundleIdentifier: try XCTUnwrap(Bundle(url: opener)?.bundleIdentifier))
        app = XCUIApplication(url: URL(fileURLWithPath: try XCTUnwrap(env["THRUSH_LINKS_APP"])))
        app.launchArguments = ["--scene", "links", "--appearance", appearance,
                               "--endpoint", try XCTUnwrap(env["THRUSH_CAPTURE_ENDPOINT"])]
        app.launch()
        defer { app.terminate() }
        let window = app.windows.firstMatch
        let guide = link(Self.guide)
        XCTAssertTrue(guide.waitForExistence(timeout: 20), app.debugDescription)
        Thread.sleep(forTimeInterval: 0.5)
        let row = guide.frame.height
        save(window.screenshot(), "rest", appearance)

        // The tooltip names where a link goes, and ⌘ engages the link under a resting pointer.
        center(of: guide).hover()
        Thread.sleep(forTimeInterval: 3)
        save(XCUIScreen.main.screenshot(), "tooltip", appearance)
        XCUIElement.perform(withKeyModifiers: .command) {
            Thread.sleep(forTimeInterval: 0.3)
            save(window.screenshot(), "command-hover", appearance)
        }

        // A ⌘-click opens a web link where the system opens it.
        XCUIElement.perform(withKeyModifiers: .command) { center(of: guide).click() }
        XCTAssertTrue(browser.wait(for: .runningForeground, timeout: 30), "A ⌘-click should open the Security guide.")
        browser.terminate()
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        // A plain click is the terminal's, and a ⌘-click dragged off the link cancels like a button.
        center(of: guide).click()
        XCTAssertFalse(browser.wait(for: .runningForeground, timeout: 2), "A plain click shouldn't open a link.")
        XCUIElement.perform(withKeyModifiers: .command) {
            center(of: guide).press(forDuration: 0.2, thenDragTo: center(of: guide).withOffset(CGVector(dx: 0, dy: row * 2)))
        }
        XCTAssertFalse(browser.wait(for: .runningForeground, timeout: 2), "A ⌘-click dragged off a link shouldn't open it.")
        XCTAssertTrue(app.state == .runningForeground)

        // A right-click puts the link's items above the terminal's own.
        NSPasteboard.general.clearContents()
        center(of: guide).rightClick()
        let copyLink = app.menuItems["Copy Link"]
        XCTAssertTrue(copyLink.waitForExistence(timeout: 5), app.debugDescription)
        let linkMenu = menu(with: "Copy Link")
        for title in ["Open Link", "Copy", "Paste", "Select All"] { XCTAssertTrue(linkMenu.menuItems[title].exists, title) }
        save(XCUIScreen.main.screenshot(), "link-menu", appearance)
        copyLink.click()
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), Self.destination)

        // Thrush never opens a file link. A ⌘-click shows its menu, titled with where it goes.
        let file = link(Self.file)
        XCTAssertTrue(file.exists, app.debugDescription)
        XCUIElement.perform(withKeyModifiers: .command) { file.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).click() }
        let copyPath = app.menuItems["Copy Path"]
        XCTAssertTrue(copyPath.waitForExistence(timeout: 5), app.debugDescription)
        let fileMenu = menu(with: "Copy Path")
        XCTAssertTrue(item(Self.host + Self.file.replacingOccurrences(of: "+", with: "%2B"), in: fileMenu).exists,
                      "The menu's title should be the link's destination.")
        XCTAssertFalse(fileMenu.menuItems["Open Link"].exists, "Thrush never opens a file link.")
        save(XCUIScreen.main.screenshot(), "file-menu", appearance)
        copyPath.click()
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "/home/robin/thrush/" + Self.file)
        XCTAssertFalse(browser.wait(for: .runningForeground, timeout: 1))

        // gh's address is plain text that opens the same way. It wraps, and its second row is the same link.
        let page = link(Self.page)
        XCTAssertTrue(page.exists, app.debugDescription)
        XCTAssertEqual(page.frame.height, row * 2, accuracy: 1, "The address should wrap onto a second row.")
        let cell = guide.frame.width / CGFloat(Self.guide.count)
        let second = window.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(dx: page.frame.minX - window.frame.minX + cell, dy: page.frame.maxY - window.frame.minY - row / 2))
        second.hover()
        XCUIElement.perform(withKeyModifiers: .command) {
            Thread.sleep(forTimeInterval: 0.3)
            save(window.screenshot(), "wrapped-command-hover", appearance)
        }
        second.rightClick()
        XCTAssertTrue(copyLink.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(menu(with: "Copy Link").menuItems["Open Link"].exists)
        save(XCUIScreen.main.screenshot(), "wrapped-menu", appearance)
        copyLink.click()
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), Self.page)
        XCUIElement.perform(withKeyModifiers: .command) { second.click() }
        XCTAssertTrue(browser.wait(for: .runningForeground, timeout: 30), "A ⌘-click should open gh's address.")
        browser.terminate()
    }

    private func link(_ text: String) -> XCUIElement {
        app.links.matching(NSPredicate(format: "label == %@", text)).firstMatch
    }

    private func center(of element: XCUIElement) -> XCUICoordinate {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    }

    /// The open menu with an item titled `title`, apart from the menu bar's.
    private func menu(with title: String) -> XCUIElement {
        app.menus.containing(NSPredicate(format: "title == %@", title)).firstMatch
    }

    private func item(_ title: String, in menu: XCUIElement) -> XCUIElement {
        menu.descendants(matching: .any).matching(NSPredicate(format: "title == %@ OR label == %@", title, title)).firstMatch
    }

    private func save(_ screenshot: XCUIScreenshot, _ name: String, _ appearance: String) {
        let attachment = XCTAttachment(data: screenshot.pngRepresentation, uniformTypeIdentifier: "public.png")
        attachment.name = "thrush-proof__links-mac-\(appearance)-\(name)__"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
