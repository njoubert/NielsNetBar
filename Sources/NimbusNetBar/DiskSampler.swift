// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import IOKit

/// Disk throughput from the IOKit registry: every `IOBlockStorageDriver` publishes a
/// `Statistics` dictionary with cumulative byte and operation counts, differenced between
/// ticks the same way the network's counters are.
@MainActor
final class DiskSampler: Sampler {

    struct Rate { var read: Double = 0; var write: Double = 0 }   // bytes per second

    struct Device {
        var name: String            // "APPLE SSD AP0512Z Media"
        var bsdName: String?        // "disk0"
        var rate = Rate()
    }

    private struct Counters { var read: UInt64 = 0; var write: UInt64 = 0 }

    private(set) var devices: [Device] = []
    private(set) var total = Rate()
    private(set) var sinceLaunchRead: UInt64 = 0
    private(set) var sinceLaunchWritten: UInt64 = 0

    var onTick: (() -> Void)?
    private var hist = History(now: 0)
    var history: [Sample] { hist.samples }
    var historyAdvanced: Bool { hist.advanced }
    private var lastTime: TimeInterval = 0

    /// Matched once, like the GPU's — never per tick.
    private var services: [io_service_t] = []
    private var names: [(name: String, bsd: String?)] = []
    private var last: [Counters] = []

    deinit {
        for s in services where s != 0 { IOObjectRelease(s) }
    }

    // MARK: Sampler

    func prime(at now: TimeInterval) {
        lastTime = now
        hist = History(now: now)
        match()
        last = readCounters()
        devices = names.map { Device(name: $0.name, bsdName: $0.bsd) }
    }

    func sample(at now: TimeInterval) {
        let dt = now - lastTime
        guard dt > 0.05 else { return }
        let current = readCounters()
        guard current.count == last.count, !current.isEmpty else {
            last = current
            lastTime = now
            return
        }
        var sum = Rate()
        var out: [Device] = []
        out.reserveCapacity(current.count)
        for (i, c) in current.enumerated() {
            let p = last[i]
            // A counter that went backwards means the device was re-enumerated; treat it
            // as no traffic rather than as an enormous burst.
            let read = c.read >= p.read ? c.read - p.read : 0
            let wrote = c.write >= p.write ? c.write - p.write : 0
            let rate = Rate(read: Double(read) / dt, write: Double(wrote) / dt)
            let n = i < names.count ? names[i] : (name: "Disk \(i)", bsd: nil)
            out.append(Device(name: n.name, bsdName: n.bsd, rate: rate))
            sum.read += rate.read
            sum.write += rate.write
            sinceLaunchRead += read
            sinceLaunchWritten += wrote
        }
        devices = out
        total = sum
        last = current
        lastTime = now
        // Writes grow up from the baseline, reads hang below — the same shape as the
        // network's ↑/↓, so the two rate widgets read the same way.
        hist.add(Sample(primary: sum.write, secondary: sum.read), dt: dt, at: now)
        onTick?()
    }

    private func match() {
        for s in services where s != 0 { IOObjectRelease(s) }
        services = []
        names = []
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOBlockStorageDriver"),
                                           &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            services.append(service)
            names.append(DiskSampler.identify(service))
        }
    }

    /// The driver itself carries no name worth showing; its child `IOMedia` is the one
    /// called "APPLE SSD AP0512Z Media" and holding the BSD name.
    private static func identify(_ service: io_service_t) -> (name: String, bsd: String?) {
        var child: io_registry_entry_t = 0
        guard IORegistryEntryGetChildEntry(service, kIOServicePlane, &child) == KERN_SUCCESS, child != 0 else {
            return ("Disk", nil)
        }
        defer { IOObjectRelease(child) }
        var buf = [CChar](repeating: 0, count: 128)   // io_name_t is 128 bytes
        let name = IORegistryEntryGetName(child, &buf) == KERN_SUCCESS ? String(cString: buf) : "Disk"
        let bsd = IORegistryEntryCreateCFProperty(child, "BSD Name" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
        return (name, bsd)
    }

    private func readCounters() -> [Counters] {
        services.map { service in
            guard service != 0,
                  let stats = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString,
                                                              kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any] else { return Counters() }
            return Counters(read: UInt64(max(stats["Bytes (Read)"] as? Int ?? 0, 0)),
                            write: UInt64(max(stats["Bytes (Write)"] as? Int ?? 0, 0)))
        }
    }
}
