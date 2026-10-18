import SwiftUI
import Combine
import AVKit
import AppKit
import UniformTypeIdentifiers
import TangerineCore

@MainActor
struct MediaEditor: View {
    let files: [URL]
    let tool: ToolID
    @Binding var options: EditOptions
    @StateObject private var preview = MediaPreview()
    @State private var position = 0.0
    @State private var selectedRedaction: UUID?
    @State private var splitMode = "Equal clips"
    @State private var ratio = "Free"
    @State private var cropOrigin: UnitRect?
    private let clock = Timer.publish(every: 0.08, on: .main, in: .common).autoconnect()
    private var duration: Double { max(0.01, preview.duration) }
    private var end: Binding<Double> { Binding(get: { options.end ?? duration }, set: { options.end = $0 }) }
    private var isVideo: Bool { preview.width > 0 }

    var body: some View {
        VStack(spacing: 18) {
            if preview.loading { ProgressView("Preparing preview…").frame(maxWidth: .infinity, minHeight: 160) }
            else if isVideo || tool == .audioVisualizer { videoCanvas }
            else { waveform.frame(height: 140).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12)) }
            if let error = preview.error { Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            if !preview.loading {
                if tool == .trimVideo || tool == .trimAudio {
                    HStack { Text("Drag the ends to trim").foregroundStyle(.secondary); Spacer(); Text("\(time((options.end ?? duration) - options.start)) selected").monospacedDigit() }
                    MediaRangeTrack(start: $options.start, end: end, duration: duration, samples: preview.samples, images: preview.frames).frame(height: isVideo ? 66 : 100)
                    HStack { timeField("Start", $options.start); Spacer(); timeField("End", end) }
                    if tool == .trimAudio { Toggle("Trim silent ends automatically", isOn: $options.trimSilence) }
                }
                if tool == .bleepAudio { bleepControls }
                if tool == .cropVideo { cropControls }
                if tool == .redactVideo { redactionControls }
                if tool == .splitVideo { splitControls }
                if tool == .videoSnapshots { snapshotControls }
                if tool == .videoSpeed {
                    HStack { Text("Playback speed"); Slider(value: $options.speed, in: 0.25...4); Text("\(options.speed, specifier: "%.2f")×").monospacedDigit().frame(width: 55) }
                    HStack { ForEach([0.25, 0.5, 1, 1.5, 2, 4], id: \.self) { speed in Button("\(speed, specifier: "%g")×") { options.speed = speed } } }
                    Text("Audio pitch is preserved. Output duration: \(time(duration / options.speed))").font(.caption).foregroundStyle(.secondary)
                }
                if tool == .normalizeAudio { normalizationControls }
                if tool == .audioChannels { channelControls }
                if tool == .audioVisualizer { visualizerControls }
                playback
            }
        }
        .task(id: files.first) { if let file = files.first { await preview.load(file); if options.end == nil { options.end = preview.duration } } }
        .onReceive(clock) { _ in
            let current = preview.player.currentTime().seconds
            if current.isFinite { position = min(duration, max(0, current)) }
            if (tool == .trimAudio || tool == .trimVideo), preview.player.rate > 0, position >= (options.end ?? duration) { preview.player.pause() }
        }
        .onDisappear { preview.player.pause(); preview.context?.runner.cancel() }
    }

    private var waveform: some View { MediaWaveform(samples: preview.samples).padding(12).accessibilityLabel("Audio waveform") }
    private var videoCanvas: some View {
        GeometryReader { proxy in
            let aspect = preview.width > 0 ? CGFloat(preview.width) / CGFloat(max(1, preview.height)) : CGFloat(options.videoWidth) / CGFloat(max(1, options.videoHeight))
            let width = min(proxy.size.width, proxy.size.height * aspect)
            let height = width / aspect
            ZStack {
                Color.black
                VideoPlayer(player: preview.player)
                if tool == .cropVideo { rectangle($options.crop, size: CGSize(width: width, height: height), shaded: false) }
                if tool == .redactVideo {
                    ForEach($options.redactions) { $redaction in
                        if position >= redaction.start && position <= (redaction.end ?? duration) {
                            rectangle($redaction.rect, size: CGSize(width: width, height: height), shaded: true)
                                .onTapGesture { selectedRedaction = redaction.id }
                        }
                    }
                }
            }
            .frame(width: width, height: height).clipShape(RoundedRectangle(cornerRadius: 10))
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }.frame(height: 270)
    }

    private func rectangle(_ rect: Binding<UnitRect>, size: CGSize, shaded: Bool) -> some View {
        let value = rect.wrappedValue
        return ZStack(alignment: .bottomTrailing) {
            Rectangle().fill(shaded ? Color(red: options.color.red, green: options.color.green, blue: options.color.blue).opacity(options.blur ? 0.45 : options.color.alpha) : Color.accentColor.opacity(0.08))
            Rectangle().stroke(Color.accentColor, lineWidth: 2)
            Image(systemName: "arrow.up.left.and.arrow.down.right").font(.caption.bold()).padding(5).background(Color.accentColor).foregroundStyle(.white)
                .gesture(DragGesture(minimumDistance: 0).onChanged { gesture in
                    let origin = cropOrigin ?? value; cropOrigin = origin
                    let parts = ratio.split(separator: ":").compactMap { Double($0) }
                    if tool == .cropVideo, parts.count == 2 {
                        let aspect = parts[0] / parts[1] * Double(size.height / size.width)
                        let width = min(1 - origin.x, (1 - origin.y) * aspect, max(0.02, origin.width + gesture.translation.width / size.width))
                        rect.wrappedValue.width = width; rect.wrappedValue.height = width / aspect
                    } else {
                        rect.wrappedValue.width = min(1 - origin.x, max(0.02, origin.width + gesture.translation.width / size.width))
                        rect.wrappedValue.height = min(1 - origin.y, max(0.02, origin.height + gesture.translation.height / size.height))
                    }
                }.onEnded { _ in cropOrigin = nil })
        }
        .frame(width: size.width * value.width, height: size.height * value.height)
        .position(x: size.width * (value.x + value.width / 2), y: size.height * (value.y + value.height / 2))
        .gesture(DragGesture().onChanged { gesture in
            let origin = cropOrigin ?? value; cropOrigin = origin
            rect.wrappedValue.x = min(1 - origin.width, max(0, origin.x + gesture.translation.width / size.width))
            rect.wrappedValue.y = min(1 - origin.height, max(0, origin.y + gesture.translation.height / size.height))
        }.onEnded { _ in cropOrigin = nil })
        .accessibilityLabel(shaded ? "Redaction rectangle. Drag to move; bottom right handle resizes." : "Crop rectangle. Drag to move; bottom right handle resizes.")
    }

    private var playback: some View {
        VStack(spacing: 10) {
            Slider(value: Binding(get: { position }, set: { position = $0; preview.seek($0) }), in: 0...duration).accessibilityLabel("Playback position")
            HStack(spacing: 16) {
                Button { preview.player.pause(); preview.player.currentItem?.step(byCount: -1) } label: { Image(systemName: "backward.end") }.help("Previous frame")
                Button { if preview.player.rate == 0 { preview.player.play() } else { preview.player.pause() } } label: { Image(systemName: preview.player.rate == 0 ? "play.fill" : "pause.fill") }.help("Play or pause")
                Button { preview.player.pause(); preview.player.currentItem?.step(byCount: 1) } label: { Image(systemName: "forward.end") }.help("Next frame")
                Text("\(time(position)) / \(time(duration))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                if tool == .trimAudio || tool == .trimVideo { Button("Play Selected Range") { preview.seek(options.start); preview.player.play() } }
                Button("Original") { preview.original() }
                if tool != .videoSnapshots && tool != .splitVideo { Button(preview.rendering ? "Preparing…" : tool == .bleepAudio ? "With Bleeps" : "Preview Changes") { Task { await preview.render(tool, options: options) } }.disabled(preview.rendering) }
            }.buttonStyle(.borderless)
        }
    }
    private var cropControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Aspect ratio", selection: $ratio) { ForEach(["Free", "1:1", "16:9", "9:16", "4:3", "3:4"], id: \.self) { Text($0) } }.pickerStyle(.segmented)
                .onChange(of: ratio) { value in
                    let parts = value.split(separator: ":").compactMap { Double($0) }
                    guard parts.count == 2 else { return }
                    let desired = parts[0] / parts[1] * Double(max(1, preview.height)) / Double(max(1, preview.width))
                    options.crop.width = min(1 - options.crop.x, (1 - options.crop.y) * desired)
                    options.crop.height = options.crop.width / desired
                }
            HStack {
                Text("W"); TextField("Width", value: Binding(get: { Int(options.crop.width * Double(preview.width)) }, set: { options.crop.width = min(1 - options.crop.x, max(2 / Double(max(2, preview.width)), Double($0) / Double(max(1, preview.width)))) }), format: .number).frame(width: 85)
                Text("H"); TextField("Height", value: Binding(get: { Int(options.crop.height * Double(preview.height)) }, set: { options.crop.height = min(1 - options.crop.y, max(2 / Double(max(2, preview.height)), Double($0) / Double(max(1, preview.height)))) }), format: .number).frame(width: 85)
                Text("px").foregroundStyle(.secondary); Spacer(); Button("Reset Crop") { options.crop = UnitRect(); ratio = "Free" }
            }
        }
    }
    private var normalizationControls: some View {
        VStack(spacing: 12) {
            numberSlider("Target loudness", $options.loudness, -30 ... -5, "LUFS")
            numberSlider("Loudness range", $options.loudnessRange, 1 ... 20, "LU")
            numberSlider("True peak", $options.truePeak, -9 ... 0, "dBTP")
            Text("Balances loudness while limiting peaks.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var channelControls: some View {
        VStack(spacing: 12) {
            Picker("Output", selection: $options.mono) { Text("Stereo").tag(false); Text("Mono").tag(true) }.pickerStyle(.segmented)
            numberSlider("Left gain", $options.leftVolume, 0 ... 2, "×")
            numberSlider("Right gain", $options.rightVolume, 0 ... 2, "×")
            HStack { Text("Channel preview"); Spacer(); Button("Left") { Task { var values = options; values.mono = false; values.rightVolume = 0; await preview.render(.audioChannels, options: values) } }; Button("Right") { Task { var values = options; values.mono = false; values.leftVolume = 0; await preview.render(.audioChannels, options: values) } }; Button("Both") { Task { await preview.render(.audioChannels, options: options) } } }
        }
    }
    private var visualizerControls: some View {
        VStack(spacing: 12) {
            Picker("Visual", selection: $options.visualizerStyle) { Text("Waveform").tag("waveform"); Text("Still Image").tag("image") }.pickerStyle(.segmented)
            HStack { Text("Canvas"); TextField("Width", value: $options.videoWidth, format: .number).frame(width: 80); Text("×"); TextField("Height", value: $options.videoHeight, format: .number).frame(width: 80); Text("px"); Spacer()
                Menu("Aspect Ratio") { ForEach(["16:9", "9:16", "1:1", "4:3"], id: \.self) { value in Button(value) { let parts = value.split(separator: ":").compactMap { Double($0) }; options.aspectRatio = parts[0] / parts[1]; options.videoHeight = Int(Double(options.videoWidth) / (parts[0] / parts[1])) } } }
            }
            if options.visualizerStyle == "image" { HStack { Button("Choose Background Image…") { let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; if panel.runModal() == .OK { options.backgroundImage = panel.url } }; Text(options.backgroundImage?.lastPathComponent ?? "Choose an image").font(.caption).lineLimit(1) } }
        }
    }
    private var splitControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Split mode", selection: $splitMode) { Text("Equal clips").tag("Equal clips"); Text("Custom cuts").tag("Custom cuts") }.pickerStyle(.segmented)
                .onChange(of: splitMode) { value in if value == "Equal clips" { options.splitPoints = [] } }
            if splitMode == "Equal clips" { Stepper("\(options.equalParts) equal clips, \(time(duration / Double(max(1, options.equalParts)))) each", value: $options.equalParts, in: 2...100) }
            else {
                Button("Add Cut at \(time(position))") { if position > 0, position < duration, !options.splitPoints.contains(position) { options.splitPoints.append(position); options.splitPoints.sort() } }
                ForEach(Array(options.splitPoints.enumerated()), id: \.offset) { index, point in HStack { Text("Cut \(index + 1)"); Text(time(point)).monospacedDigit(); Spacer(); Button("Remove") { options.splitPoints.remove(at: index) } } }
            }
            MediaFilmstrip(images: preview.frames).frame(height: 54).overlay(GeometryReader { geometry in
                let points = splitMode == "Equal clips" ? (1..<max(2, options.equalParts)).map { duration * Double($0) / Double(max(2, options.equalParts)) } : options.splitPoints
                ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                    Rectangle().fill(Color.accentColor).frame(width: 3).contentShape(Rectangle().inset(by: -5)).offset(x: geometry.size.width * point / duration)
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("split")).onChanged { value in
                            guard splitMode == "Custom cuts", options.splitPoints.indices.contains(index) else { return }
                            let lower = index > 0 ? options.splitPoints[index - 1] + 0.01 : 0.01
                            let upper = index + 1 < options.splitPoints.count ? options.splitPoints[index + 1] - 0.01 : duration - 0.01
                            options.splitPoints[index] = min(upper, max(lower, value.location.x / geometry.size.width * duration))
                        })
                }
            }).coordinateSpace(name: "split")
        }
    }
    private var snapshotControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text("\(options.snapshotTimes.count) full-resolution PNG snapshots"); Spacer(); Button("Add Current Frame") { options.snapshotTimes.append(min(position, max(0, duration - 0.01))) } }
            ScrollView(.horizontal) { HStack { ForEach(Array(options.snapshotTimes.enumerated()), id: \.offset) { index, point in VStack { if let frame = preview.frames[safe: min(preview.frames.count - 1, Int(point / duration * Double(preview.frames.count)))] { Image(nsImage: frame).resizable().scaledToFit().frame(width: 100, height: 64) }; HStack { Button(time(point)) { preview.seek(point) }; Button { options.snapshotTimes.remove(at: index) } label: { Image(systemName: "xmark.circle.fill") } } }.padding(6).background(.quaternary, in: RoundedRectangle(cornerRadius: 8)) } } }
        }
    }
    private var redactionControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Button("Add Redaction") { let value = Redaction(rect: UnitRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5), start: position, end: duration); options.redactions.append(value); selectedRedaction = value.id }; Spacer(); Picker("Style", selection: $options.blur) { Text("Solid").tag(false); Text("Blur").tag(true) }.pickerStyle(.segmented).frame(width: 180) }
            if !options.blur { ColorPicker("Redaction color", selection: Binding(get: { Color(red: options.color.red, green: options.color.green, blue: options.color.blue, opacity: options.color.alpha) }, set: { color in if let value = NSColor(color).usingColorSpace(.deviceRGB) { options.color = ColorValue(value.redComponent, value.greenComponent, value.blueComponent, value.alphaComponent) } })) }
            ForEach($options.redactions) { $redaction in HStack { Image(systemName: "rectangle.dashed").foregroundStyle(Color.accentColor); timeField("From", $redaction.start); timeField("To", Binding(get: { redaction.end ?? duration }, set: { redaction.end = $0 })); Spacer(); Button { options.redactions.removeAll { $0.id == redaction.id } } label: { Image(systemName: "trash") } } }
            Text("Drag a box to move it. Drag its bottom right corner to resize.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var bleepControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Bleeps  \(options.ranges.count)").font(.headline); Spacer(); Button("Add at Playhead") { options.ranges.append(TimeRange(start: min(position, max(0, duration - 0.1)), end: min(duration, position + 0.5))) } }
            MediaBleepTrack(ranges: $options.ranges, duration: duration).frame(height: 48)
            Text("Drag across the Bleep layer to add a selection. Drag a clip or either edge to adjust it.").font(.caption).foregroundStyle(.secondary)
            ForEach($options.ranges) { $range in HStack { timeField("From", $range.start); timeField("To", $range.end); Spacer(); Button { options.ranges.removeAll { $0.id == range.id } } label: { Image(systemName: "trash") } } }
        }
    }
    private func numberSlider(_ title: String, _ binding: Binding<Double>, _ range: ClosedRange<Double>, _ unit: String) -> some View { HStack { Text(title).frame(width: 130, alignment: .leading); Slider(value: binding, in: range); TextField(title, value: binding, format: .number.precision(.fractionLength(1))).frame(width: 58); Text(unit).font(.caption).frame(width: 38, alignment: .leading) } }
    private func timeField(_ title: String, _ binding: Binding<Double>) -> some View { HStack { Text(title).foregroundStyle(.secondary); TextField("Seconds", value: binding, format: .number.precision(.fractionLength(2))).frame(width: 75).textFieldStyle(.roundedBorder); Text("s").foregroundStyle(.secondary) } }
    private func time(_ value: Double) -> String { let value = value.isFinite ? max(0, value) : 0; return String(format: "%d:%05.2f", Int(value) / 60, value.truncatingRemainder(dividingBy: 60)) }
}

