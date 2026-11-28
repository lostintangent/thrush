import Foundation
import XCTest

@MainActor final class PaneVoiceOverProof: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "app.thrush.proofs")
    private let reader = XCUIDevice.shared.voiceOverService
    private var disableAtEnd = false

    override func setUpWithError() throws {
        continueAfterFailure = false
        disableAtEnd = !reader.isEnabled
        if disableAtEnd { try reader.enable() }
        XCTAssertTrue(reader.isEnabled)
        print("VOICEOVER XCTest service enabled=\(reader.isEnabled)")
    }

    override func tearDownWithError() throws {
        if disableAtEnd { try reader.disable() }
    }

    private func launch(_ scene: String) throws -> URL {
        let address = try XCTUnwrap(ProcessInfo.processInfo.environment["THRUSH_CAPTURE_ENDPOINT"])
        let endpoint = try XCTUnwrap(URL(string: address))
        app.launchArguments = ["--endpoint", address, "--scene", scene, "--hide-keyboard",
                               "--capture-state", "--capture-accessibility"]
        app.launch()
        return endpoint
    }

    /// Touch the element, ask what VoiceOver spoke, then try moving its reading cursor.
    /// Run the same commands on the stock Settings app and the packaged terminal.
    private func read(_ element: XCUIElement, expecting text: String) async throws -> String {
        print("VOICEOVER target=\(element.elementType) identifier=\(element.identifier) label=\(element.label)")
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        try await Task.sleep(for: .milliseconds(650))
        let movements: [(String, () throws -> XCUIVoiceOverService.Output)] = [
            ("currentSpeech", { try self.reader.currentSpeech() }),
            ("moveForward", { try self.reader.moveForward() }),
            ("moveBackward", { try self.reader.moveBackward() }),
            ("moveIn", { try self.reader.moveIn() })
        ]
        var diagnostics = [String]()
        for (name, move) in movements {
            do {
                let value = try move().utterance
                print("VOICEOVER \(name) utterance=\(value)")
                if value.localizedCaseInsensitiveContains(text) { return value }
                diagnostics.append("\(name) said \(value)")
            } catch {
                let error = error as NSError
                let detail = "\(name) failed: \(error)"
                diagnostics.append(detail)
                print("VOICEOVER " + detail)
            }
        }
        throw NSError(domain: "ThrushVoiceOverProof", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Expected speech containing \(text). " + diagnostics.joined(separator: " | ")
        ])
    }

    func testAppleSettingsVoiceOver() async throws {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launch()
        let title = settings.staticTexts.matching(NSPredicate(format: "label ==[c] %@", "Settings")).firstMatch
        let target: XCUIElement
        if title.waitForExistence(timeout: 10), title.isHittable {
            target = title
        } else {
            // A fresh OS can open a first-launch welcome page instead of the root list.
            target = try XCTUnwrap(settings.staticTexts.allElementsBoundByIndex.first {
                !$0.label.isEmpty && $0.isHittable
            }, settings.debugDescription)
        }
        let heard = try await read(target, expecting: target.label)
        print("VOICEOVER Settings native control spoke: \(heard)")
        print("VOICEOVER Settings moved to: \(try reader.moveForward().utterance)")
    }

    func testOpeningSpinnerAccessibilityLabel() throws {
        _ = try launch("spinner-opening")
        let spinner = app.descendants(matching: .any)["terminal.cursorSpinner"]
        XCTAssertTrue(spinner.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(spinner.label, "Connecting")
    }

    func testReadsTerminalLineAndExposesReconnectLabel() async throws {
        let endpoint = try launch("spinner-reconnecting")
        let row = app.staticTexts["Test run passed."]
        XCTAssertTrue(row.waitForExistence(timeout: 20), app.debugDescription)
        let focused: Result<String, Error>
        do { focused = .success(try await read(row, expecting: "Test run passed")) }
        catch { focused = .failure(error) }
        var interrupt = URLRequest(url: endpoint.appendingPathComponent("interrupt-reconnecting"))
        interrupt.httpMethod = "POST"
        let (_, response) = try await URLSession.shared.data(for: interrupt)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 204)
        let spinner = app.descendants(matching: .any)["terminal.cursorSpinner"]
        XCTAssertTrue(spinner.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(spinner.label, "Reconnecting")
        try await Task.sleep(for: .seconds(2))
        XCTAssertTrue(row.exists)
        print("VOICEOVER terminal line: \(try focused.get())")
    }
}
