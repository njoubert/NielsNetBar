// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

/// A horizontal bar split into coloured segments — one segment for a simple meter
/// (pressure, swap), several for a breakdown (wired / active / compressed / free).
///
/// Fractions are of the whole bar and are drawn in order from the left; anything past 1 is
/// clipped rather than allowed to run off the end.
final class SegmentBarView: NSView {

    struct Segment {
        var color: NSColor
        var fraction: Double
    }

    var segments: () -> [Segment] = { [] }
    /// `--dump-bars` only: paint a menu-like background so the bar is visible.
    var debugBackground = false

    static let barHeight: CGFloat = 12
    static let height: CGFloat = 22
    private static let insetX: CGFloat = 14      // lines up with the menu rows' text
    private static let radius: CGFloat = 3

    /// The unfilled remainder, and the ground the segments sit on.
    private static let trackColor = NSColor(name: nil) { a in
        a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 0, alpha: 0.45) : NSColor(white: 0, alpha: 0.10)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        autoresizingMask = [.width]
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        if debugBackground { NSColor(white: 0.13, alpha: 1).setFill(); bounds.fill() }

        let track = NSRect(x: SegmentBarView.insetX,
                           y: bounds.midY - SegmentBarView.barHeight / 2,
                           width: max(bounds.width - SegmentBarView.insetX * 2, 0),
                           height: SegmentBarView.barHeight)
        let rounded = NSBezierPath(roundedRect: track, xRadius: SegmentBarView.radius, yRadius: SegmentBarView.radius)
        SegmentBarView.trackColor.setFill()
        rounded.fill()

        // Everything is drawn inside the rounded track, so the ends stay rounded however
        // many segments there are and wherever they fall.
        NSGraphicsContext.saveGraphicsState()
        rounded.addClip()
        var x = track.minX
        for segment in segments() {
            let f = min(max(segment.fraction, 0), 1)
            guard f > 0 else { continue }
            let w = track.width * CGFloat(f)
            guard x < track.maxX else { break }
            segment.color.setFill()
            NSRect(x: x, y: track.minY, width: min(w, track.maxX - x), height: track.height).fill()
            x += w
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    // A click in here shouldn't close the menu (or do anything).
    override func mouseUp(with event: NSEvent) {}
    override func mouseDown(with event: NSEvent) {}
}
