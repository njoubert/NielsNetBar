// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation

/// How full the mounted volumes are.
///
/// Unlike every other sampler this one does **not** read anything on the tick: `statfs` on a
/// stale network mount blocks for seconds, and doing that on the main thread would freeze
/// the menu bar. It refreshes on a background task every `interval` seconds instead — free
/// space does not move fast enough to want anything better.
@MainActor
final class CapacitySampler: Sampler {

    struct Volume: Equatable {
        var name: String
        var mountPoint: String
        var total: UInt64
        var available: UInt64
        var fileSystem: String
        var isRemovable: Bool
        var isInternal: Bool
        var isLocal: Bool
        /// The APFS container ("disk3") this volume lives in. Volumes in one container share
        /// the same free space, so listing each one's "free" separately would say the same
        /// number several times and read like a bug.
        var container: String?

        var used: UInt64 { total > available ? total - available : 0 }
        var fraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
    }

    private(set) var volumes: [Volume] = []
    /// The volume the system booted from — the one the bar shows.
    var boot: Volume? { volumes.first { $0.mountPoint == "/" } ?? volumes.first }

    var onTick: (() -> Void)?
    /// Capacity has no history worth charting: it is a level that barely moves, and the bar
    /// shows it as a fill bar rather than a sparkline.
    var history: [Sample] { [] }
    var historyAdvanced: Bool { false }
    /// So its widget repaints when the number changes rather than on a second boundary it
    /// never reaches — see `WidgetController.updateBar`.
    var keepsHistory: Bool { false }

    private static let interval: TimeInterval = 10
    private var lastRefresh: TimeInterval = -.infinity
    private var refreshing = false

    // MARK: Sampler

    func prime(at now: TimeInterval) {
        refresh(at: now)
    }

    func sample(at now: TimeInterval) {
        refresh(at: now)
    }

    private func refresh(at now: TimeInterval) {
        guard !refreshing, now - lastRefresh >= CapacitySampler.interval else { return }
        refreshing = true
        lastRefresh = now
        Task {
            let found = await CapacitySampler.readVolumes()
            refreshing = false
            guard found != volumes else { return }
            volumes = found
            onTick?()
        }
    }

    /// Off the main actor: everything in here can block.
    nonisolated static func readVolumes() async -> [Volume] {
        let keys: [URLResourceKey] = [
            .volumeLocalizedNameKey, .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey, .volumeIsRemovableKey,
            .volumeIsInternalKey, .volumeIsLocalKey, .volumeTypeNameKey,
        ]
        guard let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                               options: [.skipHiddenVolumes]) else { return [] }
        var out: [Volume] = []
        for url in urls {
            guard let v = try? url.resourceValues(forKeys: Set(keys)),
                  let total = v.volumeTotalCapacity, total > 0 else { continue }
            // "Important usage" is the number Finder shows: it counts space the system would
            // free up by evicting purgeable files, which is what the user can actually use.
            let available = v.volumeAvailableCapacityForImportantUsage ?? 0
            out.append(Volume(
                name: v.volumeLocalizedName ?? url.lastPathComponent,
                mountPoint: url.path,
                total: UInt64(total),
                available: UInt64(max(available, 0)),
                fileSystem: v.volumeTypeName ?? "",
                isRemovable: v.volumeIsRemovable ?? false,
                isInternal: v.volumeIsInternal ?? false,
                isLocal: v.volumeIsLocal ?? true,
                container: containerOf(url.path)))
        }
        // Boot volume first, then the rest by name, so the list does not reshuffle itself.
        return out.sorted {
            if ($0.mountPoint == "/") != ($1.mountPoint == "/") { return $0.mountPoint == "/" }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// `statfs` gives the device a volume is mounted from — "/dev/disk3s1s1" — and the
    /// container is the whole-disk part of it, "disk3".
    private nonisolated static func containerOf(_ path: String) -> String? {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return nil }
        let from = withUnsafeBytes(of: &fs.f_mntfromname) { raw -> String in
            guard let base = raw.baseAddress else { return "" }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
        guard from.hasPrefix("/dev/disk") else { return nil }
        let rest = from.dropFirst("/dev/".count)          // "disk3s1s1"
        let digits = rest.dropFirst("disk".count).prefix { $0.isNumber }
        return digits.isEmpty ? nil : "disk\(digits)"
    }
}
