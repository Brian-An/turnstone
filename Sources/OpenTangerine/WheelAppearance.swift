import SwiftUI
import AppKit

struct WheelPetalAppearance: Identifiable {
    let id: Int
    let path: Path
    let title: String
    let symbol: String?
    let position: CGPoint
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
            .padding(.horizontal, 12).padding(.vertical, 7)
            .modifier(WheelGlass(shape: Capsule(), selected: false))
            .fixedSize().position(x: center.x, y: 337)
        }
        .frame(width: 328, height: 354)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.14), value: selected)
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
            ForEach(petals) { petal in
                Color.clear
                    .frame(width: 328, height: 354)
                    .modifier(WheelGlass(shape: PetalShape(path: petal.path), selected: selected == petal.id))
            }
            // Keep labels above every glass surface so neighboring petals cannot refract them.
            ForEach(petals) { petal in
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
                .position(petal.position)
            }
            VStack(spacing: 4) {
                if let icon { Image(nsImage: icon).resizable().scaledToFit().frame(width: 27, height: 27) }
                else { Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 23, weight: .light)).foregroundStyle(.orange) }
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
    func path(in rect: CGRect) -> Path { path }
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
                    if selected { shape.fill(Color.orange.opacity(0.20)) }
                }
            }
            .overlay(shape.stroke(Color.primary.opacity(contrast == .increased ? 0.45 : 0.12), lineWidth: contrast == .increased ? 1 : 0.5))
        } else if #available(macOS 26, *) {
            content.glassEffect(.regular.tint(selected ? .orange.opacity(0.25) : nil), in: shape)
        } else {
            content.background(.ultraThinMaterial, in: shape)
                .background(selected ? Color.orange.opacity(0.22) : .clear, in: shape)
                .overlay(shape.stroke(Color.primary.opacity(contrast == .increased ? 0.45 : 0.10), lineWidth: 0.5))
        }
    }
}

final class WheelHostingView: NSHostingView<WheelAppearance> {
    // AppKit owns every pointer and drag event, including gaps between glass petals.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
