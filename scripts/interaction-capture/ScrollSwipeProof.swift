import Foundation
import XCTest

/// Swipes through less, vim and the shell's history on a real shell, then makes the same gestures in Settings.
/// Each gesture saves its timing so the capture can line it up with the bytes the program read.
@MainActor final class ScrollSwipeProof: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "app.thrush.demo")
    private let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
    private let environment = ProcessInfo.processInfo.environment

    func testDarkSwipes() throws { try capture(appearance: "dark") }
    func testLightSwipes() throws { try capture(appearance: "light") }

    private func capture(appearance: String) throws {
        continueAfterFailure = false
        XCUIDevice.shared.appearance = appearance == "dark" ? .dark : .light
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["--endpoint", try XCTUnwrap(environment["THRUSH_CAPTURE_ENDPOINT"]),
                               "--appearance", appearance, "--keyboard", "--capture-state"]
        app.launch()
        try waitForPrompt()
        for program in ["less", "vim"] {
            try swipeThrough(program, appearance: appearance)
        }
        try swipeThroughHistory(appearance: appearance)
        try compareWithSettings(appearance: appearance)
    }

    private func swipeThrough(_ program: String, appearance: String) throws {
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 12), app.debugDescription)
        try type("\(program) birds\n")
        let first = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '001 '")).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 15), app.debugDescription)
        app.buttons["Hide Keyboard"].tap()
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: 6))
        Thread.sleep(forTimeInterval: 1)
        let start = Date.now.timeIntervalSince1970
        try swipeSequence("\(program)-\(appearance)")
        try finishClip("\(program)-\(appearance)", since: start)
        try tapToType("\(program)-\(appearance)-tap")
        try type("q")
        try waitForPrompt()
    }

    /// Makes the same gestures over the shell's own history, where UIScrollView moves the rows.
    private func swipeThroughHistory(appearance: String) throws {
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 12), app.debugDescription)
        try type("cat birds\n")
        let last = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '400 '")).firstMatch
        XCTAssertTrue(last.waitForExistence(timeout: 15), app.debugDescription)
        app.buttons["Hide Keyboard"].tap()
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: 6))
        Thread.sleep(forTimeInterval: 1)
        let start = Date.now.timeIntervalSince1970
        // Reach far enough back that the gestures toward the latest output don't arrive there.
        try swipe("history-\(appearance)-enter", from: 0.3, to: 0.75, velocity: 3000)
        try swipe("history-\(appearance)-enter-2", from: 0.3, to: 0.75, velocity: 3000)
        // XCUITest waits for UIScrollView to come to rest, so a tap can't catch the history's flick.
        try swipeSequence("history-\(appearance)", catching: false)
        // The same flick glides a little differently each time, so history plays each one again for a range.
        try swipe("history-\(appearance)-flick-2", from: 0.7, to: 0.45, velocity: 800)
        try swipe("history-\(appearance)-fast-2", from: 0.7, to: 0.45, velocity: 1600)
        try finishClip("history-\(appearance)", since: start)
    }

    private func swipeSequence(_ name: String, catching: Bool = true) throws {
        // A finger moving up reaches later lines, and one moving down returns to earlier ones.
        try swipe("\(name)-slow", from: 0.62, to: 0.38, velocity: 150, hold: 0.5)
        try swipe("\(name)-slow-back", from: 0.38, to: 0.62, velocity: 150, hold: 0.5)
        try swipe("\(name)-flick", from: 0.7, to: 0.45, velocity: 800)
        screenshot("\(name)-flicked")
        try swipe("\(name)-fast", from: 0.7, to: 0.45, velocity: 1600)
        if catching { try swipe("\(name)-catch", from: 0.7, to: 0.45, velocity: 1600, catching: true) }
        try swipe("\(name)-return", from: 0.3, to: 0.75, velocity: 3000)
    }

    /// Taps the program once its glide has come to rest, which should bring the keyboard back.
    /// Saves whether it did for the check, then taps again if a glide still coasting swallowed the first.
    private func tapToType(_ name: String) throws {
        let keyboard = app.keyboards.firstMatch
        let center = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let tapped = Date.now.timeIntervalSince1970
        center.tap()
        let opened = keyboard.waitForExistence(timeout: 3)
        save(try JSONSerialization.data(withJSONObject: ["tapped": tapped, "keyboard": opened]), name: name,
             type: "public.json")
        if !opened { center.tap() }
        XCTAssertTrue(keyboard.waitForExistence(timeout: 6), app.debugDescription)
    }

    private func compareWithSettings(appearance: String) throws {
        settings.launch()
        XCTAssertTrue(settings.staticTexts["General"].waitForExistence(timeout: 20), settings.debugDescription)
        Thread.sleep(forTimeInterval: 1)
        let start = Date.now.timeIntervalSince1970
        var labels: [String: Any] = ["height": settings.frame.height]
        for (name, from, to, velocity, hold) in [("slow", 0.62, 0.38, 150.0, 0.5), ("slow-back", 0.38, 0.62, 150, 0.5),
                                                 ("flick", 0.7, 0.45, 800, 0)] {
            let before = labelPositions()
            try swipe("settings-\(appearance)-\(name)", from: from, to: to, velocity: velocity, hold: hold, in: settings)
            labels[name] = ["before": before, "after": labelPositions()]
        }
        screenshot("settings-\(appearance)-flicked")
        try swipe("settings-\(appearance)-return", from: 0.3, to: 0.75, velocity: 3000, in: settings)
        try swipe("settings-\(appearance)-fast", from: 0.7, to: 0.45, velocity: 1600, in: settings)
        try finishClip("settings-\(appearance)", since: start)
        save(try JSONSerialization.data(withJSONObject: labels), name: "settings-\(appearance)-labels", type: "public.json")
    }

    /// Settles for longer than a flick at these speeds coasts, then saves when the gesture began and returned.
    private func swipe(_ name: String, from: CGFloat, to: CGFloat, velocity: CGFloat, hold: TimeInterval = 0,
                       catching: Bool = false, in target: XCUIApplication? = nil) throws {
        let target = target ?? app
        func point(_ y: CGFloat) -> XCUICoordinate { target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: y)) }
        let start = Date.now.timeIntervalSince1970
        var returned = start, caught: Any = NSNull()
        if catching {
            (returned, caught) = try flick(from: point(from).screenPoint, to: point(to).screenPoint, velocity: velocity,
                                           caughtAt: point(0.5).screenPoint)
        } else {
            point(from).press(forDuration: 0.05, thenDragTo: point(to),
                              withVelocity: XCUIGestureVelocity(rawValue: velocity), thenHoldForDuration: hold)
            returned = Date.now.timeIntervalSince1970
        }
        Thread.sleep(forTimeInterval: 3)
        let record: [String: Any] = [
            "start": start, "returned": returned, "caught": caught, "settled": Date.now.timeIntervalSince1970,
            "velocity": velocity, "hold": hold, "travel": (from - to) * target.frame.height,
            "keyboard": target.keyboards.firstMatch.exists,
        ]
        save(try JSONSerialization.data(withJSONObject: record), name: name, type: "public.json")
    }

    /// Plays a flick and a touch 150 ms after it lifts as one event record, since XCUITest waits for a glide that
    /// UIScrollView decelerates to come to rest before its next action. Returns when the flick lifted and the touch ended.
    private func flick(from start: CGPoint, to end: CGPoint, velocity: CGFloat,
                       caughtAt point: CGPoint) throws -> (TimeInterval, TimeInterval) {
        let paths = try xcTest("XCPointerEventPath", as: EventPath.Type.self)
        let lift = 0.05 + hypot(end.x - start.x, end.y - start.y) / velocity, touch = lift + 0.15, done = touch + 0.05
        // The same path XCUICoordinate builds for a press, drag and lift.
        let flick = paths.init(touchAt: start, offset: 0)
        flick.move(to: start, at: 0.05)
        flick.move(to: end, at: lift)
        flick.liftUp(at: lift)
        let tap = paths.init(touchAt: point, offset: touch)
        tap.liftUp(at: done)
        let record = try xcTest("XCSynthesizedEventRecord", as: EventRecord.Type.self)
            .init(name: "Flick and catch", interfaceOrientation: UIInterfaceOrientation.portrait.rawValue)
        record.add(flick)
        record.add(tap)
        let began = Date.now.timeIntervalSince1970
        try record.synthesize()
        let ended = Date.now.timeIntervalSince1970
        // A synthesizer that waited for the glide to rest would hide a touch that failed to stop it.
        XCTAssertLessThan(ended - began, done + 1, "The event synthesizer waited for the app to idle.")
        return (ended - (done - lift), ended)
    }

    private func xcTest<Type>(_ name: String, as type: Type.Type) throws -> Type {
        unsafeBitCast(try XCTUnwrap(NSClassFromString(name), "XCTest no longer has \(name)."), to: type)
    }

    private func labelPositions() -> [[Any]] {
        settings.staticTexts.allElementsBoundByIndex.compactMap { text in
            text.exists ? [text.label, text.frame.midY] : nil
        }
    }

    private func waitForPrompt() throws {
        let prompt = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'thrush$' AND NOT label CONTAINS 'birds'"))
        XCTAssertTrue(prompt.firstMatch.waitForExistence(timeout: 30), app.debugDescription)
    }

    private func type(_ text: String) throws {
        for character in text {
            let key = switch character {
            case "\n": app.keyboards.descendants(matching: .any).matching(NSPredicate(format: "label ==[c] 'return'")).firstMatch
            case " ": app.keyboards.keys["space"]
            default: app.keyboards.keys[String(character)]
            }
            XCTAssertTrue(key.waitForExistence(timeout: 3), "Missing English keyboard key \(character.debugDescription).")
            key.tap()
        }
    }

    private func screenshot(_ name: String) {
        save(XCUIScreen.main.screenshot().pngRepresentation, name: name, type: "public.png")
    }

    private func finishClip(_ name: String, since start: TimeInterval) throws {
        save(try JSONEncoder().encode([start, Date.now.timeIntervalSince1970]), name: name, type: "public.json")
    }

    private func save(_ data: Data, name: String, type: String) {
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: type)
        attachment.name = "thrush-proof__" + name + "__"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

/// XCTest's event records, which XCUICoordinate builds its gestures from.
@objc private protocol EventPath {
    @objc(initForTouchAtPoint:offset:) init(touchAt point: CGPoint, offset: TimeInterval)
    @objc(moveToPoint:atOffset:) func move(to point: CGPoint, at offset: TimeInterval)
    @objc(liftUpAtOffset:) func liftUp(at offset: TimeInterval)
}

@objc private protocol EventRecord {
    @objc(initWithName:interfaceOrientation:) init(name: String, interfaceOrientation: Int)
    @objc(addPointerEventPath:) func add(_ path: EventPath)
    @objc(synthesizeWithError:) func synthesize() throws
}
