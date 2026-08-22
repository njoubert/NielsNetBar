// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

/// The colours and fonts every widget draws with.
enum Theme {
    static let downColor = NSColor.systemGreen
    static let upColor = NSColor.systemBlue

    /// Two stacked lines fit a 22 pt menu bar at this size; a single line gets more room.
    static let stackedFont = NSFont.monospacedSystemFont(ofSize: 9, weight: .medium)
    static let stackedLineHeight: CGFloat = 10.5
    static let scalarFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
    /// A scalar widget's label is drawn as a column of letters, not a word: "MEM" written
    /// across costs about 30 pt of menu bar, stacked it costs 6. With six widgets that is
    /// the difference between fitting and not.
    static let stackedLabelFont = NSFont.monospacedSystemFont(ofSize: 6.5, weight: .bold)
    static let stackedLabelLineHeight: CGFloat = 6.9

    /// Digits at close to full contrast against the bar, a fixed value per appearance rather
    /// than the label colour with alpha (which on a dark bar comes out muddy). These were a
    /// mid-grey once and the numbers were hard to read at 9 pt next to every other menu bar
    /// item; near-white on dark and near-black on light is what the rest of the bar does.
    static let barTextColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 0.92, alpha: 1)
            : NSColor(white: 0.13, alpha: 1)
    }

    /// Menu rows: monospaced digits, so values line up down the column.
    static let monoFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
}

/// One line of a status item: a coloured glyph and a fixed-width value.
struct BarLine: Equatable {
    var glyph: String
    var glyphColor: NSColor
    /// Already padded to a fixed width — the bar must not change size between ticks.
    var value: String
}

/// The 60 s sparkline drawn beside a single-line widget. It is an area/line rather than
/// bars: sixty buckets in ~32 pt is well under a device pixel each, which bars cannot draw.
struct SparkStyle: Equatable {
    var color: NSColor
    /// nil scales to the window's peak; a number is a fixed ceiling (100 for a percentage).
    var fixedPeak: Double?
}

/// A filled bar beside a single line, for a level rather than a history: disk capacity
/// barely moves, so a sparkline of it is a flat line, while a fill bar says the same thing
/// at a glance.
struct BarGauge: Equatable {
    var color: NSColor
    var fraction: Double
}

/// What a widget wants in the menu bar this instant.
struct BarContent: Equatable {
    /// Top to bottom: two lines for a rate pair (network, disk I/O), one for a scalar.
    var lines: [BarLine]
    /// Scalars put their last minute next to the number. nil for the stacked pairs — there
    /// is no room, and the menu's chart is where their history lives.
    var spark: SparkStyle?
    /// A fill bar instead of a sparkline. At most one of the two.
    var gauge: BarGauge?
    /// Replaces the status item's tooltip when the bar is repainted. A widget that shows
    /// only a label and a sparkline puts its actual number here, so hovering still tells
    /// you what it is. Safe to update on repaint alone: no repaint means the sparkline did
    /// not move, which means the number did not either.
    var toolTip: String?
}

/// One thing the app can put in the menu bar: a sampler, a bar rendering, and a menu.
///
/// Widgets are switched on and off individually (`Widgets`); while a widget is off its
/// sampler is not registered on the ticker, so it costs nothing at all.
@MainActor
protocol Widget: AnyObject {
    /// Stable id: the defaults key (`widget.<id>.enabled`) and the status item's autosave
    /// name, so a widget keeps the slot the user dragged it to.
    var id: String { get }
    /// The name in the Widgets submenu.
    var title: String { get }
    /// The status item's tooltip.
    var barToolTip: String { get }
    /// Whether it is on for someone who has never touched the setting. Only the network
    /// widget is: an update must not silently claim four more slots in the menu bar.
    var defaultEnabled: Bool { get }
    /// The counter reader behind it.
    var sampler: any Sampler { get }
    /// Set by the controller that owns this widget's status item, so callbacks that arrive
    /// between ticks (public IP, Location) can refresh rows while the menu is open.
    var host: WidgetController? { get set }

    /// What to draw in the bar right now.
    func barContent() -> BarContent
    /// This widget's own rows. The shared tail is appended after.
    func buildMenu(into menu: NSMenu, host: WidgetController)
    /// Rows that belong in the shared settings block, under Launch at Login
    /// (the network's "Open Network Settings…").
    func settingsItems(host: WidgetController) -> [NSMenuItem]
    /// Refresh the rows that move while the menu is open.
    func updateOpenMenu()
    /// The menu closed — drop hover state and anything else tied to it being on screen.
    func menuDidClose()
}

extension Widget {
    func settingsItems(host: WidgetController) -> [NSMenuItem] { [] }
    func menuDidClose() {}
}
