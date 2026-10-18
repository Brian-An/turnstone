import AppKit
import Foundation

@main
struct MakeIcon {
    static func main() throws {
        let resources = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let iconset = resources.appendingPathComponent("AppIcon.iconset", isDirectory: true)
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let pixels = CGFloat(points * scale)
                guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(pixels), pixelsHigh: Int(pixels), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                      let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw CocoaError(.fileWriteUnknown) }
                // Explicit pixels keep icon sizes independent of the build Mac's display scale.
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = context
                let bounds = NSRect(x: 0, y: 0, width: pixels, height: pixels)
                let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: pixels * 0.06, dy: pixels * 0.06), xRadius: pixels * 0.21, yRadius: pixels * 0.21)
                NSGradient(starting: NSColor(red: 0.35, green: 0.71, blue: 1, alpha: 1), ending: NSColor(red: 0.06, green: 0.30, blue: 0.83, alpha: 1))!.draw(in: shape, angle: -65)
                NSColor.white.withAlphaComponent(0.28).setStroke()
                shape.lineWidth = max(0.5, pixels * 0.002)
                shape.stroke()

                NSGraphicsContext.saveGraphicsState()
                let shadow = NSShadow()
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
                shadow.shadowBlurRadius = pixels * 0.025
                shadow.shadowOffset = NSSize(width: 0, height: -pixels * 0.018)
                shadow.set()
                TurnstoneMark.draw(in: bounds.insetBy(dx: pixels * 0.18, dy: pixels * 0.18), color: .white)
                NSGraphicsContext.restoreGraphicsState()
                NSGraphicsContext.restoreGraphicsState()

                let data = bitmap.representation(using: .png, properties: [:])!
                let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
                try data.write(to: iconset.appendingPathComponent(name))
                if points == 512, scale == 2 { try data.write(to: resources.appendingPathComponent("Turnstone.png")) }
            }
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        process.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("AppIcon.icns").path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { exit(1) }
        try FileManager.default.removeItem(at: iconset)
    }
}
