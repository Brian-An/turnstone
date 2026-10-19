import AppKit
import SwiftUI
import TurnstoneCore

enum WheelMode: String, CaseIterable {
    case conversions, tools, actions
    var shortcut: String {
        switch self {
        case .conversions: return UserDefaults.standard.string(forKey: "conversionKey") ?? "shift"
        case .tools: return UserDefaults.standard.string(forKey: "toolsKey") ?? "command"
        case .actions: return UserDefaults.standard.string(forKey: "actionsKey") ?? "control"
        }
    }
    var symbol: String { ["shift": "⇧", "command": "⌘", "control": "⌃", "option": "⌥"][shortcut] ?? "⇧" }
    var flag: NSEvent.ModifierFlags { ["shift": .shift, "command": .command, "control": .control, "option": .option][shortcut] ?? .shift }
    static func matching(_ flags: NSEvent.ModifierFlags) -> Self? { allCases.first { $0.flag == flags } }
}
enum WheelEntry: Equatable {
    case format(String), tool(ToolID), action(FileAction)
    var title: String {
        switch self { case .format(let format): return format == "gz" ? "GZIP" : format.uppercased(); case .tool(let tool): return tool.title; case .action(let action): return action.title }
    }
    var symbol: String? {
        switch self { case .format: return nil; case .tool(let tool): return tool.symbol; case .action(let action): return action.symbol }
    }
}

@MainActor
final class WheelController {
    private unowned let model: AppModel
    private var timer: Timer?
    private var panel: WheelPanel?
    private var view: WheelCanvas?
    private var idleChange = NSPasteboard(name: .drag).changeCount
    private var wasDown = false
    private var startPoint = NSPoint.zero
    private var lastFlags: NSEvent.ModifierFlags = []
    private var dragFiles: [URL] = []
    private var suppressed = false
    private var keyboardMode = false
    init(model: AppModel) { self.model = model }

    func start() {
        timer = Timer(timeInterval: 1 / 30, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.pollDrag() } }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func pollDrag() {
        updateDrag(mouseDown: NSEvent.pressedMouseButtons & 1 == 1, location: NSEvent.mouseLocation,
                   flags: NSEvent.modifierFlags, board: NSPasteboard(name: .drag))
    }

    func updateDrag(mouseDown down: Bool, location: NSPoint, flags: NSEvent.ModifierFlags, board: NSPasteboard) {
        guard !model.paused else { return }
        if !down {
            // AppKit owns completion after release while the wheel is the native drag destination.
            if wasDown, !keyboardMode, view?.isReceivingDrag != true { hide() }
            wasDown = false; idleChange = board.changeCount; lastFlags = []; dragFiles = []; suppressed = false
            return
        }
        if keyboardMode { return }
        if !wasDown { startPoint = location; wasDown = true; lastFlags = [] }
        guard !suppressed, hypot(location.x - startPoint.x, location.y - startPoint.y) > 4,
              board.changeCount != idleChange else { return }
        if dragFiles.isEmpty { dragFiles = Self.files(from: board) }
        guard !dragFiles.isEmpty else { return }
        let flags = flags.intersection([.shift, .command, .control, .option])
        if flags != lastFlags, !flags.isEmpty {
            lastFlags = flags
            if let mode = WheelMode.matching(flags) { show(files: dragFiles, mode: mode, keyboard: false) }
        } else if flags.isEmpty { lastFlags = [] }
    }

