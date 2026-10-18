import Foundation

public enum Catalog {
    public static let conversions: [String: [String]] = {
        var routes: [String: [String]] = [:]
        func add(_ inputs: [String], _ outputs: [String]) {
            for input in inputs { routes[input] = outputs.filter { $0 != input } }
        }
        add(["jpg", "png", "webp", "heic", "tiff", "svg", "avif", "bmp"], ["jpg", "png", "webp", "heic", "tiff", "avif", "bmp", "pdf"])
        add(["mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff", "wma"], ["mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff", "wma"])
        let videos = ["mp4", "mov", "mkv", "webm", "avi", "wmv"]
        add(videos, videos + ["gif", "mp3"])
        add(["gif"], videos)
        add(["pdf"], ["docx", "pages", "pptx", "xlsx", "jpg", "png", "epub", "txt", "md"])
        add(["ppt", "pptx"], ["pdf", "jpg", "png"])
        add(["xlsx", "xls", "ods", "csv", "tsv"], ["xlsx", "ods", "csv", "tsv", "pdf"])
        add(["docx", "pages", "md", "rtf", "rtfd", "textClipping"], ["docx", "pages", "pdf", "txt", "md", "html", "epub", "png", "jpg"])
        add(["epub"], ["pdf", "docx", "pages", "txt", "md", "html"])
        add(["txt"], ["docx", "pages", "pdf", "md", "html", "epub", "jpg", "png"])
        add(["srt"], ["vtt", "txt"])
        add(["vtt"], ["srt", "txt"])
        add(["zip", "tar", "gz", "rar"], ["zip", "tar", "gz"])
        return routes
    }()

    public static func outputs(for urls: [URL]) -> [String] {
        guard let first = urls.first, !isFolder(first), let outputs = conversions[fileExtension(first)] else { return [] }
        return urls.dropFirst().reduce(outputs) { common, url in
            guard !isFolder(url), let options = conversions[fileExtension(url)] else { return [] }
            return common.filter { options.contains($0) }
        }
    }

    public static func tools(for urls: [URL]) -> [ToolID] {
        guard let first = urls.first, !isFolder(first) else { return [] }
        let batch = urls.count > 1
        let family = toolFamily(fileExtension(first))
        guard urls.allSatisfy({ toolFamily(fileExtension($0)) == family }) else { return [] }
        return urls.dropFirst().reduce(toolList(fileExtension(first), batch: batch)) { common, url in
            guard !isFolder(url) else { return [] }
            let available = toolList(fileExtension(url), batch: batch)
            return common.filter { available.contains($0) }
        }
    }

    public static func fileExtension(_ url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        return ["jpeg": "jpg", "tif": "tiff", "markdown": "md", "tgz": "gz", "textclipping": "textClipping"][ext] ?? ext
    }

    private static func isFolder(_ url: URL) -> Bool {
        fileExtension(url) != "rtfd" && (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private static func toolFamily(_ ext: String) -> String {
        if ["jpg", "png", "webp", "heic", "tiff", "svg"].contains(ext) { return "image" }
        if ["mp3", "m4a", "wav", "flac"].contains(ext) { return "audio" }
        if ["mp4", "mov", "mkv"].contains(ext) { return "video" }
        if ["zip", "tar", "gz", "rar"].contains(ext) { return "archive" }
        return ext
    }

    private static func toolList(_ ext: String, batch: Bool) -> [ToolID] {
        switch ext {
        case "jpg", "png", "webp", "heic", "tiff":
            return batch ? [.compress, .metadata, .cropImage, .createPDF, .collage] : [.compress, .metadata, .editImage, .annotateImage, .background, .cropImage, .redactImage]
        case "svg": return batch ? [.createPDF, .collage] : []
        case "mp3", "m4a", "wav", "flac":
            return batch ? [.compress, .metadata, .normalizeAudio] : [.compress, .metadata, .normalizeAudio, .audioVisualizer, .trimAudio, .audioChannels, .bleepAudio]
        case "mp4", "mov", "mkv":
            return batch ? [.compress, .metadata, .muteVideo, .joinVideos] : [.compress, .metadata, .muteVideo, .trimVideo, .cropVideo, .videoSpeed, .videoSnapshots, .splitVideo, .redactVideo]
        case "pdf": return batch ? [.compress, .metadata, .splitPDF, .mergePDF] : [.compress, .metadata, .splitPDF, .organizePDF]
        case "zip", "tar", "gz", "rar": return [.extractArchive]
        case "gif": return [.metadata]
        default: return []
        }
    }
}

extension ToolID {
    public var title: String {
        switch self {
        case .compress: return "Compress"
        case .metadata: return "Metadata"
        case .editImage: return "Edit Image"
        case .annotateImage: return "Annotate"
        case .background: return "Background"
        case .cropImage: return "Crop Image"
        case .normalizeAudio: return "Normalize Audio"
        case .muteVideo: return "Mute Video"
        case .trimVideo: return "Trim Video"
        case .splitPDF: return "Split PDF"
        case .organizePDF: return "Organize PDF"
        case .extractArchive: return "Extract Archive"
        case .createPDF: return "Create PDF"
        case .mergePDF: return "Merge PDFs"
        case .cropVideo: return "Crop Video"
        case .videoSpeed: return "Video Speed"
        case .joinVideos: return "Join Videos"
        case .videoSnapshots: return "Video Snapshots"
        case .splitVideo: return "Split Video"
        case .audioVisualizer: return "Audio Visualizer"
        case .trimAudio: return "Trim Audio"
        case .audioChannels: return "Audio Channels"
        case .collage: return "Collage"
        case .redactImage: return "Redact Image"
        case .redactVideo: return "Redact Video"
        case .bleepAudio: return "Bleep Audio"
        }
    }
    public var symbol: String {
        switch self {
        case .compress: return "arrow.down.right.and.arrow.up.left"
        case .metadata: return "info.circle"
        case .editImage: return "slider.horizontal.3"
        case .annotateImage: return "pencil.tip"
        case .background: return "rectangle.on.rectangle"
        case .cropImage, .cropVideo: return "crop"
        case .normalizeAudio: return "waveform.path"
        case .muteVideo: return "speaker.slash"
        case .trimVideo, .trimAudio: return "scissors"
        case .splitPDF, .splitVideo: return "square.split.2x1"
        case .organizePDF: return "square.grid.2x2"
        case .extractArchive: return "archivebox"
        case .createPDF: return "doc.badge.plus"
        case .mergePDF, .joinVideos: return "rectangle.stack.badge.plus"
        case .videoSpeed: return "speedometer"
        case .videoSnapshots: return "camera"
        case .audioVisualizer: return "waveform"
        case .audioChannels: return "hifispeaker.2"
        case .collage: return "square.grid.3x3"
        case .redactImage, .redactVideo: return "eye.slash"
        case .bleepAudio: return "speaker.badge.exclamationmark"
        }
    }
}
