// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

/// One widget's status item and dropdown: the bar image, the menu lifecycle, and the row
/// and action plumbing every widget's menu shares.
@MainActor
final class WidgetController: NSObject, NSMenuDelegate {

    let widget: any Widget
    private unowned let widgets: Widgets
    private let item: NSStatusItem
    private let menu = NSMenu()
    private(set) var menuOpen = false

    /// What was last drawn into the bar. A tick that would draw the same thing skips the
    /// image rebuild and the status-item redraw that comes with it — see `updateBar`.
    private var lastLines: [BarLine] = []
    private var lastSpark: [Sample] = []
    private var lastGauge: BarGauge?

    init(widget: any Widget, widgets: Widgets) {
        self.widget = widget
        self.widgets = widgets
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        // Remembers the slot the user ⌘-dragged this item to, per widget.
        item.autosaveName = "NimbusNetBar.\(widget.id)"
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        item.button?.toolTip = widget.barToolTip
        widget.host = self
        widget.sampler.onTick = { [weak self] in self?.tick() }
        updateBar(force: true)
    }

    /// The widget was switched off: take its status item out of the bar.
    func dispose() {
        widget.sampler.onTick = nil
        widget.host = nil
        NSStatusBar.system.removeStatusItem(item)
    }

    // MARK: Bar

    private func tick() {
        if !widgets.isHidden { updateBar() }
        guard menuOpen else { return }
        widget.updateOpenMenu()
    }

    /// Repaint the status item — but only when it would actually look different, and for
    /// a widget with a sparkline no more than once a second.
    ///
    /// Repainting is the most expensive thing this app does. Setting `button.image` means
    /// text layout, a rasterise, `_adjustLength`, a CA commit and a round trip to the window
    /// server; measured here, a CPU widget that followed its (constantly changing) number at
    /// 2 Hz cost **1.8 points of CPU more than the whole rest of the app**, most of it system
    /// time that `sample` cannot see because the process is parked in `mach_msg` for it.
    ///
    /// So: any widget backed by a history repaints only when a one-second bucket closes,
    /// and then only if what it shows actually moved. That includes the rate pairs — the
    /// network's number changes on nearly every tick when there is traffic, and following it
    /// at 2 Hz (or 5 Hz) bought nothing but repaints. A widget with no history at all (disk
    /// capacity) repaints whenever its content changes, which is a few times a day.
    ///
    /// The consequence is that every number in the bar updates once a second at most,
    /// whatever the sample rate. Sampling still runs at the chosen rate and the menus show
    /// every bit of it.
    func updateBar(force: Bool = false) {
        let content = widget.barContent()
        var redraw = force
        if !redraw {
            let changed = content.lines != lastLines
                || content.gauge != lastGauge
                || (content.spark != nil && widget.sampler.history != lastSpark)
            redraw = widget.sampler.keepsHistory
                ? (widget.sampler.historyAdvanced && changed)
                : changed
        }
        guard redraw else { return }
        lastLines = content.lines
        lastGauge = content.gauge
        if content.spark != nil { lastSpark = widget.sampler.history }
        let image = content.lines.count > 1 ? stackedImage(content.lines) : scalarImage(content)
        image.isTemplate = false
        item.button?.image = image
        item.button?.imagePosition = .imageOnly
        item.button?.title = ""
        if let tip = content.toolTip { item.button?.toolTip = tip }
    }

    /// A rate pair: two lines, the first above the second. Rendered into an image rather
    /// than set as a multi-line title — NSStatusBarButton centres a single line and lets a
    /// second one hang off the bottom, whereas an image is centred as a block.
    private func stackedImage(_ lines: [BarLine]) -> NSImage {
        let font = Theme.stackedFont
        let strings = lines.map { line -> NSAttributedString in
            let s = NSMutableAttributedString(string: line.glyph, attributes: [.font: font, .foregroundColor: line.glyphColor])
            s.append(NSAttributedString(string: " " + line.value, attributes: [.font: font, .foregroundColor: Theme.barTextColor]))
            return s
        }
        let lh = Theme.stackedLineHeight
        let width = ceil(strings.map { $0.size().width }.max() ?? 0) + 2
        return NSImage(size: NSSize(width: width, height: lh * CGFloat(lines.count)), flipped: true) { _ in
            for (i, l) in strings.enumerated() { l.draw(at: NSPoint(x: 1, y: CGFloat(i) * lh)) }
            return true
        }
    }

