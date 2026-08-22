// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// One instant of a metric, in the shape the chart draws it: one or two series.
///
/// Scalar metrics (CPU, memory, GPU) use `primary` only. Paired ones (network, disk I/O)
/// put the series that grows *above* the baseline in `primary` and the one that hangs below
/// it in `secondary` — for the network that is ↑ upload and ↓ download.
struct Sample: Equatable {
    var primary: Double = 0
    var secondary: Double = 0
}

/// The last minute of a metric, one entry per second, oldest first.
///
/// Samples arrive at the tick rate and are folded into whole-second buckets, so the chart
/// and the bar's sparkline look the same whatever the rate. A sample covers the seconds its
/// own `dt` spans — at 0.5 Hz that is two of them, and both get its value. Seconds no sample
/// covers at all — sleep/wake, not a slow tick rate — are padded with zeros so the time axis
/// stays honest.
struct History {
    static let length = 60

    /// The longest a single sample may be taken to cover. Past this it is not a slow tick
    /// but a stall (sleep, a wedged run loop), and smearing one average across the whole
    /// stretch would invent traffic that never happened.
    static let maxSpread: TimeInterval = 4

    private(set) var samples: [Sample] = []
    /// Set by the `add` that closed a bucket: one more second has landed in `samples`.
    /// The bar's sparkline repaints on this rather than on every tick.
    private(set) var advanced = false

    private var bucketSecond: Int
    private var acc = Sample()             // value × time accumulated in the current second
    private var accTime: TimeInterval = 0  // and the time that covers

    init(now: TimeInterval) { bucketSecond = Int(now) }

    /// Fold one sample, covering the last `dt` seconds, into the current bucket.
    mutating func add(_ s: Sample, dt: TimeInterval, at now: TimeInterval) {
        advanced = false
        let second = Int(now)
        if second != bucketSecond {
            // Close the bucket we were filling…
            if accTime > 0 {
                samples.append(Sample(primary: acc.primary / accTime, secondary: acc.secondary / accTime))
            }
            // …then account for the seconds between it and this one. Those inside what
            // this sample actually covers take its value — at 0.5 Hz that is what stops
            // every other bucket reading as zero — and the rest are silence.
            if second - bucketSecond - 1 > 0 {
                let coversFrom = dt <= History.maxSpread ? Int((now - dt).rounded(.down)) : second
                // Never loop more than the ring holds, however long the machine was asleep.
                for sec in max(bucketSecond + 1, second - History.length)..<second {
                    samples.append(sec >= coversFrom ? s : Sample())
                }
            }
            if samples.count > History.length { samples.removeFirst(samples.count - History.length) }
            bucketSecond = second
            acc = Sample()
            accTime = 0
            advanced = true
        }
        acc.primary += s.primary * dt
        acc.secondary += s.secondary * dt
        accTime += dt
    }
}
