import AppKit
import XCTest
@testable import Turnstone

final class DragInteractionTests: XCTestCase {
    @MainActor
    func testSliceGapsRemainSelectable() {
        let canvas = WheelCanvas(frame: NSRect(x: 0, y: 0, width: 328, height: 354))
        for count in [4, 7, 12] {
            canvas.entries = Array(repeating: .format("jpg"), count: count)
            for radius in [51.0, 98, 139] {
                for degrees in stride(from: 0.0, to: 360, by: 2) {
                    canvas.selected = nil
                    let angle = degrees * .pi / 180
                    canvas.updateSelection(NSPoint(x: 164 + cos(angle) * radius, y: 181 + sin(angle) * radius))
                    XCTAssertNotNil(canvas.selected, "The space between decorative slices must accept a drop")
                }
            }
        }
    }

    @MainActor
    func testSmallBoundaryJitterKeepsCurrentSlice() {
        let canvas = WheelCanvas(frame: NSRect(x: 0, y: 0, width: 328, height: 354))
        canvas.entries = Array(repeating: .format("jpg"), count: 4)
        canvas.selected = 0
        for degrees in [44.0, 46, 44, 46] {
            let angle = (90 - degrees) * .pi / 180
            canvas.updateSelection(NSPoint(x: 164 + cos(angle) * 98, y: 181 + sin(angle) * 98))
            XCTAssertEqual(canvas.selected, 0)
        }
        let angle = (90.0 - 49) * .pi / 180
        canvas.updateSelection(NSPoint(x: 164 + cos(angle) * 98, y: 181 + sin(angle) * 98))
        XCTAssertEqual(canvas.selected, 1)
    }

    @MainActor
    func testUnsupportedDragDoesNotHighlightOrAcceptDrop() {
        let (panel, canvas, drag) = makeDestination()
        defer { panel.close() }
        drag.draggingSourceOperationMask = .move
        XCTAssertEqual(canvas.draggingEntered(drag), [])
        XCTAssertNil(canvas.selected)
        XCTAssertFalse(canvas.prepareForDragOperation(drag))
        XCTAssertFalse(canvas.performDragOperation(drag))
        drag.draggingSourceOperationMask = .copy
        XCTAssertEqual(canvas.draggingUpdated(drag), .copy)
        XCTAssertEqual(canvas.selected, 0)
    }

    @MainActor
    func testMouseExitDoesNotClearNativeDragSelection() throws {
        let (panel, canvas, drag) = makeDestination()
        defer { panel.close() }
        XCTAssertEqual(canvas.draggingEntered(drag), .copy)
        let event = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        canvas.mouseExited(with: event)
        XCTAssertEqual(canvas.selected, 0)
        canvas.draggingExited(drag)
        XCTAssertNil(canvas.selected)
    }

    @MainActor
    func testDropCommitsPreparedSelectionExactlyOnce() async {
        let (panel, canvas, drag) = makeDestination()
        defer { panel.close() }
        var selections: [WheelEntry] = []
        let files = canvas.files
        let committed = expectation(description: "Prepared drop commits")
        canvas.onSelect = { entry, urls in
            XCTAssertEqual(urls, files)
            selections.append(entry)
            committed.fulfill()
        }
        XCTAssertEqual(canvas.draggingEntered(drag), .copy)
        XCTAssertTrue(canvas.prepareForDragOperation(drag))
        canvas.selected = nil
        XCTAssertTrue(canvas.performDragOperation(drag))
        XCTAssertFalse(canvas.performDragOperation(drag))
        await fulfillment(of: [committed], timeout: 2)
        XCTAssertEqual(selections, [.format("jpg")])
    }

    @MainActor
    func testPrepareRechecksReleasePosition() {
        let (panel, canvas, drag) = makeDestination()
        defer { panel.close() }
        XCTAssertEqual(canvas.draggingEntered(drag), .copy)
        drag.draggingLocation = NSPoint(x: 164, y: 181)
        XCTAssertFalse(canvas.prepareForDragOperation(drag))
        XCTAssertNil(canvas.selected)
    }

    @MainActor
    func testDifferentFilesCannotUseStaleWheelEntries() {
        let (panel, canvas, drag) = makeDestination()
        defer { panel.close() }
        drag.draggingPasteboard.clearContents()
        drag.draggingPasteboard.writeObjects([URL(fileURLWithPath: "/tmp/other.wav") as NSURL])
        XCTAssertEqual(canvas.draggingEntered(drag), [])
        XCTAssertNil(canvas.selected)
        XCTAssertFalse(canvas.performDragOperation(drag))
    }

