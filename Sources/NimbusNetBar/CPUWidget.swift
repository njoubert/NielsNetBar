// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

/// The CPU widget: total busy percentage plus a 60 s sparkline in the bar; per-core load,
/// load average, thermal state and the busiest processes in the dropdown.
@MainActor
final class CPUWidget: NSObject, Widget {

    let id = "cpu"
    let title = "CPU"
    let barToolTip = "Nimbus Net Bar — CPU load"
    let defaultEnabled = false
    weak var host: WidgetController?

    private let cpu = CPUSampler()
    var sampler: any Sampler { cpu }

    /// Activity Monitor's convention: blue for user time, red for system time, stacked.
    static let userColor = NSColor.systemBlue
    static let systemColor = NSColor.systemRed

    static let chartStyle = ChartStyle(
        mode: .stacked,
        primaryColor: userColor,
        secondaryColor: systemColor,
        primaryGlyph: "user",
        secondaryGlyph: "sys",
        format: { Format.percent($0) },
        fixedPeak: 100)

    private static let chartWidth: CGFloat = 384
    private let chart = ChartView(frame: NSRect(x: 0, y: 0, width: chartWidth, height: ChartView.chartHeight),
                                  style: CPUWidget.chartStyle)

    // Rows that update live while the menu is open.
    /// Performance cores read blue and efficiency cores green, as the rings' legend says.
    /// These are not the chart's user/system colours: the two panels answer different
    /// questions and each carries its own key.
    private static let coreColors: [NSColor] = [.systemBlue, .systemGreen, .systemTeal]

    private let cores = CoreGaugesView(frame: NSRect(x: 0, y: 0, width: CPUWidget.chartWidth,
                                                     height: CoreGaugesView.coresHeight))

    private var totalRow: NSMenuItem?
    private var loadRow: NSMenuItem?
    private var thermalRow: NSMenuItem?
    private var topRows: [NSMenuItem] = []

    private static let loadTip = "Run queue length averaged over 1, 5 and 15 minutes."
    private static let thermalTip = "What the OS says about heat: nominal, fair, serious or critical."

    override init() {
        super.init()
        chart.history = { [weak self] in self?.cpu.history ?? [] }
        cores.groups = { [weak self] in self?.coreGroups() ?? [] }
    }

    /// One ring row per performance level, in the kernel's core order.
    private func coreGroups() -> [CoreGaugesView.Group] {
        let loads = cpu.cores
        return CPUInfo.coreGroups.enumerated().map { i, g in
            CoreGaugesView.Group(
                name: g.name,
                color: CPUWidget.coreColors[i % CPUWidget.coreColors.count],
                loads: g.range.map { $0 < loads.count ? loads[$0].busy : 0 })
        }
    }

    // MARK: Bar

    /// Label and sparkline only — the shape is what a glance wants; the number is on the
    /// tooltip and at the top of the menu. It also makes the widget cheaper: with no digits
    /// to change, a repaint happens only when the sparkline itself moves.
    func barContent() -> BarContent {
        BarContent(lines: [BarLine(glyph: "CPU", glyphColor: CPUWidget.userColor, value: "")],
                   // The sparkline scales to its own window, not to 0–100: at a fixed
                   // ceiling an idle machine is a flat line one pixel tall. The number
                   // carries the absolute value, the sparkline carries the shape.
                   spark: SparkStyle(color: CPUWidget.userColor, fixedPeak: nil),
                   toolTip: "CPU \(Format.percent(cpu.total.busy * 100)) — user \(Format.percent(cpu.total.user * 100)), system \(Format.percent(cpu.total.system * 100))")
    }

    // MARK: Menu