    private static let barHeight: CGFloat = 21
    private static let sparkSize = NSSize(width: 32, height: 11)
    private static let sparkGap: CGFloat = 4
    /// A pie is square, so it needs far less width than a sparkline's strip.
    private static let pieDiameter: CGFloat = 13

    /// A scalar: the label as a column of letters, then whatever the widget wants beside it
    /// — a sparkline, a pie, and a number only if it asked for one.
    private func scalarImage(_ content: BarContent) -> NSImage {
        let line = content.lines.first ?? BarLine(glyph: "", glyphColor: .clear, value: "")
        let letters = line.glyph.map {
            NSAttributedString(string: String($0), attributes: [
                .font: Theme.stackedLabelFont, .foregroundColor: line.glyphColor])
        }
        let labelWidth = ceil(letters.map { $0.size().width }.max() ?? 0)

        let value = NSAttributedString(string: line.value, attributes: [
            .font: Theme.scalarFont, .foregroundColor: Theme.barTextColor])
        let valueWidth = line.value.isEmpty ? 0 : ceil(value.size().width)
        let valueSize = value.size()

        let spark = content.spark
        let gauge = content.gauge
        let sideSize = spark != nil
            ? WidgetController.sparkSize
            : (gauge != nil ? NSSize(width: WidgetController.pieDiameter, height: WidgetController.pieDiameter) : .zero)

        let gap = WidgetController.sparkGap
        var width: CGFloat = 1 + labelWidth
        if valueWidth > 0 { width += gap + valueWidth }
        if sideSize.width > 0 { width += gap + sideSize.width }
        width += 2

        let history = spark == nil ? [] : widget.sampler.history
        return NSImage(size: NSSize(width: width, height: WidgetController.barHeight), flipped: false) { rect in
            // The letter column, centred as a block in the bar's height.
            let lh = Theme.stackedLabelLineHeight
            let top = (rect.height + lh * CGFloat(letters.count)) / 2
            for (i, letter) in letters.enumerated() {
                let w = letter.size().width
                letter.draw(at: NSPoint(x: 1 + (labelWidth - w) / 2, y: top - lh * CGFloat(i + 1)))
            }
            var x = 1 + labelWidth
            if valueWidth > 0 {
                x += gap
                value.draw(at: NSPoint(x: x, y: (rect.height - valueSize.height) / 2))
                x += valueWidth
            }
            if sideSize.width > 0 {
                x += gap
                let side = NSRect(x: x, y: (rect.height - sideSize.height) / 2,
                                  width: sideSize.width, height: sideSize.height)
                if let s = spark {
                    WidgetController.drawSpark(history, style: s, in: side)
                } else if let g = gauge {
                    WidgetController.drawPie(g, in: side)
                }
            }
            return true
        }
    }

    /// The bar's sparkline: the same one-second buckets the menu's chart draws, as a filled
    /// area with a line along the top. Sixty buckets in 32 pt is under a device pixel each,
    /// so bars are not an option here — the shape is what carries the information.
    private static func drawSpark(_ history: [Sample], style: SparkStyle, in rect: NSRect) {
        let n = History.length
        guard !history.isEmpty else { return }
        let peak = style.fixedPeak ?? max(history.map(\.primary).max() ?? 0, .leastNormalMagnitude)
        guard peak > 0 else { return }
        let step = rect.width / CGFloat(n - 1)
        // Right-aligned: the newest bucket sits at the right edge.
        let offset = n - history.count
        func point(_ i: Int, _ v: Double) -> NSPoint {
            NSPoint(x: rect.minX + CGFloat(i + offset) * step,
                    y: rect.minY + rect.height * CGFloat(min(max(v / peak, 0), 1)))
        }
        let line = NSBezierPath()
        line.move(to: point(0, history[0].primary))
        for (i, s) in history.enumerated().dropFirst() { line.line(to: point(i, s.primary)) }

        let area = line.copy() as! NSBezierPath
        area.line(to: NSPoint(x: point(history.count - 1, 0).x, y: rect.minY))
        area.line(to: NSPoint(x: point(0, 0).x, y: rect.minY))
        area.close()
        style.color.withAlphaComponent(0.35).setFill()
        area.fill()

        style.color.setStroke()
        line.lineWidth = 1
        line.lineJoinStyle = .round
        line.stroke()
    }

