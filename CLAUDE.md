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
  `WidgetController.tick`/`updateBar`) is a change to something that runs twice a second
  for weeks. Measure before and after (below). Measured on an M3 (8 cores, 6 interfaces,
  2 Hz, menus closed, release build, CPU delta over a 620 s window):

  | | CPU | note |
  |---|---|---|
  | network only | 0.79 % | the same before and after the widget refactor |
  | all six widgets | 2.08 % | 0 leaks, RSS 45 MB |
  | all six, when the bars still showed numbers | 2.87 % | what removing the digits was worth |

  So a widget costs roughly **0.26 points**, almost all of it the status-item repaint rather
  than the sampling. That is the accepted price of an opt-in widget (all of them are off by
  default) — but a change that moves the *per-repaint* cost, or that repaints more often than
  once a second, is a regression and must be measured.
- **It is installed and running on this machine** (`/Applications/Nimbus Net Bar.app`, a Login
  Item). `build.sh run` and `install` quit every running copy first —
  that's by design, but say so before running them, and `./build.sh install` afterwards to
  put the real copy back.

## Layout

```
Sources/NimbusNetBar/
  main.swift              flag parsing, AppDelegate, first-launch Login Item registration
  Ticker.swift            the one timer + the `Sampler` protocol every metric implements
  History.swift           `Sample` (one or two series) + the 60 s, one-bucket-per-second ring
  NetworkMonitor.swift    a Sampler: sysctl(NET_RT_IFLIST2) counters → rates
  Widget.swift            the `Widget` protocol, `BarContent`/`BarLine`/`SparkStyle`, `Theme`
  Widgets.swift           which widgets are on, the Widgets submenu, the visibility pause
  WidgetController.swift  one status item: the bar image, the menu lifecycle, shared rows
  NetworkWidget.swift     the network widget's bar lines and menu (interfaces, Wi-Fi, IPs)
  CPUSampler.swift        host_processor_info per-core ticks + CPUInfo (brand, P/E groups)
  CPUWidget.swift         the CPU widget's bar line, sparkline and menu
  GPUSampler.swift        IOAccelerator PerformanceStatistics, paired to Metal by registryID
  GPUWidget.swift         the GPU widget
  MemorySampler.swift     host_statistics64(HOST_VM_INFO64) + swap and pressure sysctls
  MemoryWidget.swift      the memory widget
  DiskSampler.swift       IOBlockStorageDriver byte counters → read/write rates
  DiskIOWidget.swift      the disk activity widget (a rate pair, like the network)
  CapacitySampler.swift   mounted volumes, refreshed off the main thread every 10 s
  CapacityWidget.swift    the disk space widget (a fill bar, not a sparkline)
  ProcessList.swift       one proc_listpids + proc_pid_rusage walk, shared, menu-open only
  Interfaces.swift        the dropdown's data: SCNetworkInterface, getifaddrs, SIOCGIFMEDIA,
                          SCDynamicStore (primary/router/DNS), service order
  WiFiInfo.swift          CoreWLAN details + LocationAccess (the SSID is gated on it)
  PublicIP.swift          ipify lookup, only when the menu opens, cached on success
  ChartView.swift         the 60 s bar chart in the menu, styled per metric (`ChartStyle`)
  CoreGaugesView.swift    the CPU menu's per-core rings + legend, one row per perf level
  SegmentBarView.swift    a horizontal bar of coloured segments (memory pressure/breakdown/swap)
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
NimbusNetBar --print                   the network data as text + a 1 s rate sample (no UI)
NimbusNetBar --print-menu [ID]         a widget's built menu as rows of text
NimbusNetBar --dump-bar P [--widget ID] [--after S]   a status item → PNG
NimbusNetBar --dump-chart P [--single] the menu chart with fake data → PNG
NimbusNetBar --dump-cores P            the per-core rings with fake loads → PNG
NimbusNetBar --dump-segbar P           the memory menu's segmented bars → PNG
```

Run the debug flags from **the bundle** (`"dist/debug/Nimbus Net Bar.app/Contents/MacOS/NimbusNetBar"`),
not `.build/debug/NimbusNetBar`: a bare binary has no bundle id, so it reads none of the
app's defaults — including which widgets are switched on.

