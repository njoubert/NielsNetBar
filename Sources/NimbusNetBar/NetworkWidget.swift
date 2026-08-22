// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

/// The network widget: stacked ↑/↓ throughput in the bar, and every interface's state,
/// addresses, link speed and Wi-Fi details in the dropdown.
@MainActor
final class NetworkWidget: NSObject, Widget {

    let id = "network"
    let title = "Network"
    let barToolTip = "Nimbus Net Bar — network throughput"
    let defaultEnabled = true
    weak var host: WidgetController?

    private let monitor = NetworkMonitor()
    var sampler: any Sampler { monitor }

    /// The network's chart: ↑ upload above the centre line in blue, ↓ download below it in
    /// green, on one scale that never drops below 1 kbps so an idle minute is not a wall
    /// of full-height bars.
    static let chartStyle = ChartStyle(
        mode: .mirrored,
        primaryColor: Theme.upColor,
        secondaryColor: Theme.downColor,
        primaryGlyph: "↑",
        secondaryGlyph: "↓",
        format: { Format.rateCompact(bitsPerSecond: $0) },
        minPeak: 1_000)

    /// The chart's natural width. It carries `autoresizingMask = [.width]`, so AppKit
    /// stretches it to whatever the menu is wide; because the same view is reused on every
    /// open, that stretched frame would become the menu's new minimum and the menu could
    /// only ever grow (measured: 633 pt → 649 pt on the next open). `buildMenu` resets it.
    private static let chartWidth: CGFloat = 384
    private let chart = ChartView(frame: NSRect(x: 0, y: 0, width: chartWidth, height: ChartView.chartHeight),
                                  style: NetworkWidget.chartStyle)

    private var snapshot = NetworkSnapshot()
    // Rows that update live while the menu is open.
    private var totalRow: NSMenuItem?
    private var rateRows: [String: NSMenuItem] = [:]
    private var ssidRows: [String: NSMenuItem] = [:]   // Wi-Fi bsd name → its SSID row
    private var totalsRow: NSMenuItem?
    private var publicV4Row: NSMenuItem?
    private var publicV6Row: NSMenuItem?

    override init() {
        super.init()
        chart.history = { [weak self] in self?.monitor.history ?? [] }
        PublicIP.shared.onChange = { [weak self] in self?.updatePublicIPRows() }
        // Granting Location access mid-menu reveals the SSID: update that row in place
        // rather than rebuilding a menu that is being tracked (flicker, lost hover).
        LocationAccess.shared.onChange = { [weak self] in self?.updateSSIDRows() }
    }

    // MARK: Bar

    /// ↑ upload on top, ↓ download below, both fixed-width so the item never jiggles.
    func barContent() -> BarContent {
        BarContent(lines: [
            BarLine(glyph: "↑", glyphColor: Theme.upColor, value: Format.rateFixed(bitsPerSecond: monitor.total.up)),
            BarLine(glyph: "↓", glyphColor: Theme.downColor, value: Format.rateFixed(bitsPerSecond: monitor.total.down)),
        ])
    }

    // MARK: Menu

    func buildMenu(into menu: NSMenu, host: WidgetController) {
        // Shrink the chart back to its natural width before measuring, or the menu inherits
        // the width of whatever the widest row was last time and never gets narrower again.
        chart.setFrameSize(NSSize(width: NetworkWidget.chartWidth, height: ChartView.chartHeight))
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
        let total = host.copyRow(totalTitle(), copy: totalTitle().string,
                                 toolTip: "Sum over the physical interfaces — the number in the menu bar. Click to copy.")
        menu.addItem(total)
        totalRow = total
        let chartItem = NSMenuItem()
        chartItem.view = chart
        menu.addItem(chartItem)
        menu.addItem(.separator())

        // Totals + public IP.
        let totals = host.copyRow(totalsTitle(),
                                  copy: "↓ \(Format.bytes(monitor.sinceLaunchIn)) ↑ \(Format.bytes(monitor.sinceLaunchOut))",
                                  toolTip: "Bytes moved over the physical interfaces since Nimbus Net Bar started. Click to copy.")
        menu.addItem(totals)
        totalsRow = totals
        let v4 = NSMenuItem(), v6 = NSMenuItem()
        menu.addItem(v4); menu.addItem(v6)
        publicV4Row = v4; publicV6Row = v6
        updatePublicIPRows()

        if snapshot.interfaces.isEmpty {
            menu.addItem(host.disabled("No network interfaces found"))
        }
        var lastWasCompact = false
        for iface in snapshot.interfaces {
            let compact = iface.dot == .gray
            if !compact || !lastWasCompact { if menu.items.count > 0 { menu.addItem(.separator()) } }
            addInterface(iface, to: menu, host: host)
            lastWasCompact = compact
        }
    }

