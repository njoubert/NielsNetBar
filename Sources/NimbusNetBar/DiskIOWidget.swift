// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

/// The disk I/O widget: write over read in the bar, mirroring the network's ↑/↓, with
/// per-device rates, totals since launch and the busiest processes in the dropdown.
@MainActor
final class DiskIOWidget: NSObject, Widget {

    let id = "diskio"
    let title = "Disk Activity"
    let barToolTip = "Nimbus Net Bar — disk read and write"
    let defaultEnabled = false
    weak var host: WidgetController?

    private let disk = DiskSampler()
    var sampler: any Sampler { disk }

    static let writeColor = NSColor.systemOrange
    static let readColor = NSColor.systemTeal

    static let chartStyle = ChartStyle(
        mode: .mirrored,
        primaryColor: writeColor,
        secondaryColor: readColor,
        primaryGlyph: "W",
        secondaryGlyph: "R",
        format: { Format.bytesPerSecond($0) },
        minPeak: 100_000)

    private static let chartWidth: CGFloat = 384
    private let chart = ChartView(frame: NSRect(x: 0, y: 0, width: chartWidth, height: ChartView.chartHeight),
                                  style: DiskIOWidget.chartStyle)

    private var totalRow: NSMenuItem?
    private var deviceRows: [(item: NSMenuItem, index: Int)] = []
    private var totalsRow: NSMenuItem?
    private var topRows: [NSMenuItem] = []

    override init() {
        super.init()
        chart.history = { [weak self] in self?.disk.history ?? [] }
    }

    // MARK: Bar

    func barContent() -> BarContent {
        BarContent(lines: [
            BarLine(glyph: "W", glyphColor: DiskIOWidget.writeColor,
                    value: Format.bytesPerSecondFixed(disk.total.write)),
            BarLine(glyph: "R", glyphColor: DiskIOWidget.readColor,
                    value: Format.bytesPerSecondFixed(disk.total.read)),
        ])
    }

    // MARK: Menu

    func buildMenu(into menu: NSMenu, host: WidgetController) {
        chart.setFrameSize(NSSize(width: DiskIOWidget.chartWidth, height: ChartView.chartHeight))
        deviceRows = []
        topRows = []

        let total = host.copyRow(totalTitle(), copy: totalTitle().string,
                                 toolTip: "Every block device the system reports, summed. Click to copy.")
        menu.addItem(total)
        totalRow = total
        let chartItem = NSMenuItem()
        chartItem.view = chart
        menu.addItem(chartItem)
        menu.addItem(.separator())

        let totals = NSMenuItem()
        host.setTableRow(totals, label: "Since launch", value: totalsText(),
                         toolTip: "Bytes read and written since Nimbus Net Bar started.")
        menu.addItem(totals)
        totalsRow = totals

        if disk.devices.isEmpty {
            menu.addItem(host.disabled("No block devices found"))
        }
        for (i, _) in disk.devices.enumerated() {
            menu.addItem(.separator())
            let header = host.copyRow(deviceTitle(i), copy: disk.devices[i].bsdName ?? disk.devices[i].name,
                                      toolTip: "Click to copy")
            menu.addItem(header)
            let rate = host.copyRow(rateText(disk.devices[i].rate),
                                    copy: rateText(disk.devices[i].rate).string)
            rate.indentationLevel = 1
            menu.addItem(rate)
            deviceRows.append((rate, i))
        }
        menu.addItem(.separator())

        let topHeader = host.sectionHeader("Busiest processes (yours)")
        topHeader.toolTip = "Bytes read plus written per second. Processes owned by other users need privileges Nimbus Net Bar does not ask for."
        menu.addItem(topHeader)
        ProcessList.refresh(at: Ticker.now())
        topRows = host.makeTopRows(5, into: menu)
        updateTopRows(host: host)
    }

    func updateOpenMenu() {
        guard let host else { return }
        totalRow?.attributedTitle = totalTitle()
        chart.needsDisplay = true
        for (it, i) in deviceRows { setDeviceRow(it, index: i, host: host) }
        if let totalsRow {
            host.setTableRow(totalsRow, label: "Since launch", value: totalsText(),
                             toolTip: totalsRow.toolTip)
        }
        ProcessList.refresh(at: Ticker.now())
        updateTopRows(host: host)
    }

    func menuDidClose() {
        chart.clearHover()
    }

    // MARK: Rows

    private func rateText(_ r: DiskSampler.Rate) -> NSAttributedString {
        let s = NSMutableAttributedString()
        s.append(NSAttributedString(string: "W ", attributes: [.font: Theme.monoFont, .foregroundColor: DiskIOWidget.writeColor]))
        s.append(NSAttributedString(string: Format.bytesPerSecond(r.write), attributes: [.font: Theme.monoFont]))
        s.append(NSAttributedString(string: "    R ", attributes: [.font: Theme.monoFont, .foregroundColor: DiskIOWidget.readColor]))
        s.append(NSAttributedString(string: Format.bytesPerSecond(r.read), attributes: [.font: Theme.monoFont]))
        return s
    }

    private func totalTitle() -> NSAttributedString {
        let s = NSMutableAttributedString()
        s.append(NSAttributedString(string: "Disk  ", attributes: [
            .font: NSFont.menuFont(ofSize: 0).withWeight(.semibold)]))
        s.append(rateText(disk.total))
        return s
    }

    private func deviceTitle(_ i: Int) -> NSAttributedString {
        guard i < disk.devices.count else { return NSAttributedString(string: "") }
        let d = disk.devices[i]
        let s = NSMutableAttributedString()
        s.append(NSAttributedString(string: d.name, attributes: [
            .font: NSFont.menuFont(ofSize: 0).withWeight(.semibold)]))
        if let bsd = d.bsdName {
            s.append(NSAttributedString(string: "  \(bsd)", attributes: [
                .font: NSFont.menuFont(ofSize: 0), .foregroundColor: NSColor.secondaryLabelColor]))
        }
        return s
    }

    private func setDeviceRow(_ it: NSMenuItem, index: Int, host: WidgetController) {
        let r = index < disk.devices.count ? disk.devices[index].rate : DiskSampler.Rate()
        it.attributedTitle = rateText(r)
        it.indentationLevel = 1
    }

    private func totalsText() -> String {
        "R \(Format.bytes(disk.sinceLaunchRead))    W \(Format.bytes(disk.sinceLaunchWritten))"
    }

    private func updateTopRows(host: WidgetController) {
        host.fillTopRows(topRows,
                         entries: ProcessList.topByDisk(topRows.count)
                             .map { (Format.bytesPerSecond($0.value), $0.name) },
                         empty: "nothing reading or writing")
    }
}
