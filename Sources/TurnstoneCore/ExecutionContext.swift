import Foundation

public final class ProcessRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var processes: [UUID: Process] = [:]
    private var cancelled = false
    public init() {}

    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        let running = Array(processes.values)
        lock.unlock()
        for process in running where process.isRunning { process.terminate() }
    }

    public static func locate(_ name: String) -> URL? {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(name)")
        var paths = [bundled.path, "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)", "/bin/\(name)"]
        if name == "soffice" { paths.insert("/Applications/LibreOffice.app/Contents/MacOS/soffice", at: 1) }
        paths += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/\(name)" }
        return paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }

    public func run(_ executable: URL, arguments: [String]) async throws -> String {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do { continuation.resume(returning: try self.execute(executable, arguments: arguments)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        }, onCancel: { self.cancel() })
    }

    private func execute(_ executable: URL, arguments: [String]) throws -> String {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("turnstone-\(UUID().uuidString).log")
        guard FileManager.default.createFile(atPath: log.path, contents: nil) else {
            throw TurnstoneError.failed("Could not create a conversion log.")
        }
        defer { try? FileManager.default.removeItem(at: log) }
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = handle
        process.standardError = handle
        process.standardInput = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (environment["PATH"] ?? "")
        process.environment = environment
        let id = UUID()
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        do {
            try process.run()
            processes[id] = process
            lock.unlock()
        } catch { lock.unlock(); throw error }
        process.waitUntilExit()
        lock.lock()
        processes.removeValue(forKey: id)
        let wasCancelled = cancelled
        lock.unlock()
        if wasCancelled { throw CancellationError() }
        let input = try FileHandle(forReadingFrom: log)
        defer { try? input.close() }
        let size = try input.seekToEnd()
        // Keep diagnostics bounded even when an external tool produces excessive output.
        try input.seek(toOffset: size > 4_194_304 ? size - 4_194_304 : 0)
        let output = String(decoding: try input.readToEnd() ?? Data(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw TurnstoneError.failed("\(executable.lastPathComponent) failed (\(process.terminationStatus)). \(output.suffix(1600))")
        }
        return output
    }
}

public final class ExecutionContext: @unchecked Sendable {
    public let runner = ProcessRunner()
    public let temporaryDirectory: URL
    private let progress: @Sendable (String) -> Void

    public init(progress: @escaping @Sendable (String) -> Void = { _ in }) throws {
        self.progress = progress
        temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("Turnstone-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: temporaryDirectory) }

    public func checkCancellation() throws {
        try Task.checkCancellation()
        if runner.isCancelled { throw CancellationError() }
    }

    public func report(_ message: String) { progress(message) }

    public func temporaryURL(extension ext: String) -> URL {
        temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
    }

    public func publish(_ temporary: URL, beside source: URL, extension ext: String, suffix: String? = nil) throws -> URL {
        try checkCancellation()
        guard !ext.contains("/"), !ext.contains("\\"), !(suffix ?? "").contains("/"),
              FileManager.default.fileExists(atPath: temporary.path) else {
            throw TurnstoneError.invalid("The conversion did not produce a valid output.")
        }
        var base = source.deletingPathExtension().lastPathComponent
        if source.lastPathComponent.lowercased().hasSuffix(".tar.gz") { base = String(source.lastPathComponent.dropLast(7)) }
        if let suffix, !suffix.isEmpty { base += " \(suffix)" }
        let folder = source.deletingLastPathComponent()
        for number in 1...10_000 {
            let name = base + (number == 1 ? "" : " \(number)") + (ext.isEmpty ? "" : ".\(ext)")
            let destination = folder.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: destination.path) { continue }
            do {
                try FileManager.default.moveItem(at: temporary, to: destination)
                return destination
            } catch {
                if FileManager.default.fileExists(atPath: destination.path), FileManager.default.fileExists(atPath: temporary.path) { continue }
                throw error
            }
        }
        throw TurnstoneError.failed("Could not choose an unused output filename.")
    }
}
