import Foundation
import AppKit
import XCTest
@testable import TurnstoneCore

final class MediaEngineTests: XCTestCase {
    private var directory: URL!
    private var context: ExecutionContext!
    private let engine = MediaEngine()

    override func setUpWithError() throws {
        guard ProcessRunner.locate("ffmpeg") != nil else { throw XCTSkip("FFmpeg is not installed") }
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        context = try ExecutionContext()
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func fixture(_ name: String, video: Bool = false, silent: Bool = false, size: String = "160x120") async throws -> URL {
        let file = directory.appendingPathComponent(name)
        var args = ["-v", "error", "-y"]
        if video { args += ["-f", "lavfi", "-i", "testsrc2=size=\(size):rate=12:duration=2"] }
        if !silent { args += ["-f", "lavfi", "-i", "sine=frequency=440:duration=2:sample_rate=44100"] }
        if video { args += ["-c:v", file.pathExtension == "webm" ? "libvpx-vp9" : "libx264", "-pix_fmt", "yuv420p"] }
        args += [file.path]
        _ = try await context.runner.run(try XCTUnwrap(ProcessRunner.locate("ffmpeg")), arguments: args)
        return file
    }

    private func apply(_ file: URL, _ operation: FileOperation, _ options: EditOptions = EditOptions()) async throws -> [URL] {
        let result = try await engine.perform(JobRequest(files: [file], operation: operation, options: options), context: context)
        return try XCTUnwrap(result)
    }

    func testAudioConversionsPreserveLiteralSourceAndProducePlayableFiles() async throws {
        let source = try await fixture("sound ' $ literal.wav")
        let original = try Data(contentsOf: source)
        for format in ["mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff", "wma"] {
            let output = try await apply(source, .convert(format))[0]
            let info = try await engine.info(for: output, context: context)
            XCTAssertGreaterThan(info.duration, 1.8, format)
            XCTAssertGreaterThan(info.audioChannels, 0, format)
            XCTAssertNotEqual(output, source)
        }
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testVideoConversionsSnapshotsTrimSpeedAndMute() async throws {
        let source = try await fixture("movie.mp4", video: true)
        for format in ["mp4", "mov", "mkv", "webm", "avi", "wmv", "gif", "mp3"] {
            let output = try await apply(source, .convert(format))[0]
            XCTAssertGreaterThan(try Data(contentsOf: output).count, 100, format)
        }
        var options = EditOptions(); options.start = 0.25; options.end = 1.25
        let trimmed = try await apply(source, .tool(.trimVideo), options)[0]
        let probed1 = try await engine.info(for: trimmed, context: context)
        XCTAssertEqual(probed1.duration, 1, accuracy: 0.2)
        options.speed = 2
        let sped = try await apply(source, .tool(.videoSpeed), options)[0]
        let probed2 = try await engine.info(for: sped, context: context)
        XCTAssertEqual(probed2.duration, 1, accuracy: 0.2)
        let muted = try await apply(source, .tool(.muteVideo))[0]
        let probed3 = try await engine.info(for: muted, context: context)
        XCTAssertEqual(probed3.audioChannels, 0)
        options.snapshotTimes = [0, 1]
        let snapshots = try await apply(source, .tool(.videoSnapshots), options)
        XCTAssertEqual(snapshots.count, 2)
        let image = try await engine.info(for: snapshots[0], context: context)
        XCTAssertEqual(image.width, 160); XCTAssertEqual(image.height, 120)
    }

    func testCropSplitJoinRedactionAndBleep() async throws {
        let source = try await fixture("movie.mp4", video: true)
        var options = EditOptions(); options.crop = UnitRect(x: 0, y: 0, width: 0.5, height: 0.5)
        let cropped = try await apply(source, .tool(.cropVideo), options)[0]
        let probed4 = try await engine.info(for: cropped, context: context)
        XCTAssertEqual(probed4.width, 80)
        options.equalParts = 2
        let pieces = try await apply(source, .tool(.splitVideo), options)
        XCTAssertEqual(pieces.count, 2)
        let probed5 = try await engine.info(for: pieces[1], context: context)
        XCTAssertEqual(probed5.duration, 1, accuracy: 0.2)
        let silent = try await fixture("silent.webm", video: true, silent: true, size: "120x160")
        let joinedResult = try await engine.perform(JobRequest(files: [source, silent], operation: .tool(.joinVideos)), context: context)
        let joined = try XCTUnwrap(joinedResult)[0]
        let info = try await engine.info(for: joined, context: context)
        XCTAssertEqual(info.duration, 4, accuracy: 0.3); XCTAssertEqual(info.width, 160); XCTAssertEqual(info.height, 120)
        options.redactions = [Redaction(rect: UnitRect(x: 0.1, y: 0.1, width: 0.4, height: 0.4), start: 0.2, end: 1)]
        for blur in [false, true] {
            options.blur = blur
            let result = try await apply(source, .tool(.redactVideo), options)[0]
            XCTAssertGreaterThan(try Data(contentsOf: result).count, 100)
        }
        options.ranges = [TimeRange(start: 0.2, end: 0.7)]
        let bleeped = try await apply(source, .tool(.bleepAudio), options)[0]
        let probed6 = try await engine.info(for: bleeped, context: context)
        XCTAssertGreaterThan(probed6.audioChannels, 0)
    }

    func testAudioToolsCompressionAndVisualizer() async throws {
        let source = try await fixture("sound.wav")
        var options = EditOptions(); options.mono = true
        let mono = try await apply(source, .tool(.audioChannels), options)[0]
        let probed7 = try await engine.info(for: mono, context: context)
        XCTAssertEqual(probed7.audioChannels, 1)
        options.mono = false; options.leftVolume = 0.5; options.rightVolume = 0.8
        let stereo = try await apply(source, .tool(.audioChannels), options)[0]
        let probed8 = try await engine.info(for: stereo, context: context)
        XCTAssertEqual(probed8.audioChannels, 2)
        options.start = 0.2; options.end = 1.2
        let trimmed = try await apply(source, .tool(.trimAudio), options)[0]
        let probed9 = try await engine.info(for: trimmed, context: context)
        XCTAssertEqual(probed9.duration, 1, accuracy: 0.1)
        let normalized = try await apply(source, .tool(.normalizeAudio), options)[0]
        let probed10 = try await engine.info(for: normalized, context: context)
        XCTAssertGreaterThan(probed10.duration, 1.8)
        options.targetBytes = 40_000
        let compressed = try await apply(source, .tool(.compress), options)[0]
        XCTAssertLessThanOrEqual(try Data(contentsOf: compressed).count, 40_000)
        options.videoWidth = 160; options.videoHeight = 120
        let visualization = try await apply(source, .tool(.audioVisualizer), options)[0]
        let probed11 = try await engine.info(for: visualization, context: context)
        XCTAssertEqual(probed11.width, 160)
    }

    func testVideoRedactionCoversPixelsOnlyDuringItsTimeRange() async throws {
        let source = try await fixture("movie.mp4", video: true)
        var options = EditOptions()
        options.redactions = [Redaction(rect: UnitRect(), start: 0.5, end: 1.5)]
        let output = try await apply(source, .tool(.redactVideo), options)[0]
        options.snapshotTimes = [0.25, 0.75, 1.75]
        let frames = try await apply(output, .tool(.videoSnapshots), options)
        var brightness: [Double] = []
        for frame in frames {
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: frame)))
            var sum = 0.0; var count = 0.0
            for x in stride(from: 10, to: bitmap.pixelsWide, by: 20) {
                for y in stride(from: 10, to: bitmap.pixelsHigh, by: 20) {
                    let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                    sum += Double(color.redComponent + color.greenComponent + color.blueComponent) / 3
                    count += 1
                }
            }
            brightness.append(sum / count)
        }
        XCTAssertGreaterThan(brightness[0], 0.1)
        XCTAssertLessThan(brightness[1], 0.02)
        XCTAssertGreaterThan(brightness[2], 0.1)
    }

    func testRotatedMediaUsesDisplayDimensionsForCropRedactionAndJoin() async throws {
        let source = try await fixture("landscape.mp4", video: true)
        let rotated = directory.appendingPathComponent("portrait.mp4")
        _ = try await context.runner.run(try XCTUnwrap(ProcessRunner.locate("ffmpeg")), arguments: ["-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-display_rotation:v:0", "90", "-i", source.path, "-c", "copy", rotated.path])
        let displayed = try await engine.info(for: rotated, context: context)
        XCTAssertEqual(displayed.width, 120); XCTAssertEqual(displayed.height, 160)
        let cropped = try await apply(rotated, .tool(.cropVideo))[0]
        let croppedInfo = try await engine.info(for: cropped, context: context)
        XCTAssertEqual(croppedInfo.width, 120); XCTAssertEqual(croppedInfo.height, 160)
        var options = EditOptions()
        options.redactions = [Redaction(rect: UnitRect(x: 0, y: 0.5, width: 1, height: 0.5), start: 0, end: 2)]
        let redacted = try await apply(rotated, .tool(.redactVideo), options)[0]
        options.snapshotTimes = [0.5]
        let frame = try await apply(redacted, .tool(.videoSnapshots), options)[0]
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: frame)))
        XCTAssertEqual(bitmap.pixelsWide, 120); XCTAssertEqual(bitmap.pixelsHigh, 160)
        var pixel = [Int](repeating: 0, count: max(4, bitmap.samplesPerPixel))
        bitmap.getPixel(&pixel, atX: 100, y: 140)
        XCTAssertLessThan(pixel[0], 10); XCTAssertLessThan(pixel[1], 10); XCTAssertLessThan(pixel[2], 10)
        let joined = try await engine.perform(JobRequest(files: [rotated, source], operation: .tool(.joinVideos)), context: context)
        let joinedInfo = try await engine.info(for: XCTUnwrap(joined?.first), context: context)
        XCTAssertEqual(joinedInfo.width, 120); XCTAssertEqual(joinedInfo.height, 160)
        XCTAssertEqual(joinedInfo.duration, 4, accuracy: 0.3)
    }

    func testVideoRedactionUsesSelectedSolidColor() async throws {
        let source = try await fixture("movie.mp4", video: true)
        var options = EditOptions()
        options.color = ColorValue(1, 0, 0)
        options.redactions = [Redaction(rect: UnitRect(), start: 0, end: 2)]
        let output = try await apply(source, .tool(.redactVideo), options)[0]
        options.snapshotTimes = [0.5]
        let frame = try await apply(output, .tool(.videoSnapshots), options)[0]
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: frame)))
        var pixel = [Int](repeating: 0, count: max(4, bitmap.samplesPerPixel))
        bitmap.getPixel(&pixel, atX: 40, y: 40)
        XCTAssertGreaterThan(pixel[0], 230)
        XCTAssertLessThan(pixel[1], 20)
        XCTAssertLessThan(pixel[2], 20)
    }

    func testBleepReplacesOriginalAudioInsideRanges() async throws {
        let source = try await fixture("voice.wav")
        var options = EditOptions(); options.ranges = [TimeRange(start: 0.5, end: 1.5)]
        let output = try await apply(source, .tool(.bleepAudio), options)[0]
        let pcm = directory.appendingPathComponent("samples.raw")
        _ = try await context.runner.run(try XCTUnwrap(ProcessRunner.locate("ffmpeg")), arguments: ["-v", "error", "-y", "-i", output.path, "-ar", "48000", "-ac", "1", "-f", "s16le", pcm.path])
        let bytes = [UInt8](try Data(contentsOf: pcm))
        let samples = stride(from: 0, to: bytes.count - 1, by: 2).map { index in
            Double(Int16(bitPattern: UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8)) / 32768
        }
        func amplitude(_ frequency: Double, start: Double, end: Double) -> Double {
            let bounds = Int(start * 48000)..<Int(end * 48000)
            let sum = bounds.reduce(0.0) { $0 + samples[$1] * sin(2 * .pi * frequency * Double($1) / 48000) }
            return abs(2 * sum / Double(bounds.count))
        }
        XCTAssertGreaterThan(amplitude(440, start: 0.1, end: 0.4), 0.1)
        XCTAssertLessThan(amplitude(440, start: 0.7, end: 1.3), 0.001)
        XCTAssertGreaterThan(amplitude(1000, start: 0.7, end: 1.3), 0.01)
        XCTAssertGreaterThan(amplitude(440, start: 1.6, end: 1.9), 0.1)
    }

    func testMonoConversionAppliesGainsBeforeMixingChannels() async throws {
        let source = directory.appendingPathComponent("left-only.wav")
        _ = try await context.runner.run(try XCTUnwrap(ProcessRunner.locate("ffmpeg")), arguments: ["-v", "error", "-y", "-f", "lavfi", "-i", "aevalsrc=0.3*sin(440*2*PI*t)|0:s=44100:d=1", source.path])
        var options = EditOptions(); options.mono = true; options.leftVolume = 0; options.rightVolume = 1
        let output = try await apply(source, .tool(.audioChannels), options)[0]
        let pcm = directory.appendingPathComponent("samples.raw")
        _ = try await context.runner.run(try XCTUnwrap(ProcessRunner.locate("ffmpeg")), arguments: ["-v", "error", "-y", "-i", output.path, "-f", "s16le", pcm.path])
        XCTAssertTrue(try Data(contentsOf: pcm).allSatisfy { $0 == 0 })
    }

    func testSilenceTrimmingKeepsInternalPauses() async throws {
        let source = directory.appendingPathComponent("pauses.wav")
        let signal = "aevalsrc=if(between(t\\,0.3\\,0.7)+between(t\\,1.2\\,1.6)\\,0.1*sin(440*2*PI*t)\\,0):s=44100:d=1.9"
        _ = try await context.runner.run(try XCTUnwrap(ProcessRunner.locate("ffmpeg")), arguments: ["-v", "error", "-y", "-f", "lavfi", "-i", signal, source.path])
        var options = EditOptions(); options.trimSilence = true
        let result = try await apply(source, .tool(.trimAudio), options)[0]
        let info = try await engine.info(for: result, context: context)
        XCTAssertEqual(info.duration, 1.3, accuracy: 0.08)
    }

    func testGIFVideoRoundTripAndStillImageVisualizer() async throws {
        let source = try await fixture("movie.mp4", video: true)
        let gif = try await apply(source, .convert("gif"))[0]
        let roundTrip = try await apply(gif, .convert("mp4"))[0]
        let info = try await engine.info(for: roundTrip, context: context)
        XCTAssertGreaterThan(info.duration, 1.8)
        var options = EditOptions(); options.snapshotTimes = [0]
        let image = try await apply(source, .tool(.videoSnapshots), options)[0]
        let audio = try await fixture("sound.wav")
        options.visualizerStyle = "image"; options.backgroundImage = image
        options.videoWidth = 160; options.videoHeight = 120; options.aspectRatio = 1
        let visualization = try await apply(audio, .tool(.audioVisualizer), options)[0]
        let visualInfo = try await engine.info(for: visualization, context: context)
        XCTAssertEqual(visualInfo.width, 160); XCTAssertEqual(visualInfo.height, 160)
        XCTAssertEqual(visualInfo.duration, 2, accuracy: 0.1)
    }

    func testMetadataIsWrittenToSeparateOutputAndSourcePreserved() async throws {
        guard ProcessRunner.locate("exiftool") != nil else { throw XCTSkip("ExifTool is not installed") }
        let source = try await fixture("movie.mp4", video: true)
        let original = try Data(contentsOf: source)
        var options = EditOptions(); options.metadata = ["Title": "Literal $ metadata"]
        let edited = try await apply(source, .tool(.metadata), options)[0]
        let title = try await context.runner.run(try XCTUnwrap(ProcessRunner.locate("exiftool")), arguments: ["-s3", "-Title", edited.path])
        XCTAssertEqual(title.trimmingCharacters(in: .whitespacesAndNewlines), "Literal $ metadata")
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testCompressionNeverPublishesAnOutputLargerThanTheSource() async throws {
        let fixture = try await fixture("movie.mp4", video: true)
        let source = directory.appendingPathComponent("already-compressed.mp4")
        _ = try await context.runner.run(try XCTUnwrap(ProcessRunner.locate("ffmpeg")), arguments: ["-v", "error", "-y", "-i", fixture.path, "-c:v", "libx264", "-crf", "50", "-c:a", "aac", "-b:a", "16k", source.path])
        let originalSize = try Data(contentsOf: source).count
        do {
            let compressed = try await apply(source, .tool(.compress))[0]
            XCTAssertLessThan(try Data(contentsOf: compressed).count, originalSize)
        } catch {
            XCTAssertTrue(error is TurnstoneError)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 2)
        }
        XCTAssertEqual(try Data(contentsOf: source).count, originalSize)
    }

    func testMalformedMediaFailsWithoutPublishingAndNonMediaReturnsNil() async throws {
        let bad = directory.appendingPathComponent("bad.mp4")
        try Data("invalid media".utf8).write(to: bad)
        do { _ = try await apply(bad, .convert("mp3")); XCTFail("Malformed media succeeded") } catch {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["bad.mp4"])
        let result = try await engine.perform(JobRequest(files: [bad], operation: .tool(.splitPDF)), context: context)
        XCTAssertNil(result)
    }
}
