#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Testing
import ThrushCore
@testable import Thrush

@MainActor @Test func outputArrivingDuringDrawSupersedesTheFirstInvalidation() throws {
    let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 140))
    #if os(macOS)
    let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = view
    #else
    let window = UIWindow(frame: view.frame)
    window.addSubview(view)
    #endif
    defer { view.removeFromSuperview() }
    view.setDrawingVisible(false)
    view.setDrawingVisible(true)
    let mailbox = OutputMailbox()
    var terminal = Terminal(size: .init(columns: 16, rows: 2))
    _ = terminal.receive("old\r\n~ # clear".utf8)

    // The first Oshen Return message wakes the pane. It can invalidate the view immediately.
    _ = terminal.receive("\r\u{1b}[2K\u{1b}[32m~\u{1b}[0m # ".utf8)
    #expect(mailbox.offer(terminal.snapshot(), receivedAt: 1))
    let first = try #require(mailbox.take(notification: true))
    #expect(first.screen.rows.last?.text == "~ # " && first.receipt == 1)
    #expect(view.displayOutput(first) == 1)

    // These two reads can complete while the main actor is obtaining its drawable.
    _ = terminal.receive("\u{1b}[32mclear\u{1b}[0m".utf8)
    #expect(mailbox.offer(terminal.snapshot(), receivedAt: 1.000026))
    _ = terminal.receive("\r\n".utf8)
    #expect(!mailbox.offer(terminal.snapshot(), receivedAt: 1.000033))
    let encode = try #require(mailbox.take())
    #expect(encode.screen.rows.map(\.text) == ["~ # clear", ""])
    #expect(encode.receipt == 1.000026)
    #expect(view.displayOutput(encode) == 1)
    #expect(view.snapshot?.generation == encode.screen.generation)

    // Drawing takes the latest frame without queuing a second wakeup.
    _ = terminal.receive("X".utf8)
    #expect(!mailbox.offer(terminal.snapshot(), receivedAt: 2))
    #expect(mailbox.take(notification: true)?.screen.rows.last?.text == "X")
    #expect(mailbox.take() == nil)
}

@MainActor @Test func replayAndSynchronizedOutputWaitForEarlierShellMessages() async throws {
    let peer = try ShellTestPeer()
    defer { peer.stop() }
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while peer.port == nil {
        try #require(ContinuousClock.now < deadline)
        try await Task.sleep(for: .milliseconds(10))
    }
    let port = try #require(peer.port)
    let url = try #require(URL(string: "http://127.0.0.1:\(port)"))
    let actor = try SessionActor(baseURL: url, clientID: "ordered-output", size: .init(columns: 12, rows: 2))
    guard case .ready(resumed: false) = try await actor.nextEvent() else {
        Issue.record("Expected a fresh shell")
        return
    }
    for bytes in ["A", "\u{1b}[?2026hB", "C", "\u{1b}[?2026lD", "e"] {
        try peer.send(bytes, opcode: .binary)
    }
    try peer.send(#"{"type":"ready","resumed":true}"#, opcode: .text)
    for bytes in ["\u{1b}[?2026hR", "\u{1b}[?2026lS", "T"] { try peer.send(bytes, opcode: .binary) }
    try peer.send(#"{"type":"exit"}"#, opcode: .text)

    let mailbox = OutputMailbox()
    var seen: [String] = []
    // Leave ordinary frames for the next barrier, as if the pane were still preparing its drawable.
    try await actor.readUpdates(into: mailbox, notify: {}) { update in
        if let earlier = mailbox.take() { seen.append("pending " + earlier.screen.rows[0].text) }
        switch update {
        case .output(let screen, _):
            #expect(await actor.snapshot().generation == screen.generation)
            let state = screen.synchronizedOutputID == nil ? "released " : "synchronized "
            seen.append(state + screen.rows[0].text)
        case .replay(let screen, _): seen.append("replay " + screen.rows[0].text)
        case .ended(let screen, _):
            seen.append("exit " + screen.rows[0].text)
            return false
        default:
            Issue.record("Unexpected session transition")
            return false
        }
        return true
    }
    #expect(seen == ["pending A", "synchronized AB", "synchronized ABC", "released ABCD",
                     "pending ABCDe", "replay R", "released RS", "pending RST", "exit RST"])
}
