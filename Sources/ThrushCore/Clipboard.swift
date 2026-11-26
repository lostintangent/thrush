// OSC 52 lets a program copy text to the app's pasteboard, so a yank in Neovim, Helix or tmux reaches
// the device's clipboard even when the program runs on another machine. The Ms capability that XTGETTCAP
// reports tells a program it can.

extension Terminal {
    /// The text an OSC 52 payload copies, or nil when it copies nothing.
    ///
    /// The payload is `Pc ; Pd`. Pc names selections, and Apple platforms have one pasteboard, so every
    /// selection copies to it. Pd is the text in base64, up to any padding. A program reads with `?` and
    /// gets no reply, so it never sees what the user copied. Text that's empty or isn't base64 copies
    /// nothing, and the control string limit caps a copy near 7.5 MB.
    static func clipboardText(_ payload: [UInt8]) -> String? {
        guard let separator = payload.firstIndex(of: UInt8(ascii: ";")) else { return nil }
        let encoded = payload[(separator + 1)...].prefix { $0 != UInt8(ascii: "=") }
        var text: [UInt8] = []
        text.reserveCapacity(encoded.count / 4 * 3 + 2)
        var bits: UInt32 = 0
        var count = 0
        for byte in encoded {
            guard let value = base64Value(byte) else { return nil }
            bits = bits << 6 | value
            count += 6
            if count >= 8 {
                count -= 8
                text.append(UInt8(truncatingIfNeeded: bits >> count))
            }
        }
        return text.isEmpty ? nil : String(decoding: text, as: UTF8.self)
    }

    private static func base64Value(_ byte: UInt8) -> UInt32? {
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"): UInt32(byte - UInt8(ascii: "A"))
        case UInt8(ascii: "a")...UInt8(ascii: "z"): UInt32(byte - UInt8(ascii: "a")) + 26
        case UInt8(ascii: "0")...UInt8(ascii: "9"): UInt32(byte - UInt8(ascii: "0")) + 52
        case UInt8(ascii: "+"): 62
        case UInt8(ascii: "/"): 63
        default: nil
        }
    }
}
