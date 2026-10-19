import SwiftUI
import AppKit
import PDFKit
import TurnstoneCore

@MainActor
final class ImageEditorModel: ObservableObject {
    @Published var options = EditOptions()
    @Published var files: [URL]
    @Published var preview: NSImage?
    @Published var original: NSImage?
    @Published var error: String?
    @Published var loading = false
    let operation: FileOperation
    private var previewTask: Task<Void, Never>?
    private var revision = 0
    private var rendering = false
    init(files: [URL], operation: FileOperation) {
        self.files = files; self.operation = operation
        if let file = files.first { original = NSImage(contentsOf: file); preview = original }
    }

    func updatePreview() {
        revision += 1
        startPreview()
    }

    private func startPreview() {
        guard !rendering else { return }
        guard case .tool(let tool) = operation,
              [.editImage, .background, .cropImage, .redactImage, .annotateImage, .collage].contains(tool) else { return }
        let version = revision
        let files = files, options = options
        loading = true; rendering = true
        previewTask = Task { [weak self] in
            do {
                let worker = Task.detached(priority: .userInitiated) { try NativeEngine().preview(files: files, tool: tool, options: options, maximumDimension: 1200) }
                let image = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard let self else { return }
                if self.revision == version, !Task.isCancelled {
                    self.preview = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
                    self.error = nil
                }
            } catch {
                if let self, self.revision == version, !(error is CancellationError) { self.error = error.localizedDescription }
            }
            guard let self else { return }
            self.rendering = false; self.loading = false
            if !Task.isCancelled, self.revision != version { self.startPreview() }
        }
    }

    func cancelPreview() { previewTask?.cancel() }
}

struct ToolEditor: View {
    let files: [URL]
    let operation: FileOperation
    let submit: (EditOptions, [URL]) -> Void
    @StateObject private var editor: ImageEditorModel
    @State private var original = false
    init(files: [URL], operation: FileOperation, submit: @escaping (EditOptions, [URL]) -> Void) {
        self.files = files; self.operation = operation; self.submit = submit
        _editor = StateObject(wrappedValue: ImageEditorModel(files: files, operation: operation))
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(operation.title).font(.headline)
                    Text(files.count == 1 ? files[0].lastPathComponent : "\(files.count) files selected").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if isImageEditor {
                    Toggle("Original", isOn: $original).toggleStyle(.button).glassAction().controlSize(.small)
                }
                if editor.loading { ProgressView().controlSize(.small) }
            }.padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            if isImageEditor {
                content.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                EditorScrollView {
                    content.padding(16).frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            if let error = editor.error { Text(error).font(.caption).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.bottom, 10) }
            Divider()
            HStack {
                Button("Reset") { editor.options = EditOptions(); editor.files = files; original = false; resetVersion = UUID() }.glassAction()
                Spacer()
                Button("Save Copy") { submit(editor.options, editor.files) }.glassAction(prominent: true).keyboardShortcut(.defaultAction).disabled(!canSave).help("Saves a new copy beside the original")
            }.padding(.horizontal, 16).padding(.vertical, 12)
        }.frame(minWidth: EditorLayout.minimumSize(for: operation, fileCount: files.count).width, minHeight: EditorLayout.minimumSize(for: operation, fileCount: files.count).height)
        .onReceive(editor.$options.debounce(for: .milliseconds(140), scheduler: RunLoop.main)) { _ in editor.updatePreview() }
        .onChange(of: editor.files) { _ in editor.updatePreview() }
        .onAppear { editor.updatePreview() }
        .onDisappear { editor.cancelPreview() }
    }

    @State private var resetVersion = UUID()
    private var isImageEditor: Bool {
        guard case .tool(let tool) = operation else { return false }
        return [.editImage, .annotateImage, .background, .cropImage, .redactImage, .collage].contains(tool)
    }
    @ViewBuilder private var content: some View {
        switch operation {
        case .convert:
            VStack(alignment: .leading, spacing: 12) {
                Text("EPUB layout").font(.headline)
                Picker("Reading style", selection: $editor.options.epubLayout) {
                    Text("Reflowable text").tag("reflow"); Text("Original page layout").tag("fixed")
                }.pickerStyle(.segmented)
                Text("Reflowable books adapt text to the reader’s screen. Fixed layout preserves each PDF page as an image.").foregroundStyle(.secondary)
            }
        case .tool(let tool):
            switch tool {
            case .editImage, .annotateImage, .background, .cropImage, .redactImage, .collage:
                ImageEditor(editor: editor, tool: tool, original: $original).id(resetVersion)
            case .compress: CompressionControls(files: files, options: $editor.options).id(resetVersion)
            case .metadata: MetadataControls(files: files, options: $editor.options)
            case .organizePDF: PDFOrganizer(file: files[0], options: $editor.options).id(resetVersion)
            case .createPDF, .mergePDF, .joinVideos:
                VStack(alignment: .leading, spacing: 12) {
                    Text(tool == .joinVideos ? "Playback order" : "Document order").font(.headline)
                    FileOrderList(files: $editor.files)
                    Text(tool == .joinVideos ? "Clips use the first video’s canvas and are saved as one MP4." : "Arrange files in the order you want them to appear.").font(.caption).foregroundStyle(.secondary)
                }
            default: MediaEditor(files: files, tool: tool, options: $editor.options).id(resetVersion)
            }
        }
    }

    private var canSave: Bool {
        guard case .tool(let tool) = operation else { return true }
        if tool == .redactImage || tool == .redactVideo { return !editor.options.redactions.isEmpty }
        if tool == .annotateImage { return !editor.options.annotations.isEmpty }
        if tool == .bleepAudio { return !editor.options.ranges.isEmpty }
        if tool == .organizePDF { return !editor.options.pdfPages.isEmpty }
        if tool == .metadata { return editor.options.removeAllMetadata || !editor.options.metadata.isEmpty }
        return true
    }
}

