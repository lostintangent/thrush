import Foundation
import XCTest

/// Types through the native keyboard into oshen, which echoes input only after the terminal reports focus.
@MainActor final class FocusEchoProof: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "app.thrush.demo")
    private var interval: [Double] = []

    func testShellEchoesNativeTyping() async throws {
        continueAfterFailure = false
        #if os(iOS)
        let endpoint = try XCTUnwrap(ProcessInfo.processInfo.environment["THRUSH_CAPTURE_ENDPOINT"])
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["--endpoint", endpoint, "--scene", "shell", "--appearance", "dark", "--keyboard", "--capture-state"]
        app.launch()
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 20), app.debugDescription)
        #else
        // The recorder launched the app and found its window. Activation makes it key.
        app.activate()
        #endif
        XCTAssertTrue(row(endingWith: "~ #").waitForExistence(timeout: 30), app.debugDescription)
        try await Task.sleep(for: .milliseconds(800))
        interval.append(Date.now.timeIntervalSince1970)
        still("prompt")

        type("echo hi")
        XCTAssertTrue(row(endingWith: "~ # echo hi").waitForExistence(timeout: 10), app.debugDescription)
        try await Task.sleep(for: .milliseconds(700))
        still("typed")

        pressReturn()
        XCTAssertTrue(row(equalTo: "hi").waitForExistence(timeout: 10), app.debugDescription)
        try await Task.sleep(for: .milliseconds(900))
        still("ran")
        interval.append(Date.now.timeIntervalSince1970)
        let times = XCTAttachment(data: try JSONEncoder().encode(interval), uniformTypeIdentifier: "public.json")
        times.name = "thrush-proof__focus-echo-interval__"
        times.lifetime = .keepAlways
        add(times)
    }

    private func type(_ text: String) {
        #if os(iOS)
        for character in text {
            let label = character == " " ? "space" : String(character)
            let key = app.keyboards.keys[label]
            XCTAssertTrue(key.waitForExistence(timeout: 3), "Missing English keyboard key \(label).")
            key.tap()
        }
        #else
        app.typeText(text)
        #endif
    }

    private func pressReturn() {
        #if os(iOS)
        let named = NSPredicate(format: "label ==[c] 'return' OR identifier ==[c] 'return'")
        let key = app.keyboards.descendants(matching: .any).matching(named).firstMatch
        XCTAssertTrue(key.waitForExistence(timeout: 3), app.keyboards.firstMatch.debugDescription)
        key.tap()
        #else
        app.typeKey(.return, modifierFlags: [])
        #endif
    }

    private func row(endingWith suffix: String) -> XCUIElement {
        row(matching: ".*" + NSRegularExpression.escapedPattern(for: suffix))
    }

    private func row(equalTo text: String) -> XCUIElement {
        row(matching: NSRegularExpression.escapedPattern(for: text))
    }

    /// Each terminal row is a static text on iPhone. The Mac transcript is one text view.
    /// Either may keep the spaces a program left after its text.
    private func row(matching pattern: String) -> XCUIElement {
        #if os(iOS)
        app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", pattern + "[ ]*")).firstMatch
        #else
        app.textViews.matching(NSPredicate(format: "value MATCHES %@", "(?s)(.*\\n)?" + pattern + "[ ]*(\\n.*)?")).firstMatch
        #endif
    }

    private func still(_ name: String) {
        #if os(iOS)
        let image = XCUIScreen.main.screenshot()
        #else
        let image = app.windows.firstMatch.screenshot()
        #endif
        let attachment = XCTAttachment(screenshot: image)
        attachment.name = "thrush-proof__focus-echo-\(name)__"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