    func settingsItems(host: WidgetController) -> [NSMenuItem] {
        let settings = NSMenuItem(title: "Open Network Settings…", action: #selector(openNetworkSettings), keyEquivalent: "")
        settings.target = self
        return [settings]
    }

    func updateOpenMenu() {
        totalRow?.attributedTitle = totalTitle()
        chart.needsDisplay = true
        for (bsd, row) in rateRows {
            row.attributedTitle = rateTitle(bsd)
        }
        totalsRow?.attributedTitle = totalsTitle()
    }

    /// The menu closing sends no `mouseExited`, so clear the hover here or the next open
    /// starts with a stale highlighted bar.
    func menuDidClose() {
        chart.clearHover()
    }

    // MARK: Interface rows

    private func addInterface(_ iface: InterfaceInfo, to menu: NSMenu, host: WidgetController) {
        // Header: ● Name  en0  ·  primary
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
            let header = host.copyRow(title, copy: iface.mac ?? iface.bsdName,
                                      toolTip: iface.mac.map { "MAC \($0) — click to copy" })
            header.image = NetworkWidget.dotImage(iface.dot)
            menu.addItem(header)
            return
        }
        let header = host.copyRow(title, copy: iface.ipv4.first ?? iface.ipv6.first ?? iface.bsdName,
                                  toolTip: "Click to copy the IP address")
        header.image = NetworkWidget.dotImage(iface.dot)
        menu.addItem(header)

        // Live rate.
        let rate = host.copyRow(rateTitle(iface.bsdName), copy: rateTitle(iface.bsdName).string)
        rate.indentationLevel = 1
        menu.addItem(rate)
        rateRows[iface.bsdName] = rate

        // Addresses.
        for ip in iface.ipv4 { menu.addItem(host.row(label: "IPv4", value: ip, copy: ip)) }
        for ip in iface.selfAssigned {
            menu.addItem(host.row(label: "IPv4", value: "\(ip)  (self-assigned — no DHCP)", copy: ip, valueColor: .systemYellow))
        }
        if iface.ipv4.isEmpty && iface.selfAssigned.isEmpty && iface.ipv6.isEmpty {
            menu.addItem(host.row(label: "IPv4", value: "no address", copy: nil, valueColor: .systemYellow))
        }
        for ip in iface.ipv6 { menu.addItem(host.row(label: "IPv6", value: ip, copy: ip)) }

        // Wi-Fi.
        if iface.kind == .wifi, let w = iface.wifi {
            let ssid = NSMenuItem()
            configureSSIDRow(ssid, wifi: w, host: host)
            menu.addItem(ssid)
            ssidRows[iface.bsdName] = ssid
            if let bssid = w.bssid { menu.addItem(host.row(label: "BSSID", value: bssid, copy: bssid)) }
            menu.addItem(host.row(label: "Signal",
                                  value: "\(w.rssi) dBm · noise \(w.noise) dBm · SNR \(w.rssi - w.noise) dB",
                                  copy: "\(w.rssi) dBm"))
            var link: [String] = []
            if w.txRate > 0 { link.append(Format.linkSpeed(bitsPerSecond: UInt64(w.txRate * 1_000_000))) }
            if let p = w.phyMode { link.append(p) }
            if !link.isEmpty { menu.addItem(host.row(label: "Link", value: link.joined(separator: " · "), copy: link.first)) }
            var chan: [String] = []
            if let c = w.channel { chan.append("\(c)") }
            if let b = w.band { chan.append(b) }
            if let wd = w.width { chan.append(wd) }
            if !chan.isEmpty { menu.addItem(host.row(label: "Channel", value: chan.joined(separator: " · "), copy: chan.first)) }
        } else if let speed = iface.linkSpeed {
            let s = Format.linkSpeed(bitsPerSecond: speed)
            menu.addItem(host.row(label: "Link", value: s, copy: s))
        }

        if let mac = iface.mac { menu.addItem(host.row(label: "MAC", value: mac, copy: mac)) }

        // Routing, on the primary only.
        if iface.isPrimary {
            var gw: [String] = []
            if let g = iface.gateway { gw.append(g) }
            if let g6 = iface.gateway6 { gw.append(g6) }
            if !gw.isEmpty { menu.addItem(host.row(label: "Gateway", value: gw.joined(separator: " · "), copy: gw.first)) }
            if !iface.dns.isEmpty {
                menu.addItem(host.row(label: "DNS", value: iface.dns.joined(separator: ", "), copy: iface.dns.joined(separator: " ")))
            }
        }
    }

    // MARK: Titles

