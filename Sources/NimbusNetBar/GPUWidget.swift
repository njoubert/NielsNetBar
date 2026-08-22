// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

/// The GPU widget: utilization in the bar, and each GPU's name, load and memory in the
/// dropdown.
@MainActor
final class GPUWidget: NSObject, Widget {

    let id = "gpu"
    let title = "GPU"
    let barToolTip = "Nimbus Net Bar — GPU utilization"
    let defaultEnabled = false
    weak var host: WidgetController?

    private let gpu = GPUSampler()
    var sampler: any Sampler { gpu }

    static let color = NSColor.systemPink

    static let chartStyle = ChartStyle(
        mode: .single,
        primaryColor: color,
        format: { Format.percent($0) },
        fixedPeak: 100)

    private static let chartWidth: CGFloat = 324
    private let chart = ChartView(frame: NSRect(x: 0, y: 0, width: chartWidth, height: ChartView.chartHeight),
                                  style: GPUWidget.chartStyle)

    private var totalRow: NSMenuItem?
    private var gpuRows: [(header: NSMenuItem, inUse: NSMenuItem, index: Int)] = []

    private static let inUseTip = "Memory the GPU actually has resident. On Apple Silicon this comes out of the same pool as the rest of the machine's memory — there is no separate pool of VRAM."
    private static let reservedTip = "Address space the driver has reserved. It is not memory in use and not memory you are short of, which is why it is dimmed."

    override init() {
        super.init()
        chart.history = { [weak self] in self?.gpu.history ?? [] }
    }

    // MARK: Bar

    /// Label and sparkline only, like the CPU's — see `CPUWidget.barContent`.
    func barContent() -> BarContent {
        BarContent(lines: [BarLine(glyph: "GPU", glyphColor: GPUWidget.color, value: "")],
                   // Fixed 0–100, unlike the CPU's: a GPU is genuinely idle most of the time,
                   // and a flat line at zero is both the truth and free — an unchanged image
                   // is never repainted.
                   spark: SparkStyle(color: GPUWidget.color, fixedPeak: 100),
                   toolTip: "GPU \(Format.percent(gpu.utilization * 100))"
                       + (gpu.gpus.count == 1 ? " — \(gpu.gpus[0].name)" : ""))
    }

    // MARK: Menu

    func buildMenu(into menu: NSMenu, host: WidgetController) {
        chart.setFrameSize(NSSize(width: GPUWidget.chartWidth, height: ChartView.chartHeight))
        gpuRows = []

        let total = host.copyRow(totalTitle(), copy: Format.percent(gpu.utilization * 100),
                                 toolTip: "The busiest GPU's utilization. Click to copy.")
        menu.addItem(total)
        totalRow = total
        let chartItem = NSMenuItem()
        chartItem.view = chart
        menu.addItem(chartItem)

        if gpu.gpus.isEmpty {
            menu.addItem(.separator())
            menu.addItem(host.disabled("No GPU reported by IOKit"))
            return
        }

        for (i, g) in gpu.gpus.enumerated() {
            menu.addItem(.separator())
            let header = host.copyRow(gpuTitle(i), copy: g.name, toolTip: "Click to copy")
            menu.addItem(header)

            let inUse = NSMenuItem()
            setInUseRow(inUse, index: i, host: host)
            menu.addItem(inUse)
            gpuRows.append((header, inUse, i))

            if g.allocated > 0 {
                menu.addItem(host.tableRow(label: "Reserved", value: Format.memory(g.allocated),
                                           valueColor: .secondaryLabelColor))
                menu.items.last?.toolTip = GPUWidget.reservedTip
            }
            if g.recommendedMax > 0 {
                menu.addItem(host.tableRow(label: "Working set", value: Format.memory(g.recommendedMax)))
                menu.items.last?.toolTip = "The largest working set Metal recommends for this device."
            }
            var traits: [String] = []
            if g.unified { traits.append("unified memory") }
            if g.isLowPower { traits.append("low power") }
            if g.isRemovable { traits.append("removable") }
            if !traits.isEmpty {
                menu.addItem(host.tableRow(label: "Type", value: traits.joined(separator: " · ")))
            }
        }
    }

    func updateOpenMenu() {
        guard let host else { return }
        totalRow?.attributedTitle = totalTitle()
        chart.needsDisplay = true
        for row in gpuRows {
            row.header.attributedTitle = gpuTitle(row.index)
            setInUseRow(row.inUse, index: row.index, host: host)
        }
    }

    // MARK: Rows

    private func totalTitle() -> NSAttributedString {
        let s = NSMutableAttributedString()
        s.append(NSAttributedString(string: "GPU  ", attributes: [
            .font: NSFont.menuFont(ofSize: 0).withWeight(.semibold)]))
        s.append(NSAttributedString(string: Format.percent(gpu.utilization * 100),
                                    attributes: [.font: Theme.monoFont]))
        return s
    }

    private func gpuTitle(_ i: Int) -> NSAttributedString {
        guard i < gpu.gpus.count else { return NSAttributedString(string: "") }
        let g = gpu.gpus[i]
        let s = NSMutableAttributedString()
        s.append(NSAttributedString(string: g.name + "  ", attributes: [
            .font: NSFont.menuFont(ofSize: 0).withWeight(.semibold)]))
        s.append(NSAttributedString(string: Format.percent(g.utilization * 100), attributes: [
            .font: Theme.monoFont, .foregroundColor: NSColor.secondaryLabelColor]))
        return s
    }

    private func setInUseRow(_ it: NSMenuItem, index: Int, host: WidgetController) {
        let g = index < gpu.gpus.count ? gpu.gpus[index] : GPUSampler.GPU(name: "")
        host.setTableRow(it, label: "Memory in use", value: Format.memory(g.inUse),
                         toolTip: GPUWidget.inUseTip)
    }
}
