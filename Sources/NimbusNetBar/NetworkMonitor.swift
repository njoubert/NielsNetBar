// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Per-interface byte counters as the kernel reports them.
struct InterfaceCounters {
    var inBytes: UInt64
    var outBytes: UInt64
    /// Link speed the driver reports (bits/s). 32-bit in practice: a 10 GbE port shows
    /// 0xFFFFFFFF here, so `Interfaces` prefers the media type from SIOCGIFMEDIA.
    var baudrate: UInt64
}

/// Turns the kernel's interface counters into rates, once per tick of the shared `Ticker`.
///
/// Counters come from `sysctl(NET_RT_IFLIST2)`, which hands back one `if_msghdr2` per
/// interface with 64-bit `ifi_ibytes`/`ifi_obytes` — no subprocess, no parsing, tens of
/// microseconds per tick.
@MainActor
final class NetworkMonitor: Sampler {

    struct Rate { var down: Double = 0; var up: Double = 0 }   // bits per second

    /// Rate per BSD interface name, every interface the kernel lists.
    private(set) var rates: [String: Rate] = [:]
    /// Sum over the interfaces `countsTowardTotal` accepts.
    private(set) var total = Rate()
    /// Bytes moved since the app started, same interface set as `total`.
    private(set) var sinceLaunchIn: UInt64 = 0
    private(set) var sinceLaunchOut: UInt64 = 0

    /// Called on the main thread after every sample.
    var onTick: (() -> Void)?

    /// The last minute of `total`, one entry per second: ↑ upload above the baseline,
    /// ↓ download below. Recorded from launch, so the chart is full the first time the
    /// menu opens.
    private var hist = History(now: 0)
    var history: [Sample] { hist.samples }
    /// Whether the last sample closed a second — see `History.advanced`.
    var historyAdvanced: Bool { hist.advanced }

    private var last: [String: InterfaceCounters] = [:]
    private var lastTime: TimeInterval = 0

    // MARK: Sampler

    func prime(at now: TimeInterval) {
        last = NetworkMonitor.readCounters()
        lastTime = now
        hist = History(now: now)
    }

    func sample(at now: TimeInterval) {
        let dt = now - lastTime
        guard dt > 0.05 else { return }
        let current = NetworkMonitor.readCounters()
        // A failed read (it can't really fail, but if it did) must not wipe the baseline,
        // or the next tick has nothing to diff against either.
        guard !current.isEmpty else { return }

        var newRates: [String: Rate] = [:]
        var sum = Rate()
        for (name, c) in current {
            guard let prev = last[name] else { continue }
            // Counters can reset (interface re-created); treat a backwards step as no traffic.
            let dIn = c.inBytes >= prev.inBytes ? c.inBytes - prev.inBytes : 0
            let dOut = c.outBytes >= prev.outBytes ? c.outBytes - prev.outBytes : 0
            let r = Rate(down: Double(dIn) * 8 / dt, up: Double(dOut) * 8 / dt)
            newRates[name] = r
            if NetworkMonitor.countsTowardTotal(name) {
                sum.down += r.down
                sum.up += r.up
                sinceLaunchIn += dIn
                sinceLaunchOut += dOut
            }
        }
        rates = newRates
        total = sum
        last = current
        lastTime = now
        hist.add(Sample(primary: sum.up, secondary: sum.down), dt: dt, at: now)
        onTick?()
    }

    /// Which interfaces make up the number in the menu bar: the physical ports (`en*`,
    /// plus dial-up/cellular style `ppp*`/`pdp_ip*`). Tunnels (`utun*`) are deliberately
    /// left out — their packets are re-sent, encrypted, over a physical port and would be
    /// counted twice. Loopback, AirDrop (`awdl`/`llw`), bridges, `ap1` and the rest never count.
    nonisolated static func countsTowardTotal(_ name: String) -> Bool {
        name.hasPrefix("en") || name.hasPrefix("ppp") || name.hasPrefix("pdp_ip")
    }

    /// One `sysctl(NET_RT_IFLIST2)` walk → counters keyed by BSD name.
    ///
    /// The name is read from the `sockaddr_dl` (RTA_IFP) that follows each `if_msghdr2`
    /// in the same buffer. Do not be tempted by `if_indextoname`: on Darwin it is
    /// implemented as a full `getifaddrs()` walk, which made this ~15× slower per interface.
    nonisolated static func readCounters() -> [String: InterfaceCounters] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &len, nil, 0) == 0, len > 0 else { return [:] }
        // Slack: an interface appearing between the size probe and the read would
        // otherwise fail the read with ENOMEM.
        len += 4096
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, UInt32(mib.count), &buf, &len, nil, 0) == 0 else { return [:] }

        var result: [String: InterfaceCounters] = [:]
        let hdrSize = MemoryLayout<if_msghdr2>.size
        let nameOffset = MemoryLayout<sockaddr_dl>.offset(of: \.sdl_data)!
        buf.withUnsafeBytes { raw in
            var off = 0
            while off + MemoryLayout<if_msghdr>.size <= len {
                let hdr = raw.loadUnaligned(fromByteOffset: off, as: if_msghdr.self)
                let msglen = Int(hdr.ifm_msglen)
                guard msglen > 0 else { break }
                let end = off + msglen
                if Int32(hdr.ifm_type) == RTM_IFINFO2, off + hdrSize <= len {
                    let h2 = raw.loadUnaligned(fromByteOffset: off, as: if_msghdr2.self)
                    // The sockaddr_dl on the wire is only as long as sdl_len says (it can be
                    // shorter than the struct), so read the two header bytes we need, not
                    // the whole struct.
                    let dl = off + hdrSize
                    if h2.ifm_addrs & RTA_IFP != 0, dl + nameOffset <= len {
                        let family = Int32(raw[dl + 1])                       // sdl_family
                        let nlen = Int(raw[dl + 5])                            // sdl_nlen
                        let nameStart = dl + nameOffset
                        if family == AF_LINK, nlen > 0, nameStart + nlen <= min(end, len) {
                            let name = String(decoding: raw[nameStart..<nameStart + nlen], as: UTF8.self)
                            result[name] = InterfaceCounters(
                                inBytes: h2.ifm_data.ifi_ibytes,
                                outBytes: h2.ifm_data.ifi_obytes,
                                baudrate: h2.ifm_data.ifi_baudrate)
                        }
                    }
                }
                off = end
            }
        }
        return result
    }
}