    private func rateTitle(_ bsd: String) -> NSAttributedString {
        let r = monitor.rates[bsd] ?? NetworkMonitor.Rate()
        let s = NSMutableAttributedString()
        s.append(NSAttributedString(string: "↓ ", attributes: [.font: Theme.monoFont, .foregroundColor: Theme.downColor]))
        s.append(NSAttributedString(string: Format.rateCompact(bitsPerSecond: r.down), attributes: [.font: Theme.monoFont]))
        s.append(NSAttributedString(string: "    ↑ ", attributes: [.font: Theme.monoFont, .foregroundColor: Theme.upColor]))
        s.append(NSAttributedString(string: Format.rateCompact(bitsPerSecond: r.up), attributes: [.font: Theme.monoFont]))
        return s
    }

    private func totalTitle() -> NSAttributedString {
        let r = monitor.total
        let s = NSMutableAttributedString()
        s.append(NSAttributedString(string: "Total  ", attributes: [
            .font: NSFont.menuFont(ofSize: 0).withWeight(.semibold)]))
        s.append(NSAttributedString(string: "↓ ", attributes: [.font: Theme.monoFont, .foregroundColor: Theme.downColor]))
        s.append(NSAttributedString(string: Format.rateCompact(bitsPerSecond: r.down), attributes: [.font: Theme.monoFont]))
        s.append(NSAttributedString(string: "    ↑ ", attributes: [.font: Theme.monoFont, .foregroundColor: Theme.upColor]))
        s.append(NSAttributedString(string: Format.rateCompact(bitsPerSecond: r.up), attributes: [.font: Theme.monoFont]))
        return s
    }

    private func totalsTitle() -> NSAttributedString {
        let s = NSMutableAttributedString()
        s.append(NSAttributedString(string: "Since launch  ", attributes: [
            .font: NSFont.menuFont(ofSize: 0), .foregroundColor: NSColor.secondaryLabelColor]))
        s.append(NSAttributedString(string: "↓ ", attributes: [.font: Theme.monoFont, .foregroundColor: Theme.downColor]))
        s.append(NSAttributedString(string: Format.bytes(monitor.sinceLaunchIn), attributes: [.font: Theme.monoFont]))
        s.append(NSAttributedString(string: "    ↑ ", attributes: [.font: Theme.monoFont, .foregroundColor: Theme.upColor]))
        s.append(NSAttributedString(string: Format.bytes(monitor.sinceLaunchOut), attributes: [.font: Theme.monoFont]))
        return s
    }

    /// The SSID row: the name when we may see it, otherwise why not and a click to fix it.
    private func configureSSIDRow(_ it: NSMenuItem, wifi w: WiFiInfo, host: WidgetController) {
        if let ssid = w.ssid {
            var v = ssid
            if let s = w.security { v += " · \(s)" }
            host.setRow(it, label: "SSID", value: v, copy: ssid)
        } else if LocationAccess.shared.isAuthorized {
            host.setRow(it, label: "SSID", value: "unavailable", copy: nil)
        } else {
            // Two short lines rather than one long one: a single line here was by far the
            // widest thing in the menu and stretched the whole dropdown. The wording has to
            // match what the click will actually do — we can only raise the OS prompt while
            // it is still unspent, otherwise the click just opens Settings.
            let canPrompt = LocationAccess.shared.status == .notDetermined
                && !LocationAccess.shared.hasRequestedOnce
            host.setRow(it, label: "SSID", value: canPrompt
                        ? "hidden — click to allow Location access\nmacOS gates the network name on it"
                        : "hidden — Location access is off\nClick to open Privacy settings",
                        copy: nil, valueColor: .systemYellow)
            it.action = #selector(requestLocation)
            it.target = self
        }
    }

    /// Location authorization changed: re-read each Wi-Fi interface and refresh its SSID
    /// row in place. Nothing to do when the menu is closed — the next open rebuilds anyway.
    private func updateSSIDRows() {
        guard let host, host.menuOpen else { return }
        for (bsd, it) in ssidRows {
            guard let w = WiFiInfo.read(bsdName: bsd) else { continue }
            configureSSIDRow(it, wifi: w, host: host)
        }
    }

    private func updatePublicIPRows() {
        guard let host else { return }
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
            host.setRow(r, label: "Public IPv4", value: v, copy: c, toolTip: tip)
        }
        if let r = publicV6Row {
            let (v, c) = text(PublicIP.shared.ipv6)
            host.setRow(r, label: "Public IPv6", value: v == "unavailable" ? "none" : v, copy: c, toolTip: tip)
        }
    }

    private static func dotImage(_ dot: Dot) -> NSImage {
        let color: NSColor
        switch dot {
        case .green: color = .systemGreen
        case .yellow: color = .systemYellow
        case .gray: color = .tertiaryLabelColor
        }
        return NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5)).fill()
            return true
        }
    }

    // MARK: Actions

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
