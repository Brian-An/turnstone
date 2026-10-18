import XCTest
import AppKit
@testable import TurnstoneCore

final class ConversionEngineTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    func testDispatchesRealDocumentConversionAndPreservesSource() async throws {
        let source = try fixture()
        let output = try await ConversionEngine().run(JobRequest(files: [source], operation: .convert("docx")), context: ExecutionContext())
        XCTAssertEqual(output.count, 1)
        XCTAssertEqual(try Data(contentsOf: output[0]).prefix(2), Data([0x50, 0x4b]))
        XCTAssertEqual(try String(contentsOf: source), "Preserved input")
    }

    func testRejectsMissingFilesFoldersUnknownRoutesAndInapplicableTools() async throws {
        let source = try fixture()
        let cases = [JobRequest(files: [], operation: .convert("docx")),
                     JobRequest(files: [directory.appendingPathComponent("missing.txt")], operation: .convert("docx")),
                     JobRequest(files: [directory], operation: .convert("docx")),
                     JobRequest(files: [source], operation: .convert("mp3")),
                     JobRequest(files: [source], operation: .tool(.trimVideo)),
                     JobRequest(files: [source], operation: .tool(.mergePDF))]
        for request in cases { await rejects(request) }
        XCTAssertEqual(try String(contentsOf: source), "Preserved input")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["input.txt"])
    }

    func testRejectsNonfiniteAndOutOfBoundsOptionsBeforePublishing() async throws {
        let source = try fixture()
        var invalid: [EditOptions] = []
        var options = EditOptions(); options.quality = .nan; invalid.append(options)
        options = EditOptions(); options.photo.gamma = .infinity; invalid.append(options)
        options = EditOptions(); options.crop = UnitRect(x: 0.9, width: 0.2); invalid.append(options)
        options = EditOptions(); options.width = 0; invalid.append(options)
        options = EditOptions(); options.width = 16385; invalid.append(options)
        options = EditOptions(); options.speed = 0; invalid.append(options)
        options = EditOptions(); options.ranges = [TimeRange(start: 2, end: 1)]; invalid.append(options)
        options = EditOptions()
        var annotation = Annotation(kind: "pen", rect: UnitRect())
        annotation.points = [CanvasPoint(x: .nan, y: 0), CanvasPoint(x: 1, y: 1)]
        options.annotations = [annotation]; invalid.append(options)
        for options in invalid { await rejects(JobRequest(files: [source], operation: .convert("docx"), options: options)) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["input.txt"])
    }

    func testMixedSourcesDispatchToTheirOwnEngines() async throws {
        let source = try fixture()
        let engine = ConversionEngine()
        let pdfs = try await engine.run(JobRequest(files: [source], operation: .convert("pdf")), context: ExecutionContext())
        let images = try await engine.run(JobRequest(files: pdfs, operation: .convert("png")), context: ExecutionContext())
        let outputs = try await engine.run(JobRequest(files: [pdfs[0], images[0]], operation: .convert("jpg")), context: ExecutionContext())
        XCTAssertEqual(outputs.count, 2)
        XCTAssertTrue(outputs.allSatisfy { NSImage(contentsOf: $0) != nil })
    }

    func testCancellationStopsBeforeConversion() async throws {
        let source = try fixture()
        let context = try ExecutionContext(); context.runner.cancel()
        do {
            _ = try await ConversionEngine().run(JobRequest(files: [source], operation: .convert("docx")), context: context)
            XCTFail("Cancelled job must fail")
        } catch is CancellationError {} catch { XCTFail("Expected cancellation, got \(error)") }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["input.txt"])
    }

    private func fixture() throws -> URL {
        let source = directory.appendingPathComponent("input.txt")
        try "Preserved input".write(to: source, atomically: true, encoding: .utf8)
        return source
    }

    private func rejects(_ request: JobRequest, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await ConversionEngine().run(request, context: ExecutionContext())
            XCTFail("Invalid request must fail", file: file, line: line)
        } catch {}
    }
}
