// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The address the internet sees. Fetched only when the menu opens (never polled in the
/// background) and cached for a minute so repeated opens don't hit the service.
@MainActor
final class PublicIP {
    static let shared = PublicIP()

    enum State { case idle, fetching, value(String), failed }
    private(set) var ipv4: State = .idle
    private(set) var ipv6: State = .idle
    private var fetchedAt: Date?
    var onChange: (() -> Void)?

    private static let v4URL = URL(string: "https://api.ipify.org")!
    private static let v6URL = URL(string: "https://api6.ipify.org")!

    func refreshIfStale() {
        if let t = fetchedAt, Date().timeIntervalSince(t) < 60 { return }
        if case .fetching = ipv4 { return }
        ipv4 = .fetching
        ipv6 = .fetching
        onChange?()
        Task {
            async let a = PublicIP.fetch(PublicIP.v4URL)
            async let b = PublicIP.fetch(PublicIP.v6URL)
            let (r4, r6) = await (a, b)
            ipv4 = r4.map { .value($0) } ?? .failed
            ipv6 = r6.map { .value($0) } ?? .failed
            // Only a result is worth caching: after a transient failure (offline, captive
            // portal) the next menu open should try again, not show "unavailable" for a
            // minute. v6 alone failing is normal on a v4-only network, so either counts.
            fetchedAt = (r4 != nil || r6 != nil) ? Date() : nil
            onChange?()
        }
    }

    private static func fetch(_ url: URL) async -> String? {
        var req = URLRequest(url: url)
        req.timeoutInterval = 4
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !s.isEmpty, s.count < 64 else { return nil }
        return s
    }
}
