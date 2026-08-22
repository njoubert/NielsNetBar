// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

/// The per-core load display in the CPU menu: one ring per logical core, a row per
/// performance level, and a legend underneath.
///
/// This replaced a column of text bars, one menu row per core — which on a machine with
/// more than a few cores was both ugly and most of the menu's height. A row of rings says
/// the same thing in a glance and in a fraction of the space.
final class CoreGaugesView: NSView {

    struct Group {
        var name: String
        var color: NSColor
        var loads: [Double]    // 0…1, one per logical core
    }

    var groups: () -> [Group] = { [] }
    /// `--dump-cores` only: paint a menu-like background so the light text is visible.
    var debugBackground = false

    private static let ring: CGFloat = 26
    private static let ringWidth: CGFloat = 3.5
    private static let ringGap: CGFloat = 9
    private static let rowGap: CGFloat = 12
    private static let legendGap: CGFloat = 10
    private static let legendLine: CGFloat = 18
    private static let insetX: CGFloat = 14      // lines up with the menu rows' text
    private static let insetY: CGFloat = 5
    private static let padding = NSSize(width: 12, height: 10)
    private static let boxRadius: CGFloat = 8
    private static let legendFont = NSFont.menuFont(ofSize: 0)
    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)

    /// How many rings fit across the panel at a given width.
    private static func perRow(width: CGFloat) -> Int {
        let content = width - insetX * 2 - padding.width * 2
        return max(1, Int((content + ringGap) / (ring + ringGap)))
    }

    /// How many lines of rings a group of `count` cores takes. A Mac with two dozen cores
    /// wraps rather than running off the side of the menu.
    private static func lines(_ count: Int, width: CGFloat) -> Int {
        max(1, Int(ceil(Double(count) / Double(perRow(width: width)))))
    }

    /// The height is known before there is any data — the menu needs it at build time — but
    /// it depends on how many lines the cores wrap onto, so it needs the core counts.
    static func height(coreCounts: [Int], width: CGFloat) -> CGFloat {
        let counts = coreCounts.isEmpty ? [1] : coreCounts
        let rows = counts.reduce(0) { $0 + lines($1, width: width) }
        return insetY * 2 + padding.height * 2
            + CGFloat(rows) * ring + CGFloat(rows - 1) * rowGap
            + legendGap + CGFloat(counts.count) * legendLine
    }

    /// This machine's ring panel height at the menu's width — the core layout does not
    /// change while the app runs.
    static let coresHeight: CGFloat = height(coreCounts: CPUInfo.coreGroups.map { $0.range.count },
                                             width: 324)

    override init(frame: NSRect) {
        super.init(frame: frame)
        autoresizingMask = [.width]
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }

    /// The panel, matching the chart's.
    private static let boxFill = NSColor(name: nil) { a in
        a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 0, alpha: 0.32) : NSColor(white: 0, alpha: 0.05)
    }
    private static let boxStroke = NSColor(name: nil) { a in
        a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.09) : NSColor(white: 0, alpha: 0.10)
    }
    /// The unfilled part of a ring: present enough to read as a dial, quiet enough not to
    /// look like load.
    private static let trackColor = NSColor(name: nil) { a in
        a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.15) : NSColor(white: 0, alpha: 0.12)
    }

    private var boxRect: NSRect { bounds.insetBy(dx: CoreGaugesView.insetX, dy: CoreGaugesView.insetY) }

    override func draw(_ dirtyRect: NSRect) {
        if debugBackground { NSColor(white: 0.13, alpha: 1).setFill(); bounds.fill() }

        let box = NSBezierPath(roundedRect: boxRect.insetBy(dx: 0.5, dy: 0.5),
                               xRadius: CoreGaugesView.boxRadius, yRadius: CoreGaugesView.boxRadius)
        CoreGaugesView.boxFill.setFill(); box.fill()
        CoreGaugesView.boxStroke.setStroke(); box.lineWidth = 1; box.stroke()

        let all = groups()
        guard !all.isEmpty else { return }
        let content = boxRect.insetBy(dx: CoreGaugesView.padding.width, dy: CoreGaugesView.padding.height)

        // Rings, top down: a performance level per block, wrapped onto as many lines as it
        // takes, each line centred so a group of four does not sit in the corner of a panel
        // sized for nine.
        let perRow = CoreGaugesView.perRow(width: bounds.width)
        var y = content.maxY
        for group in all {
            var remaining = group.loads[...]
            while !remaining.isEmpty {
                let line = remaining.prefix(perRow)
                remaining = remaining.dropFirst(line.count)
                let n = CGFloat(line.count)
                let lineWidth = n * CoreGaugesView.ring + max(n - 1, 0) * CoreGaugesView.ringGap
                var x = content.minX + (content.width - lineWidth) / 2
                for load in line {
                    drawRing(center: NSPoint(x: x + CoreGaugesView.ring / 2,
                                             y: y - CoreGaugesView.ring / 2),
                             fraction: load, color: group.color)
                    x += CoreGaugesView.ring + CoreGaugesView.ringGap
                }
                y -= CoreGaugesView.ring + CoreGaugesView.rowGap
            }
        }

        // Legend, one line per group: a dot, the name, and the group's average on the right.
        y += CoreGaugesView.rowGap - CoreGaugesView.legendGap
        for group in all {
            y -= CoreGaugesView.legendLine
            let mean = group.loads.isEmpty ? 0 : group.loads.reduce(0, +) / Double(group.loads.count)
            let dot = NSRect(x: content.minX + 1, y: y + CoreGaugesView.legendLine / 2 - 4, width: 8, height: 8)
            group.color.setFill()
            NSBezierPath(ovalIn: dot).fill()

            let name = NSAttributedString(string: "\(group.name) Cores", attributes: [
                .font: CoreGaugesView.legendFont, .foregroundColor: NSColor.labelColor])
            name.draw(at: NSPoint(x: dot.maxX + 8, y: y + (CoreGaugesView.legendLine - name.size().height) / 2))

            let value = NSAttributedString(string: Format.percent(mean * 100), attributes: [
                .font: CoreGaugesView.valueFont, .foregroundColor: NSColor.labelColor])
            value.draw(at: NSPoint(x: content.maxX - value.size().width,
                                   y: y + (CoreGaugesView.legendLine - value.size().height) / 2))
        }
    }

    /// One core: a full track, and an arc over it that starts at twelve o'clock and runs
    /// clockwise for the core's share of a second.
    private func drawRing(center: NSPoint, fraction: Double, color: NSColor) {
        let radius = (CoreGaugesView.ring - CoreGaugesView.ringWidth) / 2
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        CoreGaugesView.trackColor.setStroke()
        track.lineWidth = CoreGaugesView.ringWidth
        track.stroke()

        let f = min(max(fraction, 0), 1)
        guard f > 0.005 else { return }
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: radius,
                      startAngle: 90, endAngle: 90 - 360 * CGFloat(f), clockwise: true)
        color.setStroke()
        arc.lineWidth = CoreGaugesView.ringWidth
        arc.lineCapStyle = .round
        arc.stroke()
    }

    // A click in here shouldn't close the menu (or do anything).
    override func mouseUp(with event: NSEvent) {}
    override func mouseDown(with event: NSEvent) {}
}
