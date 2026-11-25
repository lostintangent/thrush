import AppKit
import ApplicationServices
import XCTest

/// Only the disposable hosted Mac runs these tests. The build-only path reads no accessibility preferences.
@MainActor final class MacVoiceOverProof: XCTestCase {
    private let voice = XCUIDevice.shared.voiceOverService
    private var restoreOff = false

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["THRUSH_DISPOSABLE_VOICEOVER"] == "true")
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
        print("MAC-VO XCT enabled=\(voice.isEnabled), NSWorkspace enabled=\(NSWorkspace.shared.isVoiceOverEnabled), accessibility client trusted=\(AXIsProcessTrusted())")
        XCTAssertTrue(voice.isEnabled)
    }

    func testSystemTextEdit() async throws {
        let row = "Orchard reference line."
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Thrush VoiceOver Reference.txt")
        try (row + "\n").write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let application = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        _ = try await NSWorkspace.shared.open([url], withApplicationAt: application, configuration: .init())
        let app = XCUIApplication(url: application)
        app.activate()
        try await hear(row, in: app, bundleIdentifier: "com.apple.TextEdit")
    }

    func testTerminalTranscriptRow() async throws {
        let env = ProcessInfo.processInfo.environment
        let app = XCUIApplication(url: URL(fileURLWithPath: try XCTUnwrap(env["THRUSH_VOICEOVER_APP"])))
        app.launchArguments = ["--scene", "notice-reconnecting", "--endpoint", try XCTUnwrap(env["THRUSH_CAPTURE_ENDPOINT"])]
        app.launch()
        defer { app.terminate() }
        try await hear("Test run passed.", in: app, bundleIdentifier: "app.thrush.demo")
    }

    private func hear(_ wanted: String, in app: XCUIApplication, bundleIdentifier: String) async throws {
        let text = app.textViews.matching(NSPredicate(format: "value CONTAINS %@", wanted)).firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 20), app.debugDescription)
        let running = try XCTUnwrap(NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first)
        print("MAC-VO text area=\(text.label), row=\(wanted), PID=\(running.processIdentifier)")
        try await enable()
        app.activate()
        func selectRow() {
            text.click()
            // Use the same published AX selected-text range a screen reader uses. This locates
            // the row from the native text, independent of the terminal's grid size and font.
            if let area = textArea(AXUIElementCreateApplication(running.processIdentifier), containing: wanted),
               let contents = value(area, kAXValueAttribute) as? String {
                let range = (contents as NSString).range(of: wanted)
                var selected = CFRange(location: range.location, length: range.length)
                if let encoded = AXValueCreate(.cfRange, &selected) {
                    let status = AXUIElementSetAttributeValue(area, kAXSelectedTextRangeAttribute as CFString, encoded)
                    print("MAC-VO selection status=\(status.rawValue), selected=\(value(area, kAXSelectedTextAttribute) as? String ?? "")")
                }
            }
        }
        selectRow()
        var outputs = [String]()
        let commands: [(String, () throws -> XCUIVoiceOverService.Output)] = [
            ("currentSpeech", { try self.voice.currentSpeech() }),
            ("moveIn", { try self.voice.moveIn() }),
            ("moveForward", { try self.voice.moveForward() }),
            ("moveBackward", { try self.voice.moveBackward() })
        ]
        app.typeKey("l", modifierFlags: [.control, .option])
        for (name, action) in commands {
            try await Task.sleep(for: .milliseconds(400))
            do {
                let utterance = try action().utterance
                outputs.append(utterance)
                print("MAC-VO \(name) utterance=\(utterance.debugDescription)")
                if utterance.localizedCaseInsensitiveContains(wanted.trimmingCharacters(in: .punctuationCharacters)) {
                    print("MAC-VO confirmed row=\(wanted)")
                    return
                }
            } catch {
                print("MAC-VO \(name) error=\(error as NSError)")
            }
        }
        // The shipped VoiceOver scripting dictionary also exposes the last phrase it spoke.
        // Read it on both sides of the line command so a previous utterance cannot count as proof.
        let baseline = await lastPhrase()
        app.activate()
        selectRow()
        app.typeKey("l", modifierFlags: [.control, .option])
        try await Task.sleep(for: .milliseconds(900))
        if let current = await lastPhrase(), let baseline, current != baseline,
           current.localizedCaseInsensitiveContains(wanted.trimmingCharacters(in: .punctuationCharacters)) {
            print("MAC-VO confirmed native last phrase=\(current.debugDescription)")
            return
        }
        XCTFail("No VoiceOver utterance contained \(wanted). Received \(outputs)")
    }

    private func lastPhrase() async -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", #"tell application id "com.apple.VoiceOver" to get content of last phrase"#]
        process.standardOutput = output
        process.standardError = output
        do { try process.run() } catch { print("MAC-VO last phrase unavailable: \(error)"); return nil }
        for _ in 0..<12 where process.isRunning { try? await Task.sleep(for: .milliseconds(250)) }
        guard !process.isRunning else {
            process.terminate()
            print("MAC-VO last phrase timed out")
            return nil
        }
        let phrase = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        print("MAC-VO \(Date().timeIntervalSince1970) AppleScript status=\(process.terminationStatus) last phrase=\(phrase.debugDescription)")
        return process.terminationStatus == 0 ? phrase : nil
    }

    private func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
        return result
    }

    private func textArea(_ element: AXUIElement, containing row: String, depth: Int = 0) -> AXUIElement? {
        guard depth < 20 else { return nil }
        if value(element, kAXRoleAttribute) as? String == kAXTextAreaRole,
           (value(element, kAXValueAttribute) as? String)?.contains(row) == true { return element }
        for child in value(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            if let match = textArea(child, containing: row, depth: depth + 1) { return match }
        }
        return nil
    }
}
