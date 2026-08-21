import Foundation

/// Per-interface byte counters as the kernel reports them.
struct InterfaceCounters {
    var inBytes: UInt64
    var outBytes: UInt64
    /// Link speed the driver reports (bits/s). 32-bit in practice: a 10 GbE port shows
    /// 0xFFFFFFFF here, so `Interfaces` prefers the media type from SIOCGIFMEDIA.
    var baudrate: UInt64
}

/// Samples the kernel's interface counters on a timer and turns them into rates.
///
/// Counters come from `sysctl(NET_RT_IFLIST2)`, which hands back one `if_msghdr2` per
/// interface with 64-bit `ifi_ibytes`/`ifi_obytes` — no subprocess, no parsing, a few
/// microseconds per tick.
@MainActor
final class NetworkMonitor {

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

    var interval: TimeInterval {
        didSet { if timer != nil { start() } }
    }

    private var timer: Timer?
    private var last: [String: InterfaceCounters] = [:]
    private var lastTime = Date()

    init(interval: TimeInterval) {
        self.interval = interval
        last = NetworkMonitor.readCounters()
        lastTime = Date()
    }

    func start() {
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        // .common so the bar keeps updating while the dropdown menu is open (menu
        // tracking runs the run loop in a mode the default timer mode is not part of).
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func sample() {
        let now = Date()
        let dt = now.timeIntervalSince(lastTime)
        guard dt > 0.05 else { return }
        let current = NetworkMonitor.readCounters()

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
    nonisolated static func readCounters() -> [String: InterfaceCounters] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &len, nil, 0) == 0, len > 0 else { return [:] }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, UInt32(mib.count), &buf, &len, nil, 0) == 0 else { return [:] }

        var result: [String: InterfaceCounters] = [:]
        buf.withUnsafeBytes { raw in
            var off = 0
            while off + MemoryLayout<if_msghdr>.size <= len {
                let hdr = raw.loadUnaligned(fromByteOffset: off, as: if_msghdr.self)
                let msglen = Int(hdr.ifm_msglen)
                guard msglen > 0 else { break }
                if Int32(hdr.ifm_type) == RTM_IFINFO2, off + MemoryLayout<if_msghdr2>.size <= len {
                    let h2 = raw.loadUnaligned(fromByteOffset: off, as: if_msghdr2.self)
                    var cname = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
                    if if_indextoname(UInt32(h2.ifm_index), &cname) != nil {
                        result[String(cString: cname)] = InterfaceCounters(
                            inBytes: h2.ifm_data.ifi_ibytes,
                            outBytes: h2.ifm_data.ifi_obytes,
                            baudrate: h2.ifm_data.ifi_baudrate)
                    }
                }
                off += msglen
            }
        }
        return result
    }
}
