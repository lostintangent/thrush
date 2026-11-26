/// ThrushCore's one unsafe technique. Scrolling a region rotates its rows, and inserting or deleting
/// characters rotates the cells after the cursor. Safe Swift can only move elements one at a time,
/// so the rotation moves them in blocks instead. It checks its bounds first, so no caller can reach
/// outside the array.
extension Array {
    /// Moves the elements in `range` toward its end by `offset`, or toward its start when it's negative,
    /// and wraps the elements pushed past one end around to the other.
    ///
    /// The shorter side waits in temporary storage while the rest slides over its slots, then fills the
    /// slots the slide left behind. Each typed move hands its elements to the destination and leaves the
    /// source uninitialized, so every element keeps its one owner and nothing is retained or released.
    /// Nothing between the moves can throw or read the array, and taking the buffer first copies it when
    /// a snapshot shares it.
    mutating func rotate(_ range: Range<Int>, by offset: Int) {
        precondition(range.lowerBound >= 0 && range.upperBound <= self.count, "Rotation out of bounds")
        let count = range.count
        guard count > 1 else { return }
        var offset = offset % count
        // Rotating the other way by the rest of the range is the same rotation, so set aside the shorter side.
        if offset > count / 2 { offset -= count } else if offset < -(count / 2) { offset += count }
        guard offset != 0 else { return }
        let shift = abs(offset)
        withUnsafeMutableBufferPointer { buffer in
            let first = buffer.baseAddress! + range.lowerBound, last = first + count - shift
            withUnsafeTemporaryAllocation(of: Element.self, capacity: shift) { aside in
                let aside = aside.baseAddress!
                if offset < 0 {
                    aside.moveInitialize(from: first, count: shift)
                    first.moveInitialize(from: first + shift, count: count - shift)
                    last.moveInitialize(from: aside, count: shift)
                } else {
                    aside.moveInitialize(from: last, count: shift)
                    (first + shift).moveInitialize(from: first, count: count - shift)
                    first.moveInitialize(from: aside, count: shift)
                }
            }
        }
    }
}
