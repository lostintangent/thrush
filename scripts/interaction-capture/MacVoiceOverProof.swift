import AppKit
import XCTest

@MainActor final class MacVoiceOverProof: XCTestCase {
    private let voice = XCUIDevice.shared.voiceOverService
    private var restoreOff = false

    override func setUpWithError() throws {
        continueAfterFailure = false
        restoreOff = !voice.isEnabled
    }

    override func tearDownWithError() throws {
        if restoreOff, voice.isEnabled { try voice.disable() }
    }

    func testSystemTextEdit() async throws {
        let title = "VoiceOver reference " + UUID().uuidString
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(title + ".txt")
        try "Orchard\nJuniper\nCedar".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let application = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        _ = try await NSWorkspace.shared.open([url], withApplicationAt: application, configuration: .init())
        let app = XCUIApplication(url: application)
        app.activate()
        defer {
            let reference = app.windows.matching(NSPredicate(format: "title BEGINSWITH %@", title)).firstMatch
            if reference.exists { reference.buttons[XCUIIdentifierCloseWindow].click() }
        }
        try await readLine("Juniper", in: app)
    }

    func testTerminalTranscriptRow() async throws {
        let env = ProcessInfo.processInfo.environment
        let app = XCUIApplication(url: URL(fileURLWithPath: try XCTUnwrap(env["THRUSH_VOICEOVER_APP"])))
        app.launchArguments = ["--scene", "shell", "--endpoint", try XCTUnwrap(env["THRUSH_CAPTURE_ENDPOINT"])]
        app.launch()
        defer { app.terminate() }
        try await readLine("Build complete.", in: app)
    }

    private func readLine(_ wanted: String, in app: XCUIApplication) async throws {
        let area = app.textViews.matching(NSPredicate(format: "value CONTAINS %@", wanted)).firstMatch
        XCTAssertTrue(area.waitForExistence(timeout: 20), app.debugDescription)
        let start = try XCTUnwrap(area.value as? String)
        let row = try XCTUnwrap(start.components(separatedBy: "\n").firstIndex(of: wanted))
        XCTAssertGreaterThan(row, 0)
        if restoreOff { try voice.enable() }
        for _ in 0..<20 where !NSWorkspace.shared.isVoiceOverEnabled {
            try await Task.sleep(for: .milliseconds(250))
        }
        XCTAssertTrue(voice.isEnabled)
        XCTAssertTrue(NSWorkspace.shared.isVoiceOverEnabled)
        app.activate()
        area.click()

        // Interact with the text area, go to its beginning, then ask VoiceOver to read each line.
        let vo: XCUIElement.KeyModifierFlags = [.control, .option]
        app.typeKey(.downArrow, modifierFlags: [.control, .option, .shift])
        app.typeKey(.home, modifierFlags: vo)
        for step in 0...(row + 1) {
            if step > 0 { app.typeKey(.downArrow, modifierFlags: vo) }
            try await Task.sleep(for: .milliseconds(400))
            do {
                let utterance = try voice.currentSpeech().utterance
                print("VoiceOver step \(step): \(utterance.debugDescription)")
                if utterance.trimmingCharacters(in: .newlines) == wanted {
                    XCTAssertEqual(area.value as? String, start)
                    return
                }
            } catch {
                print("VoiceOver step \(step): \(error as NSError)")
            }
        }
        XCTFail("VoiceOver did not speak the interior line ‘\(wanted)’ in the unchanged text.")
    }
}
