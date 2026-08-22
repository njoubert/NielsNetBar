// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation

/// One process, as one walk sees it. The counters are all totals since the process
/// started, so a rate needs two walks.
struct ProcessCounters {
    var name: String
    /// User + system CPU time, nanoseconds (converted — see `ProcessList.nanos`).
    var cpuTime: UInt64
    /// Physical footprint — what Activity Monitor's "Memory" column shows.
    var footprint: UInt64
    var diskRead: UInt64
    var diskWritten: UInt64
}

struct ProcessSnapshot {
    var at: TimeInterval
    var byPID: [pid_t: ProcessCounters]
}

/// One walk over every process — `proc_listpids`, then a `proc_pid_rusage` each — shared by
/// the CPU, Memory and Disk I/O menus.
///
/// This is by far the most expensive thing the app does, so it never runs on the ordinary
/// tick: only while a menu is open, at most once a second, and all three widgets read the
/// same pair of snapshots. Processes belonging to other users (root daemons, other
/// accounts) refuse `proc_pid_rusage` without privileges and are simply left out — the
/// lists say "yours" for that reason.
@MainActor
enum ProcessList {

    private(set) static var latest: ProcessSnapshot?
    private(set) static var previous: ProcessSnapshot?

    /// Walk again if the newest snapshot is at least a second old. Called when a menu opens
    /// and on each tick while it stays open.
    static func refresh(at now: TimeInterval) {
        if let latest, now - latest.at < 1 { return }
        let snap = ProcessSnapshot(at: now, byPID: walk())
        guard !snap.byPID.isEmpty else { return }
        // A snapshot left over from a menu opened minutes ago is not a baseline: differencing
        // against it reports an average over the whole gap, which makes something that was
        // busy long ago look busy now. Drop it and start again — the lists show "measuring…"
        // for a second instead of showing something untrue.
        previous = latest.flatMap { now - $0.at <= ProcessList.maxBaselineAge ? $0 : nil }
        latest = snap
    }

    /// How old a snapshot may be and still serve as the other end of a rate.
    private static let maxBaselineAge: TimeInterval = 5

    /// Fraction of one core each process used between the last two walks, biggest first.
    /// Empty until there are two walks to difference.
    static func topByCPU(_ n: Int) -> [(name: String, value: Double)] {
        guard let latest, let previous, latest.at > previous.at else { return [] }
        let dt = latest.at - previous.at
        var out: [(String, Double)] = []
        for (pid, now) in latest.byPID {
            guard let before = previous.byPID[pid], now.cpuTime >= before.cpuTime else { continue }
            let share = Double(now.cpuTime - before.cpuTime) / 1e9 / dt
            if share > 0.001 { out.append((now.name, share)) }
        }
        return Array(out.sorted { $0.1 > $1.1 }.prefix(n))
    }

    /// Biggest physical footprints, biggest first.
    static func topByMemory(_ n: Int) -> [(name: String, value: UInt64)] {
        guard let latest else { return [] }
        return Array(latest.byPID.values
            .map { ($0.name, $0.footprint) }
            .sorted { $0.1 > $1.1 }
            .prefix(n))
    }

    /// Bytes per second read + written between the last two walks, biggest first.
    static func topByDisk(_ n: Int) -> [(name: String, value: Double)] {
        guard let latest, let previous, latest.at > previous.at else { return [] }
        let dt = latest.at - previous.at
        var out: [(String, Double)] = []
        for (pid, now) in latest.byPID {
            guard let before = previous.byPID[pid] else { continue }
            let read = now.diskRead >= before.diskRead ? now.diskRead - before.diskRead : 0
            let wrote = now.diskWritten >= before.diskWritten ? now.diskWritten - before.diskWritten : 0
            let rate = Double(read + wrote) / dt
            if rate > 1_000 { out.append((now.name, rate)) }
        }
        return Array(out.sorted { $0.1 > $1.1 }.prefix(n))
    }

    // MARK: The walk

    /// `ri_user_time` and `ri_system_time` are **mach absolute time units, not nanoseconds**.
    /// On Apple Silicon one unit is 41.67 ns (timebase 125/3), so reading them as nanoseconds
    /// under-reports every process by ~42×. Measured here: a thread busy for exactly 2.000 s
    /// of wall on one core reads 99.9 % converted and 2.4 % unconverted. On Intel the timebase
    /// is 1:1, which is how a bug like this survives — always convert.
    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return (UInt64(max(tb.numer, 1)), UInt64(max(tb.denom, 1)))
    }()

    static func nanos(_ machTime: UInt64) -> UInt64 {
        machTime / timebase.denom * timebase.numer + machTime % timebase.denom * timebase.numer / timebase.denom
    }

    private static func walk() -> [pid_t: ProcessCounters] {
        let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bytes > 0 else { return [:] }
        // Slack, for processes that appear between the size probe and the read.
        var pids = [pid_t](repeating: 0, count: Int(bytes) / MemoryLayout<pid_t>.size + 64)
        let got = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard got > 0 else { return [:] }
        let count = Int(got) / MemoryLayout<pid_t>.size

        var out: [pid_t: ProcessCounters] = [:]
        out.reserveCapacity(count)
        var nameBuf = [CChar](repeating: 0, count: 256)
        for i in 0..<count {
            let pid = pids[i]
            guard pid > 0 else { continue }
            var info = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &info) { p in
                p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            }
            guard ok == 0 else { continue }   // another user's process, or it just exited
            let n = proc_name(pid, &nameBuf, UInt32(nameBuf.count))
            let name = n > 0 ? String(cString: nameBuf) : "pid \(pid)"
            out[pid] = ProcessCounters(
                name: name,
                cpuTime: ProcessList.nanos(info.ri_user_time + info.ri_system_time),
                footprint: info.ri_phys_footprint,
                diskRead: info.ri_diskio_bytesread,
                diskWritten: info.ri_diskio_byteswritten)
        }
        return out
    }
}
