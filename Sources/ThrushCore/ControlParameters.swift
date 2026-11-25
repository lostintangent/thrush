/// Collects up to 32 parameters and 32 colon-separated subparameters in fixed storage.
/// Dispatch reads them in place. Copying them with each parser action made control-heavy
/// output about 12 times slower.
struct ControlParameters: Sendable {
    private typealias Fields = InlineArray<32, Int32>
    /// Applies separately to the main parameters and to the colon components across the header.
    static var limit: Int { Fields.count }

    private var main = Fields(repeating: 0)
    private var subparameters = Fields(repeating: 0)
    private var subparameterStarts: InlineArray<32, UInt8> = .init(repeating: 0)
    private(set) var count = 1
    private var totalSubparameters = 0

    enum Destination { case main, subparameter, discardSubparameters, discardRemainder }
    private(set) var destination: Destination = .main

    subscript(_ index: Int) -> Int { self[index, default: 0] }

    /// Both omitted and zero main parameters select the control function's default.
    subscript(_ index: Int, default fallback: Int) -> Int {
        guard (0..<count).contains(index), main[index] != 0 else { return fallback }
        return Int(main[index])
    }

    func subparameterCount(at index: Int) -> Int {
        guard (0..<count).contains(index) else { return 0 }
        let end = index + 1 == count ? totalSubparameters : Int(subparameterStarts[index + 1])
        return end - Int(subparameterStarts[index])
    }

    /// An omitted colon subparameter is nil. A literal zero remains zero.
    subscript(parameter index: Int, subparameter ordinal: Int) -> Int? {
        guard (0..<subparameterCount(at: index)).contains(ordinal) else { return nil }
        let value = subparameters[Int(subparameterStarts[index]) + ordinal]
        return value < 0 ? nil : Int(value)
    }

    mutating func reset() {
        count = 1
        main[0] = 0
        totalSubparameters = 0
        subparameterStarts[0] = 0
        destination = .main
    }

    /// Accepts the parameter bytes 0x30–0x3B after the framer has consumed any prefix.
    @inline(__always)
    mutating func append(_ byte: UInt8) {
        guard destination != .discardRemainder else { return }
        switch byte {
        case 0x3B: // ;
            guard count < main.count else { destination = .discardRemainder; return }
            main[count] = 0
            subparameterStarts[count] = UInt8(totalSubparameters)
            count += 1
            destination = .main
        case 0x3A: // :
            guard totalSubparameters < subparameters.count else { destination = .discardSubparameters; return }
            subparameters[totalSubparameters] = -1
            totalSubparameters += 1
            destination = .subparameter
        default:
            // A stored field fits in Int32, so the next digit can't overflow an Int before clamping.
            let digit = Int(byte &- 0x30)
            switch destination {
            case .main:
                let index = count - 1
                main[index] = Int32(clamping: Int(main[index]) &* 10 &+ digit)
            case .subparameter:
                let index = totalSubparameters - 1
                subparameters[index] = Int32(clamping: max(0, Int(subparameters[index])) &* 10 &+ digit)
            case .discardSubparameters, .discardRemainder:
                break
            }
        }
    }
}
