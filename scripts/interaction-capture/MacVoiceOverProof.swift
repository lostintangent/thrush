import AppKit
import XCTest

@MainActor final class MacVoiceOverProof: XCTestCase {
    private let voice = XCUIDevice.shared.voiceOverService
    private let vo: XCUIElement.KeyModifierFlags = [.control, .option]
    private var restoreOff = false

    override func setUpWithError() throws {
        continueAfterFailure = false
        restoreOff = !voice.isEnabled
    }

    override func tearDownWithError() throws {
        if restoreOff, voice.isEnabled { try voice.disable() }
    }

    func testTerminalTranscriptRow() async throws {
        let wanted = "Build complete."
        let env = ProcessInfo.processInfo.environment
        let app = XCUIApplication(url: URL(fileURLWithPath: try XCTUnwrap(env["THRUSH_VOICEOVER_APP"])))
        app.launchArguments = ["--scene", "shell", "--endpoint", try XCTUnwrap(env["THRUSH_CAPTURE_ENDPOINT"])]
        app.launch()
        defer { app.terminate() }

        let area = app.textViews.matching(NSPredicate(format: "value CONTAINS %@", wanted)).firstMatch
        XCTAssertTrue(area.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertEqual(area.label, "Terminal")
        let start = try XCTUnwrap(area.value as? String)
        let lines = start.components(separatedBy: "\n")
        let row = try XCTUnwrap(lines.firstIndex(of: wanted))
        XCTAssertGreaterThan(row, 0)
        if restoreOff { try voice.enable() }
        for _ in 0..<20 where !NSWorkspace.shared.isVoiceOverEnabled {
            try await Task.sleep(for: .milliseconds(250))
        }
        XCTAssertTrue(voice.isEnabled)
        XCTAssertTrue(NSWorkspace.shared.isVoiceOverEnabled)

        // On activation, VoiceOver can briefly focus XCTest's "Automation Running" panel.
        // Confirm it spoke the terminal's opening line before walking the unchanged text.
        let firstLine = "~/thrush % ./build.sh"
        XCTAssertEqual(lines.first, firstLine)
        var focused = false
        for attempt in 1...3 {
            app.activate()
            area.click()
            app.typeKey(.downArrow, modifierFlags: [.control, .option, .shift])
            app.typeKey(.home, modifierFlags: vo)
            if try await speech("focus \(attempt), home") == firstLine {
                focused = true
                break
            }
            app.typeKey(.downArrow, modifierFlags: vo)
            if try await speech("focus \(attempt), first line") == firstLine {
                focused = true
                break
            }
        }
        XCTAssertTrue(focused, "VoiceOver did not focus the terminal's opening line.")

        // The first VO-Down can repeat the line announced by VO-Home.
        for step in 1...(row + 1) {
            app.typeKey(.downArrow, modifierFlags: vo)
            if try await speech("next line \(step)") == wanted {
                XCTAssertEqual(area.value as? String, start)
                return
            }
        }
        XCTFail("VoiceOver did not speak the interior line ‘\(wanted)’ in the unchanged terminal transcript.")
    }

    private func speech(_ context: String) async throws -> String? {
        try await Task.sleep(for: .milliseconds(400))
        do {
            let utterance = try voice.currentSpeech().utterance
            print("VoiceOver \(context): \(utterance.debugDescription)")
            return utterance.trimmingCharacters(in: .newlines)
        } catch {
            print("VoiceOver \(context): \(error as NSError)")
            return nil
        }
    }
}
