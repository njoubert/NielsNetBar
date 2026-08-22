// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

/// Every widget the app knows about, which of them are switched on, and the one timer and
/// the visibility state they share.
@MainActor
final class Widgets: NSObject {

    /// 0.5 Hz is there for people who want this to cost as close to nothing as a menu bar
    /// monitor can: at a two-second interval every widget samples and repaints half as often.
    static let hzOptions: [Double] = [0.5, 1, 2, 5]
    static let hzDefaultsKey = "updateHz"

    static func rateTitle(_ hz: Double) -> String {
        switch hz {
        case 0.5: return "0.5 Hz (every 2 seconds)"
        case 1: return "1 Hz (every second)"
        default: return "\(Int(hz)) Hz"
        }
    }

    let ticker: Ticker
    /// In the order the Widgets submenu lists them.
    let all: [any Widget]

    private var controllers: [String: WidgetController] = [:]
    /// Why nobody can see the menu bar right now: displays asleep, screen locked, or
    /// another user's session in front. While any apply, sampling continues (charts and
    /// "since launch" totals stay honest) but no bar is repainted.
    private var hiddenReasons: Set<String> = []
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    init(hz: Double) {
        ticker = Ticker(interval: 1 / hz)
        all = [NetworkWidget(), CPUWidget(), GPUWidget(), MemoryWidget(), DiskIOWidget(), CapacityWidget()]
        super.init()
    }

    deinit {
        for (center, token) in observers { center.removeObserver(token) }
    }

    func start() {
        for w in all where isEnabled(w) { show(w) }
        // The app has no Dock icon and no window, so with every widget off there would be
        // no way back in — and no way to quit but Activity Monitor. Fall back to the first.
        if controllers.isEmpty, let first = all.first { setEnabled(first, true) }
        observeVisibility()
        ticker.start()
    }

    var isHidden: Bool { !hiddenReasons.isEmpty }

    /// For `--dump-bar`: the named widget, or whichever is showing if no name is given.
    func controller(named id: String?) -> WidgetController? {
        if let id { return controllers[id] }
        return all.compactMap { controllers[$0.id] }.first
    }

    // MARK: On and off

    private func key(_ w: any Widget) -> String { "widget.\(w.id).enabled" }

    func isEnabled(_ w: any Widget) -> Bool {
        UserDefaults.standard.object(forKey: key(w)) as? Bool ?? w.defaultEnabled
    }

    func setEnabled(_ w: any Widget, _ on: Bool) {
        UserDefaults.standard.set(on, forKey: key(w))
        if on { show(w) } else { hide(w) }
    }

    /// Switching a widget on registers its sampler — and only then does it start costing
    /// anything. Priming happens at that moment, so its first rate is measured from now.
    private func show(_ w: any Widget) {
        guard controllers[w.id] == nil else { return }
        ticker.add(w.sampler)
        controllers[w.id] = WidgetController(widget: w, widgets: self)
    }

    private func hide(_ w: any Widget) {
        guard let c = controllers.removeValue(forKey: w.id) else { return }
        ticker.remove(w.sampler)
        c.dispose()
    }

    /// The Widgets submenu, rebuilt with the menu that carries it.
    func buildSubmenu() -> NSMenu {
        let m = NSMenu()
        // Without this AppKit recomputes each item's enabled state from its target/action
        // and re-enables the last-widget item that `isEnabled = false` below turns off.
        m.autoenablesItems = false
        for w in all {
            let it = NSMenuItem(title: w.title, action: #selector(toggle(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = w.id
            it.state = isEnabled(w) ? .on : .off
            if it.state == .on, controllers.count == 1 {
                it.isEnabled = false
                it.toolTip = "The last widget cannot be hidden — there would be no menu left to bring it back."
            }
            m.addItem(it)
        }
        return m
    }

    @objc private func toggle(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let w = all.first(where: { $0.id == id }) else { return }
        setEnabled(w, !isEnabled(w))
    }

    // MARK: Visibility

    /// Pause bar repaints while the menu bar is not on screen. A long-running app spends
    /// most of its life behind a locked screen or a sleeping display; painting text into
    /// the status bar twice a second there is the single biggest waste.
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
        let wasHidden = isHidden
        if hidden { hiddenReasons.insert(reason) } else { hiddenReasons.remove(reason) }
        if wasHidden, !isHidden {
            for c in controllers.values { c.updateBar() }   // catch up right away
        }
    }
}
