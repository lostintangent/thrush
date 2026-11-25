extension Terminal {
    /// The ISO 2022 graphic sets that redraw printable ASCII. A program designates a set into one of
    /// four slots, G0 to G3, then invokes a slot to print with it. Most programs only put DEC line
    /// drawing in G0 or G1 to draw boxes.
    struct CharacterSets: Sendable {
        /// A 94-character set that replaces some printable ASCII characters.
        enum Set: Hashable, Sendable {
            case ascii, lineDrawing
            case british, dutch, finnish, french, frenchCanadian, german, italian, norwegianDanish, spanish, swedish, swiss

            /// The final byte of the SCS sequence that designates the set.
            init?(final: UInt8) {
                switch Unicode.Scalar(final) {
                case "B": self = .ascii
                case "0": self = .lineDrawing
                case "A": self = .british
                case "4": self = .dutch
                case "C", "5": self = .finnish
                case "R": self = .french
                case "Q": self = .frenchCanadian
                case "K": self = .german
                case "Y": self = .italian
                case "E", "6": self = .norwegianDanish
                case "Z": self = .spanish
                case "H", "7": self = .swedish
                case "=": self = .swiss
                default: return nil
                }
            }

            /// Only characters below DEL change. Everything else prints as it is.
            func translate(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
                switch self {
                case .ascii:
                    return scalar
                case .lineDrawing:
                    let index = Int(scalar.value) - 0x60
                    return Self.lineDrawingGlyphs.indices.contains(index) ? Self.lineDrawingGlyphs[index] : scalar
                default:
                    return Self.national[self]?[scalar] ?? scalar
                }
            }

            /// Line drawing replaces each character from ` through ~, in order.
            private static let lineDrawingGlyphs = Array("◆▒␉␌␍␊°±␤␋┘┐┌└┼⎺⎻─⎼⎽├┤┴┬│≤≥π≠£·".unicodeScalars)

            /// Each national set replaces a few of the ASCII symbols with its own letters.
            private static let national: [Set: [Unicode.Scalar: Unicode.Scalar]] = [
                .british: ["#": "£"],
                .dutch: ["#": "£", "@": "¾", "[": "ĳ", "\\": "½", "]": "|", "{": "¨", "|": "ƒ", "}": "¼", "~": "´"],
                .finnish: ["[": "Ä", "\\": "Ö", "]": "Å", "^": "Ü", "`": "é", "{": "ä", "|": "ö", "}": "å", "~": "ü"],
                .french: ["#": "£", "@": "à", "[": "°", "\\": "ç", "]": "§", "{": "é", "|": "ù", "}": "è", "~": "¨"],
                .frenchCanadian: ["@": "à", "[": "â", "\\": "ç", "]": "ê", "^": "î", "`": "ô", "{": "é", "|": "ù", "}": "è", "~": "û"],
                .german: ["@": "§", "[": "Ä", "\\": "Ö", "]": "Ü", "{": "ä", "|": "ö", "}": "ü", "~": "ß"],
                .italian: ["#": "£", "@": "§", "[": "°", "\\": "ç", "]": "é", "`": "ù", "{": "à", "|": "ò", "}": "è", "~": "ì"],
                .norwegianDanish: ["@": "Ä", "[": "Æ", "\\": "Ø", "]": "Å", "^": "Ü", "`": "ä", "{": "æ", "|": "ø", "}": "å", "~": "ü"],
                .spanish: ["#": "£", "@": "§", "[": "¡", "\\": "Ñ", "]": "¿", "{": "°", "|": "ñ", "}": "ç"],
                .swedish: ["@": "É", "[": "Ä", "\\": "Ö", "]": "Å", "^": "Ü", "`": "é", "{": "ä", "|": "ö", "}": "å", "~": "ü"],
                .swiss: ["#": "ù", "@": "à", "[": "é", "\\": "ç", "]": "ê", "^": "î", "_": "è", "`": "ô", "{": "ä", "|": "ö", "}": "ü", "~": "û"],
            ]
        }

        private var slots: InlineArray<4, Set> = .init(repeating: .ascii)
        private var invoked = 0
        /// The set that prints. Restoring a saved cursor replaces it until the next shift or designation.
        var active = Set.ascii

        /// SCS puts a set in a slot. It prints at once if that slot is the one invoked.
        mutating func designate(_ set: Set, slot: Int) {
            slots[slot] = set
            if slot == invoked { active = set }
        }

        /// SI, SO and the locking shifts choose the slot that prints.
        mutating func invoke(_ slot: Int) {
            invoked = slot
            active = slots[slot]
        }
    }
}
