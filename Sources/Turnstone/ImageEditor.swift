import SwiftUI
import AppKit
import TurnstoneCore

struct ImageEditor: View {
    @ObservedObject var editor: ImageEditorModel
    let tool: ToolID
    @State private var original = false
    @State private var kind = "arrow"
    @State private var annotationColor = Color.orange
    @State private var annotationText = "Text"
    @State private var stamp: URL?
    @State private var selected: UUID?
    @State private var ratio = "free"
    @State private var detecting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let image = (original ? editor.original : editor.preview) {
                VStack(spacing: 8) {
                    HStack {
                        Spacer()
                        Toggle("Original", isOn: $original).toggleStyle(.button).glassAction().controlSize(.small)
                    }
                    PhotoCanvas(image: tool == .cropImage ? (editor.original ?? image) : image, tool: tool, options: $editor.options, selected: $selected, kind: kind, annotationColor: annotationColor.value, annotationText: annotationText, stamp: stamp)
                        .frame(height: tool == .collage ? 340 : 360)
                        .background(Color.black.opacity(0.92), in: RoundedRectangle(cornerRadius: 14))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
            } else {
                Text("This file’s preview could not be loaded.").foregroundStyle(.secondary).frame(height: 120)
            }
            switch tool {
            case .editImage: photoControls
            case .background: backgroundControls
            case .cropImage: cropControls
            case .annotateImage: annotationControls
            case .redactImage: redactionControls
            case .collage: collageControls
            default: EmptyView()
            }
        }
    }

    private var photoControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Light").font(.headline)
            adjustment("Exposure", key: \.exposure, range: -3...3, initial: 0, unit: " EV")
            adjustment("Brightness", key: \.brightness, range: -0.5...0.5, initial: 0)
            adjustment("Contrast", key: \.contrast, range: 0...2, initial: 1)
            adjustment("Highlights", key: \.highlights, range: 0...2, initial: 1)
            adjustment("Shadows", key: \.shadows, range: -1...1, initial: 0)
            adjustment("Whites", key: \.whites, range: -1...1, initial: 0)
            adjustment("Blacks", key: \.blacks, range: -1...1, initial: 0)
            adjustment("Gamma", key: \.gamma, range: 0.2...3, initial: 1)
            Divider(); Text("Color").font(.headline)
            adjustment("Temperature", key: \.temperature, range: 2000...10000, initial: 6500, unit: " K")
            adjustment("Tint", key: \.tint, range: -150...150, initial: 0)
            adjustment("Saturation", key: \.saturation, range: 0...2, initial: 1)
            adjustment("Vibrance", key: \.vibrance, range: -1...1, initial: 0)
            adjustment("Hue", key: \.hue, range: -180...180, initial: 0, unit: "°")
            Divider(); Text("Detail & effects").font(.headline)
            adjustment("Clarity", key: \.clarity, range: 0...1, initial: 0)
            adjustment("Sharpness", key: \.sharpness, range: 0...2, initial: 0)
            adjustment("Dehaze", key: \.dehaze, range: 0...1, initial: 0)
            adjustment("Noise reduction", key: \.noiseReduction, range: 0...1, initial: 0)
            adjustment("Grain", key: \.grain, range: 0...1, initial: 0)
            adjustment("Vignette", key: \.vignette, range: 0...2, initial: 0)
        }
    }

    private func adjustment(_ title: String, key: WritableKeyPath<PhotoAdjustments, Double>, range: ClosedRange<Double>, initial: Double, unit: String = "") -> some View {
        HStack(spacing: 12) {
            Text(title).font(.callout).frame(width: 120, alignment: .leading)
            Slider(value: Binding(get: { editor.options.photo[keyPath: key] }, set: { editor.options.photo[keyPath: key] = $0 }), in: range).accessibilityLabel(title)
            Text(String(format: range.upperBound > 100 ? "%.0f%@" : "%.2f%@", editor.options.photo[keyPath: key], unit)).font(.caption.monospacedDigit()).frame(width: 66, alignment: .trailing)
            Button { editor.options.photo[keyPath: key] = initial } label: { Image(systemName: "arrow.counterclockwise") }.buttonStyle(.borderless).help("Reset \(title.lowercased())")
        }
    }

    private var backgroundControls: some View {
        VStack(spacing: 16) {
            Picker("Background", selection: $editor.options.backgroundStyle) {
                Text("Solid color").tag("solid"); Text("Gradient").tag("gradient"); Text("Image").tag("image")
            }.pickerStyle(.segmented)
            HStack {
                ColorPicker("Background color", selection: colorBinding(\EditOptions.background))
                if editor.options.backgroundStyle == "image" { Button("Choose Image…") { chooseImage { editor.options.backgroundImage = $0 } } }
            }
            slider("Padding", value: $editor.options.padding, range: 0...500)
            slider("Corners", value: $editor.options.cornerRadius, range: 0...200)
            slider("Shadow", value: $editor.options.shadowRadius, range: 0...100)
            Picker("Canvas ratio", selection: Binding(get: { editor.options.aspectRatio ?? 0 }, set: { editor.options.aspectRatio = $0 == 0 ? nil : $0 })) {
                Text("Auto").tag(0.0); Text("1:1").tag(1.0); Text("16:9").tag(16.0 / 9); Text("4:5").tag(0.8)
            }.pickerStyle(.segmented)
        }
    }

    private var cropControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Drag the selection or its corner handles to crop.").font(.caption).foregroundStyle(.secondary)
            Picker("Aspect ratio", selection: $ratio) {
                ForEach(["free", "1:1", "16:9", "9:16", "4:3", "3:4"], id: \.self) { Text($0 == "free" ? "Free" : $0).tag($0) }
            }.pickerStyle(.segmented).onChange(of: ratio) { value in
                guard value != "free", let image = editor.original else { return }
                let parts = value.split(separator: ":").compactMap { Double($0) }
                guard parts.count == 2 else { return }
                let unitRatio = parts[0] / parts[1] / (image.size.width / image.size.height)
                let width = min(1, unitRatio), height = min(1, 1 / unitRatio)
                editor.options.crop = UnitRect(x: (1 - width) / 2, y: (1 - height) / 2, width: width, height: height)
            }
            HStack {
                Text("Output size")
                TextField("Width", value: Binding(get: { editor.options.width ?? Int((editor.original?.size.width ?? 100) * editor.options.crop.width) }, set: { newValue in
                    editor.options.width = newValue
                    if editor.options.height == nil { editor.options.height = max(1, Int((editor.original?.size.height ?? 100) * editor.options.crop.height)) }
                }), format: .number).frame(width: 90)
                Text("×")
                TextField("Height", value: Binding(get: { editor.options.height ?? Int((editor.original?.size.height ?? 100) * editor.options.crop.height) }, set: { newValue in
                    editor.options.height = newValue
                    if editor.options.width == nil { editor.options.width = max(1, Int((editor.original?.size.width ?? 100) * editor.options.crop.width)) }
                }), format: .number).frame(width: 90)
                Text("px").foregroundStyle(.secondary)
            }.textFieldStyle(.roundedBorder)
        }
    }

    private var annotationControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 5) {
                ForEach([("arrow", "arrow.up.right"), ("line", "line.diagonal"), ("text", "textformat"), ("rectangle", "rectangle"), ("ellipse", "circle"), ("pen", "pencil.tip"), ("highlight", "highlighter"), ("number", "1.circle"), ("magnify", "plus.magnifyingglass"), ("image", "photo.badge.plus")], id: \.0) { name, symbol in
                    Button { kind = name; if name == "image" { chooseImage { stamp = $0 } } } label: {
                        Image(systemName: symbol).frame(maxWidth: .infinity).frame(height: 26)
                    }.glassAction(prominent: kind == name).help(name.capitalized)
                }
            }
            HStack {
                ColorPicker("Color", selection: $annotationColor).labelsHidden()
                if kind == "text" { TextField("Text", text: $annotationText).textFieldStyle(.roundedBorder).onChange(of: annotationText) { text in
                    if let index = editor.options.annotations.firstIndex(where: { $0.id == selected }) { editor.options.annotations[index].text = text }
                } }
                Spacer()
                Button { if !editor.options.annotations.isEmpty { editor.options.annotations.removeLast() } } label: { Image(systemName: "arrow.uturn.backward") }.help("Undo last annotation")
                Button { editor.options.annotations.removeAll { $0.id == selected }; selected = nil } label: { Image(systemName: "trash") }.disabled(selected == nil).help("Delete selected annotation")
            }
            Text("Drag on the photo to draw. Select an annotation to move or resize it.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var redactionControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Style", selection: $editor.options.blur) { Text("Solid").tag(false); Text("Blur").tag(true) }.pickerStyle(.segmented)
            if !editor.options.blur { ColorPicker("Cover color", selection: colorBinding(\EditOptions.color)) }
            HStack {
                Text("Detect locally").foregroundStyle(.secondary)
                Spacer()
                Button("Faces") { detect(faces: true) }.disabled(detecting)
                Button("Text") { detect(faces: false) }.disabled(detecting)
                Button { editor.options.redactions.removeAll { $0.id == selected }; selected = nil } label: { Image(systemName: "trash") }.disabled(selected == nil).help("Delete selected redaction")
            }
            if detecting { ProgressView("Finding regions on your Mac…") }
            Text("Drag on the photo to cover an area. Solid covers are best for permanently hiding sensitive content.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var collageControls: some View {
        VStack(spacing: 14) {
            Picker("Layout", selection: $editor.options.collageStyle) {
                Text("Grid").tag("grid"); Text("Row").tag("row"); Text("Column").tag("column"); Text("Featured").tag("featured")
            }
            Stepper("Columns: \(editor.options.columns)", value: $editor.options.columns, in: 1...12)
            HStack { Text("Canvas width"); TextField("Pixels", value: $editor.options.canvasWidth, format: .number).frame(width: 100); Text("px").foregroundStyle(.secondary) }
            Picker("Image fit", selection: $editor.options.imageFit) { Text("Fill cells").tag("fill"); Text("Fit inside").tag("fit") }
            slider("Spacing", value: $editor.options.padding, range: 0...200)
            slider("Corners", value: $editor.options.cornerRadius, range: 0...120)
            ColorPicker("Background", selection: colorBinding(\EditOptions.background))
            DisclosureGroup("Image order") { FileOrderList(files: $editor.files).padding(.top, 10) }
        }
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack { Text(title).frame(width: 90, alignment: .leading); Slider(value: value, in: range); Text("\(Int(value.wrappedValue)) px").font(.caption.monospacedDigit()).frame(width: 60) }
    }
    private func colorBinding(_ key: WritableKeyPath<EditOptions, ColorValue>) -> Binding<Color> {
        Binding(get: { Color(editor.options[keyPath: key]) }, set: { editor.options[keyPath: key] = $0.value })
    }
    private func chooseImage(_ completion: @escaping (URL) -> Void) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; panel.canChooseDirectories = false
        panel.begin { response in if response == .OK, let url = panel.url { completion(url) } }
    }
    private func detect(faces: Bool) {
        detecting = true
        Task {
            do {
                let boxes = try await NativeEngine.detectRedactions(in: editor.files[0], faces: faces)
                editor.options.redactions += boxes.map { Redaction(rect: $0) }
            } catch { editor.error = error.localizedDescription }
            detecting = false
        }
    }
}

extension Color {
    init(_ value: ColorValue) { self.init(.sRGB, red: value.red, green: value.green, blue: value.blue, opacity: value.alpha) }
    var value: ColorValue {
        let color = NSColor(self).usingColorSpace(.deviceRGB) ?? .black
        return ColorValue(color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent)
    }
}
