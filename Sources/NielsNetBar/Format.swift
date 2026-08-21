// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Number formatting for the bar and the menu.
enum Format {

    /// Bits per second → ("12.4", "Mbps"). SI prefixes (×1000), kbps at minimum so the
    /// bar never flips between "bps" and "kbps" widths at idle.
    static func rate(bitsPerSecond bps: Double) -> (value: String, unit: String) {
        let v = max(bps, 0)
        if v < 1_000_000 { return (String(format: "%.1f", v / 1_000), "kbps") }
        if v < 1_000_000_000 { return (String(format: "%.1f", v / 1_000_000), "Mbps") }
        return (String(format: "%.1f", v / 1_000_000_000), "Gbps")
    }

    /// Fixed-width rate for the menu bar: always `nnn.n Xbps` (5-char value), so the
    /// status item does not change width between ticks. 999.9 kbps → 1.0 Mbps.
    static func rateFixed(bitsPerSecond bps: Double) -> String {
        let (value, unit) = rate(bitsPerSecond: bps)
        return String(repeating: " ", count: max(0, 5 - value.count)) + value + " " + unit
    }

    /// Compact rate for menu rows: "12.4 Mbps".
    static func rateCompact(bitsPerSecond bps: Double) -> String {
        let (value, unit) = rate(bitsPerSecond: bps)
        return value + " " + unit
    }

    /// Byte totals, SI (×1000) to match the bits convention: "1.23 GB", "210 MB", "512 B".
    static func bytes(_ n: UInt64) -> String {
        let v = Double(n)
        if v < 1_000 { return "\(n) B" }
        if v < 1_000_000 { return String(format: "%.0f kB", v / 1_000) }
        if v < 1_000_000_000 { return String(format: "%.0f MB", v / 1_000_000) }
        if v < 1_000_000_000_000 { return String(format: "%.2f GB", v / 1_000_000_000) }
        return String(format: "%.2f TB", v / 1_000_000_000_000)
    }

    /// Link speed from bits per second: "10 Gbps", "2.5 Gbps", "100 Mbps".
    static func linkSpeed(bitsPerSecond bps: UInt64) -> String {
        let v = Double(bps)
        if v >= 1_000_000_000 {
            let g = v / 1_000_000_000
            return g == g.rounded() ? String(format: "%.0f Gbps", g) : String(format: "%.1f Gbps", g)
        }
        if v >= 1_000_000 { return String(format: "%.0f Mbps", v / 1_000_000) }
        return String(format: "%.0f kbps", v / 1_000)
    }
}