    /// A pie: a faint whole circle with the used fraction filled in as a wedge from twelve
    /// o'clock, clockwise, and a thin outline to hold it together at this size.
    private static func drawPie(_ gauge: BarGauge, in rect: NSRect) {
        let side = min(rect.width, rect.height)
        let circle = NSRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
        gauge.color.withAlphaComponent(0.22).setFill()
        NSBezierPath(ovalIn: circle).fill()

        let fraction = min(max(gauge.fraction, 0), 1)
        if fraction > 0.004 {
            let centre = NSPoint(x: circle.midX, y: circle.midY)
            let wedge = NSBezierPath()
            wedge.move(to: centre)
            wedge.appendArc(withCenter: centre, radius: side / 2,
                            startAngle: 90, endAngle: 90 - 360 * CGFloat(fraction), clockwise: true)
            wedge.close()
            gauge.color.setFill()
            wedge.fill()
        }
        gauge.color.withAlphaComponent(0.55).setStroke()
        let outline = NSBezierPath(ovalIn: circle.insetBy(dx: 0.5, dy: 0.5))
        outline.lineWidth = 1
        outline.stroke()
    }

    /// Render the status button itself (for checking the layout without a screen grab).
    func dumpBar(to path: String) -> Bool {
        guard let b = item.button, let rep = b.bitmapImageRepForCachingDisplay(in: b.bounds) else { return false }
        b.cacheDisplay(in: b.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }

    /// `--print-menu`: build the menu as if it were opening and return its rows as text.
    /// Checks what `buildMenu` produces without needing Accessibility to click the real one.
    func dumpMenu() -> String {
        menuNeedsUpdate(menu)
        var out: [String] = []
        for (i, it) in menu.items.enumerated() {
            if it.isSeparatorItem { out.append("  ---"); continue }
            if it.view != nil { out.append("  [view: \(type(of: it.view!))]"); continue }
            let text = it.attributedTitle?.string ?? it.title
            var flags: [String] = []
            if it.isHidden { flags.append("hidden") }
            if !it.isEnabled { flags.append("disabled") }
            if it.submenu != nil { flags.append("submenu: " + (it.submenu?.items.map(\.title).joined(separator: ", ") ?? "")) }
            let suffix = flags.isEmpty ? "" : "   (\(flags.joined(separator: "; ")))"
            out.append(String(format: "%3d. ", i) + text.replacingOccurrences(of: "\n", with: " ⏎ ") + suffix)
        }
        return out.joined(separator: "\n")
    }

    // MARK: Menu lifecycle

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        widget.buildMenu(into: menu, host: self)
        appendSharedTail(to: menu)
    }

    func menuWillOpen(_ menu: NSMenu) { menuOpen = true }

    func menuDidClose(_ menu: NSMenu) {
        menuOpen = false
        widget.menuDidClose()
    }

