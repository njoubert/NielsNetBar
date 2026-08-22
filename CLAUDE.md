# Nimbus Net Bar — notes for agents

A macOS menu bar network monitor in Swift: live ↑/↓ throughput in the bar, every
interface's details in the dropdown. Pure SwiftPM, no dependencies, no Xcode project.
`README.md` is the user-facing description of what it shows and how it works — read it
first and keep it true when behaviour changes. This file is the rest: how to work here,
how to measure, and the traps already found.

## Ground rules

- **Be concise.** Short reports, no repetition, the salient facts only.
- **`prek` (pre-commit) must pass.** Hooks are installed; `prek run --all-files` before
  claiming done. Shellcheck runs at its default severity here, so `A && B || true` is
  flagged — write an `if`. Never disable a hook to get past it.
- **Licence headers.** Every new Swift file starts with
  `// Copyright (C) 2026 Niels Joubert` / `// SPDX-License-Identifier: GPL-3.0-or-later`.
  The project is GPL-3.0-or-later; don't vendor code under an incompatible licence.
- **This is a long-running app.** Every change on the per-tick path (`NetworkMonitor.sample`,
  `StatusBarController.tick`/`updateBar`) is a change to something that runs twice a second
  for weeks. Measure before and after (below); the budget is well under 1 % CPU idle.
- **It is installed and running on this machine** (`/Applications/Nimbus Net Bar.app`, a Login
  Item). `build.sh run` and `install` quit every running copy first —
  that's by design, but say so before running them, and `./build.sh install` afterwards to
  put the real copy back.

## Layout

```
Sources/NimbusNetBar/
  main.swift              flag parsing, AppDelegate, first-launch Login Item registration
  NetworkMonitor.swift    timer + sysctl(NET_RT_IFLIST2) counters → rates, 60 s history
  StatusBarController.swift  the status item image, the menu, live rows, visibility pause
  Interfaces.swift        the dropdown's data: SCNetworkInterface, getifaddrs, SIOCGIFMEDIA,
                          SCDynamicStore (primary/router/DNS), service order
  WiFiInfo.swift          CoreWLAN details + LocationAccess (the SSID is gated on it)
  PublicIP.swift          ipify lookup, only when the menu opens, cached on success
  ChartView.swift         the 60 s bar chart in the menu
  Format.swift            number formatting (bits, SI, fixed-width for the bar)
  LoginItem.swift         SMAppService wrapper + the "registered once" default
  AppIcon.swift           the icon, drawn in code → .iconset/.icns at bundle time
  DMGBackground.swift     the disk image's background, drawn in code
build.sh                  build / run / stop / app / dmg / install / uninstall / status /
                          icon / clean — `./build.sh` with no args prints help
docs/                     icon.png (re-rendered by `build.sh icon`) and screenshot.png (taken
                          by hand: open the menu, ⇧⌘4, space, click the menu) for the README
dist/                     build products (gitignored): Nimbus Net Bar.app, debug/, *.dmg
```

Swift 5 language mode (`swift-tools-version:5.10`) with the Swift 6 compiler; UI classes
are `@MainActor`, the timer and notification callbacks hop in with `MainActor.assumeIsolated`
because they already run on the main thread. Keep it that way rather than sprinkling `Task`.

## Build, run, test

```
./build.sh run [--hz 5] [--fg]   debug build as dist/debug/Nimbus Net Bar.app (--fg: logs here)
./build.sh stop
./build.sh install               release → /Applications, launch, register Login Item
./build.sh dmg                   release → dist/NimbusNetBar-<version>.dmg
.build/debug/NimbusNetBar --print         the menu's data as text + a 1 s rate sample (no UI)
.build/debug/NimbusNetBar --dump-bar P    the status-item image → PNG
.build/debug/NimbusNetBar --dump-chart P  the chart with fake data → PNG
```

There are no unit tests; `--print` is the quickest correctness check for the data path
(compare with `ifconfig` / `netstat -ib`). Dev builds are ad-hoc signed, so macOS sees
each rebuild as a new app: Location permission granted to a dev build does
not survive the next `run`. The installed copy keeps them.

## Inspecting the menu (there is no screenshot helper any more)

Drive the real app through the accessibility API — it reads the live menu, so it verifies
what the user actually sees, and it can click rows:

```
osascript -e 'tell application "System Events" to tell process "NimbusNetBar"
  click menu bar item 1 of menu bar 1        -- accessory app: there is only menu bar 1
  delay 1.5
  set m to menu 1 of menu bar item 1 of menu bar 1
  set sz to size of m                        -- {width, height}; read item 1 of sz, do not
  ...                                        -- coerce it inline or AppleScript errors
  get name of menu item i of m               -- multi-line rows come back with the \n
  key code 53                                -- escape, to close
end tell'
```

Needs Accessibility permission for whatever runs it (the terminal / the IDE). System Settings
panes can be walked the same way (`entire contents of window 1`, then match `AXCheckBox` /
`AXSwitch` by name) to read or flip a privacy switch. Careful: the Location dialog's button is
`Don’t Allow` with a **curly** apostrophe — matching `"Don't Allow"` silently fails.

