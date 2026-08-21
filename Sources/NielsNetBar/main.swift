// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

// NielsNetBar — a menu bar network throughput monitor. See README.md.
//
// Flags (all optional; build.sh uses most of them):
//   --hz N                  sample rate for this run (default: saved setting, else 2)
//   --enable-login-item     register this bundle as a Login Item, then keep running
//   --disable-login-item    unregister the Login Item and exit
//   --login-item-status     print the Login Item state and exit
//   --render-icon PATH [--size PX]   write the app icon as a PNG and exit
//   --render-iconset DIR    write an .iconset (for iconutil) and exit
//   --render-dmg-background DIR   write the disk image's background PNGs (1× and 2×) and exit
//   --screenshot PATH       open the menu, capture it to PATH, quit (for the README)
//   --dump-bar PATH         render just the status item to PATH, quit (layout check)
//   --dump-chart PATH       render the history chart with fake data to PATH, quit
//   --print                 print what the menu would show, as text, and quit

struct Options {
    var hz: Double?
    var enableLoginItem = false
    var screenshotPath: String?
    var dumpBarPath: String?
}

func usage() -> Never {
    print("""
    usage: NielsNetBar [--hz N] [--enable-login-item | --disable-login-item | --login-item-status]
                    [--render-icon PATH [--size PX]] [--render-iconset DIR] [--screenshot PATH]
    """)
    exit(2)
}

var options = Options()
var renderIconPath: String?
var renderIconSize = 1024
var renderIconsetDir: String?
var renderDMGBackgroundDir: String?

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
    case "--screenshot": options.screenshotPath = takeValue(a)
    case "--dump-bar": options.dumpBarPath = takeValue(a)
    case "--dump-chart":
        // Render the history chart with synthetic data (layout check, no screen grab needed).
        let path = takeValue(a)
        MainActor.assumeIsolated {
            NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
            let v = ChartView(frame: NSRect(x: 0, y: 0, width: 448, height: ChartView.chartHeight))
            let fake: [NetworkMonitor.Rate] = (0..<52).map { i in
                NetworkMonitor.Rate(down: Double(i % 9) * 1_400_000 + (i % 4 == 0 ? 6_000_000 : 0), up: Double(i % 5) * 400_000)
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
    do { try DMGBackground.write(to: dir); print("wrote \(dir)") }
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
    var monitor: NetworkMonitor!
    var statusBar: StatusBarController!

    init(options: Options) { self.options = options }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only: no Dock icon, no app menu. (The bundle's LSUIElement says the same;
        // this also covers running the bare binary.)
        NSApp.setActivationPolicy(.accessory)

        let savedHz = UserDefaults.standard.double(forKey: StatusBarController.hzDefaultsKey)
        let hz = options.hz ?? (savedHz > 0 ? savedHz : 2)
        monitor = NetworkMonitor(interval: 1 / hz)
        statusBar = StatusBarController(monitor: monitor)
        monitor.start()

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

        // The SSID needs Location access. Ask once, automatically, but only for the installed
        // copy: an ad-hoc signed dev build is a "new app" to macOS on every rebuild and would
        // re-prompt each time (the menu has a row to ask on demand instead).
        if Bundle.main.bundlePath.hasPrefix("/Applications/") {
            LocationAccess.shared.requestIfNeeded()
        }

        if let path = options.screenshotPath {
            scheduleScreenshot(to: path)
        }
        if let path = options.dumpBarPath {
            let t = Timer(timeInterval: 2.5, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    let ok = self?.statusBar.dumpBar(to: path) ?? false
                    NSLog(ok ? "bar → \(path)" : "bar dump failed")
                    exit(ok ? 0 : 1)
                }
            }
            RunLoop.main.add(t, forMode: .common)
        }
    }

    /// Open the menu, wait for the public IP to land, capture our own windows, quit.
    private func scheduleScreenshot(to path: String) {
        let t1 = Timer(timeInterval: 1.5, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.statusBar.openMenu() }
        }
        RunLoop.main.add(t1, forMode: .common)
        let t2 = Timer(timeInterval: 4.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let ok = await Screenshot.captureOwnWindows(to: path)
                self.statusBar.closeMenu()
                NSLog(ok ? "screenshot → \(path)" : "screenshot failed")
                exit(ok ? 0 : 1)
            }
        }
        RunLoop.main.add(t2, forMode: .common)
        // ScreenCaptureKit blocks on the Screen Recording permission prompt; don't hang forever.
        let t3 = Timer(timeInterval: 20.0, repeats: false) { _ in
            NSLog("screenshot timed out — grant Screen Recording to NielsNetBar in System Settings › Privacy & Security, then retry")
            exit(1)
        }
        RunLoop.main.add(t3, forMode: .common)
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate(options: options)
    app.delegate = delegate
    app.run()
}
