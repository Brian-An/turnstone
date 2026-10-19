import Foundation

public enum WheelGeometry {
    public static func selection(x: Double, y: Double, count: Int, inner: Double = 50, outer: Double = 140, previous: Int? = nil) -> Int? {
        guard count > 0, x.isFinite, y.isFinite else { return nil }
        let distance = hypot(x, y)
        guard distance >= inner, distance <= outer else { return nil }
        let step = 2 * Double.pi / Double(count)
        let angle = (Double.pi / 2 - atan2(y, x) + 2 * Double.pi).truncatingRemainder(dividingBy: 2 * Double.pi)
        if let previous, (0..<count).contains(previous) {
            let delta = abs(atan2(sin(angle - Double(previous) * step), cos(angle - Double(previous) * step)))
            // A small overlap absorbs hand jitter while crossing the decorative gap.
            if delta <= step / 2 + min(.pi / 60, step * 0.12) { return previous }
        }
        return Int((angle / step).rounded()) % count
    }
}
