/// A control string's text, kept as the UTF-8 that arrived. A string Thrush doesn't perform keeps
/// none, and one longer than 10M UTF-16 code units has no effect.
struct Payload: Sendable {
    private static let limit = 10_000_000
    /// The text so far.
    private(set) var bytes: [UInt8] = []
    /// Whether the string is one Thrush performs and its text is still within the limit.
    private(set) var isKept = false
    private var remainingCodeUnits = 0

    /// The text, for the functions that read it as a string.
    var text: String { String(decoding: bytes, as: UTF8.self) }

    mutating func start(keeping: Bool) {
        // A large payload's storage goes back, and a small one's is reused.
        bytes.removeAll(keepingCapacity: bytes.capacity <= 4096)
        isKept = keeping
        remainingCodeUnits = Self.limit
    }

    /// Appends a run of printable ASCII, each byte one UTF-16 code unit.
    mutating func append(_ run: Span<UInt8>) {
        guard isKept else { return }
        remainingCodeUnits -= run.count
        guard remainingCodeUnits >= 0 else { return drop() }
        run.withUnsafeBufferPointer { bytes.append(contentsOf: $0) }
    }

    /// Appends one scalar.
    mutating func append(_ code: UInt32) {
        guard isKept, let scalar = Unicode.Scalar(code) else { return }
        remainingCodeUnits -= scalar.utf16.count
        guard remainingCodeUnits >= 0 else { return drop() }
        bytes.append(contentsOf: scalar.utf8)
    }

    private mutating func drop() {
        isKept = false
        bytes = []
    }
}
