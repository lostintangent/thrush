import Testing
import ThrushCore
import ThrushFixtures

enum Delivery: String, CaseIterable, Sendable { case recorded, whole, singleByte }

@Test(arguments: Recording.names, Delivery.allCases)
func recordingPlaysBack(named name: String, delivery: Delivery) throws {
    let fixture = try Recording.load(named: name)
    try verifyRecording(fixture, delivery: delivery)
}

@Test(arguments: Delivery.allCases)
func handsetVimResumeRecording(delivery: Delivery) throws {
    // The handset reference is copied to the bundle root. The desktop fixture has the same name.
    let fixture = try Recording.load(named: "vim-resume", subdirectory: nil)
    try #require(fixture.columns == 45 && fixture.rows == 18)
    try verifyRecording(fixture, delivery: delivery)
}

private func verifyRecording(_ fixture: Recording, delivery: Delivery) throws {
    var terminal = Terminal(size: .init(columns: fixture.columns, rows: fixture.rows))
    var pending: [UInt8] = []
    var expectedReplies: [UInt8] = []

    func drain() {
        let reply = terminal.write(pending)
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
            let reply = terminal.write(event.bytes)
            #expect(reply == event.reply, "\(event.name)")
        case .singleByte:
            var reply: [UInt8] = []
            for byte in event.bytes { reply += terminal.write(CollectionOfOne(byte)) }
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
