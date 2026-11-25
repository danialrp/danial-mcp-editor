/// Editing operations on one track. They keep the track's invariant: clips are
/// sorted by start and never overlap. All of them are pure value operations.
extension Track {
    /// Index of the clip that covers `t` (start <= t < end).
    public func clipIndex(containing t: Time) -> Int? {
        let i = firstClipIndex(endingAfter: t)
        guard i < clips.count, clips[i].start <= t else { return nil }
        return i
    }

    /// Index of the first clip whose end is after `t` (binary search).
    public func firstClipIndex(endingAfter t: Time) -> Int {
        var lo = 0, hi = clips.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if clips[mid].end <= t { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// Index of the first clip that starts at or after `t` (binary search).
    public func firstClipIndex(startingAtOrAfter t: Time) -> Int {
        var lo = 0, hi = clips.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if clips[mid].start < t { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// Clips that overlap a range, ignoring the given ids.
    public func overlapping(_ range: TimeRange, ignoring: Set<EntityID> = []) -> [Clip] {
        var out: [Clip] = []
        var i = firstClipIndex(endingAfter: range.start)
        while i < clips.count, clips[i].start < range.end {
            if !ignoring.contains(clips[i].id) { out.append(clips[i]) }
            i += 1
        }
        return out
    }

    public func ensureUnlocked() throws {
        if locked { throw EditorError(.locked, "track \(id) is locked") }
    }

    /// Places a clip where there is free space.
    public mutating func place(_ clip: Clip) throws {
        let hits = overlapping(clip.range)
        if let h = hits.first {
            throw EditorError(.conflict,
                "clip would overlap clip \(h.id) (\(h.start.seconds)-\(h.end.seconds) s) on track \(id); use mode \"insert\" or choose another start")
        }
        clips.insert(clip, at: firstClipIndex(startingAtOrAfter: clip.start))
    }

    /// Places a clip and pushes every clip at or after its start later by its
    /// duration. A clip that is cut in two by the start point is split first.
    public mutating func insertRippling(_ clip: Clip, ids: inout IDGenerator) {
        split(at: clip.start, ids: &ids)
        let i = firstClipIndex(startingAtOrAfter: clip.start)
        for j in i..<clips.count { clips[j].start = clips[j].start + clip.duration }
        clips.insert(clip, at: i)
    }

    /// Splits the clip that covers `t` into two at `t`. Returns the new clip's
    /// id, or nil when `t` is not strictly inside a clip.
    @discardableResult
    public mutating func split(at t: Time, ids: inout IDGenerator) -> EntityID? {
        guard let i = clipIndex(containing: t), clips[i].start < t else { return nil }
        let c = clips[i]
        let leftDuration = t - c.start
        var left = c, right = c
        left.duration = leftDuration
        right.id = ids.next("clip")
        right.start = t
        right.duration = c.end - t
        if c.sourceDuration.ticks >= 2 {
            // Each half reads at least one tick of the file, even on a very
            // slow clip (a long freeze frame), where a share rounds to nothing.
            let share = Int64((Double(leftDuration.ticks) * c.speed).rounded())
            let leftSource = Time(ticks: Swift.min(Swift.max(share, 1), c.sourceDuration.ticks - 1))
            left.sourceDuration = leftSource
            right.sourceStart = c.sourceStart + leftSource
            right.sourceDuration = c.sourceDuration - leftSource
        } else {
            // A clip that reads a single tick shows one moment: both halves keep it.
        }
        // An intro stays at the start and an outro at the end; filters go on
        // both halves. Keyframes are in source time and need no change.
        left.effects = c.effects.filter { $0.kind != .out }
        right.effects = c.effects.filter { $0.kind != .in }.map { e in
            var e = e
            if e.kind == .filter { e.id = ids.next("fx") }
            return e
        }
        // The fade-in stays at the start and the fade-out at the end, as
        // with intros and outros: a cut must not dip the sound.
        left.fadeOut = .zero
        right.fadeIn = .zero
        left.fitFades()
        right.fitFades()
        clips[i] = left
        clips.insert(right, at: i + 1)
        return right.id
    }

    /// Removes everything inside `range`, splitting clips at its edges. With
    /// `ripple`, later clips move left to close the gap. Returns removed ids.
    @discardableResult
    public mutating func delete(_ range: TimeRange, ripple: Bool, ids: inout IDGenerator) -> [EntityID] {
        guard !range.isEmpty else { return [] }
        split(at: range.start, ids: &ids)
        split(at: range.end, ids: &ids)
        var removed: [EntityID] = []
        clips.removeAll { c in
            let inside = c.start >= range.start && c.end <= range.end
            if inside { removed.append(c.id) }
            return inside
        }
        if ripple {
            let i = firstClipIndex(startingAtOrAfter: range.end)
            for j in i..<clips.count { clips[j].start = clips[j].start - range.duration }
        }
        return removed
    }

    /// Removes clips by id. With `ripple`, each later clip moves left by the
    /// total length of the removed clips before it.
    public mutating func remove(_ ids: Set<EntityID>, ripple: Bool) {
        var shift = Time.zero
        var kept: [Clip] = []
        kept.reserveCapacity(clips.count)
        for c in clips {
            if ids.contains(c.id) {
                shift = shift + c.duration
            } else {
                var c = c
                if ripple { c.start = c.start - shift }
                kept.append(c)
            }
        }
        clips = kept
    }

    /// Moves every clip left so there are no empty spaces, starting at zero.
    public mutating func closeGaps() {
        var cursor = Time.zero
        for i in clips.indices {
            clips[i].start = cursor
            cursor = clips[i].end
        }
    }
}
