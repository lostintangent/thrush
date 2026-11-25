import Foundation
import XCTest

@MainActor final class PaneVoiceOverProof: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "app.thrush.demo")
    private let reader = XCUIDevice.shared.voiceOverService
    private var disableAtEnd = false

    override func setUpWithError() throws {
        continueAfterFailure = false
        disableAtEnd = !reader.isEnabled
        if disableAtEnd { try reader.enable() }
        XCTAssertTrue(reader.isEnabled)
    }

    override func tearDownWithError() throws {
        if disableAtEnd { try reader.disable() }
    }

    private func launch(_ scene: String) throws -> URL {
        let address = try XCTUnwrap(ProcessInfo.processInfo.environment["THRUSH_CAPTURE_ENDPOINT"])
        let endpoint = try XCTUnwrap(URL(string: address))
        app.launchArguments = ["--endpoint", address, "--scene", "notice-" + scene, "--hide-keyboard"]
        app.launch()
        return endpoint
    }

    /// Explore the actual onscreen element before asking for its speech. A freshly
    /// enabled VoiceOver service can have no focus or utterance until a first gesture.
    private func read(_ element: XCUIElement, expecting text: String) throws -> String {
        XCTAssertTrue(element.waitForExistence(timeout: 20), app.debugDescription)
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        var utterances = [String]()
        let movements: [() throws -> XCUIVoiceOverService.Output] = [
            { try self.reader.currentSpeech() }, { try self.reader.moveForward() },
            { try self.reader.moveBackward() }, { try self.reader.moveIn() }
        ]
        for move in movements {
            do {
                let value = try move().utterance
                print("VOICEOVER explored: \(value)")
                utterances.append(value)
                if value.localizedCaseInsensitiveContains(text) { return value }
            } catch let error as XCUIVoiceOverService.Error where error.code == .noSpeech {
                print("VOICEOVER awaiting a first utterance for \(text): \(error.localizedDescription)")
            }
        }
        XCTFail("VoiceOver did not speak \(text) after touch exploration and navigation. Heard: \(utterances)")
        return ""
    }

    func testTranscriptKeepsVoiceOverFocusThroughReconnect() async throws {
        let endpoint = try launch("reconnecting")
        let focused = try read(app.staticTexts["Test run passed."], expecting: "Test run passed")
        var interrupt = URLRequest(url: endpoint.appendingPathComponent("interrupt-reconnecting"))
        interrupt.httpMethod = "POST"
        let (_, response) = try await URLSession.shared.data(for: interrupt)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 204)
        let status = app.descendants(matching: .any).matching(identifier: "terminal.status").firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(try reader.currentSpeech().utterance, focused, app.debugDescription)
        try await Task.sleep(for: .seconds(2))
        XCTAssertEqual(try reader.currentSpeech().utterance, focused)
        print("VOICEOVER retained transcript: \(focused)")
        print("VOICEOVER reconnect status: \(try read(status, expecting: "Reconnecting"))")
    }

    func testTakeoverAndExitButtonSpeech() throws {
        for (scene, title, label) in [("displaced", "Open in another window", "Use shell in this window"),
                                     ("ended", "Ended", "New Shell")] {
            _ = try launch(scene)
            let button = app.buttons["terminal.status.action"]
            XCTAssertTrue(button.waitForExistence(timeout: 18), app.debugDescription)
            XCTAssertEqual(button.label, label)
            XCTAssertGreaterThanOrEqual(button.frame.width, 44)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44)
            if scene == "displaced" {
                let image = XCTAttachment(data: XCUIScreen.main.screenshot().pngRepresentation, uniformTypeIdentifier: "public.png")
                image.name = "thrush-accessibility-takeover"
                image.lifetime = .keepAlways
                add(image)
            }
            let status = app.descendants(matching: .any).matching(identifier: "terminal.status").firstMatch
            let heading = try read(status, expecting: title)
            let next = try reader.moveForward().utterance
            XCTAssertTrue(next.localizedCaseInsensitiveContains(label), "Speech after \(heading): \(next)")
            print("VOICEOVER \(scene): \(heading) / \(next)")
        }
    }
}
