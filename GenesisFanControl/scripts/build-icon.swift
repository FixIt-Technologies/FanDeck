#!/usr/bin/env swift
//
// build-icon.swift — render fanblades.fill (the menu-bar symbol) into an
// AppIcon.iconset directory, then iconutil it into AppIcon.icns next to
// this script. Run once, or re-run when you want to tweak the look.
//

import AppKit
import Foundation

let scriptDir = (CommandLine.arguments[0] as NSString).deletingLastPathComponent
let outDir = scriptDir + "/AppIcon.iconset"
try? FileManager.default.removeItem(atPath: outDir)
try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let sizes: [(name: String, px: Int)] = [
    ("icon_16x16",      16),  ("icon_16x16@2x",   32),
    ("icon_32x32",      32),  ("icon_32x32@2x",   64),
    ("icon_128x128",   128),  ("icon_128x128@2x", 256),
    ("icon_256x256",   256),  ("icon_256x256@2x", 512),
    ("icon_512x512",   512),  ("icon_512x512@2x",1024),
]

let bgColor    = NSColor(red: 0.06, green: 0.07, blue: 0.10, alpha: 1)
let strokeTop  = NSColor(red: 1.00, green: 0.74, blue: 0.20, alpha: 1)
let strokeBot  = NSColor(red: 1.00, green: 0.46, blue: 0.10, alpha: 1)
let glowColor  = NSColor(red: 1.00, green: 0.60, blue: 0.20, alpha: 0.6)

func render(px: Int) -> Data? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                     pixelsWide: px, pixelsHigh: px,
                                     bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0)
    else { return nil }
    rep.size = NSSize(width: px, height: px)

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    guard let gctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.current = gctx
    gctx.imageInterpolation = .high

    let radius = CGFloat(px) * 0.225
    let rect = NSRect(x: 0, y: 0, width: px, height: px).insetBy(dx: CGFloat(px) * 0.08,
                                                                  dy: CGFloat(px) * 0.08)
    let bgPath = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    bgColor.set()
    bgPath.fill()
    NSColor(white: 1, alpha: 0.08).set()
    bgPath.lineWidth = max(1, CGFloat(px) * 0.005)
    bgPath.stroke()

    let pointSize = CGFloat(px) * 0.55
    var cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .bold)
    cfg = cfg.applying(NSImage.SymbolConfiguration(paletteColors: [strokeTop, strokeBot]))
    guard let raw = NSImage(systemSymbolName: "fanblades.fill", accessibilityDescription: nil),
          let symbol = raw.withSymbolConfiguration(cfg) else { return nil }

    let s = symbol.size
    let symbolRect = NSRect(x: (CGFloat(px) - s.width) / 2,
                            y: (CGFloat(px) - s.height) / 2,
                            width: s.width, height: s.height)

    let shadow = NSShadow()
    shadow.shadowColor = glowColor
    shadow.shadowBlurRadius = CGFloat(px) * 0.06
    shadow.shadowOffset = NSSize(width: 0, height: -CGFloat(px) * 0.01)
    shadow.set()

    symbol.draw(in: symbolRect)

    gctx.flushGraphics()
    return rep.representation(using: .png, properties: [:])
}

for (name, px) in sizes {
    if let png = render(px: px) {
        try png.write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
    } else {
        FileHandle.standardError.write(Data("× failed to render \(name) at \(px)x\(px)\n".utf8))
    }
}

let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", outDir, "-o", scriptDir + "/AppIcon.icns"]
try proc.run()
proc.waitUntilExit()
if proc.terminationStatus == 0 {
    FileHandle.standardOutput.write(Data("✓ AppIcon.icns generated\n".utf8))
} else {
    FileHandle.standardError.write(Data("× iconutil failed: \(proc.terminationStatus)\n".utf8))
    exit(1)
}
