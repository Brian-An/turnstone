import XCTest
import AppKit
import CoreText
import ImageIO
import PDFKit
@testable import TurnstoneCore

final class NativeFeatureCoverageTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("NativeCoverage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func run(_ files: [URL], _ operation: FileOperation, options: EditOptions = EditOptions()) async throws -> [URL] {
        try await ConversionEngine().run(JobRequest(files: files, operation: operation, options: options), context: ExecutionContext())
    }

    private func image(_ name: String = "image.png", text: String? = nil) throws -> URL {
        let width = text == nil ? 96 : 1000, height = text == nil ? 64 : 240
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(text == nil ? CGColor(red: 1, green: 0.1, blue: 0, alpha: 1) : CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if let text {
            context.textPosition = CGPoint(x: 30, y: 90)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 72), .foregroundColor: NSColor.black]) as CFAttributedString), context)
        } else {
            context.setFillColor(CGColor(red: 0, green: 0.1, blue: 1, alpha: 1))
            context.fill(CGRect(x: width / 2, y: 0, width: width / 2, height: height))
        }
        let url = directory.appendingPathComponent(name)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func pdf(_ name: String = "pages.pdf") throws -> URL {
        let data = NSMutableData()
        var bounds = CGRect(x: 0, y: 0, width: 200, height: 100)
        let context = try XCTUnwrap(CGContext(consumer: XCTUnwrap(CGDataConsumer(data: data)), mediaBox: &bounds, nil))
        for text in ["First page", "Second page", "Third page"] {
            context.beginPDFPage(nil)
            context.textPosition = CGPoint(x: 15, y: 40)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 18)]) as CFAttributedString), context)
            context.endPDFPage()
        }
        context.closePDF()
        let url = directory.appendingPathComponent(name)
        try (data as Data).write(to: url)
        return url
    }

    func testExplicitSinglePagePDFRangeUsesInclusivePageNumbers() async throws {
        let source = try pdf()
        var options = EditOptions()
        options.ranges = [TimeRange(start: 2, end: 2)]
        let output = try await run([source], .tool(.splitPDF), options: options)
        let parts = try FileManager.default.contentsOfDirectory(at: output[0], includingPropertiesForKeys: nil)
        XCTAssertEqual(parts.count, 1)
        let part = try XCTUnwrap(PDFDocument(url: parts[0]))
        XCTAssertEqual(part.pageCount, 1)
        XCTAssertTrue(part.string?.contains("Second page") == true)
    }

    func testEveryRasterImageRoutePreservesDimensionsPixelsAndSources() async throws {
        guard ProcessRunner.locate("magick") != nil else { throw XCTSkip("ImageMagick is required for optional image encoders") }
        let original = try image()
        var sources = [original]
        for target in ["jpg", "webp", "heic", "tiff", "avif", "bmp"] {
            sources += try await run([original], .convert(target))
        }
        for source in sources {
            let originalBytes = try Data(contentsOf: source)
            for target in Catalog.outputs(for: [source]) {
                let output = try await run([source], .convert(target))
                XCTAssertEqual(output.count, 1)
                if target == "pdf" {
                    let document = try XCTUnwrap(PDFDocument(url: output[0]))
                    XCTAssertEqual(document.pageCount, 1)
                    XCTAssertEqual(document.page(at: 0)?.bounds(for: .mediaBox).size, CGSize(width: 96, height: 64))
                } else {
                    let decoder = try XCTUnwrap(CGImageSourceCreateWithURL(output[0] as CFURL, nil), "\(source.pathExtension) -> \(target)")
                    let pixels = try XCTUnwrap(CGImageSourceCreateImageAtIndex(decoder, 0, nil))
                    XCTAssertEqual(pixels.width, 96)
                    XCTAssertEqual(pixels.height, 64)
                    let bitmap = NSBitmapImageRep(cgImage: pixels)
                    let red = try XCTUnwrap(bitmap.colorAt(x: 10, y: 20)?.usingColorSpace(.deviceRGB))
                    let blue = try XCTUnwrap(bitmap.colorAt(x: 80, y: 20)?.usingColorSpace(.deviceRGB))
                    XCTAssertGreaterThan(red.redComponent, red.blueComponent + 0.5, "\(source.pathExtension) -> \(target)")
                    XCTAssertGreaterThan(blue.blueComponent, blue.redComponent + 0.5, "\(source.pathExtension) -> \(target)")
                }
            }
            XCTAssertEqual(try Data(contentsOf: source), originalBytes)
        }
    }

    func testImageMetadataCanBeWrittenRemovedAndStrippedFromRedaction() async throws {
        guard let exiftool = ProcessRunner.locate("exiftool") else { throw XCTSkip("ExifTool is required for image metadata editing") }
        let source = try await run([image()], .convert("jpg"))[0]
        let originalBytes = try Data(contentsOf: source)
        var options = EditOptions()
        options.metadata = ["Artist": "Private Artist", "GPSLatitude": "43.65", "GPSLongitude": "79.38"]
        let tagged = try await run([source], .tool(.metadata), options: options)[0]
        let artist = try await ProcessRunner().run(exiftool, arguments: ["-s3", "-Artist", tagged.path])
        XCTAssertEqual(artist.trimmingCharacters(in: .whitespacesAndNewlines), "Private Artist")
        options = EditOptions(); options.removeAllMetadata = true
        let cleared = try await run([tagged], .tool(.metadata), options: options)[0]
        let removed = try await ProcessRunner().run(exiftool, arguments: ["-s3", "-Artist", "-GPSLatitude", "-GPSLongitude", cleared.path])
        XCTAssertTrue(removed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        options = EditOptions(); options.redactions = [Redaction(rect: UnitRect(x: 0, y: 0, width: 0.5, height: 1))]
        let redacted = try await run([tagged], .tool(.redactImage), options: options)[0]
        let redactionMetadata = try await ProcessRunner().run(exiftool, arguments: ["-s3", "-Artist", "-GPSLatitude", "-GPSLongitude", redacted.path])
        XCTAssertTrue(redactionMetadata.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertEqual(try Data(contentsOf: source), originalBytes)
        let taggedArtist = try await ProcessRunner().run(exiftool, arguments: ["-s3", "-Artist", tagged.path])
        XCTAssertEqual(taggedArtist.trimmingCharacters(in: .whitespacesAndNewlines), "Private Artist")
    }

    func testCropAndCompressionWorkAcrossEveryEditableImageFormat() async throws {
        guard ProcessRunner.locate("magick") != nil else { throw XCTSkip("ImageMagick is required for the WebP encoder") }
        let png = try image()
        for format in ["png", "jpg", "webp", "heic", "tiff"] {
            let source = format == "png" ? png : try await run([png], .convert(format))[0]
            var original = try Data(contentsOf: source)
            original.append(Data(repeating: 0, count: max(20_000, original.count * 3)))
            try original.write(to: source)
            var options = EditOptions(); options.crop = UnitRect(x: 0.5, y: 0, width: 0.5, height: 1)
            let cropped = try await run([source], .tool(.cropImage), options: options)[0]
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: cropped)), format)
            XCTAssertEqual(bitmap.pixelsWide, 48)
            XCTAssertEqual(bitmap.pixelsHigh, 64)
            let pixel = try XCTUnwrap(bitmap.colorAt(x: 20, y: 20)?.usingColorSpace(.deviceRGB))
            XCTAssertGreaterThan(pixel.blueComponent, pixel.redComponent + 0.5, format)
            options = EditOptions(); options.reduction = 50
            do {
                let compressed = try await run([source], .tool(.compress), options: options)[0]
                XCTAssertLessThan(try Data(contentsOf: compressed).count, original.count / 2, format)
                XCTAssertNotNil(NSBitmapImageRep(data: try Data(contentsOf: compressed)), format)
            } catch { XCTFail("Compression of \(format) (\(original.count) source bytes): \(error)") }
            XCTAssertEqual(try Data(contentsOf: source), original)
        }
    }

    func testOrientedJPEGConversionsAndCropUseDisplayedDimensions() async throws {
        let source = try image()
        let original = try XCTUnwrap(CGImageSourceCreateWithURL(source as CFURL, nil))
        let oriented = directory.appendingPathComponent("portrait.jpg")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(oriented as CFURL, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(CGImageSourceCreateImageAtIndex(original, 0, nil)), [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let png = try await run([oriented], .convert("png"))[0]
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: png)))
        XCTAssertEqual(bitmap.pixelsWide, 64)
        XCTAssertEqual(bitmap.pixelsHigh, 96)
        var options = EditOptions(); options.crop = UnitRect(x: 0, y: 0, width: 1, height: 0.5)
        let cropped = try await run([oriented], .tool(.cropImage), options: options)[0]
        let crop = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: cropped)))
        XCTAssertEqual(crop.pixelsWide, 64)
        XCTAssertEqual(crop.pixelsHigh, 48)
    }

    func testImageAndGradientBackgroundsAndBlurRedactionRenderTheirEffects() async throws {
        let source = try image()
        var options = EditOptions(); options.padding = 20; options.shadowRadius = 0; options.cornerRadius = 0
        options.backgroundStyle = "gradient"
        let gradient = try await run([source], .tool(.background), options: options)[0]
        let pixels = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: gradient)))
        let first = try XCTUnwrap(pixels.colorAt(x: 3, y: 100)?.usingColorSpace(.deviceRGB))
        let last = try XCTUnwrap(pixels.colorAt(x: 130, y: 3)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(abs(first.redComponent - last.redComponent), 0.3)
        options.backgroundStyle = "image"; options.backgroundImage = source
        let backdrop = try await run([source], .tool(.background), options: options)[0]
        let background = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: backdrop)))
        let red = try XCTUnwrap(background.colorAt(x: 3, y: 3)?.usingColorSpace(.deviceRGB))
        let blue = try XCTUnwrap(background.colorAt(x: 130, y: 100)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(red.redComponent, 0.8)
        XCTAssertGreaterThan(blue.blueComponent, 0.8)
        options = EditOptions(); options.blur = true; options.redactions = [Redaction(rect: UnitRect())]
        let blurred = try await run([source], .tool(.redactImage), options: options)[0]
        let blurPixels = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: blurred)))
        let boundary = try XCTUnwrap(blurPixels.colorAt(x: 45, y: 32)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(boundary.redComponent, 0.2)
        XCTAssertGreaterThan(boundary.blueComponent, 0.2)
    }

    func testScannedPDFAndImageTextDetectionRecognizeVisibleContent() async throws {
        let source = try image("scan.png", text: "TURNSTONE TEST")
        let rectangles = try await NativeEngine.detectRedactions(in: source, faces: false)
        XCTAssertFalse(rectangles.isEmpty)
        for rect in rectangles {
            XCTAssertGreaterThan(rect.width, 0)
            XCTAssertGreaterThan(rect.height, 0)
            XCTAssertGreaterThanOrEqual(rect.x, 0)
            XCTAssertGreaterThanOrEqual(rect.y, 0)
            XCTAssertLessThanOrEqual(rect.x + rect.width, 1)
            XCTAssertLessThanOrEqual(rect.y + rect.height, 1)
        }
        let faces = try await NativeEngine.detectRedactions(in: source, faces: true)
        XCTAssertTrue(faces.isEmpty)
        let scannedPDF = try await run([source], .convert("pdf"))[0]
        for target in ["txt", "md"] {
            let output = try await run([scannedPDF], .convert(target))[0]
            XCTAssertTrue(try String(contentsOf: output, encoding: .utf8).contains("TURNSTONE TEST"))
        }
    }

    func testPDFSplitRangesAndMergeRetainOrderedPageText() async throws {
        let source = try pdf()
        let original = try Data(contentsOf: source)
        var options = EditOptions()
        options.ranges = [TimeRange(start: 2, end: 3), TimeRange(start: 1, end: 2)]
        let output = try await run([source], .tool(.splitPDF), options: options)[0]
        let parts = try FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(PDFDocument(url: parts[0])?.pageCount, 2)
        XCTAssertTrue(PDFDocument(url: parts[0])?.page(at: 0)?.string?.contains("Second page") == true)
        XCTAssertTrue(PDFDocument(url: parts[0])?.page(at: 1)?.string?.contains("Third page") == true)
        let merged = try await run(parts, .tool(.mergePDF))[0]
        let document = try XCTUnwrap(PDFDocument(url: merged))
        XCTAssertEqual(document.pageCount, 4)
        for (index, text) in ["Second page", "Third page", "First page", "Second page"].enumerated() {
            XCTAssertTrue(document.page(at: index)?.string?.contains(text) == true)
        }
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testInvalidAndLockedPDFsNeverPublishOutput() async throws {
        let valid = try pdf()
        let malformed = directory.appendingPathComponent("broken.pdf")
        try Data("not a PDF".utf8).write(to: malformed)
        let locked = directory.appendingPathComponent("locked.pdf")
        let document = try XCTUnwrap(PDFDocument(url: valid))
        XCTAssertTrue(document.write(to: locked, withOptions: [.userPasswordOption: "secret", .ownerPasswordOption: "owner"]))
        let before = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        for source in [malformed, locked] {
            for operation in [FileOperation.convert("jpg"), .convert("txt"), .tool(.splitPDF), .tool(.organizePDF), .tool(.compress)] {
                do {
                    _ = try await run([source], operation)
                    XCTFail("Invalid PDF must be rejected: \(source.lastPathComponent), \(operation)")
                } catch {}
            }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(), before)
    }

    func testInvalidPDFPageRangesAreRejectedBeforePublishing() async throws {
        let source = try pdf()
        let before = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        for range in [TimeRange(start: 1.5, end: 2.5), TimeRange(start: 0, end: 2), TimeRange(start: 3, end: 2), TimeRange(start: 1, end: 4)] {
            var options = EditOptions(); options.ranges = [range]
            do {
                _ = try await run([source], .tool(.splitPDF), options: options)
                XCTFail("Invalid PDF page range must be rejected")
            } catch {}
            do {
                _ = try await NativeEngine().perform(JobRequest(files: [source], operation: .tool(.splitPDF), options: options), context: ExecutionContext())
                XCTFail("Native PDF splitting must reject invalid page ranges")
            } catch {}
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(), before)
    }

    func testArchiveConversionMatrixRetainsNestedUnicodeAndHiddenFiles() async throws {
        let payload = directory.appendingPathComponent("payload")
        let nested = payload.appendingPathComponent("nested folder")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("Unicode contents: café 🦊".utf8).write(to: nested.appendingPathComponent("résumé.txt"))
        try Data("hidden settings".utf8).write(to: payload.appendingPathComponent(".settings"))
        try FileManager.default.createDirectory(at: payload.appendingPathComponent("empty"), withIntermediateDirectories: true)
        let tar = directory.appendingPathComponent("bundle.tar")
        _ = try await ProcessRunner().run(URL(fileURLWithPath: "/usr/bin/tar"), arguments: ["-cf", tar.path, "-C", payload.path, "."])
        var sources = [tar]
        for target in ["zip", "gz"] { sources += try await run([tar], .convert(target)) }
        for source in sources {
            let original = try Data(contentsOf: source)
            for target in Catalog.outputs(for: [source]) {
                let converted = try await run([source], .convert(target))[0]
                let extracted = try await run([converted], .tool(.extractArchive))[0]
                XCTAssertEqual(try String(contentsOf: extracted.appendingPathComponent("nested folder/résumé.txt"), encoding: .utf8), "Unicode contents: café 🦊")
                XCTAssertEqual(try String(contentsOf: extracted.appendingPathComponent(".settings"), encoding: .utf8), "hidden settings")
                XCTAssertEqual(try extracted.appendingPathComponent("empty").resourceValues(forKeys: [.isDirectoryKey]).isDirectory, true)
            }
            XCTAssertEqual(try Data(contentsOf: source), original)
        }
    }

    func testStoredRARExtractsAndConvertsToEveryAdvertisedArchive() async throws {
        let source = directory.appendingPathComponent("stored.rar")
        try storedRAR(name: "hello.txt", contents: Data("RAR payload".utf8)).write(to: source)
        let original = try Data(contentsOf: source)
        let extracted = try await run([source], .tool(.extractArchive))[0]
        XCTAssertEqual(try String(contentsOf: extracted.appendingPathComponent("hello.txt"), encoding: .utf8), "RAR payload")
        for target in ["zip", "tar", "gz"] {
            let converted = try await run([source], .convert(target))[0]
            let unpacked = try await run([converted], .tool(.extractArchive))[0]
            XCTAssertEqual(try String(contentsOf: unpacked.appendingPathComponent("hello.txt"), encoding: .utf8), "RAR payload")
        }
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testMalformedEmptyAndSpecialFileArchivesDoNotPublish() async throws {
        var archives: [URL] = []
        for ext in ["zip", "tar", "gz", "rar"] {
            let source = directory.appendingPathComponent("broken.\(ext)")
            try Data("not an archive".utf8).write(to: source)
            archives.append(source)
        }
        let empty = directory.appendingPathComponent("empty.tar")
        _ = try await ProcessRunner().run(URL(fileURLWithPath: "/usr/bin/tar"), arguments: ["-cf", empty.path, "-T", "/dev/null"])
        archives.append(empty)
        let fifo = directory.appendingPathComponent("pipe")
        _ = try await ProcessRunner().run(URL(fileURLWithPath: "/usr/bin/mkfifo"), arguments: [fifo.path])
        let special = directory.appendingPathComponent("special.tar")
        _ = try await ProcessRunner().run(URL(fileURLWithPath: "/usr/bin/tar"), arguments: ["-cf", special.path, "-C", directory.path, "pipe"])
        archives.append(special)
        let before = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        for archive in archives {
            do {
                _ = try await run([archive], .tool(.extractArchive))
                XCTFail("Unsafe or malformed archive must fail: \(archive.lastPathComponent)")
            } catch {}
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(), before)
    }

    // A stored RAR 4 entry exercises the decoder without an optional proprietary archiver.
    private func storedRAR(name: String, contents: Data) -> Data {
        func littleEndian(_ value: UInt32, bytes: Int) -> Data {
            Data((0..<bytes).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
        }
        func crc32(_ data: Data) -> UInt32 {
            var crc: UInt32 = 0xffff_ffff
            for byte in data {
                crc ^= UInt32(byte)
                for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xedb8_8320 : 0) }
            }
            return ~crc
        }
        func header(type: UInt8, flags: UInt32, fields: Data) -> Data {
            let body = Data([type]) + littleEndian(flags, bytes: 2) + littleEndian(UInt32(fields.count + 7), bytes: 2) + fields
            return littleEndian(crc32(body), bytes: 2) + body
        }
        var fields = littleEndian(UInt32(contents.count), bytes: 4) + littleEndian(UInt32(contents.count), bytes: 4)
        fields.append(3)
        fields += littleEndian(crc32(contents), bytes: 4) + littleEndian(0, bytes: 4)
        fields += Data([20, 0x30]) + littleEndian(UInt32(name.utf8.count), bytes: 2) + littleEndian(0x81a4, bytes: 4) + Data(name.utf8)
        return Data([0x52, 0x61, 0x72, 0x21, 0x1a, 0x07, 0x00])
            + header(type: 0x73, flags: 0, fields: Data(repeating: 0, count: 6))
            + header(type: 0x74, flags: 0x8000, fields: fields) + contents
            + header(type: 0x7b, flags: 0x4000, fields: Data())
    }
}
