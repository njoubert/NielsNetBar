// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

/// The headline at the top of the menu: the summed rate in two large columns, download then
/// upload, each with a caption under it.
///
/// A view rather than an `NSMenuItem` title because the columns have to be placed against the
/// menu's *actual* width, and nothing knows that until AppKit has laid the menu out. Tab stops
/// in an attributed title have to be computed up front, so they were sized against the chart's
/// width — but the widest row in this menu is whichever public IPv6 address happens to be
/// there (367 pt against the chart's 324), so the columns ended up stranded in the left of a
/// wider menu with dead space beside them. With `autoresizingMask = [.width]` this view is
/// handed the real width and splits it in half.
///
/// Same trap as `ChartView`, and the same fix: because the instance is reused across opens,
/// the stretched frame would become the menu's new minimum and the menu could only ever get
/// wider. `NetworkWidget.buildMenu` resets the frame first.
final class TotalsView: NSView {

    static let height: CGFloat = 54
    /// Matches `ChartView.insetX`, so the block lines up with the panel under it.
    private static let insetX: CGFloat = 14
    private static let figureFont = NSFont.monospacedDigitSystemFont(ofSize: 23, weight: .medium)
    private static let captionFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    private static let gap: CGFloat = 6
    private static let captionGap: CGFloat = 2

    /// Read at draw time so the row keeps up with the timer without being rebuilt.
    var rate: () -> NetworkMonitor.Rate = { NetworkMonitor.Rate() }
    /// What a click copies.
    var copyText: () -> String = { "" }

    override init(frame: NSRect) {
        super.init(frame: frame)
        autoresizingMask = [.width]
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }

    // MARK: Layout

    /// The fixed slots inside one column: the arrow, a field reserved for the widest number
    /// `Format.rateHeadline` can return, then the unit. The number is right-aligned into its
    /// field, so the arrow and the unit stay at a constant x and only the digits change —
    /// laying the column out around the current text instead makes the arrows visibly slide
    /// left and right as the rate crosses 9.9 / 16.4 / 115.
    private static let slot: (arrow: CGFloat, number: CGFloat, unit: CGFloat, width: CGFloat) = {
        func width(_ s: String, _ font: NSFont) -> CGFloat {
            ceil(NSAttributedString(string: s, attributes: [.font: font]).size().width)
        }
        let f = figureFont
        let arrow = max(width("↑", f), width("↓", f))
        let number = width("99.9", f)
        let unit = ["kbps", "Mbps", "Gbps"].map { width($0, f) }.max() ?? 0
        return (arrow, number, unit, arrow + gap + number + gap + unit)
    }()

    /// Centre of each column: the content width split in two.
    private func columnCentre(_ i: Int) -> CGFloat {
        let content = bounds.width - TotalsView.insetX * 2
        return TotalsView.insetX + content * (i == 0 ? 0.25 : 0.75)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let r = rate()
        drawColumn(0, arrow: "↓", color: Theme.downColor, bps: r.down, caption: "Download")
        drawColumn(1, arrow: "↑", color: Theme.upColor, bps: r.up, caption: "Upload")
    }

    private func drawColumn(_ i: Int, arrow: String, color: NSColor, bps: Double, caption: String) {
        let slot = TotalsView.slot
        let (value, unit) = Format.rateHeadline(bitsPerSecond: bps)
        // The slot is a constant width, so centring *it* keeps every fixed part fixed.
        let left = columnCentre(i) - slot.width / 2
        let figureAttrs: [NSAttributedString.Key: Any] = [
            .font: TotalsView.figureFont, .foregroundColor: NSColor.labelColor]

        let baseline = bounds.height - TotalsView.figureFont.ascender - 6
        NSAttributedString(string: arrow, attributes: [
            .font: TotalsView.figureFont, .foregroundColor: color])
            .draw(at: NSPoint(x: left, y: baseline))

        let number = NSAttributedString(string: value, attributes: figureAttrs)
        let numberRight = left + slot.arrow + TotalsView.gap + slot.number
        number.draw(at: NSPoint(x: numberRight - ceil(number.size().width), y: baseline))

        NSAttributedString(string: unit, attributes: figureAttrs)
            .draw(at: NSPoint(x: numberRight + TotalsView.gap, y: baseline))

        // Caption, centred under the column rather than under the slot: with the slot's
        // trailing slack the two would not agree, and the caption is what the eye lines up.
        let label = NSAttributedString(string: caption, attributes: [
            .font: TotalsView.captionFont, .foregroundColor: NSColor.secondaryLabelColor])
        let size = label.size()
        label.draw(at: NSPoint(x: columnCentre(i) - ceil(size.width) / 2,
                               y: baseline - size.height - TotalsView.captionGap))
    }

    // MARK: Click to copy

    override func mouseDown(with event: NSEvent) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(copyText(), forType: .string)
        // A menu item's own click dismisses the menu; a view has to do it itself.
        enclosingMenuItem?.menu?.cancelTracking()
    }
}
