import AppKit
import XCTest
import TurnstoneCore
@testable import Turnstone

final class EditorLayoutTests: XCTestCase {
    @MainActor
    func testBackgroundControlsFitAtDefaultWindowSizeWithoutGutter() throws {
        let source = try fixture()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let window = try open(.tool(.background), files: [source])
        defer { window.close() }
        XCTAssertLessThanOrEqual(window.frame.width, 560)
        XCTAssertLessThanOrEqual(window.frame.height, 660)
        let scrollViews = descendants(try XCTUnwrap(window.contentView)).compactMap { $0 as? NSScrollView }
        XCTAssertFalse(scrollViews.isEmpty)
        for scroll in scrollViews {
            XCTAssertEqual(scroll.scrollerStyle, .overlay)
            XCTAssertTrue(scroll.autohidesScrollers)
            scroll.scrollerStyle = .legacy
            XCTAssertEqual(scroll.scrollerStyle, .overlay, "Input-device updates must retain the overlay style")
            let document = try XCTUnwrap(scroll.documentView)
            XCTAssertLessThanOrEqual(document.frame.height, scroll.contentView.bounds.height + 1, "The default background controls should all fit")
        }
    }

    @MainActor
    func testSimpleToolsOpenInSmallWindows() throws {
        let source = try fixture()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        for (operation, files) in [(FileOperation.tool(.compress), [source]), (.tool(.createPDF), [source, source]), (.convert("epub"), [source])] {
            let window = try open(operation, files: files)
            XCTAssertLessThanOrEqual(window.frame.width, 520, operation.title)
            XCTAssertLessThanOrEqual(window.frame.height, 500, operation.title)
            window.close()
        }
    }

    @MainActor
    private func open(_ operation: FileOperation, files: [URL]) throws -> NSWindow {
        _ = NSApplication.shared
        let model = AppModel()
        model.edit(files, operation: operation)
        let window = try XCTUnwrap(NSApp.windows.first { $0.title == operation.title && $0.isVisible })
        for _ in 0..<5 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            window.contentView?.layoutSubtreeIfNeeded()
        }
        return window
    }

    @MainActor
    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func fixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Turnstone-EditorLayout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let image = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 48, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        image.bitmapData?.initialize(repeating: 0, count: image.bytesPerRow * image.pixelsHigh)
        let source = directory.appendingPathComponent("sample.png")
        try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: source)
        return source
    }
}
