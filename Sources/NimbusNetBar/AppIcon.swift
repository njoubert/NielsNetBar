// Copyright (C) 2026 Niels Joubert
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import AppKit
import CoreGraphics

/// The app icon, drawn in code (no .icns checked in): a dark macOS squircle, a blue ↑ and
/// a green ↓ — upload and download — standing over a glowing throughput trace.
/// `build.sh app` renders it to an .iconset → .icns; `build.sh icon` refreshes docs/icon.png.
enum AppIcon {

    // Apple's macOS icon grid in a 1024-pt reference canvas: 824×824 body, radius 185.4.
    private static let ref: CGFloat = 1024
    private static let bodyInset: CGFloat = 100
    private static let bodyRadius: CGFloat = 185.4

    private static let green = rgb(0x3D, 0xE8, 0x9C)   // download
    private static let blue = rgb(0x3A, 0xA8, 0xFF)    // upload

    /// The scale of the current render: shadow offsets and blurs are in *base* space (the
    /// CTM does not scale them), so every `setShadow` below multiplies by this — otherwise a
    /// blur sized for the 1024 canvas is that many device pixels at every size, and at the
    /// 128-pt icon the body shadow runs off the bottom edge and is clipped to a hard line.
    nonisolated(unsafe) private static var scale: CGFloat = 1

