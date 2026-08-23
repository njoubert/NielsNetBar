// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import NimbusUpdater

/// This app's side of `NimbusUpdater`: the facts that identify it, in one place, so the menu
/// and `--check-update` ask about the same thing. Identical in shape to nimbus-leviton-bar's.
enum Updates {
    static let repo = "njoubert/nimbus-net-bar"
    static let bundleID = "com.njoubert.nimbusnetbar"
    /// The Developer ID team the release is signed with; a download signed by anyone else is
    /// refused. Shared with nimbus-leviton-bar (one Apple ID, one team).
    static let teamID = "93A96TD57U"
    static let appName = "Nimbus Net Bar"
    static let executableName = "NimbusNetBar"

    static func config(currentVersion: SemanticVersion) -> UpdaterConfig {
        UpdaterConfig(repo: repo, bundleID: bundleID, teamID: teamID, appName: appName,
                      executableName: executableName, currentVersion: currentVersion,
                      // Say so when the daily check finds one, rather than waiting for someone
                      // to open the menu — this app can sit untouched for weeks. Once per
                      // version, and never on the check that runs as the menu opens.
                      announcesReadyUpdates: true)
    }

    /// The running bundle's version — nil for the bare binary (no Info.plist).
    static var runningVersion: SemanticVersion? { SemanticVersion.ofBundle() }

    /// What `/Applications/<appName>.app` says it is, for a CLI run outside a bundle.
    static var installedVersion: SemanticVersion? {
        let plist = URL(fileURLWithPath: "/Applications/\(appName).app/Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let short = info["CFBundleShortVersionString"] as? String else { return nil }
        return SemanticVersion(short)
    }
}
