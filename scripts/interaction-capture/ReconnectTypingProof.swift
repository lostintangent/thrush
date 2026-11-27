import Foundation
import XCTest

/// Drives the visible English keyboard before, during and after a real socket interruption.
@MainActor final class ReconnectTypingProof: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "app.thrush.proofs")
    private let base = URL(string: ProcessInfo.processInfo.environment["THRUSH_CAPTURE_ENDPOINT"]!)!

    func testTypingThroughReconnect() async throws {
        continueAfterFailure = false
        let appearance = ProcessInfo.processInfo.environment["THRUSH_CAPTURE_APPEARANCE"] ?? "dark"
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["--endpoint", base.absoluteString, "--scene", "reconnect-typing",
                               "--appearance", appearance, "--keyboard", "--capture-state"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Test run passed."].waitForExistence(timeout: 30), app.debugDescription)
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 12))
        XCTAssertTrue(app.buttons["Control"].exists)
        let initial = keyboard.frame
        try await post("app-ready")
        try await waitForRecorder("recording")
        try tap("git")
        let live = app.staticTexts["~/thrush % git"]
        XCTAssertTrue(live.waitForExistence(timeout: 8), app.debugDescription)
        try await post("interrupt")
        let spinner = app.descendants(matching: .any)["terminal.cursorSpinner"]
        XCTAssertTrue(spinner.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(spinner.label, "Reconnecting")
        XCTAssertEqual(keyboard.frame, initial)
        try tap(" status")
        XCTAssertTrue(live.exists, "The old transcript must stay still while the shell is unavailable.")
        let echoed = app.staticTexts["~/thrush % git status"]
        XCTAssertFalse(echoed.exists)
        // Let the recorder sample the spinner with the completed input held at the peer gate.
        try await Task.sleep(for: .seconds(2))
        try await post("resume")
        XCTAssertTrue(echoed.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(spinner.waitForNonExistence(timeout: 5))
        XCTAssertEqual(keyboard.frame, initial)
        try await Task.sleep(for: .milliseconds(700))
        try await post("complete")
        try await waitForRecorder("observed")
    }

    private func waitForRecorder(_ field: String) async throws {
        let deadline = Date.now.addingTimeInterval(50)
        while true {
            let (data, _) = try await URLSession.shared.data(from: base.appending(path: "motion/state"))
            let state = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            if state?[field] as? Bool == true { break }
            guard Date.now < deadline else { throw NSError(domain: "Simulator recorder checkpoint timed out", code: 1) }
            try await Task.sleep(for: .milliseconds(80))
        }
    }

    private func tap(_ text: String) throws {
        for character in text {
            let label = character == " " ? "space" : String(character)
            let key = app.keyboards.keys[label]
            XCTAssertTrue(key.waitForExistence(timeout: 3), "Missing English keyboard key \(label).")
            key.tap()
        }
    }

    private func post(_ step: String) async throws {
        var request = URLRequest(url: base.appending(path: "motion/" + step))
        request.httpMethod = "POST"
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 204, String(decoding: data, as: UTF8.self))
    }
}