**Testing first-launch behaviour with throwaway bundle ids**: copy the built .app, change
`CFBundleIdentifier`, re-sign ad-hoc, and macOS treats it as a brand-new app (Location state
"not determined" again). Keep the copy **outside `/Applications`** — from inside it, the app
registers itself as a Login Item, and deleting the bundle then leaves a ghost entry that can
only be cleared by recreating the bundle and running `--disable-login-item`. Pre-seed state
with `defaults write <probe id> <key>` to reach a specific case without any dialogs. A
CoreLocation dialog **survives the requesting app being killed**, so dismiss it explicitly.

## Measuring load and leaks (do this for any per-tick change)

```
PID=$(pgrep -x NimbusNetBar)
ps -o etime=,time=,rss= -p $PID          # time/etime = average CPU since launch; RSS
sample $PID 10 1 -mayDie -file s.txt     # where the time goes (read the call graph)
leaks $PID | grep "leaks for"            # expect 0
heap $PID | head                         # node count; take two, minutes apart, for growth
```

Baselines on a Mac Studio (M-series, 32 interfaces, 2 Hz, menu closed, release build):
**0.83 % CPU, 0 leaks, heap flat over 1000 ticks** — after the fixes below. Before them
it was 2.7 %. `readCounters()` costs ~40 µs per call; a 500-iteration microbenchmark of a
copy of the function is the way to check a change there.

## Release and distribution

The deliverable is the disk image. Nothing is automated beyond `build.sh dmg`; a release is:

