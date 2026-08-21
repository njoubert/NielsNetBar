import Foundation
import SystemConfiguration

enum InterfaceKind { case wifi, ethernet, thunderbolt, usb, vpn, other }

/// The dot in the menu.
enum Dot { case green, yellow, gray }

struct InterfaceInfo {
    let bsdName: String
    let displayName: String
    let kind: InterfaceKind
    var isPrimary = false
    var isUp = false            // IFF_UP
    var linkActive: Bool?       // SIOCGIFMEDIA; nil where media status does not apply (tunnels)
    var ipv4: [String] = []     // routable (non 169.254/8) addresses
    var ipv6: [String] = []     // global scope (non fe80::) addresses
    var selfAssigned: [String] = []   // 169.254.x.x — link but no DHCP
    var mac: String?
    var linkSpeed: UInt64?      // bits/s as negotiated: Ethernet media type, or Wi-Fi PHY rate
    var serviceOrder = Int.max  // position in System Settings › Network
    var wifi: WiFiInfo?
    var gateway: String?        // set on the primary interface only
    var gateway6: String?
    var dns: [String] = []

    var hasAddress: Bool { !ipv4.isEmpty || !ipv6.isEmpty }

    /// Green: link up and a usable address. Yellow: link up, no (or only a self-assigned)
    /// address. Gray: down, no cable, radio off.
    var dot: Dot {
        guard isUp, linkActive != false else { return .gray }
        if kind == .wifi, let w = wifi, !w.isAssociated { return .gray }
        return hasAddress ? .green : .yellow
    }
}

struct NetworkSnapshot {
    var interfaces: [InterfaceInfo] = []
    var primary: String?
}

/// Enumerates the interfaces worth showing and everything we can learn about them.
enum Interfaces {

    static func snapshot() -> NetworkSnapshot {
        var byName: [String: InterfaceInfo] = [:]

        // 1. Hardware ports as System Settings knows them: gives the human name
        //    ("Wi-Fi", "Thunderbolt 2", "USB 10/100/1000 LAN") and the type.
        if let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] {
            for iface in all {
                guard let bsd = SCNetworkInterfaceGetBSDName(iface) as String? else { continue }
                let type = SCNetworkInterfaceGetInterfaceType(iface) as String? ?? ""
                // Bridges only mirror their member ports; VLANs/bonds are rare enough to skip.
                if type == "Bridge" { continue }
                var name = SCNetworkInterfaceGetLocalizedDisplayName(iface) as String? ?? bsd
                // "Ethernet Adapter (en6)" — the menu shows the BSD name separately.
                if name.hasSuffix(" (\(bsd))") { name = String(name.dropLast(bsd.count + 3)) }
                let kind: InterfaceKind
                if type == kSCNetworkInterfaceTypeIEEE80211 as String { kind = .wifi }
                else if name.localizedCaseInsensitiveContains("thunderbolt") { kind = .thunderbolt }
                else if name.localizedCaseInsensitiveContains("usb") { kind = .usb }
                else if type == kSCNetworkInterfaceTypeEthernet as String { kind = .ethernet }
                else { kind = .other }
                var info = InterfaceInfo(bsdName: bsd, displayName: name, kind: kind)
                info.mac = SCNetworkInterfaceGetHardwareAddressString(iface) as String?
                byName[bsd] = info
            }
        }

        // 2. Addresses and flags from the kernel. Tunnels (utun/ipsec/ppp…) are not hardware
        //    ports, so they only appear here — and only earn a row while they carry an address.
        let addrs = readAddresses()
        for (bsd, a) in addrs {
            if byName[bsd] == nil {
                guard isTunnelName(bsd), a.up, !a.ipv4.isEmpty || !a.ipv6.isEmpty else { continue }
                byName[bsd] = InterfaceInfo(bsdName: bsd, displayName: "VPN", kind: .vpn)
            }
            byName[bsd]!.isUp = a.up
            byName[bsd]!.ipv4 = a.ipv4
            byName[bsd]!.ipv6 = a.ipv6
            byName[bsd]!.selfAssigned = a.selfAssigned
            if byName[bsd]!.mac == nil { byName[bsd]!.mac = a.mac }
        }

