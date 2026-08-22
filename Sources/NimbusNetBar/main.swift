// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

// Nimbus Net Bar — a menu bar network throughput monitor. See README.md.
//
// Flags (all optional; build.sh uses most of them):
//   --hz N                  sample rate for this run (default: saved setting, else 2)
//   --enable-login-item     register this bundle as a Login Item, then keep running
//   --disable-login-item    unregister the Login Item and exit
//   --login-item-status     print the Login Item state and exit
//   --render-icon PATH [--size PX]   write the app icon as a PNG and exit
//   --render-iconset DIR    write an .iconset (for iconutil) and exit
//   --render-dmg-background DIR [--signed]   write the disk image's background PNGs (1× and 2×)
//                           and exit; --signed omits the "unsigned build" footer
//   --dump-bar PATH [--widget ID] [--after S]   render a status item to PATH, quit (layout
//                           check); ID is a widget id (network, cpu), default the first one
//                           showing; --after waits S seconds first (60+ fills a sparkline)
//   --dump-chart PATH [--single]   render the history chart with fake data to PATH, quit;
//                           --single draws it as a one-series chart (the scalar widgets)
//   --dump-cores PATH       render the CPU menu's per-core rings with fake loads → PNG
//   --dump-segbar PATH      render the memory menu's segmented bars with fake values → PNG
//   --print                 print the network data as text (no UI) and quit
//   --print-menu [ID]       print a widget's built menu as text and quit (needs the UI,
//                           so it launches, waits --after seconds, prints and exits)

struct Options {
    var hz: Double?
    var enableLoginItem = false
    var dumpBarPath: String?
    var dumpBarWidget: String?
    var dumpBarAfter: TimeInterval = 2.5
    var printMenuWidget: String?
    var printMenu = false
}

func usage() -> Never {
    print("""
    usage: NimbusNetBar [--hz N] [--enable-login-item | --disable-login-item | --login-item-status]
                    [--render-icon PATH [--size PX]] [--render-iconset DIR]
    """)
    exit(2)
}

var options = Options()
var renderIconPath: String?
var renderIconSize = 1024
var renderIconsetDir: String?
var renderDMGBackgroundDir: String?
var dmgSigned = false

