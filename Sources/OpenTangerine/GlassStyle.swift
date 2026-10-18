import SwiftUI
import AppKit

struct GlassAction: ViewModifier {
    var prominent = false
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            if prominent { content.buttonStyle(.glassProminent) }
            else { content.buttonStyle(.glass).tint(nil as Color?) }
        } else {
            if prominent { content.buttonStyle(.borderedProminent) }
            else { content.buttonStyle(.bordered) }
        }
    }
}

extension View {
    func glassAction(prominent: Bool = false) -> some View { modifier(GlassAction(prominent: prominent)) }
}

struct WindowBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

struct WindowSurface<Content: View>: View {
    let content: Content
    var body: some View { content.background(WindowBackdrop().ignoresSafeArea()).tint(.orange) }
}
