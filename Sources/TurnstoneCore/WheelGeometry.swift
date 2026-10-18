import Foundation

public enum WheelGeometry {
    public static func selection(x: Double, y: Double, count: Int, inner: Double = 50, outer: Double = 140) -> Int? {
        guard count > 0, x.isFinite, y.isFinite else { return nil }
        let distance = hypot(x, y)
        guard distance >= inner, distance <= outer else { return nil }
        let step = 2 * Double.pi / Double(count)
        let angle = (Double.pi / 2 - atan2(y, x) + 2 * Double.pi).truncatingRemainder(dividingBy: 2 * Double.pi)
        let index = Int((angle / step).rounded()) % count
        let delta = abs(atan2(sin(angle - Double(index) * step), cos(angle - Double(index) * step)))
        return delta < step / 2 - 0.025 ? index : nil
    }
}
