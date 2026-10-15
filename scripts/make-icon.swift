// SPDX-License-Identifier: GPL-3.0-or-later
// Renders the Voxum app icon (voice waveform turning into lines of text) and
// writes Resources/AppIcon.icns. Run: swift scripts/make-icon.swift
import AppKit

func render(size: CGFloat) -> NSBitmapImageRep {
    let px = Int(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = size / 1024

    // Squircle body on the macOS icon grid (824 pt body, 100 pt margin) with a soft shadow.
    let body = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let path = CGPath(roundedRect: body, cornerWidth: 185 * s, cornerHeight: 185 * s, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 28 * s,
                  color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(path); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    let colors = [NSColor(srgbRed: 0.39, green: 0.27, blue: 0.96, alpha: 1).cgColor,
                  NSColor(srgbRed: 0.93, green: 0.33, blue: 0.55, alpha: 1).cgColor] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 100 * s, y: 924 * s), end: CGPoint(x: 924 * s, y: 100 * s), options: [])
    // Subtle top highlight.
    let shine = [NSColor.white.withAlphaComponent(0.18).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray
    ctx.drawLinearGradient(CGGradient(colorsSpace: nil, colors: shine, locations: [0, 1])!,
                           start: CGPoint(x: 512 * s, y: 924 * s), end: CGPoint(x: 512 * s, y: 560 * s), options: [])

    func capsule(_ r: CGRect, _ alpha: CGFloat) {
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: min(r.width, r.height) / 2,
                           cornerHeight: min(r.width, r.height) / 2, transform: nil))
        ctx.setFillColor(NSColor.white.withAlphaComponent(alpha).cgColor)
        ctx.fillPath()
    }
    // Waveform bars (left) — the voice.
    let barW: CGFloat = 46, gap: CGFloat = 30, cy: CGFloat = 512
    let heights: [CGFloat] = [150, 300, 420, 250]
    for (i, h) in heights.enumerated() {
        let x = 236 + CGFloat(i) * (barW + gap)
        capsule(CGRect(x: x * s, y: (cy - h / 2) * s, width: barW * s, height: h * s), 1)
    }
    // Text lines (right) — the written result.
    let lineH: CGFloat = 46, lx: CGFloat = 560
    let lines: [(CGFloat, CGFloat)] = [(cy + 95, 228), (cy, 190), (cy - 95, 132)]
    for (y, w) in lines {
        capsule(CGRect(x: lx * s, y: (y - lineH / 2) * s, width: w * s, height: lineH * s), 0.95)
    }
    ctx.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let data = render(size: CGFloat(base * scale)).representation(using: .png, properties: [:])!
        try data.write(to: iconset.appendingPathComponent(name))
    }
}
try render(size: 1024).representation(using: .png, properties: [:])!
    .write(to: root.appendingPathComponent("Resources/AppIcon-1024.png"))
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try task.run(); task.waitUntilExit()
print(task.terminationStatus == 0 ? "OK: Resources/AppIcon.icns" : "iconutil failed")
