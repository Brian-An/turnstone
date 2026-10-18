import Foundation

public struct MediaInfo: Sendable {
    public let duration: Double
    public let width: Int
    public let height: Int
    public let audioChannels: Int
}

public struct MediaEngine: Sendable {
    private static let audio = Set(["mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff", "wma"])
    private static let video = Set(["mp4", "mov", "mkv", "webm", "avi", "wmv", "gif"])
    private static let tools: Set<ToolID> = [.compress, .metadata, .normalizeAudio, .muteVideo, .trimVideo, .cropVideo, .videoSpeed, .joinVideos, .videoSnapshots, .splitVideo, .audioVisualizer, .trimAudio, .audioChannels, .redactVideo, .bleepAudio]
    public init() {}

    public func info(for url: URL, context: ExecutionContext) async throws -> MediaInfo {
        struct Probe: Decodable {
            struct Stream: Decodable {
                struct SideData: Decodable { let rotation: Double? }
                struct Tags: Decodable { let rotate: String? }
                let codec_type: String?
                let width: Int?
                let height: Int?
                let channels: Int?
                let duration: String?
                let side_data_list: [SideData]?
                let tags: Tags?
            }
            struct Format: Decodable { let duration: String? }
            let streams: [Stream]
            let format: Format?
        }
        let raw = try await execute("ffprobe", ["-v", "error", "-show_streams", "-show_format", "-of", "json", url.path], context)
        let probe = try JSONDecoder().decode(Probe.self, from: Data(raw.utf8))
        guard !probe.streams.isEmpty else { throw TangerineError.invalid("The file contains no readable media streams.") }
        let video = probe.streams.first { $0.codec_type == "video" }
        let audio = probe.streams.first { $0.codec_type == "audio" }
        let duration = Double(probe.format?.duration ?? "") ?? probe.streams.compactMap { Double($0.duration ?? "") }.max() ?? 0
        let rotation = video?.side_data_list?.compactMap(\.rotation).first ?? Double(video?.tags?.rotate ?? "") ?? 0
        // FFmpeg autorotates decoded frames before spatial filters.
        let swapsAxes = rotation.isFinite && abs(abs(rotation).truncatingRemainder(dividingBy: 180) - 90) < 0.5
        let width = video?.width ?? 0
        let height = video?.height ?? 0
        return MediaInfo(duration: duration, width: swapsAxes ? height : width, height: swapsAxes ? width : height, audioChannels: audio?.channels ?? 0)
    }

    public func perform(_ request: JobRequest, context: ExecutionContext) async throws -> [URL]? {
        switch request.operation {
        case .convert(let format):
            guard Self.audio.contains(format.lowercased()) || Self.video.contains(format.lowercased()), request.files.allSatisfy({ isMedia($0) }) else { return nil }
        case .tool(let tool):
            guard Self.tools.contains(tool), request.files.allSatisfy({ isMedia($0) }) else { return nil }
        }
        guard !request.files.isEmpty else { throw TangerineError.invalid("Choose at least one media file.") }
        if request.operation == .tool(.joinVideos) { return [try await join(request, context)] }
        var outputs: [URL] = []
        for source in request.files {
            try context.checkCancellation()
            context.report("Processing \(source.lastPathComponent)")
            let media = try await info(for: source, context: context)
            switch request.operation {
            case .convert(let format):
                outputs.append(try await transcode(source, format.lowercased(), context: context))
            case .tool(.metadata):
                outputs.append(try await metadata(source, request.options, context))
            case .tool(.compress):
                outputs.append(try await compress(source, media, request.options, context))
            case .tool(.videoSnapshots):
                guard media.width > 0 else { throw TangerineError.invalid("Snapshots require video.") }
                for (index, time) in request.options.snapshotTimes.enumerated() {
                    guard time.isFinite, time >= 0, time < media.duration else { throw TangerineError.invalid("Snapshot times must fall inside the video.") }
                    outputs.append(try await transcode(source, "png", extra: ["-ss", number(time), "-frames:v", "1", "-an"], suffix: "frame-\(index + 1)", context: context))
                }
            case .tool(.splitVideo):
                guard media.width > 0, media.duration > 0 else { throw TangerineError.invalid("Splitting requires a video with a duration.") }
                let options = request.options
                guard options.equalParts > 0, options.equalParts <= 1000 else { throw TangerineError.invalid("Choose between 1 and 1000 parts.") }
                let points = options.splitPoints.isEmpty ? (1..<options.equalParts).map { media.duration * Double($0) / Double(options.equalParts) } : options.splitPoints
                guard points.allSatisfy({ $0.isFinite && $0 > 0 && $0 < media.duration }), points == points.sorted(), Set(points).count == points.count else { throw TangerineError.invalid("Split points must be distinct increasing times inside the video.") }
                let boundaries = [0] + points + [media.duration]
                for index in 0..<(boundaries.count - 1) {
                    outputs.append(try await transcode(source, "mp4", extra: ["-ss", number(boundaries[index]), "-t", number(boundaries[index + 1] - boundaries[index])], suffix: "part-\(index + 1)", context: context))
                }
            case .tool(let tool):
                outputs.append(try await edit(source, media, tool, request.options, context))
            }
        }
        return outputs
    }

