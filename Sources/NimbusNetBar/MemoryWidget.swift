// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

/// The memory widget: a label and a sparkline in the bar; pressure, the breakdown, the
/// biggest processes, swap and paging in the dropdown, each as its own section.
@MainActor
final class MemoryWidget: NSObject, Widget {

    let id = "memory"
    let title = "Memory"
    let barToolTip = "Nimbus Net Bar — memory used"
    let defaultEnabled = false
    weak var host: WidgetController?

    private let mem = MemorySampler()
    var sampler: any Sampler { mem }

    static let residentColor = NSColor.systemTeal
    static let compressedColor = NSColor.systemIndigo
    /// The breakdown bar's key. Free is the track's own colour: it is the part of the bar
    /// nothing has been painted over.
    static let wiredColor = NSColor.systemBlue
    static let activeColor = NSColor.systemRed
    static let freeColor = NSColor.tertiaryLabelColor

    /// The chart plots exactly what the menu bar's sparkline plots — memory used, against
    /// a fixed 0–100. It used to stack resident under compressed, which was a *third* way of
    /// cutting up the same 24 GB, competing with the breakdown bar a few rows below it.
    static let chartStyle = ChartStyle(
        mode: .single,
        primaryColor: residentColor,
        format: { Format.percent($0) },
        fixedPeak: 100)

    private static let chartWidth: CGFloat = 384
    private let chart = ChartView(frame: NSRect(x: 0, y: 0, width: chartWidth, height: ChartView.chartHeight),
                                  style: MemoryWidget.chartStyle)
    private let pressureBar = SegmentBarView(frame: NSRect(x: 0, y: 0, width: chartWidth, height: SegmentBarView.height))
    private let breakdownBar = SegmentBarView(frame: NSRect(x: 0, y: 0, width: chartWidth, height: SegmentBarView.height))
    private let swapBar = SegmentBarView(frame: NSRect(x: 0, y: 0, width: chartWidth, height: SegmentBarView.height))

    /// Every row whose value moves while the menu is open.
    private enum Row: CaseIterable {
        case pressure, state
        case keyWired, keyActive, keyCompressed, keyFree
        case app, cache
        case swap, pageIns, pageOuts
    }

    private var totalRow: NSMenuItem?
    private var rows: [Row: NSMenuItem] = [:]
    private var topRows: [NSMenuItem] = []

    private static let lensTip = "A different cut of the same memory, not a fifth slice of the bar: app memory is spread across the wired and active parts above, so these two overlap them rather than adding to them."
    private static let cacheTip = "Files the system keeps in memory because there is room. It hands this back the moment anything needs it — it is not memory you are short of."
    private static let pressureTip = "Memory that cannot be reclaimed — wired plus compressed — as a share of the total. That is this app's stated formula, not Activity Monitor's undocumented pressure curve; the kernel's own signal is the State row below."
    private static let stateTip = "The kernel's own signal (kern.memorystatus_vm_pressure_level): normal, warning or critical."
    private static let swapTip = "Swap is the disk the system uses as overflow. A little is normal; a lot, with warning pressure, is not."
    private static let pagesTip = "Bytes moving between memory and disk. Sustained page-outs mean the machine is short of memory."

    override init() {
        super.init()
        chart.history = { [weak self] in self?.mem.history ?? [] }
        pressureBar.segments = { [weak self] in
            guard let self else { return [] }
            return [.init(color: MemoryWidget.residentColor, fraction: mem.usage.pressure)]
        }
        breakdownBar.segments = { [weak self] in
            guard let self else { return [] }
            let total = Double(max(MemoryInfo.total, 1))
            return [
                .init(color: MemoryWidget.wiredColor, fraction: Double(mem.usage.wired) / total),
                .init(color: MemoryWidget.activeColor, fraction: Double(mem.usage.active) / total),
                .init(color: MemoryWidget.compressedColor, fraction: Double(mem.usage.compressed) / total),
            ]
        }
        swapBar.segments = { [weak self] in
            guard let self, mem.swap.total > 0 else { return [] }
            return [.init(color: MemoryWidget.residentColor,
                          fraction: Double(mem.swap.used) / Double(mem.swap.total))]
        }
    }

    // MARK: Bar

    /// Label and sparkline only, like the CPU's and GPU's — the number is on the tooltip
    /// and at the top of the menu.
    func barContent() -> BarContent {
        BarContent(lines: [BarLine(glyph: "MEM", glyphColor: MemoryWidget.residentColor, value: "")],
                   // Unlike CPU, this is a level rather than an activity: it belongs on a
                   // fixed 0–100 scale, where "nearly full" looks nearly full instead of
                   // being normalised away into the same shape as "nearly empty".
                   spark: SparkStyle(color: MemoryWidget.residentColor, fixedPeak: 100),
                   toolTip: "Memory \(Format.percent(mem.usage.fraction * 100)) — \(Format.memory(mem.usage.used)) of \(Format.memory(MemoryInfo.total))")
    }

    // MARK: Menu

