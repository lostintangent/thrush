// OSC 8 makes the text after it a link, and a style carries the link's number in the screen's
// link table. A number is never reused while any row or the current style holds it.

extension Terminal {
    /// The target of an OSC 8 link. Text with the same id and URI belongs to one link, wherever it is.
    package struct Link: Hashable, Sendable {
        package let id: String?
        package let uri: String

        package init(id: String?, uri: String) {
            self.id = id
            self.uri = uri
        }

        /// What `OSC 8 ; params ; uri` asks for: a link to open or the current one to close.
        enum Command {
            case open(Link), close
        }

        /// The params are colon-separated `key=value` pairs, and only `id` has a meaning. A payload
        /// without a semicolon, or with params but no URI, changes nothing and returns `nil`.
        static func command(_ payload: String) -> Command? {
            guard let separator = payload.firstIndex(of: ";") else { return nil }
            let parameters = payload[..<separator].trimmingWhitespace
            let uri = payload[payload.index(after: separator)...]
            if uri.isEmpty { return parameters.isEmpty ? .close : nil }
            let id = parameters.split(separator: ":", omittingEmptySubsequences: false)
                .first { $0.hasPrefix("id=") }?.dropFirst(3)
            return .open(Link(id: id?.isEmpty == false ? String(id!) : nil, uri: String(uri)))
        }

        // What the link adds to the table's text.
        fileprivate var size: Int { uri.utf8.count + (id?.utf8.count ?? 0) }
    }

    /// The links that styles refer to by number. A link with an id keeps one number, so text a program
    /// redraws or splits across rows stays one link. A link without one gets a new number each time it
    /// opens, as in the reference.
    package struct Links: Sendable {
        /// The URI and id lengths VTE and iTerm2 accept. A longer one opens no link.
        package static let uriLimit = 2083
        static let idLimit = 250
        /// A link that would pass either limit, even after a sweep, prints as plain text.
        static let countLimit = 65_536
        static let textLimit = 4 << 20

        // Number `n` is `entries[n - 1]`, and `nil` marks a free number. A snapshot holds only these,
        // so opening a link after a frame copies them and none of the bookkeeping below.
        private(set) var entries: [Link?] = []
        private var free: [UInt32] = []
        private var identified: [Link: UInt32] = [:]
        private var text = 0
        // A sweep visits every style on both screens and in history, so the table sweeps only after
        // opening as many new links as it kept on the last sweep. That keeps the cost per link small.
        // A table out of numbers or text sweeps every 64 opens instead.
        private var opened = 0
        private var sweepAfter = 64

        subscript(number: UInt32) -> Link? {
            number == 0 || number > entries.count ? nil : entries[Int(number) - 1]
        }

        /// Whether the table should free the numbers no style holds before it adds `link`.
        func needsSweep(before link: Link) -> Bool {
            guard identified[link] == nil, opened >= 64 else { return false }
            let full = free.isEmpty && entries.count >= Self.countLimit
            return opened >= sweepAfter || full || text + link.size > Self.textLimit
        }

        /// Returns the number for `link`, or zero when the link is too long or the table is full.
        mutating func number(for link: Link) -> UInt32 {
            if let number = identified[link] { return number }
            opened += 1
            guard link.uri.utf8.count <= Self.uriLimit, (link.id?.utf8.count ?? 0) <= Self.idLimit,
                  text + link.size <= Self.textLimit else { return 0 }
            let number: UInt32
            if let reused = free.popLast() {
                number = reused
                entries[Int(number) - 1] = link
            } else {
                guard entries.count < Self.countLimit else { return 0 }
                entries.append(link)
                number = UInt32(entries.count)
            }
            text += link.size
            if link.id != nil { identified[link] = number }
            return number
        }

        /// Frees every number not in `used`.
        mutating func sweep(keeping used: NumberSet) {
            var kept = 0
            for index in entries.indices {
                guard let link = entries[index] else { continue }
                let number = UInt32(index + 1)
                if used.contains(number) {
                    kept += 1
                    continue
                }
                entries[index] = nil
                free.append(number)
                text -= link.size
                if link.id != nil { identified[link] = nil }
            }
            // Hand out low numbers first.
            free.sort(by: >)
            opened = 0
            sweepAfter = max(64, kept)
        }

        /// Link numbers, one bit each, so marking every number a full table holds stays cheap.
        struct NumberSet {
            private var words: [UInt64]

            /// A set that can hold the numbers from zero through `last`.
            init(through last: Int) { words = Array(repeating: 0, count: last / 64 + 1) }

            mutating func insert(_ number: UInt32) { words[Int(number / 64)] |= 1 << (number % 64) }

            func contains(_ number: UInt32) -> Bool { words[Int(number / 64)] & 1 << (number % 64) != 0 }
        }
    }
}

extension Substring {
    /// Trims what the reference trims: Unicode white space and the byte order mark, but not NEL.
    fileprivate var trimmingWhitespace: Substring {
        func isSpace(_ scalar: Unicode.Scalar) -> Bool {
            scalar == "\u{feff}" || scalar != "\u{85}" && scalar.properties.isWhitespace
        }
        let scalars = unicodeScalars
        let start = scalars.firstIndex { !isSpace($0) } ?? scalars.endIndex
        let end = scalars[start...].lastIndex { !isSpace($0) }.map(scalars.index(after:)) ?? start
        return Substring(scalars[start..<end])
    }
}
