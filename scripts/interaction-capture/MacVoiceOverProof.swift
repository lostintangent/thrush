import AppKit
import XCTest

@MainActor final class MacVoiceOverProof: XCTestCase {
    private let voice = XCUIDevice.shared.voiceOverService
    private var restoreOff = false

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["THRUSH_TEST_VOICEOVER"] == "true")
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        if restoreOff, voice.isEnabled { try voice.disable() }
    }

    private func enable() async throws {
        restoreOff = !voice.isEnabled
        if restoreOff { try voice.enable() }
        for _ in 0..<20 where !NSWorkspace.shared.isVoiceOverEnabled {
            try await Task.sleep(for: .milliseconds(250))
        }
        print("MAC-VO XCTest=\(voice.isEnabled), NSWorkspace=\(NSWorkspace.shared.isVoiceOverEnabled)")
        XCTAssertTrue(voice.isEnabled)
        XCTAssertTrue(NSWorkspace.shared.isVoiceOverEnabled)
    }

    func testSystemTextEdit() async throws {
        let wanted = "Orchard"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("VoiceOver reference " + UUID().uuidString + ".txt")
        try wanted.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let application = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        _ = try await NSWorkspace.shared.open([url], withApplicationAt: application, configuration: .init())
        let app = XCUIApplication(url: application)
        app.activate()
        let area = app.textViews.matching(NSPredicate(format: "value == %@", wanted)).firstMatch
        XCTAssertTrue(area.waitForExistence(timeout: 20), app.debugDescription)
        try await enable()
        app.activate()
        area.click()
        let heard = try await read(wanted, in: app)
        XCTAssertTrue(heard)
    }

    func testTerminalTranscriptRow() async throws {
        let wanted = "Build complete."
        let env = ProcessInfo.processInfo.environment
        let app = XCUIApplication(url: URL(fileURLWithPath: try XCTUnwrap(env["THRUSH_VOICEOVER_APP"])))
        app.launchArguments = ["--scene", "shell", "--endpoint", try XCTUnwrap(env["THRUSH_CAPTURE_ENDPOINT"])]
        app.launch()
        defer { app.terminate() }
        let area = app.textViews["Terminal"]
        let loaded = app.textViews.matching(NSPredicate(format: "value CONTAINS %@", wanted)).firstMatch
        XCTAssertTrue(loaded.waitForExistence(timeout: 20))
        let lines = try XCTUnwrap(area.value as? String).components(separatedBy: "\n")
        let row = try XCTUnwrap(lines.firstIndex(of: wanted))
        XCTAssertGreaterThan(row, 0)
        try await enable()
        app.activate()

        // Select this output line with the ordinary mouse gesture in the sample's default
        // 14-point monospaced grid. VoiceOver can report a selection within one text area.
        let font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        let advance = ("0" as NSString).size(withAttributes: [.font: font]).width
        let top = area.coordinate(withNormalizedOffset: .zero)
        let y = 10 + (CGFloat(row) + 0.5) * 18
        let start = top.withOffset(CGVector(dx: 12 + 0.3 * advance, dy: y))
        let end = top.withOffset(CGVector(dx: 12 + (CGFloat(wanted.count) - 0.3) * advance, dy: y))
        start.click(forDuration: 0.2, thenDragTo: end)
        if try await read(wanted, in: app) {
            print("MAC-VO confirmed selected output row \(row + 1)")
            return
        }

        // This text area also presents the top visible line on focus. Advance the actual
        // shell with Return until the completed build becomes the first visible output.
        for _ in 0..<(lines.count + 2) {
            let visible = try XCTUnwrap(area.value as? String).components(separatedBy: "\n")
            if visible.first == wanted { break }
            XCTAssertTrue(visible.contains(wanted), "The output scrolled past the window.")
            app.typeKey(.return, modifierFlags: [])
        }
        XCTAssertEqual((area.value as? String)?.components(separatedBy: "\n").first, wanted)
        start.withOffset(CGVector(dx: 0, dy: -CGFloat(row) * 18)).click()
        let heard = try await read(wanted, in: app)
        XCTAssertTrue(heard, "VoiceOver did not speak the visible output row.")
        print("MAC-VO confirmed output after the shell scrolled")
    }

    private func read(_ wanted: String, in app: XCUIApplication) async throws -> Bool {
        app.typeKey("l", modifierFlags: [.control, .option])
        try await Task.sleep(for: .milliseconds(550))
        for command in ["currentSpeech", "moveIn"] {
            do {
                let output = try command == "currentSpeech" ? voice.currentSpeech() : voice.moveIn()
                print("MAC-VO \(command) utterance=\(output.utterance.debugDescription)")
                if output.utterance.localizedCaseInsensitiveContains(wanted) { return true }
            } catch { print("MAC-VO \(command) reported \(error as NSError)") }
        }
        return false
    }
}
