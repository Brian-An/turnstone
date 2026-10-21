import SwiftUI
import AppKit
import ServiceManagement
import TurnstoneCore

struct HomeView: View {
    @ObservedObject var model: AppModel
    @AppStorage("conversionKey") private var conversionKey = "shift"
    @State private var targeted = false
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                TurnstoneLogo().frame(width: 22, height: 22).foregroundStyle(Color.accentColor)
                Text("Turnstone").font(.system(size: 16, weight: .medium))
                Spacer()
                Button { model.showSettings() } label: { Image(systemName: "gearshape").frame(width: 18, height: 18) }.glassAction().help("Settings")
            }.padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 8)
            ScrollView {
                VStack(spacing: 14) {
                    WheelPreview().frame(width: 328, height: 354).scaleEffect(0.60).frame(width: 197, height: 213).accessibilityHidden(true)
                    VStack(spacing: 5) {
                        Text("Drag a file in Finder, then tap \(WheelMode.conversions.symbol) \(conversionKey.capitalized).")
                            .font(.callout)
                        Text("Release the key, keep dragging, and drop onto a format.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.multilineTextAlignment(.center)
                    Button("Choose Files…") { model.chooseFiles() }.glassAction(prominent: true).controlSize(.large).keyboardShortcut("o")
                    Text(targeted ? "Drop to choose an operation" : "Or drop files anywhere in this window")
                        .font(.caption).foregroundStyle(targeted ? Color.accentColor : .secondary)
                    Button("Set up more formats…") { model.showSettings(tab: .engines) }
                        .buttonStyle(.link).font(.caption)
                }.frame(maxWidth: .infinity).padding(.horizontal, 24).padding(.bottom, 20)
            }
            HStack {
                Label("On your Mac", systemImage: "lock").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button("Recent Jobs") { model.showJobs() }.buttonStyle(.link)
            }.padding(16)
        }
        .background(targeted ? Color.accentColor.opacity(0.06) : Color.clear)
        .dropDestination(for: URL.self) { urls, _ in model.wheel.show(files: urls, mode: .conversions, keyboard: true); return !urls.isEmpty } isTargeted: { targeted = $0 }
    }
}

private struct WheelPreview: NSViewRepresentable {
    func makeNSView(context: Context) -> WheelCanvas {
        let view = WheelCanvas(frame: NSRect(x: 0, y: 0, width: 328, height: 354))
        view.entries = ["jpg", "webp", "heic", "tiff", "avif", "bmp", "pdf"].map(WheelEntry.format)
        view.selected = 0
        return view
    }
    func updateNSView(_ nsView: WheelCanvas, context: Context) {}
}

struct JobsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Recent jobs").font(.system(size: 20, weight: .medium))
                Spacer()
                Button("Choose Files…") { model.chooseFiles() }.glassAction()
            }.padding(20)
            if model.jobs.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "tray").font(.system(size: 38)).foregroundStyle(.tertiary)
                    Text("Ready when you are").font(.title3.weight(.medium))
                    Text("Converted files appear beside their originals.").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(model.jobs) { job in JobRow(job: job) }
                    }.padding([.horizontal, .bottom], 20)
                }
            }
        }.frame(minWidth: 440, minHeight: 300)
    }
}

private struct JobRow: View {
    @ObservedObject var job: ConversionJob
    @State private var errorsExpanded = true
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: job.finished ? (job.errors.isEmpty && !job.cancelled ? "checkmark.circle.fill" : "exclamationmark.circle") : "arrow.triangle.2.circlepath")
                    .foregroundStyle(job.finished ? (job.errors.isEmpty && !job.cancelled ? Color.green : Color.orange) : Color.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text(job.request.operation.title).font(.headline)
                    Text(job.request.files.count == 1 ? job.request.files[0].lastPathComponent : "\(job.request.files.count) files")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if !job.finished { Button("Cancel") { job.cancel() } }
                if !job.outputs.isEmpty {
                    Button { NSWorkspace.shared.activateFileViewerSelecting(job.outputs) } label: { Image(systemName: "folder") }.help("Reveal outputs in Finder")
                }
            }
            if !job.finished {
                ProgressView(value: job.fraction)
                Text(job.message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            } else {
                Text("\(job.message) · \(job.outputs.count) output\(job.outputs.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
            }
            if !job.errors.isEmpty {
                DisclosureGroup("\(job.errors.count) error\(job.errors.count == 1 ? "" : "s")", isExpanded: $errorsExpanded) {
                    ForEach(Array(job.errors.enumerated()), id: \.offset) { _, error in
                        Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 5)
                    }
                }.font(.caption)
            }
        }.padding(.vertical, 16).padding(.horizontal, 4).overlay(alignment: .bottom) { Divider().opacity(0.45) }
    }
}

