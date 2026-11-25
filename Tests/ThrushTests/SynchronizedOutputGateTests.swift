import Testing
import ThrushCore
@testable import Thrush

/// A canceled callback can still be delivered to exercise queued main-actor work racing a reset.
@MainActor
private final class GateClock {
    private(set) var now = ContinuousClock.now
    private(set) var deadlines: [ContinuousClock.Instant] = []
    private(set) var canceled: Set<Int> = []
    private var callbacks: [@MainActor () -> Void] = []

    func advance(_ duration: Duration) { now = now.advanced(by: duration) }

    func schedule(_ deadline: ContinuousClock.Instant, _ callback: @escaping @MainActor () -> Void) -> (@MainActor () -> Void) {
        let index = callbacks.count
        deadlines.append(deadline)
        callbacks.append(callback)
        return { self.canceled.insert(index) }
    }

    func fire(_ index: Int) { callbacks[index]() }
}

@MainActor
private final class GateProbe {
    struct Output: Equatable {
        var text: String
        var receivedAt: Double?
    }
    let clock = GateClock()
    private(set) var outputs: [Output] = []
    private var terminal = Terminal(size: .init(columns: 12, rows: 2))
    lazy var gate = SynchronizedOutputGate(now: { [clock] in clock.now }, schedule: clock.schedule) { [weak self] snapshot, receipt in
        self?.outputs.append(.init(text: snapshot.rows[0].text, receivedAt: receipt))
    }

    func send(_ text: String, _ receipt: Double?, _ group: UInt64?) {
        _ = terminal.receive(("\u{1b}[1;1H\u{1b}[K" + text).utf8)
        gate.submit(terminal.snapshot(), receivedAt: receipt, synchronizedOutputID: group)
    }
}

@MainActor
@Test func endOfSynchronizedOutputReleasesTheClosingSnapshot() {
    let p = GateProbe()
    p.send("ready", 0, nil)
    p.send("half", 1, 7)
    p.clock.advance(.milliseconds(700))
    p.send("newer", 2, 7)
    #expect(p.outputs == [.init(text: "ready", receivedAt: 0)])
    #expect(p.clock.deadlines.count == 1)
    p.send("complete", 3, nil)
    #expect(p.clock.canceled == [0])
    p.clock.advance(.seconds(1))
    p.clock.fire(0)
    #expect(p.outputs == [.init(text: "ready", receivedAt: 0), .init(text: "complete", receivedAt: 3)])
}

@MainActor
@Test func watchdogUsesTheFirstDeadlineAndPassesLaterUpdatesInThatGroup() {
    let p = GateProbe()
    let start = p.clock.now
    p.send("first", 1, 16)
    p.clock.advance(.milliseconds(999))
    p.send("second", 2, 17) // Repeated DECSET issues a fresh ID during the same hold.
    #expect(p.clock.deadlines == [start.advanced(by: .seconds(1))])
    #expect(p.outputs.isEmpty)
    p.clock.advance(.milliseconds(1))
    p.clock.fire(0)
    #expect(p.outputs == [.init(text: "second", receivedAt: 2)])
    p.send("third", 3, 17)
    #expect(p.outputs.last == .init(text: "third", receivedAt: 3))
    #expect(p.clock.deadlines.count == 1)
    p.send("new group", 4, 18)
    #expect(p.outputs.count == 2)
    #expect(p.clock.deadlines == [start.advanced(by: .seconds(1)), start.advanced(by: .seconds(2))])
}

@MainActor
@Test func staleAlarmCannotPublishAfterReplacementEvenWithAReusedID() {
    let p = GateProbe()
    p.send("a", 1, 4)
    p.clock.advance(.milliseconds(600))
    p.send("b", 2, 5)
    #expect(p.outputs.isEmpty && p.clock.deadlines.count == 1)
    p.gate.reset()
    p.send("c", 3, 5)
    #expect(p.clock.canceled == [0])
    p.clock.advance(.milliseconds(401))
    p.clock.fire(0)
    #expect(p.outputs.isEmpty)
    p.clock.advance(.milliseconds(599))
    p.clock.fire(1)
    #expect(p.outputs == [.init(text: "c", receivedAt: 3)])
}

@MainActor
@Test func suspendedGateRetainsTheCompletedAndLatestHeldFrames() {
    let p = GateProbe()
    p.gate.setActive(false)
    p.send("complete", nil, nil)
    p.send("partial", 1, 30)
    p.clock.advance(.milliseconds(300))
    #expect(p.clock.deadlines.isEmpty && p.outputs.isEmpty)
    p.gate.setActive(true)
    #expect(p.outputs == [.init(text: "complete", receivedAt: nil)])
    #expect(p.clock.deadlines == [p.clock.now.advanced(by: .milliseconds(700))])
    p.gate.setActive(false)
    #expect(p.clock.canceled == [0])
    p.clock.advance(.milliseconds(800))
    p.clock.fire(0)
    #expect(p.outputs.count == 1)
    p.send("latest", 2, 30)
    #expect(p.outputs.count == 1)
    p.gate.setActive(true)
    #expect(p.outputs.last == .init(text: "latest", receivedAt: 2))
    #expect(p.clock.deadlines.count == 1)
}

@MainActor
@Test func overdueUpdateWinsTheRaceWithItsScheduledCallback() {
    let p = GateProbe()
    p.send("held", 1, 20)
    p.clock.advance(.seconds(2))
    p.send("latest", 2, 20)
    p.clock.fire(0)
    #expect(p.outputs == [.init(text: "latest", receivedAt: 2)])
    #expect(p.clock.canceled == [0])
}

@MainActor
@Test func overdueHoldClosesBeforeRepeatedDECSETStartsANewInterval() {
    let p = GateProbe()
    p.send("previous", 1, 20)
    p.clock.advance(.milliseconds(1_001))
    // The old alarm is already due, but the socket update gets the actor first.
    p.send("next", 2, 21)
    #expect(p.outputs == [.init(text: "previous", receivedAt: 1)])
    #expect(p.clock.canceled == [0])
    #expect(p.clock.deadlines.count == 2)
    #expect(p.clock.deadlines.last == p.clock.now.advanced(by: .seconds(1)))
    p.clock.fire(0)
    #expect(p.outputs.count == 1)
    p.clock.advance(.seconds(1))
    p.clock.fire(1)
    #expect(p.outputs.last == .init(text: "next", receivedAt: 2))
}
