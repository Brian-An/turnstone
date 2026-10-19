import AppKit
import SwiftUI
import TurnstoneCore

enum EditorLayout {
    static func size(for operation: FileOperation, fileCount: Int) -> NSSize {
        guard case .tool(let tool) = operation else { return NSSize(width: 460, height: 280) }
        switch tool {
        case .compress: return NSSize(width: 460, height: 440)
        case .metadata: return NSSize(width: 540, height: 520)
        case .background: return NSSize(width: 520, height: 620)
        case .editImage: return NSSize(width: 540, height: 650)
        case .annotateImage: return NSSize(width: 560, height: 560)
        case .redactImage: return NSSize(width: 560, height: 580)
        case .cropImage: return NSSize(width: 540, height: 540)
        case .collage: return NSSize(width: 540, height: 660)
        case .createPDF, .mergePDF, .joinVideos:
            return NSSize(width: 480, height: min(540, 220 + CGFloat(min(fileCount, 5)) * 54))
        case .organizePDF: return NSSize(width: 640, height: 600)
        case .normalizeAudio, .audioChannels: return NSSize(width: 520, height: 470)
        case .trimAudio, .bleepAudio: return NSSize(width: 540, height: 560)
        default: return NSSize(width: 560, height: 600)
        }
    }

    static func minimumSize(for operation: FileOperation, fileCount: Int) -> NSSize {
        let preferred = size(for: operation, fileCount: fileCount)
        var height: CGFloat = 360
        if case .tool(let tool) = operation,
           [.editImage, .annotateImage, .background, .cropImage, .redactImage, .collage].contains(tool) {
            height = imagePreviewHeight(for: tool) + 280
        }
        return NSSize(width: min(520, preferred.width), height: min(height, preferred.height))
    }

    static func imagePreviewHeight(for tool: ToolID) -> CGFloat {
        switch tool {
        case .editImage, .collage: return 240
        case .annotateImage: return 280
        case .redactImage: return 250
        default: return 260
        }
    }
}

struct EditorScrollView<Content: View>: NSViewRepresentable {
    @ViewBuilder var content: Content

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = EditorNativeScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let document = NSHostingView(rootView: AnyView(content.padding(.trailing, 12).fixedSize(horizontal: false, vertical: true)))
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        NSLayoutConstraint.activate([
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let document = scroll.documentView as? NSHostingView<AnyView> else { return }
        document.rootView = AnyView(content.padding(.trailing, 12).fixedSize(horizontal: false, vertical: true))
    }
}

private final class EditorNativeScrollView: NSScrollView {
    // Keep the editor's overlay style when AppKit broadcasts input-device preference changes.
    override var scrollerStyle: NSScroller.Style {
        get { super.scrollerStyle }
        set { super.scrollerStyle = .overlay }
    }
}
