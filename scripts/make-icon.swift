import AppKit
import Foundation

let resources = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let iconset = resources.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let bounds = NSRect(x: 0, y: 0, width: pixels, height: pixels)
        let inset = CGFloat(pixels) * 0.06
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: inset, dy: inset), xRadius: CGFloat(pixels) * 0.21, yRadius: CGFloat(pixels) * 0.21)
        NSGradient(starting: NSColor(red: 0.32, green: 0.68, blue: 1, alpha: 1), ending: NSColor(red: 0.05, green: 0.32, blue: 0.86, alpha: 1))!.draw(in: shape, angle: -55)
        if let symbol = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: CGFloat(pixels) * 0.60, weight: .medium).applying(.init(paletteColors: [.white]))) {
            symbol.draw(in: bounds.insetBy(dx: CGFloat(pixels) * 0.19, dy: CGFloat(pixels) * 0.19))
        }
        image.unlockFocus()
        let data = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try data.write(to: iconset.appendingPathComponent(name))
    }
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("AppIcon.icns").path]
try process.run(); process.waitUntilExit()
guard process.terminationStatus == 0 else { exit(1) }
try FileManager.default.removeItem(at: iconset)