private struct MediaWaveform: View {
    let samples: [Float]
    var body: some View { Canvas { context, size in
        let values = samples.isEmpty ? [Float](repeating: 0, count: 200) : samples
        let step = size.width / CGFloat(values.count)
        var path = Path()
        for (index, value) in values.enumerated() { let height = max(2, CGFloat(value) * size.height * 0.9); let x = CGFloat(index) * step; path.move(to: CGPoint(x: x, y: (size.height - height) / 2)); path.addLine(to: CGPoint(x: x, y: (size.height + height) / 2)) }
        context.stroke(path, with: .color(Color.accentColor), style: StrokeStyle(lineWidth: max(1, step * 0.55), lineCap: .round))
    } }
}
private struct MediaFilmstrip: View {
    let images: [NSImage]
    var body: some View { GeometryReader { geometry in HStack(spacing: 1) { ForEach(Array(images.enumerated()), id: \.offset) { _, image in Image(nsImage: image).resizable().scaledToFill().frame(width: geometry.size.width / CGFloat(max(1, images.count)), height: geometry.size.height).clipped() } }.background(.quaternary).clipShape(RoundedRectangle(cornerRadius: 6)) } }
}
private struct MediaRangeTrack: View {
    @Binding var start: Double
    @Binding var end: Double
    let duration: Double
    let samples: [Float]
    let images: [NSImage]
    var body: some View { GeometryReader { geometry in
        ZStack(alignment: .leading) {
            if images.isEmpty { MediaWaveform(samples: samples).padding(.vertical, 8) } else { MediaFilmstrip(images: images) }
            Rectangle().fill(Color.accentColor.opacity(0.12)).frame(width: max(0, (end - start) / duration * geometry.size.width)).offset(x: start / duration * geometry.size.width)
            handle("Trim start").offset(x: start / duration * geometry.size.width - 6).gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("trim")).onChanged { start = min(end - 0.01, max(0, $0.location.x / geometry.size.width * duration)) })
            handle("Trim end").offset(x: end / duration * geometry.size.width - 6).gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("trim")).onChanged { end = max(start + 0.01, min(duration, $0.location.x / geometry.size.width * duration)) })
        }.coordinateSpace(name: "trim")
    }.clipShape(RoundedRectangle(cornerRadius: 8)) }
    private func handle(_ title: String) -> some View { RoundedRectangle(cornerRadius: 4).fill(Color.accentColor).frame(width: 12).overlay(Capsule().fill(.white).frame(width: 2, height: 22)).accessibilityLabel(title) }
}
private struct MediaBleepTrack: View {
    @Binding var ranges: [TimeRange]
    let duration: Double
    @State private var original: TimeRange?
    var body: some View { GeometryReader { geometry in
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 8).fill(.quaternary).gesture(DragGesture(minimumDistance: 4).onEnded { value in let start = max(0, min(value.startLocation.x, value.location.x) / geometry.size.width * duration); let end = min(duration, max(value.startLocation.x, value.location.x) / geometry.size.width * duration); if end - start > 0.01 { ranges.append(TimeRange(start: start, end: end)) } })
            ForEach($ranges) { $range in
                ZStack { RoundedRectangle(cornerRadius: 7).fill(Color.accentColor.opacity(0.65)); Text("Bleep").font(.caption.bold()).foregroundStyle(.white); HStack { edge($range, leading: true, width: geometry.size.width); Spacer(minLength: 0); edge($range, leading: false, width: geometry.size.width) }.padding(.horizontal, 4) }
                    .frame(width: max(14, (range.end - range.start) / duration * geometry.size.width)).offset(x: range.start / duration * geometry.size.width)
                    .gesture(DragGesture().onChanged { value in let initial = original ?? range; original = initial; let start = min(duration - (initial.end - initial.start), max(0, initial.start + value.translation.width / geometry.size.width * duration)); range.start = start; range.end = start + initial.end - initial.start }.onEnded { _ in original = nil })
            }
        }
    } }
    private func edge(_ range: Binding<TimeRange>, leading: Bool, width: CGFloat) -> some View { Capsule().fill(.white).frame(width: 4, height: 26).padding(.horizontal, 3).contentShape(Rectangle()).highPriorityGesture(DragGesture(minimumDistance: 0).onChanged { value in let initial = original ?? range.wrappedValue; original = initial; let delta = value.translation.width / width * duration; if leading { range.wrappedValue.start = min(initial.end - 0.01, max(0, initial.start + delta)) } else { range.wrappedValue.end = max(initial.start + 0.01, min(duration, initial.end + delta)) } }.onEnded { _ in original = nil }) }
}

