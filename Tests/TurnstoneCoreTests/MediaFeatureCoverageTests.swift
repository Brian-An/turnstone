import AppKit
import Foundation
import XCTest
@testable import TurnstoneCore

final class MediaFeatureCoverageTests: XCTestCase {
    private var directory: URL!
    private var context: ExecutionContext!
    private let engine = MediaEngine()

    override func setUpWithError() throws {
        guard ProcessRunner.locate("ffmpeg") != nil, ProcessRunner.locate("ffprobe") != nil else {
            throw XCTSkip("FFmpeg and ffprobe are required")
        }
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("media-coverage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        context = try ExecutionContext()
    }

    override func tearDownWithError() throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    private func ffmpeg(_ arguments: [String]) async throws -> String {
        try await context.runner.run(XCTUnwrap(ProcessRunner.locate("ffmpeg")), arguments: ["-nostdin", "-hide_banner", "-v", "error", "-y"] + arguments)
    }

    private func fixture(_ name: String, video: String? = nil, audio: String? = "sine=frequency=440:duration=2:sample_rate=48000") async throws -> URL {
        let output = directory.appendingPathComponent(name)
        var arguments: [String] = []
        if let video { arguments += ["-f", "lavfi", "-i", video] }
        if let audio { arguments += ["-f", "lavfi", "-i", audio] }
        if video != nil { arguments += ["-c:v", "libx264", "-pix_fmt", "yuv420p"] }
        _ = try await ffmpeg(arguments + [output.path])
        return output
    }

    private func apply(_ files: [URL], _ operation: FileOperation, _ options: EditOptions = EditOptions()) async throws -> [URL] {
        let outputs = try await engine.perform(JobRequest(files: files, operation: operation, options: options), context: context)
        return try XCTUnwrap(outputs)
    }

    private func samples(_ file: URL, channels: Int = 1) async throws -> [Double] {
        let output = directory.appendingPathComponent("\(UUID().uuidString).raw")
        _ = try await ffmpeg(["-i", file.path, "-ar", "48000", "-ac", String(channels), "-f", "s16le", output.path])
        let bytes = [UInt8](try Data(contentsOf: output))
        return stride(from: 0, to: bytes.count - 1, by: 2).map {
            Double(Int16(bitPattern: UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8)) / 32768
        }
    }

    private func rms(_ samples: [Double], start: Double, end: Double) -> Double {
        let lower = Int(start * 48000)
        let upper = min(Int(end * 48000), samples.count)
        guard upper > lower else { return 0 }
        let range = lower..<upper
        return sqrt(range.reduce(0.0) { $0 + samples[$1] * samples[$1] } / Double(range.count))
    }

    private func frame(_ video: URL, at time: Double) async throws -> NSBitmapImageRep {
        var options = EditOptions(); options.snapshotTimes = [time]
        let image = try await apply([video], .tool(.videoSnapshots), options)[0]
        return try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: image)))
    }

    private func rgb(_ bitmap: NSBitmapImageRep, x: Int, y: Int) throws -> [Double] {
        let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
        return [Double(color.redComponent), Double(color.greenComponent), Double(color.blueComponent)]
    }

    func testEveryAdvertisedMediaConversionProducesDecodableStreamsWithoutChangingSource() async throws {
        let audioFormats = ["mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff", "wma"]
        let videoFormats = ["mp4", "mov", "mkv", "webm", "avi", "wmv", "gif"]
        let sound = try await fixture("seed.wav")
        let movie = try await fixture("seed.mp4", video: "testsrc2=size=64x48:rate=10:duration=2")
        for format in audioFormats + videoFormats {
            let seed = audioFormats.contains(format) ? sound : movie
            let source = try await apply([seed], .convert(format))[0]
            let original = try Data(contentsOf: source)
            for destination in try XCTUnwrap(Catalog.conversions[format]) {
                let output = try await apply([source], .convert(destination))[0]
                let info = try await engine.info(for: output, context: context)
                XCTAssertGreaterThan(info.duration, 1.7, "\(format) -> \(destination)")
                if audioFormats.contains(destination) {
                    XCTAssertGreaterThan(info.audioChannels, 0, "\(format) -> \(destination)")
                    XCTAssertEqual(info.width, 0)
                } else {
                    XCTAssertEqual(info.width, 64, "\(format) -> \(destination)")
                    XCTAssertEqual(info.height, 48)
                    XCTAssertEqual(info.audioChannels > 0, format != "gif" && destination != "gif")
                }
                _ = try await ffmpeg(["-xerror", "-i", output.path, "-f", "null", "-"])
                XCTAssertNotEqual(output, source)
            }
            XCTAssertEqual(try Data(contentsOf: source), original, format)
        }
    }

    func testCropUsesSelectedRegionAndExplicitSplitsUseRequestedDurations() async throws {
        let source = try await fixture("regions.mp4", video: "color=red:size=160x120:rate=20:duration=2,drawbox=x=80:y=0:w=80:h=120:color=blue:t=fill")
        var options = EditOptions(); options.crop = UnitRect(x: 0.5, y: 0.25, width: 0.5, height: 0.5)
        let cropped = try await apply([source], .tool(.cropVideo), options)[0]
        let info = try await engine.info(for: cropped, context: context)
        XCTAssertEqual(info.width, 80); XCTAssertEqual(info.height, 60)
        let pixel = try await rgb(frame(cropped, at: 0.5), x: 40, y: 30)
        XCTAssertLessThan(pixel[0], 0.1); XCTAssertGreaterThan(pixel[2], 0.8)
        options.splitPoints = [0.5, 1.25]
        let parts = try await apply([source], .tool(.splitVideo), options)
        XCTAssertEqual(parts.count, 3)
        for (part, duration) in zip(parts, [0.5, 0.75, 0.75]) {
            let info = try await engine.info(for: part, context: context)
            XCTAssertEqual(info.duration, duration, accuracy: 0.09)
            XCTAssertGreaterThan(info.audioChannels, 0)
        }
    }

    func testJoiningSilentFirstClipPreservesOrderAndInsertsSilence() async throws {
        let first = try await fixture("red ' $ first.mp4", video: "color=red:size=160x120:rate=15:duration=2", audio: nil)
        let second = try await fixture("blue second.mp4", video: "color=blue:size=120x160:rate=24:duration=2")
        let originals = try [first, second].map { try Data(contentsOf: $0) }
        let joined = try await apply([first, second], .tool(.joinVideos))[0]
        let info = try await engine.info(for: joined, context: context)
        XCTAssertEqual(info.width, 160); XCTAssertEqual(info.height, 120)
        XCTAssertEqual(info.duration, 4, accuracy: 0.15); XCTAssertEqual(info.audioChannels, 2)
        let red = try await rgb(frame(joined, at: 0.5), x: 80, y: 60)
        let blue = try await rgb(frame(joined, at: 2.5), x: 80, y: 60)
        let padding = try await rgb(frame(joined, at: 2.5), x: 5, y: 60)
        XCTAssertGreaterThan(red[0], 0.8); XCTAssertLessThan(red[2], 0.1)
        XCTAssertGreaterThan(blue[2], 0.8); XCTAssertLessThan(blue[0], 0.1)
        XCTAssertTrue(padding.allSatisfy { $0 < 0.05 })
        let audio = try await samples(joined)
        XCTAssertLessThan(rms(audio, start: 0.2, end: 1.8), 0.001)
        XCTAssertGreaterThan(rms(audio, start: 2.2, end: 3.8), 0.05)
        XCTAssertEqual(try [first, second].map { try Data(contentsOf: $0) }, originals)
    }

    func testChannelGainsAffectIndependentStereoSignals() async throws {
        let source = try await fixture("stereo.wav", audio: "aevalsrc=0.2*sin(440*2*PI*t)|0.4*sin(880*2*PI*t):s=48000:d=2")
        var options = EditOptions(); options.leftVolume = 0.5; options.rightVolume = 0.25
        let output = try await apply([source], .tool(.audioChannels), options)[0]
        let audio = try await samples(output, channels: 2)
        let left = stride(from: 0, to: audio.count, by: 2).map { audio[$0] }
        let right = stride(from: 1, to: audio.count, by: 2).map { audio[$0] }
        XCTAssertEqual(rms(left, start: 0.1, end: 1.9), 0.07071, accuracy: 0.001)
        XCTAssertEqual(rms(right, start: 0.1, end: 1.9), 0.07071, accuracy: 0.001)
    }

    func testNormalizationReachesRequestedLoudnessInBatch() async throws {
        let sources = try await [fixture("quiet.wav", audio: "aevalsrc=0.01*sin(440*2*PI*t):s=48000:d=3"), fixture("loud.wav", audio: "aevalsrc=0.6*sin(440*2*PI*t):s=48000:d=3")]
        var options = EditOptions(); options.loudness = -20; options.loudnessRange = 7; options.truePeak = -2
        let outputs = try await apply(sources, .tool(.normalizeAudio), options)
        XCTAssertEqual(outputs.count, 2)
        for output in outputs {
            let raw = try await context.runner.run(XCTUnwrap(ProcessRunner.locate("ffmpeg")), arguments: ["-hide_banner", "-i", output.path, "-af", "loudnorm=print_format=json", "-f", "null", "-"])
            let start = try XCTUnwrap(raw.range(of: "{", options: .backwards)?.lowerBound)
            let end = try XCTUnwrap(raw[start...].firstIndex(of: "}"))
            let measurement = try JSONDecoder().decode([String: String].self, from: Data(raw[start...end].utf8))
            let loudness = try XCTUnwrap(Double(try XCTUnwrap(measurement["input_i"])))
            XCTAssertEqual(loudness, -20, accuracy: 0.5)
        }
    }

    func testBatchMuteAndPercentageCompressionPreserveSources() async throws {
        let first = try await fixture("first.mp4", video: "testsrc2=size=160x120:rate=20:duration=2")
        let second = try await fixture("second.mov", video: "testsrc2=size=160x120:rate=20:duration=2")
        let originals = try [first, second].map { try Data(contentsOf: $0) }
        let outputs = try await apply([first, second], .tool(.muteVideo))
        XCTAssertEqual(outputs.count, 2)
        for output in outputs {
            let info = try await engine.info(for: output, context: context)
            XCTAssertEqual(info.audioChannels, 0); XCTAssertEqual(info.duration, 2, accuracy: 0.1)
        }
        let audio = try await fixture("large.wav")
        var options = EditOptions(); options.reduction = 60
        let compressed = try await apply([audio], .tool(.compress), options)[0]
        XCTAssertLessThanOrEqual(try Data(contentsOf: compressed).count, Int(Double(try Data(contentsOf: audio).count) * 0.4))
        XCTAssertEqual(try [first, second].map { try Data(contentsOf: $0) }, originals)
    }

    func testExtremePlaybackSpeedsKeepAudioAndVideoInSync() async throws {
        let source = try await fixture("speed.mp4", video: "testsrc2=size=64x48:rate=30:duration=2")
        for (speed, duration) in [(0.0625, 32.0), (16.0, 0.125)] {
            var options = EditOptions(); options.speed = speed
            let output = try await apply([source], .tool(.videoSpeed), options)[0]
            let info = try await engine.info(for: output, context: context)
            XCTAssertEqual(info.duration, duration, accuracy: speed < 1 ? 0.6 : 0.12)
            XCTAssertGreaterThan(info.audioChannels, 0)
            struct Probe: Decodable {
                struct Stream: Decodable { let codec_type: String; let duration: String }
                let streams: [Stream]
            }
            let raw = try await context.runner.run(XCTUnwrap(ProcessRunner.locate("ffprobe")), arguments: ["-v", "error", "-show_entries", "stream=codec_type,duration", "-of", "json", output.path])
            let streams = try JSONDecoder().decode(Probe.self, from: Data(raw.utf8)).streams
            let videoDuration = try XCTUnwrap(Double(try XCTUnwrap(streams.first { $0.codec_type == "video" }).duration))
            let audioDuration = try XCTUnwrap(Double(try XCTUnwrap(streams.first { $0.codec_type == "audio" }).duration))
            XCTAssertEqual(videoDuration, duration, accuracy: speed < 1 ? 0.6 : 0.12)
            XCTAssertEqual(audioDuration, duration, accuracy: speed < 1 ? 0.6 : 0.12)
            XCTAssertEqual(videoDuration, audioDuration, accuracy: speed < 1 ? 0.6 : 0.12)
        }
    }

    func testCancelledMediaRequestPublishesNothing() async throws {
        let source = try await fixture("cancel.wav")
        let original = try Data(contentsOf: source)
        context.runner.cancel()
        do {
            _ = try await apply([source], .convert("mp3"))
            XCTFail("Cancelled conversion succeeded")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["cancel.wav"])
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testInvalidMediaOptionsFailBeforePublishing() async throws {
        let source = try await fixture("boundaries.mp4", video: "testsrc2=size=64x48:rate=10:duration=2")
        var cases: [(String, ToolID, EditOptions)] = []
        func add(_ label: String, _ tool: ToolID, _ configure: (inout EditOptions) -> Void) {
            var options = EditOptions(); configure(&options); cases.append((label, tool, options))
        }
        for value in [-0.1, Double.nan, Double.infinity] {
            add("trim start \(value)", .trimVideo) { $0.start = value }
        }
        for value in [0, 2.1, Double.nan] {
            add("trim end \(value)", .trimAudio) { $0.end = value }
        }
        for value in [0.0624, 16.01, Double.infinity] {
            add("speed \(value)", .videoSpeed) { $0.speed = value }
        }
        for rect in [UnitRect(x: -0.1), UnitRect(width: 1.01), UnitRect(height: 0), UnitRect(width: 0.01), UnitRect(y: .nan)] {
            add("crop \(rect)", .cropVideo) { $0.crop = rect }
        }
        for points in [[0.0], [2.0], [1.0, 0.5], [0.5, 0.5], [Double.nan]] {
            add("split \(points)", .splitVideo) { $0.splitPoints = points }
        }
        for count in [0, 1001] { add("parts \(count)", .splitVideo) { $0.equalParts = count } }
        for time in [-0.01, 2.0, Double.nan] { add("snapshot \(time)", .videoSnapshots) { $0.snapshotTimes = [time] } }
        for value in [-70.1, -4.9, Double.nan] { add("loudness \(value)", .normalizeAudio) { $0.loudness = value } }
        add("loudness range", .normalizeAudio) { $0.loudnessRange = 0 }
        add("true peak", .normalizeAudio) { $0.truePeak = 0.1 }
        add("negative gain", .audioChannels) { $0.leftVolume = -0.1 }
        add("large gain", .audioChannels) { $0.rightVolume = 10.1 }
        add("nonfinite gain", .audioChannels) { $0.rightVolume = .infinity }
        add("compression quality", .compress) { $0.quality = .nan }
        add("compression reduction", .compress) { $0.reduction = 100.1 }
        add("compression target", .compress) { $0.targetBytes = 1023 }
        add("no redactions", .redactVideo) { _ in }
        add("redaction time", .redactVideo) { $0.redactions = [Redaction(rect: UnitRect(), start: 1.5, end: 1)] }
        add("redaction color", .redactVideo) { $0.redactions = [Redaction(rect: UnitRect())]; $0.color = ColorValue(1.1, 0, 0) }
        add("no bleep ranges", .bleepAudio) { _ in }
        add("bleep time", .bleepAudio) { $0.ranges = [TimeRange(start: 0, end: 2.1)] }
        add("visualizer width", .audioVisualizer) { $0.videoWidth = 1 }
        add("visualizer height", .audioVisualizer) { $0.videoHeight = 7681 }
        add("visualizer aspect", .audioVisualizer) { $0.aspectRatio = .infinity }
        add("missing image", .audioVisualizer) { $0.visualizerStyle = "image" }
        add("empty metadata", .metadata) { _ in }
        add("invalid metadata field", .metadata) { $0.metadata = ["-Title": "invalid"] }
        for (label, tool, options) in cases {
            do {
                _ = try await apply([source], .tool(tool), options)
                XCTFail("Accepted invalid \(label)")
            } catch TurnstoneError.invalid {} catch { XCTFail("Unexpected \(label) error: \(error)") }
        }
        do {
            _ = try await apply([source], .tool(.joinVideos))
            XCTFail("Joined a single video")
        } catch TurnstoneError.invalid {} catch { XCTFail("Unexpected single-join error: \(error)") }
        do {
            _ = try await apply([], .convert("mp3"))
            XCTFail("Converted an empty selection")
        } catch TurnstoneError.invalid {} catch { XCTFail("Unexpected empty-selection error: \(error)") }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["boundaries.mp4"])
    }

    func testMetadataRemovalInBatchClearsTitlesWithoutChangingSources() async throws {
        guard ProcessRunner.locate("exiftool") != nil else { throw XCTSkip("ExifTool is required") }
        let first = try await fixture("tagged.m4a")
        let second = try await fixture("tagged.flac")
        let originals = try [first, second].map { try Data(contentsOf: $0) }
        var options = EditOptions(); options.metadata = ["Title": "Remove this title"]
        let tagged = try await apply([first, second], .tool(.metadata), options)
        options.metadata = [:]; options.removeAllMetadata = true
        let removed = try await apply(tagged, .tool(.metadata), options)
        XCTAssertEqual(removed.count, 2)
        for output in removed {
            let title = try await context.runner.run(XCTUnwrap(ProcessRunner.locate("exiftool")), arguments: ["-s3", "-Title", output.path])
            XCTAssertTrue(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            let info = try await engine.info(for: output, context: context)
            XCTAssertGreaterThan(info.duration, 1.9)
        }
        XCTAssertEqual(try [first, second].map { try Data(contentsOf: $0) }, originals)
    }

    func testMultipleBlurRedactionsApplyOnlyDuringTheirTimeWindows() async throws {
        let source = try await fixture("grid.mp4", video: "color=black:size=160x120:rate=20:duration=2,drawgrid=width=8:height=8:thickness=4:color=white", audio: nil)
        var options = EditOptions(); options.blur = true
        options.redactions = [
            Redaction(rect: UnitRect(x: 0, y: 0, width: 0.5, height: 1), start: 0.5, end: 1),
            Redaction(rect: UnitRect(x: 0.5, y: 0, width: 0.5, height: 1), start: 1, end: 1.5)
        ]
        let output = try await apply([source], .tool(.redactVideo), options)[0]
        let initial = try await frame(output, at: 0.25)
        let leftBlur = try await frame(output, at: 0.75)
        let rightBlur = try await frame(output, at: 1.25)
        let finished = try await frame(output, at: 1.75)
        for x in [34, 114] {
            XCTAssertGreaterThan(try rgb(initial, x: x, y: 34)[0], 0.9)
            XCTAssertGreaterThan(try rgb(finished, x: x, y: 34)[0], 0.9)
        }
        XCTAssertLessThan(try rgb(leftBlur, x: 34, y: 34)[0], 0.85)
        XCTAssertGreaterThan(try rgb(leftBlur, x: 114, y: 34)[0], 0.9)
        XCTAssertGreaterThan(try rgb(rightBlur, x: 34, y: 34)[0], 0.9)
        XCTAssertLessThan(try rgb(rightBlur, x: 114, y: 34)[0], 0.85)
    }

    func testWaveformVisualizerRoundsOddDimensionsAndKeepsAudioDuration() async throws {
        let source = try await fixture("visualizer.wav")
        var options = EditOptions(); options.videoWidth = 161; options.videoHeight = 121
        let output = try await apply([source], .tool(.audioVisualizer), options)[0]
        let info = try await engine.info(for: output, context: context)
        XCTAssertEqual(info.width, 160); XCTAssertEqual(info.height, 120)
        XCTAssertEqual(info.duration, 2, accuracy: 0.1); XCTAssertGreaterThan(info.audioChannels, 0)
        let bitmap = try await frame(output, at: 0.5)
        var orangePixels = 0
        for x in 0..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh {
                let color = try rgb(bitmap, x: x, y: y)
                if color[0] > 0.4, color[0] > color[1] * 1.3, color[1] > color[2] { orangePixels += 1 }
            }
        }
        XCTAssertGreaterThan(orangePixels, 100)
    }

    func testCancellingActiveEncoderDoesNotPublishPartialMedia() async throws {
        let source = try await fixture("active.mp4", video: "testsrc2=size=640x360:rate=30:duration=20", audio: nil)
        let original = try Data(contentsOf: source)
        let conversion = Task { try await self.apply([source], .convert("webm")) }
        defer { conversion.cancel(); context.runner.cancel() }
        var encoderStarted = false
        for _ in 0..<500 {
            if !(try FileManager.default.contentsOfDirectory(atPath: context.temporaryDirectory.path)).isEmpty {
                encoderStarted = true
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        context.runner.cancel()
        do {
            _ = try await conversion.value
            XCTFail("Cancelled encoder published media")
        } catch is CancellationError {} catch { XCTFail("Unexpected cancellation error: \(error)") }
        XCTAssertTrue(encoderStarted, "Encoder never created its staged output")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["active.mp4"])
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testMetadataWorksForEveryAdvertisedMediaFormat() async throws {
        guard ProcessRunner.locate("exiftool") != nil else { throw XCTSkip("ExifTool is required") }
        let audio = try await fixture("metadata-seed.wav")
        let video = try await fixture("metadata-seed.mp4", video: "testsrc2=size=64x48:rate=10:duration=2")
        for format in ["mp3", "m4a", "wav", "flac", "mp4", "mov", "mkv", "gif"] {
            let source = try await apply([["mp3", "m4a", "wav", "flac"].contains(format) ? audio : video], .convert(format))[0]
            let original = try Data(contentsOf: source)
            do {
                let field = ["mp3": "ID3v2_4:Title", "wav": "RIFF:Title", "flac": "Vorbis:Title", "mkv": "Matroska:Title"][format] ?? "Title"
                var options = EditOptions(); options.metadata = [field: "Literal ' $ title"]
                let edited = try await apply([source], .tool(.metadata), options)[0]
                let title = try await context.runner.run(XCTUnwrap(ProcessRunner.locate("exiftool")), arguments: ["-s3", "-Title", edited.path])
                XCTAssertEqual(title.trimmingCharacters(in: .whitespacesAndNewlines), "Literal ' $ title", format)
                let sourceHash = try await ffmpeg(["-i", source.path, "-map", "0", "-f", "hash", "-"])
                let editedHash = try await ffmpeg(["-i", edited.path, "-map", "0", "-f", "hash", "-"])
                XCTAssertEqual(editedHash, sourceHash, "Metadata editing changed decoded media for \(format)")
                options.metadata = [:]; options.removeAllMetadata = true
                let removed = try await apply([edited], .tool(.metadata), options)[0]
                let removedTitle = try await context.runner.run(XCTUnwrap(ProcessRunner.locate("exiftool")), arguments: ["-s3", "-Title", removed.path])
                XCTAssertTrue(removedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, format)
            } catch { XCTFail("\(format) metadata failed: \(error)") }
            XCTAssertEqual(try Data(contentsOf: source), original)
        }
    }
}
