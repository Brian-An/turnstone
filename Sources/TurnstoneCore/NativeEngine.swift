import Foundation
import AppKit
import CoreImage
import ImageIO
import PDFKit
import Quartz
import Vision
import UniformTypeIdentifiers

public struct NativeEngine {
    private static let images: Set<String> = ["jpg", "png", "webp", "heic", "tiff", "svg", "avif", "bmp"]
    private static let archives: Set<String> = ["zip", "tar", "gz", "rar"]
    public init() {}

    public func perform(_ request: JobRequest, context: ExecutionContext) async throws -> [URL]? {
        guard let first = request.files.first else { throw TurnstoneError.invalid("Select at least one file.") }
        try context.checkCancellation()
        let ext = Catalog.fileExtension(first)
        switch request.operation {
        case .convert(let target):
            if Self.images.contains(ext) {
                if target == "pdf" { return [try makePDF(request.files, source: first, context: context)] }
                guard Self.images.contains(target), target != "svg" else { return nil }
                return try await request.files.asyncMap { file in
                    let output = context.temporaryURL(extension: target)
                    try await encode(try loadImage(file), to: output, quality: request.options.quality, properties: imageProperties(file), context: context)
                    return try context.publish(output, beside: file, extension: target)
                }
            }
            if ext == "pdf", ["jpg", "png", "txt", "md"].contains(target) {
                return try await request.files.asyncMap { try await convertPDF($0, target: target, options: request.options, context: context) }.flatMap { $0 }
            }
            if ["srt", "vtt"].contains(ext), ["srt", "vtt", "txt"].contains(target) {
                return try request.files.map { try subtitle($0, target: target, context: context) }
            }
            if Self.archives.contains(ext), Self.archives.contains(target), target != "rar" {
                return try await request.files.asyncMap { try await archive($0, target: target, context: context) }
            }
            return nil
        case .tool(let tool):
            if [.createPDF, .collage].contains(tool), request.files.allSatisfy({ Self.images.contains(Catalog.fileExtension($0)) }) {
                if tool == .createPDF { return [try makePDF(request.files, source: first, context: context)] }
                let image = try collage(request.files, options: request.options)
                return [try await publishImage(image, source: first, ext: "png", suffix: "Collage", options: request.options, context: context)]
            }
            if Self.images.contains(ext), [.compress, .metadata, .editImage, .annotateImage, .background, .cropImage, .redactImage].contains(tool) {
                return try await request.files.asyncMap { try await imageTool($0, tool: tool, options: request.options, context: context) }
            }
            if ext == "pdf", [.compress, .metadata, .splitPDF, .organizePDF, .mergePDF].contains(tool) {
                return try await pdfTool(request, tool: tool, context: context)
            }
            if Self.archives.contains(ext), tool == .extractArchive {
                return try await request.files.asyncMap { file in
                    let directory = try await extract(file, context: context)
                    return try context.publish(directory, beside: file, extension: "", suffix: "Extracted")
                }
            }
            return nil
        }
    }

