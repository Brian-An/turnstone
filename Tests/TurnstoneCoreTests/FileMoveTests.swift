import XCTest
@testable import TurnstoneCore

final class FileMoveTests: XCTestCase {
    func testCollisionInLaterItemLeavesEntireSelectionUnmoved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let first = root.appendingPathComponent("first.txt"), second = root.appendingPathComponent("second.txt")
        try "first".write(to: first, atomically: true, encoding: .utf8)
        try "second".write(to: second, atomically: true, encoding: .utf8)
        try "existing".write(to: target.appendingPathComponent(second.lastPathComponent), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try FileMove.perform([first, second], to: target))
        XCTAssertEqual(try String(contentsOf: first), "first")
        XCTAssertEqual(try String(contentsOf: second), "second")
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent(second.lastPathComponent)), "existing")
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent(first.lastPathComponent).path))
    }

    func testCaseInsensitiveDestinationCollisionsLeaveBothSources() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target"), other = root.appendingPathComponent("other")
        for directory in [target, other] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        if try target.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames == true { throw XCTSkip("Case-sensitive volume") }
        let first = root.appendingPathComponent("Item.txt"), second = other.appendingPathComponent("item.txt")
        for file in [first, second] { try "content".write(to: file, atomically: true, encoding: .utf8) }
        XCTAssertThrowsError(try FileMove.perform([first, second], to: target))
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }

    func testMovesWholeSelectionAndRejectsDuplicateDestinationNames() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target"), other = root.appendingPathComponent("other")
        for directory in [target, other] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let first = root.appendingPathComponent("item.txt"), duplicate = other.appendingPathComponent("item.txt")
        for file in [first, duplicate] { try "content".write(to: file, atomically: true, encoding: .utf8) }
        XCTAssertThrowsError(try FileMove.perform([first, duplicate], to: target))
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        let results = try FileMove.perform([first], to: target)
        XCTAssertEqual(results, [target.appendingPathComponent("item.txt")])
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertEqual(try String(contentsOf: results[0]), "content")
    }
}
