import Foundation
import Observation
import Synchronization
import Testing
@testable import Thrush

@MainActor private final class ChangeCount {
    private(set) var count = 0

    func observe(_ read: () -> Void) {
        withObservationTracking(read) {
            MainActor.assumeIsolated { self.count += 1 }
        }
    }
}

@MainActor @Test func observingSessionMetadataAcrossAttachments() async throws {
    let peer = try ShellTestPeer()
    defer { peer.stop() }
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while peer.port == nil {
        try #require(ContinuousClock.now < deadline, "The loopback peer did not start.")
        try await Task.sleep(for: .milliseconds(10))
    }
    let port = try #require(peer.port)
    let url = try #require(URL(string: "ws://127.0.0.1:\(port)/socket"))
    let urlSession = URLSession(configuration: .ephemeral)
    defer { urlSession.invalidateAndCancel() }
    let clientID = UUID().uuidString
    let attempts = Mutex<[URL]>([])
    let session = TerminalSession { size in
        let endpoint = url.appending(queryItems: [
            URLQueryItem(name: "clientId", value: clientID),
            URLQueryItem(name: "cols", value: String(size.columns)),
            URLQueryItem(name: "rows", value: String(size.rows)),
        ])
        attempts.withLock { $0.append(endpoint) }
        return urlSession.webSocketTask(with: endpoint)
    }
    var theme = TerminalTheme.slateDark
    theme.cursor = .init(red: 29, green: 103, blue: 197)
    await session.setTheme(theme)
    let titleChanges = ChangeCount()
    let endChanges = ChangeCount()
    titleChanges.observe { _ = session.title }
    endChanges.observe { _ = session.hasEnded }

    func attach(resumed: Bool) async throws {
        peer.resumeNextAttachment = resumed
        try #require(await session.actor.show())
        let event = try await session.actor.nextEvent()
        try #require(event == .ready(resumed: resumed))
    }
    func output(_ text: String, expecting expected: SessionActor.Event = .output) async throws {
        try peer.send(text, opcode: .binary)
        #expect(try await session.actor.nextEvent() == expected)
        #expect(await session.actor.currentTerminal.cursorColor == theme.cursor)
    }

    #expect(session.title.isEmpty && !session.hasEnded)
    try await session.actor.sendResize(to: .init(columns: 77, rows: 21))
    try await attach(resumed: false)
    try await output("ordinary output")
    #expect(titleChanges.count == 0 && endChanges.count == 0)
    try await output("\u{1b}]2;Shell title\u{7}")
    #expect(session.title == "Shell title" && titleChanges.count == 1)

    titleChanges.observe { _ = session.title }
    try await output("\u{1b}]2;Shell title\u{7}more output")
    await session.actor.hide()
    try await session.actor.sendResize(to: .init(columns: 47, rows: 25))
    try await attach(resumed: true)
    let queries = attempts.withLock { $0.map(\.query) }
    #expect(queries == ["clientId=\(clientID)&cols=77&rows=21", "clientId=\(clientID)&cols=47&rows=25"])
    #expect(session.title == "Shell title" && titleChanges.count == 1)
    #expect(await session.actor.text(inRow: 0) == "ordinary outputmore output")
    try await output("\u{1b}]2;Shell title\u{7}restored output", expecting: .replay)
    #expect(await session.actor.text(inRow: 0) == "restored output")
    #expect(titleChanges.count == 1)

    // An empty replay supersedes the retained title, even without a title sequence.
    await session.actor.hide()
    try await attach(resumed: true)
    try await output("", expecting: .replay)
    #expect(session.title.isEmpty && titleChanges.count == 2)
    try await output("\u{1b}]2;Another session\u{7}")
    titleChanges.observe { _ = session.title }
    try peer.send(#"{"type":"ready","resumed":true}"#, opcode: .text)
    try peer.send("\u{1b}]2;\u{7}restored output", opcode: .binary)
    #expect(try await session.actor.nextEvent() == .replay)
    #expect(await session.actor.currentTerminal.cursorColor == theme.cursor)
    #expect(session.title.isEmpty && titleChanges.count == 3 && endChanges.count == 0)

    try await output("\u{1b}]2;Finished\u{7}")
    try peer.send(#"{"type":"exit"}"#, opcode: .text)
    #expect(try await session.actor.nextEvent() == .exit)
    #expect(session.title == "Finished" && session.hasEnded && endChanges.count == 1)
    endChanges.observe { _ = session.hasEnded }
    #expect(await session.actor.show(userInitiated: true) == false)
    #expect(session.hasEnded && session.title == "Finished")
    #expect(endChanges.count == 1)
}

@MainActor @Test func releasingSessionInterruptsQuietWebSocketReadAndPreservesTheShell() async throws {
    let peer = try ShellTestPeer()
    defer { peer.stop() }
    let deadline = ContinuousClock.now + .seconds(5)
    func waitFor(_ expected: Comment, until condition: () -> Bool) async throws {
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition(), expected)
    }
    try await waitFor("The loopback peer must be listening.") { peer.port != nil }
    let port = try #require(peer.port)
    let endpoint = try #require(URL(string: "ws://127.0.0.1:\(port)/socket"))
    let sockets = URLSession(configuration: .ephemeral)
    defer { sockets.invalidateAndCancel() }
    var session: TerminalSession? = TerminalSession { _ in sockets.webSocketTask(with: endpoint) }
    weak let released = session
    let actor = try #require(session?.actor)
    try #require(await actor.show())

    try await actor.readUpdates(into: OutputMailbox(), notify: {}) { update in
        if case .fresh = update { return false }
        Issue.record("Expected a fresh shell")
        return false
    }

    // The second read proves the first one reached the quiet socket before the app releases it.
    var pendingRead = false
    var interrupted = false
    let readers = (0..<2).map { _ in
        Task {
            do {
                try await actor.readUpdates(into: OutputMailbox(), notify: {
                    Issue.record("The quiet socket delivered output.")
                }) { _ in
                    Issue.record("The quiet socket delivered an unexpected update.")
                    return false
                }
            } catch SessionActor.TransportError.concurrentRead {
                pendingRead = true
            } catch is CancellationError {
                interrupted = true
            } catch {
                Issue.record(error)
            }
        }
    }
    defer { for reader in readers { reader.cancel() } }
    try await waitFor("One reader must be waiting on the quiet socket.") { pendingRead }
    session = nil
    #expect(released == nil)
    try await waitFor("The read must return and the peer must see a disconnect.") { interrupted && peer.closes == 1 }
    #expect(peer.opens == 1)
    #expect(peer.receivedText.isEmpty)
    #expect(await actor.state == .idle)
}

@MainActor @Test func programsHearTheCurrentFocusEvenWhenItChangesDuringAReply() async throws {
    let peer = try ShellTestPeer()
    defer { peer.stop() }
    let deadline = ContinuousClock.now + .seconds(5)
    func waitFor(_ expected: Comment, until condition: () -> Bool) async throws {
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition(), expected)
    }
    try await waitFor("The loopback peer must be listening.") { peer.port != nil }
    let port = try #require(peer.port)
    let actor = Mutex<SessionActor?>(nil)
    let focusDuringReply = Mutex<Bool?>(nil)
    // Changes focus as the output's reply goes out, the moment a racing click or tap would land.
    let session = try TerminalSession(baseURL: try #require(URL(string: "http://127.0.0.1:\(port)")),
                                      clientID: "focus", onOutput: { _ in
        guard let focused = focusDuringReply.withLock({ $0.take() }), let actor = actor.withLock({ $0 }) else { return }
        actor.assumeIsolated { actor in Task { try? await actor.setFocused(focused) } }
    })
    actor.withLock { $0 = session.actor }
    let report = "\u{1b}[?1004h"

    // A program that asks hears the current focus at once, then each change, even one made while
    // the title it set is being published.
    try #require(await session.actor.show())
    #expect(try await session.actor.nextEvent() == .ready(resumed: false))
    focusDuringReply.withLock { $0 = true }
    try peer.send("\u{1b}]2;oshen\u{7}" + report, opcode: .binary)
    #expect(try await session.actor.nextEvent() == .output)
    try await session.actor.setFocused(true)
    try await session.actor.setFocused(false)
    try await waitFor("The program must hear each focus change once.") { peer.receivedBinary.count == 3 }
    #expect(peer.receivedBinary == ["\u{1b}[O", "\u{1b}[I", "\u{1b}[O"])

    // Focus returns while the network is down, and a key waits for the resumed shell. Focus leaves
    // again as the replay's reply goes out, before the held key reaches the shell.
    peer.drop()
    #expect(try await session.actor.nextEvent() == .reconnecting)
    try await session.actor.setFocused(true)
    try await session.actor.send(.text("x"))
    peer.resumeNextAttachment = true
    #expect(try await session.actor.nextEvent() == .ready(resumed: true))
    focusDuringReply.withLock { $0 = false }
    try peer.send(report, opcode: .binary)
    #expect(try await session.actor.nextEvent() == .replay)
    try await waitFor("The held key must reach the resumed shell.") { peer.receivedBinary.last == "x" }
    #expect(peer.receivedBinary == ["\u{1b}[O", "\u{1b}[I", "\u{1b}[O", "\u{1b}[I", "\u{1b}[O", "x"])
    withExtendedLifetime(session) {}
}

