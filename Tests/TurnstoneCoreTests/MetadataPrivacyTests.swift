import AppKit
import PDFKit
import XCTest
@testable import TurnstoneCore

final class MetadataPrivacyTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("Turnstone-MetadataPrivacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    func testPDFRemovalOverridesRetainedPrivateEditsAndPreservesSource() async throws {
        let image = try makeImage()
        let source = try await perform(image, operation: .convert("pdf"))
        var options = EditOptions()
        options.metadata = ["Title": "Original private PDF title"]
        let tagged = try await perform(source, operation: .tool(.metadata), options: options)
        XCTAssertEqual(PDFDocument(url: tagged)?.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, "Original private PDF title")
        let original = try Data(contentsOf: tagged)
        options.metadata = ["Title": "Pending private PDF edit"]
        options.removeAllMetadata = true
        let removed = try await perform(tagged, operation: .tool(.metadata), options: options)
        XCTAssertNil(PDFDocument(url: removed)?.documentAttributes?[PDFDocumentAttribute.titleAttribute])
        XCTAssertEqual(try Data(contentsOf: tagged), original)
        options.removeAllMetadata = false
        let edited = try await perform(tagged, operation: .tool(.metadata), options: options)
        XCTAssertEqual(PDFDocument(url: edited)?.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, "Pending private PDF edit")
    }

    func testImageAndBothMediaBackendsRemoveMetadataDespiteRetainedEdits() async throws {
        guard let exiftool = ProcessRunner.locate("exiftool"), let ffmpeg = ProcessRunner.locate("ffmpeg") else {
            throw XCTSkip("ExifTool and FFmpeg are required")
        }
        let image = try makeImage()
        let jpeg = try await perform(image, operation: .convert("jpg"))
        var sources = [jpeg]
        for ext in ["m4a", "flac"] {
            let source = directory.appendingPathComponent("audio.\(ext)")
            _ = try await ProcessRunner().run(ffmpeg, arguments: ["-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=1", source.path])
            sources.append(source)
        }
        for source in sources {
            let field = source.pathExtension == "jpg" ? "Artist" : "Title"
            var options = EditOptions()
            options.metadata = [field: "Original private metadata"]
            let tagged = try await perform(source, operation: .tool(.metadata), options: options)
            let original = try Data(contentsOf: tagged)
            let initial = try await ProcessRunner().run(exiftool, arguments: ["-s3", "-\(field)", tagged.path])
            XCTAssertEqual(initial.trimmingCharacters(in: .whitespacesAndNewlines), "Original private metadata")
            options.metadata = [field: "Pending private metadata"]
            options.removeAllMetadata = true
            let removed = try await perform(tagged, operation: .tool(.metadata), options: options)
            let value = try await ProcessRunner().run(exiftool, arguments: ["-s3", "-\(field)", removed.path])
            XCTAssertTrue(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, source.pathExtension)
            XCTAssertEqual(try Data(contentsOf: tagged), original)
            options.removeAllMetadata = false
            let edited = try await perform(tagged, operation: .tool(.metadata), options: options)
            let retained = try await ProcessRunner().run(exiftool, arguments: ["-s3", "-\(field)", edited.path])
            XCTAssertEqual(retained.trimmingCharacters(in: .whitespacesAndNewlines), "Pending private metadata")
        }
    }

    private func perform(_ source: URL, operation: FileOperation, options: EditOptions = EditOptions()) async throws -> URL {
        let outputs = try await ConversionEngine().run(JobRequest(files: [source], operation: operation, options: options), context: ExecutionContext())
        return try XCTUnwrap(outputs.first)
    }

    private func makeImage() throws -> URL {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let color = NSColor(deviceRed: 1, green: 0.4, blue: 0, alpha: 1)
        for y in 0..<8 { for x in 0..<8 { bitmap.setColor(color, atX: x, y: y) } }
        let source = directory.appendingPathComponent("image.png")
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: source)
        return source
    }
}
