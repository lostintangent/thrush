#if os(macOS)
import AppKit
import QuartzCore
import Synchronization
import Testing
import ThrushCore
@testable import Thrush

@MainActor private final class Publications {
    let view = TerminalView(frame: CGRect(x: 0,y: 0,width: 720,height: 486))
    let window = NSWindow(contentRect: CGRect(x: 0,y: 0,width: 720,height: 486),styleMask: [.borderless],backing: .buffered,defer: false)
    var frames: [(gen: UInt64, receipt: Double, accepted: Double)] = []
    var draws: [(gen: UInt64, cutoff: Double, submitted: Double)] = []
    var cutoff = 0.0
    var visible: [UInt64: Double] = [:]
    var legacy = false
    init() {
        window.contentView = view
        view.onFrameSubmitted = { [weak self] time, _, _ in
            if let self, let frame = view.snapshot { draws.append((frame.generation,cutoff,time)) }
        }
        view.onFrame = { [weak self] frame in
            if let time = frame.presentedTime, time > 0 { self?.visible[frame.generation] = time }
        }
        view.setDrawingVisible(false)
        view.setDrawingVisible(true)
    }
    func accept(_ frame: OutputMailbox.Frame) {
        if legacy { view.display(frame.screen, receivedAt: frame.receipt) }
        else { _ = view.displayOutput(frame) }
        precondition(view.snapshot?.generation == frame.screen.generation)
        frames.append((frame.screen.generation, frame.receipt!, CACurrentMediaTime()))
    }
}

private extension SessionActor {
    // Same isolated operation used by the serial main-actor reader before this change.
    func legacyRead() async throws -> OutputMailbox.Frame? {
        guard case .output = try await nextEvent() else { return nil }
        return .init(screen: snapshot(), receipt: lastReceiptTime)
    }
}

@MainActor @Test func measuredRealProducerMailbox() async throws {
    guard let origin = ProcessInfo.processInfo.environment["THRUSH_DRAIN_URL"], let url=URL(string:origin) else { return }
    for policy in ["serial","drain","drain","serial"] {
        let reads = Mutex<[Double]>([])
        let session = try TerminalSession(baseURL:url,clientID:UUID().uuidString,size:.init(columns:80,rows:24),onOutput:{ _ in reads.withLock { $0.append(CACurrentMediaTime()) } })
        guard case .ready(resumed: false) = try await session.actor.nextEvent() else { throw CocoaError(.fileReadUnknown) }
        let mailbox=OutputMailbox()
        let pub=Publications()
        pub.legacy = policy == "serial"
        pub.view.beforeOutputDraw = { pub.cutoff = CACurrentMediaTime() }
        let reader:Task<Void,Error>
        if policy == "serial" {
            reader=Task {
                while !Task.isCancelled {
                    guard let frame = try await session.actor.legacyRead() else { return }
                    pub.accept(frame)
                }
            }
        } else {
            pub.view.beforeOutputDraw = {
                pub.cutoff = CACurrentMediaTime()
                if let frame=mailbox.take(){pub.accept(frame)}
            }
            reader=Task {
                try await session.actor.readUpdates(into:mailbox) {
                    if let frame=mailbox.take(notification:true){pub.accept(frame)}
                } deliver:{_ in false}
            }
        }
        var drawnBursts=0,drawnIntermediate=0
        var soloSubmitted:[Double]=[], soloPresented:[Double]=[]
        var split=0, gaps:[Double]=[], intermediate:[Double]=[], latency:[Double]=[]
        for trial in 0..<80 {
            for burst in [true,false] {
                reads.withLock { $0.removeAll(keepingCapacity:true) }
                pub.frames.removeAll(keepingCapacity:true)
                pub.draws.removeAll(keepingCapacity:true)
                pub.visible.removeAll(keepingCapacity:true)
                try await session.actor.send(.text(burst ? "B" : "E"))
                let deadline = CACurrentMediaTime() + 1
                repeat {
                    try await Task.sleep(for:.milliseconds(3))
                    if reads.withLock({$0.count}) == (burst ? 3:1), pub.view.snapshot?.generation == (await session.actor.snapshot()).generation { break }
                    try #require(CACurrentMediaTime() < deadline)
                } while true
                try await Task.sleep(for:.milliseconds(18))
                let seen=reads.withLock{$0}
                let frames=pub.frames
                try #require(!frames.isEmpty)
                if burst {
                    let presented = Set(pub.draws.map(\.gen))
                    if presented.contains(frames.last!.gen) { drawnBursts += 1 }
                    let intermediates = Set(frames.dropLast().map(\.gen))
                    let partial = pub.draws.filter { intermediates.contains($0.gen) }
                    if !partial.isEmpty {
                        drawnIntermediate += 1
                        for draw in partial {
                            let delta = (seen.last! - draw.cutoff) * 1e6
                            print("intermediate policy=\(policy) trial=\(trial) generation=\(draw.gen) final=\(frames.last!.gen) lastAppliedMinusCutoffUs=\(delta) cutoff=\(draw.cutoff) submitted=\(draw.submitted) presented=\(String(describing:pub.visible[draw.gen]))")
                        }
                    }
                    gaps.append((seen.last!-seen[0])*1e6)
                    if frames.count > 1 {split+=1}
                    intermediate.append((frames.last!.accepted-frames[0].accepted)*1e6)
                } else {
                    let echo=frames.last!, receipt=frames[0].receipt
                    latency.append((frames[0].accepted-receipt)*1e6)
                    if let draw=pub.draws.first(where:{$0.gen==echo.gen}) { soloSubmitted.append((draw.submitted-receipt)*1e6) }
                    if let time=pub.visible[echo.gen] { soloPresented.append((time-receipt)*1e6) }
                }
            }
        }
        pub.view.beforeOutputDraw = nil
        pub.window.contentView = nil
        reader.cancel()
        await session.actor.hide()
        _ = await reader.result
        func stats(_ a:[Double])->String { guard !a.isEmpty else { return "unavailable" };let s=a.sorted();return [0.5,0.95,0.99,1.0].map{String(format:"%.1f",s[Int(ceil(Double(s.count)*$0))-1])}.joined(separator:",") }
        print("drain-probe policy=\(policy) trials=80 multiplePublications=\(split) capturedNativeSubmissions=\(drawnBursts) submittedIntermediate=\(drawnIntermediate) arrivalSpanUs=\(stats(gaps)) intermediatePublicationUs=\(stats(intermediate)) loneReceiptToAcceptUs=\(stats(latency)) singletonSubmittedN=\(soloSubmitted.count) singletonReceiptToSubmitUs=\(stats(soloSubmitted)) singletonPresentedN=\(soloPresented.count) singletonReceiptToPresentUs=\(stats(soloPresented))")
    }
}
#endif
