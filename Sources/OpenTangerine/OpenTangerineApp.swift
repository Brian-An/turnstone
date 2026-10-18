import SwiftUI
import AppKit
import TangerineCore

@main
struct OpenTangerineApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        Settings { SettingsView() }
            .commands {
                CommandGroup(replacing: .newItem) {
                    Button("Choose Files…") { AppModel.shared.chooseFiles() }.keyboardShortcut("o")
                    Button("Open Tangerine") { AppModel.shared.showHome() }
                }
                CommandMenu("Tools") {
                    Button("Recent Jobs") { AppModel.shared.showJobs() }.keyboardShortcut("j")
                    Button("Floating Shelf") { AppModel.shared.showShelf() }
                }
            }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var item: NSStatusItem!
    private let model = AppModel.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "arrow.trianglehead.2.clockwise.rotate.90", accessibilityDescription: "Open Tangerine") ?? NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "Open Tangerine")
        item.button?.image?.isTemplate = true
        let menu = NSMenu()
        menu.delegate = self
        for (title, action, key) in [
            ("Open Tangerine", #selector(home), ""),
            ("Choose Files…", #selector(choose), "o"),
            ("Floating Shelf", #selector(shelf), ""),
            ("Recent Jobs", #selector(jobs), "j"),
            ("Settings…", #selector(settings), ",")
        ] {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
            entry.target = self
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        let pause = NSMenuItem(title: "Pause Drag Detection", action: #selector(togglePause), keyEquivalent: "")
        pause.tag = 10; pause.target = self; menu.addItem(pause)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Open Tangerine", action: #selector(quit), keyEquivalent: "q")
        quit.target = self; menu.addItem(quit)
        item.menu = menu
        model.wheel.start()
        if !UserDefaults.standard.bool(forKey: "hasLaunched") || CommandLine.arguments.contains("--welcome") {
            home(); UserDefaults.standard.set(true, forKey: "hasLaunched")
        }
        if let index = CommandLine.arguments.firstIndex(of: "--open"), CommandLine.arguments.count > index + 1 {
            let urls = CommandLine.arguments[(index + 1)...].map { URL(fileURLWithPath: $0) }
            model.wheel.show(files: urls, mode: .conversions, keyboard: true)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        model.wheel.show(files: urls, mode: .conversions, keyboard: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { model.showHome() }
        return false
    }
    func menuWillOpen(_ menu: NSMenu) { menu.item(withTag: 10)?.state = model.paused ? .on : .off }
    @objc private func home() { model.showHome() }
    @objc private func choose() { model.chooseFiles() }
    @objc private func shelf() { model.showShelf() }
    @objc private func jobs() { model.showJobs() }
    @objc private func settings() { model.showSettings() }
    @objc private func togglePause() { model.paused.toggle(); if model.paused { model.wheel.hide() } }
    @objc private func quit() { NSApp.terminate(nil) }
}

@MainActor
enum Windows {
    private static var windows: [String: NSWindow] = [:]
    private static var delegates: [String: HostedWindowDelegate] = [:]
    static func show<Content: View>(_ key: String, title: String, size: NSSize, floating: Bool = false, content: Content) {
        if let existing = windows[key] { existing.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = title
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content.tint(.orange))
        window.minSize = NSSize(width: min(size.width, 480), height: min(size.height, 420))
        if floating { window.level = .floating; window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary] }
        window.center()
        windows[key] = window
        let delegate = HostedWindowDelegate(key: key)
        delegates[key] = delegate
        window.delegate = delegate
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    static func close(_ key: String) { windows[key]?.close() }

    static func pinShelf(to edge: String) {
        guard let window = windows["shelf"], let screen = window.screen ?? NSScreen.main else { return }
        UserDefaults.standard.set(edge, forKey: "shelfEdge")
        let visible = screen.visibleFrame.insetBy(dx: 12, dy: 12)
        var frame = window.frame
        frame.origin.x = min(max(frame.minX, visible.minX), max(visible.minX, visible.maxX - frame.width))
        frame.origin.y = min(max(frame.minY, visible.minY), max(visible.minY, visible.maxY - frame.height))
        switch edge {
        case "left": frame.origin.x = visible.minX
        case "right": frame.origin.x = visible.maxX - frame.width
        case "top": frame.origin.y = visible.maxY - frame.height
        case "bottom": frame.origin.y = visible.minY
        default: return
        }
        window.setFrame(frame, display: true, animate: true)
    }

    fileprivate static func didClose(_ key: String, window: NSWindow?) {
        guard windows[key] === window else { return }
        windows.removeValue(forKey: key)
        delegates.removeValue(forKey: key)
    }
}

@MainActor
private final class HostedWindowDelegate: NSObject, NSWindowDelegate {
    private let key: String
    init(key: String) { self.key = key }
    func windowWillClose(_ notification: Notification) {
        Windows.didClose(key, window: notification.object as? NSWindow)
    }
}
