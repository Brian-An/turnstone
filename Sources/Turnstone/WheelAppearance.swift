import SwiftUI
import AppKit

struct WheelPetalAppearance: Identifiable {
    let id: Int
    let path: Path
    let title: String
    let symbol: String?
    let position: CGPoint
}

enum WheelEmphasis {
    static let scale: CGFloat = 1.08
    static let lift: CGFloat = 8

    static func offset(at anchor: CGPoint, from center: CGPoint) -> CGSize {
        let dx = anchor.x - center.x, dy = anchor.y - center.y
        let distance = hypot(dx, dy)
        guard distance > 0 else { return .zero }
        return CGSize(width: dx / distance * lift, height: dy / distance * lift)
    }

    static func transform(at anchor: CGPoint, from center: CGPoint, amount: CGFloat = 1) -> CGAffineTransform {
        let offset = offset(at: anchor, from: center)
        let scale = 1 + (scale - 1) * amount
        return CGAffineTransform(translationX: anchor.x + offset.width * amount, y: anchor.y + offset.height * amount)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -anchor.x, y: -anchor.y)
    }
}

struct WheelAppearance: View {
    let petals: [WheelPetalAppearance]
    let selected: Int?
    let center: CGPoint
    let icon: NSImage?
    let centerTitle: String
    let emptyTitle: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if #available(macOS 26, *) {
                GlassEffectContainer(spacing: 0) { face }
            } else { face }
            HStack(spacing: 12) {
                shortcut(WheelMode.conversions, "Convert")
                shortcut(WheelMode.tools, "Tools")
                shortcut(WheelMode.actions, "Actions")
            }
            .padding(.horizontal, 12).padding(.vertical, 4)
            .modifier(WheelGlass(shape: Capsule(), selected: false))
            .fixedSize().position(x: center.x, y: 341)
        }
        .frame(width: 328, height: 354)
        .animation(reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 0.72), value: selected)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var face: some View {
        if petals.isEmpty {
            VStack(spacing: 9) {
                Text(emptyTitle).font(.system(size: 13, weight: .medium))
                Text("\(WheelMode.actions.symbol) for file actions").font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: 240, height: 110)
            .modifier(WheelGlass(shape: RoundedRectangle(cornerRadius: 26), selected: false))
            .position(center)
        } else {
            ZStack {
                ForEach(petals) { petal in
                    let active = selected == petal.id
                    let lifted = active && !reduceMotion
                    // Animating the path keeps native glass, its outline, and hit testing aligned.
                    let shape = PetalShape(path: petal.path, anchor: petal.position, center: center, emphasis: lifted ? 1 : 0)
                    Color.clear
                        .frame(width: 328, height: 354)
                        .modifier(WheelGlass(shape: shape, selected: active))
                        .overlay(shape.stroke(Color.accentColor.opacity(active ? 0.85 : 0), lineWidth: 1.2))
                        .shadow(color: Color.accentColor.opacity(active ? 0.20 : 0), radius: 8, y: 3)
                        .zIndex(active ? 1 : 0)
                }
            }
            // Keep labels above every glass surface so neighboring petals cannot refract them.
            ForEach(petals) { petal in
                let lifted = selected == petal.id && !reduceMotion
                let offset = lifted ? WheelEmphasis.offset(at: petal.position, from: center) : .zero
                VStack(spacing: 5) {
                    if let symbol = petal.symbol {
                        Image(systemName: symbol).font(.system(size: 17, weight: .regular))
                    }
                    Text(petal.title)
                        .font(.system(size: petal.symbol == nil ? 12 : petals.count > 7 ? 8 : 9, weight: selected == petal.id ? .semibold : .medium))
                        .lineLimit(1).minimumScaleFactor(0.85)
                }
                .foregroundStyle(.primary)
                .frame(width: petals.count > 7 ? 64 : 78)
                .scaleEffect(lifted ? WheelEmphasis.scale : 1)
                .position(petal.position)
                .offset(offset)
            }
            VStack(spacing: 4) {
                if let icon { Image(nsImage: icon).resizable().scaledToFit().frame(width: 27, height: 27) }
                else { TurnstoneLogo().frame(width: 28, height: 28).foregroundStyle(Color.accentColor) }
                Text(centerTitle).font(.system(size: 9, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(width: 84, height: 84)
            .modifier(WheelGlass(shape: Circle(), selected: false))
            .position(center)
        }
    }

    private func shortcut(_ mode: WheelMode, _ title: String) -> some View {
        HStack(spacing: 4) {
            Text(mode.symbol).font(.system(size: 12, weight: .medium))
            Text(title).font(.system(size: 9))
        }.foregroundStyle(.primary)
    }
}

private struct PetalShape: Shape {
    let path: Path
    let anchor: CGPoint
    let center: CGPoint
    var emphasis: CGFloat
    var animatableData: CGFloat {
        get { emphasis }
        set { emphasis = newValue }
    }
    func path(in rect: CGRect) -> Path {
        path.applying(WheelEmphasis.transform(at: anchor, from: center, amount: emphasis))
    }
}

private struct WheelGlass<S: Shape>: ViewModifier {
    let shape: S
    let selected: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency {
            content.background {
                ZStack {
                    shape.fill(Color(nsColor: .windowBackgroundColor))
                    if selected { shape.fill(Color.accentColor.opacity(0.35)) }
                }
            }
            .overlay(shape.stroke(Color.primary.opacity(contrast == .increased ? 0.45 : 0.12), lineWidth: contrast == .increased ? 1 : 0.5))
        } else if #available(macOS 26, *) {
            content.glassEffect(.regular.tint(selected ? Color.accentColor.opacity(0.60) : nil), in: shape)
        } else {
            content.background(.ultraThinMaterial, in: shape)
                .overlay(shape.fill(selected ? Color.accentColor.opacity(0.30) : .clear))
                .overlay(shape.stroke(Color.primary.opacity(contrast == .increased ? 0.45 : 0.10), lineWidth: 0.5))
        }
    }
}

final class WheelHostingView: NSHostingView<WheelAppearance> {
    // AppKit owns every pointer and drag event, including gaps between glass petals.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
