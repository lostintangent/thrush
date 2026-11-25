import Foundation
import Observation
import Testing
import Thrush

@MainActor private final class ChangeCount {
    private(set) var count = 0

    func observe(_ read: () -> Void) {
        withObservationTracking(read) {
            MainActor.assumeIsolated { self.count += 1 }
        }
    }
}

@MainActor @Test func observingShellMetadataAcrossAttachments() async throws {
    let peer = try ShellTestPeer()
    defer { peer.stop() }
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while peer.port == nil {
        try #require(ContinuousClock.now < deadline, "The loopback peer did not start.")
        try await Task.sleep(for: .milliseconds(10))
    }
    let port = try #require(peer.port)
    let url = try #require(URL(string: "ws://127.0.0.1:\(port)/socket"))
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let shell = TerminalShell(clientID: "observable-shell") { _, _ in session.webSocketTask(with: url) }
    let titleChanges = ChangeCount()
    let exitChanges = ChangeCount()
    titleChanges.observe { _ = shell.title }
    exitChanges.observe { _ = shell.hasExited }

    func attach(resumed: Bool, userInitiated: Bool = false) async throws {
        peer.resumeNextAttachment = resumed
        try #require(await shell.connection.attach(userInitiated: userInitiated))
        let event = try await shell.connection.nextEvent()
        try #require(event == .ready(resumed: resumed))
    }
    func output(_ text: String) async throws {
        try peer.send(text, opcode: .binary)
        #expect(try await shell.connection.nextEvent() == .output)
    }

    #expect(shell.title.isEmpty && !shell.hasExited)
    try await attach(resumed: false)
    try await output("ordinary output")
    #expect(titleChanges.count == 0 && exitChanges.count == 0)
    try await output("\u{1b}]2;Shell title\u{7}")
    #expect(shell.title == "Shell title" && titleChanges.count == 1)

    titleChanges.observe { _ = shell.title }
    try await output("\u{1b}]2;Shell title\u{7}more output")
    await shell.connection.detach()
    try await attach(resumed: true)
    #expect(shell.title == "Shell title" && titleChanges.count == 1)
    try await output("\u{1b}]2;Shell title\u{7}restored output")
    #expect(titleChanges.count == 1)

    // An empty replay supersedes the retained title, even without a title sequence.
    await shell.connection.detach()
    try await attach(resumed: true)
    try await output("")
    #expect(shell.title.isEmpty && titleChanges.count == 2)
    try await output("\u{1b}]2;Another shell\u{7}")
    titleChanges.observe { _ = shell.title }
    try peer.send(#"{"type":"ready","resumed":true}"#, opcode: .text)
    try peer.send("\u{1b}]2;\u{7}restored output", opcode: .binary)
    #expect(try await shell.connection.nextEvent() == .resynchronized)
    #expect(shell.title.isEmpty && titleChanges.count == 3 && exitChanges.count == 0)

    try await output("\u{1b}]2;Finished\u{7}")
    try peer.send(#"{"type":"exit"}"#, opcode: .text)
    #expect(try await shell.connection.nextEvent() == .exit)
    #expect(shell.title == "Finished" && shell.hasExited && exitChanges.count == 1)
    exitChanges.observe { _ = shell.hasExited }
    try await attach(resumed: false, userInitiated: true)
    #expect(shell.title.isEmpty && !shell.hasExited && exitChanges.count == 2)

    exitChanges.observe { _ = shell.hasExited }
    try await shell.close()
    #expect(shell.hasExited && exitChanges.count == 3)
}
