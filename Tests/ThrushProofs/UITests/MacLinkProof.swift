import AppKit
import XCTest

/// Opens the links an rg search and Claude Code's trust prompt send, and the address gh prints as plain text,
/// through real clicks in the packaged Mac proofs app. ⌘ engages the link under a resting pointer, even when output
/// brings it there. A ⌘-click opens a web link in the default browser and shows a file link's menu, a plain click
/// or a ⌘-drag away opens nothing, and a right-click adds the link's items above the terminal's own, with
/// nothing to AutoFill.
@MainActor final class MacLinkProof: XCTestCase {
    private static let guide = "Security guide"
    private static let destination = "https://code.claude.com/docs/en/security"
    private static let file = "Sources/Thrush/View/TerminalMetalView+Links.swift"
    private static let host = "file://devbox/home/robin/thrush/"
    private static let page = "https://github.com/lostintangent/thrush/blob/main/\(file)?plain=1#L176"
    private var app: XCUIApplication!
    private var endpoint = ""

    func testDarkLinks() throws { try capture(appearance: "dark") }
    func testLightLinks() throws { try capture(appearance: "light") }

    private func capture(appearance: String) throws {
        let env = ProcessInfo.processInfo.environment
        let opener = try XCTUnwrap(NSWorkspace.shared.urlForApplication(toOpen: URL(string: Self.destination)!))
        let browser = XCUIApplication(bundleIdentifier: try XCTUnwrap(Bundle(url: opener)?.bundleIdentifier))
        app = XCUIApplication(url: URL(fileURLWithPath: try XCTUnwrap(env["THRUSH_PROOFS_APP"])))
        endpoint = try XCTUnwrap(env["THRUSH_CAPTURE_ENDPOINT"])
        app.launchArguments = ["--scene", "links", "--appearance", appearance, "--endpoint", endpoint]
        app.launch()
        defer { app.terminate() }
        let window = app.windows.firstMatch
        let guide = link(Self.guide)
        XCTAssertTrue(guide.waitForExistence(timeout: 20), app.debugDescription)
        Thread.sleep(forTimeInterval: 0.5)
        let row = guide.frame.height
        let rest = window.screenshot()
        save(rest, "rest", appearance)

        // The tooltip names where a link goes. ⌘ engages the link under a resting pointer, and output that
        // takes the link away or brings it back under the pointer lets it go or engages it again.
        center(of: guide).hover()
        Thread.sleep(forTimeInterval: 3)
        save(XCUIScreen.main.screenshot(), "tooltip", appearance)
        let resting = cursor()
        XCTAssertNotEqual(resting, "pointing hand", "A link should wait for ⌘ before it engages.")
        XCUIElement.perform(withKeyModifiers: .command) {
            expectCursor("pointing hand", "⌘ should engage the link under a resting pointer.")
            let plain = pixels(of: guide, in: rest)
            let engaged = expectStill(of: guide, { $0 != plain }, "An engaged link should look engaged.")
            save(engaged, "command-hover", appearance)
            let look = pixels(of: guide, in: engaged)
            output(drawn: false)
            XCTAssertTrue(link(Self.guide).waitForNonExistence(timeout: 5), app.debugDescription)
            expectCursor(resting, "Output that takes the link away should let it go.")
            output(drawn: true)
            XCTAssertTrue(link(Self.guide).waitForExistence(timeout: 10), app.debugDescription)
            expectCursor("pointing hand", "Output that brings a link under a resting pointer should engage it.")
            save(expectStill(of: guide, { $0 == look }, "The link should look engaged again."), "command-output", appearance)
        }
        expectCursor(resting, "Letting go of ⌘ should let the link go.")

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
        XCTAssertFalse(linkMenu.menuItems["AutoFill"].exists, "A terminal has nothing to AutoFill.")
        save(XCUIScreen.main.screenshot(), "link-menu", appearance)
        copyLink.click()
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), Self.destination)

        // Away from links, a right-click shows the terminal's own items and nothing to AutoFill.
        let autoFill = app.menuItems.matching(NSPredicate(format: "title == 'AutoFill'"))
        let autoFills = autoFill.count
        center(of: guide).withOffset(CGVector(dx: 0, dy: row * 5)).rightClick()
        XCTAssertTrue(app.menuItems["Select All"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(autoFill.count, autoFills, "A terminal has nothing to AutoFill.")
        save(XCUIScreen.main.screenshot(), "menu", appearance)
        app.typeKey(.escape, modifierFlags: [])

        // Thrush never opens a file link. A ⌘-click shows its menu, titled with where it goes.
        let file = link(Self.file)
        XCTAssertTrue(file.exists, app.debugDescription)
        XCUIElement.perform(withKeyModifiers: .command) { file.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).click() }
        let copyPath = app.menuItems["Copy Path"]
        XCTAssertTrue(copyPath.waitForExistence(timeout: 5), app.debugDescription)
        let fileMenu = menu(with: "Copy Path")
        XCTAssertTrue(item(Self.host + Self.file, in: fileMenu).exists,
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
            expectCursor("pointing hand", "⌘ should engage the wrapped address from its second row.")
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

    /// Waits a moment for the system cursor to become `expected`. A still of the window doesn't show the pointer,
    /// so the cursor is how the proof sees a link engage.
    private func expectCursor(_ expected: String, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(2)
        while cursor() != expected, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        XCTAssertEqual(cursor(), expected, message, file: file, line: line)
    }

    /// The system cursor, told apart from the pointing hand by its hot spot and size.
    private func cursor() -> String {
        guard let current = NSCursor.currentSystem else { return "hidden" }
        let hand = NSCursor.pointingHand
        return hand.hotSpot == current.hotSpot && hand.image.size == current.image.size
            ? "pointing hand" : "\(current.hotSpot) \(current.image.size)"
    }

    /// Waits a moment for a still of the window in which `element` looks the way `matches` wants. The pointer
    /// changes as soon as a link engages, and the link draws its new look on the next frame.
    private func expectStill(of element: XCUIElement, _ matches: (Data) -> Bool, _ message: String,
                             file: StaticString = #filePath, line: UInt = #line) -> XCUIScreenshot {
        let deadline = Date().addingTimeInterval(3)
        var still = app.windows.firstMatch.screenshot()
        while !matches(pixels(of: element, in: still)), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
            still = app.windows.firstMatch.screenshot()
        }
        XCTAssertTrue(matches(pixels(of: element, in: still)), message, file: file, line: line)
        return still
    }

    /// The pixels of an element in a still of its window, so the proof can tell how a link looks.
    private func pixels(of element: XCUIElement, in still: XCUIScreenshot) -> Data {
        let window = app.windows.firstMatch.frame
        guard let image = still.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return Data() }
        let scale = CGFloat(image.width) / window.width
        let frame = element.frame.offsetBy(dx: -window.minX, dy: -window.minY)
        guard let crop = image.cropping(to: CGRect(x: frame.minX * scale, y: frame.minY * scale,
                                                   width: frame.width * scale, height: frame.height * scale)),
              let context = CGContext(data: nil, width: crop.width, height: crop.height, bitsPerComponent: 8,
                                      bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return Data() }
        context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        return Data(bytes: context.data!, count: crop.width * crop.height * 4)
    }

    /// Has the peer send output that clears the links scene, or lays it out again.
    private func output(drawn: Bool) {
        var request = URLRequest(url: URL(string: endpoint + "/links?draw=" + (drawn ? "1" : "0"))!)
        request.httpMethod = "POST"
        let sent = expectation(description: "The peer sends the output.")
        URLSession.shared.dataTask(with: request) { _, response, error in
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 204, String(describing: error))
            sent.fulfill()
        }.resume()
        wait(for: [sent], timeout: 10)
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
