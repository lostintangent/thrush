import Foundation
import XCTest

@MainActor final class PaneVoiceOverProof: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "app.thrush.demo")
    private let reader = XCUIDevice.shared.voiceOverService

    func testTranscriptFocusAndNoticeActions() async throws {
        continueAfterFailure = false
        let endpoint = try XCTUnwrap(URL(string: try XCTUnwrap(ProcessInfo.processInfo.environment["THRUSH_CAPTURE_ENDPOINT"])))
        func launch(_ scene: String) {
            app.launchArguments = ["--endpoint", endpoint.absoluteString, "--scene", "notice-" + scene, "--hide-keyboard"]
            app.launch()
        }
        func read(until text: String) throws -> String {
            var values = [try reader.currentSpeech().utterance]
            for _ in 0..<32 {
                if let value = values.last, value.localizedCaseInsensitiveContains(text) { return value }
                values.append(try reader.moveForward().utterance)
            }
            XCTFail("VoiceOver never reached \(text). Traversal: \(values)")
            return ""
        }
        let wasEnabled = reader.isEnabled
        defer { if !wasEnabled { try? reader.disable() } }
        launch("reconnecting")
        XCTAssertTrue(app.staticTexts["Test run passed."].waitForExistence(timeout: 30))
        if !wasEnabled { try reader.enable() }
        XCTAssertTrue(reader.isEnabled)
        let focused = try read(until: "Test run passed")
        var interrupt = URLRequest(url: endpoint.appendingPathComponent("interrupt-reconnecting"))
        interrupt.httpMethod = "POST"
        let (_, response) = try await URLSession.shared.data(for: interrupt)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 204)
        let status = app.descendants(matching: .any).matching(identifier: "terminal.status").firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(try reader.currentSpeech().utterance, focused, app.debugDescription)
        // The peer leaves the shell disconnected. Backoff may not replace the
        // transcript reader with the status or move it to the start of the grid.
        try await Task.sleep(for: .seconds(2))
        XCTAssertEqual(try reader.currentSpeech().utterance, focused)
        print("VOICEOVER retained transcript: \(focused)")
        print("VOICEOVER reconnect status: \(try read(until: "Reconnecting"))")

        for (scene, title, label) in [("displaced", "Open in another window", "Use shell in this window"),
                                     ("ended", "Ended", "New Shell")] {
            launch(scene)
            let button = app.buttons["terminal.status.action"]
            XCTAssertTrue(button.waitForExistence(timeout: 18), app.debugDescription)
            XCTAssertEqual(button.label, label)
            XCTAssertGreaterThanOrEqual(button.frame.width, 44)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44)
            let heading = try read(until: title)
            let action = try read(until: label)
            print("VOICEOVER \(scene): \(heading) / \(action)")
            if scene == "displaced" {
                let image = XCTAttachment(data: XCUIScreen.main.screenshot().pngRepresentation, uniformTypeIdentifier: "public.png")
                image.name = "thrush-accessibility-takeover"
                image.lifetime = .keepAlways
                add(image)
            }
        }
    }
}
