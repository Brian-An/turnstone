import XCTest
import AppKit
import PDFKit
import ImageIO
import CoreText
@testable import TurnstoneCore

final class NativeEngineTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func image(_ name: String = "photo.png") throws -> URL {
        let url = directory.appendingPathComponent(name)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 80, pixelsHigh: 60, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for x in 0..<80 { for y in 0..<60 { bitmap.setColor(NSColor(deviceRed: 1, green: 0.5, blue: 0, alpha: 1), atX: x, y: y) } }
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        return url
    }

    private func perform(_ request: JobRequest) async throws -> [URL] {
        let outputs = try await NativeEngine().perform(request, context: ExecutionContext())
        return try XCTUnwrap(outputs)
    }

    func testConvertsRealImageAndPreservesOriginal() async throws {
        let source = try image()
        let original = try Data(contentsOf: source)
        let result = try await perform(JobRequest(files: [source], operation: .convert("jpg")))
        XCTAssertEqual(result.count, 1)
        let decoded = try XCTUnwrap(CGImageSourceCreateWithURL(result[0] as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(decoded), 1)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testCropsPixelsAndRejectsMalformedImageWithoutOutput() async throws {
        let source = try image()
        var options = EditOptions()
        options.crop = UnitRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let result = try await perform(JobRequest(files: [source], operation: .tool(.cropImage), options: options))
        let decoded = try XCTUnwrap(CGImageSourceCreateWithURL(result[0] as CFURL, nil))
        let pixels = try XCTUnwrap(CGImageSourceCreateImageAtIndex(decoded, 0, nil))
        XCTAssertEqual(pixels.width, 40)
        XCTAssertEqual(pixels.height, 30)
        let broken = directory.appendingPathComponent("broken.png")
        try Data("not an image".utf8).write(to: broken)
        do {
            _ = try await NativeEngine().perform(JobRequest(files: [broken], operation: .convert("jpg")), context: ExecutionContext())
            XCTFail("Malformed images must fail")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("broken.jpg").path))
    }

    func testCreatesMergesSplitsAndReordersRealPDFs() async throws {
        let source = try image()
        let second = try image("other.png")
        let created = try await perform(JobRequest(files: [source, second], operation: .tool(.createPDF)))
        XCTAssertEqual(PDFDocument(url: created[0])?.pageCount, 2)
        var options = EditOptions()
        options.pdfPages = [PDFPageEdit(index: 1, rotation: 90), PDFPageEdit(index: 0), PDFPageEdit(index: 0)]
        let reordered = try await perform(JobRequest(files: created, operation: .tool(.organizePDF), options: options))
        XCTAssertEqual(PDFDocument(url: reordered[0])?.pageCount, 3)
        XCTAssertEqual(PDFDocument(url: reordered[0])?.page(at: 0)?.rotation, 90)
        let split = try await perform(JobRequest(files: created, operation: .tool(.splitPDF)))
        XCTAssertEqual(split.count, 1)
        XCTAssertTrue(try split[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
        let parts = try FileManager.default.contentsOfDirectory(at: split[0], includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertEqual(parts.count, 2)
        XCTAssertTrue(parts.allSatisfy { PDFDocument(url: $0)?.pageCount == 1 })
        let merged = try await perform(JobRequest(files: parts, operation: .tool(.mergePDF)))
        XCTAssertEqual(PDFDocument(url: merged[0])?.pageCount, 2)
    }

    func testSubtitleRoundTripPreservesTimestampsAndRemovesMarkupForText() async throws {
        let source = directory.appendingPathComponent("captions.srt")
        try Data("1\n00:00:01,250 --> 00:00:03,750\n<b>Hello</b> world\n\n2\n00:00:04,000 --> 00:00:05,000\nSecond line\n".utf8).write(to: source)
        let converted = try await perform(JobRequest(files: [source], operation: .convert("vtt")))
        let content = try String(contentsOf: converted[0], encoding: .utf8)
        XCTAssertTrue(content.contains("WEBVTT"))
        XCTAssertTrue(content.contains("00:00:01.250 --> 00:00:03.750"))
        let text = try await perform(JobRequest(files: [source], operation: .convert("txt")))
        XCTAssertEqual(try String(contentsOf: text[0], encoding: .utf8), "Hello world\nSecond line\n")
    }

    func testArchiveRoundTripAndTraversalRejection() async throws {
        let input = directory.appendingPathComponent("hello.txt")
        try Data("hello".utf8).write(to: input)
        let tar = directory.appendingPathComponent("sample.tar")
        _ = try await ProcessRunner().run(URL(fileURLWithPath: "/usr/bin/tar"), arguments: ["-cf", tar.path, "-C", directory.path, input.lastPathComponent])
        let converted = try await perform(JobRequest(files: [tar], operation: .convert("zip")))
        let extracted = try await perform(JobRequest(files: converted, operation: .tool(.extractArchive)))
        XCTAssertEqual(try String(contentsOf: extracted[0].appendingPathComponent("hello.txt"), encoding: .utf8), "hello")
        let link = directory.appendingPathComponent("unsafe-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/etc/passwd"))
        let unsafe = directory.appendingPathComponent("unsafe.tar")
        _ = try await ProcessRunner().run(URL(fileURLWithPath: "/usr/bin/tar"), arguments: ["-cf", unsafe.path, "-C", directory.path, link.lastPathComponent])
        do {
            _ = try await NativeEngine().perform(JobRequest(files: [unsafe], operation: .tool(.extractArchive)), context: ExecutionContext())
            XCTFail("Archive links must be rejected")
        } catch {}
    }
    func testExtractsRawGzipAndPreservesOriginal() async throws {
        let source = directory.appendingPathComponent("message.txt")
        try Data("a gzip payload".utf8).write(to: source)
        _ = try await ProcessRunner().run(URL(fileURLWithPath: "/usr/bin/gzip"), arguments: ["-k", source.path])
        let compressed = source.appendingPathExtension("gz")
        let result = try await perform(JobRequest(files: [compressed], operation: .tool(.extractArchive)))
        XCTAssertEqual(try String(contentsOf: result[0].appendingPathComponent("message.txt"), encoding: .utf8), "a gzip payload")
        XCTAssertTrue(FileManager.default.fileExists(atPath: compressed.path))
    }

    func testAdjustmentsAnnotationsBackgroundsCollagesAndRedactionRenderPixels() async throws {
        let source = try image()
        var options = EditOptions()
        options.photo.saturation = 0
        let adjusted = try await perform(JobRequest(files: [source], operation: .tool(.editImage), options: options))
        let gray = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: adjusted[0]))?.colorAt(x: 40, y: 30)?.usingColorSpace(.deviceRGB))
        XCTAssertEqual(gray.redComponent, gray.greenComponent, accuracy: 0.02)
        options.redactions = [Redaction(rect: UnitRect())]
        let redacted = try await perform(JobRequest(files: [source], operation: .tool(.redactImage), options: options))
        let black = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: redacted[0]))?.colorAt(x: 40, y: 30)?.usingColorSpace(.deviceRGB))
        XCTAssertEqual(black.redComponent, 0, accuracy: 0.01)
        options.padding = 10
        let background = try await perform(JobRequest(files: [source], operation: .tool(.background), options: options))
        let backdrop = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: background[0])))
        XCTAssertEqual(backdrop.pixelsWide, 100)
        XCTAssertEqual(backdrop.pixelsHigh, 80)
        options.canvasWidth = 200
        let collage = try await perform(JobRequest(files: [source, source], operation: .tool(.collage), options: options))
        XCTAssertEqual(NSBitmapImageRep(data: try Data(contentsOf: collage[0]))?.pixelsWide, 200)
        options.annotations = [Annotation(kind: "highlight", rect: UnitRect(), color: ColorValue(0, 0, 1))]
        let annotated = try await perform(JobRequest(files: [source], operation: .tool(.annotateImage), options: options))
        let colored = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: annotated[0]))?.colorAt(x: 40, y: 30)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(colored.blueComponent, 0.2)
    }

    func testPDFTextImagesAndMetadataPreserveTheSource() async throws {
        let source = directory.appendingPathComponent("text.pdf")
        let data = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        var bounds = CGRect(x: 0, y: 0, width: 200, height: 100)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &bounds, nil))
        context.beginPDFPage(nil)
        context.textPosition = CGPoint(x: 20, y: 50)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Hello PDF", attributes: [.font: NSFont.systemFont(ofSize: 20)]) as CFAttributedString)
        CTLineDraw(line, context)
        context.endPDFPage(); context.closePDF()
        try (data as Data).write(to: source)
        let text = try await perform(JobRequest(files: [source], operation: .convert("txt")))
        XCTAssertTrue(try String(contentsOf: text[0], encoding: .utf8).contains("Hello PDF"))
        let image = try await perform(JobRequest(files: [source], operation: .convert("png")))
        XCTAssertEqual(NSBitmapImageRep(data: try Data(contentsOf: image[0]))?.pixelsWide, 833)
        var options = EditOptions()
        options.metadata = ["Title": "Test document"]
        let edited = try await perform(JobRequest(files: [source], operation: .tool(.metadata), options: options))
        XCTAssertEqual(PDFDocument(url: edited[0])?.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, "Test document")
        XCTAssertEqual(try Data(contentsOf: source), data as Data)
    }

    func testFreehandAnnotationsUseActualPointsAndCanStampImages() async throws {
        let source = try image()
        var options = EditOptions()
        var pen = Annotation(kind: "pen", rect: UnitRect(), color: ColorValue(0, 0, 1))
        pen.points = [CanvasPoint(x: 0.1, y: 0.5), CanvasPoint(x: 0.5, y: 0.5), CanvasPoint(x: 0.9, y: 0.5)]
        options.annotations = [pen]
        let line = try NativeEngine().preview(files: [source], tool: .annotateImage, options: options)
        let blue = try XCTUnwrap(NSBitmapImageRep(cgImage: line).colorAt(x: 40, y: 30)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(blue.blueComponent, 0.9)
        var arrow = Annotation(kind: "arrow", rect: UnitRect(), color: ColorValue(0, 0, 1))
        arrow.points = [CanvasPoint(x: 0.8, y: 0.8), CanvasPoint(x: 0.2, y: 0.2)]
        options.annotations = [arrow]
        let arrowImage = try NativeEngine().preview(files: [source], tool: .annotateImage, options: options)
        let tip = try XCTUnwrap(NSBitmapImageRep(cgImage: arrowImage).colorAt(x: 16, y: 12)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(tip.blueComponent, 0.5)
        var stamp = Annotation(kind: "image", rect: UnitRect(x: 0, y: 0, width: 0.5, height: 0.5))
        stamp.imageURL = source
        options.annotations = [stamp, Annotation(kind: "number", rect: UnitRect(x: 0.5, y: 0.5, width: 0.4, height: 0.4))]
        let stamped = try await perform(JobRequest(files: [source], operation: .tool(.annotateImage), options: options))
        XCTAssertNotEqual(try Data(contentsOf: source), try Data(contentsOf: stamped[0]))
    }

    func testCompressionHonorsReductionPercentageAndNeverPublishesUnreachableTarget() async throws {
        let source = try image()
        var data = try Data(contentsOf: source)
        data.append(Data(repeating: 0, count: 10_000))
        try data.write(to: source)
        var options = EditOptions()
        options.reduction = 99.999
        do {
            _ = try await perform(JobRequest(files: [source], operation: .tool(.compress), options: options))
            XCTFail("An unreachable size target must fail")
        } catch {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [source.lastPathComponent])
        XCTAssertEqual(try Data(contentsOf: source), data)
    }

    func testPDFCompressionReencodesImagesAndRetainsSelectableText() async throws {
        let source = directory.appendingPathComponent("large.pdf")
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: 800, height: 800, bitsPerComponent: 8, bytesPerRow: 3200, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let pixels = try XCTUnwrap(bitmap.data).assumingMemoryBound(to: UInt8.self)
        var random: UInt32 = 12345
        for index in 0..<(800 * 800) {
            for component in 0..<3 {
                random = 1664525 &* random &+ 1013904223
                pixels[index * 4 + component] = UInt8(truncatingIfNeeded: random >> 24)
            }
            pixels[index * 4 + 3] = 255
        }
        let data = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        var bounds = CGRect(x: 0, y: 0, width: 800, height: 840)
        let pdf = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &bounds, nil))
        pdf.beginPDFPage(nil)
        pdf.draw(try XCTUnwrap(bitmap.makeImage()), in: CGRect(x: 0, y: 0, width: 800, height: 800))
        pdf.textPosition = CGPoint(x: 20, y: 810)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: "Selectable text survives", attributes: [.font: NSFont.systemFont(ofSize: 20)]) as CFAttributedString), pdf)
        pdf.endPDFPage(); pdf.closePDF()
        try (data as Data).write(to: source)
        var options = EditOptions(); options.quality = 0.3; options.reduction = 50
        let result = try await perform(JobRequest(files: [source], operation: .tool(.compress), options: options))
        XCTAssertLessThan(try Data(contentsOf: result[0]).count, data.count / 2)
        XCTAssertTrue(PDFDocument(url: result[0])?.string?.contains("Selectable text survives") == true)
        XCTAssertEqual(try Data(contentsOf: source), data as Data)
    }

    func testSVGConvertsToEveryAdvertisedImageOutput() async throws {
        guard ProcessRunner.locate("magick") != nil else { throw XCTSkip("ImageMagick provides optional encoders") }
        let source = directory.appendingPathComponent("vector.svg")
        try Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="80" height="60"><rect width="80" height="60" fill="orange"/></svg>"#.utf8).write(to: source)
        for target in Catalog.outputs(for: [source]) {
            let result = try await perform(JobRequest(files: [source], operation: .convert(target)))
            if target == "pdf" {
                XCTAssertEqual(PDFDocument(url: result[0])?.pageCount, 1)
            } else {
                XCTAssertNotNil(CGImageSourceCreateWithURL(result[0] as CFURL, nil), target)
            }
        }
    }

    func testArchiveRejectsTraversalAbsolutePathsAndHardLinksBeforeExtraction() async throws {
        let source = directory.appendingPathComponent("hello.txt")
        try Data("hello".utf8).write(to: source)
        let traversal = directory.appendingPathComponent("traversal.tar")
        let absolute = directory.appendingPathComponent("absolute.tar")
        let hardArchive = directory.appendingPathComponent("hard.tar")
        let hardLink = directory.appendingPathComponent("hard.txt")
        try FileManager.default.linkItem(at: source, to: hardLink)
        let runner = ProcessRunner()
        let tar = URL(fileURLWithPath: "/usr/bin/tar")
        _ = try await runner.run(tar, arguments: ["-cf", traversal.path, "-s", ",^hello.txt$,../escaped.txt,", "-C", directory.path, "hello.txt"])
        _ = try await runner.run(tar, arguments: ["-cf", absolute.path, "-P", source.path])
        _ = try await runner.run(tar, arguments: ["-cf", hardArchive.path, "-C", directory.path, "hello.txt", "hard.txt"])
        for archive in [traversal, absolute, hardArchive] {
            do {
                _ = try await perform(JobRequest(files: [archive], operation: .tool(.extractArchive)))
                XCTFail("Unsafe archive must fail: \(archive.lastPathComponent)")
            } catch {}
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.deletingLastPathComponent().appendingPathComponent("escaped.txt").path))
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "hello")
    }

    func testCollageRowColumnAndFeaturedLayoutsHaveDistinctGeometry() async throws {
        let source = try image()
        var options = EditOptions(); options.canvasWidth = 300; options.padding = 10
        options.collageStyle = "row"
        let row = try NativeEngine().preview(files: [source, source, source], tool: .collage, options: options)
        XCTAssertEqual(row.height, 106)
        options.collageStyle = "column"
        let column = try NativeEngine().preview(files: [source, source, source], tool: .collage, options: options)
        XCTAssertEqual(column.height, 880)
        options.collageStyle = "featured"
        let featured = try NativeEngine().preview(files: [source, source, source], tool: .collage, options: options)
        XCTAssertEqual(featured.height, 203)
    }

    func testPDFWidthMatchingUsesNarrowestRenderedPageAndRotation() async throws {
        let source = try image()
        let created = try await perform(JobRequest(files: [source, source], operation: .tool(.createPDF)))
        let pdf = try XCTUnwrap(PDFDocument(url: created[0]))
        pdf.page(at: 0)?.setBounds(CGRect(x: 0, y: 0, width: 400, height: 200), for: .mediaBox)
        pdf.page(at: 1)?.setBounds(CGRect(x: 0, y: 0, width: 200, height: 300), for: .mediaBox)
        XCTAssertTrue(pdf.write(to: created[0]))
        var options = EditOptions(); options.matchPageWidth = true
        let output = try await perform(JobRequest(files: created, operation: .tool(.organizePDF), options: options))
        let organized = try XCTUnwrap(PDFDocument(url: output[0]))
        XCTAssertEqual(organized.page(at: 0)?.bounds(for: .mediaBox).width, 200)
        XCTAssertEqual(organized.page(at: 1)?.bounds(for: .mediaBox).width, 200)
        pdf.page(at: 0)?.rotation = 90
        XCTAssertTrue(pdf.write(to: created[0]))
        let rendered = try await perform(JobRequest(files: created, operation: .convert("png")))
        XCTAssertEqual(rendered.count, 1)
        let pages = try FileManager.default.contentsOfDirectory(at: rendered[0], includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertEqual(pages.count, 2)
        let rotatedImage = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: pages[0])))
        XCTAssertEqual(rotatedImage.pixelsWide, 833)
        XCTAssertEqual(rotatedImage.pixelsHigh, 1666)
    }

    func testLimitedPreviewsDownsampleLargeImagesAndKeepExportsAtFullSize() async throws {
        let source = directory.appendingPathComponent("large.png")
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: 2400, height: 1600, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.setFillColor(CGColor(red: 1, green: 0.4, blue: 0, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: 2400, height: 1600))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(source as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(bitmap.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        var options = EditOptions(); options.padding = 200; options.cornerRadius = 100; options.shadowRadius = 40
        let preview = try NativeEngine().preview(files: [source], tool: .background, options: options, maximumDimension: 1200)
        XCTAssertEqual(preview.width, 1200)
        XCTAssertEqual(Double(preview.width) / Double(preview.height), 1.4, accuracy: 0.003)
        let exported = try await perform(JobRequest(files: [source], operation: .tool(.background), options: options))
        let full = try XCTUnwrap(CGImageSourceCreateWithURL(exported[0] as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(full, 0, nil))
        XCTAssertEqual(image.width, 2800)
        XCTAssertEqual(image.height, 2000)
        options.width = 4000; options.height = 2000
        let resized = try NativeEngine().preview(files: [source], tool: .cropImage, options: options, maximumDimension: 1200)
        XCTAssertEqual(resized.width, 1200)
        XCTAssertEqual(resized.height, 600)
        options.collageStyle = "column"; options.canvasWidth = 4000
        let collage = try NativeEngine().preview(files: [source, source, source], tool: .collage, options: options, maximumDimension: 1200)
        XCTAssertLessThanOrEqual(max(collage.width, collage.height), 1200)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testEmptyPDFMetadataValueRemovesTheField() async throws {
        let source = try image()
        let pdf = try await perform(JobRequest(files: [source], operation: .tool(.createPDF)))
        var options = EditOptions(); options.metadata = ["Title": "Private title"]
        let titled = try await perform(JobRequest(files: pdf, operation: .tool(.metadata), options: options))
        options.metadata = ["Title": ""]
        let cleared = try await perform(JobRequest(files: titled, operation: .tool(.metadata), options: options))
        XCTAssertNil(PDFDocument(url: cleared[0])?.documentAttributes?[PDFDocumentAttribute.titleAttribute])
        XCTAssertEqual(PDFDocument(url: titled[0])?.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, "Private title")
    }

    func testPDFPageGroupsAvoidCollisionsAndPublishOnlyWhenComplete() async throws {
        let image = try self.image()
        let created = try await perform(JobRequest(files: [image, image], operation: .tool(.createPDF)))
        let first = try await perform(JobRequest(files: created, operation: .convert("png")))
        let second = try await perform(JobRequest(files: created, operation: .convert("png")))
        XCTAssertNotEqual(first[0], second[0])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: first[0].path).count, 2)
        let pdf = try XCTUnwrap(PDFDocument(url: created[0]))
        pdf.page(at: 1)?.setBounds(CGRect(x: 0, y: 0, width: 40_000, height: 40_000), for: .mediaBox)
        XCTAssertTrue(pdf.write(to: created[0]))
        let before = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        let original = try Data(contentsOf: created[0])
        do {
            _ = try await perform(JobRequest(files: created, operation: .convert("png")))
            XCTFail("An oversized later page must fail the complete group")
        } catch {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(), before)
        XCTAssertEqual(try Data(contentsOf: created[0]), original)
    }

}