    @MainActor
    func testMouseReleaseKeepsNativeDestinationUntilDropCompletes() throws {
        _ = NSApplication.shared
        let model = AppModel()
        let controller = model.wheel
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally(); controller.hide() }
        controller.updateDrag(mouseDown: false, location: .zero, flags: [], board: board)
        controller.updateDrag(mouseDown: true, location: .zero, flags: [], board: board)
        let files = [URL(fileURLWithPath: "/tmp/turnstone-release-fixture.png")]
        controller.show(files: files, mode: .conversions, keyboard: false)
        let panel = try XCTUnwrap(NSApp.windows.compactMap { $0 as? WheelPanel }.first { ($0.contentView as? WheelCanvas)?.files == files })
        let canvas = try XCTUnwrap(panel.contentView as? WheelCanvas)
        let drag = TestDragInfo(window: panel, files: files)
        XCTAssertEqual(canvas.draggingEntered(drag), .copy)
        controller.updateDrag(mouseDown: false, location: .zero, flags: [], board: board)
        XCTAssertTrue(panel.isVisible, "Mouse-up polling must let AppKit complete the drop")
        canvas.draggingEnded(drag)
        XCTAssertFalse(panel.isVisible)
    }

    @MainActor
    func testExitReentryAndStaleEndDoNotCancelNewDrag() {
        let (panel, canvas, drag) = makeDestination()
        defer { panel.close() }
        var ended = 0
        canvas.onDragEnd = { ended += 1 }
        XCTAssertEqual(canvas.draggingEntered(drag), .copy)
        canvas.draggingExited(drag)
        XCTAssertFalse(canvas.isReceivingDrag)
        XCTAssertEqual(canvas.draggingEntered(drag), .copy)
        let next = TestDragInfo(window: panel, files: canvas.files)
        next.draggingSequenceNumber = 2
        XCTAssertEqual(canvas.draggingEntered(next), .copy)
        canvas.draggingEnded(drag)
        XCTAssertTrue(canvas.isReceivingDrag)
        XCTAssertEqual(canvas.selected, 0)
        XCTAssertEqual(ended, 0)
        canvas.concludeDragOperation(next)
        canvas.draggingEnded(next)
        XCTAssertFalse(canvas.isReceivingDrag)
        XCTAssertNil(canvas.selected)
        XCTAssertEqual(ended, 1)
    }

    @MainActor
    func testModeSwitchRefreshesStationaryDragSelection() throws {
        _ = NSApplication.shared
        let model = AppModel()
        let files = [URL(fileURLWithPath: "/tmp/turnstone-mode-fixture.png")]
        model.wheel.show(files: files, mode: .conversions, keyboard: false)
        defer { model.wheel.hide() }
        let panel = try XCTUnwrap(NSApp.windows.compactMap { $0 as? WheelPanel }.first { ($0.contentView as? WheelCanvas)?.files == files })
        let canvas = try XCTUnwrap(panel.contentView as? WheelCanvas)
        let drag = TestDragInfo(window: panel, files: files)
        XCTAssertEqual(canvas.draggingEntered(drag), .copy)
        canvas.onMode?(.actions)
        XCTAssertEqual(canvas.mode, .actions)
        XCTAssertEqual(canvas.selected, 0)
        XCTAssertEqual(canvas.draggingUpdated(drag), .copy)
        canvas.draggingEnded(drag)
        XCTAssertFalse(panel.isVisible)
    }

    @MainActor
    func testMouseReleaseOutsideDestinationDismissesWheel() throws {
        _ = NSApplication.shared
        let model = AppModel()
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally(); model.wheel.hide() }
        model.wheel.updateDrag(mouseDown: true, location: .zero, flags: [], board: board)
        let files = [URL(fileURLWithPath: "/tmp/turnstone-outside-fixture.png")]
        model.wheel.show(files: files, mode: .conversions, keyboard: false)
        let panel = try XCTUnwrap(NSApp.windows.compactMap { $0 as? WheelPanel }.first { ($0.contentView as? WheelCanvas)?.files == files })
        let canvas = try XCTUnwrap(panel.contentView as? WheelCanvas)
        let drag = TestDragInfo(window: panel, files: files)
        XCTAssertEqual(canvas.draggingEntered(drag), .copy)
        canvas.draggingExited(drag)
        model.wheel.updateDrag(mouseDown: false, location: .zero, flags: [], board: board)
        XCTAssertFalse(panel.isVisible)
    }

    @MainActor
    private func makeDestination() -> (WheelPanel, WheelCanvas, TestDragInfo) {
        _ = NSApplication.shared
        let panel = WheelPanel(contentRect: NSRect(x: 0, y: 0, width: 328, height: 354), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let canvas = WheelCanvas(frame: NSRect(x: 0, y: 0, width: 328, height: 354))
        canvas.files = [URL(fileURLWithPath: "/tmp/turnstone-drag-fixture.png")]
        canvas.entries = [.format("jpg"), .format("pdf"), .format("webp"), .format("heic")]
        panel.contentView = canvas
        let drag = TestDragInfo(window: panel, files: canvas.files)
        return (panel, canvas, drag)
    }
}

// AppKit supplies this protocol during real drags; tests drive the same destination callbacks.
@MainActor
private final class TestDragInfo: NSObject, NSDraggingInfo {
    let draggingDestinationWindow: NSWindow?
    var draggingSourceOperationMask: NSDragOperation = .copy
    var draggingLocation = NSPoint(x: 164, y: 281)
    var draggedImageLocation: NSPoint { draggingLocation }
    nonisolated var draggedImage: NSImage? { nil }
    let draggingPasteboard = NSPasteboard.withUniqueName()
    var draggingSource: Any? { nil }
    var draggingSequenceNumber = 1
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    init(window: NSWindow, files: [URL]) {
        draggingDestinationWindow = window
        super.init()
        draggingPasteboard.writeObjects(files as [NSURL])
    }
    deinit { draggingPasteboard.releaseGlobally() }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?, classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}