    func buildMenu(into menu: NSMenu, host: WidgetController) {
        chart.setFrameSize(NSSize(width: MemoryWidget.chartWidth, height: ChartView.chartHeight))
        for bar in [pressureBar, breakdownBar, swapBar] {
            bar.setFrameSize(NSSize(width: MemoryWidget.chartWidth, height: SegmentBarView.height))
        }
        rows = [:]
        topRows = []

        let total = host.copyRow(totalTitle(), copy: Format.memory(mem.usage.used),
                                 toolTip: "App, wired and compressed memory — everything that is not free and cannot simply be reclaimed. Click to copy.")
        menu.addItem(total)
        totalRow = total
        let chartItem = NSMenuItem()
        chartItem.view = chart
        menu.addItem(chartItem)

        menu.addItem(.separator())
        menu.addItem(host.sectionHeader("Pressure"))
        addView(pressureBar, to: menu)
        add(.pressure, to: menu, host: host, toolTip: MemoryWidget.pressureTip)
        add(.state, to: menu, host: host, toolTip: MemoryWidget.stateTip)

        menu.addItem(.separator())
        menu.addItem(host.sectionHeader("Where it is"))
        addView(breakdownBar, to: menu)
        add(.keyWired, to: menu, host: host)
        add(.keyActive, to: menu, host: host)
        add(.keyCompressed, to: menu, host: host)
        add(.keyFree, to: menu, host: host)
        // A second cut of the same memory, so these carry no swatch and sit dimmed: they
        // overlap the four above rather than adding to them, and saying so is the difference
        // between a useful extra figure and a menu that appears not to add up.
        add(.app, to: menu, host: host, toolTip: MemoryWidget.lensTip)
        add(.cache, to: menu, host: host, toolTip: MemoryWidget.cacheTip)

        menu.addItem(.separator())
        menu.addItem(host.sectionHeader("Biggest processes (yours)"))
        ProcessList.refresh(at: Ticker.now())
        topRows = host.makeTopRows(5, into: menu)
        updateTopRows(host: host)

        menu.addItem(.separator())
        menu.addItem(host.sectionHeader("Swap"))
        addView(swapBar, to: menu)
        add(.swap, to: menu, host: host, toolTip: MemoryWidget.swapTip)

        menu.addItem(.separator())
        menu.addItem(host.sectionHeader("Paging"))
        add(.pageIns, to: menu, host: host, toolTip: MemoryWidget.pagesTip)
        add(.pageOuts, to: menu, host: host, toolTip: MemoryWidget.pagesTip)

        menu.addItem(.separator())
        menu.addItem(host.tableRow(label: "Installed", value: Format.memory(MemoryInfo.total),
                                   copy: Format.memory(MemoryInfo.total)))
    }

    func updateOpenMenu() {
        guard let host else { return }
        totalRow?.attributedTitle = totalTitle()
        chart.needsDisplay = true
        for bar in [pressureBar, breakdownBar, swapBar] { bar.needsDisplay = true }
        for (row, item) in rows { fill(row, item, host: host) }
        ProcessList.refresh(at: Ticker.now())
        updateTopRows(host: host)
    }

    func menuDidClose() {
        chart.clearHover()
    }

    // MARK: Rows

    private func addView(_ view: NSView, to menu: NSMenu) {
        let it = NSMenuItem()
        it.view = view
        menu.addItem(it)
    }

    private func add(_ row: Row, to menu: NSMenu, host: WidgetController, toolTip: String? = nil) {
        let it = NSMenuItem()
        fill(row, it, host: host, toolTip: toolTip)
        menu.addItem(it)
        rows[row] = it
    }

    private func fill(_ row: Row, _ it: NSMenuItem, host: WidgetController, toolTip: String? = nil) {
        let u = mem.usage
        let (label, value, swatch): (String, String, NSColor?) = {
            switch row {
            case .pressure:  return ("Unreclaimable", Format.percent(u.pressure * 100), nil)
            case .state:     return ("Kernel signal", mem.pressure.text, nil)
            case .app:       return ("App memory", Format.memory(u.app), nil)
            case .cache:     return ("Cached files", Format.memory(u.cached), nil)
            case .keyWired:  return ("Wired", Format.memory(u.wired), MemoryWidget.wiredColor)
            case .keyActive: return ("Active", Format.memory(u.active), MemoryWidget.activeColor)
            case .keyCompressed: return ("Compressed", Format.memory(u.compressed), MemoryWidget.compressedColor)
            case .keyFree:   return ("Free", Format.memory(u.available), MemoryWidget.freeColor)
            case .swap:
                return ("In use", mem.swap.total > 0
                        ? "\(Format.memory(mem.swap.used)) of \(Format.memory(mem.swap.total))"
                        : "none in use", nil)
            case .pageIns:   return ("Page ins", Format.bytesPerSecond(mem.pageInRate), nil)
            case .pageOuts:  return ("Page outs", Format.bytesPerSecond(mem.pageOutRate), nil)
            }
        }()
        var color = NSColor.labelColor
        if row == .state {
            switch mem.pressure {
            case .normal, .unknown: color = .labelColor
            case .warning: color = .systemYellow
            case .critical: color = .systemRed
            }
        }
        if row == .cache || row == .app || row == .keyFree { color = .secondaryLabelColor }
        // The tooltip is only passed when the row is created; setTableRow would otherwise
        // clear it on the next tick, so keep whatever it already had.
        host.setTableRow(it, label: label, value: value, swatch: swatch, copy: nil,
                         valueColor: color, toolTip: toolTip ?? it.toolTip)
    }

    private func totalTitle() -> NSAttributedString {
        let s = NSMutableAttributedString()
        s.append(NSAttributedString(string: "Memory used  ", attributes: [
            .font: NSFont.menuFont(ofSize: 0).withWeight(.semibold)]))
        s.append(NSAttributedString(string: Format.percent(mem.usage.fraction * 100) + "    ",
                                    attributes: [.font: Theme.monoFont]))
        s.append(NSAttributedString(string: "\(Format.memory(mem.usage.used)) of \(Format.memory(MemoryInfo.total))",
                                    attributes: [.font: Theme.monoFont,
                                                 .foregroundColor: NSColor.secondaryLabelColor]))
        return s
    }

    private func updateTopRows(host: WidgetController) {
        host.fillTopRows(topRows,
                         entries: ProcessList.topByMemory(topRows.count)
                             .map { (Format.memory($0.value), $0.name) },
                         empty: "measuring…")
    }
}
