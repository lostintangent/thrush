import Foundation
import XCTest

/// Opens the links an rg search and Claude Code's trust prompt send, and the address gh prints as plain text,
/// through real touches on the proofs app. A file link shows its menu clear of its rows, a long press lifts a web
/// link into its context menu, and a tap opens it in Safari.
@MainActor final class PhoneLinkProof: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "app.thrush.proofs")
    private let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
    private var endpoint = ""
    private static let wrappedPath = "Sources/Thrush/View/TerminalMetalView+Links.swift"
    private static let fileDestination = "file://devbox/home/robin/thrush/Sources/Thrush/View/TerminalMetalView+Links.swift"
    private static let page = "https://github.com/lostintangent/thrush/blob/main/\(wrappedPath)?plain=1#L176"

    func testDarkLinks() throws { try capture(appearance: "dark") }
    func testLightLinks() throws { try capture(appearance: "light") }

    private func capture(appearance: String) throws {
        continueAfterFailure = false
        XCUIDevice.shared.appearance = appearance == "dark" ? .dark : .light
        XCUIDevice.shared.orientation = .portrait
        endpoint = try XCTUnwrap(ProcessInfo.processInfo.environment["THRUSH_CAPTURE_ENDPOINT"])
        app.launchArguments = ["--endpoint", endpoint, "--scene", "links", "--hide-keyboard", "--capture-state"]
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
        try openFileMenu(path, row: row, still: "links-\(appearance)-file-menu")

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

        // On the bottom rows, the file link's menu opens upward. Claude exits and the search runs again.
        output(draw: 2)
        let paths = app.staticTexts.matching(NSPredicate(format: "label == %@", Self.wrappedPath))
        XCTAssertTrue(paths.element(boundBy: 1).waitForExistence(timeout: 5), app.debugDescription)
        let lower = try XCTUnwrap(paths.allElementsBoundByIndex.max { $0.frame.minY < $1.frame.minY })
        XCTAssertGreaterThan(lower.frame.minY, app.frame.midY, "The search should run again on the bottom rows.")
        try openFileMenu(lower, row: row, still: "links-\(appearance)-file-menu-bottom")
        output(draw: 1)
        XCTAssertTrue(paths.element(boundBy: 1).waitForNonExistence(timeout: 5), "The scene should be laid out again as it began.")

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

    /// A tap on the wrapped file name's second row shows its menu, titled with its destination and clear of
    /// both of its rows. The link stays pressed while its menu is up and lets go as the menu closes.
    private func openFileMenu(_ path: XCUIElement, row: CGFloat, still: String) throws {
        let link = path.frame
        XCTAssertEqual(link.height, row * 2, accuracy: 1, "The file name should wrap onto a second row.")
        let firstRow = CGRect(x: link.minX, y: link.minY, width: link.width, height: row)
        let canvas = ground(of: firstRow, in: XCUIScreen.main.screenshot())
        point(x: link.minX + row * 0.75, y: link.maxY - row / 2).tap()
        let copyPath = item("Copy Path")
        XCTAssertTrue(copyPath.waitForExistence(timeout: 5), app.debugDescription)
        let title = item(Self.fileDestination)
        XCTAssertTrue(title.exists, "The menu's title should be the link's destination.")
        XCTAssertFalse(item("Open Link").exists, "Thrush never opens a file link.")
        XCTAssertFalse(app.keyboards.firstMatch.exists, "A tap on a link shouldn't raise the keyboard.")
        // The menu's frame settles once it has grown into place.
        Thread.sleep(forTimeInterval: 0.5)
        let menu = title.frame.union(copyPath.frame)
        XCTAssertFalse(menu.intersects(link), "The menu at \(menu) should leave the link's rows at \(link) in view.")
        let shown = XCUIScreen.main.screenshot()
        save(shown.pngRepresentation, name: still, type: "public.png")
        // The press tints the canvas under the link a sixth of the way to the text. The menu's shadow is fainter.
        let pressed = ground(of: firstRow, in: shown)
        XCTAssertGreaterThan(zip(pressed, canvas).map { abs($0 - $1) }.max() ?? 0, 12,
                             "The link should stay pressed under its menu, not \(pressed) on \(canvas).")
        copyPath.tap()
        XCTAssertTrue(copyPath.waitForNonExistence(timeout: 5))
        let deadline = Date.now.addingTimeInterval(3)
        var released = ground(of: firstRow, in: XCUIScreen.main.screenshot())
        while released != canvas, Date.now < deadline {
            Thread.sleep(forTimeInterval: 0.05)
            released = ground(of: firstRow, in: XCUIScreen.main.screenshot())
        }
        XCTAssertEqual(released, canvas, "The link should let go as its menu closes.")
    }

    /// The commonest color in a rect of a still, which under a row of text is the canvas between its glyphs.
    private func ground(of rect: CGRect, in still: XCUIScreenshot) -> [Int] {
        guard let image = still.image.cgImage else { return [] }
        let scale = CGFloat(image.width) / app.frame.width
        let pixels = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
        guard let crop = image.cropping(to: pixels.insetBy(dx: 1, dy: 1).integral),
              let context = CGContext(data: nil, width: crop.width, height: crop.height, bitsPerComponent: 8,
                                      bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let data = context.data else { return [] }
        context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        let bytes = UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: crop.width * crop.height * 4)
        var counts: [[Int]: Int] = [:]
        for pixel in stride(from: 0, to: bytes.count, by: 4) {
            counts[[Int(bytes[pixel]), Int(bytes[pixel + 1]), Int(bytes[pixel + 2])], default: 0] += 1
        }
        return counts.max { $0.value < $1.value }?.key ?? []
    }

    /// Has the peer lay the links scene out again, with the search run a second time when `draw` is 2.
    private func output(draw: Int) {
        var request = URLRequest(url: URL(string: endpoint + "/links?draw=\(draw)")!)
        request.httpMethod = "POST"
        let sent = expectation(description: "The peer sends the output.")
        URLSession.shared.dataTask(with: request) { _, response, error in
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 204, String(describing: error))
            sent.fulfill()
        }.resume()
        wait(for: [sent], timeout: 10)
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