var args = Array(CommandLine.arguments.dropFirst())
func takeValue(_ flag: String) -> String {
    guard !args.isEmpty else { fputs("\(flag) needs a value\n", stderr); usage() }
    return args.removeFirst()
}
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--hz":
        guard let v = Double(takeValue(a)), v > 0, v <= 30 else { fputs("--hz must be 0–30\n", stderr); usage() }
        options.hz = v
    case "--enable-login-item": options.enableLoginItem = true
    case "--disable-login-item":
        do { try LoginItem.setEnabled(false); print("login item: \(LoginItem.statusDescription)") }
        catch { fputs("could not unregister login item: \(error)\n", stderr); exit(1) }
        exit(0)
    case "--login-item-status":
        print(LoginItem.statusDescription)
        exit(0)
    case "--render-icon": renderIconPath = takeValue(a)
    case "--size": renderIconSize = Int(takeValue(a)) ?? 1024
    case "--render-iconset": renderIconsetDir = takeValue(a)
    case "--render-dmg-background": renderDMGBackgroundDir = takeValue(a)
    case "--signed": dmgSigned = true
    case "--print-menu":
        options.printMenu = true
        if let next = args.first, !next.hasPrefix("-") { options.printMenuWidget = args.removeFirst() }
    case "--dump-bar": options.dumpBarPath = takeValue(a)
    case "--widget": options.dumpBarWidget = takeValue(a)
    case "--after":
        guard let v = Double(takeValue(a)), v > 0, v <= 300 else { fputs("--after must be 0–300\n", stderr); usage() }
        options.dumpBarAfter = v
    case "--dump-chart":
        // Render the history chart with synthetic data (layout check, no screen grab needed).
        let path = takeValue(a)
        let single = args.first == "--single"
        if single { args.removeFirst() }
        MainActor.assumeIsolated {
            NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
            // A percentage-shaped stand-in for the scalar widgets: one series, fixed 0–100 scale.
            let singleStyle = ChartStyle(
                mode: .single,
                primaryColor: .systemOrange,
                format: { String(format: "%.0f %%", $0) },
                fixedPeak: 100)
            let v = ChartView(frame: NSRect(x: 0, y: 0, width: 448, height: ChartView.chartHeight),
                              style: single ? singleStyle : NetworkWidget.chartStyle)
            let fake: [Sample] = (0..<52).map { i in
                single
                    ? Sample(primary: Double((i * 7) % 55) + Double(i % 3) * 12)
                    : Sample(primary: Double(i % 5) * 400_000,
                             secondary: Double(i % 9) * 1_400_000 + (i % 4 == 0 ? 6_000_000 : 0))
            }
            v.history = { fake }
            v.simulateHover(at: 40)
            v.debugBackground = true
            guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { exit(1) }
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            print("wrote \(path)")
        }
        exit(0)
    case "--dump-cores":
        // The per-core rings with synthetic loads (layout check, no screen grab needed).
        let path = takeValue(a)
        MainActor.assumeIsolated {
            NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
            let groups = CPUInfo.coreGroups
            let v = CoreGaugesView(frame: NSRect(x: 0, y: 0, width: 324,
                                                 height: CoreGaugesView.coresHeight))
            v.groups = {
                groups.enumerated().map { i, g in
                    CoreGaugesView.Group(
                        name: g.name,
                        color: i == 0 ? .systemBlue : .systemGreen,
                        loads: g.range.enumerated().map { k, _ in
                            i == 0 ? [0.92, 0.61, 0.34, 0.08][k % 4] : [0.05, 0.18, 0.02, 0.11][k % 4]
                        })
                }
            }
            v.debugBackground = true
            guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { exit(1) }
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            print("wrote \(path)")
        }
        exit(0)
    case "--dump-segbar":
        // The memory menu's bars: a single-value meter over a four-part breakdown.
        let path = takeValue(a)
        MainActor.assumeIsolated {
            NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
            let w: CGFloat = 324, h = SegmentBarView.height
            let container = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h * 2 + 8))
            let meter = SegmentBarView(frame: NSRect(x: 0, y: h + 8, width: w, height: h))
            meter.segments = { [.init(color: .systemTeal, fraction: 0.37)] }
            meter.debugBackground = true
            let stack = SegmentBarView(frame: NSRect(x: 0, y: 0, width: w, height: h))
            stack.segments = {
                [.init(color: .systemBlue, fraction: 0.117),
                 .init(color: .systemRed, fraction: 0.30),
                 .init(color: .systemIndigo, fraction: 0.254)]
            }
            stack.debugBackground = true
            container.addSubview(meter)
            container.addSubview(stack)
            guard let rep = container.bitmapImageRepForCachingDisplay(in: container.bounds) else { exit(1) }
            container.cacheDisplay(in: container.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            print("wrote \(path)")
        }
        exit(0)
    case "--print":
        // Text dump of what the menu would show, plus a one-second rate sample.
        let before = NetworkMonitor.readCounters()
        let snap = Interfaces.snapshot()
        sleep(1)
        let after = NetworkMonitor.readCounters()
        for i in snap.interfaces {
            let dot = i.dot == .green ? "●" : i.dot == .yellow ? "◐" : "○"
            print("\(dot) \(i.displayName) (\(i.bsdName))\(i.isPrimary ? "  [primary]" : "")  up=\(i.isUp) link=\(i.linkActive.map { "\($0)" } ?? "n/a")")
            if let b = before[i.bsdName], let a = after[i.bsdName] {
                let down = Double(a.inBytes &- b.inBytes) * 8, up = Double(a.outBytes &- b.outBytes) * 8
                print("    ↓ \(Format.rateCompact(bitsPerSecond: down))  ↑ \(Format.rateCompact(bitsPerSecond: up))")
            }
            for ip in i.ipv4 { print("    IPv4     \(ip)") }
            for ip in i.selfAssigned { print("    IPv4     \(ip) (self-assigned)") }
            for ip in i.ipv6 { print("    IPv6     \(ip)") }
            if let w = i.wifi {
                print("    SSID     \(w.ssid ?? "(hidden — needs Location access)")  \(w.security ?? "")")
                print("    Signal   \(w.rssi) dBm, noise \(w.noise) dBm")
                print("    Link     \(Format.linkSpeed(bitsPerSecond: UInt64(w.txRate * 1_000_000)))  ch \(w.channel ?? 0) \(w.band ?? "") \(w.width ?? "") \(w.phyMode ?? "")")
            } else if let sp = i.linkSpeed {
                print("    Link     \(Format.linkSpeed(bitsPerSecond: sp))")
            }
            if let m = i.mac { print("    MAC      \(m)") }
            if let g = i.gateway { print("    Gateway  \(g)") }
            if let g = i.gateway6 { print("    Gateway6 \(g)") }
            if !i.dns.isEmpty { print("    DNS      \(i.dns.joined(separator: ", "))") }
        }
        exit(0)
    case "-h", "--help": usage()
    default:
        // Finder/LaunchServices can pass -psn_… style args; ignore anything unknown.
        if !a.hasPrefix("-psn") { fputs("ignoring unknown argument \(a)\n", stderr) }
    }
}