`--print-menu` is the substitute for clicking the real menu when the machine running the
agent has no Accessibility permission. It builds the menu twice, 1.4 s apart, and prints the
second: the process lists need two walks before they have a rate to show, exactly as the
real menu does for its first second. It exercises `buildMenu`, not AppKit's menu tracking —
widths, hover and flicker still need the real thing.

`--after S` on `--dump-bar` waits before rendering: a sparkline needs 60 s to fill, so
`--after 70` is what shows one properly.

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
it was 2.7 %. A 500-iteration microbenchmark of a copy of the function is the way to check
a change to any of the per-tick readers. Measured costs, per call:

| | cost | how often |
|---|---|---|
| `NetworkMonitor.readCounters()` | ~40 µs | every tick, network widget on |
| `CPUSampler.readTicks()` | ~9 µs (M3, 8 cores) | every tick, CPU widget on |
| `GPUSampler.read()` | ~30 µs (one GPU) | every tick, GPU widget on |
| `CapacitySampler.readVolumes()` | blocks — never on the main thread | every 10 s, off-main |
| `ProcessList.walk()` | ~1.3 ms (578 procs) | at most 1 Hz, **only while a menu is open** |

Compare like with like: an M3 laptop with 6 interfaces idles lower than the Studio those
baselines came from, so measure a before *and* an after on the machine in front of you
rather than against the number above. The honest way is a **delta over a window** — read
`ps -o time=` twice and divide by the wall seconds between — because that drops the launch
transient. Do not busy-wait (`until …; do :; done`) while a window is open: it burns a core
and lands in the measurement.

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
5. **Tag and publish** (check `gh auth status` first — it is not necessarily the upstream
   owner's account; on at least one machine it is a contributor's):
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
`.signing` file (or the environment). The notary credentials are per Apple ID + team, not per
app, so one profile serves every project — don't name it after this one. When set, release bundles are signed with the
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
  (`hiddenReasons` in `Widgets`). Sampling must continue regardless so the chart
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
- **Gap padding must not treat a slow tick as sleep.** `History` fills seconds no sample
  covered with silence, which is right after a sleep/wake and *wrong* at 0.5 Hz, where every
  sample legitimately spans two seconds — every other bucket came out as zero. A sample now
  fills the seconds its own `dt` covers, up to `History.maxSpread` (4 s); past that it is a
  stall, not a slow rate, and the seconds are silence again. Verified by driving the real
  `History` at 0.2/0.5/1/2 s intervals: no silent buckets at any rate, and a simulated 30 s
  sleep still pads. Compile it standalone to re-check — it only imports Foundation:
  `swiftc Sources/NimbusNetBar/History.swift yourtest.swift` (the test file must be
  `main.swift` for top-level code).
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
- **`MTLDevice.registryID` *is* the `IOAccelerator`'s IOKit registry entry id** (checked:
  Metal says 4294968365 where `ioreg` shows id 0x10000042d), so
  `IORegistryEntryIDMatching` pairs a Metal device with its statistics exactly, instead of
  matching on class names like `AGXAcceleratorG15G`. Use `MTLCopyAllDevices`, not
  `MTLCreateSystemDefaultDevice`, which can force a GPU switch on an older dual-GPU Mac.
- **The GPU's "Alloc system memory" is address space, not memory in use.** It reads ~14 GB
  on an idle 24 GB M3 while "In use system memory" reads 28 MB. Showing the first as "VRAM
  used" would be alarming and wrong; the menu shows in-use and dims the other as "Reserved".
- **`IOBlockStorageDriver` carries no name and no BSD name** — its child `IOMedia` is the
  entry called "APPLE SSD AP0512Z Media" and holding `BSD Name`. `kIOMaxPathLen` does not
  import into Swift; `io_name_t` is 128 bytes.
- **`volumeAvailableCapacityForImportantUsage` is not `df`'s "avail".** It counts space the
  system would reclaim by evicting purgeable files (snapshots, caches): 227 GB here against
  `df`'s 150 Gi. That is deliberate — it is the number Finder shows, and the one a user can
  actually spend.
- **Only one volume is visible on a stock Mac.** `mountedVolumeURLs(.skipHiddenVolumes)`
  presents the system+data pair as the single "Macintosh HD", so the APFS
  container-grouping path in `CapacityWidget` **has not been exercised on this machine** —
  it needs a second visible volume in one container. Check it before trusting it.