struct ShelfView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Keep it within reach").font(.headline)
                Spacer()
                Menu {
                    Button("Free Floating") { Windows.pinShelf(to: "free") }
                    Button("Left Edge") { Windows.pinShelf(to: "left") }
                    Button("Right Edge") { Windows.pinShelf(to: "right") }
                    Button("Top Edge") { Windows.pinShelf(to: "top") }
                    Button("Bottom Edge") { Windows.pinShelf(to: "bottom") }
                } label: { Image(systemName: "pin") }.menuStyle(.borderlessButton).frame(width: 24).help("Pin shelf to a screen edge")
                if !model.shelfFiles.isEmpty { Button("Clear") { model.shelfFiles = [] }.buttonStyle(.link) }
            }
            Text("Drag a file from here into Finder or another app.").font(.caption).foregroundStyle(.secondary)
            if model.shelfFiles.isEmpty {
                Spacer()
                Image(systemName: "pin").font(.largeTitle).foregroundStyle(.tertiary).frame(maxWidth: .infinity)
                Text("Drop files here to hold them temporarily.").font(.callout).multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(model.shelfFiles, id: \.self) { url in
                            HStack {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 32, height: 32)
                                Text(url.lastPathComponent).lineLimit(2).truncationMode(.middle)
                                Spacer()
                                Button { model.shelfFiles.removeAll { $0 == url } } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Remove from shelf")
                            }.padding(.vertical, 10)
                                .contentShape(Rectangle())
                                .onDrag { NSItemProvider(object: url as NSURL) }
                        }
                    }
                }
            }
        }.padding(20).frame(minWidth: 280, minHeight: 260)
        .dropDestination(for: URL.self) { urls, _ in
            for url in urls where !model.shelfFiles.contains(url) { model.shelfFiles.append(url) }
            return !urls.isEmpty
        }
    }
}

enum SettingsTab: String { case general, engines, about }

struct SettingsView: View {
    @AppStorage("settingsTab") private var tab: SettingsTab = .general
    @AppStorage("wheelSound") private var sound = false
    @AppStorage("terminalApp") private var terminal = "Terminal"
    @AppStorage("conversionKey") private var conversionKey = "shift"
    @AppStorage("toolsKey") private var toolsKey = "command"
    @AppStorage("actionsKey") private var actionsKey = "control"
    @State private var login = SMAppService.mainApp.status == .enabled
    @State private var error: String?
    @State private var refresh = UUID()
    var body: some View {
        TabView(selection: $tab) {
            Form {
                Section("Workflow") {
                    Toggle("Play a sound when a wheel item is selected", isOn: $sound)
                    Toggle("Start Turnstone at login", isOn: $login).onChange(of: login) { enabled in
                        do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                        catch { self.error = error.localizedDescription; login = SMAppService.mainApp.status == .enabled }
                    }
                    Picker("Terminal application", selection: $terminal) { Text("Terminal").tag("Terminal"); Text("iTerm2").tag("iTerm2") }
                }
                Section("Drag shortcuts") {
                    keyPicker("Conversion wheel", selection: $conversionKey)
                    keyPicker("Tool wheel", selection: $toolsKey)
                    keyPicker("Action wheel", selection: $actionsKey)
                    Text("Tap the modifier during a file drag. The wheel stays open after you release it.").font(.caption).foregroundStyle(.secondary)
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }.formStyle(.grouped).scrollContentBackground(.hidden).tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsTab.general)
            ScrollView { VStack(alignment: .leading, spacing: 14) {
                Text("Conversion engines").font(.title3.weight(.semibold))
                Text("Basic image, PDF, subtitle, and archive tools run with macOS. These local engines add more formats.").font(.callout).foregroundStyle(.secondary)
                ForEach([("ffmpeg", "Audio and video"), ("magick", "Additional image encoders"), ("exiftool", "Embedded metadata"), ("pandoc", "Documents and EPUB"), ("soffice", "Office, slides, and spreadsheets")], id: \.0) { name, purpose in
                    HStack(alignment: .top) {
                        Image(systemName: ProcessRunner.locate(name) == nil ? "circle.dashed" : "checkmark.circle.fill").foregroundStyle(ProcessRunner.locate(name) == nil ? Color.secondary : Color.green)
                        VStack(alignment: .leading, spacing: 2) { Text(name).font(.headline); Text(purpose).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Text(ProcessRunner.locate(name) == nil ? "Not installed" : "Ready").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Divider()
                Text("Install with Homebrew:").font(.caption)
                Text("brew install ffmpeg imagemagick exiftool pandoc\nbrew install --cask libreoffice").font(.system(.caption, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Text("Writing .pages files additionally uses Apple Pages and its macOS Automation permission. Files stay on your Mac.").font(.caption).foregroundStyle(.secondary)
                Button("Refresh") { refresh = UUID() }
                Spacer(minLength: 0)
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading) }.id(refresh).tabItem { Label("Engines", systemImage: "puzzlepiece.extension") }.tag(SettingsTab.engines)
            VStack(spacing: 16) {
                TurnstoneLogo().frame(width: 64, height: 64).foregroundStyle(Color.accentColor)
                Text("Turnstone").font(.title.bold())
                Text("An open source file utility for macOS.").foregroundStyle(.secondary)
                Text("Independent implementation inspired by Tangerine.\nConversions run locally. Originals stay intact.").multilineTextAlignment(.center).font(.callout).foregroundStyle(.secondary)
                Link("Reference product", destination: URL(string: "https://tangerineformac.com/")!)
            }.frame(maxWidth: .infinity, maxHeight: .infinity).tabItem { Label("About", systemImage: "info.circle") }.tag(SettingsTab.about)
        }.padding(12).frame(minWidth: 540, idealWidth: 600, minHeight: 470, idealHeight: 540).background(WindowBackdrop().ignoresSafeArea())
    }

    private func keyPicker(_ title: String, selection: Binding<String>) -> some View {
        Picker(title, selection: Binding(get: { selection.wrappedValue }, set: { value in
            let prior = selection.wrappedValue
            for other in [$conversionKey, $toolsKey, $actionsKey] where other.wrappedValue == value {
                other.wrappedValue = prior
            }
            selection.wrappedValue = value
        })) {
            Text("⇧ Shift").tag("shift"); Text("⌘ Command").tag("command"); Text("⌃ Control").tag("control"); Text("⌥ Option").tag("option")
        }
    }
}