    static func draw(in ctx: CGContext, size: CGFloat) {
        ctx.saveGState()
        scale = size / ref
        ctx.scaleBy(x: scale, y: scale)

        let body = CGRect(x: bodyInset, y: bodyInset, width: ref - 2 * bodyInset, height: ref - 2 * bodyInset)
        let shape = CGPath(roundedRect: body, cornerWidth: bodyRadius, cornerHeight: bodyRadius, transform: nil)

        // Shadow, as macOS icons carry their own. Kept small enough to fade out inside the
        // canvas: a shadow that is still visible at the edge gets clipped to a hard line,
        // which shows as a grey box on light backgrounds (e.g. the disk image window).
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -12 * scale), blur: 28 * scale,
                      color: NSColor(calibratedWhite: 0, alpha: 0.45).cgColor)
        ctx.addPath(shape); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(shape); ctx.clip()

        // Body: deep blue-graphite, lit from the top.
        fillLinear(ctx, from: CGPoint(x: 512, y: body.maxY), to: CGPoint(x: 512, y: body.minY),
                   stops: [(0, rgb(0x2A, 0x36, 0x4A)), (0.5, rgb(0x14, 0x1B, 0x27)), (1, rgb(0x08, 0x0B, 0x11))],
                   rect: body)

        // Bloom behind the trace, as if it is lit.
        drawGlow(ctx, center: CGPoint(x: 512, y: 380), radius: 470, color: rgb(0x2E, 0xE0, 0xC0), alpha: 0.22)

        drawTrace(ctx)
        drawArrows(ctx)

        // Top-edge highlight.
        ctx.addPath(shape)
        ctx.setStrokeColor(NSColor(calibratedWhite: 1, alpha: 0.14).cgColor)
        ctx.setLineWidth(3)
        ctx.strokePath()
        ctx.restoreGState()

        ctx.restoreGState()
    }

    /// The throughput trace: a smooth line through a handful of peaks, filled underneath.
    private static func drawTrace(_ ctx: CGContext) {
        let pts: [CGPoint] = [
            CGPoint(x: 150, y: 300), CGPoint(x: 250, y: 342), CGPoint(x: 330, y: 260),
            CGPoint(x: 410, y: 400), CGPoint(x: 500, y: 270), CGPoint(x: 580, y: 440),
            CGPoint(x: 660, y: 320), CGPoint(x: 740, y: 380), CGPoint(x: 874, y: 288),
        ]
        let line = smoothPath(through: pts)
        let area = CGRect(x: 150, y: 0, width: 724, height: 520)

        // Fill under the line, fading out downwards.
        let fill = line.mutableCopy()!
        fill.addLine(to: CGPoint(x: 874, y: 120))
        fill.addLine(to: CGPoint(x: 150, y: 120))
        fill.closeSubpath()
        ctx.saveGState()
        ctx.addPath(fill); ctx.clip()
        fillLinear(ctx, from: CGPoint(x: 0, y: 440), to: CGPoint(x: 0, y: 120),
                   stops: [(0, green.copy(alpha: 0.30)!), (1, blue.copy(alpha: 0.0)!)], rect: area)
        ctx.restoreGState()

        // The line itself: thick, round, blue → green left to right, with a soft glow.
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 28 * scale, color: green.copy(alpha: 0.55))
        ctx.addPath(line)
        ctx.setLineWidth(30); ctx.setLineCap(.round); ctx.setLineJoin(.round)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        fillLinear(ctx, from: CGPoint(x: 150, y: 0), to: CGPoint(x: 874, y: 0),
                   stops: [(0, blue), (1, green)], rect: area)
        ctx.restoreGState()
    }

    /// ↑ in blue (upload) and ↓ in green (download), side by side above the trace.
    /// Sits a little below the body's top edge (about 10 % of it) so the icon does not
    /// read as top-heavy; the trace is placed to leave the same gap under the arrows.
    private static func drawArrows(_ ctx: CGContext) {
        let top: CGFloat = 800, bottom: CGFloat = 535
        let head: CGFloat = 100
        let w: CGFloat = 74
        let up = CGMutablePath()
        up.move(to: CGPoint(x: 376, y: bottom)); up.addLine(to: CGPoint(x: 376, y: top))
        up.move(to: CGPoint(x: 376 - head, y: top - head)); up.addLine(to: CGPoint(x: 376, y: top))
        up.addLine(to: CGPoint(x: 376 + head, y: top - head))
        let down = CGMutablePath()
        down.move(to: CGPoint(x: 648, y: top)); down.addLine(to: CGPoint(x: 648, y: bottom))
        down.move(to: CGPoint(x: 648 - head, y: bottom + head)); down.addLine(to: CGPoint(x: 648, y: bottom))
        down.addLine(to: CGPoint(x: 648 + head, y: bottom + head))

        for (path, color) in [(up, blue), (down, green)] {
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 34 * scale, color: color.copy(alpha: 0.6))
            ctx.addPath(path)
            ctx.setStrokeColor(color)
            ctx.setLineWidth(w); ctx.setLineCap(.round); ctx.setLineJoin(.round)
            ctx.strokePath()
            ctx.restoreGState()
        }
    }

    // MARK: Helpers

    /// Catmull-Rom → cubic Bézier through every point.
    private static func smoothPath(through p: [CGPoint]) -> CGMutablePath {
        let path = CGMutablePath()
        guard p.count > 1 else { return path }
        path.move(to: p[0])
        for i in 0..<(p.count - 1) {
            let p0 = i > 0 ? p[i - 1] : p[i]
            let p1 = p[i], p2 = p[i + 1]
            let p3 = i + 2 < p.count ? p[i + 2] : p2
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        return path
    }

    private static func rgb(_ r: Int, _ g: Int, _ b: Int) -> CGColor {
        CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }

    private static func fillLinear(_ ctx: CGContext, from: CGPoint, to: CGPoint,
                                   stops: [(CGFloat, CGColor)], rect: CGRect) {
        guard let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 colors: stops.map { $0.1 } as CFArray,
                                 locations: stops.map { $0.0 }) else { return }
        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }

    private static func drawGlow(_ ctx: CGContext, center: CGPoint, radius: CGFloat, color: CGColor, alpha: CGFloat) {
        guard let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 colors: [color.copy(alpha: alpha)!, color.copy(alpha: 0)!] as CFArray,
                                 locations: [0, 1]) else { return }
        ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
    }

    // MARK: Rasterising

    static func cgImage(px: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setAllowsAntialiasing(true)
        ctx.interpolationQuality = .high
        draw(in: ctx, size: CGFloat(px))
        return ctx.makeImage()
    }

    static func pngData(px: Int) -> Data? {
        guard let cg = cgImage(px: px) else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }

    /// Write an .iconset directory for `iconutil -c icns`.
    static func writeIconset(to dir: String) throws {
        let fm = FileManager.default
        try? fm.removeItem(atPath: dir)
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let variants: [(Int, Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                                      (256, 1), (256, 2), (512, 1), (512, 2)]
        for (pt, scale) in variants {
            let name = scale == 1 ? "icon_\(pt)x\(pt).png" : "icon_\(pt)x\(pt)@2x.png"
            guard let data = pngData(px: pt * scale) else { continue }
            try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
        }
    }
}