        // 3. Link status + negotiated Ethernet speed, Wi-Fi details.
        for bsd in byName.keys {
            var info = byName[bsd]!
            if info.kind != .vpn, let m = mediaStatus(bsd) {
                info.linkActive = m.active
                info.linkSpeed = m.speed
            }
            if info.kind == .wifi, let w = WiFiInfo.read(bsdName: bsd) {
                info.wifi = w
                if w.txRate > 0 { info.linkSpeed = UInt64(w.txRate * 1_000_000) }
                if !w.powerOn { info.linkActive = false }
            }
            byName[bsd] = info
        }

        // 4. Primary interface, router, DNS, service order.
        var snap = NetworkSnapshot()
        let store = SCDynamicStoreCreate(nil, "NielsNetBar" as CFString, nil, nil)
        func global(_ key: String) -> [String: Any]? {
            guard let store else { return nil }
            return SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any]
        }
        let v4 = global("State:/Network/Global/IPv4")
        let v6 = global("State:/Network/Global/IPv6")
        let dns = global("State:/Network/Global/DNS")?["ServerAddresses"] as? [String] ?? []
        snap.primary = v4?["PrimaryInterface"] as? String ?? v6?["PrimaryInterface"] as? String
        if let p = snap.primary, byName[p] != nil {
            byName[p]!.isPrimary = true
            byName[p]!.gateway = v4?["Router"] as? String
            byName[p]!.gateway6 = v6?["Router"] as? String
            byName[p]!.dns = dns
        }
        for (bsd, order) in serviceOrder() where byName[bsd] != nil {
            byName[bsd]!.serviceOrder = order
        }

        // Primary first, then green → yellow → gray, then the System Settings order.
        snap.interfaces = byName.values.sorted { a, b in
            if a.isPrimary != b.isPrimary { return a.isPrimary }
            let ra = rank(a.dot), rb = rank(b.dot)
            if ra != rb { return ra < rb }
            if a.serviceOrder != b.serviceOrder { return a.serviceOrder < b.serviceOrder }
            return a.bsdName.localizedStandardCompare(b.bsdName) == .orderedAscending
        }
        return snap
    }

    private static func rank(_ d: Dot) -> Int {
        switch d { case .green: return 0; case .yellow: return 1; case .gray: return 2 }
    }

    private static func isTunnelName(_ n: String) -> Bool {
        ["utun", "ipsec", "ppp", "tun", "tap", "wg"].contains { n.hasPrefix($0) }
    }

    // MARK: getifaddrs

    private struct Addrs {
        var up = false
        var ipv4: [String] = []
        var ipv6: [String] = []
        var selfAssigned: [String] = []
        var mac: String?
    }

    private static func readAddresses() -> [String: Addrs] {
        var result: [String: Addrs] = [:]
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return result }
        defer { freeifaddrs(list) }

        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            defer { p = cur.pointee.ifa_next }
            let name = String(cString: cur.pointee.ifa_name)
            var a = result[name] ?? Addrs()
            a.up = (Int32(cur.pointee.ifa_flags) & IFF_UP) != 0
            if let sa = cur.pointee.ifa_addr {
                switch Int32(sa.pointee.sa_family) {
                case AF_INET:
                    sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                        var addr = sin.pointee.sin_addr
                        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                        if inet_ntop(AF_INET, &addr, &buf, socklen_t(buf.count)) != nil {
                            let s = String(cString: buf)
                            if s.hasPrefix("169.254.") { a.selfAssigned.append(s) } else { a.ipv4.append(s) }
                        }
                    }
                case AF_INET6:
                    sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { sin6 in
                        var addr = sin6.pointee.sin6_addr
                        // Skip link-local fe80::/10 (every interface has one; it says nothing).
                        let b0 = addr.__u6_addr.__u6_addr8.0, b1 = addr.__u6_addr.__u6_addr8.1
                        if b0 == 0xfe && (b1 & 0xc0) == 0x80 { return }
                        var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                        if inet_ntop(AF_INET6, &addr, &buf, socklen_t(buf.count)) != nil {
                            a.ipv6.append(String(cString: buf))
                        }
                    }
                case AF_LINK:
                    sa.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { dl in
                        let alen = Int(dl.pointee.sdl_alen)
                        guard alen == 6 else { return }
                        // The address follows the name inside sdl_data, which can run past the
                        // struct's nominal 12 bytes (sdl_len says how long it really is).
                        let nlen = Int(dl.pointee.sdl_nlen)
                        let start = MemoryLayout<sockaddr_dl>.offset(of: \.sdl_data)! + nlen
                        guard start + alen <= Int(dl.pointee.sdl_len) else { return }
                        let base = UnsafeRawPointer(dl)
                        let bytes: [UInt8] = (0..<alen).map { base.load(fromByteOffset: start + $0, as: UInt8.self) }
                        a.mac = bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
                    }
                default: break
                }
            }
            result[name] = a
        }
        return result
    }

    // MARK: SIOCGIFMEDIA

    /// `ioctl(SIOCGIFMEDIA)` — the same call `ifconfig` uses for its "status: active" and
    /// "media: … (10Gbase-T)" lines. The request number is `_IOWR('i', 56, struct ifmediareq)`
    /// with a 44-byte packed struct (name[16], current, mask, status, active, count, ulist*),
    /// which the C macro does not import into Swift, so it is spelled out here.
    private static let SIOCGIFMEDIA: UInt = 0xc02c6938

    static func mediaStatus(_ name: String) -> (active: Bool, speed: UInt64?)? {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var req = [UInt8](repeating: 0, count: 44)
        for (i, c) in name.utf8.prefix(15).enumerated() { req[i] = c }
        let rc = req.withUnsafeMutableBytes { ioctl(fd, SIOCGIFMEDIA, $0.baseAddress!) }
        guard rc == 0 else { return nil }
        let status = req.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 24, as: Int32.self) }
        let active = req.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 28, as: Int32.self) }
        guard status & 0x1 != 0 else { return nil }        // IFM_AVALID: driver reports link state
        let linkUp = status & 0x2 != 0                      // IFM_ACTIVE
        return (linkUp, linkUp ? ethernetSpeed(media: active) : nil)
    }

    /// Ethernet media subtype → bits/s. Constants from <net/if_media.h>.
    private static func ethernetSpeed(media: Int32) -> UInt64? {
        guard media & 0xe0 == 0x20 else { return nil }      // IFM_ETHER
        let sub = (media & 0x1f) | (media & 0x000f_0000)    // IFM_TMASK_COMPAT | IFM_TMASK_EXT
        switch sub {
        case 3: return 10_000_000                            // 10baseT
        case 6: return 100_000_000                           // 100baseTX
        case 11, 16, 25: return 1_000_000_000                // 1000baseSX/T/KX
        case 22: return 2_500_000_000                        // 2500baseT
        case 23: return 5_000_000_000                        // 5000baseT
        case 18, 19, 20, 21, 26, 27: return 10_000_000_000   // 10Gbase-SR/LR/CX4/T/KX4/KR
        default: return nil
        }
    }

    // MARK: Service order

    /// BSD name → index in System Settings › Network's service list (the order macOS
    /// itself uses to pick the primary interface).
    private static func serviceOrder() -> [String: Int] {
        var map: [String: Int] = [:]
        guard let prefs = SCPreferencesCreate(nil, "NielsNetBar" as CFString, nil),
              let set = SCNetworkSetCopyCurrent(prefs),
              let order = SCNetworkSetGetServiceOrder(set) as? [String] else { return map }
        for (i, id) in order.enumerated() {
            guard let svc = SCNetworkServiceCopy(prefs, id as CFString),
                  let iface = SCNetworkServiceGetInterface(svc),
                  let bsd = SCNetworkInterfaceGetBSDName(iface) as String? else { continue }
            if map[bsd] == nil { map[bsd] = i }
        }
        return map
    }
}
