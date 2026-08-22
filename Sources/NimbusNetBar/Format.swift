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

    /// Fixed-width rate for the menu bar: three characters of value and a four-character
    /// unit — `" 36 kb/s"`, `"1.2 Mb/s"`, `"341 Mb/s"`. Deliberately coarser than `rate`:
    /// the bar is a glanceable indicator and the menu carries the precise figure, so three
    /// characters of value buy back the width `999.9 kbps` cost. Fixed width because the
    /// status item must not change size between ticks; the bar's font is monospaced, so
    /// padding the value with spaces is enough to hold the columns still.
    ///
    /// Both roll-over points are set so the value can never reach a fourth character: below
    /// 9.95 it keeps a decimal (`"9.9"`), above it rounds (`"36"`), and the unit steps up at
    /// 999.5 rather than 1000 so we never print `"1000"`.
    static func rateFixed(bitsPerSecond bps: Double) -> String {
        let bits = max(bps, 0)
        let value: Double, unit: String
        if bits < 999_500 { value = bits / 1_000; unit = "kb/s" }
        else if bits < 999_500_000 { value = bits / 1_000_000; unit = "Mb/s" }
        else { value = bits / 1_000_000_000; unit = "Gb/s" }
        let text = value < 9.95 ? String(format: "%.1f", value) : String(format: "%.0f", value)
        return String(repeating: " ", count: max(0, 3 - text.count)) + text + " " + unit
    }

    /// The menu's headline rate, at three significant figures — `("16.4", "kbps")`,
    /// `("115", "kbps")`, `("341", "Mbps")`. The same rule the bar uses, one digit wider:
    /// it caps the value at four characters (`"99.9"`) instead of the five `rate` can need
    /// (`"999.9"`), which is what lets the headline stay large without the two columns
    /// pushing the menu wider. Interface rows keep `rateCompact`'s full precision.
    ///
    /// The unit steps up at 999.5 rather than 1000 so the value can never round to `"1000"`
    /// and overflow the field reserved for it.
    static func rateHeadline(bitsPerSecond bps: Double) -> (value: String, unit: String) {
        let bits = max(bps, 0)
        let value: Double, unit: String
        if bits < 999_500 { value = bits / 1_000; unit = "kbps" }
        else if bits < 999_500_000 { value = bits / 1_000_000; unit = "Mbps" }
        else { value = bits / 1_000_000_000; unit = "Gbps" }
        return (value < 99.95 ? String(format: "%.1f", value) : String(format: "%.0f", value), unit)
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

    /// Disk throughput, SI like the network's bits: "12.4 MB/s".
    static func bytesPerSecond(_ v: Double) -> String {
        let x = max(v, 0)
        if x < 1_000_000 { return String(format: "%.1f kB/s", x / 1_000) }
        if x < 1_000_000_000 { return String(format: "%.1f MB/s", x / 1_000_000) }
        return String(format: "%.1f GB/s", x / 1_000_000_000)
    }

    /// Fixed-width throughput for the menu bar, on the same three-character discipline as
    /// `rateFixed`: a decimal below 9.95, whole numbers above it, and the unit steps up at
    /// 999.5 so the value can never reach a fourth character. Every unit is four characters
    /// and the bar's font is monospaced, so padding the value holds the column still.
    static func bytesPerSecondFixed(_ v: Double) -> String {
        let bytes = max(v, 0)
        let value: Double, unit: String
        if bytes < 999_500 { value = bytes / 1_000; unit = "kB/s" }
        else if bytes < 999_500_000 { value = bytes / 1_000_000; unit = "MB/s" }
        else { value = bytes / 1_000_000_000; unit = "GB/s" }
        let text = value < 9.95 ? String(format: "%.1f", value) : String(format: "%.0f", value)
        return String(repeating: " ", count: max(0, 3 - text.count)) + text + " " + unit
    }

    /// Memory sizes, binary (×1024): macOS calls a 25,769,803,776-byte Mac a "24 GB" one,
    /// so RAM does not use the SI convention `bytes` uses for traffic and disks.
    static func memory(_ n: UInt64) -> String {
        let v = Double(n)
        if v < 1024 { return "\(n) B" }
        if v < 1024 * 1024 { return String(format: "%.0f KB", v / 1024) }
        if v < 1024 * 1024 * 1024 { return String(format: "%.0f MB", v / (1024 * 1024)) }
        let g = v / (1024 * 1024 * 1024)
        // A 24 GiB Mac says "24 GB", not "24.00 GB" — but only for a value that really is
        // round. The tolerance is tight on purpose: at 0.005 a 4.998 GB reading also came
        // out as "5 GB", which looks like a different precision from the "6.23 GB" beside it.
        if g >= 100 || abs(g - g.rounded()) < 0.0005 { return String(format: "%.0f GB", g) }
        return String(format: "%.2f GB", g)
    }

    /// A percentage for the menu bar: always four characters, `  4%` … `100%`, so the
    /// status item does not change width between ticks.
    static func percentFixed(_ p: Double) -> String {
        String(format: "%3.0f%%", min(max(p, 0), 100))
    }

    /// A percentage for menu rows and chart labels: "34%".
    static func percent(_ p: Double) -> String {
        String(format: "%.0f%%", min(max(p, 0), 100))
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
