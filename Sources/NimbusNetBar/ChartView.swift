// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

/// How a chart draws one metric: which colours, which glyphs, how a value reads as text,
/// and what sets the vertical scale.
struct ChartStyle {

    /// `.mirrored` — two series around a centre line (network ↑/↓, disk write/read).
    /// `.single`   — one series growing up from the bottom (GPU, memory).
    /// `.stacked`  — the two series summed into one bar, primary at the bottom (CPU
    ///               user under system).
    enum Mode { case mirrored, single, stacked }

    var mode: Mode = .mirrored
    /// Drawn above the baseline, and the only series in `.single` mode.
    var primaryColor: NSColor
    /// Drawn below the baseline; unused in `.single` mode.
    var secondaryColor: NSColor = .clear
    var primaryGlyph: String = ""
    var secondaryGlyph: String = ""
    /// A value → the short text the peak and hover labels show ("12.4 Mbps", "34 %").
    var format: (Double) -> String
    /// The scale follows the window's peak, but never drops below this — otherwise an idle
    /// minute is a wall of full-height bars.
    var minPeak: Double = 1
    /// A fixed ceiling for the scale (100 for a percentage) instead of the window's peak.
    /// When set no "peak …" label is drawn: a scale that never moves says nothing.
    var fixedPeak: Double?
}

/// The history chart at the top of a widget's menu: one bar per second for the last minute.
/// Two-series metrics are mirrored around a centre line — the primary series grows up, the
/// secondary hangs down — on a single linear scale. Hovering a bar shows that second's
/// numbers.
final class ChartView: NSView {

