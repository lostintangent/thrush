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
        let nativeLines = ["Orchard", "Juniper", "Cedar"]
        try nativeLines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let application = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        _ = try await NSWorkspace.shared.open([url], withApplicationAt: application, configuration: .init())
        let app = XCUIApplication(url: application)
        app.activate()
        let area = app.textViews.matching(NSPredicate(format: "value CONTAINS %@", wanted)).firstMatch
        XCTAssertTrue(area.waitForExistence(timeout: 20), app.debugDescription)
        try await enable()
        app.activate()
        area.click()
        // Check line commands independently in an ordinary editable AppKit text area.
        let heard = try await navigate(to: "Juniper", in: app, area: area, original: nativeLines)
        XCTAssertTrue(heard, "TextEdit did not speak the interior reference row.")
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
            XCTAssertEqual((area.value as? String)?.components(separatedBy: "\n"), lines)
            print("MAC-VO confirmed selected output row \(row + 1)")
            return
        }

        let navigated = try await navigate(to: wanted, in: app, area: area, original: lines)
        XCTAssertTrue(navigated, "VoiceOver did not read the completed output inside the unchanged transcript.")
    }

    private func navigate(to wanted: String, in app: XCUIApplication, area: XCUIElement,
                          original lines: [String]) async throws -> Bool {
        let row = try XCTUnwrap(lines.firstIndex(of: wanted))
        // Follow the standard VoiceOver text commands through the original, unchanged
        // transcript, keeping the element in focus. XCTest's moveForward is element navigation.
        let vo: XCUIElement.KeyModifierFlags = [.control, .option]
        app.typeKey(.downArrow, modifierFlags: [.control, .option, .shift])
        app.typeKey(.home, modifierFlags: vo)
        for step in 0...row + 1 {
            if step > 0 { app.typeKey(.downArrow, modifierFlags: vo) }
            try await Task.sleep(for: .milliseconds(400))
            let utterance: String
            do { utterance = try voice.currentSpeech().utterance }
            catch {
                print("MAC-VO text line step=\(step) reported \(error as NSError)")
                continue
            }
            print("MAC-VO text line step=\(step) utterance=\(utterance.debugDescription)")
            if utterance.localizedCaseInsensitiveContains(wanted),
               !utterance.localizedCaseInsensitiveContains(lines[0]) {
                XCTAssertEqual((area.value as? String)?.components(separatedBy: "\n"), lines)
                print("MAC-VO confirmed interior row in unchanged text: \(wanted)")
                return true
            }
        }
        return false
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
