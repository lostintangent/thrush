import Foundation
import Thrush

/// One socket receives live bytes, repairs its screen in-band during silence, then accepts a live echo.
enum SilentRecoveryCheck {
    struct Result: Encodable {
        let reader = "silent"
        let setupBytes: Int
        let receivedBytes: Int
        let appliedBytes: Int
        let liveNumberedBytes: Int
        let replayBytes: Int
        let restoredLastMarker: Int
        let matchingRows: Int
        let liveEchoReceived: Bool
    }

    static func run(_ connection: TerminalConnection, id: String, directory: URL, setupBytes: Int) async throws {
        // The harness stops the entire process before allowing the producer to write its burst.
        let gate = directory.appending(path: "send-gap-input")
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while !FileManager.default.fileExists(atPath: gate.path) {
            guard ContinuousClock.now < deadline else { throw PTYCheckFailure("Gap-input gate timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
        // Send before reading any backlog. The PTY records this input to disk without producing output.
        try await connection.send(.text("gap-\(id)\r"))
        let receipt = directory.appending(path: "gap-input-received")
        let receiptDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !FileManager.default.fileExists(atPath: receipt.path) {
            guard ContinuousClock.now < receiptDeadline else { throw PTYCheckFailure("Silent producer did not acknowledge gap input") }
            try await Task.sleep(for: .milliseconds(10))
        }
        var liveBytes = 0
        while true {
            let before = await connection.receivedBytes
            switch try await connection.nextEvent() {
            case .output:
                liveBytes += await connection.receivedBytes - before
            case .resynchronized:
                let replayBytes = await connection.receivedBytes - before
                let expected = (131050...131072).map {
                    "THRUSH \($0) " + String(repeating: ".", count: 48)
                } + [""]
                guard await connection.state == .active,
                      await connection.snapshot().rows.map(\.text) == expected,
                      liveBytes < 8 * 1048576, replayBytes > 0 else {
                    throw PTYCheckFailure("Silent in-band repair did not restore the expected 24 rows after loss")
                }
                try await connection.send(.text("live-\(id)\r"))
                var echo = false
                echoLoop: while true {
                    switch try await connection.nextEvent() {
                    case .output:
                        if await connection.snapshot().rows.contains(where: { $0.text == "ECHO-live-\(id)" }) { echo = true }
                    case .exit: break echoLoop
                    default: throw PTYCheckFailure("Unexpected transition while waiting for live echo")
                    }
                }
                guard echo, await connection.state == .ended else { throw PTYCheckFailure("Missing live echo before exit") }
                let result = Result(setupBytes: setupBytes, receivedBytes: await connection.receivedBytes - setupBytes,
                                    appliedBytes: await connection.appliedBytes - setupBytes,
                                    liveNumberedBytes: liveBytes, replayBytes: replayBytes, restoredLastMarker: 131072,
                                    matchingRows: expected.count, liveEchoReceived: echo)
                try JSONEncoder().encode(result).write(to: directory.appending(path: "client.json"))
                return
            default: throw PTYCheckFailure("Expected an in-band repair on the original ready socket")
            }
        }
    }
}
