import Foundation
import XCTest

/// Drives the installed demo through its UIKit accessibility tree and real screen coordinates.
/// The runner saves the app's framebuffer at each reviewed state and the intervals of motion.
@MainActor
final class PhoneInteractionProof: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "app.thrush.demo")
    private static let wrappedText = "1024  compile units/café/界/e\u{301}/long-dependency/with/nested-source-folders/unit-1024.h"

    func testDarkInteractions() throws { try capture(appearance: "dark") }
    func testLightInteractions() throws { try capture(appearance: "light") }

    private func capture(appearance: String) throws {
        continueAfterFailure = false
        let previousAppearance = XCUIDevice.shared.appearance
        XCUIDevice.shared.appearance = appearance == "dark" ? .dark : .light
        defer { XCUIDevice.shared.appearance = previousAppearance }
        try launch(scene: "shell")
        try waitForOrientation(landscape: false)
        let built = app.staticTexts["Build complete."]
        XCTAssertTrue(built.waitForExistence(timeout: 12), app.debugDescription)
        try assertKeyboard()
        try screenshot("shell-\(appearance)-portrait")
        try captureControl(appearance: appearance)

        // The log fills the screen down to its prompt, so the grid travels with the keyboard.
        try launch(scene: "log")
        let wrapped = app.staticTexts[Self.wrappedText]
        XCTAssertTrue(wrapped.waitForExistence(timeout: 30), app.debugDescription)
        try captureKeyboard(appearance: appearance, keeping: wrapped)
        try captureTranscript(appearance: appearance, wrapped: wrapped)
        try captureLastLine(appearance: appearance)

        // The simulated Duo's resizable scene doesn't turn with the device, so the shell opens turned instead.
        try launch(scene: "shell", landscape: true)
        try waitForOrientation(landscape: true)
        XCTAssertTrue(built.waitForExistence(timeout: 12), "Landscape should keep the build completion line above the prompt.")
        try assertKeyboard()
        try screenshot("shell-\(appearance)-landscape")
        try captureLandscapeControl(appearance: appearance)
    }

    /// Taps the modifier key to arm Control, chooses Shift from the chooser it raises, then holds the key
    /// and slides to Option.
    private func captureControl(appearance: String) throws {
        let modifier = app.buttons["terminal.modifier"]
        let choices = ["control", "option", "shift"].map { app.buttons["terminal.modifier.\($0)"] }
        let start = Date.now.timeIntervalSince1970
        modifier.tap()
        XCTAssertEqual(modifier.value as? String, "Armed")
        XCTAssertTrue(choices[2].waitForExistence(timeout: 3), app.debugDescription)
        // The chooser floats above the row with its Ctrl over the key, and every choice takes a 44-point tap.
        XCTAssertEqual(choices[0].frame.midX, modifier.frame.midX, accuracy: 1)
        for choice in choices {
            XCTAssertGreaterThanOrEqual(choice.frame.width, 44, choice.identifier)
            XCTAssertGreaterThanOrEqual(choice.frame.height, 44, choice.identifier)
            XCTAssertLessThanOrEqual(choice.frame.maxY, modifier.frame.minY - 7, choice.identifier)
        }
        try screenshot("control-\(appearance)-armed")
        // Choosing from the chooser proves its taps land though it floats above the keyboard's own window.
        choices[2].tap()
        XCTAssertEqual(modifier.label, "Shift")
        try screenshot("control-\(appearance)-shift")
        modifier.tap()
        let lowered = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: choices[2])
        XCTAssertEqual(XCTWaiter.wait(for: [lowered], timeout: 3), .completed)
        XCTAssertEqual(modifier.value as? String, "Off")

        // Option's center sits 64 points right of Ctrl's and 32 points above the row.
        let key = modifier.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        key.press(forDuration: 0.6, thenDragTo: key.withOffset(CGVector(dx: 64, dy: -(modifier.frame.height / 2 + 32))))
        XCTAssertEqual(modifier.label, "Option")
        XCTAssertEqual(modifier.value as? String, "Armed")
        try screenshot("control-\(appearance)-option")
        modifier.tap()
        XCTAssertEqual(modifier.value as? String, "Off")
        try finishClip("control-\(appearance)", since: start)
    }

    /// In landscape the chooser slims with the row, and its choices take taps beyond their 36-point capsule.
    private func captureLandscapeControl(appearance: String) throws {
        let modifier = app.buttons["terminal.modifier"]
        let choices = ["control", "option", "shift"].map { app.buttons["terminal.modifier.\($0)"] }
        modifier.tap()
        XCTAssertTrue(choices[2].waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertEqual(choices[0].frame.midX, modifier.frame.midX, accuracy: 1)
        for choice in choices {
            XCTAssertGreaterThanOrEqual(choice.frame.width, 44, choice.identifier)
            XCTAssertLessThanOrEqual(choice.frame.maxY, modifier.frame.minY - 7, choice.identifier)
        }
        choices[2].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: -3)).tap()
        XCTAssertEqual(modifier.label, "Shift")
        try screenshot("control-\(appearance)-landscape")
        modifier.tap()
        XCTAssertEqual(modifier.value as? String, "Off")
    }

    /// Hides the keyboard with the key row's button, then taps the transcript to bring it back.
    private func captureKeyboard(appearance: String, keeping line: XCUIElement) throws {
        try assertKeyboard()
        // Let the launch's keyboard settle before the clip begins.
        Thread.sleep(forTimeInterval: 0.75)
        let keyboard = app.keyboards.firstMatch
        let start = Date.now.timeIntervalSince1970
        app.buttons["Hide Keyboard"].tap()
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: keyboard)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 6), .completed)
        // Let the taller grid settle on screen before the keyboard returns.
        Thread.sleep(forTimeInterval: 0.75)
        XCTAssertTrue(line.exists, "Hiding the keyboard should keep the wrapped line in view.")
        try screenshot("keyboard-\(appearance)-hidden")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        try assertKeyboard()
        XCTAssertTrue(line.exists, "Showing the keyboard should keep the wrapped line in view.")
        try finishClip("keyboard-\(appearance)", since: start)
        Thread.sleep(forTimeInterval: 0.75)
    }

    private func captureTranscript(appearance: String, wrapped: XCUIElement) throws {
        let transcript = app.coordinate(withNormalizedOffset: .zero)
        let wordPoint = transcript.withOffset(CGVector(dx: wrapped.frame.minX + 8,
                                                       dy: wrapped.frame.minY + 8))
        let select = Date.now.timeIntervalSince1970
        wordPoint.press(forDuration: 0.65)
        let selected = app.staticTexts["Selected text"]
        XCTAssertTrue(selected.waitForExistence(timeout: 6))
        XCTAssertEqual(selected.value as? String, "1024")
        let selectLine = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Select Line'")).firstMatch
        XCTAssertTrue(selectLine.waitForExistence(timeout: 6), app.debugDescription)
        try screenshot("word-\(appearance)-menu")
        selectLine.tap()
        let full = NSPredicate(format: "value == %@", Self.wrappedText)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: full, object: selected)], timeout: 5), .completed)
        try screenshot("line-\(appearance)-selected")
        let copy = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Copy'")).firstMatch
        if !copy.exists || !copy.isHittable {
            // UIKit can dismiss the edit menu after an action. Tap inside the
            // highlighted line, clear of its handles, to reopen the menu.
            transcript.withOffset(CGVector(dx: wrapped.frame.midX, dy: wrapped.frame.minY + 8)).tap()
        }
        XCTAssertTrue(copy.waitForExistence(timeout: 6))
        copy.tap()
        try finishClip("select-\(appearance)", since: select)

        let upper = transcript.withOffset(CGVector(dx: app.frame.midX, dy: app.frame.height * 0.19))
        let lower = transcript.withOffset(CGVector(dx: app.frame.midX, dy: app.frame.height * 0.42))
        let history = Date.now.timeIntervalSince1970
        upper.press(forDuration: 0.08, thenDragTo: lower)
        let latest = app.buttons["terminal.latest"]
        XCTAssertTrue(latest.waitForExistence(timeout: 6))
        XCTAssertGreaterThanOrEqual(latest.frame.height, 44)
        try screenshot("history-\(appearance)-latest")
        latest.tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: latest)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 5), .completed)
        let live = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '1030  compile'")).firstMatch
        XCTAssertTrue(live.exists)
        try finishClip("history-\(appearance)", since: history)
    }

    /// With the keyboard down, the last row runs on under the home indicator, and a long press there still selects.
    private func captureLastLine(appearance: String) throws {
        let keyboard = app.keyboards.firstMatch
        if keyboard.exists {
            app.buttons["Hide Keyboard"].tap()
            let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: keyboard)
            XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 6), .completed)
        }
        Thread.sleep(forTimeInterval: 0.75)
        // Terminal lines span the grid's width. The log fills the grid down to its prompt.
        let lines = app.staticTexts.allElementsBoundByIndex.filter { $0.frame.width > app.frame.width * 0.8 }
        let last = try XCTUnwrap(lines.max { $0.frame.maxY < $1.frame.maxY }, app.debugDescription)
        // Within a row of the grid's 8-point bottom inset, below the home indicator's safe area.
        XCTAssertGreaterThanOrEqual(app.frame.maxY - last.frame.maxY, 7.5, last.label)
        XCTAssertLessThan(app.frame.maxY - last.frame.maxY, 8 + last.frame.height, last.label)
        let label = last.label
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: last.frame.minX + 8, dy: last.frame.midY)).press(forDuration: 0.65)
        let selected = app.staticTexts["Selected text"]
        let word = NSPredicate { element, _ in
            guard let value = (element as? XCUIElement)?.value as? String else { return false }
            return !value.isEmpty && label.contains(value)
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: word, object: selected)], timeout: 6),
                       .completed, "\(selected.value ?? "nothing") isn't from the last line, \(label)")
        try screenshot("line-\(appearance)-last")
    }

    private func launch(scene: String, landscape: Bool = false) throws {
        let address = try XCTUnwrap(ProcessInfo.processInfo.environment["THRUSH_CAPTURE_ENDPOINT"])
        app.launchArguments = ["--endpoint", address, "--scene", scene, "--keyboard", "--capture-state"]
        if landscape {
            app.launchArguments.append("--capture-landscape")
        }
        app.launch()
    }

    private func waitForOrientation(landscape: Bool) throws {
        let displayed = NSPredicate { [app] _, _ in (app.frame.width > app.frame.height) == landscape }
        let ready = XCTNSPredicateExpectation(predicate: displayed, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 12), .completed)
    }

    private func assertKeyboard() throws {
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 12), app.debugDescription)
        let keys = ["Esc", "Control", "Tab", "Left arrow", "Up arrow", "Down arrow", "Right arrow", "Hide Keyboard"]
        for name in keys {
            let key = app.buttons[name]
            XCTAssertTrue(key.exists, name)
            XCTAssertGreaterThanOrEqual(key.frame.width, 44, name)
            // Landscape's 36-point capsule floats 8 points above the keyboard, and its keys take
            // taps down to the keyboard's edge, so every target stays 44 points tall.
            XCTAssertGreaterThanOrEqual(key.frame.height, 36, name)
            XCTAssertGreaterThanOrEqual(keyboard.frame.minY - key.frame.minY, 44, name)
        }
    }

    private func screenshot(_ name: String) throws {
        save(XCUIScreen.main.screenshot().pngRepresentation, name: name, type: "public.png")
    }

    private func finishClip(_ name: String, since start: TimeInterval) throws {
        let data = try JSONEncoder().encode([start, Date.now.timeIntervalSince1970])
        save(data, name: name, type: "public.json")
    }

    private func save(_ data: Data, name: String, type: String) {
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: type)
        attachment.name = "thrush-proof__" + name + "__"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