- **`proc_pid_rusage`'s `ri_user_time`/`ri_system_time` are mach absolute time units, not
  nanoseconds.** On Apple Silicon one unit is 41.67 ns (timebase 125/3), so treating them as
  nanoseconds under-reports every process by ~42× — the busiest-process list showed a
  pegged `yes` spinner as "2%". Measured: a thread busy for exactly 2.000 s of wall on one
  core reads 99.9 % converted, 2.4 % not. On Intel the timebase is 1:1, so the bug is
  invisible there; convert through `mach_timebase_info` always (`ProcessList.nanos`).
- **Repainting the status item costs far more than `sample` admits.** A CPU widget that
  followed its (constantly changing) number at 2 Hz measured **2.59 %** against the
  network-only app's **0.79 %** — and `sample` could only account for ~1.1 % on the main
  thread, every other thread idle. The rest is system time in the window-server round trip
  that `button.image =` triggers: the process is parked in `mach_msg` for it, so a sampler
  sees nothing while `ps -o time=` charges us for all of it. Repainting once a second
  instead brought it to **1.14 %**. Never diagnose this path with `sample` alone — measure
  the CPU delta over a window.
- **`host_processor_info` hands over memory you must free.** The kernel allocates the
  per-core array in our address space; without the `vm_deallocate` in `readTicks`'s `defer`
  it leaks on every tick, forever.
- **CPU tick counters are 32-bit and wrap** (~497 days at 100 Hz per core). Difference them
  with `&-`, not `-`.
- **Core order on Apple Silicon: `hw.perflevel0` (Performance) is CPUs 0…n first**, then
  perflevel1 (Efficiency) — confirmed on an M3 by loading them: a compile lands on 0–3, a
  low-QoS spinner (`yes`) lands on 4–7. Don't assume the reverse "E-cores first" folklore,
  but do re-confirm it the same way if the grouping ever looks wrong.
- **`proc_pid_rusage` only reads your own processes.** Measured here: 887 pids listed, 579
  readable — exactly the ones this user owns; `launchd` and every root daemon refuse. So the
  busiest-process lists are labelled "(yours)" and must stay that way; making them complete
  would mean asking for privileges this app has no business having.
- **One design language across the menus.** Section headings are `sectionHeader`: small,
  semibold, dim, left-aligned, sentence case. They are deliberately quiet — an earlier
  version was centred, uppercase and accent-blue, copied from another app's menu, and it
  looked bolted on. The separator above a heading already does the dividing.
- **Right-align quantities, left-align identifiers.** `setTableRow` puts the value on a tab
  stop so a column of numbers can be scanned; `setRow` keeps the value beside its label. An
  IP address, SSID or MAC is not compared down a column, so the network menu keeps `setRow`
  and every metric widget uses `setTableRow`. Don't mix the two inside one menu.
- **Show one decomposition of a quantity, not two.** The memory menu used to cut the same
  24 GB three ways at once — a stacked chart of resident/compressed, a pressure block listing
  wired and compressed again, and a breakdown bar of wired/active/compressed/free. Wired and
  compressed each appeared twice with the same number, which reads as a bug. Now: the chart
  plots exactly what the menu bar sparkline plots (memory used), the Pressure section is a
  *state* and carries no breakdown at all, and "Where it is" is the only place memory is
  divided up. App memory and cached files sit there too but dimmed and without a swatch,
  because they overlap the four slices rather than adding to them — the tooltip says so.
  If a fifth figure is ever added, work out first whether it is a slice or a lens.
- **A section heading and its rows should not repeat the same word.** Under a "Swap" heading
  the row is "In use", not "Swap"; under "Pressure" the rows name what the figures actually
  are ("Unreclaimable", "Kernel signal").
- **Nothing in the bar repaints more than once a second.** Every widget backed by a history
  repaints only when `Sampler.historyAdvanced` says a one-second bucket closed, and only if
  what it draws actually moved. That includes the rate pairs: the network's number changes on
  nearly every tick when there is traffic, so following it at 2 Hz — or 5 Hz — bought nothing
  but repaints, which is the one thing this app cannot afford. `CapacitySampler` keeps no
  history and says so (`keepsHistory == false`), so its widget repaints on content change
  instead; without that it would never repaint at all, having no second boundary to reach.
