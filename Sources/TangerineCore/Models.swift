import Foundation

public enum ToolID: String, CaseIterable, Codable, Identifiable, Sendable {
    case compress, metadata, editImage, annotateImage, background, cropImage
    case normalizeAudio, muteVideo, trimVideo, splitPDF, organizePDF, extractArchive
    case createPDF, mergePDF, cropVideo, videoSpeed, joinVideos, videoSnapshots
    case splitVideo, audioVisualizer, trimAudio, audioChannels, collage
    case redactImage, redactVideo, bleepAudio
    public var id: String { rawValue }
}

public enum FileAction: String, CaseIterable, Identifiable, Sendable {
    case airDrop, float, copy, move, copyPath, terminal
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .airDrop: return "AirDrop"
        case .float: return "Float"
        case .copy: return "Copy"
        case .move: return "Move"
        case .copyPath: return "Copy Path"
        case .terminal: return "Terminal"
        }
    }
    public var symbol: String {
        switch self {
        case .airDrop: return "airplayaudio"
        case .float: return "pin.fill"
        case .copy: return "doc.on.doc"
        case .move: return "folder"
        case .copyPath: return "doc.text"
        case .terminal: return "terminal"
        }
    }
}

public enum FileOperation: Equatable, Sendable {
    case convert(String)
    case tool(ToolID)
}

public struct UnitRect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double = 0, y: Double = 0, width: Double = 1, height: Double = 1) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

public struct ColorValue: Codable, Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double
    public init(_ red: Double = 0, _ green: Double = 0, _ blue: Double = 0, _ alpha: Double = 1) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }
}

public struct TimeRange: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var start: Double
    public var end: Double
    public init(start: Double, end: Double) { self.start = start; self.end = end }
}

public struct Redaction: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var rect: UnitRect
    public var start: Double
    public var end: Double?
    public init(rect: UnitRect, start: Double = 0, end: Double? = nil) {
        self.rect = rect; self.start = start; self.end = end
    }
}

public struct CanvasPoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public struct Annotation: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var kind: String
    public var rect: UnitRect
    public var text: String
    public var color: ColorValue
    public var points: [CanvasPoint] = []
    public var imageURL: URL?
    public var number = 1
    public init(kind: String, rect: UnitRect, text: String = "", color: ColorValue = ColorValue(1, 0.25, 0.1)) {
        self.kind = kind; self.rect = rect; self.text = text; self.color = color
    }
}

public struct PDFPageEdit: Equatable, Sendable, Identifiable {
    public var id = UUID()
    public var index: Int
    public var rotation: Int
    public init(index: Int, rotation: Int = 0) { self.index = index; self.rotation = rotation }
}

public struct PhotoAdjustments: Equatable, Sendable {
    public var exposure = 0.0
    public var brightness = 0.0
    public var contrast = 1.0
    public var highlights = 1.0
    public var shadows = 0.0
    public var whites = 0.0
    public var blacks = 0.0
    public var gamma = 1.0
    public var temperature = 6500.0
    public var tint = 0.0
    public var saturation = 1.0
    public var vibrance = 0.0
    public var hue = 0.0
    public var sharpness = 0.0
    public var clarity = 0.0
    public var dehaze = 0.0
    public var noiseReduction = 0.0
    public var grain = 0.0
    public var vignette = 0.0
    public init() {}
}

public struct EditOptions: Sendable {
    public var quality = 0.78
    public var targetBytes: Int?
    public var reduction = 0.0
    public var maxDimension: Int?
    public var width: Int?
    public var height: Int?
    public var crop = UnitRect()
    public var photo = PhotoAdjustments()
    public var start = 0.0
    public var end: Double?
    public var speed = 1.0
    public var trimSilence = false
    public var mono = false
    public var leftVolume = 1.0
    public var rightVolume = 1.0
    public var loudness = -16.0
    public var loudnessRange = 11.0
    public var truePeak = -1.5
    public var ranges: [TimeRange] = []
    public var splitPoints: [Double] = []
    public var equalParts = 2
    public var snapshotTimes: [Double] = [0]
    public var redactions: [Redaction] = []
    public var blur = false
    public var color = ColorValue()
    public var annotations: [Annotation] = []
    public var background = ColorValue(0.96, 0.64, 0.36)
    public var backgroundStyle = "solid"
    public var backgroundImage: URL?
    public var padding = 80.0
    public var cornerRadius = 24.0
    public var shadowRadius = 16.0
    public var aspectRatio: Double?
    public var collageStyle = "grid"
    public var columns = 2
    public var canvasWidth = 2048
    public var imageFit = "fill"
    public var pdfPages: [PDFPageEdit] = []
    public var matchPageWidth = false
    public var metadata: [String: String] = [:]
    public var removeAllMetadata = false
    public var visualizerStyle = "waveform"
    public var videoWidth = 1280
    public var videoHeight = 720
    public var epubLayout = "reflow"
    public init() {}
}

public struct JobRequest: Sendable {
    public var files: [URL]
    public var operation: FileOperation
    public var options: EditOptions
    public init(files: [URL], operation: FileOperation, options: EditOptions = EditOptions()) {
        self.files = files; self.operation = operation; self.options = options
    }
}

public enum TangerineError: LocalizedError {
    case invalid(String), missingDependency(String), failed(String), unsupported(String)
    public var errorDescription: String? {
        switch self {
        case .invalid(let message), .failed(let message), .unsupported(let message): return message
        case .missingDependency(let name): return "Install \(name) to use this operation. Open Settings for setup instructions."
        }
    }
}