    static let chartHeight: CGFloat = 128
    private static let insetX: CGFloat = 14     // lines up with the menu rows' text
    private static let insetY: CGFloat = 5
    private static let gap: CGFloat = 1
    private static let labelFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)

    var history: () -> [Sample] = { [] }
    var style: ChartStyle
    /// `--dump-chart` only: paint a menu-like background so the light text is visible.
    var debugBackground = false
    private var hoverIndex: Int?
    private var tracking: NSTrackingArea?

    init(frame: NSRect, style: ChartStyle) {
        self.style = style
        super.init(frame: frame)
        autoresizingMask = [.width]
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }

    // MARK: Layout

    private static let labelStrip: CGFloat = 13  // labels live above the bars, not on them
    private static let boxPadding = NSSize(width: 10, height: 7)
    private static let boxRadius: CGFloat = 8

    /// The panel the chart sits in: darker than the menu, like a window inside it.
    private static let boxFill = NSColor(name: nil) { a in
        a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 0, alpha: 0.32) : NSColor(white: 0, alpha: 0.05)
    }
    private static let boxStroke = NSColor(name: nil) { a in
        a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.09) : NSColor(white: 0, alpha: 0.10)
    }

    private var boxRect: NSRect {
        bounds.insetBy(dx: ChartView.insetX, dy: ChartView.insetY)
    }

    private var plotRect: NSRect {
        var r = boxRect.insetBy(dx: ChartView.boxPadding.width, dy: ChartView.boxPadding.height)
        r.size.height -= ChartView.labelStrip
        return r
    }

    private var labelRect: NSRect {
        NSRect(x: plotRect.minX, y: plotRect.maxY, width: plotRect.width, height: ChartView.labelStrip)
    }

    private var barWidth: CGFloat {
        let n = CGFloat(History.length)
        return (plotRect.width - (n - 1) * ChartView.gap) / n
    }

    /// Bar index (0 = oldest) under an x coordinate, if any.
    private func index(at x: CGFloat) -> Int? {
        let rel = x - plotRect.minX
        guard rel >= 0 else { return nil }
        let i = Int(rel / (barWidth + ChartView.gap))
        return i < History.length ? i : nil
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        if debugBackground { NSColor(white: 0.13, alpha: 1).setFill(); bounds.fill() }

        // The panel.
        let box = NSBezierPath(roundedRect: boxRect.insetBy(dx: 0.5, dy: 0.5), xRadius: ChartView.boxRadius, yRadius: ChartView.boxRadius)
        ChartView.boxFill.setFill(); box.fill()
        ChartView.boxStroke.setStroke(); box.lineWidth = 1; box.stroke()

        let plot = plotRect
        let samples = history()
        let n = History.length
        // Right-align: the newest second is the rightmost bar.
        let offset = n - samples.count
        let mirrored = style.mode == .mirrored
        let windowPeak: Double
        switch style.mode {
        case .mirrored: windowPeak = samples.map { max($0.primary, $0.secondary) }.max() ?? 0
        case .single:   windowPeak = samples.map(\.primary).max() ?? 0
        case .stacked:  windowPeak = samples.map { $0.primary + $0.secondary }.max() ?? 0
        }
        let peak = style.fixedPeak ?? max(windowPeak, style.minPeak)
        // Mirrored splits the plot around its middle; a single series gets the whole height.
        let span = mirrored ? plot.height / 2 - 1 : plot.height - 2
        let baseline = mirrored ? plot.midY : plot.minY + 1
        let bw = barWidth

        // Baseline.
        NSColor.separatorColor.setStroke()
        let base = NSBezierPath()
        base.move(to: NSPoint(x: plot.minX, y: baseline))
        base.line(to: NSPoint(x: plot.maxX, y: baseline))
        base.lineWidth = 1
        base.stroke()

        for (j, r) in samples.enumerated() {
            let i = j + offset
            let x = plot.minX + CGFloat(i) * (bw + ChartView.gap)
            let hovered = hoverIndex == i
            let alpha: CGFloat = hoverIndex == nil ? 0.85 : (hovered ? 1 : 0.6)
            if style.mode == .stacked {
                // The whole bar in the secondary colour, then the primary share painted
                // over it from the baseline up: the straight edge between them is the split.
                let sum = r.primary + r.secondary
                let h = max(2, span * CGFloat(min(sum / peak, 1)))
                style.secondaryColor.withAlphaComponent(sum > 0 ? alpha : 0.25).setFill()
                roundedTop(NSRect(x: x, y: baseline + 1, width: bw, height: h), up: true).fill()
                let h1 = min(h, span * CGFloat(min(r.primary / peak, 1)))
                if h1 > 0 {
                    style.primaryColor.withAlphaComponent(alpha).setFill()
                    NSRect(x: x, y: baseline + 1, width: bw, height: h1).fill()
                }
                continue
            }
            let up = max(2, span * CGFloat(min(r.primary / peak, 1)))
            style.primaryColor.withAlphaComponent(r.primary > 0 ? alpha : 0.25).setFill()
            roundedTop(NSRect(x: x, y: baseline + 1, width: bw, height: up), up: true).fill()
            guard mirrored else { continue }
            let down = max(2, span * CGFloat(min(r.secondary / peak, 1)))
            style.secondaryColor.withAlphaComponent(r.secondary > 0 ? alpha : 0.25).setFill()
            roundedTop(NSRect(x: x, y: baseline - 1 - down, width: bw, height: down), up: false).fill()
        }

        // Peak label, top-right; hover readout, top-left.
        let labelAttrs: [NSAttributedString.Key: Any] = [.font: ChartView.labelFont, .foregroundColor: NSColor.secondaryLabelColor]
        let labels = labelRect
        if style.fixedPeak == nil {
            let peakText = NSAttributedString(string: "peak \(style.format(peak))", attributes: labelAttrs)
            peakText.draw(at: NSPoint(x: labels.maxX - peakText.size().width, y: labels.minY + 1))
        }

        if let h = hoverIndex, h - offset >= 0, h - offset < samples.count {
            let r = samples[h - offset]
            let age = n - 1 - h
            let s = NSMutableAttributedString(string: age == 0 ? "now   " : "−\(age) s   ", attributes: labelAttrs)
            func part(_ glyph: String, _ color: NSColor, _ value: Double, trailing: String = "") {
                if !glyph.isEmpty {
                    s.append(NSAttributedString(string: glyph + " ", attributes: [.font: ChartView.labelFont, .foregroundColor: color]))
                }
                s.append(NSAttributedString(string: style.format(value) + trailing, attributes: [.font: ChartView.labelFont, .foregroundColor: NSColor.labelColor]))
            }
            switch style.mode {
            case .mirrored:
                part(style.secondaryGlyph, style.secondaryColor, r.secondary, trailing: "   ")
                part(style.primaryGlyph, style.primaryColor, r.primary)
            case .stacked:
                part(style.primaryGlyph, style.primaryColor, r.primary, trailing: "   ")
                part(style.secondaryGlyph, style.secondaryColor, r.secondary)
            case .single:
                part(style.primaryGlyph, style.primaryColor, r.primary)
            }
            s.draw(at: NSPoint(x: labels.minX, y: labels.minY + 1))
        }
    }

    /// A bar with its far end rounded (top for ↓ bars, bottom for ↑ bars).
    private func roundedTop(_ r: NSRect, up: Bool) -> NSBezierPath {
        let radius = min(r.width / 2, 2)
        let p = NSBezierPath()
        if up {
            p.move(to: NSPoint(x: r.minX, y: r.minY))
            p.line(to: NSPoint(x: r.minX, y: r.maxY - radius))
            p.appendArc(withCenter: NSPoint(x: r.minX + radius, y: r.maxY - radius), radius: radius, startAngle: 180, endAngle: 90, clockwise: true)
            p.line(to: NSPoint(x: r.maxX - radius, y: r.maxY))
            p.appendArc(withCenter: NSPoint(x: r.maxX - radius, y: r.maxY - radius), radius: radius, startAngle: 90, endAngle: 0, clockwise: true)
            p.line(to: NSPoint(x: r.maxX, y: r.minY))
        } else {
            p.move(to: NSPoint(x: r.minX, y: r.maxY))
            p.line(to: NSPoint(x: r.minX, y: r.minY + radius))
            p.appendArc(withCenter: NSPoint(x: r.minX + radius, y: r.minY + radius), radius: radius, startAngle: 180, endAngle: 270, clockwise: false)
            p.line(to: NSPoint(x: r.maxX - radius, y: r.minY))
            p.appendArc(withCenter: NSPoint(x: r.maxX - radius, y: r.minY + radius), radius: radius, startAngle: 270, endAngle: 360, clockwise: false)
            p.line(to: NSPoint(x: r.maxX, y: r.maxY))
        }
        p.close()
        return p
    }

    // MARK: Hover

    /// For `--dump-chart`.
    func simulateHover(at index: Int) { hoverIndex = index }

    /// The menu closing does not send `mouseExited`, so the controller calls this to
    /// avoid a stale highlighted bar the next time it opens.
    func clearHover() {
        if hoverIndex != nil { hoverIndex = nil; needsDisplay = true }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let i = index(at: p.x)
        if i != hoverIndex { hoverIndex = i; needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        if hoverIndex != nil { hoverIndex = nil; needsDisplay = true }
    }

    // A click on the chart shouldn't close the menu (or do anything).
    override func mouseUp(with event: NSEvent) {}
    override func mouseDown(with event: NSEvent) {}
}
