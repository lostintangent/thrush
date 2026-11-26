// Maps a parser state and an input byte to a next state and a framing operation.
// The state diagram by Paul Williams describes DEC parser transitions.
// https://vt100.net/emu/dec_ansi_parser

extension EscapeParser {
    enum State: UInt8, CaseIterable {
        case ground, escape, escapeIntermediate
        case csiEntry, csiParameters, csiIntermediate, csiIgnore
        case dcsEntry, dcsParameters, dcsIntermediate, dcsIgnore
        case oscIdentifier, oscPayload, invalidOSC, dcsPayload, ignoredString
        case discardedOSC, discardedDCS
    }

    enum Operation: UInt8 {
        case ignore, print, execute, beginEscape, beginHeader, collect, parameter
        case escapeFinal, controlFinal, startDCS
        case beginOSC, oscDigit, startOSC, put
        case finish, cancel, finishEmptyOSC, cancelEmptyOSC
        case cancelAndExecute, cancelAndBeginHeader, cancelAndBeginOSC
    }

    struct Transition {
        let nextState: State
        let operation: Operation

        init(_ next: State, _ operation: Operation = .ignore) {
            nextState = next
            self.operation = operation
        }
    }

    static func transition(from state: State, scalar: UInt32) -> Transition {
        transitions[Int(state.rawValue) << 8 | Int(min(scalar, 0xA0))]
    }

    // Each state occupies one 256-entry row. Slot A0 stands for every Unicode scalar
    // beyond the C1 range. The two-byte entry gives both the next state and its operation.
    static let transitions: InlineArray<4608, Transition> = {
        var table = InlineArray<4608, Transition>(repeating: Transition(.ground))
        precondition(table.count == State.allCases.count * 256)
        for state in State.allCases {
            let row = Int(state.rawValue) << 8
            func set(_ byte: Int, _ next: State, _ operation: Operation = .ignore) {
                table[row + byte] = Transition(next, operation)
            }
            func set(_ bytes: ClosedRange<Int>, _ next: State, _ operation: Operation = .ignore) {
                for byte in bytes { set(byte, next, operation) }
            }

            switch state {
            case .ground:
                set(0...0x1F, .ground, .execute)
                set(0x20...0x7E, .ground, .print)
                set(0xA0, .ground, .print)
            case .escape, .escapeIntermediate:
                set(0...0x1F, state, .execute)
                set(0x20...0x2F, .escapeIntermediate, .collect)
                set(0x30...0x7E, .ground, .escapeFinal)
                set(0x7F, state)
                if state == .escape {
                    set(0x50, .dcsEntry, .beginHeader)
                    set(0x5B, .csiEntry, .beginHeader)
                    set(0x5D, .oscIdentifier, .beginOSC)
                    for byte in [0x58, 0x5E, 0x5F] { set(byte, .ignoredString) }
                }
            case .csiEntry, .csiParameters, .csiIntermediate, .dcsEntry, .dcsParameters, .dcsIntermediate:
                let dcs = state == .dcsEntry || state == .dcsParameters || state == .dcsIntermediate
                let parameters: State = dcs ? .dcsParameters : .csiParameters
                let intermediate: State = dcs ? .dcsIntermediate : .csiIntermediate
                let ignoring: State = dcs ? .dcsIgnore : .csiIgnore
                set(0...0x1F, state, dcs ? .ignore : .execute)
                set(0x20...0x2F, intermediate, .collect)
                set(0x30...0x3F, ignoring)
                if state != intermediate { set(0x30...0x3B, parameters, .parameter) }
                if state == .csiEntry || state == .dcsEntry { set(0x3C...0x3F, parameters, .collect) }
                set(0x40...0x7E, dcs ? .dcsPayload : .ground, dcs ? .startDCS : .controlFinal)
                set(0x7F, state)
            case .csiIgnore:
                set(0...0x1F, state, .execute)
                set(0x20...0x3F, state)
                set(0x7F, state)
                set(0xA0, state)
            case .dcsIgnore:
                set(0...0xA0, state)
            case .oscIdentifier:
                set(0...0x1F, state)
                set(0x20...0xA0, .invalidOSC)
                set(0x30...0x39, state, .oscDigit)
                set(0x3B, .oscPayload, .startOSC)
            case .oscPayload, .discardedOSC:
                set(0...0x1F, state)
                set(0x20...0xA0, state, state == .oscPayload ? .put : .ignore)
            case .invalidOSC:
                set(0...0xA0, state)
            case .dcsPayload, .discardedDCS:
                set(0...0xA0, state, state == .dcsPayload ? .put : .ignore)
                set(0x7F, state)
            case .ignoredString:
                set(0...0x7F, state)
            }

            // C1 introducers can replace a string before its terminator.
            let streaming = state == .oscPayload || state == .dcsPayload
            set(0x80...0x9F, .ground, streaming ? .cancelAndExecute : .execute)
            set(0x90, .dcsEntry, streaming ? .cancelAndBeginHeader : .beginHeader)
            set(0x9B, .csiEntry, streaming ? .cancelAndBeginHeader : .beginHeader)
            set(0x9D, .oscIdentifier, streaming ? .cancelAndBeginOSC : .beginOSC)
            for byte in [0x98, 0x9E, 0x9F] { set(byte, .ignoredString, streaming ? .cancel : .ignore) }

            let finish: Operation
            let cancel: Operation
            switch state {
            case .oscIdentifier: (finish, cancel) = (.finishEmptyOSC, .cancelEmptyOSC)
            case .invalidOSC, .discardedOSC, .discardedDCS: (finish, cancel) = (.ignore, .ignore)
            default: (finish, cancel) = streaming ? (.finish, .cancel) : (.ignore, .execute)
            }
            set(0x9C, .ground, finish) // ST
            set(0x1B, .escape, finish == .ignore ? .beginEscape : finish)
            if state == .oscIdentifier || state == .oscPayload || state == .discardedOSC || state == .invalidOSC {
                set(0x07, .ground, finish) // BEL terminates only OSC.
            }
            set(0x18, .ground, cancel) // CAN
            set(0x1A, .ground, cancel) // SUB
        }
        return table
    }()
}
