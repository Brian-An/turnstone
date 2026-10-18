import XCTest
@testable import TurnstoneCore

final class ExecutionTests: XCTestCase {
    func testPublishPreservesOriginalAndExistingOutput() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("photo.png")
        let existing = directory.appendingPathComponent("photo.jpg")
        try Data("original".utf8).write(to: original)
        try Data("existing".utf8).write(to: existing)
        let context = try ExecutionContext()
        let staged = context.temporaryURL(extension: "jpg")
        try Data("converted".utf8).write(to: staged)
        let published = try context.publish(staged, beside: original, extension: "jpg")
        XCTAssertEqual(published.lastPathComponent, "photo 2.jpg")
        XCTAssertEqual(try String(contentsOf: original), "original")
        XCTAssertEqual(try String(contentsOf: existing), "existing")
        XCTAssertEqual(try String(contentsOf: published), "converted")
    }

    func testProcessArgumentsStayLiteralAndFailuresPropagate() async throws {
        let runner = ProcessRunner()
        let result = try await runner.run(URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["%s", "$(touch /tmp/should-never-exist); `hello`"])
        XCTAssertEqual(result, "$(touch /tmp/should-never-exist); `hello`")
        do {
            _ = try await runner.run(URL(fileURLWithPath: "/usr/bin/false"), arguments: [])
            XCTFail("A failed child process must fail the job")
        } catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
    }

    func testCancelledRunnerNeverStartsAnotherProcess() async throws {
        let runner = ProcessRunner()
        runner.cancel()
        do {
            _ = try await runner.run(URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["bad"])
            XCTFail("Cancelled runner started a process")
        } catch is CancellationError {} catch { XCTFail("Expected cancellation, got \(error)") }
    }
}
