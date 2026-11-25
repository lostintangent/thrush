import Testing
import Thrush
import ThrushFixtures

enum Delivery: String, CaseIterable, Sendable { case recorded, whole, singleByte }

@Test(arguments: ReplayFixture.names, Delivery.allCases)
func milestoneTwoReplay(named name: String, delivery: Delivery) throws {
    let fixture = try ReplayFixture.load(named: name)
    try verifyReplay(fixture, delivery: delivery)
}

@Test(arguments: Delivery.allCases)
func handsetVimResumeReplay(delivery: Delivery) throws {
    // The handset reference is copied to the bundle root. The desktop fixture has the same name.
    let fixture = try ReplayFixture.load(named: "vim-resume", subdirectory: nil)
    try #require(fixture.columns == 47 && fixture.rows == 25)
    try verifyReplay(fixture, delivery: delivery)
}

private func verifyReplay(_ fixture: ReplayFixture, delivery: Delivery) throws {
    var terminal = Terminal(size: .init(columns: fixture.columns, rows: fixture.rows))
    var pending: [UInt8] = []
    var expectedReplies: [UInt8] = []

    func drain() {
        let reply = terminal.receive(pending)
        #expect(reply == expectedReplies)
        pending.removeAll(keepingCapacity: true)
        expectedReplies.removeAll(keepingCapacity: true)
    }

    for event in fixture.events {
        // Host updates and semantic input observe all preceding bytes.
        if delivery == .whole, event.lifecycle != nil || event.palette != nil || event.resize != nil || event.hasSemanticInput { drain() }
        event.applyReady(to: &terminal)
        if let palette = event.palette { terminal.palette = palette }
        if let resize = event.resize {
            let before = terminal.snapshot()
            #expect(before.history.count == event.historyRowsBefore)
            if !before.isAlternate { #expect(before.history.count == event.normalHistoryRowsBefore) }
            terminal.resize(to: .init(columns: resize.columns, rows: resize.rows))
        }
        switch delivery {
        case .recorded:
            let reply = terminal.receive(event.bytes)
            #expect(reply == event.reply, "\(event.name)")
        case .singleByte:
            var reply: [UInt8] = []
            for byte in event.bytes { reply += terminal.receive(CollectionOfOne(byte)) }
            #expect(reply == event.reply, "\(event.name)")
        case .whole:
            pending += event.bytes
            expectedReplies += event.reply
            if event.checkpoint != nil { drain() }
        }
        try event.verify(terminal)
    }
    if delivery == .whole { drain() }
}

@Test func heldSnapshotKeepsRowsAndCursorAcrossEditsAndScroll() {
    var terminal = Terminal(size: .init(columns: 6, rows: 3))
    _ = terminal.receive("first\r\nnext".utf8)
    let first = terminal.snapshot()
    let originalText = first.rows.map(\.text)
    let originalGenerations = first.rows.map(\.generation)
    let originalCursor = (first.cursorRow, first.cursorColumn)

    _ = terminal.receive("\rNEW".utf8)
    let edited = terminal.snapshot()
    #expect(edited.generation > first.generation)
    #expect(edited.rows[0].generation == originalGenerations[0])
    #expect(edited.rows[1].generation != originalGenerations[1])
    #expect(edited.rows[2].generation == originalGenerations[2])

    // One contiguous receive scrolls two rows into history and writes three distinct new rows.
    _ = terminal.receive("\r\nABCDEFGHIJKLMNO".utf8)
    let scrolled = terminal.snapshot()
    #expect(scrolled.generation > edited.generation)
    #expect(scrolled.history.map(\.generation) == Array(edited.rows.prefix(2)).map(\.generation))
    #expect(Set(scrolled.rows.map(\.generation)).count == 3)
    #expect(first.rows.map(\.text) == originalText)
    #expect(first.rows.map(\.generation) == originalGenerations)
    #expect((first.cursorRow, first.cursorColumn) == originalCursor)
    #expect(first.history.isEmpty)
}
