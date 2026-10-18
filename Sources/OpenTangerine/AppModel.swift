import SwiftUI
import AppKit
import TangerineCore

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    @Published var paused = false
    @Published var jobs: [ConversionJob] = []
    @Published var shelfFiles: [URL] = []
    lazy var wheel = WheelController(model: self)

    func showHome() { Windows.show("home", title: "Open Tangerine", size: NSSize(width: 640, height: 650), content: HomeView(model: self)) }
    func showJobs() { Windows.show("jobs", title: "Conversion Jobs", size: NSSize(width: 600, height: 480), content: JobsView(model: self)) }
    func showSettings() { Windows.show("settings", title: "Open Tangerine Settings", size: NSSize(width: 620, height: 560), content: SettingsView()) }
    func showShelf() {
        Windows.show("shelf", title: "Floating Shelf", size: NSSize(width: 340, height: 420), floating: true, content: ShelfView(model: self))
        Windows.pinShelf(to: UserDefaults.standard.string(forKey: "shelfEdge") ?? "free")
    }

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = true
        panel.prompt = "Choose Files"
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            if response == .OK { self.wheel.show(files: panel.urls, mode: .conversions, keyboard: true) }
        }
    }

    func select(_ entry: WheelEntry, files: [URL]) {
        wheel.hide()
        switch entry {
        case .format(let format):
            if format == "epub", files.contains(where: { Catalog.fileExtension($0) == "pdf" }) {
                edit(files, operation: .convert(format))
            } else { submit(JobRequest(files: files, operation: .convert(format))) }
        case .tool(let tool):
            if [.muteVideo, .splitPDF, .extractArchive].contains(tool) {
                submit(JobRequest(files: files, operation: .tool(tool)))
            } else { edit(files, operation: .tool(tool)) }
        case .action(let action): perform(action, files: files)
        }
    }

    func edit(_ files: [URL], operation: FileOperation) {
        let key = UUID().uuidString
        Windows.show(key, title: operation.title, size: NSSize(width: 760, height: 790), content: ToolEditor(files: files, operation: operation) { options, orderedFiles in
            self.submit(JobRequest(files: orderedFiles, operation: operation, options: options))
            Windows.close(key)
        })
    }

    func submit(_ request: JobRequest) {
        let job = ConversionJob(request: request)
        jobs.insert(job, at: 0)
        if jobs.count > 50 { jobs = Array(jobs.prefix(50)) + jobs.dropFirst(50).filter { !$0.finished } }
        showJobs()
        job.start()
    }

    func perform(_ action: FileAction, files: [URL]) {
        do {
            switch action {
            case .copy:
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects(files as [NSURL])
            case .copyPath:
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(files.map(\.path).joined(separator: "\n"), forType: .string)
            case .float:
                shelfFiles = Array(Set(shelfFiles + files)).sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                showShelf()
            case .airDrop:
                guard let service = NSSharingService(named: .sendViaAirDrop) else { throw TangerineError.failed("AirDrop is unavailable on this Mac.") }
                service.perform(withItems: files)
            case .move:
                let picker = NSOpenPanel()
                picker.canChooseDirectories = true; picker.canChooseFiles = false; picker.canCreateDirectories = true
                picker.prompt = "Move Here"
                NSApp.activate(ignoringOtherApps: true)
                picker.begin { result in
                    guard result == .OK, let directory = picker.url else { return }
                    Task { @MainActor in
                        do {
                            _ = try await Task.detached(priority: .userInitiated) { try FileMove.perform(files, to: directory) }.value
                            self.shelfFiles = self.shelfFiles.filter { FileManager.default.fileExists(atPath: $0.path) }
                            NSWorkspace.shared.open(directory)
                        } catch { self.showError(error) }
                    }
                }
            case .terminal:
                let folders = Set(files.map { url in
                    (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true ? url : url.deletingLastPathComponent()
                })
                let appName = UserDefaults.standard.string(forKey: "terminalApp") ?? "Terminal"
                let identifier = appName == "iTerm2" ? "com.googlecode.iterm2" : "com.apple.Terminal"
                guard let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else { throw TangerineError.invalid("\(appName) is not installed.") }
                for folder in folders {
                    NSWorkspace.shared.open([folder], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration())
                }
            }
        } catch { showError(error) }
    }

    func showError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Couldn’t complete the operation"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}

extension FileOperation {
    var title: String {
        switch self { case .convert(let format): return "Convert to \(format.uppercased())"; case .tool(let tool): return tool.title }
    }
}

@MainActor
final class ConversionJob: ObservableObject, Identifiable {
    let id = UUID()
    let request: JobRequest
    @Published var message = "Preparing…"
    @Published var fraction = 0.0
    @Published var outputs: [URL] = []
    @Published var errors: [String] = []
    @Published var finished = false
    @Published var cancelled = false
    private var context: ExecutionContext?
    private var task: Task<Void, Never>?
    init(request: JobRequest) { self.request = request }

    func start() {
        guard task == nil, !finished else { return }
        do {
            let context = try ExecutionContext { [weak self] text in
                Task { @MainActor [weak self] in self?.message = text }
            }
            self.context = context
            let combined: Bool
            if case .tool(let tool) = request.operation { combined = [.collage, .createPDF, .mergePDF, .joinVideos].contains(tool) } else { combined = false }
            let work = combined ? [request] : request.files.map { JobRequest(files: [$0], operation: request.operation, options: request.options) }
            task = Task(priority: .userInitiated) { [self] in
                defer { self.context = nil; self.task = nil }
                for (index, item) in work.enumerated() {
                    do {
                        try context.checkCancellation()
                        outputs += try await ConversionEngine().run(item, context: context)
                    } catch is CancellationError {
                        cancelled = true
                        break
                    } catch {
                        errors.append("\(item.files.first?.lastPathComponent ?? "File"): \(error.localizedDescription)")
                    }
                    fraction = Double(index + 1) / Double(work.count)
                }
                finished = true
                message = cancelled ? "Cancelled" : errors.isEmpty ? "Finished" : "Finished with errors"
                if !outputs.isEmpty && UserDefaults.standard.object(forKey: "revealResults") as? Bool != false {
                    NSWorkspace.shared.activateFileViewerSelecting(outputs)
                }
            }
        } catch { errors = [error.localizedDescription]; message = "Couldn’t start"; finished = true }
    }

    func cancel() {
        guard !finished else { return }
        cancelled = true
        message = "Cancelling…"
        context?.runner.cancel()
        task?.cancel()
    }
}