    private func isMedia(_ url: URL) -> Bool { Self.audio.contains(url.pathExtension.lowercased()) || Self.video.contains(url.pathExtension.lowercased()) }
    private func number(_ value: Double) -> String { String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value) }
    private func execute(_ name: String, _ args: [String], _ context: ExecutionContext) async throws -> String {
        try context.checkCancellation()
        guard let executable = ProcessRunner.locate(name) else { throw TangerineError.missingDependency(name) }
        return try await context.runner.run(executable, arguments: args)
    }
    private func encodeOptions(_ format: String) -> [String] {
        switch format {
        case "mp3": return ["-vn", "-c:a", "libmp3lame", "-b:a", "192k"]
        case "m4a": return ["-vn", "-c:a", "aac", "-b:a", "192k"]
        case "wav": return ["-vn", "-c:a", "pcm_s16le"]
        case "flac": return ["-vn", "-c:a", "flac"]
        case "ogg": return ["-vn", "-c:a", "libopus", "-b:a", "160k"]
        case "opus": return ["-vn", "-c:a", "libopus", "-b:a", "128k"]
        case "aiff": return ["-vn", "-c:a", "pcm_s16be"]
        case "wma": return ["-vn", "-c:a", "wmav2", "-b:a", "192k"]
        case "webm": return ["-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-c:a", "libopus"]
        case "wmv": return ["-c:v", "wmv2", "-c:a", "wmav2"]
        case "avi": return ["-c:v", "mpeg4", "-q:v", "4", "-c:a", "libmp3lame"]
        case "gif", "png": return []
        default: return ["-c:v", "libx264", "-preset", "medium", "-crf", "23", "-pix_fmt", "yuv420p", "-c:a", "aac", "-movflags", "+faststart"]
        }
    }
    private func transcode(_ source: URL, _ format: String, extra: [String] = [], suffix: String? = nil, context: ExecutionContext) async throws -> URL {
        let output = context.temporaryURL(extension: format)
        var args = ["-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-i", source.path]
        var encoding = encodeOptions(format)
        if format == "mkv" { encoding = ["-c:v", "libx264", "-crf", "23", "-pix_fmt", "yuv420p", "-c:a", "aac"] }
        if format == "gif" { encoding = ["-filter_complex", "[0:v]split[a][b];[a]palettegen[p];[b][p]paletteuse", "-an"] }
        args += encoding + extra + [output.path]
        _ = try await execute("ffmpeg", args, context)
        guard (try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.intValue ?? 0 > 0 else { throw TangerineError.failed("The media encoder produced an empty file.") }
        return try context.publish(output, beside: source, extension: format, suffix: suffix)
    }

    private func edit(_ source: URL, _ media: MediaInfo, _ tool: ToolID, _ options: EditOptions, _ context: ExecutionContext) async throws -> URL {
        let audioOnly = media.width == 0
        var format = audioOnly ? source.pathExtension.lowercased() : "mp4"
        var extra: [String] = []
        switch tool {
        case .muteVideo:
            guard !audioOnly else { throw TangerineError.invalid("Muting requires video.") }
            extra = ["-an"]
        case .trimVideo, .trimAudio:
            let end = options.end ?? media.duration
            guard options.start.isFinite, end.isFinite, options.start >= 0, end > options.start, end <= media.duration + 0.05 else { throw TangerineError.invalid("The trim range must fall inside the media.") }
            extra = ["-ss", number(options.start), "-t", number(end - options.start)]
            if tool == .trimAudio {
                format = audioOnly ? format : "m4a"
                if options.trimSilence {
                    // Reverse only to remove trailing silence without deleting pauses inside the recording.
                    extra += ["-af", "silenceremove=start_periods=1:start_duration=0.02:start_threshold=-50dB,areverse,silenceremove=start_periods=1:start_duration=0.02:start_threshold=-50dB,areverse"]
                }
            }
        case .normalizeAudio:
            guard media.audioChannels > 0, options.loudness.isFinite, (-70 ... -5).contains(options.loudness), options.loudnessRange.isFinite, (1 ... 50).contains(options.loudnessRange), options.truePeak.isFinite, (-9 ... 0).contains(options.truePeak) else { throw TangerineError.invalid("Choose loudness from -70 to -5 LUFS, range from 1 to 50 LU, and true peak from -9 to 0 dBTP.") }
            extra = ["-af", "loudnorm=I=\(number(options.loudness)):LRA=\(number(options.loudnessRange)):TP=\(number(options.truePeak))"]
        case .cropVideo:
            let rect = try pixelRect(options.crop, media)
            extra = ["-vf", "crop=\(rect.w):\(rect.h):\(rect.x):\(rect.y)"]
        case .videoSpeed:
            guard media.width > 0, options.speed.isFinite, (0.0625 ... 16).contains(options.speed) else { throw TangerineError.invalid("Choose a playback speed between 0.0625 and 16.") }
            extra = ["-vf", "setpts=(PTS-STARTPTS)/\(number(options.speed))"]
            if media.audioChannels > 0 {
                var remaining = options.speed
                var filters: [String] = []
                while remaining > 2 { filters.append("atempo=2"); remaining /= 2 }
                while remaining < 0.5 { filters.append("atempo=0.5"); remaining /= 0.5 }
                filters.append("atempo=\(number(remaining))")
                extra += ["-af", filters.joined(separator: ",")]
            }
        case .audioChannels:
            guard media.audioChannels > 0, options.leftVolume.isFinite, options.rightVolume.isFinite, (0 ... 10).contains(options.leftVolume), (0 ... 10).contains(options.rightVolume) else { throw TangerineError.invalid("Channel gains must be between 0 and 10.") }
            format = audioOnly ? format : "m4a"
            extra = ["-af", "aformat=channel_layouts=stereo,pan=stereo|c0=\(number(options.leftVolume))*c0|c1=\(number(options.rightVolume))*c1", "-ac", options.mono ? "1" : "2"]
        case .redactVideo:
            guard media.width > 0, !options.redactions.isEmpty else { throw TangerineError.invalid("Add a video redaction first.") }
            if options.blur {
                var filters: [String] = []; var previous = "0:v"
                for (index, redaction) in options.redactions.enumerated() {
                    let rect = try pixelRect(redaction.rect, media)
                    let enable = try timeExpression(redaction.start, redaction.end ?? media.duration, media.duration)
                    filters.append("[\(previous)]split[base\(index)][part\(index)];[part\(index)]crop=\(rect.w):\(rect.h):\(rect.x):\(rect.y),boxblur=\(max(1, min(rect.w, rect.h) / 10)):1[blur\(index)];[base\(index)][blur\(index)]overlay=\(rect.x):\(rect.y):enable='\(enable)'[out\(index)]")
                    previous = "out\(index)"
                }
                extra = ["-filter_complex", filters.joined(separator: ";"), "-map", "[\(previous)]", "-map", "0:a?"]
            } else {
                let channels = [options.color.red, options.color.green, options.color.blue, options.color.alpha]
                guard channels.allSatisfy({ $0.isFinite && (0 ... 1).contains($0) }) else { throw TangerineError.invalid("Choose a valid redaction color.") }
                let color = String(format: "0x%02x%02x%02x@%.3f", locale: Locale(identifier: "en_US_POSIX"), Int(options.color.red * 255), Int(options.color.green * 255), Int(options.color.blue * 255), options.color.alpha)
                let filters = try options.redactions.map { redaction -> String in
                    let rect = try pixelRect(redaction.rect, media)
                    let enable = try timeExpression(redaction.start, redaction.end ?? media.duration, media.duration)
                    return "drawbox=x=\(rect.x):y=\(rect.y):w=\(rect.w):h=\(rect.h):color=\(color):t=fill:enable='\(enable)'"
                }
                extra = ["-vf", filters.joined(separator: ",")]
            }
        case .bleepAudio:
            guard media.audioChannels > 0, !options.ranges.isEmpty else { throw TangerineError.invalid("Add an audio range first.") }
            let enabled = try options.ranges.map { try timeExpression($0.start, $0.end, media.duration) }.joined(separator: "+")
            let graph = "[0:a]volume=0:enable='\(enabled)'[muted];sine=frequency=1000:sample_rate=48000:duration=\(number(media.duration)),volume=0.2:enable='\(enabled)',volume=0:enable='not(\(enabled))'[tone];[muted][tone]amix=inputs=2:normalize=0[a]"
            extra = ["-filter_complex", graph, "-map", "0:v?", "-map", "[a]"]
        case .audioVisualizer:
            return try await visualize(source, media, options, context)
        default: throw TangerineError.unsupported("This media tool is not supported.")
        }
        return try await transcode(source, format, extra: extra, suffix: tool.rawValue, context: context)
    }

    private func pixelRect(_ rect: UnitRect, _ media: MediaInfo) throws -> (x: Int, y: Int, w: Int, h: Int) {
        guard media.width > 0, [rect.x, rect.y, rect.width, rect.height].allSatisfy({ $0.isFinite }), rect.x >= 0, rect.y >= 0, rect.width > 0, rect.height > 0, rect.x + rect.width <= 1.000001, rect.y + rect.height <= 1.000001 else { throw TangerineError.invalid("The rectangle must fall inside the video.") }
        let result = (x: Int(rect.x * Double(media.width)) / 2 * 2, y: Int(rect.y * Double(media.height)) / 2 * 2, w: Int(rect.width * Double(media.width)) / 2 * 2, h: Int(rect.height * Double(media.height)) / 2 * 2)
        guard result.w >= 2, result.h >= 2 else { throw TangerineError.invalid("The rectangle must be at least two pixels wide and tall.") }
        return result
    }
    private func timeExpression(_ start: Double, _ end: Double, _ duration: Double) throws -> String {
        guard start.isFinite, end.isFinite, start >= 0, end > start, end <= duration + 0.05 else { throw TangerineError.invalid("Time ranges must fall inside the media.") }
        return "between(t,\(number(start)),\(number(end)))"
    }

    private func visualize(_ source: URL, _ media: MediaInfo, _ options: EditOptions, _ context: ExecutionContext) async throws -> URL {
        guard media.audioChannels > 0, options.videoWidth >= 2, options.videoWidth <= 7680, options.videoHeight >= 2, options.videoHeight <= 7680 else { throw TangerineError.invalid("Visualization requires audio and dimensions from 2 to 7680.") }
        let width = options.videoWidth / 2 * 2
        if let aspect = options.aspectRatio, !aspect.isFinite || !(0.1 ... 10).contains(aspect) { throw TangerineError.invalid("Choose an aspect ratio between 0.1 and 10.") }
        let height = options.aspectRatio.map { Int(Double(width) / $0) / 2 * 2 } ?? options.videoHeight / 2 * 2
        guard height >= 2, height <= 7680 else { throw TangerineError.invalid("Choose a valid aspect ratio.") }
        let output = context.temporaryURL(extension: "mp4")
        var args = ["-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i", source.path]
        if options.visualizerStyle == "image" {
            guard let image = options.backgroundImage else { throw TangerineError.invalid("Choose a still image for the visualization.") }
            args += ["-loop", "1", "-i", image.path, "-map", "1:v", "-map", "0:a", "-vf", "scale=\(width):\(height):force_original_aspect_ratio=decrease,pad=\(width):\(height):(ow-iw)/2:(oh-ih)/2", "-t", number(media.duration)]
        } else {
            args += ["-filter_complex", "[0:a]showwaves=s=\(width)x\(height):mode=line:rate=25:colors=0xff8833,format=yuv420p[v]", "-map", "[v]", "-map", "0:a"]
        }
        args += encodeOptions("mp4") + ["-shortest", output.path]
        _ = try await execute("ffmpeg", args, context)
        return try context.publish(output, beside: source, extension: "mp4", suffix: "visualizer")
    }

    private func compress(_ source: URL, _ media: MediaInfo, _ options: EditOptions, _ context: ExecutionContext) async throws -> URL {
        guard media.duration > 0, options.quality.isFinite, (0 ... 1).contains(options.quality), options.reduction.isFinite, (0 ... 100).contains(options.reduction) else { throw TangerineError.invalid("Choose a valid compression quality and reduction percentage.") }
        let sourceSize = (try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.intValue ?? 0
        let requestedTarget = options.targetBytes ?? (options.reduction > 0 ? Int(Double(sourceSize) * (1 - options.reduction / 100)) : nil)
        let target = min(requestedTarget ?? (sourceSize - 1), sourceSize - 1)
        guard target >= 1024 else { throw TangerineError.invalid("The target file size must be at least 1 KB and smaller than the source.") }
        let format = media.width > 0 ? "mp4" : "mp3"
        let output = context.temporaryURL(extension: format)
        var bitrate = requestedTarget.map { Double(min($0, target)) * 8 / media.duration * 0.88 }
        for _ in 0..<5 {
            var args = ["-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i", source.path]
            if media.width > 0 {
                args += ["-c:v", "libx264", "-preset", "medium", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "32k"]
                if let bitrate {
                    guard bitrate > (media.audioChannels > 0 ? 40_000 : 8_000) else { throw TangerineError.invalid("The target size is too small for this video's duration.") }
                    args += ["-b:v", String(Int(bitrate) - (media.audioChannels > 0 ? 32_000 : 0))]
                } else { args += ["-crf", String(Int(18 + (1 - options.quality) * 26))] }
            } else {
                args += ["-vn", "-c:a", "libmp3lame", "-b:a", String(Int(max(8_000, min(320_000, bitrate ?? (32_000 + options.quality * 160_000)))))]
            }
            _ = try await execute("ffmpeg", args + [output.path], context)
            let actual = (try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.intValue ?? 0
            guard actual > 0 else { throw TangerineError.failed("Compression produced an empty file.") }
            if actual <= target { return try context.publish(output, beside: source, extension: format, suffix: "compressed") }
            bitrate = (bitrate ?? (Double(target) * 8 / media.duration * 0.88)) * Double(target) / Double(actual) * 0.85
        }
        throw TangerineError.failed("The requested file size could not be reached. Choose a larger target.")
    }

    private func metadata(_ source: URL, _ options: EditOptions, _ context: ExecutionContext) async throws -> URL {
        let staged = context.temporaryURL(extension: source.pathExtension)
        try FileManager.default.copyItem(at: source, to: staged)
        var args = ["-overwrite_original"]
        if options.removeAllMetadata { args += ["-all="] }
        for (key, value) in options.metadata.sorted(by: { $0.key < $1.key }) {
            guard key.range(of: "^[A-Za-z][A-Za-z0-9:_-]*$", options: .regularExpression) != nil else { throw TangerineError.invalid("Invalid metadata field: \(key)") }
            args.append("-\(key)=\(value)")
        }
        guard args.count > 1 else { throw TangerineError.invalid("Choose metadata fields to edit or remove.") }
        _ = try await execute("exiftool", args + [staged.path], context)
        return try context.publish(staged, beside: source, extension: source.pathExtension, suffix: "metadata")
    }

    private func join(_ request: JobRequest, _ context: ExecutionContext) async throws -> URL {
        guard request.files.count > 1, let first = request.files.first else { throw TangerineError.invalid("Choose at least two videos to join.") }
        let canvas = try await info(for: first, context: context)
        guard canvas.width > 0, canvas.height > 0 else { throw TangerineError.invalid("Joining requires video files.") }
        let width = canvas.width / 2 * 2; let height = canvas.height / 2 * 2
        var intermediates: [URL] = []
        for source in request.files {
            let media = try await info(for: source, context: context)
            guard media.width > 0, media.duration > 0 else { throw TangerineError.invalid("Every joined file must contain video.") }
            let staged = context.temporaryURL(extension: "mp4")
            var args = ["-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i", source.path]
            if media.audioChannels == 0 { args += ["-f", "lavfi", "-i", "anullsrc=channel_layout=stereo:sample_rate=48000"] }
            args += ["-map", "0:v:0", "-map", media.audioChannels == 0 ? "1:a:0" : "0:a:0", "-vf", "scale=\(width):\(height):force_original_aspect_ratio=decrease,pad=\(width):\(height):(ow-iw)/2:(oh-ih)/2,setsar=1,fps=30", "-af", "aresample=48000,apad", "-ac", "2", "-t", number(media.duration)]
            args += encodeOptions("mp4") + [staged.path]
            _ = try await execute("ffmpeg", args, context)
            intermediates.append(staged)
        }
        let list = context.temporaryURL(extension: "txt")
        let listing = intermediates.map { "file '\($0.path.replacingOccurrences(of: "'", with: "'\\''"))'" }.joined(separator: "\n")
        try listing.write(to: list, atomically: true, encoding: .utf8)
        let output = context.temporaryURL(extension: "mp4")
        _ = try await execute("ffmpeg", ["-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-f", "concat", "-safe", "0", "-i", list.path, "-c", "copy", "-movflags", "+faststart", output.path], context)
        return try context.publish(output, beside: first, extension: "mp4", suffix: "joined")
    }
}
