import AppKit
import Combine
import XCTest
import TurnstoneCore
@testable import Turnstone

final class InteractionTests: XCTestCase {
    @MainActor
    func testSubmittingConversionDoesNotOpenRecentJobs() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory); Windows.close("jobs") }
        let source = directory.appendingPathComponent("sample.png")
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: source)

        let model = AppModel()
        model.submit(JobRequest(files: [source], operation: .convert("jpg")))
        let job = try XCTUnwrap(model.jobs.first)
        let completed = expectation(description: "Conversion finishes")
        let observation = job.$finished.filter { $0 }.prefix(1).sink { _ in completed.fulfill() }
        defer { observation.cancel() }
        await fulfillment(of: [completed], timeout: 10)

        XCTAssertTrue(job.errors.isEmpty, "\(job.errors)")
        XCTAssertEqual(job.outputs.count, 1)
        XCTAssertFalse(NSApp.windows.contains { $0.title == "Conversion Jobs" && $0.isVisible })
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    @MainActor
    func testHighlightedPetalKeepsItsPoppedOutEdgeSelectable() {
        let canvas = WheelCanvas(frame: NSRect(x: 0, y: 0, width: 328, height: 354))
        canvas.entries = ["jpg", "png", "webp", "pdf"].map(WheelEntry.format)
        for index in 0..<4 {
            canvas.selected = index
            let angle = Double(90 - index * 90) * .pi / 180
            canvas.updateSelection(NSPoint(x: 164 + cos(angle) * 142, y: 181 + sin(angle) * 142))
            XCTAssertEqual(canvas.selected, NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : index)
            canvas.updateSelection(NSPoint(x: 164 + cos(angle) * 150, y: 181 + sin(angle) * 150))
            XCTAssertNil(canvas.selected, "The subtle highlight must not retain an oversized outer target")
        }
        canvas.updateSelection(NSPoint(x: 264, y: 181))
        XCTAssertEqual(canvas.selected, 1)
        canvas.updateSelection(NSPoint(x: 164, y: 181))
        XCTAssertNil(canvas.selected)
        canvas.updateSelection(NSPoint(x: 164, y: 331))
        XCTAssertNil(canvas.selected, "An inactive slice must not acquire selection outside its normal target")
    }
}
