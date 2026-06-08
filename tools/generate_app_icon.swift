#!/usr/bin/env swift
import AppKit

struct IconStyle {
    let background: NSColor
    let symbol: NSColor
    let filename: String
}

let outputDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "TactileNav/Assets.xcassets/AppIcon.appiconset"

let symbolName = "map.fill"
let size = NSSize(width: 1024, height: 1024)

let styles: [IconStyle] = [
    IconStyle(background: .white,
              symbol: NSColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 1.0),
              filename: "AppIcon.png"),
    IconStyle(background: NSColor(red: 0.05, green: 0.12, blue: 0.28, alpha: 1.0),
              symbol: NSColor(red: 0.55, green: 0.78, blue: 1.0, alpha: 1.0),
              filename: "AppIcon-Dark.png"),
    IconStyle(background: NSColor(white: 0.92, alpha: 1.0),
              symbol: NSColor(white: 0.15, alpha: 1.0),
              filename: "AppIcon-Tinted.png"),
]

func renderIcon(style: IconStyle) throws {
    let image = NSImage(size: size)
    image.lockFocus()

    style.background.setFill()
    NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()

    let config = NSImage.SymbolConfiguration(pointSize: 500, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [style.symbol]))
    guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: "TactileNav")?
        .withSymbolConfiguration(config) else {
        throw NSError(domain: "IconGen", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing symbol \(symbolName)"])
    }

    let symbolRect = NSRect(
        x: (size.width - 520) / 2,
        y: (size.height - 520) / 2 - 20,
        width: 520,
        height: 520
    )
    symbol.draw(in: symbolRect)
    image.unlockFocus()

    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff) else {
        throw NSError(domain: "IconGen", code: 2, userInfo: [NSLocalizedDescriptionKey: "Bitmap export failed"])
    }

    let export = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: 1024,
        pixelsHigh: 1024,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: export)
    image.draw(in: NSRect(x: 0, y: 0, width: 1024, height: 1024))
    NSGraphicsContext.restoreGraphicsState()

    guard let png = export.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "IconGen", code: 3, userInfo: [NSLocalizedDescriptionKey: "PNG export failed"])
    }

    let path = (outputDir as NSString).appendingPathComponent(style.filename)
    try png.write(to: URL(fileURLWithPath: path))
    print("Wrote \(path)")
}

for style in styles {
    try renderIcon(style: style)
}
