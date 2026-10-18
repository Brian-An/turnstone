import AppKit

enum TurnstoneMark {
    static func draw(in rect: NSRect, color: NSColor) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let transform = NSAffineTransform()
        transform.translateX(by: rect.midX, yBy: rect.midY)
        transform.rotate(byDegrees: -12)
        transform.scaleX(by: rect.width / 100, yBy: rect.height / 100)
        transform.translateX(by: -50, yBy: -50)
        transform.concat()

        let stone = NSBezierPath()
        stone.move(to: NSPoint(x: 19, y: 36))
        stone.line(to: NSPoint(x: 48, y: 53))
        stone.curve(to: NSPoint(x: 55, y: 54), controlPoint1: NSPoint(x: 51, y: 55), controlPoint2: NSPoint(x: 52, y: 55))
        stone.line(to: NSPoint(x: 85, y: 48))
        stone.line(to: NSPoint(x: 83, y: 67))
        stone.curve(to: NSPoint(x: 74, y: 80), controlPoint1: NSPoint(x: 82, y: 75), controlPoint2: NSPoint(x: 80, y: 77))
        stone.line(to: NSPoint(x: 58, y: 90))
        stone.curve(to: NSPoint(x: 43, y: 90), controlPoint1: NSPoint(x: 53, y: 94), controlPoint2: NSPoint(x: 48, y: 94))
        stone.line(to: NSPoint(x: 24, y: 78))
        stone.curve(to: NSPoint(x: 16, y: 67), controlPoint1: NSPoint(x: 19, y: 75), controlPoint2: NSPoint(x: 17, y: 72))
        stone.line(to: NSPoint(x: 13, y: 49))
        stone.curve(to: NSPoint(x: 19, y: 36), controlPoint1: NSPoint(x: 12, y: 43), controlPoint2: NSPoint(x: 14, y: 39))
        stone.close()

        stone.move(to: NSPoint(x: 19, y: 28))
        stone.line(to: NSPoint(x: 48, y: 45))
        stone.curve(to: NSPoint(x: 55, y: 46), controlPoint1: NSPoint(x: 51, y: 47), controlPoint2: NSPoint(x: 52, y: 47))
        stone.line(to: NSPoint(x: 84, y: 40))
        stone.line(to: NSPoint(x: 80, y: 25))
        stone.curve(to: NSPoint(x: 72, y: 16), controlPoint1: NSPoint(x: 79, y: 21), controlPoint2: NSPoint(x: 77, y: 18))
        stone.line(to: NSPoint(x: 53, y: 7))
        stone.curve(to: NSPoint(x: 40, y: 8), controlPoint1: NSPoint(x: 48, y: 4), controlPoint2: NSPoint(x: 44, y: 6))
        stone.line(to: NSPoint(x: 25, y: 16))
        stone.curve(to: NSPoint(x: 19, y: 28), controlPoint1: NSPoint(x: 20, y: 19), controlPoint2: NSPoint(x: 19, y: 23))
        stone.close()
        color.setFill()
        stone.fill()
    }

    static func image(size: CGFloat, template: Bool = true) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            draw(in: rect, color: .black)
            return true
        }
        image.isTemplate = template
        image.accessibilityDescription = "Turnstone"
        return image
    }
}