    func buildMenu(into menu: NSMenu, host: WidgetController) {
        // See NetworkWidget: the chart stretches to the menu's width and would otherwise
        // make that width the menu's new minimum on the next open.
        chart.setFrameSize(NSSize(width: CPUWidget.chartWidth, height: ChartView.chartHeight))
        cores.setFrameSize(NSSize(width: CPUWidget.chartWidth, height: CoreGaugesView.coresHeight))
        topRows = []

        let total = host.copyRow(totalTitle(), copy: Format.percent(cpu.total.busy * 100),
                                 toolTip: "User and system time averaged over every core. Click to copy.")
        menu.addItem(total)
        totalRow = total
        let chartItem = NSMenuItem()
        chartItem.view = chart
        menu.addItem(chartItem)
        menu.addItem(.separator())

        // Per-core load: one ring each, grouped by performance level.
        let coresItem = NSMenuItem()
        coresItem.view = cores
        menu.addItem(coresItem)
        menu.addItem(.separator())

        let load = NSMenuItem()
        host.setTableRow(load, label: "Load average", value: loadText(), toolTip: CPUWidget.loadTip)
        menu.addItem(load)
        loadRow = load

        let thermal = NSMenuItem()
        let (t, color) = thermalText()
        host.setTableRow(thermal, label: "Thermal", value: t, valueColor: color,
                         toolTip: CPUWidget.thermalTip)
        menu.addItem(thermal)
        thermalRow = thermal
        menu.addItem(.separator())

        // Busiest processes. The walk is expensive, so it happens here and then once a
        // second for as long as the menu stays open — never on the ordinary tick.
        // Only this user's processes: `proc_pid_rusage` refuses the rest without
        // privileges (measured here: 887 processes listed, 579 readable — exactly the ones
        // this user owns), so say "yours" rather than implying it is the whole machine.
        let topHeader = host.sectionHeader("Busiest processes (yours)")
        topHeader.toolTip = "Processes owned by you. Reading another user's — root daemons, other accounts — needs privileges Nimbus Net Bar does not ask for."
        menu.addItem(topHeader)
        ProcessList.refresh(at: Ticker.now())
        topRows = host.makeTopRows(5, into: menu)
        updateTopRows(host: host)
        menu.addItem(.separator())

        let cores = CPUInfo.coreGroups.count > 1
            ? CPUInfo.coreGroups.map { "\($0.range.count)\($0.name.prefix(1))" }.joined(separator: " + ")
            : "\(CPUInfo.logicalCores)"
        menu.addItem(host.tableRow(label: CPUInfo.brand, value: "\(CPUInfo.logicalCores) cores (\(cores))",
                                   copy: CPUInfo.brand))
    }

    func updateOpenMenu() {
        guard let host else { return }
        totalRow?.attributedTitle = totalTitle()
        chart.needsDisplay = true
        cores.needsDisplay = true
        // setRow clears any tooltip it is not given, so these have to be passed every time.
        if let loadRow {
            host.setTableRow(loadRow, label: "Load average", value: loadText(), toolTip: CPUWidget.loadTip)
        }
        if let thermalRow {
            let (t, color) = thermalText()
            host.setTableRow(thermalRow, label: "Thermal", value: t, valueColor: color,
                             toolTip: CPUWidget.thermalTip)
        }
        ProcessList.refresh(at: Ticker.now())
        updateTopRows(host: host)
    }

    // MARK: Rows

    private func totalTitle() -> NSAttributedString {
        let s = NSMutableAttributedString()
        s.append(NSAttributedString(string: "CPU  ", attributes: [
            .font: NSFont.menuFont(ofSize: 0).withWeight(.semibold)]))
        s.append(NSAttributedString(string: Format.percent(cpu.total.busy * 100) + "    ",
                                    attributes: [.font: Theme.monoFont]))
        s.append(NSAttributedString(string: "user ", attributes: [
            .font: Theme.monoFont, .foregroundColor: CPUWidget.userColor]))
        s.append(NSAttributedString(string: Format.percent(cpu.total.user * 100) + "    ",
                                    attributes: [.font: Theme.monoFont]))
        s.append(NSAttributedString(string: "sys ", attributes: [
            .font: Theme.monoFont, .foregroundColor: CPUWidget.systemColor]))
        s.append(NSAttributedString(string: Format.percent(cpu.total.system * 100),
                                    attributes: [.font: Theme.monoFont]))
        return s
    }

    private func loadText() -> String {
        let la = CPUInfo.loadAverage()
        guard la.count == 3 else { return "unavailable" }
        return la.map { String(format: "%.2f", $0) }.joined(separator: "  ")
    }

    private func thermalText() -> (String, NSColor) {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:  return ("nominal", .labelColor)
        case .fair:     return ("fair", .labelColor)
        case .serious:  return ("serious — the system is throttling", .systemYellow)
        case .critical: return ("critical — heavy throttling", .systemRed)
        @unknown default: return ("unknown", .labelColor)
        }
    }

    /// Fill the five process rows from the latest walk, hiding the ones with nothing to say.
    private func updateTopRows(host: WidgetController) {
        host.fillTopRows(topRows,
                         // Unpadded: the tab stop does the aligning now, and the old
                         // right-padding pushed the number away from it.
                         entries: ProcessList.topByCPU(topRows.count)
                             .map { (Format.percent($0.value * 100), $0.name) },
                         empty: "measuring…")
    }
}
