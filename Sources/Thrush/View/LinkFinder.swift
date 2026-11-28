import ThrushCore

/// Finds the URLs programs print as plain text, so they open like the links programs send with OSC 8.
///
/// A URL starts at `http://` or `https://` and runs to the next space, or to a character a URL can't
/// hold unescaped, such as a quote or an angle bracket. It reads on across soft-wrapped rows but never
/// past a line break. Punctuation that ends a sentence, and a closing bracket without its opener, end it
/// too, so `(see https://x.y/z).` finds `https://x.y/z`. Text in a program's link is the program's, so a
/// URL that touches one isn't found.
///
/// A link opens only where the program meant, so a URL a program may have cut short isn't found: one
/// that fills its row without wrapping on, as when a pager or a split pane breaks a long line itself,
/// or one that runs into a border, an ellipsis or another symbol.
struct LinkFinder {
    /// A URL in the viewport, with its runs on the rows in view.
    struct Found {
        let number: UInt32
        let link: Terminal.Link
        let runs: [LinkRun]
    }

    /// Found links take numbers from 2^31 up, past any number the program's link table gives.
    static func isFound(_ number: UInt32) -> Bool { number >= first }
    private static let first: UInt32 = 1 << 31
    private var next = first

    /// A soft-wrapped line, known by its rows' revisions, which change with any change to their cells.
    private struct Line: Hashable {
        let columns: Int
        let revisions: [UInt64]
    }
    /// A URL in a line, with its runs on the line's rows.
    private struct Match {
        let number: UInt32
        let link: Terminal.Link
        let runs: [(row: Int, columns: Range<Int>)]
    }
    /// What the last call found in each line it read, so a line keeps its links and their numbers
    /// until its rows change or it leaves the viewport.
    private var lines: [Line: [Match]] = [:]

    /// The URLs in the `count` rows from `top` in `transcript`, where row zero is the oldest in history.
    /// A URL that starts above the viewport or ends below it is read whole, as far as a URI can run.
    mutating func find(in transcript: Terminal.Snapshot, top: Int, count: Int) -> [Found] {
        let columns = transcript.size.columns
        let bottom = min(transcript.history.count + transcript.rows.count, top + count)
        let reach = Terminal.Links.uriLimit / max(1, columns) + 1
        var start = top
        while start > max(0, top - reach), transcript.row(atAbsoluteIndex: start).isWrapped { start -= 1 }
        var found: [Found] = []
        var read: [Line: [Match]] = [:]
        while start < bottom {
            var rows = [transcript.row(atAbsoluteIndex: start)]
            while start + rows.count < min(transcript.history.count + transcript.rows.count, bottom + reach) {
                let row = transcript.row(atAbsoluteIndex: start + rows.count)
                guard row.isWrapped else { break }
                rows.append(row)
            }
            let line = Line(columns: columns, revisions: rows.map(\.generation))
            let matches = read[line] ?? lines[line] ?? scan(rows, from: start, in: transcript)
            read[line] = matches
            for match in matches {
                let runs = match.runs.compactMap { run in
                    (0..<count).contains(start + run.row - top)
                        ? LinkRun(number: match.number, row: start + run.row - top, columns: run.columns) : nil
                }
                if !runs.isEmpty { found.append(Found(number: match.number, link: match.link, runs: runs)) }
            }
            start += rows.count
        }
        lines = read
        return found
    }

    /// Reads `rows`, which start at row `first` of `transcript`.
    private mutating func scan(_ rows: [Terminal.Row], from first: Int, in transcript: Terminal.Snapshot) -> [Match] {
        let columns = transcript.size.columns
        // Each cell's first scalar and its place. A blank cell reads as a space, and a wide cell's second
        // column is skipped.
        var scalars: [Unicode.Scalar] = []
        var places: [(row: Int, column: Int, width: Int)] = []
        for (index, row) in rows.enumerated() {
            let end = transcript.textEnd(in: first + index)
            var column = 0
            while column < end {
                let cell = row[column]
                scalars.append(cell.text.unicodeScalars.first ?? " ")
                places.append((index, column, max(1, cell.width)))
                column += max(1, cell.width)
            }
        }
        var matches: [Match] = []
        for range in Self.urls(in: scalars, cut: rows[rows.count - 1].trimmedLength == columns) {
            let cells = places[range].map { rows[$0.row][$0.column] }
            guard !cells.contains(where: { $0.style.link != 0 }) else { continue }
            let link = Terminal.Link(id: nil, uri: cells.map(\.text).joined())
            guard link.uri.utf8.count <= Terminal.Links.uriLimit, case .web = link.destination else { continue }
            var runs: [(row: Int, columns: Range<Int>)] = []
            for place in places[range] {
                if let last = runs.last, last.row == place.row {
                    runs[runs.count - 1].columns = last.columns.lowerBound..<(place.column + place.width)
                } else {
                    runs.append((place.row, place.column..<(place.column + place.width)))
                }
            }
            matches.append(Match(number: next, link: link, runs: runs))
            next = next == .max ? Self.first : next + 1
        }
        return matches
    }

    private static let schemes = ["https://", "http://"].map { Array($0.unicodeScalars) }

    /// Where `text` holds URLs, leaving out any a program may have cut short, including one that runs
    /// to the end of a `cut` text.
    private static func urls(in text: [Unicode.Scalar], cut: Bool) -> [Range<Int>] {
        var urls: [Range<Int>] = []
        var start = 0
        while let h = text[start...].firstIndex(of: "h") {
            guard let scheme = schemes.first(where: { text[h...].starts(with: $0) }) else {
                start = h + 1
                continue
            }
            var end = h + scheme.count
            while end < text.count, !endsURL(text[end]) { end += 1 }
            start = end
            if end < text.count ? cuts(text[end]) : cut { continue }
            while end > h + scheme.count, endsOutside(text[h..<end]) { end -= 1 }
            if end > h + scheme.count { urls.append(h..<end) }
        }
        return urls
    }

    /// Whether a URL can't hold `scalar` unescaped: a space, a character such as a quote or an angle
    /// bracket that text around a URL uses to set it off, or past ASCII, anything but a letter.
    private static func endsURL(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "\"", "<", ">", "{", "}", "|", "\\", "^", "`": true
        default: scalar.isASCII ? scalar.value <= 0x20 : !scalar.properties.isAlphabetic
        }
    }

    /// Whether a URL that stops at `scalar` may go on past it, because a program drew a border such as
    /// `|` or `│`, an ellipsis or another symbol over the rest, rather than setting it off with a space
    /// or punctuation.
    private static func cuts(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == "|" || scalar == "…" { return true }
        if scalar.isASCII || scalar.properties.isWhitespace { return false }
        return !Character(scalar).isPunctuation
    }

    /// Whether a URL's last character belongs to the text around it: punctuation that ends a sentence
    /// or clause, or a closing bracket the URL doesn't open.
    private static func endsOutside(_ url: ArraySlice<Unicode.Scalar>) -> Bool {
        guard let last = url.last else { return false }
        if ".,;:!?'".unicodeScalars.contains(last) { return true }
        let opener: Unicode.Scalar? = switch last {
        case ")": "("
        case "]": "["
        default: nil
        }
        guard let opener else { return false }
        return url.count { $0 == last } > url.count { $0 == opener }
    }
}