    static func files(from board: NSPasteboard) -> [URL] {
        (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    func show(files: [URL], mode: WheelMode, keyboard: Bool) {
        guard !files.isEmpty else { return }
        keyboardMode = keyboard
        if panel == nil {
            let panel = WheelPanel(contentRect: NSRect(x: 0, y: 0, width: 328, height: 354), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false
            // WindowServer passes input through clear pixels even where native glass is visible.
            panel.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(1.0 / 255.0)
            panel.hasShadow = false
            panel.level = .popUpMenu
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            panel.isMovable = false; panel.acceptsMouseMovedEvents = true
            let view = WheelCanvas(frame: NSRect(x: 0, y: 0, width: 328, height: 354))
            view.onSelect = { [weak self] entry, urls in self?.model.select(entry, files: urls) }
            view.onCancel = { [weak self] in self?.suppressed = true; self?.hide() }
            view.onMode = { [weak self] newMode in self?.switchMode(newMode) }
            view.onDragEnd = { [weak self] in self?.hide() }
            panel.contentView = view; self.panel = panel; self.view = view
        }
        let newSession = panel?.isVisible != true
        if newSession { view?.resetDragSession() }
        view?.files = files
        view?.keyboardNavigation = keyboard
        switchMode(mode)
        if newSession, let panel {
            let pointer = NSEvent.mouseLocation
            let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main
            let safe = (screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)).insetBy(dx: 10, dy: 10)
            let point = keyboard ? NSPoint(x: safe.midX, y: safe.midY) : pointer
            let origin = NSPoint(x: min(max(point.x - 164, safe.minX), safe.maxX - 328), y: min(max(point.y - 181, safe.minY), safe.maxY - 354))
            panel.setFrameOrigin(origin)
        }
        if keyboard {
            view?.selected = view?.entries.isEmpty == false ? 0 : nil
            panel?.makeKeyAndOrderFront(nil)
            panel?.makeFirstResponder(view)
            NSApp.activate(ignoringOtherApps: true)
        } else { panel?.orderFrontRegardless() }
    }

    private func switchMode(_ mode: WheelMode) {
        guard let view else { return }
        view.mode = mode
        switch mode {
        case .conversions: view.entries = Catalog.outputs(for: view.files).map(WheelEntry.format)
        case .tools: view.entries = Catalog.tools(for: view.files).map(WheelEntry.tool)
        case .actions: view.entries = FileAction.allCases.map(WheelEntry.action)
        }
        view.selected = keyboardMode && !view.entries.isEmpty ? 0 : nil
        view.refreshDragSelection()
        view.needsDisplay = true
    }

    func hide() { panel?.orderOut(nil); view?.resetDragSession(); keyboardMode = false }
}

final class WheelPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class WheelCanvas: NSView {
    var files: [URL] = [] { didSet { fileIcon = files.first.map { NSWorkspace.shared.icon(forFile: $0.path) }; refreshSurface() } }
    var mode: WheelMode = .conversions { didSet { refreshSurface() } }
    var entries: [WheelEntry] = [] { didSet { updateAccessibility(); refreshSurface() } }
    var keyboardNavigation = false
    var selected: Int? { didSet { if selected != oldValue { refreshSurface(); playFeedback() } } }
    var onSelect: ((WheelEntry, [URL]) -> Void)?
    var onCancel: (() -> Void)?
    var onMode: ((WheelMode) -> Void)?
    private let center = NSPoint(x: 164, y: 181)
    private var surface: WheelHostingView?
    private var fileIcon: NSImage?
    private var dragSequence: Int?
    private var dragPoint: NSPoint?
    private var dragBoardChange: Int?
    private var dragURLs: [URL] = []
    private var dragAllowsCopy = false
    private var preparedDrop: (sequence: Int, entry: WheelEntry, files: [URL])?
    private var performedSequence: Int?
    private var dragHint: String? { didSet { if dragHint != oldValue { refreshSurface() } } }
    var isReceivingDrag: Bool { dragSequence != nil }
    var onDragEnd: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("File operation wheel. Arrow keys select, Return applies, Escape cancels. Shift, Command, or Control changes wheels.")
        let hosting = WheelHostingView(rootView: wheelAppearance)
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
        surface = hosting
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    private func playFeedback() {
        guard selected != nil, UserDefaults.standard.bool(forKey: "wheelSound") else { return }
        NSSound(named: "Pop")?.play()
    }

    func updateSelection(_ point: NSPoint) {
        let x = point.x - center.x, y = point.y - center.y
        if let index = WheelGeometry.selection(x: x, y: y, count: entries.count, previous: selected) {
            selected = index
            return
        }
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
           let selected,
           WheelGeometry.selection(x: x, y: y, count: entries.count, outer: 140 + WheelEmphasis.lift, previous: selected) == selected {
            return
        }
        selected = nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        guard !isReceivingDrag else { return }
        if keyboardNavigation, event.deltaX == 0, event.deltaY == 0 { return }
        keyboardNavigation = false
        updateSelection(convert(event.locationInWindow, from: nil))
    }
    override func mouseDown(with event: NSEvent) {
        updateSelection(convert(event.locationInWindow, from: nil))
        if let selected { onSelect?(entries[selected], files) }
    }
    override func mouseExited(with event: NSEvent) { if !isReceivingDrag && !keyboardNavigation { selected = nil } }
    override func keyDown(with event: NSEvent) {
        keyboardNavigation = true
        switch event.keyCode {
        case 53: onCancel?()
        case 36, 76, 49: if let selected { onSelect?(entries[selected], files) }
        case 123, 126: if !entries.isEmpty { selected = ((selected ?? 1) - 1 + entries.count) % entries.count }
        case 124, 125: if !entries.isEmpty { selected = ((selected ?? -1) + 1) % entries.count }
        default: super.keyDown(with: event)
        }
    }

    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateAccessibility() }
    private func updateAccessibility() {
        let children = entries.enumerated().map { index, entry -> WheelAccessibilityButton in
            let element = WheelAccessibilityButton()
            element.setAccessibilityRole(.button)
            element.setAccessibilityEnabled(true)
            element.setAccessibilityLabel(entry.symbol == nil ? "Convert to \(entry.title)" : entry.title)
            element.setAccessibilityParent(self)
            let angle = 90.0 - Double(index) * 360 / Double(entries.count)
            let half = 180 / Double(entries.count)
            let rect = convert(path(start: angle - half, end: angle + half).bounds, to: nil)
            element.setAccessibilityFrame(window?.convertToScreen(rect) ?? rect)
            element.onPress = { [weak self] in guard let self else { return }; self.onSelect?(entry, self.files) }
            return element
        }
        setAccessibilityChildren(children)
    }
    override func flagsChanged(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.shift, .command, .control, .option])
        if let mode = WheelMode.matching(flags) { onMode?(mode) }
    }

    override func wantsPeriodicDraggingUpdates() -> Bool { true }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard performedSequence != sender.draggingSequenceNumber else { return [] }
        if dragSequence != sender.draggingSequenceNumber {
            resetDragSession()
            dragSequence = sender.draggingSequenceNumber
        }
        if dragBoardChange != sender.draggingPasteboard.changeCount {
            dragURLs = WheelController.files(from: sender.draggingPasteboard)
            dragBoardChange = sender.draggingPasteboard.changeCount
        }
        dragPoint = convert(sender.draggingLocation, from: nil)
        let matchingFiles = !dragURLs.isEmpty && dragURLs == files
        dragAllowsCopy = matchingFiles && sender.draggingSourceOperationMask.contains(.copy)
        if dragAllowsCopy { dragHint = nil }
        else {
            let modifiers = NSEvent.modifierFlags.intersection([.command, .control, .option])
            dragHint = matchingFiles && !modifiers.isEmpty ? "Release key" : "Can't drop"
        }
        refreshDragSelection()
        // Accept valid drags on entry; preparation requires a selected slice before committing.
        return dragAllowsCopy ? .copy : []
    }
    func refreshDragSelection() {
        guard let dragPoint else { return }
        keyboardNavigation = false
        if dragAllowsCopy { updateSelection(dragPoint) }
        else { selected = nil }
    }
    override func draggingExited(_ sender: NSDraggingInfo?) {
        guard sender == nil || sender?.draggingSequenceNumber == dragSequence else { return }
        if preparedDrop == nil { resetDragSession() }
        selected = nil
    }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard draggingUpdated(sender) == .copy, let selected else { preparedDrop = nil; return false }
        // Freeze the accepted target before the drag image is removed and callbacks can clear hover.
        preparedDrop = (sender.draggingSequenceNumber, entries[selected], dragURLs)
        return true
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let drop = preparedDrop, drop.sequence == sender.draggingSequenceNumber,
              performedSequence != drop.sequence,
              sender.draggingSourceOperationMask.contains(.copy),
              WheelController.files(from: sender.draggingPasteboard) == drop.files else { return false }
        preparedDrop = nil
        performedSequence = drop.sequence
        let onSelect = onSelect
        // Let the source complete its copy session before starting conversion or opening an editor.
        DispatchQueue.main.async { onSelect?(drop.entry, drop.files) }
        return true
    }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        if let sender { finishDrag(sender) }
    }
    override func draggingEnded(_ sender: NSDraggingInfo) { finishDrag(sender) }
    private func finishDrag(_ sender: NSDraggingInfo) {
        guard dragSequence == sender.draggingSequenceNumber else { return }
        resetDragSession()
        selected = nil
        onDragEnd?()
    }
    func resetDragSession() {
        dragSequence = nil
        dragPoint = nil
        dragBoardChange = nil
        dragURLs = []
        dragAllowsCopy = false
        preparedDrop = nil
        dragHint = nil
    }

    private func refreshSurface() {
        surface?.rootView = wheelAppearance
        // Resolve hosting updates during AppKit's drag-tracking run loop as well as normal mouse moves.
        surface?.layoutSubtreeIfNeeded()
    }

    private var wheelAppearance: WheelAppearance {
        let petals = entries.enumerated().map { index, entry in
            let angle = 90.0 - Double(index) * 360 / Double(entries.count)
            let half = 180 / Double(entries.count)
            let radians = angle * .pi / 180
            return WheelPetalAppearance(
                id: index,
                path: displayPath(path(start: angle - half, end: angle + half)),
                title: shortTitle(entry),
                symbol: entry.symbol,
                position: CGPoint(x: center.x + cos(radians) * 98, y: 354 - center.y - sin(radians) * 98)
            )
        }
        let title = dragHint ?? selected.flatMap { entries.indices.contains($0) ? entries[$0].title : nil }
            ?? (files.count > 1 ? "\(files.count) files" : files.isEmpty ? "Convert" : "Choose")
        return WheelAppearance(petals: petals, selected: selected,
            center: CGPoint(x: center.x, y: 354 - center.y), icon: fileIcon,
            centerTitle: title, emptyTitle: mode == .tools ? "No tools for this selection" : "No common formats")
    }

    private func displayPath(_ bezier: NSBezierPath) -> Path {
        var result = Path()
        var points = [NSPoint](repeating: .zero, count: 3)
        func flipped(_ point: NSPoint) -> CGPoint { CGPoint(x: point.x, y: 354 - point.y) }
        for index in 0..<bezier.elementCount {
            switch bezier.element(at: index, associatedPoints: &points) {
            case .moveTo: result.move(to: flipped(points[0]))
            case .lineTo: result.addLine(to: flipped(points[0]))
            case .curveTo, .cubicCurveTo: result.addCurve(to: flipped(points[2]), control1: flipped(points[0]), control2: flipped(points[1]))
            case .quadraticCurveTo: result.addQuadCurve(to: flipped(points[1]), control: flipped(points[0]))
            case .closePath: result.closeSubpath()
            @unknown default: break
            }
        }
        return result
    }

    private func shortTitle(_ entry: WheelEntry) -> String {
        guard case .tool(let tool) = entry else { return entry.title.uppercased() }
        switch tool {
        case .editImage: return "EDIT"
        case .annotateImage: return "ANNOTATE"
        case .background: return "ADD BG"
        case .cropImage, .cropVideo: return "CROP"
        case .normalizeAudio: return "NORMALIZE"
        case .muteVideo: return "MUTE"
        case .trimVideo, .trimAudio: return "TRIM"
        case .organizePDF: return "ORGANIZE"
        case .extractArchive: return "EXTRACT"
        case .videoSpeed: return "SPEED"
        case .joinVideos: return "JOIN"
        case .videoSnapshots: return "SNAPSHOT"
        case .splitVideo, .splitPDF: return "SPLIT"
        case .audioVisualizer: return "VISUALIZE"
        case .audioChannels: return "CHANNELS"
        case .redactImage, .redactVideo: return "REDACT"
        case .bleepAudio: return "BLEEP"
        default: return entry.title.uppercased()
        }
    }

    private func path(start: Double, end: Double) -> NSBezierPath {
        let outer = 140.0, inner = 50.0, gap = 1.5
        let path = NSBezierPath()
        let point: (Double, Double) -> NSPoint = { radius, angle in NSPoint(x: self.center.x + cos(angle * .pi / 180) * radius, y: self.center.y + sin(angle * .pi / 180) * radius) }
        path.move(to: point(inner + 9, start + gap + 3))
        path.line(to: point(outer - 10, start + gap))
        path.curve(to: point(outer, start + gap + 5), controlPoint1: point(outer, start + gap), controlPoint2: point(outer, start + gap))
        path.appendArc(withCenter: center, radius: outer, startAngle: CGFloat(start + gap + 5), endAngle: CGFloat(end - gap - 5))
        path.curve(to: point(outer - 10, end - gap), controlPoint1: point(outer, end - gap), controlPoint2: point(outer, end - gap))
        path.line(to: point(inner + 9, end - gap - 3))
        path.curve(to: point(inner, end - gap - 9), controlPoint1: point(inner, end - gap - 3), controlPoint2: point(inner, end - gap - 3))
        path.appendArc(withCenter: center, radius: inner, startAngle: CGFloat(end - gap - 9), endAngle: CGFloat(start + gap + 9), clockwise: true)
        path.curve(to: point(inner + 9, start + gap + 3), controlPoint1: point(inner, start + gap + 3), controlPoint2: point(inner, start + gap + 3))
        path.close()
        return path
    }


}

@MainActor
private final class WheelAccessibilityButton: NSAccessibilityElement {
    var onPress: (() -> Void)?
    override func accessibilityPerformPress() -> Bool { onPress?(); return true }
}
