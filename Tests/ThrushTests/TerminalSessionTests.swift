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
    let read = try #require(session?.readUpdate)
    try #require(await actor.show())

    var ready = false
    let handshake = Task {
        if case .fresh = try await read() { ready = true }
    }
    defer { handshake.cancel() }
    try await waitFor("The session must receive ready.") { ready }

    // The second read proves the first one reached the quiet socket before the app releases it.
    var pendingRead = false
    var interrupted = false
    let readers = (0..<2).map { _ in
        Task {
            do {
                _ = try await read()
                Issue.record("The quiet socket delivered an unexpected update.")
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

@MainActor @Test func resumedReplayReportsTheCurrentFocusBeforeHeldKeys() async throws {
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
    let session = TerminalSession { _ in sockets.webSocketTask(with: endpoint) }
    let actor = session.actor
    let report = "\u{1b}[?1004h"

    // A program that asks hears the current focus at once, then each change.
    try #require(await actor.show())
    #expect(try await actor.nextEvent() == .ready(resumed: false))
    try peer.send(report, opcode: .binary)
    #expect(try await actor.nextEvent() == .output)
    try await actor.setFocused(true)
    try await actor.setFocused(true)
    try await actor.setFocused(false)
    try await waitFor("The program must hear each focus change once.") { peer.receivedBinary.count == 3 }

    // Focus returns while the network is down, and a key waits for the resumed shell.
    peer.drop()
    #expect(try await actor.nextEvent() == .reconnecting)
    try await actor.setFocused(true)
    try await actor.send(.text("x"))
    peer.resumeNextAttachment = true
    #expect(try await actor.nextEvent() == .ready(resumed: true))
    try peer.send(report, opcode: .binary)
    #expect(try await actor.nextEvent() == .replay)
    try await waitFor("The resumed shell must hear focus, then the held key.") { peer.receivedBinary.count == 5 }
    #expect(peer.receivedBinary == ["\u{1b}[O", "\u{1b}[I", "\u{1b}[O", "\u{1b}[I", "x"])
    withExtendedLifetime(session) {}
}