    private func loadImage(_ url: URL, maximumDimension: Int? = nil) throws -> CGImage {
        try Task.checkCancellation()
        let limit = max(1, min(32768, maximumDimension ?? 32768))
        if let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
           let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: limit, kCGImageSourceShouldCacheImmediately: true] as CFDictionary) {
            try Task.checkCancellation()
            return image
        }
        if url.pathExtension.lowercased() == "svg", let image = NSImage(contentsOf: url) {
            let scale = min(1, Double(limit) / max(1, image.size.width, image.size.height))
            let width = max(1, Int(image.size.width * scale)), height = max(1, Int(image.size.height * scale))
            let context = try canvas(width: width, height: height)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            image.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
            NSGraphicsContext.restoreGraphicsState()
            try Task.checkCancellation()
            return try finish(context)
        }
        throw TurnstoneError.invalid("Could not decode \(url.lastPathComponent) as an image.")
    }

    private func imageSize(_ url: URL) -> CGSize? {
        let properties = imageProperties(url)
        if let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
           let height = properties[kCGImagePropertyPixelHeight] as? NSNumber {
            let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
            return orientation > 4 ? CGSize(width: height.doubleValue, height: width.doubleValue) : CGSize(width: width.doubleValue, height: height.doubleValue)
        }
        return NSImage(contentsOf: url)?.size
    }

    private func imageProperties(_ url: URL) -> [CFString: Any] {
        // ImageIO exposes untyped format-specific metadata dictionaries.
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return [:] }
        return properties
    }

    private func encode(_ image: CGImage, to output: URL, quality: Double, properties: [CFString: Any] = [:], context: ExecutionContext) async throws {
        try context.checkCancellation()
        guard quality.isFinite, (0...1).contains(quality) else { throw TurnstoneError.invalid("Choose a quality between zero and one.") }
        let identifiers = ["jpg": "public.jpeg", "png": "public.png", "heic": "public.heic", "tiff": "public.tiff", "bmp": "com.microsoft.bmp", "webp": "org.webmproject.webp", "avif": "public.avif"]
        let ext = output.pathExtension
        if let identifier = identifiers[ext], (CGImageDestinationCopyTypeIdentifiers() as! [String]).contains(identifier),
           let destination = CGImageDestinationCreateWithURL(output as CFURL, identifier as CFString, 1, nil) {
            var metadata = properties
            metadata[kCGImageDestinationLossyCompressionQuality] = min(1, max(0, quality))
            metadata[kCGImagePropertyOrientation] = 1
            CGImageDestinationAddImage(destination, image, metadata as CFDictionary)
            if CGImageDestinationFinalize(destination) { return }
        }
        guard let magick = ProcessRunner.locate("magick") else { throw TurnstoneError.missingDependency("ImageMagick") }
        let intermediary = context.temporaryURL(extension: "png")
        guard let destination = CGImageDestinationCreateWithURL(intermediary as CFURL, "public.png" as CFString, 1, nil) else { throw TurnstoneError.failed("Could not prepare the image encoder.") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw TurnstoneError.failed("Could not prepare the image encoder.") }
        _ = try await context.runner.run(magick, arguments: [intermediary.path, "-quality", String(Int(min(1, max(0, quality)) * 100)), output.path])
    }

    private func publishImage(_ image: CGImage, source: URL, ext: String, suffix: String, options: EditOptions, context: ExecutionContext) async throws -> URL {
        let output = context.temporaryURL(extension: ext)
        try await encode(image, to: output, quality: options.quality, context: context)
        return try context.publish(output, beside: source, extension: ext, suffix: suffix)
    }

    public func preview(files: [URL], tool: ToolID, options: EditOptions, maximumDimension: Int? = nil) throws -> CGImage {
        try Task.checkCancellation()
        guard let first = files.first else { throw TurnstoneError.invalid("Select an image to preview.") }
        if let maximumDimension, maximumDimension <= 0 { throw TurnstoneError.invalid("Choose a positive preview dimension.") }
        if tool == .collage { return try collage(files, options: options, maximumDimension: maximumDimension) }
        var image = try loadImage(first, maximumDimension: maximumDimension)
        let original = maximumDimension == nil ? nil : imageSize(first)
        let scale = original.map { Double(image.width) / max(1, $0.width) } ?? 1
        var rendering = options
        rendering.padding *= scale
        rendering.cornerRadius *= scale
        rendering.shadowRadius *= scale
        try Task.checkCancellation()
        if tool == .cropImage {
            let crop = try pixelRect(options.crop, width: image.width, height: image.height)
            guard let cropped = image.cropping(to: crop) else { throw TurnstoneError.invalid("The crop does not overlap the image.") }
            image = cropped
        } else if tool == .editImage {
            image = try adjusted(image, options: rendering, pixelScale: scale)
        } else if tool == .background {
            image = try background(image, options: rendering, pixelScale: scale, maximumDimension: maximumDimension)
        } else if tool == .annotateImage || tool == .redactImage {
            image = try marked(image, options: rendering, redact: tool == .redactImage, pixelScale: scale, maximumDimension: maximumDimension)
        }
        try Task.checkCancellation()
        if let maxDimension = options.maxDimension, maxDimension > 0, max(image.width, image.height) > maxDimension {
            let ratio = Double(maxDimension) / Double(max(image.width, image.height))
            image = try resize(image, width: max(1, Int(Double(image.width) * ratio)), height: max(1, Int(Double(image.height) * ratio)))
        }
        if let width = options.width, let height = options.height, width > 0, height > 0 {
            let ratio = maximumDimension.map { min(1, Double($0) / Double(max(width, height))) } ?? 1
            image = try resize(image, width: max(1, Int(Double(width) * ratio)), height: max(1, Int(Double(height) * ratio)))
        }
        if let maximumDimension, max(image.width, image.height) > maximumDimension {
            let ratio = Double(maximumDimension) / Double(max(image.width, image.height))
            image = try resize(image, width: max(1, Int(Double(image.width) * ratio)), height: max(1, Int(Double(image.height) * ratio)))
        }
        try Task.checkCancellation()
        return image
    }

    private func imageTool(_ file: URL, tool: ToolID, options: EditOptions, context: ExecutionContext) async throws -> URL {
        if tool == .metadata { return try await metadata(file, options: options, context: context) }
        let image = try preview(files: [file], tool: tool, options: options)
        let ext = Catalog.fileExtension(file)
        let outputExtension = ["svg", "avif", "bmp"].contains(ext) && tool != .compress ? "png" : ext
        let output = context.temporaryURL(extension: outputExtension)
        let target = tool == .compress ? try compressionTarget(file, options: options) : nil
        var quality = options.quality
        var attempts = 0
        repeat {
            try await encode(image, to: output, quality: quality, properties: tool == .redactImage ? [:] : imageProperties(file), context: context)
            attempts += 1
            guard tool == .compress, let target, try size(output) > target, quality > 0.12, attempts < 8 else { break }
            quality *= 0.72
        } while true
        if tool == .compress {
            guard try size(output) < size(file) else { throw TurnstoneError.failed("This image cannot be made smaller with these settings. The original is preserved.") }
            if let target, try size(output) > target { throw TurnstoneError.failed("The image cannot reach the requested size with these settings.") }
        }
        return try context.publish(output, beside: file, extension: outputExtension, suffix: tool.title)
    }

    private func compressionTarget(_ file: URL, options: EditOptions) throws -> Int? {
        guard options.reduction.isFinite, (0...100).contains(options.reduction), options.quality.isFinite, (0...1).contains(options.quality) else { throw TurnstoneError.invalid("Choose a valid compression quality and reduction percentage.") }
        let sourceSize = try size(file)
        let target = options.targetBytes ?? (options.reduction > 0 ? Int(Double(sourceSize) * (1 - options.reduction / 100)) : nil)
        if let target, target <= 0 { throw TurnstoneError.invalid("Choose a compression target greater than zero bytes.") }
        return target
    }

    private func size(_ url: URL) throws -> Int {
        try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    }

    private func pixelRect(_ unit: UnitRect, width: Int, height: Int) throws -> CGRect {
        guard [unit.x, unit.y, unit.width, unit.height].allSatisfy({ $0.isFinite }), unit.width > 0, unit.height > 0 else { throw TurnstoneError.invalid("Choose a valid crop rectangle.") }
        let rect = CGRect(x: unit.x * Double(width), y: unit.y * Double(height), width: unit.width * Double(width), height: unit.height * Double(height)).intersection(CGRect(x: 0, y: 0, width: width, height: height)).integral
        guard !rect.isEmpty, !rect.isNull else { throw TurnstoneError.invalid("The rectangle falls outside the image.") }
        return rect
    }

    private func canvas(width: Int, height: Int) throws -> CGContext {
        guard width > 0, height > 0, width <= 32768, height <= 32768, width * height <= 180_000_000,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw TurnstoneError.invalid("The requested image dimensions are too large or invalid.") }
        context.interpolationQuality = .high
        return context
    }

    private func resize(_ image: CGImage, width: Int, height: Int) throws -> CGImage {
        let context = try canvas(width: width, height: height)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return try finish(context)
    }

    private func finish(_ context: CGContext) throws -> CGImage {
        guard let image = context.makeImage() else { throw TurnstoneError.failed("Could not render the image.") }
        return image
    }

    private func adjusted(_ image: CGImage, options: EditOptions, pixelScale: Double = 1) throws -> CGImage {
        let p = options.photo
        var ci = CIImage(cgImage: image)
        func apply(_ name: String, _ values: [String: Any]) { ci = ci.applyingFilter(name, parameters: values) }
        apply("CIExposureAdjust", [kCIInputEVKey: p.exposure])
        apply("CIColorControls", [kCIInputBrightnessKey: p.brightness + p.whites * 0.1 + p.blacks * 0.1, kCIInputContrastKey: p.contrast + p.dehaze * 0.2, kCIInputSaturationKey: p.saturation])
        apply("CIHighlightShadowAdjust", ["inputHighlightAmount": p.highlights, "inputShadowAmount": p.shadows])
        apply("CIGammaAdjust", ["inputPower": max(0.01, p.gamma)])
        apply("CITemperatureAndTint", ["inputNeutral": CIVector(x: p.temperature, y: p.tint), "inputTargetNeutral": CIVector(x: 6500, y: 0)])
        apply("CIVibrance", ["inputAmount": p.vibrance])
        apply("CIHueAdjust", [kCIInputAngleKey: p.hue * .pi / 180])
        if p.sharpness != 0 || p.clarity != 0 { apply("CIUnsharpMask", [kCIInputRadiusKey: max(0.1, max(1, abs(p.clarity) * 8) * pixelScale), kCIInputIntensityKey: p.sharpness + p.clarity]) }
        if p.noiseReduction > 0 { apply("CINoiseReduction", ["inputNoiseLevel": p.noiseReduction * 0.1, "inputSharpness": 0.4]) }
        if p.vignette > 0 { apply("CIVignette", [kCIInputIntensityKey: p.vignette, kCIInputRadiusKey: Double(min(image.width, image.height)) / 2]) }
        if p.grain > 0, let noise = CIFilter(name: "CIRandomGenerator")?.outputImage {
            let grain = noise.cropped(to: ci.extent).applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0]).applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: min(1, p.grain) * 0.15)])
            ci = grain.composited(over: ci)
        }
        guard let result = CIContext().createCGImage(ci, from: CGRect(x: 0, y: 0, width: image.width, height: image.height)) else { throw TurnstoneError.failed("Could not apply the photo adjustments.") }
        return result
    }

    private func cgColor(_ color: ColorValue) -> CGColor { CGColor(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha) }

    private func marked(_ image: CGImage, options: EditOptions, redact: Bool, pixelScale: Double = 1, maximumDimension: Int? = nil) throws -> CGImage {
        let context = try canvas(width: image.width, height: image.height)
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.draw(image, in: bounds)
        if redact {
            let blurred = options.blur ? CIContext().createCGImage(CIImage(cgImage: image).clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 24 * pixelScale]), from: bounds) : nil
            for redaction in options.redactions {
                try Task.checkCancellation()
                var rect = try pixelRect(redaction.rect, width: image.width, height: image.height)
                rect.origin.y = CGFloat(image.height) - rect.maxY
                if let blurred {
                    context.saveGState(); context.clip(to: rect); context.draw(blurred, in: bounds); context.restoreGState()
                } else { context.setFillColor(cgColor(options.color)); context.fill(rect) }
            }
        } else {
            for annotation in options.annotations {
                try Task.checkCancellation()
                let pointBased = ["pen", "line", "arrow"].contains(annotation.kind) && annotation.points.count >= 2
                var rect = pointBased ? bounds : try pixelRect(annotation.rect, width: image.width, height: image.height)
                rect.origin.y = CGFloat(image.height) - rect.maxY
                context.setStrokeColor(cgColor(annotation.color)); context.setFillColor(cgColor(annotation.color))
                context.setLineWidth(max(2 * pixelScale, Double(image.width) / 250))
                switch annotation.kind {
                case "text":
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
                    (annotation.text as NSString).draw(in: rect, withAttributes: [.font: NSFont.systemFont(ofSize: max(12 * pixelScale, rect.height * 0.7)), .foregroundColor: NSColor(cgColor: cgColor(annotation.color)) ?? .systemOrange])
                    NSGraphicsContext.restoreGraphicsState()
                case "ellipse", "circle": context.strokeEllipse(in: rect)
                case "pen", "line", "arrow":
                    let points = try annotation.points.map { point -> CGPoint in
                        guard point.x.isFinite, point.y.isFinite else { throw TurnstoneError.invalid("Annotation points must be finite.") }
                        return CGPoint(x: point.x * Double(image.width), y: (1 - point.y) * Double(image.height))
                    }
                    let start = points.first ?? rect.origin
                    let end = points.last ?? CGPoint(x: rect.maxX, y: rect.maxY)
                    context.setLineCap(.round); context.setLineJoin(.round)
                    context.move(to: start)
                    if annotation.kind == "pen", points.count > 1 {
                        for point in points.dropFirst() { context.addLine(to: point) }
                    } else { context.addLine(to: end) }
                    context.strokePath()
                    if annotation.kind == "arrow" {
                        let angle = atan2(end.y - start.y, end.x - start.x)
                        let length = min(24 * pixelScale, max(6 * pixelScale, hypot(end.x - start.x, end.y - start.y) * 0.2))
                        context.move(to: CGPoint(x: end.x - length * cos(angle - .pi / 6), y: end.y - length * sin(angle - .pi / 6)))
                        context.addLine(to: end)
                        context.addLine(to: CGPoint(x: end.x - length * cos(angle + .pi / 6), y: end.y - length * sin(angle + .pi / 6)))
                        context.strokePath()
                    }
                case "number":
                    let diameter = min(rect.width, rect.height)
                    let circle = CGRect(x: rect.midX - diameter / 2, y: rect.midY - diameter / 2, width: diameter, height: diameter)
                    context.fillEllipse(in: circle)
                    let style = NSMutableParagraphStyle(); style.alignment = .center
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
                    let text = String(annotation.number) as NSString
                    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: diameter * 0.58), .foregroundColor: NSColor.white, .paragraphStyle: style]
                    let textHeight = text.size(withAttributes: attributes).height
                    text.draw(in: CGRect(x: circle.minX, y: circle.midY - textHeight / 2, width: diameter, height: textHeight), withAttributes: attributes)
                    NSGraphicsContext.restoreGraphicsState()
                case "magnify":
                    let source = CGRect(x: rect.midX - rect.width / 4, y: CGFloat(image.height) - rect.midY - rect.height / 4, width: rect.width / 2, height: rect.height / 2).intersection(bounds)
                    guard let magnified = image.cropping(to: source) else { throw TurnstoneError.invalid("Choose a magnifier inside the image.") }
                    context.saveGState(); context.addEllipse(in: rect); context.clip(); context.draw(magnified, in: rect); context.restoreGState(); context.strokeEllipse(in: rect)
                case "image":
                    guard let url = annotation.imageURL else { throw TurnstoneError.invalid("Choose an image to stamp.") }
                    context.draw(try loadImage(url, maximumDimension: maximumDimension), in: rect)
                case "highlight": context.setAlpha(0.35); context.fill(rect); context.setAlpha(1)
                default: context.stroke(rect)
                }
            }
        }
        return try finish(context)
    }

    private func background(_ image: CGImage, options: EditOptions, pixelScale: Double = 1, maximumDimension: Int? = nil) throws -> CGImage {
        let padding = max(0, min(5000, options.padding))
        var width = Double(image.width) + padding * 2
        var height = Double(image.height) + padding * 2
        if let ratio = options.aspectRatio, ratio.isFinite, ratio > 0 {
            if width / height < ratio { width = height * ratio } else { height = width / ratio }
        }
        let context = try canvas(width: Int(width), height: Int(height))
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        if options.backgroundStyle == "image", let url = options.backgroundImage {
            context.draw(try loadImage(url, maximumDimension: maximumDimension), in: bounds)
        } else if options.backgroundStyle == "gradient", let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [cgColor(options.background), cgColor(ColorValue(0.2, 0.12, 0.4))] as CFArray, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        } else { context.setFillColor(cgColor(options.background)); context.fill(bounds) }
        let imageWidth = Double(image.width)
        let imageHeight = Double(image.height)
        let rect = CGRect(x: (width - imageWidth) / 2, y: (height - imageHeight) / 2, width: imageWidth, height: imageHeight)
        let path = CGPath(roundedRect: rect, cornerWidth: max(0, options.cornerRadius), cornerHeight: max(0, options.cornerRadius), transform: nil)
        if options.shadowRadius > 0 {
            context.saveGState(); context.setShadow(offset: CGSize(width: 0, height: -5 * pixelScale), blur: options.shadowRadius, color: CGColor(gray: 0, alpha: 0.4)); context.setFillColor(CGColor(gray: 0, alpha: 1)); context.addPath(path); context.fillPath(); context.restoreGState()
        }
        context.addPath(path); context.clip(); context.draw(image, in: rect)
        return try finish(context)
    }

    private func collage(_ files: [URL], options: EditOptions, maximumDimension: Int? = nil) throws -> CGImage {
        try Task.checkCancellation()
        guard !files.isEmpty else { throw TurnstoneError.invalid("Select images for the collage.") }
        let featured = options.collageStyle == "featured" && files.count > 1
        let columns: Int
        switch options.collageStyle {
        case "vertical", "column": columns = 1
        case "horizontal", "row": columns = files.count
        case "featured": columns = max(3, min(12, options.columns))
        default: columns = max(1, min(files.count, options.columns))
        }
        var cells: [(column: Int, row: Int, span: Int)] = []
        if featured {
            cells.append((0, 0, 2))
            var row = 0, column = 2
            while cells.count < files.count {
                if column >= columns { row += 1; column = row < 2 ? 2 : 0 }
                cells.append((column, row, 1)); column += 1
            }
        } else {
            cells = files.indices.map { ($0 % columns, $0 / columns, 1) }
        }
        let rows = cells.map { $0.row + $0.span }.max() ?? 1
        let originalWidth = Double(max(64, min(16384, options.canvasWidth)))
        let originalGap = max(0, min(originalWidth / Double(columns * 4), options.padding))
        let originalCell = (originalWidth - originalGap * Double(columns + 1)) / Double(columns)
        let originalHeight = originalCell * Double(rows) + originalGap * Double(rows + 1)
        let renderScale = maximumDimension.map { min(1, Double($0) / max(originalWidth, originalHeight)) } ?? 1
        let width = max(1, Int(originalWidth * renderScale)), height = max(1, Int(originalHeight * renderScale))
        let gap = originalGap * renderScale, cell = originalCell * renderScale
        let context = try canvas(width: width, height: height)
        context.setFillColor(cgColor(options.background)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for (index, file) in files.enumerated() {
            try Task.checkCancellation()
            let image = try loadImage(file, maximumDimension: maximumDimension)
            let placement = cells[index]
            let side = cell * Double(placement.span) + gap * Double(placement.span - 1)
            let rect = CGRect(x: gap + Double(placement.column) * (cell + gap), y: Double(height) - gap - side - Double(placement.row) * (cell + gap), width: side, height: side)
            let scale = options.imageFit == "fit" ? min(side / Double(image.width), side / Double(image.height)) : max(side / Double(image.width), side / Double(image.height))
            let destination = CGRect(x: rect.midX - Double(image.width) * scale / 2, y: rect.midY - Double(image.height) * scale / 2, width: Double(image.width) * scale, height: Double(image.height) * scale)
            context.saveGState(); context.addPath(CGPath(roundedRect: rect, cornerWidth: max(0, options.cornerRadius * renderScale), cornerHeight: max(0, options.cornerRadius * renderScale), transform: nil)); context.clip(); context.draw(image, in: destination); context.restoreGState()
        }
        try Task.checkCancellation()
        return try finish(context)
    }

    private func makePDF(_ files: [URL], source: URL, context: ExecutionContext) throws -> URL {
        let document = PDFDocument()
        for file in files {
            try context.checkCancellation()
            let image = try loadImage(file)
            guard let page = PDFPage(image: NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))) else { throw TurnstoneError.failed("Could not add \(file.lastPathComponent) to the PDF.") }
            document.insert(page, at: document.pageCount)
        }
        return try publishPDF(document, source: source, suffix: nil, context: context)
    }

    private func readPDF(_ file: URL) throws -> PDFDocument {
        guard let document = PDFDocument(url: file), !document.isLocked, document.pageCount > 0 else { throw TurnstoneError.invalid("Could not open \(file.lastPathComponent). Check that the PDF is valid and unlocked.") }
        return document
    }

    private func publishPDF(_ document: PDFDocument, source: URL, suffix: String?, context: ExecutionContext) throws -> URL {
        let output = context.temporaryURL(extension: "pdf")
        guard document.write(to: output) else { throw TurnstoneError.failed("Could not write the PDF.") }
        return try context.publish(output, beside: source, extension: "pdf", suffix: suffix)
    }

    private func pdfTool(_ request: JobRequest, tool: ToolID, context: ExecutionContext) async throws -> [URL] {
        guard let first = request.files.first else { return [] }
        if tool == .mergePDF {
            let merged = PDFDocument()
            for file in request.files {
                let document = try readPDF(file)
                for index in 0..<document.pageCount {
                    try context.checkCancellation()
                    if let page = document.page(at: index)?.copy() as? PDFPage { merged.insert(page, at: merged.pageCount) }
                }
            }
            return [try publishPDF(merged, source: first, suffix: "Merged", context: context)]
        }
        return try await request.files.asyncMap { file in
            let document = try readPDF(file)
            if tool == .splitPDF {
                // Explicit ranges use inclusive, one-based page numbers.
                let groups: [[Int]]
                if !request.options.ranges.isEmpty {
                    groups = try request.options.ranges.map { range in
                        guard range.start.isFinite, range.end.isFinite, range.start >= 1, range.end >= range.start, range.end <= Double(document.pageCount) else { throw TurnstoneError.invalid("Choose valid PDF page ranges.") }
                        return Array((Int(range.start) - 1)...(Int(range.end) - 1))
                    }
                } else { groups = (0..<document.pageCount).map { [$0] } }
                let folder = context.temporaryURL(extension: "")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for (index, group) in groups.enumerated() {
                    try context.checkCancellation()
                    let part = PDFDocument()
                    for pageIndex in group { if let page = document.page(at: pageIndex)?.copy() as? PDFPage { part.insert(page, at: part.pageCount) } }
                    let output = folder.appendingPathComponent(String(format: "Part %03d.pdf", index + 1))
                    guard part.write(to: output) else { throw TurnstoneError.failed("Could not write a split PDF part.") }
                }
                return [try context.publish(folder, beside: file, extension: "", suffix: "Split PDF")]
            }
            if tool == .metadata {
                var attributes = request.options.removeAllMetadata ? [:] : document.documentAttributes ?? [:]
                for (key, value) in request.options.metadata {
                    let attribute = PDFDocumentAttribute(rawValue: key)
                    if value.isEmpty { attributes.removeValue(forKey: attribute) } else { attributes[attribute] = value }
                }
                document.documentAttributes = attributes
            }
            if tool == .organizePDF {
                let organized = PDFDocument()
                let edits = request.options.pdfPages.isEmpty ? (0..<document.pageCount).map { PDFPageEdit(index: $0) } : request.options.pdfPages
                let targetWidth = try edits.map { edit -> CGFloat in
                    guard (0..<document.pageCount).contains(edit.index), let page = document.page(at: edit.index) else { throw TurnstoneError.invalid("Choose valid PDF pages.") }
                    let bounds = page.bounds(for: .mediaBox)
                    return (page.rotation + edit.rotation) % 180 == 0 ? bounds.width : bounds.height
                }.min() ?? 612
                for edit in edits {
                    guard (0..<document.pageCount).contains(edit.index), edit.rotation % 90 == 0,
                          let page = document.page(at: edit.index)?.copy() as? PDFPage else { throw TurnstoneError.invalid("Choose valid PDF pages and quarter-turn rotations.") }
                    page.rotation = (page.rotation + edit.rotation) % 360
                    if request.options.matchPageWidth {
                        let size = Self.renderedPDFSize(page)
                        let scale = targetWidth / max(1, size.width)
                        let resized = try scaledPDFPage(page, scale: scale)
                        organized.insert(resized, at: organized.pageCount)
                    } else { organized.insert(page, at: organized.pageCount) }
                }
                return [try publishPDF(organized, source: file, suffix: tool.title, context: context)]
            }
            if tool == .compress {
                let target = try compressionTarget(file, options: request.options)
                let originalSize = try size(file)
                var best: URL?
                var bestSize = originalSize
                for attempt in 0..<6 {
                    try context.checkCancellation()
                    let quality = max(0.08, request.options.quality * pow(0.7, Double(attempt)))
                    let resolution = max(48, 144 * pow(0.85, Double(attempt)))
                    let settings: [String: Any] = [
                        "Domains": ["Applications": true, "Printing": true],
                        "FilterData": ["ColorSettings": ["ImageSettings": [
                            "Compression Quality": quality,
                            "ImageCompression": "ImageJPEGCompress",
                            "ImageScaleSettings": ["ImageResolution": resolution, "ImageScaleInterpolate": true, "ImageSizeMax": request.options.maxDimension ?? 2400, "ImageSizeMin": 0]
                        ]]],
                        "FilterType": 1, "Name": "Turnstone Compression"
                    ]
                    guard let filter = QuartzFilter(properties: settings) else { throw TurnstoneError.failed("Could not prepare PDF image compression.") }
                    let temporary = context.temporaryURL(extension: "pdf")
                    guard document.write(to: temporary, withOptions: [PDFDocumentWriteOption(rawValue: "QuartzFilter"): filter]) else { throw TurnstoneError.failed("Could not optimize this PDF.") }
                    let bytes = try size(temporary)
                    if bytes < bestSize { best = temporary; bestSize = bytes }
                    if let target { if bestSize <= target { break } } else { break }
                }
                guard let best else { throw TurnstoneError.failed("This PDF cannot be made smaller with these settings. The original is preserved.") }
                if let target, bestSize > target { throw TurnstoneError.failed("The PDF cannot reach the requested size with these settings.") }
                return [try context.publish(best, beside: file, extension: "pdf", suffix: "Compressed")]
            }
            return [try publishPDF(document, source: file, suffix: tool.title, context: context)]
        }.flatMap { $0 }
    }

    private func scaledPDFPage(_ page: PDFPage, scale: CGFloat) throws -> PDFPage {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data) else { throw TurnstoneError.failed("Could not prepare the PDF page.") }
        let source = Self.renderedPDFSize(page)
        var bounds = CGRect(x: 0, y: 0, width: source.width * scale, height: source.height * scale)
        guard let context = CGContext(consumer: consumer, mediaBox: &bounds, nil) else { throw TurnstoneError.failed("Could not resize the PDF page.") }
        context.beginPDFPage(nil); context.scaleBy(x: scale, y: scale); page.draw(with: .mediaBox, to: context); context.endPDFPage(); context.closePDF()
        guard let result = PDFDocument(data: data as Data)?.page(at: 0) else { throw TurnstoneError.failed("Could not resize the PDF page.") }
        return result
    }

    private func convertPDF(_ file: URL, target: String, options: EditOptions, context: ExecutionContext) async throws -> [URL] {
        if target == "txt" || target == "md" {
            let output = context.temporaryURL(extension: target)
            let text = try await Self.pdfText(at: file)
            try text.write(to: output, atomically: true, encoding: .utf8)
            return [try context.publish(output, beside: file, extension: target)]
        }
        let document = try readPDF(file)
        let folder: URL?
        if document.pageCount > 1 {
            let directory = context.temporaryURL(extension: "")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            folder = directory
        } else { folder = nil }
        var singleOutput: URL?
        for index in 0..<document.pageCount {
            try context.checkCancellation()
            guard let page = document.page(at: index) else { throw TurnstoneError.failed("Could not read a PDF page.") }
            let image = try Self.renderPDFPage(page, scale: CGFloat(300) / 72)
            if let folder {
                let output = folder.appendingPathComponent(String(format: "Page %03d.%@", index + 1, target))
                try await encode(image, to: output, quality: options.quality, context: context)
            } else {
                singleOutput = try await publishImage(image, source: file, ext: target, suffix: "", options: options, context: context)
            }
        }
        if let folder { return [try context.publish(folder, beside: file, extension: "", suffix: "\(target.uppercased()) Pages")] }
        return singleOutput.map { [$0] } ?? []
    }

    private static func renderedPDFSize(_ page: PDFPage) -> CGSize {
        let bounds = page.bounds(for: .mediaBox)
        return page.rotation % 180 == 0 ? bounds.size : CGSize(width: bounds.height, height: bounds.width)
    }

    private static func renderPDFPage(_ page: PDFPage, scale: CGFloat) throws -> CGImage {
        let bounds = renderedPDFSize(page)
        let engine = NativeEngine()
        let context = try engine.canvas(width: Int(bounds.width * scale), height: Int(bounds.height * scale))
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        return try engine.finish(context)
    }

    public static func pdfText(at url: URL) async throws -> String {
        let document = try NativeEngine().readPDF(url)
        var pages: [String] = []
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { continue }
            if let text = page.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { pages.append(text); continue }
            let image = try renderPDFPage(page, scale: 2)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            try VNImageRequestHandler(cgImage: image).perform([request])
            pages.append((request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n"))
        }
        return pages.joined(separator: "\n\n")
    }

    public static func detectRedactions(in url: URL, faces: Bool) async throws -> [UnitRect] {
        let image = try NativeEngine().loadImage(url)
        let handler = VNImageRequestHandler(cgImage: image)
        let boxes: [CGRect]
        if faces {
            let request = VNDetectFaceRectanglesRequest()
            try handler.perform([request]); boxes = (request.results ?? []).map(\.boundingBox)
        } else {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            try handler.perform([request]); boxes = (request.results ?? []).map(\.boundingBox)
        }
        return boxes.map { UnitRect(x: $0.minX, y: 1 - $0.maxY, width: $0.width, height: $0.height) }
    }

    private func metadata(_ file: URL, options: EditOptions, context: ExecutionContext) async throws -> URL {
        guard let exiftool = ProcessRunner.locate("exiftool") else { throw TurnstoneError.missingDependency("ExifTool") }
        let ext = Catalog.fileExtension(file)
        let output = context.temporaryURL(extension: ext)
        try FileManager.default.copyItem(at: file, to: output)
        var arguments = ["-overwrite_original"]
        if options.removeAllMetadata { arguments.append("-all=") }
        for key in options.metadata.keys.sorted() {
            guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == ":" || $0 == "_" || $0 == "-" }), !key.hasPrefix("-") else { throw TurnstoneError.invalid("Invalid metadata field name.") }
            arguments.append("-\(key)=\(options.metadata[key] ?? "")")
        }
        guard arguments.count > 1 else { throw TurnstoneError.invalid("Choose metadata fields to edit or remove.") }
        arguments.append(output.path)
        _ = try await context.runner.run(exiftool, arguments: arguments)
        return try context.publish(output, beside: file, extension: ext, suffix: "Metadata")
    }

    private func subtitle(_ file: URL, target: String, context: ExecutionContext) throws -> URL {
        let content = try String(contentsOf: file, encoding: .utf8).replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let blocks = content.components(separatedBy: "\n\n")
        var cues: [(String, String)] = []
        let pattern = #"^(?:(\d{2,}):)?(\d{2}):(\d{2})[,.](\d{3})\s+-->\s+(?:(\d{2,}):)?(\d{2}):(\d{2})[,.](\d{3})(?:\s+.*)?$"#
        let regex = try NSRegularExpression(pattern: pattern)
        for block in blocks {
            let lines = block.components(separatedBy: "\n")
            guard let timestampIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let line = lines[timestampIndex]
            guard let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)), timestampIndex + 1 < lines.count else { throw TurnstoneError.invalid("The subtitle contains an invalid cue.") }
            func field(_ index: Int) -> String { Range(match.range(at: index), in: line).map { String(line[$0]) } ?? "00" }
            let separator = target == "srt" ? "," : "."
            let timing = "\(field(1)):\(field(2)):\(field(3))\(separator)\(field(4)) --> \(field(5)):\(field(6)):\(field(7))\(separator)\(field(8))"
            cues.append((timing, lines[(timestampIndex + 1)...].joined(separator: "\n").trimmingCharacters(in: .newlines)))
        }
        guard !cues.isEmpty else { throw TurnstoneError.invalid("No valid subtitle cues were found.") }
        let result: String
        if target == "txt" {
            result = cues.map { $0.1.replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression) }.joined(separator: "\n") + "\n"
        } else {
            result = (target == "vtt" ? "WEBVTT\n\n" : "") + cues.enumerated().map { index, cue in
                (target == "srt" ? "\(index + 1)\n" : "") + cue.0 + "\n" + cue.1
            }.joined(separator: "\n\n") + "\n"
        }
        let output = context.temporaryURL(extension: target)
        try result.write(to: output, atomically: true, encoding: .utf8)
        return try context.publish(output, beside: file, extension: target)
    }

    private func extract(_ file: URL, context: ExecutionContext) async throws -> URL {
        let tar = URL(fileURLWithPath: "/usr/bin/tar")
        let staged = context.temporaryURL(extension: file.pathExtension)
        try FileManager.default.copyItem(at: file, to: staged)
        let entries: String
        do {
            entries = try await context.runner.run(tar, arguments: ["-tf", staged.path])
        } catch {
            try context.checkCancellation()
            guard Catalog.fileExtension(file) == "gz" else { throw error }
            _ = try await context.runner.run(URL(fileURLWithPath: "/usr/bin/gzip"), arguments: ["-d", "-k", staged.path])
            let directory = context.temporaryURL(extension: "")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent(file.deletingPathExtension().lastPathComponent)
            try FileManager.default.moveItem(at: staged.deletingPathExtension(), to: destination)
            return directory
        }
        guard !entries.isEmpty, entries.utf8.count < 4_190_000 else { throw TurnstoneError.invalid("The archive is empty or unsupported.") }
        for path in entries.split(separator: "\n", omittingEmptySubsequences: true) {
            guard !path.hasPrefix("/"), !path.hasPrefix("\\"), !path.contains("\\"), !path.split(separator: "/").contains(".."), !path.contains("\0") else { throw TurnstoneError.invalid("The archive contains an unsafe path.") }
        }
        let verbose = try await context.runner.run(tar, arguments: ["-tvf", staged.path])
        guard verbose.utf8.count < 4_190_000 else { throw TurnstoneError.invalid("This archive has too many entries to inspect safely.") }
        // Reject every link and special file before extraction, including hard links.
        for line in verbose.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let type = line.first, type == "-" || type == "d" else { throw TurnstoneError.invalid("The archive contains links or special files, which cannot be safely extracted.") }
        }
        let output = context.temporaryURL(extension: "")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        _ = try await context.runner.run(tar, arguments: ["-xf", staged.path, "-C", output.path, "--no-same-owner", "--no-same-permissions"])
        try validateExtractedDirectory(output)
        return output
    }

    private func validateExtractedDirectory(_ output: URL) throws {
        let rootPath = output.standardizedFileURL.path + "/"
        guard let enumerator = FileManager.default.enumerator(at: output, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey]) else { throw TurnstoneError.failed("Could not inspect the extracted archive.") }
        for case let item as URL in enumerator {
            let values = try item.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey])
            guard values.isSymbolicLink != true, values.isRegularFile == true || values.isDirectory == true, item.resolvingSymlinksInPath().path.hasPrefix(rootPath) else { throw TurnstoneError.invalid("The archive produced an unsafe entry.") }
        }
    }

    private func archive(_ file: URL, target: String, context: ExecutionContext) async throws -> URL {
        let directory = try await extract(file, context: context)
        let output = context.temporaryURL(extension: target)
        if target == "zip" {
            _ = try await context.runner.run(URL(fileURLWithPath: "/usr/bin/ditto"), arguments: ["-c", "-k", "--norsrc", directory.path, output.path])
        } else {
            _ = try await context.runner.run(URL(fileURLWithPath: "/usr/bin/tar"), arguments: [target == "gz" ? "-czf" : "-cf", output.path, "-C", directory.path, "."])
        }
        return try context.publish(output, beside: file, extension: target)
    }
}

private extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var results: [T] = []
        for element in self { results.append(try await transform(element)) }
        return results
    }
}