@MainActor @Test func programsHearEachAppearanceFlipAndTheCurrentAppearanceOnResume() async throws {
    let peer = try ShellTestPeer()
    defer { peer.stop() }
    let deadline = ContinuousClock.now + .seconds(5)
    func waitFor(_ expected: Comment, until condition: () -> Bool) async throws {
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition(), expected)
    }
    try await waitFor("The loopback peer must be listening.") { peer.port != nil }
    let port = try #require(peer.port)
    let session = try TerminalSession(baseURL: try #require(URL(string: "http://127.0.0.1:\(port)")),
                                      clientID: "appearance")
    // Typed input follows any report on the same socket, so it marks where reports would have arrived.
    func expectWrites(_ expected: [String], through marker: String) async throws {
        try await session.actor.send(.text(marker))
        try await waitFor("The shell must receive \(marker).") { peer.receivedBinary.last == marker }
        #expect(peer.receivedBinary == expected + [marker])
    }
    // Resumes a hidden session, or one whose network dropped.
    func resume(replaying replay: String, afterDrop: Bool = false) async throws {
        peer.resumeNextAttachment = true
        if afterDrop {
            peer.drop()
            #expect(try await session.actor.nextEvent() == .reconnecting)
        } else {
            try #require(await session.actor.show())
        }
        #expect(try await session.actor.nextEvent() == .ready(resumed: true))
        try peer.send(replay, opcode: .binary)
        #expect(try await session.actor.nextEvent() == .replay)
    }
    let reports = "\u{1b}[?2031h", dark = "\u{1b}[?997;1n", light = "\u{1b}[?997;2n"
    var warmDark = TerminalTheme.slateDark
    warmDark.palette = .init(foreground: warmDark.palette.foreground, background: .init(red: 0x1c, green: 0x1a, blue: 0x18), ansi: warmDark.palette.ansi)

    // Only a flip between dark and light is reported, not another theme of the same appearance or a
    // background the program set.
    await session.setTheme(.slateDark)
    try #require(await session.actor.show())
    #expect(try await session.actor.nextEvent() == .ready(resumed: false))
    try peer.send(reports + "\u{1b}]11;#ffffff\u{7}", opcode: .binary)
    #expect(try await session.actor.nextEvent() == .output)
    await session.setTheme(warmDark)
    await session.setTheme(.slateLight)
    await session.setTheme(.slateLight)
    await session.setTheme(.slateDark)
    try await expectWrites([light, dark], through: "1")

    // Another attachment may have told the shell otherwise, so a resumed program hears the current
    // appearance once, whether or not it changed while the shell was detached.
    // A drop discards whatever the peer hasn't read yet, so the first resume's report must arrive before it.
    await session.actor.hide()
    await session.setTheme(.slateLight)
    try await resume(replaying: reports)
    try await expectWrites([light, dark, "1", light], through: "2")
    try await resume(replaying: reports, afterDrop: true)
    try await expectWrites([light, dark, "1", light, "2", light], through: "3")

    // A resumed program that hasn't asked hears nothing.
    await session.actor.hide()
    try await resume(replaying: "")
    try await expectWrites([light, dark, "1", light, "2", light, "3"], through: "4")
}