if let dir = renderIconsetDir {
    do { try AppIcon.writeIconset(to: dir); print("wrote \(dir)") }
    catch { fputs("iconset: \(error)\n", stderr); exit(1) }
    exit(0)
}
if let dir = renderDMGBackgroundDir {
    do { try DMGBackground.write(to: dir, signed: dmgSigned); print("wrote \(dir)") }
    catch { fputs("dmg background: \(error)\n", stderr); exit(1) }
    exit(0)
}
if let path = renderIconPath {
    guard let data = AppIcon.pngData(px: renderIconSize) else { fputs("icon render failed\n", stderr); exit(1) }
    do { try data.write(to: URL(fileURLWithPath: path)); print("wrote \(path) (\(renderIconSize)×\(renderIconSize))") }
    catch { fputs("icon: \(error)\n", stderr); exit(1) }
    exit(0)
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let options: Options
    var widgets: Widgets!

    init(options: Options) { self.options = options }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only: no Dock icon, no app menu. (The bundle's LSUIElement says the same;
        // this also covers running the bare binary.)
        NSApp.setActivationPolicy(.accessory)

        let savedHz = UserDefaults.standard.double(forKey: Widgets.hzDefaultsKey)
        let hz = options.hz ?? (savedHz > 0 ? savedHz : 2)
        widgets = Widgets(hz: hz)
        widgets.start()

        // Login Item. `build.sh install` passes --enable-login-item; a drag-install from the
        // disk image has nobody to pass it, so the first launch from /Applications registers
        // too. Once only — the flag is then set, so turning it off later (menu, System
        // Settings) sticks across relaunches and updates.
        let installed = Bundle.main.bundlePath.hasPrefix("/Applications/")
        let registered = UserDefaults.standard.bool(forKey: LoginItem.registeredDefaultsKey)
        if options.enableLoginItem || (installed && !registered) {
            do { try LoginItem.setEnabled(true); NSLog("login item: \(LoginItem.statusDescription)") }
            catch { NSLog("could not register login item: \(error)") }
            UserDefaults.standard.set(true, forKey: LoginItem.registeredDefaultsKey)
        }

        // The SSID needs Location access. Ask automatically, but only for the installed copy
        // (see requestIfNeededWhenInstalled). Opening the menu asks again if this was missed.
        LocationAccess.shared.requestIfNeededWhenInstalled()

        if options.printMenu {
            let t = Timer(timeInterval: options.dumpBarAfter, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    guard let c = self?.widgets.controller(named: self?.options.printMenuWidget) else {
                        fputs("no such widget showing\n", stderr); exit(1)
                    }
                    // Build once and throw it away, then again a beat later: the rows fed by
                    // two process walks (the busiest-process lists) are empty until there are
                    // two, which is exactly what a real menu shows for its first second.
                    _ = c.dumpMenu()
                    let settle = Timer(timeInterval: 1.4, repeats: false) { _ in
                        MainActor.assumeIsolated {
                            print(c.dumpMenu())
                            exit(0)
                        }
                    }
                    RunLoop.main.add(settle, forMode: .common)
                }
            }
            RunLoop.main.add(t, forMode: .common)
        }

        if let path = options.dumpBarPath {
            let t = Timer(timeInterval: options.dumpBarAfter, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    // Say which of the two went wrong: "failed" alone reads as a rendering
                    // problem when usually the widget is simply switched off.
                    guard let c = self?.widgets.controller(named: self?.options.dumpBarWidget) else {
                        fputs("no such widget showing — check `defaults read \(Bundle.main.bundleIdentifier ?? "") | grep widget`\n", stderr)
                        exit(2)
                    }
                    let ok = c.dumpBar(to: path)
                    NSLog(ok ? "bar → \(path)" : "bar dump failed (the status item has no size — is it hidden?)")
                    exit(ok ? 0 : 1)
                }
            }
            RunLoop.main.add(t, forMode: .common)
        }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate(options: options)
    app.delegate = delegate
    app.run()
}
