// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation

/// The kernel's per-core tick counters, as one reading.
///
/// They are 32-bit and count at the scheduler's tick rate, so they wrap (roughly every
/// 497 days at 100 Hz). Deltas are taken with `&-` for that reason.
struct CPUTicks {
    var user: UInt32 = 0
    var system: UInt32 = 0
    var idle: UInt32 = 0
    var nice: UInt32 = 0
}

/// CPU load from `host_processor_info(PROCESSOR_CPU_LOAD_INFO)`: one set of tick counters
/// per logical core, differenced between ticks. No subprocess, no `powermetrics`, no
/// privileges — and no temperature or frequency either, which need both.
@MainActor
final class CPUSampler: Sampler {

    /// Fractions of one core's time, 0…1.
    struct Load: Equatable {
        var user: Double = 0     // user + nice
        var system: Double = 0
        var busy: Double { user + system }
    }

    /// Per logical core, in the kernel's order (see `CPUInfo.coreGroups` for which are
    /// performance cores and which are efficiency cores).
    private(set) var cores: [Load] = []
    /// The whole machine: the average over every core.
    private(set) var total = Load()

    var onTick: (() -> Void)?
    private var hist = History(now: 0)
    var history: [Sample] { hist.samples }
    var historyAdvanced: Bool { hist.advanced }

    private var last: [CPUTicks] = []
    private var lastTime: TimeInterval = 0

    // MARK: Sampler

    func prime(at now: TimeInterval) {
        last = CPUSampler.readTicks()
        lastTime = now
        hist = History(now: now)
    }

    func sample(at now: TimeInterval) {
        let dt = now - lastTime
        guard dt > 0.05 else { return }
        let current = CPUSampler.readTicks()
        // A core count that changed under us (or a failed read) leaves the baseline in a
        // state nothing can be differenced against; re-seed and skip this tick.
        guard !current.isEmpty else { return }
        guard current.count == last.count else {
            last = current
            lastTime = now
            return
        }

        var loads: [Load] = []
        loads.reserveCapacity(current.count)
        var sum = Load()
        for (i, c) in current.enumerated() {
            let p = last[i]
            let user = Double(c.user &- p.user) + Double(c.nice &- p.nice)
            let system = Double(c.system &- p.system)
            let idle = Double(c.idle &- p.idle)
            let ticks = user + system + idle
            // A core that reported no ticks at all (idle-halted for the whole interval)
            // counts as idle rather than as a divide by zero.
            let l = ticks > 0 ? Load(user: user / ticks, system: system / ticks) : Load()
            loads.append(l)
            sum.user += l.user
            sum.system += l.system
        }
        let n = Double(loads.count)
        cores = loads
        total = Load(user: sum.user / n, system: sum.system / n)
        last = current
        lastTime = now
        // The chart stacks user under system, both as a percentage of the whole machine.
        hist.add(Sample(primary: total.user * 100, secondary: total.system * 100), dt: dt, at: now)
        onTick?()
    }

    /// One `host_processor_info` call → the tick counters for every logical core.
    ///
    /// The kernel allocates the array in our address space and hands over ownership, so it
    /// has to be `vm_deallocate`d — leaking it here would leak on every tick, forever.
    nonisolated static func readTicks() -> [CPUTicks] {
        var count = mach_msg_type_number_t(0)
        var numCPUs = natural_t(0)
        var info: processor_info_array_t?
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &numCPUs, &info, &count) == KERN_SUCCESS,
              let info else { return [] }
        defer {
            vm_deallocate(mach_task_self_,
                          vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(Int(count) * MemoryLayout<integer_t>.size))
        }
        let states = Int(CPU_STATE_MAX)
        var out: [CPUTicks] = []
        out.reserveCapacity(Int(numCPUs))
        for i in 0..<Int(numCPUs) {
            let base = i * states
            guard base + states <= Int(count) else { break }
            out.append(CPUTicks(
                user: UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
                system: UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                idle: UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
                nice: UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])))
        }
        return out
    }
}

/// What the machine is, read once: it does not change while the app runs.
enum CPUInfo {

    /// A group of logical cores that share a performance level, in the order
    /// `host_processor_info` reports them.
    struct Group {
        var name: String        // "Performance", "Efficiency", or "CPU" on one level
        var range: Range<Int>
    }

    static let brand: String = sysctlString("machdep.cpu.brand_string") ?? "CPU"
    static let logicalCores: Int = sysctlInt("hw.logicalcpu") ?? 1
    static let physicalCores: Int = sysctlInt("hw.physicalcpu") ?? 1

    /// Apple Silicon reports its core types as "performance levels": level 0 is the fastest.
    /// The kernel numbers the logical CPUs in the same order, so the groups are contiguous
    /// ranges over `CPUSampler.cores`.
    static let coreGroups: [Group] = {
        let levels = sysctlInt("hw.nperflevels") ?? 1
        guard levels > 1 else { return [Group(name: "CPU", range: 0..<logicalCores)] }
        var groups: [Group] = []
        var start = 0
        for level in 0..<levels {
            guard let n = sysctlInt("hw.perflevel\(level).logicalcpu"), n > 0 else { continue }
            let name = sysctlString("hw.perflevel\(level).name") ?? (level == 0 ? "Performance" : "Efficiency")
            groups.append(Group(name: name, range: start..<(start + n)))
            start += n
        }
        return groups.isEmpty ? [Group(name: "CPU", range: 0..<logicalCores)] : groups
    }()

    static func sysctlInt(_ name: String) -> Int? {
        var value: Int = 0
        var size = MemoryLayout<Int>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    /// The 1 / 5 / 15 minute load averages.
    static func loadAverage() -> [Double] {
        var la = [Double](repeating: 0, count: 3)
        guard getloadavg(&la, 3) == 3 else { return [] }
        return la
    }
}
