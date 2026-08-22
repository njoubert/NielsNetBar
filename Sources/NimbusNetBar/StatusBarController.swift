// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

/// The status item (two stacked lines of throughput) and its dropdown menu.
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {

    static let hzOptions: [Double] = [1, 2, 5]
    static let hzDefaultsKey = "updateHz"

    private let item: NSStatusItem
    private let menu = NSMenu()
    private let monitor: NetworkMonitor
    private var snapshot = NetworkSnapshot()
    private var menuOpen = false

    // Rows that update live while the menu is open.
    private var totalRow: NSMenuItem?
    /// The chart's natural width. It carries `autoresizingMask = [.width]`, so AppKit stretches
    /// it to whatever the menu is wide; because the same view is reused on every open, that
    /// stretched frame would become the menu's new minimum and the menu could only ever grow
    /// (measured: 633 pt → 649 pt on the next open). `rebuild()` resets it to this.
    private static let chartWidth: CGFloat = 384
    private let chart = ChartView(frame: NSRect(x: 0, y: 0, width: chartWidth, height: ChartView.chartHeight))
    private var rateRows: [String: NSMenuItem] = [:]
    private var ssidRows: [String: NSMenuItem] = [:]   // Wi-Fi bsd name → its SSID row
    private var totalsRow: NSMenuItem?
    private var publicV4Row: NSMenuItem?
    private var publicV6Row: NSMenuItem?

    /// The two lines last drawn into the bar; a tick that would draw the same text skips
    /// the image rebuild and the status-item redraw that comes with it.
    private var lastBarText: [String] = []
    /// Why nobody can see the menu bar right now: displays asleep, screen locked, or
    /// another user's session in front. While any apply, sampling continues (the chart
    /// and the totals stay honest) but the bar is not repainted.
    private var hiddenReasons: Set<String> = []
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    init(monitor: NetworkMonitor) {
        self.monitor = monitor
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        item.button?.toolTip = "Nimbus Net Bar — network throughput"
        chart.history = { [weak self] in self?.monitor.history ?? [] }
        monitor.onTick = { [weak self] in self?.tick() }
        PublicIP.shared.onChange = { [weak self] in self?.updatePublicIPRows() }
        // Granting Location access mid-menu reveals the SSID: update that row in place
        // rather than rebuilding a menu that is being tracked (flicker, lost hover).
        LocationAccess.shared.onChange = { [weak self] in self?.updateSSIDRows() }
        observeVisibility()
        updateBar()
    }

    deinit {
        for (center, token) in observers { center.removeObserver(token) }
    }

    // MARK: Visibility

    /// Pause bar repaints while the menu bar is not on screen. A long-running app spends
    /// most of its life behind a locked screen or a sleeping display; painting two lines of
    /// text into the status bar twice a second there is the single biggest waste.
    private func observeVisibility() {
        let ws = NSWorkspace.shared.notificationCenter
        let dnc = DistributedNotificationCenter.default()
        func watch(_ center: NotificationCenter, _ name: Notification.Name, hidden: Bool, reason: String) {
            let o = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setHidden(hidden, reason: reason) }
            }
            observers.append((center, o))
        }
        watch(ws, NSWorkspace.screensDidSleepNotification, hidden: true, reason: "displays")
        watch(ws, NSWorkspace.screensDidWakeNotification, hidden: false, reason: "displays")
        watch(ws, NSWorkspace.sessionDidResignActiveNotification, hidden: true, reason: "session")
        watch(ws, NSWorkspace.sessionDidBecomeActiveNotification, hidden: false, reason: "session")
        watch(dnc, Notification.Name("com.apple.screenIsLocked"), hidden: true, reason: "lock")
        watch(dnc, Notification.Name("com.apple.screenIsUnlocked"), hidden: false, reason: "lock")
    }

    private func setHidden(_ hidden: Bool, reason: String) {
        let wasHidden = !hiddenReasons.isEmpty
        if hidden { hiddenReasons.insert(reason) } else { hiddenReasons.remove(reason) }
        if wasHidden, hiddenReasons.isEmpty { updateBar() }   // catch up right away
    }

    /// Render the status button itself (for checking the two-line layout without a screen grab).
    func dumpBar(to path: String) -> Bool {
        guard let b = item.button, let rep = b.bitmapImageRepForCachingDisplay(in: b.bounds) else { return false }
        b.cacheDisplay(in: b.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }

    // MARK: Bar

    private static let barFont = NSFont.monospacedSystemFont(ofSize: 9, weight: .medium)
    private static let barLineHeight: CGFloat = 10.5   // two lines → 21 pt inside the 22 pt bar
    /// Grey digits: a fixed mid-grey per appearance rather than the label colour with alpha,
    /// which on a dark bar comes out nearly white. Tune the two `white:` values to taste.
    private static let barTextColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 0.55, alpha: 1)
            : NSColor(white: 0.40, alpha: 1)
    }

    static let downColor = NSColor.systemGreen
    static let upColor = NSColor.systemBlue

    /// The bar shows ↑ upload on top and ↓ download below. The two lines are rendered into an
    /// image rather than set as a multi-line title: NSStatusBarButton centres a single line
    /// and lets a second one hang off the bottom, whereas an image is centred as a block.
    /// Green ↓ / blue ↑; the digits are grey, resolved at draw time against the bar's
    /// light/dark appearance (`barTextColor`).
    private func updateBar() {
        let values = [Format.rateFixed(bitsPerSecond: monitor.total.up),
                      Format.rateFixed(bitsPerSecond: monitor.total.down)]
        guard values != lastBarText else { return }
        lastBarText = values

        let font = StatusBarController.barFont
        let text = StatusBarController.barTextColor
        func line(_ arrow: String, _ color: NSColor, _ value: String) -> NSAttributedString {
            let s = NSMutableAttributedString(string: arrow, attributes: [.font: font, .foregroundColor: color])
            s.append(NSAttributedString(string: " " + value, attributes: [.font: font, .foregroundColor: text]))
            return s
        }
        let lines = [
            line("↑", StatusBarController.upColor, values[0]),
            line("↓", StatusBarController.downColor, values[1]),
        ]
        let lh = StatusBarController.barLineHeight
        let width = ceil(lines.map { $0.size().width }.max() ?? 0) + 2
        let image = NSImage(size: NSSize(width: width, height: lh * 2), flipped: true) { _ in
            for (i, l) in lines.enumerated() { l.draw(at: NSPoint(x: 1, y: CGFloat(i) * lh)) }
            return true
        }
        image.isTemplate = false
        item.button?.image = image
        item.button?.imagePosition = .imageOnly
        item.button?.title = ""
    }

    private func tick() {
        if hiddenReasons.isEmpty { updateBar() }
        guard menuOpen else { return }
        totalRow?.attributedTitle = totalTitle()
        chart.needsDisplay = true
        for (bsd, row) in rateRows {
            row.attributedTitle = rateTitle(bsd)
        }
        totalsRow?.attributedTitle = totalsTitle()
    }

    // MARK: Menu lifecycle

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild()
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
    }

    func menuDidClose(_ menu: NSMenu) {
        menuOpen = false
        chart.clearHover()
    }

    private func rebuild() {
        menu.removeAllItems()
        // Shrink the chart back to its natural width before measuring, or the menu inherits
        // the width of whatever the widest row was last time and never gets narrower again.
        chart.setFrameSize(NSSize(width: StatusBarController.chartWidth, height: ChartView.chartHeight))
        rateRows = [:]
        ssidRows = [:]
        totalRow = nil
        totalsRow = nil
        publicV4Row = nil
        publicV6Row = nil

        snapshot = Interfaces.snapshot()
        PublicIP.shared.refreshIfStale()
        // A prompt at launch can go unnoticed (it appears while the user is looking elsewhere).
        // Opening the menu is the moment they care about the SSID, so ask again if it is still
        // unanswered; this is a no-op once it has been answered either way.
        LocationAccess.shared.requestIfNeededWhenInstalled()

        // Total + the last minute as a chart.
        let total = NSMenuItem(title: "", action: #selector(copyValue(_:)), keyEquivalent: "")
        total.target = self
        total.attributedTitle = totalTitle()
        total.representedObject = totalTitle().string
        total.toolTip = "Sum over the physical interfaces — the number in the menu bar. Click to copy."
        menu.addItem(total)
        totalRow = total
        let chartItem = NSMenuItem()
        chartItem.view = chart
        menu.addItem(chartItem)
        menu.addItem(.separator())

        // Totals + public IP.
        let totals = NSMenuItem(title: "", action: #selector(copyValue(_:)), keyEquivalent: "")
        totals.target = self
        totals.attributedTitle = totalsTitle()
        totals.representedObject = "↓ \(Format.bytes(monitor.sinceLaunchIn)) ↑ \(Format.bytes(monitor.sinceLaunchOut))"
        totals.toolTip = "Bytes moved over the physical interfaces since Nimbus Net Bar started. Click to copy."
        menu.addItem(totals)
        totalsRow = totals
        let v4 = NSMenuItem(), v6 = NSMenuItem()
        menu.addItem(v4); menu.addItem(v6)
        publicV4Row = v4; publicV6Row = v6
        updatePublicIPRows()

        if snapshot.interfaces.isEmpty {
            menu.addItem(disabled("No network interfaces found"))
        }
        var lastWasCompact = false
        for iface in snapshot.interfaces {
            let compact = iface.dot == .gray
            if !compact || !lastWasCompact { if menu.items.count > 0 { menu.addItem(.separator()) } }
            addInterface(iface)
            lastWasCompact = compact
        }
        menu.addItem(.separator())

        // Settings.
        let rate = NSMenuItem(title: "Update Rate", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let currentHz = 1 / monitor.interval
        for hz in StatusBarController.hzOptions {
            let it = NSMenuItem(title: hz == 1 ? "1 Hz (every second)" : "\(Int(hz)) Hz", action: #selector(setRate(_:)), keyEquivalent: "")
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

        let settings = NSMenuItem(title: "Open Network Settings…", action: #selector(openNetworkSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())

        // Version, dim and small, just above Quit. Click to copy — the first thing a bug
        // report needs. Falls back to "dev build" when running the bare binary (no bundle).
        let versionText = StatusBarController.versionString()
        let version = NSMenuItem(title: versionText, action: #selector(copyValue(_:)), keyEquivalent: "")
        version.target = self
        version.representedObject = versionText
        version.toolTip = "Click to copy"
        version.attributedTitle = NSAttributedString(string: versionText, attributes: [
            .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor])
        menu.addItem(version)

        let quit = NSMenuItem(title: "Quit Nimbus Net Bar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    // MARK: Interface rows

    private func addInterface(_ iface: InterfaceInfo) {
        // Header: ● Name  en0  ·  primary
        let header = NSMenuItem(title: "", action: #selector(copyValue(_:)), keyEquivalent: "")
        header.target = self
        header.image = StatusBarController.dotImage(iface.dot)
        let title = NSMutableAttributedString()
        title.append(NSAttributedString(string: iface.displayName, attributes: [
            .font: NSFont.menuFont(ofSize: 0).withWeight(.semibold)]))
        title.append(NSAttributedString(string: "  \(iface.bsdName)", attributes: [
            .font: NSFont.menuFont(ofSize: 0), .foregroundColor: NSColor.secondaryLabelColor]))
        if iface.isPrimary {
            title.append(NSAttributedString(string: " · primary", attributes: [
                .font: NSFont.menuFont(ofSize: 0).withWeight(.medium), .foregroundColor: NSColor.controlAccentColor]))
        }
        if iface.dot == .gray {
            // Disconnected interfaces get one line only.
            let why: String
            if iface.kind == .wifi, let w = iface.wifi, !w.powerOn { why = "Wi-Fi off" }
            else if iface.kind == .wifi { why = "not associated" }
            else if !iface.isUp { why = "down" }
            else { why = "no link" }
            title.append(NSAttributedString(string: "  —  \(why)", attributes: [
                .font: NSFont.menuFont(ofSize: 0), .foregroundColor: NSColor.tertiaryLabelColor]))
            header.attributedTitle = title
            header.representedObject = iface.mac ?? iface.bsdName
            header.toolTip = iface.mac.map { "MAC \($0) — click to copy" }
            menu.addItem(header)
            return
        }
        header.attributedTitle = title
        header.representedObject = iface.ipv4.first ?? iface.ipv6.first ?? iface.bsdName
        header.toolTip = "Click to copy the IP address"
        menu.addItem(header)

        // Live rate.
        let rate = NSMenuItem(title: "", action: #selector(copyValue(_:)), keyEquivalent: "")
        rate.target = self
        rate.indentationLevel = 1
        rate.attributedTitle = rateTitle(iface.bsdName)
        rate.representedObject = rateTitle(iface.bsdName).string
        menu.addItem(rate)
        rateRows[iface.bsdName] = rate

        // Addresses.
        for ip in iface.ipv4 { menu.addItem(row(label: "IPv4", value: ip, copy: ip)) }
        for ip in iface.selfAssigned {
            let r = row(label: "IPv4", value: "\(ip)  (self-assigned — no DHCP)", copy: ip, valueColor: .systemYellow)
            menu.addItem(r)
        }
        if iface.ipv4.isEmpty && iface.selfAssigned.isEmpty && iface.ipv6.isEmpty {
            menu.addItem(row(label: "IPv4", value: "no address", copy: nil, valueColor: .systemYellow))
        }
        for ip in iface.ipv6 { menu.addItem(row(label: "IPv6", value: ip, copy: ip)) }

        // Wi-Fi.
        if iface.kind == .wifi, let w = iface.wifi {
            let ssid = NSMenuItem()
            configureSSIDRow(ssid, wifi: w)
            menu.addItem(ssid)
            ssidRows[iface.bsdName] = ssid
            if let bssid = w.bssid { menu.addItem(row(label: "BSSID", value: bssid, copy: bssid)) }
            menu.addItem(row(label: "Signal",
                             value: "\(w.rssi) dBm · noise \(w.noise) dBm · SNR \(w.rssi - w.noise) dB",
                             copy: "\(w.rssi) dBm"))
            var link: [String] = []
            if w.txRate > 0 { link.append(Format.linkSpeed(bitsPerSecond: UInt64(w.txRate * 1_000_000))) }
            if let p = w.phyMode { link.append(p) }
            if !link.isEmpty { menu.addItem(row(label: "Link", value: link.joined(separator: " · "), copy: link.first)) }
            var chan: [String] = []
            if let c = w.channel { chan.append("\(c)") }
            if let b = w.band { chan.append(b) }
            if let wd = w.width { chan.append(wd) }
            if !chan.isEmpty { menu.addItem(row(label: "Channel", value: chan.joined(separator: " · "), copy: chan.first)) }
        } else if let speed = iface.linkSpeed {
            let s = Format.linkSpeed(bitsPerSecond: speed)
            menu.addItem(row(label: "Link", value: s, copy: s))
        }

        if let mac = iface.mac { menu.addItem(row(label: "MAC", value: mac, copy: mac)) }

        // Routing, on the primary only.
        if iface.isPrimary {
            var gw: [String] = []
            if let g = iface.gateway { gw.append(g) }
            if let g6 = iface.gateway6 { gw.append(g6) }
            if !gw.isEmpty { menu.addItem(row(label: "Gateway", value: gw.joined(separator: " · "), copy: gw.first)) }
            if !iface.dns.isEmpty {
                menu.addItem(row(label: "DNS", value: iface.dns.joined(separator: ", "), copy: iface.dns.joined(separator: " ")))
            }
        }
    }

    // MARK: Titles

    private static let monoFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

    private func rateTitle(_ bsd: String) -> NSAttributedString {
        let r = monitor.rates[bsd] ?? NetworkMonitor.Rate()
        let s = NSMutableAttributedString()
        s.append(NSAttributedString(string: "↓ ", attributes: [.font: StatusBarController.monoFont, .foregroundColor: StatusBarController.downColor]))
        s.append(NSAttributedString(string: Format.rateCompact(bitsPerSecond: r.down), attributes: [.font: StatusBarController.monoFont]))
        s.append(NSAttributedString(string: "    ↑ ", attributes: [.font: StatusBarController.monoFont, .foregroundColor: StatusBarController.upColor]))
        s.append(NSAttributedString(string: Format.rateCompact(bitsPerSecond: r.up), attributes: [.font: StatusBarController.monoFont]))
        return s
    }

    private func totalTitle() -> NSAttributedString {
        let r = monitor.total
        let s = NSMutableAttributedString()
        s.append(NSAttributedString(string: "Total  ", attributes: [
            .font: NSFont.menuFont(ofSize: 0).withWeight(.semibold)]))
        s.append(NSAttributedString(string: "↓ ", attributes: [.font: StatusBarController.monoFont, .foregroundColor: StatusBarController.downColor]))
        s.append(NSAttributedString(string: Format.rateCompact(bitsPerSecond: r.down), attributes: [.font: StatusBarController.monoFont]))
        s.append(NSAttributedString(string: "    ↑ ", attributes: [.font: StatusBarController.monoFont, .foregroundColor: StatusBarController.upColor]))
        s.append(NSAttributedString(string: Format.rateCompact(bitsPerSecond: r.up), attributes: [.font: StatusBarController.monoFont]))
        return s
    }

    private func totalsTitle() -> NSAttributedString {
        let s = NSMutableAttributedString()
        s.append(NSAttributedString(string: "Since launch  ", attributes: [
            .font: NSFont.menuFont(ofSize: 0), .foregroundColor: NSColor.secondaryLabelColor]))
        s.append(NSAttributedString(string: "↓ ", attributes: [.font: StatusBarController.monoFont, .foregroundColor: StatusBarController.downColor]))
        s.append(NSAttributedString(string: Format.bytes(monitor.sinceLaunchIn), attributes: [.font: StatusBarController.monoFont]))
        s.append(NSAttributedString(string: "    ↑ ", attributes: [.font: StatusBarController.monoFont, .foregroundColor: StatusBarController.upColor]))
        s.append(NSAttributedString(string: Format.bytes(monitor.sinceLaunchOut), attributes: [.font: StatusBarController.monoFont]))
        return s
    }

    /// "Label  value" row; click copies `copy` (or does nothing if nil).
    private func row(label: String, value: String, copy: String?, valueColor: NSColor = .labelColor) -> NSMenuItem {
        let it = NSMenuItem()
        setRow(it, label: label, value: value, copy: copy, valueColor: valueColor)
        return it
    }

    /// (Re)fill an existing row — used for the ones that change while the menu is open.
    private func setRow(_ it: NSMenuItem, label: String, value: String, copy: String?, valueColor: NSColor = .labelColor,
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
            .font: StatusBarController.monoFont, .foregroundColor: valueColor]))
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

    /// The SSID row: the name when we may see it, otherwise why not and a click to fix it.
    private func configureSSIDRow(_ it: NSMenuItem, wifi w: WiFiInfo) {
        if let ssid = w.ssid {
            var v = ssid
            if let s = w.security { v += " · \(s)" }
            setRow(it, label: "SSID", value: v, copy: ssid)
        } else if LocationAccess.shared.isAuthorized {
            setRow(it, label: "SSID", value: "unavailable", copy: nil)
        } else {
            // Two short lines rather than one long one: a single line here was by far the
            // widest thing in the menu and stretched the whole dropdown. The wording has to
            // match what the click will actually do — we can only raise the OS prompt while
            // it is still unspent, otherwise the click just opens Settings.
            let canPrompt = LocationAccess.shared.status == .notDetermined
                && !LocationAccess.shared.hasRequestedOnce
            setRow(it, label: "SSID", value: canPrompt
                   ? "hidden — click to allow Location access\nmacOS gates the network name on it"
                   : "hidden — Location access is off\nClick to open Privacy settings",
                   copy: nil, valueColor: .systemYellow)
            it.action = #selector(requestLocation)
        }
    }

    /// Location authorization changed: re-read each Wi-Fi interface and refresh its SSID
    /// row in place. Nothing to do when the menu is closed — the next open rebuilds anyway.
    private func updateSSIDRows() {
        guard menuOpen else { return }
        for (bsd, it) in ssidRows {
            guard let w = WiFiInfo.read(bsdName: bsd) else { continue }
            configureSSIDRow(it, wifi: w)
        }
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.isEnabled = false
        return it
    }

    private func updatePublicIPRows() {
        func text(_ s: PublicIP.State) -> (String, String?) {
            switch s {
            case .idle, .fetching: return ("…", nil)
            case .value(let v): return (v, v)
            case .failed: return ("unavailable", nil)
            }
        }
        let tip = "Looked up via api.ipify.org when the menu opens; cached for a minute."
        if let r = publicV4Row {
            let (v, c) = text(PublicIP.shared.ipv4)
            setRow(r, label: "Public IPv4", value: v, copy: c, toolTip: tip)
        }
        if let r = publicV6Row {
            let (v, c) = text(PublicIP.shared.ipv6)
            setRow(r, label: "Public IPv6", value: v == "unavailable" ? "none" : v, copy: c, toolTip: tip)
        }
    }

    /// "Nimbus Net Bar v1.2 (23)" — marketing version plus the build number, which is the
    /// commit count, so a report pins down the exact source it came from.
    private static func versionString() -> String {
        let info = Bundle.main.infoDictionary
        let name = info?["CFBundleName"] as? String ?? "Nimbus Net Bar"
        guard let short = info?["CFBundleShortVersionString"] as? String else { return "\(name) — dev build" }
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(name) v\(short) (\($0))" } ?? "\(name) v\(short)"
    }

    private static func dotImage(_ dot: Dot) -> NSImage {
        let color: NSColor
        switch dot {
        case .green: color = .systemGreen
        case .yellow: color = .systemYellow
        case .gray: color = .tertiaryLabelColor
        }
        let img = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5)).fill()
            return true
        }
        return img
    }

    // MARK: Actions

    @objc private func copyValue(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? String else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }

    @objc private func setRate(_ sender: NSMenuItem) {
        guard let hz = sender.representedObject as? Double, hz > 0 else { return }
        monitor.interval = 1 / hz
        UserDefaults.standard.set(hz, forKey: StatusBarController.hzDefaultsKey)
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

    @objc private func openNetworkSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension")!)
    }

    @objc private func requestLocation() {
        // The OS prompt appears only for the very first request; after that it is a silent
        // no-op. So prompt only when we genuinely can (never asked, still undecided); in every
        // other case — denied, restricted, or the one prompt already spent — open Settings,
        // which always does something visible and is where the user can flip the switch.
        if LocationAccess.shared.status == .notDetermined && !LocationAccess.shared.hasRequestedOnce {
            LocationAccess.shared.requestIfNeeded()
        } else {
            NSWorkspace.shared.open(LocationAccess.settingsURL)
        }
    }
}

private extension NSFont {
    func withWeight(_ weight: NSFont.Weight) -> NSFont {
        NSFont.systemFont(ofSize: pointSize, weight: weight)
    }
}