@MainActor
private final class MediaPreview: ObservableObject {
    @Published var player = AVPlayer()
    @Published var duration = 0.0
    @Published var width = 0
    @Published var height = 0
    @Published var samples: [Float] = []
    @Published var frames: [NSImage] = []
    @Published var loading = true
    @Published var rendering = false
    @Published var error: String?
    var context: ExecutionContext?
    private var source: URL?
    private var playable: URL?
    func seek(_ seconds: Double) { player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
    func original() { guard let playable else { return }; player.replaceCurrentItem(with: AVPlayerItem(url: playable)); player.play() }
    func load(_ source: URL) async {
        self.source = source
        do {
            let context = try ExecutionContext(); self.context = context
            let info = try await MediaEngine().info(for: source, context: context)
            duration = info.duration; width = info.width; height = info.height
            var url = source
            if !(try await AVURLAsset(url: source).load(.isPlayable)) {
                guard let ffmpeg = ProcessRunner.locate("ffmpeg") else { throw TangerineError.missingDependency("ffmpeg") }
                url = context.temporaryURL(extension: width > 0 ? "mp4" : "m4a")
                _ = try await context.runner.run(ffmpeg, arguments: ["-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i", source.path] + (width > 0 ? ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac"] : ["-vn", "-c:a", "aac"]) + [url.path])
            }
            playable = url; player.replaceCurrentItem(with: AVPlayerItem(url: url))
            if width > 0 {
                let previewURL = url; let total = duration
                let task = Task.detached(priority: .userInitiated) {
                    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: previewURL)); generator.appliesPreferredTrackTransform = true; generator.maximumSize = CGSize(width: 180, height: 110)
                    return try (0..<10).compactMap { index -> Data? in
                        try Task.checkCancellation()
                        let frame = try generator.copyCGImage(at: CMTime(seconds: total * Double(index) / 10, preferredTimescale: 600), actualTime: nil)
                        return NSBitmapImageRep(cgImage: frame).representation(using: .png, properties: [:])
                    }
                }
                let data = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
                frames = data.compactMap { NSImage(data: $0) }
            } else if info.audioChannels > 0 {
                var audioURL = url
                do { samples = try await Self.waveform(audioURL) }
                catch {
                    guard let ffmpeg = ProcessRunner.locate("ffmpeg") else { throw error }
                    audioURL = context.temporaryURL(extension: "wav")
                    _ = try await context.runner.run(ffmpeg, arguments: ["-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i", source.path, "-vn", "-ac", "1", "-ar", "16000", audioURL.path])
                    samples = try await Self.waveform(audioURL)
                }
            }
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
        loading = false
    }
    func render(_ tool: ToolID, options: EditOptions) async {
        guard let source, let context, !rendering else { return }
        rendering = true; error = nil
        defer { rendering = false }
        do {
            // A temporary symlink keeps generated preview outputs inside the preview workspace.
            let staged = context.temporaryURL(extension: source.pathExtension)
            try FileManager.default.createSymbolicLink(at: staged, withDestinationURL: source)
            guard let output = try await MediaEngine().perform(JobRequest(files: [staged], operation: .tool(tool), options: options), context: context)?.first else { throw TangerineError.unsupported("This preview is unavailable.") }
            player.replaceCurrentItem(with: AVPlayerItem(url: output)); player.play()
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
    nonisolated private static func waveform(_ url: URL) async throws -> [Float] {
        let task = Task.detached(priority: .userInitiated) {
            let file = try AVAudioFile(forReading: url)
            let bins = 360
            var peaks = [Float](repeating: 0, count: bins)
            guard file.length > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192) else { return peaks }
            var cursor: AVAudioFramePosition = 0
            while cursor < file.length {
                try Task.checkCancellation()
                try file.read(into: buffer, frameCount: AVAudioFrameCount(min(8192, file.length - cursor)))
                guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { break }
                for index in 0..<Int(buffer.frameLength) {
                    let bin = min(bins - 1, Int(Double(cursor + Int64(index)) / Double(file.length) * Double(bins)))
                    for channel in 0..<Int(buffer.format.channelCount) { peaks[bin] = max(peaks[bin], abs(channels[channel][index])) }
                }
                cursor += Int64(buffer.frameLength)
            }
            let maximum = max(0.001, peaks.max() ?? 1)
            return peaks.map { $0 / maximum }
        }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
}
private extension Array { subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil } }
