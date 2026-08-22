// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// One metric's counter reader. Everything the bar can show is one of these, and they all
/// run off the single `Ticker` — never a timer each: this app's whole CPU budget rests on
/// there being exactly one wake-up per interval no matter how many widgets are on.
@MainActor
protocol Sampler: AnyObject {
    /// The last minute, one entry per second: the menu's chart and the bar's sparkline
    /// both draw this.
    var history: [Sample] { get }
    /// Whether the last sample closed a second (`History.advanced`). The bar repaints on
    /// this rather than on every tick — see `WidgetController.updateBar`.
    var historyAdvanced: Bool { get }
    /// Whether this sampler records a history at all. One that does drives its widget's
    /// repaints off the second boundary; one that does not (disk capacity, which changes a
    /// few times a day) repaints whenever what it shows changes.
    var keepsHistory: Bool { get }
    /// Called on the main thread after every sample. The widget's controller sets it.
    var onTick: (() -> Void)? { get set }

    /// Seed the baseline. Called when the sampler joins the ticker, so its first rate is
    /// measured from that moment rather than from whenever the app started.
    func prime(at now: TimeInterval)
    /// Read the counters and fold one sample into the history. `now` is the tick's shared
    /// clock reading; a sampler keeps its own previous time, because one that skips a read
    /// must not lose the interval that read would have covered.
    func sample(at now: TimeInterval)
}

extension Sampler {
    var keepsHistory: Bool { true }
}

/// The single timer behind every widget.
@MainActor
final class Ticker {

    /// Seconds between samples. Assigning restarts the timer.
    var interval: TimeInterval {
        didSet { if timer != nil { start() } }
    }

    private var samplers: [any Sampler] = []
    private var timer: Timer?

    init(interval: TimeInterval) { self.interval = interval }

    /// Register a sampler (a widget being switched on) and prime it.
    func add(_ s: any Sampler) {
        guard !samplers.contains(where: { $0 === s }) else { return }
        s.prime(at: Ticker.now())
        samplers.append(s)
    }

    /// Unregister a sampler (a widget being switched off): it stops costing anything.
    func remove(_ s: any Sampler) {
        samplers.removeAll { $0 === s }
    }

    func start() {
        timer?.invalidate()
        // The timer fires on the main run loop, so it is already on the main actor; no
        // need to bounce through a Task (which would cost a second wake-up per tick).
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // A little slack lets the kernel coalesce our wake-up with others (energy).
        t.tolerance = interval / 10
        // .common so the bar keeps updating while a dropdown menu is open (menu tracking
        // runs the run loop in a mode the default timer mode is not part of).
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// One clock reading per tick, shared by every sampler.
    private func tick() {
        let now = Ticker.now()
        for s in samplers { s.sample(at: now) }
    }

    /// Seconds on a monotonic clock that keeps counting through sleep (CLOCK_MONOTONIC
    /// does on Darwin). Wall-clock time can step backwards (NTP) and would stall sampling;
    /// CLOCK_UPTIME_RAW stops during sleep and would misattribute the bytes moved across it.
    nonisolated static func now() -> TimeInterval {
        Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1e9
    }
}