1. **Version.** `VERSION=` near the top of `build.sh` is the marketing version
   (`CFBundleShortVersionString`, the DMG's file name). `CFBundleVersion` is
   `git rev-list --count HEAD`, so it increments by itself — commit before building. It
   cannot be a git hash: macOS requires one to three period-separated integers and *orders*
   versions by it. The menu's version row shows `v<short> (<build>)`.
2. **Docs.** If the icon changed, `./build.sh icon`; if the menu changed, retake
   `docs/screenshot.png` by hand. Keep README's "What it shows" honest.
3. **Build and check.** `./build.sh dmg` → `dist/NimbusNetBar-<VERSION>.dmg`. Then
   `open` it and look: 640-wide window, no blank strip, icon shadow not boxed, footer line
   visible, nothing selected. Drag-install it somewhere (or `ditto` the app out of it) and
   confirm first launch from `/Applications` registers the Login Item and prompts for
   Location. Measure (`ps`/`leaks` above) on the release build, not the debug one.
4. **Installing what you just built:** mount the notarized DMG and `ditto` the app out of it
   to `/Applications` rather than `./build.sh install` — install re-signs the bundle, which
   invalidates the staple and costs another full notarization round, and the DMG copy is the
   exact artifact users get. Quit the running copy first; the Login Item registration points
   at the path, so replacing the bundle in place keeps it.
5. **Tag and publish** (`gh` is logged in as njoubert):
   ```
   git tag -a v<VERSION> -m "Nimbus Net Bar <VERSION>"
   git push origin main --tags
   gh release create v<VERSION> dist/NimbusNetBar-<VERSION>.dmg --title "Nimbus Net Bar <VERSION>" --notes-file <notes>
   ```
   Release notes: what changed for a user, in a few lines, plus the standing caveat that
   the build is unsigned (and how to allow it). Don't commit `dist/`.

What a recipient gets: the DMG holds the app, an Applications alias, a background with the
instructions and the Login Item / Location notes, and a hidden `.LICENSE`; the bundle
itself also carries `Contents/Resources/LICENSE`. The app phones home only to
`api.ipify.org`/`api6.ipify.org`, only when the menu is open — keep it that way and keep
README saying so; it's what reviewers of a menu bar tool look for.

**Signing.** `build.sh` reads `SIGN_IDENTITY` / `NOTARY_PROFILE` from a git-ignored
`.signing` file (or the environment). When set, release bundles are signed with the
Developer ID (`--options runtime --timestamp`), the app is notarized (zipped, submitted,
stapled) and then the DMG is signed, notarized and stapled too, so both the image and a
copy dragged out of it verify offline; the DMG background drops its "unsigned" footer
(`--render-dmg-background --signed`). Unset, everything is ad-hoc as before — keep that
path working, it's what any machine without the certificate uses. `./build.sh status`
shows who signed the installed copy and Gatekeeper's verdict. Notarization waits on Apple
(minutes, occasionally longer); failures: `xcrun notarytool log <id> --keychain-profile …`.
The private key lives only in this Mac's login keychain — it is backed up as a `.p12`,
not re-downloadable. The membership is annual; if it lapses, already-notarized releases
keep working forever, new builds fall back to ad-hoc.

A Homebrew cask is possible once releases are stable (fixed download URL + the DMG's
`shasum -a 256`). GPL-3.0 makes the Mac App Store a non-option, deliberately.

## Traps already found (don't re-learn these)

- **`if_indextoname` is a full `getifaddrs()` walk on Darwin.** Calling it per interface per
  tick was 80 % of the app's CPU. The interface name is in the `sockaddr_dl` (RTA_IFP)
  that follows each `if_msghdr2` in the sysctl buffer; read it from there. The on-wire
  `sockaddr_dl` can be shorter than the struct — read `sdl_family`/`sdl_nlen` bytes, don't
  load the whole struct.
- **Repainting the status item is the other cost.** `NSStatusItem.button.image = …` means
  text layout + rasterise + `_adjustLength` + a CA commit. Skip it when the text is unchanged,
  and don't paint at all while the screen is locked / displays asleep / session inactive
  (`hiddenReasons` in StatusBarController). Sampling must continue regardless so the chart
  and "since launch" totals stay honest.
- **Clocks.** Rates and history buckets use `CLOCK_MONOTONIC`, which on macOS keeps counting
  through sleep; `Date()` can step backwards under NTP and stalled sampling. Don't switch to
  `CLOCK_UPTIME_RAW`/`systemUptime` — they stop during sleep and misattribute bytes.
- **sysctl size race.** The `NET_RT_IFLIST2` size probe and read are two calls; an interface
  appearing in between fails the read. The buffer has slack, and `sample()` must never wipe
  its baseline on an empty read.
- **`SIOCGIFMEDIA` is spelled out as `0xc02c6938`** because the C macro doesn't import; the
  struct is 44 bytes (`#pragma pack(4)`), status at offset 24, active at 28.
- **`plutil -lint` misparses JSON/plists here — validate with `plutil -convert xml1 -o /dev/null`.**
- **Don't rebuild the menu while it is open.** `removeAllItems()` under tracking flickers and
  loses hover; update rows in place (`setRow`, `configureSSIDRow`, `updatePublicIPRows`).
  The menu closing sends no `mouseExited` — clear the chart hover in `menuDidClose`.
- **Public IP is cached only on success** (either family), so a transient failure retries
  on the next open instead of showing "unavailable" for a minute.
- **Login Item registration happens once.** `--enable-login-item` (from `build.sh install`)
  or the first launch from `/Applications` (a drag install) registers, then sets the
  `loginItemRegistered` default; the menu toggle sets it too. Never auto-register when the
  default is set — a user's "off" must stick across updates. `SMAppService` registers the
  bundle that calls it, so `uninstall` must unregister *before* deleting the app.
- **Icon shadow must fade out inside the canvas.** A shadow still visible at the edge is
  clipped to a hard line and shows as a grey box on light backgrounds (the DMG window).
  Check edge alpha is 0 after touching `AppIcon.draw`.
- **DMG layout.** Geometry is shared by `DMGBackground.swift` (640×440, icon centres
  170/210 and 470/210) and the AppleScript in `build.sh`; change both. Finder's window
  `bounds` include the 28 pt title bar, and Finder adds the *hidden* sidebar's remembered
  width back on reopen unless `sidebar width` is set to 0 and bounds re-applied after the
  close/open cycle. `set selection to {}` is invalid inside `tell disk`. The first run
  prompts for permission to control Finder.
- **Unsigned build.** Ad-hoc signed, not notarized: a quarantined DMG (browser, AirDrop) is
  refused until allowed in System Settings › Privacy & Security ("Open Anyway"); on macOS 15
  right-click › Open no longer works. Notarizing needs an Apple Developer ID.
- **The macOS Location prompt is one-shot.** `requestWhenInUseAuthorization()` raises the
  dialog only on the *first* call an app (bundle id) ever makes; every later call is a silent
  no-op. So any "click to allow" affordance must check whether the prompt is still available
  (the `locationRequested` default) and otherwise open Privacy settings — otherwise the click
  does nothing at all. Adding a well-meaning extra auto-request *consumes* that one prompt and
  breaks the manual path; that is exactly how the SSID row got broken once already.
- **Only `/Applications` copies auto-ask for Location** (`isInstalledCopy`), so a dev build
  deliberately never prompts on launch — if you are testing "why didn't it ask me", check
  which copy is running before assuming the code is wrong.
- **Running the binary from a shell is not a valid TCC test.** `…/Contents/MacOS/NimbusNetBar
  --print` shows the SSID as hidden even when the installed .app is authorized, because TCC
  attributes the request to the *responsible* process (your terminal), not the bundle. Test
  permissions through the real .app, launched with `open`.
- **The menu could only ever get wider.** `ChartView` has `autoresizingMask = [.width]`, so
  AppKit stretches it to the menu width; the same instance is reused on every open, so that
  stretched frame became the menu's new minimum (measured: 633 pt → 649 pt on the next open).
  `rebuild()` resets it to `chartWidth` first. Any long row therefore widens the menu
  permanently — keep notices to two short lines rather than one long one.
- **Interfaces that count toward the bar total** are `en*`, `ppp*`, `pdp_ip*` only; tunnels
  are excluded on purpose (their bytes are re-sent over a physical port — double counting).
