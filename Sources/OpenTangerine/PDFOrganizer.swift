import SwiftUI
import PDFKit
import TangerineCore

struct PDFOrganizer: View {
    let file: URL
    @Binding var options: EditOptions
    @State private var document: PDFDocument?
    @State private var error: String?
    private let columns = [GridItem(.adaptive(minimum: 145), spacing: 14)]
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("\(options.pdfPages.count) pages").font(.headline)
                Spacer()
                Button("Reset Order") { reset() }
            }
            Text("Drag pages to reorder. Use the controls to rotate, duplicate, or remove a page.").font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red) }
            if let document {
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(Array(options.pdfPages.enumerated()), id: \.element.id) { index, edit in
                        VStack(spacing: 8) {
                            ZStack(alignment: .topLeading) {
                                if let page = document.page(at: edit.index)?.copy() as? PDFPage {
                                    Image(nsImage: thumbnail(page, rotation: edit.rotation)).resizable().scaledToFit().frame(height: 170).frame(maxWidth: .infinity)
                                        .background(.white, in: RoundedRectangle(cornerRadius: 8))
                                }
                                Text("\(index + 1)").font(.caption.bold()).foregroundStyle(.white).padding(7).background(Color.accentColor, in: Circle()).padding(6)
                            }
                            HStack(spacing: 10) {
                                Button { change(edit.id) { $0.rotation = ($0.rotation + 90) % 360 } } label: { Image(systemName: "rotate.right") }.help("Rotate page")
                                Button { options.pdfPages.insert(PDFPageEdit(index: edit.index, rotation: edit.rotation), at: index + 1) } label: { Image(systemName: "plus.square.on.square") }.help("Duplicate page")
                                Button { options.pdfPages.removeAll { $0.id == edit.id } } label: { Image(systemName: "trash") }.disabled(options.pdfPages.count < 2).help("Remove page")
                            }.buttonStyle(.borderless)
                            HStack {
                                Button { options.pdfPages.swapAt(index, index - 1) } label: { Image(systemName: "chevron.left") }.disabled(index == 0).help("Move page earlier")
                                Spacer()
                                Text("Source \(edit.index + 1)").font(.caption2).foregroundStyle(.secondary)
                                Spacer()
                                Button { options.pdfPages.swapAt(index, index + 1) } label: { Image(systemName: "chevron.right") }.disabled(index == options.pdfPages.count - 1).help("Move page later")
                            }.buttonStyle(.borderless)
                        }.padding(10).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
                            .draggable(edit.id.uuidString)
                            .dropDestination(for: String.self) { ids, _ in
                                guard let id = ids.first.flatMap(UUID.init(uuidString:)), let from = options.pdfPages.firstIndex(where: { $0.id == id }), from != index else { return false }
                                let moving = options.pdfPages.remove(at: from)
                                options.pdfPages.insert(moving, at: min(index, options.pdfPages.count))
                                return true
                            }
                    }
                }
            }
            Divider()
            Toggle("Make all pages the same width", isOn: $options.matchPageWidth)
            Text("Page contents scale proportionally; their heights may differ.").font(.caption).foregroundStyle(.secondary)
        }.onAppear {
            document = PDFDocument(url: file)
            if document == nil { error = "Could not open this PDF." }
            if options.pdfPages.isEmpty { reset() }
        }
    }
    private func reset() { options.pdfPages = (0..<(document?.pageCount ?? 0)).map { PDFPageEdit(index: $0) } }
    private func change(_ id: UUID, _ operation: (inout PDFPageEdit) -> Void) {
        if let index = options.pdfPages.firstIndex(where: { $0.id == id }) { operation(&options.pdfPages[index]) }
    }
    private func thumbnail(_ page: PDFPage, rotation: Int) -> NSImage {
        page.rotation = (page.rotation + rotation) % 360
        return page.thumbnail(of: NSSize(width: 140, height: 180), for: .mediaBox)
    }
}
