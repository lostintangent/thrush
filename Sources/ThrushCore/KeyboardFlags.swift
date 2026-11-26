// The kitty keyboard protocol lets a program ask for keys that legacy encoding can't tell apart, such
// as Shift-Enter from Enter or Control-I from Tab. A program pushes the flags it wants when it starts
// and pops them when it exits, and it can ask which flags are in effect.

extension Terminal {
    /// The kitty keyboard protocol's enhancements that the terminal applies. A program can ask for
    /// others, but the terminal keeps and reports only these two.
    struct KeyboardFlags: OptionSet, Sendable {
        let rawValue: UInt8
        init(rawValue: UInt8) { self.rawValue = rawValue }
        /// Escape, Control and Alt chords, and Enter, Tab and Backspace with any modifier, send
        /// `CSI code ; modifiers u`. Function keys report every modifier.
        static let disambiguate = Self(rawValue: 1)
        /// A report for a chord that holds Shift adds the shifted key after a colon.
        static let alternateKeys = Self(rawValue: 4)

        /// The flags a program's parameter asks for, keeping the ones the terminal applies.
        init(parameter: Int) {
            let applied: Self = [.disambiguate, .alternateKeys]
            self = Self(rawValue: UInt8(truncatingIfNeeded: parameter)).intersection(applied)
        }
    }

    /// One screen's keyboard flags, with the latest push on top. Each screen keeps its own stack, so a
    /// full-screen program's flags leave with it. The stack holds eight entries and forgets the oldest
    /// one past that.
    struct KeyboardStack: Equatable, Sendable {
        private(set) var entries = InlineArray<8, KeyboardFlags>(repeating: [])
        private(set) var count = 0

        /// The flags in effect while this screen is active. An empty stack applies none.
        var top: KeyboardFlags { count == 0 ? [] : entries[count - 1] }

        mutating func push(_ flags: KeyboardFlags) {
            if count == entries.count {
                for index in 1..<count { entries[index - 1] = entries[index] }
                count -= 1
            }
            entries[count] = flags
            count += 1
        }

        /// Popping more entries than the stack holds empties it.
        mutating func pop(_ entries: Int) {
            count -= min(entries, count)
        }

        /// Mode 1 replaces the top entry's flags, 2 adds to them and 3 removes them. An empty stack
        /// gains an entry to change.
        mutating func update(_ flags: KeyboardFlags, mode: Int) {
            guard (1...3).contains(mode) else { return }
            if count == 0 { push([]) }
            switch mode {
            case 1: entries[count - 1] = flags
            case 2: entries[count - 1].formUnion(flags)
            default: entries[count - 1].subtract(flags)
            }
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.count == rhs.count && (0..<lhs.count).allSatisfy { lhs.entries[$0] == rhs.entries[$0] }
        }
    }
}
