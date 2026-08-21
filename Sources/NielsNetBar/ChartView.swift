import AppKit

/// The throughput history chart at the top of the menu: one bar per second for the last
/// minute, mirrored around a baseline — green ↓ grows up, blue ↑ grows down — on a single
/// linear scale set by the window's peak. Hovering a bar shows that second's numbers.
final class ChartView: NSView {

    static let chartHeight: CGFloat = 64
    private static let insetX: CGFloat = 14     // lines up with the menu rows' text
    private static let insetY: CGFloat = 4
    private static let gap: CGFloat = 1
    private static let labelFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)

    var history: () -> [NetworkMonitor.Rate] = { [] }
    /// `--dump-chart` only: paint a menu-like background so the light text is visible.
    var debugBackground = false
    private var hoverIndex: Int?
    private var tracking: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        autoresizingMask = [.width]
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }

    // MARK: Layout

    private static let labelStrip: CGFloat = 13  // labels live above the bars, not on them

    private var plotRect: NSRect {
        var r = bounds.insetBy(dx: ChartView.insetX, dy: ChartView.insetY)
        r.size.height -= ChartView.labelStrip
        return r
    }

    private var labelRect: NSRect {
        NSRect(x: plotRect.minX, y: plotRect.maxY, width: plotRect.width, height: ChartView.labelStrip)
    }

    private var barWidth: CGFloat {
        let n = CGFloat(NetworkMonitor.historyLength)
        return (plotRect.width - (n - 1) * ChartView.gap) / n
    }

    /// Bar index (0 = oldest) under an x coordinate, if any.
    private func index(at x: CGFloat) -> Int? {
        let rel = x - plotRect.minX
        guard rel >= 0 else { return nil }
        let i = Int(rel / (barWidth + ChartView.gap))
        return i < NetworkMonitor.historyLength ? i : nil
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        if debugBackground { NSColor(white: 0.13, alpha: 1).setFill(); bounds.fill() }
        let plot = plotRect
        let samples = history()
        let n = NetworkMonitor.historyLength
        // Right-align: the newest second is the rightmost bar.
        let offset = n - samples.count
        let peak = max(samples.map { max($0.down, $0.up) }.max() ?? 0, 1_000)  // ≥ 1 kbps so idle isn't a wall of full bars
        let half = plot.height / 2 - 1
        let baseline = plot.midY
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
            let down = max(2, half * CGFloat(r.down / peak))
            let up = max(2, half * CGFloat(r.up / peak))
            StatusBarController.downColor.withAlphaComponent(r.down > 0 ? alpha : 0.25).setFill()
            roundedTop(NSRect(x: x, y: baseline + 1, width: bw, height: down), up: true).fill()
            StatusBarController.upColor.withAlphaComponent(r.up > 0 ? alpha : 0.25).setFill()
            roundedTop(NSRect(x: x, y: baseline - 1 - up, width: bw, height: up), up: false).fill()
        }

        // Peak label, top-right; hover readout, top-left.
        let labelAttrs: [NSAttributedString.Key: Any] = [.font: ChartView.labelFont, .foregroundColor: NSColor.secondaryLabelColor]
        let peakText = NSAttributedString(string: "peak \(Format.rateCompact(bitsPerSecond: peak))", attributes: labelAttrs)
        let labels = labelRect
        peakText.draw(at: NSPoint(x: labels.maxX - peakText.size().width, y: labels.minY + 1))

        if let h = hoverIndex, h - offset >= 0, h - offset < samples.count {
            let r = samples[h - offset]
            let age = n - 1 - h
            let s = NSMutableAttributedString(string: age == 0 ? "now   " : "−\(age) s   ", attributes: labelAttrs)
            s.append(NSAttributedString(string: "↓ ", attributes: [.font: ChartView.labelFont, .foregroundColor: StatusBarController.downColor]))
            s.append(NSAttributedString(string: Format.rateCompact(bitsPerSecond: r.down) + "   ", attributes: [.font: ChartView.labelFont, .foregroundColor: NSColor.labelColor]))
            s.append(NSAttributedString(string: "↑ ", attributes: [.font: ChartView.labelFont, .foregroundColor: StatusBarController.upColor]))
            s.append(NSAttributedString(string: Format.rateCompact(bitsPerSecond: r.up), attributes: [.font: ChartView.labelFont, .foregroundColor: NSColor.labelColor]))
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
