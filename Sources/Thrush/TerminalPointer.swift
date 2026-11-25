extension Terminal {
    package enum MouseTracking: Sendable { case off, press, drag, all }
}

extension Terminal.Input {
    /// A native pointer event in zero-based cell coordinates on the live grid.
    public struct Pointer: Equatable, Sendable {
        public enum Action: String, Sendable { case press, release, move }
        public enum Button: String, Sendable { case left, middle, right, none, wheelUp, wheelDown }

        public let action: Action
        public let button: Button
        public let row: Int
        public let column: Int
        public let modifiers: Modifiers

        public init(_ action: Action, button: Button, row: Int, column: Int, modifiers: Modifiers = []) {
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