    /// Everything every widget's menu ends with.
    private func appendSharedTail(to menu: NSMenu) {
        menu.addItem(.separator())

        let widgetsItem = NSMenuItem(title: "Widgets", action: nil, keyEquivalent: "")
        widgetsItem.submenu = widgets.buildSubmenu()
        menu.addItem(widgetsItem)

        let rate = NSMenuItem(title: "Update Rate", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let currentHz = 1 / widgets.ticker.interval
        for hz in Widgets.hzOptions {
            let it = NSMenuItem(title: Widgets.rateTitle(hz), action: #selector(setRate(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = hz
            it.state = abs(hz - currentHz) < 0.01 ? .on : .off
            sub.addItem(it)
        }
        rate.submenu = sub
        menu.addItem(rate)

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin(_:)), keyEquivalent: "")
        login.target = self
        login.state = LoginItem.isEnabled ? .on : .off
        if LoginItem.status == .requiresApproval {
            login.title = "Launch at Login (approve in System Settings)"
        }
        if !Bundle.main.bundlePath.hasPrefix("/Applications/") {
            login.toolTip = "This copy runs from \(Bundle.main.bundlePath). Registering it as a Login Item points the Login Item at this path — use ./build.sh install for the real thing."
        }
        menu.addItem(login)

        for it in widget.settingsItems(host: self) { menu.addItem(it) }
        menu.addItem(.separator())

        // Version, dim and small, just above Quit. Click to copy — the first thing a bug
        // report needs. Falls back to "dev build" when running the bare binary (no bundle).
        let versionText = WidgetController.versionString()
        let version = NSMenuItem(title: versionText, action: #selector(copyValue(_:)), keyEquivalent: "")
        version.target = self
        version.representedObject = versionText
        version.toolTip = "Click to copy"
        version.attributedTitle = NSAttributedString(string: versionText, attributes: [
            .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor])
        menu.addItem(version)

        let quit = NSMenuItem(title: "Quit \(WidgetController.appName())", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    // MARK: Shared rows

    /// "Label  value" row; click copies `copy` (or does nothing if nil).
    func row(label: String, value: String, copy: String?, valueColor: NSColor = .labelColor) -> NSMenuItem {
        let it = NSMenuItem()
        setRow(it, label: label, value: value, copy: copy, valueColor: valueColor)
        return it
    }

    /// (Re)fill an existing row — used for the ones that change while the menu is open.
    func setRow(_ it: NSMenuItem, label: String, value: String, copy: String?, valueColor: NSColor = .labelColor,
                toolTip: String? = nil) {
        it.title = "\(label) \(value)"
        it.action = copy == nil ? nil : #selector(copyValue(_:))
        it.target = self
        it.indentationLevel = 1
        it.representedObject = copy
        let labelText = label + "  "
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.menuFont(ofSize: 0), .foregroundColor: NSColor.secondaryLabelColor]
        let s = NSMutableAttributedString()
        s.append(NSAttributedString(string: labelText, attributes: labelAttrs))
        // A value may carry a second line (the Location notice). Indent it under the first
        // and dim it, so it reads as a continuation rather than another row.
        let lines = value.components(separatedBy: "\n")
        s.append(NSAttributedString(string: lines[0], attributes: [
            .font: Theme.monoFont, .foregroundColor: valueColor]))
        if lines.count > 1 {
            let indent = NSAttributedString(string: labelText, attributes: labelAttrs).size().width
            let ps = NSMutableParagraphStyle()
            ps.firstLineHeadIndent = indent
            ps.headIndent = indent
            ps.paragraphSpacingBefore = 2
            s.append(NSAttributedString(string: "\n" + lines.dropFirst().joined(separator: "\n"), attributes: [
                .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: ps]))
        }
        it.attributedTitle = s
        it.toolTip = toolTip ?? (copy == nil ? nil : "Click to copy")
    }

    /// A block of `count` rows for a "busiest processes" list.
    ///
    /// The rows are created once and **never hidden**, however little there is to show. A
    /// list that appears and disappears as processes cross the threshold resizes the menu
    /// while it is open, which slides everything below it out from under the pointer just as
    /// the user is clicking — the list is refreshed once a second, so this happened
    /// constantly. Blank rows keep the block, and the menu, exactly the same height.
    func makeTopRows(_ count: Int, into menu: NSMenu) -> [NSMenuItem] {
        (0..<count).map { _ in
            let it = NSMenuItem()
            // Built like a filled row, so an empty one is exactly the same height.
            setTableRow(it, label: " ", value: " ")
            it.isEnabled = false
            menu.addItem(it)
            return it
        }
    }

    /// Fill a `makeTopRows` block. Entries past the end become blanks rather than vanishing;
    /// when there is nothing at all, the first row says so and the rest stay blank.
    func fillTopRows(_ rows: [NSMenuItem], entries: [(value: String, name: String)], empty: String) {
        for (i, it) in rows.enumerated() {
            if i < entries.count {
                setTableRow(it, label: entries[i].name, value: entries[i].value)
            } else if i == 0 {
                setTableRow(it, label: empty, value: "", valueColor: .tertiaryLabelColor)
            } else {
                setTableRow(it, label: " ", value: " ")
            }
            it.isEnabled = false
        }
    }

    /// A section heading: small, semibold, dim, left-aligned with everything else.
    ///
    /// Deliberately quiet. An earlier version was centred, uppercase and in the accent
    /// colour — which looked like a different application's menu bolted onto this one. The
    /// separator above a header already does the dividing; the header only has to name the
    /// block, so it sits in the same left margin and the same restrained palette as every
    /// other row.
    func sectionHeader(_ title: String) -> NSMenuItem {
        let it = NSMenuItem()
        it.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize).withWeight(.semibold),
            .foregroundColor: NSColor.secondaryLabelColor])
        it.isEnabled = false
        return it
    }

    /// Where a table row's value is right-aligned to. Fixed rather than derived: a menu item
    /// cannot know how wide the menu will end up, and this is comfortably inside the width
    /// the chart already forces, so no row can widen the menu by itself.
    ///
    /// Which rows get this treatment is a rule, not a taste: **a value that is a quantity is
    /// right-aligned so a column of them can be compared at a glance; a value that is an
    /// identifier — an IP address, an SSID, a MAC — stays left-aligned next to its label**,
    /// because there is nothing to compare and a ragged left edge just makes it harder to
    /// read. That is why the network menu keeps `setRow` and the metric widgets use this.
    static let tableTabStop: CGFloat = 330

    /// "Label ............ value", with the value pushed right. `swatch` puts a small
    /// colour chip in front of the label, for rows that key a segment of a bar.
    func setTableRow(_ it: NSMenuItem, label: String, value: String, swatch: NSColor? = nil,
                     copy: String? = nil, valueColor: NSColor = .labelColor, toolTip: String? = nil) {
        it.title = "\(label) \(value)"
        it.action = copy == nil ? nil : #selector(copyValue(_:))
        it.target = self
        it.representedObject = copy
        it.image = swatch.map { WidgetController.swatchImage($0) }
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .right, location: WidgetController.tableTabStop)]
        let s = NSMutableAttributedString(string: label + "\t", attributes: [
            .font: NSFont.menuFont(ofSize: 0),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: style])
        s.append(NSAttributedString(string: value, attributes: [
            .font: Theme.monoFont, .foregroundColor: valueColor, .paragraphStyle: style]))
        it.attributedTitle = s
        it.toolTip = toolTip ?? (copy == nil ? nil : "Click to copy")
    }

    func tableRow(label: String, value: String, swatch: NSColor? = nil, copy: String? = nil,
                  valueColor: NSColor = .labelColor, toolTip: String? = nil) -> NSMenuItem {
        let it = NSMenuItem()
        setTableRow(it, label: label, value: value, swatch: swatch, copy: copy,
                    valueColor: valueColor, toolTip: toolTip)
        return it
    }

    /// A small rounded colour chip, for keying a row to a segment of a bar.
    static func swatchImage(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            color.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 2, yRadius: 2).fill()
            return true
        }
    }

    func disabled(_ title: String) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.isEnabled = false
        return it
    }

    /// A row whose click copies `value`; the widget owns everything about how it reads.
    func copyRow(_ title: NSAttributedString, copy: String?, toolTip: String? = nil) -> NSMenuItem {
        let it = NSMenuItem(title: "", action: copy == nil ? nil : #selector(copyValue(_:)), keyEquivalent: "")
        it.target = self
        it.attributedTitle = title
        it.representedObject = copy
        it.toolTip = toolTip
        return it
    }

    /// "Nimbus Net Bar v1.2 (23)" — marketing version plus the build number, which is the
    /// commit count, so a report pins down the exact source it came from.
    static func versionString() -> String {
        let info = Bundle.main.infoDictionary
        let name = appName()
        guard let short = info?["CFBundleShortVersionString"] as? String else { return "\(name) — dev build" }
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(name) v\(short) (\($0))" } ?? "\(name) v\(short)"
    }

    static func appName() -> String {
        Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "Nimbus Net Bar"
    }

    // MARK: Actions

    @objc func copyValue(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? String else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }

    @objc private func setRate(_ sender: NSMenuItem) {
        guard let hz = sender.representedObject as? Double, hz > 0 else { return }
        widgets.ticker.interval = 1 / hz
        UserDefaults.standard.set(hz, forKey: Widgets.hzDefaultsKey)
    }

    @objc private func toggleLogin(_ sender: NSMenuItem) {
        let turnOn = !LoginItem.isEnabled
        UserDefaults.standard.set(true, forKey: LoginItem.registeredDefaultsKey)   // the user decided; never auto-register again
        do {
            try LoginItem.setEnabled(turnOn)
        } catch {
            NSLog("Login item: \(error)")
            let alert = NSAlert()
            alert.messageText = turnOn ? "Could not enable Launch at Login" : "Could not disable Launch at Login"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}

extension NSFont {
    func withWeight(_ weight: NSFont.Weight) -> NSFont {
        NSFont.systemFont(ofSize: pointSize, weight: weight)
    }
}