- **Sixty buckets do not fit in a 32 pt sparkline as bars** (well under a device pixel each),
  which is why `WidgetController.drawSpark` draws a filled line instead. Bars stay in the
  menu's chart, where each second has real width and can be hovered.
- **Submenus default to `autoenablesItems = true`** and will re-enable an item you set
  `isEnabled = false` on. `Widgets.buildSubmenu` turns it off so the last-widget item stays
  disabled.
- **Scalar labels are drawn as a column of letters, not a word.** "MEM" across costs ~30 pt
  of menu bar; stacked it costs 6, and with six widgets on that is the difference between
  fitting and not. `Theme.stackedLabelFont` / `WidgetController.scalarImage`.
- **Paging is far too bursty for a per-tick rate.** `pageins` moved by *one page in five
  seconds* on an idle machine here, so a half-second delta reads "0.0 kB/s" essentially
  always. `MemorySampler` differences against the oldest reading in a rolling 3 s window
  instead. Before concluding the page rows are broken, check the raw counter actually moved
  (`vm_stat | grep Pageins` twice) — measured here it genuinely did not.
- **The memory "Pressure" percentage is this app's own stated formula** — wired plus
  compressed over the physical total, i.e. the share of RAM the system cannot reclaim on
  demand — and the tooltip says so in as many words. It is deliberately *not* presented as
  Activity Monitor's pressure figure, whose curve Apple does not document and which this app
  will not guess at; the kernel's own three-state signal sits beside it in the Kernel signal
  row. Don't quietly swap in a different formula; if one is ever needed, change the tooltip
  with it, because the whole point is that the number is explained rather than mysterious.
- **`Format.memory`'s whole-number shortening needs a tight tolerance.** At 0.005 a 4.998 GB
  reading printed as "5 GB" next to a "6.23 GB" beside it, which reads as two different
  precisions. It is 0.0005 now, so only genuinely round values (installed RAM, a 2.00 GB
  swap file) lose their decimals.
- **No widget shows a number in the bar** — a coloured label and a sparkline (or, for Disk
  Space, a pie), nothing else. It was asked for: digits next to a graph are distracting. It
  also makes them cheaper, because with no digits to change the repaint test comes down to
  whether the sparkline moved, so an idle GPU sitting at zero never repaints at all. Every
  value lives on the status item's tooltip and at the top of its menu. Don't "fix" this by
  putting the numbers back.
- **Top-N process rows are never hidden.** Five rows are built once and filled — blanks when
  there is nothing to say. Hiding them resized the menu about once a second as processes
  crossed the threshold, which slid the rows below out from under the pointer mid-click.
  `WidgetController.makeTopRows`/`fillTopRows` are the shared implementation; use them.
- **`--dump-bar` on a widget that is switched off used to say "bar dump failed"**, which
  reads as a rendering bug and sent this session chasing one twice. It now says "no such
  widget showing" and tells you which defaults to check. When a bar or menu dump behaves
  oddly, check `defaults read com.njoubert.nimbusnetbar | grep widget` *first*.
- **`defaults write` while the app is running gets reverted.** A copy that has the domain
  cached will flush its own stale snapshot over your write the next time it writes anything
  itself (it writes `locationRequested` at launch), and two of the `widget.*.enabled` keys
  silently went back to 0 that way mid-session. Quit every copy first, write, then launch.
  This is a testing trap, not an app bug — `setEnabled` is the only writer of those keys and
  it only runs from the Widgets submenu.
- **A bar sparkline pinned to a fixed 0–100 is a flat line.** An idle machine at 14 % is
  1.5 pt of an 11 pt strip. The number carries the absolute value; the sparkline auto-scales
  to its own window so it carries the shape. The menu's chart keeps the fixed 0–100 scale.
- **The app must never end up with every widget off.** No Dock icon, no window: there would
  be no menu to switch one back on and no way to quit but Activity Monitor. `Widgets.start`
  falls back to the first widget, and the last enabled item in the Widgets submenu is
  disabled.
- **Interfaces that count toward the bar total** are `en*`, `ppp*`, `pdp_ip*` only; tunnels
  are excluded on purpose (their bytes are re-sent over a physical port — double counting).
