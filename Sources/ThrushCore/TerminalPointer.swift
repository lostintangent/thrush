// Encodes pointer events for programs that request mouse tracking. The active tracking
// mode selects which events to send, and the coordinate format determines their encoding.

extension Terminal {
    package enum MouseTracking: Sendable { case off, press, drag, all }
}

extension Terminal.Input {
    /// A native pointer event in zero-based cell coordinates on the live grid.
    package struct Pointer: Equatable, Sendable {
        /// The phase of the pointer event.
        package enum Action: Sendable {
            /// A button press or a single scroll-wheel step.
            case press
            /// A button release.
            case release
            /// Pointer movement, including a drag with a held button.
            case move
        }

        /// The button or scroll-wheel direction associated with a pointer event.
        package enum Button: Sendable {
            /// The left mouse button.
            case left
            /// The middle mouse button.
            case middle
            /// The right mouse button.
            case right
            /// Movement with no button held.
            case none
            /// An upward scroll-wheel step, reported as a press.
            case wheelUp
            /// A downward scroll-wheel step, reported as a press.
            case wheelDown
        }

        /// The phase of this event.
        package let action: Action
        /// The button involved, or the wheel direction for a scroll.
        package let button: Button
        /// The cell's row, counting downward from zero at the top of the visible grid.
        package let row: Int
        /// The cell's column, counting rightward from zero at the left edge of the grid.
        package let column: Int
        /// The terminal keyboard modifiers held during this event.
        package let modifiers: Modifiers

        /// Creates a pointer event at the given visible cell. Encoding an event outside the grid returns no bytes.
        package init(_ action: Action, button: Button, row: Int, column: Int, modifiers: Modifiers = []) {
            self.action = action
            self.button = button
            self.row = row
            self.column = column
            self.modifiers = modifiers
        }
    }
}

extension Terminal {
    func encodePointer(_ event: Input.Pointer) -> [UInt8] {
        guard modes.mouseTracking != .off, (0..<size.rows).contains(event.row),
              (0..<size.columns).contains(event.column) else { return [] }
        if event.action == .move {
            guard modes.mouseTracking == .all || (modes.mouseTracking == .drag && event.button != .none) else { return [] }
        } else if event.button == .none {
            return []
        }
        var code: UInt8
        switch event.button {
        case .left: code = 0
        case .middle: code = 1
        case .right: code = 2
        case .none: code = 3
        case .wheelUp, .wheelDown:
            guard event.action == .press else { return [] }
            code = event.button == .wheelUp ? 64 : 65
        }
        if event.action == .release, !modes.mouseSGR { code = 3 }
        if event.action == .move { code |= 32 }
        if event.modifiers.contains(.shift) { code |= 4 }
        if event.modifiers.contains(.alt) { code |= 8 }
        if event.modifiers.contains(.control) { code |= 16 }

        let x = event.column + 1, y = event.row + 1
        if modes.mouseSGR {
            let final = event.action == .release ? "m" : "M"
            return Array("\u{1b}[<\(code);\(x);\(y)\(final)".utf8)
        }
        guard x <= 223, y <= 223 else { return [] }
        return [0x1b, 0x5b, 0x4d, code + 32, UInt8(x) + 32, UInt8(y) + 32]
    }
}
