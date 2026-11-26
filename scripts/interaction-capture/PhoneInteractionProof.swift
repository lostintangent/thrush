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
        XCUIDevice.shared.orientation = .portrait
        defer {
            XCUIDevice.shared.orientation = .portrait
            XCUIDevice.shared.appearance = previousAppearance
        }
        try launch(scene: "shell")
        let built = app.staticTexts["Build complete."]
        XCTAssertTrue(built.waitForExistence(timeout: 12), app.debugDescription)
        try assertKeyboard()
        try screenshot("shell-\(appearance)-portrait")

        let rotationOnly = ProcessInfo.processInfo.environment["THRUSH_CAPTURE_ROTATION_ONLY"] == "1"
        if !rotationOnly {
            try captureControl(appearance: appearance)
        }

        // Turn to landscape and back twice, since a stalled main thread can miss a turn's frames.
        let rotate = Date.now.timeIntervalSince1970
        var retainedBuild = true
        for trip in 0..<2 {
            XCUIDevice.shared.orientation = .landscapeLeft
            try waitForOrientation(landscape: true)
            try assertKeyboard()
            if trip == 0 {
                try screenshot("shell-\(appearance)-landscape")
            }
            retainedBuild = retainedBuild && built.exists
            XCUIDevice.shared.orientation = .portrait
            try waitForOrientation(landscape: false)
            try assertKeyboard()
        }
        try finishClip("rotate-\(appearance)", since: rotate)
        // Keep the settled portrait on screen through the movie's post-gesture padding.
        Thread.sleep(forTimeInterval: 0.75)
        XCTAssertTrue(retainedBuild, "Rotation should keep the build completion line visible above the prompt.")

        // The log fills the screen down to its prompt, so the grid travels with the keyboard.
        try launch(scene: "log")
        let wrapped = app.staticTexts[Self.wrappedText]
        XCTAssertTrue(wrapped.waitForExistence(timeout: 30), app.debugDescription)
        try captureKeyboard(appearance: appearance, keeping: wrapped)
        if !rotationOnly {
            try captureTranscript(appearance: appearance, wrapped: wrapped)
        }
    }

    private func captureControl(appearance: String) throws {
        let controls = app.buttons["Control"]
        let start = Date.now.timeIntervalSince1970
        controls.tap()
        XCTAssertTrue(controls.isSelected || controls.value as? String == "Armed")
        try screenshot("control-\(appearance)-armed")
        controls.tap()
        XCTAssertFalse(controls.isSelected)
        try finishClip("control-\(appearance)", since: start)
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

    private func launch(scene: String) throws {
        let address = try XCTUnwrap(ProcessInfo.processInfo.environment["THRUSH_CAPTURE_ENDPOINT"])
        app.launchArguments = ["--endpoint", address, "--scene", scene, "--keyboard", "--capture-state"]
        if scene == "shell", ProcessInfo.processInfo.environment["THRUSH_TRACE_ROTATION_LAYOUT"] == "1" {
            app.launchArguments.append("--trace-rotation-layout")
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
