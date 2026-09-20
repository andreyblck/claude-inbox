#!/usr/bin/env swift
// Draws the app icon and writes an .icns beside it.
//
// The icon is code rather than a binary in the repository: it is reviewable, it
// diffs, and changing it is an edit rather than an import. It is also the picture
// on every notification banner this app sends, which is the only place most
// people will ever see it — so it has to read at 32 points, not just at 1024.
//
//   swift icon.swift            writes build/ClaudeInbox.icns
import AppKit

let sizes = [16, 32, 64, 128, 256, 512, 1024]
let out = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("build")
let iconset = out.appendingPathComponent("ClaudeInbox.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

/// One row of the stack. The top one is the thing that needs you; the two below
/// it are everything else, which is how the panel itself is arranged.
func draw(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let context = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return image
    }
    context.setShouldAntialias(true)

    // macOS icons are a squircle, not a rounded rectangle, and the difference is
    // visible the moment it sits beside a system one.
    let inset = size * 0.06
    let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let squircle = NSBezierPath(roundedRect: rect,
                                xRadius: rect.width * 0.2237,
                                yRadius: rect.height * 0.2237)
    context.saveGState()
    squircle.addClip()

    let background = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            NSColor(calibratedRed: 0.13, green: 0.14, blue: 0.17, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.07, green: 0.07, blue: 0.09, alpha: 1).cgColor,
        ] as CFArray,
        locations: [0, 1])!
    context.drawLinearGradient(
        background,
        start: CGPoint(x: rect.minX, y: rect.maxY),
        end: CGPoint(x: rect.maxX, y: rect.minY),
        options: [])

    // Rows, widest at the top, decreasing — a list read from the top down.
    let barHeight = rect.height * 0.105
    let radius = barHeight / 2
    let left = rect.minX + rect.width * 0.2
    let widths: [CGFloat] = [0.60, 0.44, 0.30]
    let tints: [NSColor] = [
        NSColor(calibratedRed: 0.98, green: 0.72, blue: 0.25, alpha: 1),  // the one that needs you
        NSColor(calibratedWhite: 1, alpha: 0.30),
        NSColor(calibratedWhite: 1, alpha: 0.16),
    ]
    for (index, width) in widths.enumerated() {
        let y = rect.midY + rect.height * 0.17 - CGFloat(index) * barHeight * 1.85
        let bar = NSBezierPath(
            roundedRect: CGRect(x: left, y: y, width: rect.width * width, height: barHeight),
            xRadius: radius, yRadius: radius)
        tints[index].setFill()
        bar.fill()
    }

    context.restoreGState()
    image.unlockFocus()
    return image
}

for size in sizes {
    for scale in [1, 2] {
        let pixels = size * scale
        guard pixels <= 1024 else { continue }
        let image = draw(size: CGFloat(pixels))
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else { continue }
        let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
        try? png.write(to: iconset.appendingPathComponent(name))
    }
}

let convert = Process()
convert.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
convert.arguments = ["-c", "icns", iconset.path, "-o", out.appendingPathComponent("ClaudeInbox.icns").path]
try? convert.run()
convert.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(convert.terminationStatus == 0 ? "build/ClaudeInbox.icns" : "iconutil failed")
