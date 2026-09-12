// make-icon.swift
// Generates Resources/AppIcon.icns from a programmatic drawing so the app ships
// with a real icon (the overlapping-windows glyph on an accent-blue rounded
// tile, matching the onboarding header). Run via `make icon`.
//
// Usage: swift tools/make-icon.swift <output-dir>

import AppKit
import Foundation

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources"
let iconsetDir = NSTemporaryDirectory() + "ShakaPachi.iconset"

try? FileManager.default.removeItem(atPath: iconsetDir)
try! FileManager.default.createDirectory(
    atPath: iconsetDir, withIntermediateDirectories: true)

/// Draw the icon into a `size`×`size` bitmap and return PNG data.
func renderIcon(size: CGFloat) -> Data {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext

    // Rounded tile with a subtle vertical gradient (accent blue), laid out on
    // Apple's macOS icon grid: the body covers 824 of the 1024pt canvas and the
    // rest stays transparent margin. That margin is what makes the icon read at
    // the same size as system apps in Dock and Launchpad.
    let body = size * (824.0 / 1024.0)
    let origin = (size - body) / 2
    let rect = NSRect(x: origin, y: origin, width: body, height: body)
    let corner = body * 0.25
    let tile = NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner)
    tile.addClip()
    let top = NSColor(calibratedRed: 0.30, green: 0.55, blue: 1.0, alpha: 1)
    let bottom = NSColor(calibratedRed: 0.13, green: 0.39, blue: 0.92, alpha: 1)
    let gradient = NSGradient(starting: top, ending: bottom)!
    gradient.draw(in: rect, angle: -90)

    // Two overlapping rounded window frames in white. Measured against the tile
    // rather than the canvas so the glyph keeps its proportions inside the body
    // whatever margin the grid asks for.
    ctx.resetClip()
    func onTile(_ fraction: CGFloat) -> CGFloat { origin + body * fraction }
    let w = body * 0.386
    let r = body * 0.057
    let line = max(body * 0.057, 1)
    NSColor.white.withAlphaComponent(0.95).setStroke()

    let back = NSBezierPath(
        roundedRect: NSRect(x: onTile(0.205), y: onTile(0.205), width: w, height: w),
        xRadius: r, yRadius: r)
    back.lineWidth = line
    back.stroke()

    let frontRect = NSRect(x: onTile(0.409), y: onTile(0.409), width: w, height: w)
    let front = NSBezierPath(roundedRect: frontRect, xRadius: r, yRadius: r)
    NSColor.white.setFill()
    front.fill()
    NSColor.white.setStroke()
    front.lineWidth = line
    front.stroke()

    image.unlockFocus()

    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("PNG encode failed at size \(size)")
    }
    return png
}

// Standard AppIcon sizes (@1x and @2x).
let specs: [(name: String, px: CGFloat)] = [
    ("icon_16x16",      16),  ("icon_16x16@2x",   32),
    ("icon_32x32",      32),  ("icon_32x32@2x",   64),
    ("icon_128x128",   128),  ("icon_128x128@2x", 256),
    ("icon_256x256",   256),  ("icon_256x256@2x", 512),
    ("icon_512x512",   512),  ("icon_512x512@2x", 1024),
]

for spec in specs {
    let data = renderIcon(size: spec.px)
    let path = "\(iconsetDir)/\(spec.name).png"
    try! data.write(to: URL(fileURLWithPath: path))
}

// Compile the iconset into an .icns.
let icnsPath = "\(outDir)/AppIcon.icns"
let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", iconsetDir, "-o", icnsPath]
try! proc.run()
proc.waitUntilExit()
guard proc.terminationStatus == 0 else {
    fatalError("iconutil failed with status \(proc.terminationStatus)")
}
print("Wrote \(icnsPath)")
