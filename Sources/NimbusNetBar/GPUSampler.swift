// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import IOKit
import Metal

/// GPU load from the IOKit registry: every `IOAccelerator` service publishes a
/// `PerformanceStatistics` dictionary with a utilization percentage and its memory use.
/// No privileges, no `powermetrics` — and, for the same reason, no Neural Engine or media
/// engine figures and nothing per-process, none of which are exposed.
@MainActor
final class GPUSampler: Sampler {

    struct GPU {
        var name: String
        var utilization: Double = 0        // 0…1
        var inUse: UInt64 = 0              // resident memory
        var allocated: UInt64 = 0          // address space reserved, not resident
        var recommendedMax: UInt64 = 0
        var isLowPower = false
        var isRemovable = false
        var unified = false
    }

    private(set) var gpus: [GPU] = []
    /// What the bar shows: the busiest GPU, since on a two-GPU Mac only one is doing the work.
    var utilization: Double { gpus.map(\.utilization).max() ?? 0 }

    var onTick: (() -> Void)?
    private var hist = History(now: 0)
    var history: [Sample] { hist.samples }
    var historyAdvanced: Bool { hist.advanced }
    private var lastTime: TimeInterval = 0

    /// Matched once, not per tick. Re-matching the registry every half second would be the
    /// `if_indextoname` mistake in a new costume.
    private var services: [io_service_t] = []
    private var devices: [MTLDevice] = []

    deinit {
        for s in services where s != 0 { IOObjectRelease(s) }
    }

    // MARK: Sampler

    func prime(at now: TimeInterval) {
        lastTime = now
        hist = History(now: now)
        match()
        read()
    }

    func sample(at now: TimeInterval) {
        let dt = now - lastTime
        guard dt > 0.05 else { return }
        lastTime = now
        read()
        hist.add(Sample(primary: utilization * 100), dt: dt, at: now)
        onTick?()
    }

    /// Pair each Metal device with its accelerator service. `MTLDevice.registryID` *is* the
    /// IOKit registry entry id of the `IOAccelerator` (checked: Metal reports 4294968365 for
    /// the entry `ioreg` shows as id 0x10000042d), so they match exactly rather than by name.
    private func match() {
        for s in services where s != 0 { IOObjectRelease(s) }
        services = []
        devices = []
        // MTLCopyAllDevices lists every GPU without forcing a switch to the discrete one,
        // which MTLCreateSystemDefaultDevice would do on an older dual-GPU Mac.
        for device in MTLCopyAllDevices() {
            let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                      IORegistryEntryIDMatching(device.registryID))
            devices.append(device)
            services.append(service)
        }
    }

    private func read() {
        var out: [GPU] = []
        out.reserveCapacity(devices.count)
        for (i, device) in devices.enumerated() {
            var gpu = GPU(name: device.name)
            gpu.recommendedMax = device.recommendedMaxWorkingSetSize
            gpu.isLowPower = device.isLowPower
            gpu.isRemovable = device.isRemovable
            gpu.unified = device.hasUnifiedMemory
            if i < services.count, services[i] != 0,
               let stats = IORegistryEntryCreateCFProperty(services[i], "PerformanceStatistics" as CFString,
                                                           kCFAllocatorDefault, 0)?
                                .takeRetainedValue() as? [String: Any] {
                if let u = stats["Device Utilization %"] as? Int { gpu.utilization = Double(u) / 100 }
                if let m = stats["In use system memory"] as? Int { gpu.inUse = UInt64(max(m, 0)) }
                if let m = stats["Alloc system memory"] as? Int { gpu.allocated = UInt64(max(m, 0)) }
            }
            out.append(gpu)
        }
        gpus = out
    }
}