struct FileOrderList: View {
    @Binding var files: [URL]
    var body: some View {
        VStack(spacing: 8) {
            ForEach(Array(files.enumerated()), id: \.offset) { index, url in
                HStack {
                    Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 20)
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 24, height: 24)
                    Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button { files.swapAt(index, index - 1) } label: { Image(systemName: "chevron.up") }.disabled(index == 0).help("Move earlier")
                    Button { files.swapAt(index, index + 1) } label: { Image(systemName: "chevron.down") }.disabled(index == files.count - 1).help("Move later")
                }.padding(8).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}

struct CompressionControls: View {
    let files: [URL]
    @Binding var options: EditOptions
    @State private var target = false
    @State private var mode = "percent"
    @State private var megabytes = 1.0
    @State private var percent = 30.0
    @State private var preset = "balanced"
    private var size: Int { files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Original size: \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))").font(.headline)
            Picker("Compression preset", selection: $preset) { Text("Balanced").tag("balanced"); Text("Strong").tag("strong") }.pickerStyle(.segmented)
                .onChange(of: preset) { options.quality = $0 == "balanced" ? 0.78 : 0.45 }
            if ["jpg", "png", "webp", "heic", "tiff"].contains(Catalog.fileExtension(files[0])) {
                Picker("Image size", selection: Binding(get: { options.maxDimension ?? 0 }, set: { options.maxDimension = $0 == 0 ? nil : $0 })) {
                    Text("Keep original dimensions").tag(0)
                    Text("Up to 2560 px").tag(2560); Text("Up to 1920 px").tag(1920); Text("Up to 1280 px").tag(1280); Text("Up to 640 px").tag(640)
                }
            }
            Divider()
            Toggle("Use a compression target", isOn: $target).onChange(of: target) { _ in updateTarget() }
            if target {
                Picker("Target", selection: $mode) { Text("Percentage reduction").tag("percent"); Text("File size").tag("size") }.pickerStyle(.segmented).onChange(of: mode) { _ in updateTarget() }
                if mode == "size" {
                    HStack { Text("Maximum per file"); TextField("MB", value: $megabytes, format: .number).frame(width: 100); Text("MB") }.onChange(of: megabytes) { _ in updateTarget() }
                } else {
                    HStack { Slider(value: $percent, in: 1...95, step: 1).onChange(of: percent) { _ in updateTarget() }; Text("\(Int(percent))% smaller").frame(width: 100) }
                }
            }
            Text("Some lossless or already compressed files cannot meet a target. A failed target keeps the original and reports an error.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func updateTarget() {
        options.targetBytes = target && mode == "size" ? Int(min(1_000_000_000_000, max(1, megabytes.isFinite ? megabytes * 1_000_000 : 1))) : nil
        options.reduction = target && mode != "size" ? percent : 0
    }
}

struct MetadataControls: View {
    let files: [URL]
    @Binding var options: EditOptions
    @State private var values: [String: String] = [:]
    @State private var search = ""
    @State private var error: String?
    @State private var loading = false
    @State private var tag = "Artist"
    @State private var value = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("Search metadata", text: $search)
            if loading { ProgressView("Reading embedded metadata…") }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            if files.count > 1 { Text("Changes apply to every selected file. The fields below show the first file.").font(.caption).foregroundStyle(.secondary) }
            Toggle("Remove all embedded metadata", isOn: $options.removeAllMetadata)
            ForEach(values.keys.sorted().filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) || values[$0, default: ""].localizedCaseInsensitiveContains(search) }, id: \.self) { key in
                HStack(alignment: .center) {
                    Text(key).font(.caption).frame(width: 180, alignment: .trailing).lineLimit(2)
                    TextField(key, text: Binding(get: { options.metadata[key] ?? values[key, default: ""] }, set: { options.metadata[key] = $0 })).textFieldStyle(.roundedBorder)
                    Button { options.metadata[key] = "" } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless).help("Remove field")
                }
            }.disabled(options.removeAllMetadata)
            Divider()
            HStack {
                TextField("Field name", text: $tag).frame(width: 180)
                TextField("Value", text: $value)
                Button("Add") { if !tag.isEmpty { options.metadata[tag] = value; values[tag] = value } }
            }.disabled(options.removeAllMetadata)
            Text("Metadata removal can change HDR or portrait effects. Read-only fields may not be writable by the file format.").font(.caption).foregroundStyle(.secondary)
        }.task { await load() }
    }

    private func load() async {
        loading = true; defer { loading = false }
        if Catalog.fileExtension(files[0]) == "pdf", let document = PDFDocument(url: files[0]) {
            for (key, value) in document.documentAttributes ?? [:] {
                let name = (key.base as? PDFDocumentAttribute)?.rawValue ?? String(describing: key)
                values[name] = String(describing: value)
            }
            return
        }
        do {
            guard let executable = ProcessRunner.locate("exiftool") else { throw TurnstoneError.missingDependency("ExifTool") }
            let context = try ExecutionContext()
            let json = try await context.runner.run(executable, arguments: ["-j", "-G1", "-s", files[0].path])
            // ExifTool returns a heterogeneous JSON object at this process boundary.
            let records = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]]
            values = (records?.first ?? [:]).filter { key, _ in !key.hasPrefix("File:") && !key.hasPrefix("System:") && !key.hasPrefix("ExifTool:") && key != "SourceFile" }.mapValues { String(describing: $0) }
        } catch { self.error = error.localizedDescription }
    }
}
