import Foundation

public struct ConversionEngine {
    public init() {}

    public func run(_ request: JobRequest, context: ExecutionContext) async throws -> [URL] {
        try context.checkCancellation()
        guard !request.files.isEmpty else { throw TurnstoneError.invalid("Choose at least one file.") }
        for file in request.files {
            guard file.isFileURL, FileManager.default.fileExists(atPath: file.path) else { throw TurnstoneError.invalid("The source file is unavailable: \(file.lastPathComponent).") }
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            let package = Catalog.fileExtension(file) == "rtfd" && values.isDirectory == true
            guard values.isRegularFile == true || package else { throw TurnstoneError.invalid("Choose files rather than folders for conversion or editing.") }
        }
        try validate(request.options)
        switch request.operation {
        case .convert(let target):
            guard request.files.allSatisfy({ Catalog.conversions[Catalog.fileExtension($0)]?.contains(target) == true }) else {
                throw TurnstoneError.unsupported("This format conversion is not supported for every selected file.")
            }
            context.report("Converting to \(target.uppercased())")
        case .tool(let tool):
            if [.createPDF, .mergePDF, .joinVideos, .collage].contains(tool), request.files.count < 2 { throw TurnstoneError.invalid("Choose at least two files for \(tool.title).") }
            guard Catalog.tools(for: request.files).contains(tool) else { throw TurnstoneError.unsupported("\(tool.title) is not available for every selected file.") }
            context.report(tool.title)
        }
        let combined: Bool
        if case .tool(let tool) = request.operation { combined = [.createPDF, .mergePDF, .joinVideos, .collage].contains(tool) }
        else { combined = false }
        if combined { return try await dispatch(request, context: context) }
        var outputs: [URL] = []
        for source in request.files {
            try context.checkCancellation()
            let single = JobRequest(files: [source], operation: request.operation, options: request.options)
            outputs += try await dispatch(single, context: context)
        }
        return outputs
    }

    private func dispatch(_ request: JobRequest, context: ExecutionContext) async throws -> [URL] {
        if let outputs = try await NativeEngine().perform(request, context: context) { return outputs }
        if let outputs = try await MediaEngine().perform(request, context: context) { return outputs }
        if let outputs = try await DocumentEngine().perform(request, context: context) { return outputs }
        throw TurnstoneError.unsupported("No local conversion engine supports this operation.")
    }

    private func validate(_ options: EditOptions) throws {
        let photo = options.photo
        let scalars = [options.quality, options.reduction, options.start, options.speed, options.leftVolume, options.rightVolume,
                       options.loudness, options.loudnessRange, options.truePeak, options.padding, options.cornerRadius, options.shadowRadius,
                       photo.exposure, photo.brightness, photo.contrast, photo.highlights, photo.shadows, photo.whites, photo.blacks,
                       photo.gamma, photo.temperature, photo.tint, photo.saturation, photo.vibrance, photo.hue, photo.sharpness,
                       photo.clarity, photo.dehaze, photo.noiseReduction, photo.grain, photo.vignette]
        guard scalars.allSatisfy(\.isFinite), options.end?.isFinite != false, options.aspectRatio?.isFinite != false else { throw TurnstoneError.invalid("All editing values must be finite numbers.") }
        guard (0...1).contains(options.quality), (0...100).contains(options.reduction), options.targetBytes.map({ $0 > 0 }) != false else { throw TurnstoneError.invalid("Choose a valid compression quality, reduction, and positive file size.") }
        let dimensions = [options.width, options.height, options.maxDimension, options.canvasWidth, options.videoWidth, options.videoHeight].compactMap { $0 }
        guard dimensions.allSatisfy({ (1...16_384).contains($0) }), (1...1000).contains(options.columns), (1...1000).contains(options.equalParts) else { throw TurnstoneError.invalid("Choose dimensions between 1 and 16384 pixels and a valid number of columns or parts.") }
        guard (0.25...4).contains(options.speed), (0...10).contains(options.leftVolume), (0...10).contains(options.rightVolume),
              options.start >= 0, options.end.map({ $0 > options.start }) != false,
              (-70 ... -5).contains(options.loudness), (1...50).contains(options.loudnessRange), (-9...0).contains(options.truePeak) else { throw TurnstoneError.invalid("Choose valid playback, timing, channel gain, and loudness values.") }
        guard options.padding >= 0, options.padding <= 16_384, options.cornerRadius >= 0, options.cornerRadius <= 16_384,
              options.shadowRadius >= 0, options.shadowRadius <= 16_384,
              options.aspectRatio.map({ (0.1...10).contains($0) }) != false, photo.gamma > 0, photo.temperature > 0 else { throw TurnstoneError.invalid("Choose positive aspect, gamma, and temperature values and valid canvas effects.") }
        try validate(options.crop)
        try validate(options.color)
        try validate(options.background)
        for annotation in options.annotations {
            try validate(annotation.color)
            let path = ["pen", "line", "arrow"].contains(annotation.kind) && annotation.points.count >= 2
            if !path { try validate(annotation.rect) }
            guard annotation.points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) }) else { throw TurnstoneError.invalid("Annotation points must lie inside the image.") }
        }
        for redaction in options.redactions {
            try validate(redaction.rect)
            guard redaction.start.isFinite, redaction.start >= 0, redaction.end.map({ $0.isFinite && $0 > redaction.start }) != false else { throw TurnstoneError.invalid("Redaction times must be finite and ordered.") }
        }
        for range in options.ranges {
            guard range.start.isFinite, range.end.isFinite, range.start >= 0, range.end > range.start else { throw TurnstoneError.invalid("Time ranges must be finite, positive, and ordered.") }
        }
        guard (options.splitPoints + options.snapshotTimes).allSatisfy({ $0.isFinite && $0 >= 0 }) else { throw TurnstoneError.invalid("Snapshot and split times must be finite and nonnegative.") }
        guard ["reflow", "fixed"].contains(options.epubLayout) else { throw TurnstoneError.invalid("Choose reflow or fixed EPUB layout.") }
    }

    private func validate(_ rect: UnitRect) throws {
        guard [rect.x, rect.y, rect.width, rect.height].allSatisfy(\.isFinite), rect.x >= 0, rect.y >= 0, rect.width > 0, rect.height > 0,
              rect.x + rect.width <= 1.000001, rect.y + rect.height <= 1.000001 else { throw TurnstoneError.invalid("Crop, annotation, and redaction rectangles must lie inside the image.") }
    }

    private func validate(_ color: ColorValue) throws {
        guard [color.red, color.green, color.blue, color.alpha].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { throw TurnstoneError.invalid("Colors must use values between zero and one.") }
    }
}
