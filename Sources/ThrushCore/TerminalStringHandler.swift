/// Reads a supported string command’s payload as it arrives and commits its effect at the terminator.
/// A cancelled or overlong command has no effect.
struct TerminalStringHandler: Sendable {
    // The limit is measured in UTF-16 code units. An overlong command has no effect.
    private static let payloadLimit = 10_000_000
    private var remainingCodeUnits = 0
    private(set) var command: TerminalControlFunction.OSC?
    /// The payload so far, or nil when the command is unsupported, overlong or finished.
    private(set) var payload: String?

    mutating func start(_ command: TerminalControlFunction.OSC?) {
        self.command = command
        payload = command == nil ? nil : ""
        remainingCodeUnits = Self.payloadLimit
    }

    var isCollecting: Bool { payload != nil }

    // Printable ASCII contributes exactly one UTF-16 code unit per byte.
    mutating func appendASCII(_ bytes: Span<UInt8>) {
        remainingCodeUnits -= bytes.count
        if remainingCodeUnits < 0 {
            payload = nil
        } else {
            bytes.withUnsafeBufferPointer { payload?.append(String(decoding: $0, as: UTF8.self)) }
        }
    }

    mutating func put(_ scalar: Unicode.Scalar) {
        guard payload != nil else { return }
        remainingCodeUnits -= scalar.value > 0xffff ? 2 : 1
        if remainingCodeUnits < 0 {
            payload = nil
        } else {
            payload?.unicodeScalars.append(scalar)
        }
    }

    /// The completed command and its payload, or nil when it was unsupported, overlong or cancelled.
    mutating func finish(success: Bool) -> (command: TerminalControlFunction.OSC, payload: String)? {
        defer { start(nil) }
        guard success, let command, let payload else { return nil }
        return (command, payload)
    }
}
