import AppKit

/// A slider that says when its value is final. While the mouse drags it its
/// action runs with `isFinal` false (to show the value); when the drag or
/// click ends the action runs once more with `isFinal` true, so the change
/// is applied once and is one undo step. A change that does not come from a
/// drag (keys, accessibility, scripts) is final at once. NSSlider's own last
/// action comes with the last drag event, not with the release, so the
/// release cannot be read from the current event.
///
/// Its bar fills from the neutral value (`origin`: 0 when the range holds
/// 0, else its minimum, or 1 for a speed or scale), not from the left end:
/// blue towards higher values, red towards lower ones.
final class CommitSlider: NSSlider {
    private var tracking = false

    var isFinal: Bool { !tracking }

    /// The value the bar fills from; nil uses 0 when the range holds it,
    /// else the minimum.
    var origin: Double? { didSet { needsDisplay = true } }

    var neutral: Double {
        if let origin { return origin }
        return minValue < 0 && maxValue > 0 ? 0 : minValue
    }

    override class var cellClass: AnyClass? {
        get { FromZeroSliderCell.self }
        set {}
    }

    // The drag is followed through plain mouse events instead of NSSlider's
    // own tracking loop: that loop holds the run loop in tracking mode, and
    // there the player does not draw a new frame, so the picture would only
    // change on release. A click on the bar puts the knob there; a double
    // click puts it back to the neutral value.
    override func mouseDown(with e: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
        if e.clickCount == 2 {
            tracking = false
            doubleValue = neutral
            sendAction(action, to: target)
            return
        }
        tracking = true
        grab = knobGrab(e)
        follow(e)
    }

    override func mouseDragged(with e: NSEvent) {
        guard tracking else { return }
        follow(e)
    }

    override func mouseUp(with e: NSEvent) {
        guard tracking else { return }
        let before = doubleValue
        set(from: e)
        tracking = false
        if doubleValue != before { needsDisplay = true }
        sendAction(action, to: target)
    }

    /// Where on the knob it was taken, so taking it does not make it jump.
    private var grab: CGFloat = 0

    private func knobGrab(_ e: NSEvent) -> CGFloat {
        guard let cell = cell as? NSSliderCell else { return 0 }
        let p = convert(e.locationInWindow, from: nil)
        let knob = cell.knobRect(flipped: isFlipped)
        return knob.insetBy(dx: -2, dy: -4).contains(p) ? p.x - knob.midX : 0
    }

    private func set(from e: NSEvent) {
        guard let cell = cell as? NSSliderCell, maxValue > minValue else { return }
        let p = convert(e.locationInWindow, from: nil)
        let knob = cell.knobRect(flipped: isFlipped)
        let track = cell.barRect(flipped: isFlipped)
        let inset = knob.width / 2
        let f = (p.x - grab - track.minX - inset) / max(1, track.width - 2 * inset)
        doubleValue = minValue + Double(min(1, max(0, f))) * (maxValue - minValue)
    }

    private func follow(_ e: NSEvent) {
        let before = doubleValue
        set(from: e)
        if doubleValue != before || !isFinal {
            needsDisplay = true
            sendAction(action, to: target)
        }
    }

    /// Steps through `values` as a drag would (the self-test), then lets go.
    func simulateDrag(_ values: [Double]) async {
        tracking = true
        for v in values {
            doubleValue = v
            sendAction(action, to: target)
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
        tracking = false
        sendAction(action, to: target)
    }

    /// True when `sender` is not a slider in the middle of a drag.
    static func isFinal(_ sender: Any?) -> Bool {
        (sender as? CommitSlider)?.isFinal ?? true
    }
}

/// Draws the bar of a CommitSlider: a dim track, a mark at the neutral
/// value, and the part between the neutral value and the knob in colour.
final class FromZeroSliderCell: NSSliderCell {
    static let positive = NSColor.controlAccentColor
    static let negative = NSColor.systemRed

    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let bar = NSRect(x: rect.minX, y: rect.midY - 2, width: rect.width, height: 4)
        NSColor(white: 1, alpha: 0.14).setFill()
        NSBezierPath(roundedRect: bar, xRadius: 2, yRadius: 2).fill()
        guard maxValue > minValue else { return }
        let neutral = (controlView as? CommitSlider)?.neutral ?? minValue
        // Where a value sits along the bar: the knob's centre travels between
        // half a knob in from each end.
        let knob = knobRect(flipped: flipped)
        let inset = knob.width / 2
        func x(_ v: Double) -> CGFloat {
            let f = (min(max(v, minValue), maxValue) - minValue) / (maxValue - minValue)
            return rect.minX + inset + CGFloat(f) * (rect.width - 2 * inset)
        }
        let x0 = x(neutral), x1 = knob.midX
        if neutral > minValue {
            // A mark at the neutral value, so zero is visible when nothing is set.
            NSColor(white: 1, alpha: 0.35).setFill()
            NSRect(x: x0 - 0.75, y: rect.midY - 5, width: 1.5, height: 10).fill()
        }
        guard abs(x1 - x0) > 0.5 else { return }
        (doubleValue >= neutral ? Self.positive : Self.negative).setFill()
        NSBezierPath(roundedRect: NSRect(x: min(x0, x1), y: bar.minY, width: abs(x1 - x0), height: bar.height), xRadius: 2, yRadius: 2).fill()
    }
}
