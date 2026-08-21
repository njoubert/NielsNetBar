import AppKit
import ScreenCaptureKit

/// README screenshot helper: grabs every on-screen window this process owns (the status
/// item and the open menu) in one image, on a transparent background. Needs Screen
/// Recording permission like any capture.
enum Screenshot {
    static func captureOwnWindows(to path: String) async -> Bool {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else {
            NSLog("screenshot: no shareable content (Screen Recording permission?)")
            return false
        }
        let pid = getpid()
        let mine = content.windows.filter { $0.owningApplication?.processID == pid && $0.frame.width > 1 && $0.frame.height > 1 }
        guard !mine.isEmpty else { NSLog("screenshot: no windows"); return false }
        let rect = mine.reduce(CGRect.null) { $0.union($1.frame) }.insetBy(dx: -8, dy: -8)
        guard let display = content.displays.first(where: { $0.frame.intersects(rect) }) ?? content.displays.first else { return false }

        let filter = SCContentFilter(display: display, including: mine)
        let scale = CGFloat(filter.pointPixelScale)
        let cfg = SCStreamConfiguration()
        cfg.sourceRect = CGRect(x: rect.minX - display.frame.minX, y: rect.minY - display.frame.minY,
                                width: rect.width, height: rect.height)
        cfg.width = Int(rect.width * scale)
        cfg.height = Int(rect.height * scale)
        cfg.showsCursor = false
        cfg.captureResolution = .best
        cfg.backgroundColor = .clear
        guard let img = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg) else {
            NSLog("screenshot: capture failed")
            return false
        }
        guard let data = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) else { return false }
        do { try data.write(to: URL(fileURLWithPath: path)); return true } catch { NSLog("screenshot: \(error)"); return false }
    }
}
