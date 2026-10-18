import Foundation

public enum FileMove {
    public static func perform(_ files: [URL], to directory: URL) throws -> [URL] {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard directory.isFileURL, manager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else { throw TangerineError.invalid("Choose an existing destination folder.") }
        let destinationFolder = directory.resolvingSymlinksInPath().standardizedFileURL
        let caseSensitive = try directory.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames == true
        let sources = Array(Set(files.map { $0.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent($0.lastPathComponent).standardizedFileURL })).sorted { $0.path < $1.path }
        var moves: [(source: URL, destination: URL)] = []
        var destinationNames: Set<String> = []
        for source in sources {
            guard source.isFileURL, manager.fileExists(atPath: source.path) else { throw TangerineError.invalid("The source is unavailable: \(source.lastPathComponent).") }
            let destination = destinationFolder.appendingPathComponent(source.lastPathComponent).standardizedFileURL
            if source == destination { continue }
            guard !destination.path.hasPrefix(source.path + "/"), !sources.contains(where: { $0 != source && source.path.hasPrefix($0.path + "/") }) else { throw TangerineError.invalid("Move a folder or its contents separately, and choose a destination outside that folder.") }
            let name = source.lastPathComponent.precomposedStringWithCanonicalMapping
            let comparisonName = caseSensitive ? name : name.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            guard !manager.fileExists(atPath: destination.path), destinationNames.insert(comparisonName).inserted else { throw TangerineError.invalid("A file named \(source.lastPathComponent) already exists at the destination or in this selection.") }
            moves.append((source, destination))
        }
        var completed: [URL] = []
        do {
            for move in moves {
                try manager.moveItem(at: move.source, to: move.destination)
                completed.append(move.destination)
            }
        } catch {
            throw TangerineError.failed("Moved \(completed.count) of \(moves.count) items to \(directory.lastPathComponent). \(error.localizedDescription)")
        }
        return completed
    }
}
