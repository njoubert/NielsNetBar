// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation

/// Memory as `host_statistics64(HOST_VM_INFO64)` reports it, in the categories Activity
/// Monitor shows — because those are the ones people recognise, not because the kernel
/// hands them over that way.
@MainActor
final class MemorySampler: Sampler {

    struct Usage: Equatable {
        var app: UInt64 = 0          // anonymous pages that are not purgeable
        var wired: UInt64 = 0        // the kernel's, never paged out
        var compressed: UInt64 = 0
        var cached: UInt64 = 0       // file-backed and purgeable: reclaimable
        var active: UInt64 = 0       // recently used and not reclaimable on the spot
        var free: UInt64 = 0

        /// What is left once wired, active and compressed are accounted for — everything
        /// the system could hand to the next thing that asks, whether it is idle now or
        /// holding a cached file.
        var available: UInt64 {
            let spoken = wired + active + compressed
            return MemoryInfo.total > spoken ? MemoryInfo.total - spoken : 0
        }

        /// The pressure reading, as a fraction: memory that cannot be reclaimed at all —
        /// wired plus compressed — over the physical total. This is a *stated formula*, not
        /// a reproduction of Activity Monitor's undocumented pressure curve; the kernel's
        /// own three-state signal is shown next to it.
        var pressure: Double {
            MemoryInfo.total > 0 ? Double(wired + compressed) / Double(MemoryInfo.total) : 0
        }
        /// What "memory used" means here: everything that is not free and not reclaimable.
        var used: UInt64 { app + wired + compressed }
        var fraction: Double {
            MemoryInfo.total > 0 ? Double(used) / Double(MemoryInfo.total) : 0
        }
    }

    /// What the kernel says about pressure. It is a coarse signal — three states, not a
    /// curve — so it is shown as a row and never charted.
    enum Pressure: Equatable {
        case normal, warning, critical, unknown
        var text: String {
            switch self {
            case .normal: return "normal"
            case .warning: return "warning — the system is reclaiming"
            case .critical: return "critical — the system is out of room"
            case .unknown: return "unknown"
            }
        }
    }

    struct Swap: Equatable {
        var total: UInt64 = 0
        var used: UInt64 = 0
    }

    private(set) var usage = Usage()
    private(set) var pressure = Pressure.unknown
    private(set) var swap = Swap()
    /// Bytes per second moving between memory and disk.
    private(set) var pageInRate: Double = 0
    private(set) var pageOutRate: Double = 0

    /// Paging is bursty: a machine that pages a few thousand pages a minute still reports
    /// zero in most half-second ticks, so a per-tick rate reads "0.0 kB/s" almost always and
    /// tells nobody anything. These rates are taken over a rolling few seconds instead.
    private struct PageCount { var at: TimeInterval; var ins: UInt64; var outs: UInt64 }
    private var pageWindow: [PageCount] = []
    private static let pageWindowLength: TimeInterval = 3

    var onTick: (() -> Void)?
    private var hist = History(now: 0)
    var history: [Sample] { hist.samples }
    var historyAdvanced: Bool { hist.advanced }
    private var lastTime: TimeInterval = 0

    // MARK: Sampler

    func prime(at now: TimeInterval) {
        lastTime = now
        hist = History(now: now)
        pageWindow = []
        read(at: now)
    }

    func sample(at now: TimeInterval) {
        let dt = now - lastTime
        guard dt > 0.05 else { return }
        lastTime = now
        read(at: now)
        // The same figure the menu bar's sparkline shows: memory used, as a percentage of
        // physical RAM. It used to record resident and compressed as two stacked series,
        // which was a third way of cutting up the same memory and competed with the
        // breakdown bar in the menu.
        hist.add(Sample(primary: usage.fraction * 100), dt: dt, at: now)
        onTick?()
    }

    private func read(at now: TimeInterval) {
        if let vm = MemorySampler.readVMStatistics() {
            let page = UInt64(vm_kernel_page_size)
            updatePageRates(vm, at: now, pageSize: Double(page))
            // Activity Monitor's arithmetic: "App" is anonymous memory that cannot simply be
            // thrown away, "Cached files" is everything reclaimable (file-backed plus
            // purgeable), and neither `active` nor `inactive` maps onto either on its own.
            let purgeable = UInt64(vm.purgeable_count)
            let external = UInt64(vm.external_page_count)
            let internalPages = UInt64(vm.internal_page_count)
            usage = Usage(
                app: (internalPages > purgeable ? internalPages - purgeable : 0) * page,
                wired: UInt64(vm.wire_count) * page,
                compressed: UInt64(vm.compressor_page_count) * page,
                cached: (external + purgeable) * page,
                active: UInt64(vm.active_count) * page,
                free: (UInt64(vm.free_count) + UInt64(vm.speculative_count)) * page)
        }
        pressure = MemoryInfo.pressure()
        swap = MemoryInfo.swap()
    }

    /// Difference the page counters against the oldest reading still inside the window,
    /// so the rate covers a few seconds rather than one tick.
    private func updatePageRates(_ vm: vm_statistics64_data_t, at now: TimeInterval, pageSize: Double) {
        pageWindow.append(PageCount(at: now, ins: vm.pageins, outs: vm.pageouts))
        // Keep one reading from before the window as the baseline, and drop the rest.
        while pageWindow.count > 2, now - pageWindow[1].at >= MemorySampler.pageWindowLength {
            pageWindow.removeFirst()
        }
        guard let oldest = pageWindow.first, pageWindow.count > 1 else {
            pageInRate = 0
            pageOutRate = 0
            return
        }
        let dt = now - oldest.at
        guard dt > 0 else { return }
        // &- so a counter reset cannot produce an absurd spike.
        pageInRate = Double(vm.pageins &- oldest.ins) * pageSize / dt
        pageOutRate = Double(vm.pageouts &- oldest.outs) * pageSize / dt
    }

    nonisolated static func readVMStatistics() -> vm_statistics64_data_t? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        return result == KERN_SUCCESS ? stats : nil
    }
}

/// The parts of the memory picture that come from sysctl rather than the VM statistics.
enum MemoryInfo {

    static let total: UInt64 = {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname("hw.memsize", &value, &size, nil, 0) == 0 else { return 0 }
        return value
    }()

    /// `kern.memorystatus_vm_pressure_level`: 1 normal, 2 warning, 4 critical. This is the
    /// kernel's own signal — not Activity Monitor's "memory pressure" graph, which is a
    /// derived curve Apple does not document and which this app deliberately does not fake.
    static func pressure() -> MemorySampler.Pressure {
        guard let level = CPUInfo.sysctlInt("kern.memorystatus_vm_pressure_level") else { return .unknown }
        switch level {
        case 1: return .normal
        case 2: return .warning
        case 4: return .critical
        default: return .unknown
        }
    }

    static func swap() -> MemorySampler.Swap {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return MemorySampler.Swap() }
        return MemorySampler.Swap(total: usage.xsu_total, used: usage.xsu_used)
    }
}
