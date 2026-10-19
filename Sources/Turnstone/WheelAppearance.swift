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
    static let lift: CGFloat = 2

    static func offset(at anchor: CGPoint, from center: CGPoint) -> CGSize {
        let dx = anchor.x - center.x, dy = anchor.y - center.y
        let distance = hypot(dx, dy)
        guard distance > 0 else { return .zero }
        return CGSize(width: dx / distance * lift, height: dy / distance * lift)
    }

    static func transform(at anchor: CGPoint, from center: CGPoint, amount: CGFloat = 1) -> CGAffineTransform {
        let offset = offset(at: anchor, from: center)
        return CGAffineTransform(translationX: offset.width * amount, y: offset.height * amount)
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
            face
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
                    let bounds = petal.path.boundingRect
                    let offset = lifted ? WheelEmphasis.offset(at: petal.position, from: center) : .zero
                    let shape = PetalShape(path: petal.path.offsetBy(dx: -bounds.minX, dy: -bounds.minY), size: bounds.size)
                    // Independent, fixed glass surfaces prevent neighboring selections from morphing together.
                    Color.clear
                        .frame(width: bounds.width, height: bounds.height)
                        .modifier(WheelGlass(shape: shape, selected: active))
                        .animation(nil, value: active)
                        .offset(offset)
                        .position(x: bounds.midX, y: bounds.midY)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: active)
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
                .animation(nil, value: selected == petal.id)
                .frame(width: petals.count > 7 ? 64 : 78)
                .position(petal.position)
                .offset(offset)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: selected == petal.id)
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
    let size: CGSize
    func path(in rect: CGRect) -> Path {
        path.applying(CGAffineTransform(a: rect.width / size.width, b: 0, c: 0, d: rect.height / size.height, tx: rect.minX, ty: rect.minY))
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
                    if selected { shape.fill(Color.accentColor.opacity(0.12)) }
                }
            }
            .overlay(shape.stroke(Color.primary.opacity(contrast == .increased ? 0.45 : 0.12), lineWidth: contrast == .increased ? 1 : 0.5))
        } else if #available(macOS 26, *) {
            content.glassEffect(.regular.tint(selected ? Color.accentColor.opacity(0.18) : nil), in: shape)
        } else {
            content.background(.ultraThinMaterial, in: shape)
                .overlay(shape.fill(selected ? Color.accentColor.opacity(0.12) : .clear))
                .overlay(shape.stroke(Color.primary.opacity(contrast == .increased ? 0.45 : 0.10), lineWidth: 0.5))
        }
    }
}

final class WheelHostingView: NSHostingView<WheelAppearance> {
    // AppKit owns every pointer and drag event, including gaps between glass petals.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
