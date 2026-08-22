// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

/// The disk capacity widget: how full the boot volume is, as a number and a fill bar in the
/// bar; every mounted volume, grouped by the container they share, in the dropdown.
@MainActor
final class CapacityWidget: NSObject, Widget {

    let id = "capacity"
    let title = "Disk Space"
    let barToolTip = "Nimbus Net Bar — disk space used"
    let defaultEnabled = false
    weak var host: WidgetController?

    private let capacity = CapacitySampler()
    var sampler: any Sampler { capacity }

    static let color = NSColor.systemPurple
    /// Matches the chart's natural width, so the menu is the same width as every other one.
    private static let barWidth: CGFloat = 384

    private var rows: [(item: NSMenuItem, mountPoint: String, shared: Bool)] = []
    /// One bar per volume, rebuilt with the menu. Unlike the chart these are cheap and hold
    /// no state, so a fresh one each time is simpler than reusing them — and it sidesteps
    /// the reused-view-only-ever-grows trap that `ChartView` has to work around.
    private var bars: [SegmentBarView] = []

    // MARK: Bar

    /// Label and pie only. No sparkline — free space over the last minute is a flat line —
    /// and no number: the pie is the reading, and the exact figures are on the tooltip and
    /// in the menu.
    func barContent() -> BarContent {
        let boot = capacity.boot
        let tip = boot.map { "\($0.name) \(Format.percent($0.fraction * 100)) full — \(Format.memory($0.available)) free of \(Format.memory($0.total))" }
        return BarContent(lines: [BarLine(glyph: "SSD", glyphColor: CapacityWidget.color, value: "")],
                          gauge: BarGauge(color: CapacityWidget.color, fraction: boot?.fraction ?? 0),
                          toolTip: tip)
    }

    // MARK: Menu

    func buildMenu(into menu: NSMenu, host: WidgetController) {
        rows = []
        bars = []
        if capacity.volumes.isEmpty {
            menu.addItem(host.disabled("Reading volumes…"))
            return
        }

        // Group by APFS container: the volumes in one share a single pool of free space, so
        // the free figure belongs to the group and not to each volume in it.
        var groups: [(key: String, volumes: [CapacitySampler.Volume])] = []
        for v in capacity.volumes {
            let key = v.container ?? v.mountPoint
            if let i = groups.firstIndex(where: { $0.key == key }) {
                groups[i].volumes.append(v)
            } else {
                groups.append((key, [v]))
            }
        }

        for (i, group) in groups.enumerated() {
            if i > 0 { menu.addItem(.separator()) }
            let shared = group.volumes.count > 1
            if shared, let first = group.volumes.first {
                let header = NSMutableAttributedString()
                header.append(NSAttributedString(string: "\(group.key)  ", attributes: [
                    .font: NSFont.menuFont(ofSize: 0).withWeight(.semibold)]))
                header.append(NSAttributedString(
                    string: "\(Format.memory(first.available)) free, shared by \(group.volumes.count) volumes",
                    attributes: [.font: NSFont.menuFont(ofSize: 0),
                                 .foregroundColor: NSColor.secondaryLabelColor]))
                let it = host.copyRow(header, copy: nil,
                                      toolTip: "These volumes are in one APFS container: the free space is one pool they all draw on, not that much each.")
                menu.addItem(it)
            }
            for v in group.volumes {
                let mountPoint = v.mountPoint
                let bar = SegmentBarView(frame: NSRect(x: 0, y: 0, width: CapacityWidget.barWidth,
                                                       height: SegmentBarView.height))
                bar.segments = { [weak self] in
                    guard let v = self?.capacity.volumes.first(where: { $0.mountPoint == mountPoint })
                    else { return [] }
                    return [.init(color: CapacityWidget.color, fraction: v.fraction)]
                }
                let barItem = NSMenuItem()
                barItem.view = bar
                menu.addItem(barItem)
                bars.append(bar)

                let it = NSMenuItem()
                setVolumeRow(it, volume: v, shared: shared, host: host)
                if shared { it.indentationLevel = 2 }
                menu.addItem(it)
                rows.append((it, v.mountPoint, shared))
            }
        }
    }

    /// Into the shared settings block, next to Launch at Login — the same place the network
    /// widget puts its own shortcut, rather than trailing its own rows.
    func settingsItems(host: WidgetController) -> [NSMenuItem] {
        let it = NSMenuItem(title: "Open Storage Settings…", action: #selector(openStorageSettings),
                            keyEquivalent: "")
        it.target = self
        return [it]
    }

    /// The volumes only change every ten seconds and can appear or disappear, so a row
    /// whose volume is gone is left as it was until the next open rebuilds the menu.
    func updateOpenMenu() {
        guard let host else { return }
        for bar in bars { bar.needsDisplay = true }
        // `shared` is remembered rather than read back off the row: setRow indents every
        // row it fills, so an indentation test is always true and would flip a standalone
        // volume's wording to the shared one on the first tick after the menu opened.
        for (it, mountPoint, shared) in rows {
            guard let v = capacity.volumes.first(where: { $0.mountPoint == mountPoint }) else { continue }
            setVolumeRow(it, volume: v, shared: shared, host: host)
            if shared { it.indentationLevel = 2 }
        }
    }

    // MARK: Rows

    private func setVolumeRow(_ it: NSMenuItem, volume v: CapacitySampler.Volume,
                              shared: Bool, host: WidgetController) {
        var traits: [String] = []
        if !v.fileSystem.isEmpty { traits.append(v.fileSystem) }
        if !v.isLocal { traits.append("network") }
        else if v.isRemovable { traits.append("removable") }
        else if !v.isInternal { traits.append("external") }
        // In a shared container the per-volume "free" is the container's, so say what this
        // volume takes up instead; on its own, free space is the useful number.
        let value = shared
            ? "\(Format.memory(v.used)) used"
            : "\(Format.memory(v.available)) free of \(Format.memory(v.total))"
        host.setTableRow(it, label: v.name, value: value, copy: v.mountPoint,
                         valueColor: v.fraction > 0.9 ? .systemYellow : .labelColor,
                         toolTip: "\(v.mountPoint)\(traits.isEmpty ? "" : " · " + traits.joined(separator: " · ")) — click to copy the path")
    }

    @objc private func openStorageSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.settings.Storage")!)
    }
}
