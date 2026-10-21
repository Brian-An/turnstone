import AppKit
import Combine
import XCTest
import TurnstoneCore
@testable import Turnstone

final class UtilityFeatureTests: XCTestCase {
    @MainActor
    func testBatchJobKeepsSuccessfulOutputsAndReportsEachFailedFile() async throws {
        _ = NSApplication.shared
        Windows.close("jobs")
        let folder = try fixtureFolder()
        defer { Windows.close("jobs"); try? FileManager.default.removeItem(at: folder) }
        let first = try image(in: folder, name: "first.png")
        let second = try image(in: folder, name: "second.png")
        let broken = folder.appendingPathComponent("broken.png")
        try Data("not an image".utf8).write(to: broken)
        let files = [first, broken, second]
        let originals = try files.map { try Data(contentsOf: $0) }
        let model = AppModel()
        model.submit(JobRequest(files: files, operation: .convert("jpg")))
        let job = try XCTUnwrap(model.jobs.first)
        await finish(job)
        XCTAssertEqual(job.outputs.count, 2)
        XCTAssertEqual(job.errors.count, 1)
        XCTAssertTrue(try XCTUnwrap(job.errors.first).contains("broken.png"))
        XCTAssertEqual(job.fraction, 1)
        XCTAssertEqual(job.message, "Finished with errors")
        XCTAssertTrue(NSApp.windows.contains { $0.title == "Conversion Jobs" && $0.isVisible })
        XCTAssertEqual(try files.map { try Data(contentsOf: $0) }, originals)
        for output in job.outputs { XCTAssertNotNil(NSBitmapImageRep(data: try Data(contentsOf: output))) }
    }

    @MainActor
    func testImmediateJobCancellationPreservesSourcesAndSkipsRemainingFiles() async throws {
        _ = NSApplication.shared
        Windows.close("jobs")
        let folder = try fixtureFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = try (0..<4).map { try image(in: folder, name: "image\($0).png") }
        let originals = try files.map { try Data(contentsOf: $0) }
        let model = AppModel()
        model.submit(JobRequest(files: files, operation: .convert("jpg")))
        let job = try XCTUnwrap(model.jobs.first)
        job.cancel()
        await finish(job)
        XCTAssertTrue(job.cancelled)
        XCTAssertEqual(job.message, "Cancelled")
        XCTAssertTrue(job.outputs.isEmpty)
        XCTAssertTrue(job.errors.isEmpty)
        XCTAssertFalse(NSApp.windows.contains { $0.title == "Conversion Jobs" && $0.isVisible })
        XCTAssertEqual(try files.map { try Data(contentsOf: $0) }, originals)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).contains { $0.pathExtension == "jpg" })
    }

    @MainActor
    func testCopyActionsPublishFilesAndLiteralPaths() throws {
        let folder = try fixtureFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = try ["first image.png", "second.png"].map { try image(in: folder, name: $0) }
        let board = NSPasteboard.general
        let saved = board.pasteboardItems?.map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        } ?? []
        defer {
            board.clearContents()
            let items = saved.map { values in
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            }
            if !items.isEmpty { board.writeObjects(items) }
        }
        let model = AppModel()
        model.perform(.copy, files: files)
        XCTAssertEqual(WheelController.files(from: board), files)
        model.perform(.copyPath, files: files)
        XCTAssertEqual(board.string(forType: .string), files.map(\.path).joined(separator: "\n"))
        XCTAssertTrue(WheelController.files(from: board).isEmpty)
        XCTAssertTrue(files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    @MainActor
    func testFloatingShelfDeduplicatesAndRemovingEntryKeepsOriginal() throws {
        _ = NSApplication.shared
        let folder = try fixtureFolder()
        defer { Windows.close("shelf"); try? FileManager.default.removeItem(at: folder) }
        let first = try image(in: folder, name: "first.png")
        let second = try image(in: folder, name: "second.png")
        let model = AppModel()
        model.perform(.float, files: [second, first, second])
        model.perform(.float, files: [first])
        XCTAssertEqual(model.shelfFiles, [first, second])
        XCTAssertTrue(NSApp.windows.contains { $0.title == "Floating Shelf" && $0.isVisible })
        model.shelfFiles.removeAll { $0 == first }
        XCTAssertEqual(model.shelfFiles, [second])
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }

    @MainActor
    private func finish(_ job: ConversionJob) async {
        if job.finished { return }
        let completed = expectation(description: "Job reaches its final state")
        let observation = job.$finished.filter { $0 }.prefix(1).sink { _ in completed.fulfill() }
        defer { observation.cancel() }
        await fulfillment(of: [completed], timeout: 10)
        XCTAssertTrue(job.finished)
    }
    private func fixtureFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("turnstone-utility-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
    private func image(in folder: URL, name: String) throws -> URL {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.bitmapData?.initialize(repeating: 0, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        let file = folder.appendingPathComponent(name)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: file)
        return file
    }
}
