import XCTest
import AppKit
import PDFKit
@testable import TurnstoneCore

final class DocumentFeatureCoverageTests: XCTestCase {
    private var directory: URL!
    private let marker = "TurnstoneFixture817"

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("Turnstone-DocumentCoverage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testUncoveredAdvertisedDocumentRoutesRetainReadableContentAndSources() async throws {
        guard ProcessRunner.locate("pandoc") != nil, ProcessRunner.locate("soffice") != nil else {
            throw XCTSkip("The document route matrix requires Pandoc and LibreOffice")
        }
        let fixtures = try await makeFixtures()
        // These routes already have content or rendered-page checks in the existing engine tests.
        let covered: [String: Set<String>] = [
            "txt": ["docx", "pdf", "jpg"], "docx": ["txt"], "md": ["pdf", "png", "epub"],
            "epub": ["txt"], "pdf": ["docx", "pptx", "xlsx", "png", "txt"],
            "csv": ["xlsx"], "xlsx": ["tsv", "ods", "pdf"], "pptx": ["pdf", "jpg"],
            "rtfd": ["txt"], "textClipping": ["docx"]
        ]
        var checked = 0
        for ext in fixtures.keys.sorted() {
            let source = try XCTUnwrap(fixtures[ext])
            let original = try snapshot(source)
            for target in try XCTUnwrap(Catalog.conversions[ext]) where target != "pages" && covered[ext]?.contains(target) != true {
                do {
                    let result = try await convert(source, to: target)
                    XCTAssertNotEqual(result, source, "\(ext) -> \(target)")
                    try await assertReadable(result, format: target)
                    XCTAssertEqual(try snapshot(source), original, "\(ext) -> \(target) changes its source")
                    checked += 1
                    print("DOCUMENT ROUTE CHECK \(ext) -> \(target)")
                } catch {
                    XCTFail("\(ext) -> \(target): \(error)")
                }
            }
        }
        XCTAssertEqual(checked, 64)
    }

    func testWebVTTCuesConvertBackToSRTAndPlainTextWithoutChangingSource() async throws {
        let source = directory.appendingPathComponent("captions.vtt")
        let content = "WEBVTT\r\n\r\nintro\r\n00:01.250 --> 00:03.750 align:start\r\n<b>Café</b>\r\nSecond line\r\n\r\n00:04.000 --> 00:05.000\r\n日本語\r\n"
        try content.write(to: source, atomically: true, encoding: .utf8)
        let srt = try await convert(source, to: "srt")
        XCTAssertEqual(try String(contentsOf: srt, encoding: .utf8), "1\n00:00:01,250 --> 00:00:03,750\n<b>Café</b>\nSecond line\n\n2\n00:00:04,000 --> 00:00:05,000\n日本語\n")
        let text = try await convert(source, to: "txt")
        XCTAssertEqual(try String(contentsOf: text, encoding: .utf8), "Café\nSecond line\n日本語\n")
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), content)
    }

    func testSubtitleRejectsReversedAndOutOfRangeTimestamps() async throws {
        let source = directory.appendingPathComponent("invalid-timing.srt")
        for timing in ["00:00:03,000 --> 00:00:02,000", "00:00:61,000 --> 00:01:03,000", "00:60:00,000 --> 01:01:00,000", "00:00:02,000 --> 00:00:02,000"] {
            let bytes = Data("1\n\(timing)\nSubtitle text\n".utf8)
            try bytes.write(to: source)
            let before = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
            do {
                _ = try await convert(source, to: "vtt")
                XCTFail("Invalid subtitle timing must fail: \(timing)")
            } catch {}
            XCTAssertEqual(try Data(contentsOf: source), bytes)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(), before)
        }
        try "1\n99:59:59,999 --> 100:00:00,000\nLong program\n".write(to: source, atomically: true, encoding: .utf8)
        let output = try await convert(source, to: "vtt")
        XCTAssertTrue(try String(contentsOf: output, encoding: .utf8).contains("99:59:59.999 --> 100:00:00.000"))
    }

    func testMalformedDocumentsAndSubtitlesFailWithoutPublishing() async throws {
        let cases: [(String, Data, String)] = [
            ("broken.epub", Data("not an EPUB archive".utf8), "txt"),
            ("empty.textClipping", try PropertyListSerialization.data(fromPropertyList: ["UTI-Data": [:]], format: .binary, options: 0), "txt"),
            ("unsupported.textClipping", try PropertyListSerialization.data(fromPropertyList: ["UTI-Data": ["image/png": Data([1, 2])]], format: .binary, options: 0), "docx"),
            ("broken.srt", Data("1\n00:bad --> 00:02.000\nText\n".utf8), "vtt"),
            ("empty.vtt", Data("WEBVTT\n\nNOTE no cues\n".utf8), "txt")
        ]
        for (name, bytes, target) in cases {
            let source = directory.appendingPathComponent(name)
            try bytes.write(to: source)
            let before = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
            do {
                _ = try await convert(source, to: target)
                XCTFail("\(name) must fail")
            } catch {}
            XCTAssertEqual(try Data(contentsOf: source), bytes)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(), before)
        }
    }

    func testDocumentBatchAndRepeatedExportsAvoidExistingDestinations() async throws {
        let first = directory.appendingPathComponent("one.txt")
        let second = directory.appendingPathComponent("two.txt")
        try "First café".write(to: first, atomically: true, encoding: .utf8)
        try "Second 日本語".write(to: second, atomically: true, encoding: .utf8)
        let sentinel = directory.appendingPathComponent("one.docx")
        let sentinelBytes = Data("keep existing document".utf8)
        try sentinelBytes.write(to: sentinel)
        let request = JobRequest(files: [first, second], operation: .convert("docx"))
        let result = try await ConversionEngine().run(request, context: ExecutionContext())
        let repeated = try await ConversionEngine().run(request, context: ExecutionContext())
        XCTAssertEqual(Set(result + repeated).count, 4)
        XCTAssertEqual(try Data(contentsOf: sentinel), sentinelBytes)
        for (index, output) in result.enumerated() {
            let text = try NSAttributedString(url: output, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil).string
            XCTAssertTrue(text.contains(index == 0 ? "First café" : "Second 日本語"))
        }
        let context = try ExecutionContext()
        context.runner.cancel()
        let before = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        do {
            _ = try await ConversionEngine().run(request, context: context)
            XCTFail("Cancelled documents must not publish")
        } catch is CancellationError {} catch { XCTFail("Expected cancellation, got \(error)") }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(), before)
    }

    func testFixedEPUBRetainsOrderedDistinctPageImagesAndEscapesTitle() async throws {
        let source = directory.appendingPathComponent("Book <A> & B.pdf")
        let pdf = PDFDocument()
        for color in [NSColor.red, NSColor.blue] {
            let image = NSImage(size: NSSize(width: 240, height: 120))
            image.lockFocus()
            color.setFill()
            NSRect(x: 0, y: 0, width: 240, height: 120).fill()
            image.unlockFocus()
            pdf.insert(try XCTUnwrap(PDFPage(image: image)), at: pdf.pageCount)
        }
        XCTAssertTrue(pdf.write(to: source))
        let original = try Data(contentsOf: source)
        var options = EditOptions()
        options.epubLayout = "fixed"
        let outputs = try await ConversionEngine().run(JobRequest(files: [source], operation: .convert("epub"), options: options), context: ExecutionContext())
        let output = try XCTUnwrap(outputs.first)
        let context = try ExecutionContext()
        _ = try await context.runner.run(URL(fileURLWithPath: "/usr/bin/unzip"), arguments: ["-q", output.path, "-d", context.temporaryDirectory.path])
        let root = context.temporaryDirectory.appendingPathComponent("EPUB")
        let package = try String(contentsOf: root.appendingPathComponent("book.opf"), encoding: .utf8)
        XCTAssertTrue(package.contains("Book &lt;A&gt; &amp; B"))
        XCTAssertTrue(package.contains("<spine><itemref idref=\"p0\"/><itemref idref=\"p1\"/></spine>"))
        for index in 0..<2 {
            let page = try String(contentsOf: root.appendingPathComponent("page\(index).xhtml"), encoding: .utf8)
            XCTAssertTrue(page.contains("src=\"page\(index).png\""))
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: root.appendingPathComponent("page\(index).png"))))
            XCTAssertEqual(Double(bitmap.pixelsWide) / Double(bitmap.pixelsHigh), 2, accuracy: 0.01)
            let color = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
            if index == 0 { XCTAssertGreaterThan(color.redComponent - color.blueComponent, 0.5) }
            else { XCTAssertGreaterThan(color.blueComponent - color.redComponent, 0.5) }
        }
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    private func makeFixtures() async throws -> [String: URL] {
        let txt = directory.appendingPathComponent("fixture.txt")
        try "\(marker)\nCafé <special> & characters\nRevenue  42".write(to: txt, atomically: true, encoding: .utf8)
        var fixtures = ["txt": txt]
        for ext in ["docx", "pdf", "md", "epub"] { fixtures[ext] = try await convert(txt, to: ext) }
        let rich = NSAttributedString(string: "\(marker)\nCafé <special> & characters", attributes: [.font: NSFont.systemFont(ofSize: 14)])
        for (ext, type) in [("rtf", NSAttributedString.DocumentType.rtf), ("rtfd", .rtfd)] {
            let source = directory.appendingPathComponent("fixture.\(ext)")
            let wrapper = try rich.fileWrapper(from: NSRange(location: 0, length: rich.length), documentAttributes: [.documentType: type])
            try wrapper.write(to: source, options: .atomic, originalContentsURL: nil)
            fixtures[ext] = source
        }
        let clipping = directory.appendingPathComponent("fixture.textClipping")
        try PropertyListSerialization.data(fromPropertyList: ["UTI-Data": ["public.utf8-plain-text": marker]], format: .binary, options: 0).write(to: clipping)
        fixtures["textClipping"] = clipping
        let csv = directory.appendingPathComponent("cells.csv")
        try "Name,Value\n\(marker),817\n\"Café, Inc\",42\n".write(to: csv, atomically: true, encoding: .utf8)
        fixtures["csv"] = csv
        let xlsx = try await convert(csv, to: "xlsx")
        fixtures["xlsx"] = xlsx
        for ext in ["ods", "tsv"] { fixtures[ext] = try await convert(xlsx, to: ext) }
        fixtures["xls"] = try await officeFixture(xlsx, target: "xls")
        let pptx = try await convert(try XCTUnwrap(fixtures["pdf"]), to: "pptx")
        fixtures["pptx"] = pptx
        fixtures["ppt"] = try await officeFixture(pptx, target: "ppt")
        return fixtures
    }

    private func convert(_ source: URL, to target: String) async throws -> URL {
        let outputs = try await ConversionEngine().run(JobRequest(files: [source], operation: .convert(target)), context: ExecutionContext())
        XCTAssertEqual(outputs.count, 1)
        return try XCTUnwrap(outputs.first)
    }

    private func officeFixture(_ source: URL, target: String) async throws -> URL {
        let soffice = try XCTUnwrap(ProcessRunner.locate("soffice"))
        let out = directory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let profile = directory.appendingPathComponent(UUID().uuidString)
        _ = try await ProcessRunner().run(soffice, arguments: ["-env:UserInstallation=\(profile.absoluteString)", "--headless", "--convert-to", target, "--outdir", out.path, source.path])
        let result = out.appendingPathComponent(source.deletingPathExtension().lastPathComponent).appendingPathExtension(target)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.path))
        return result
    }

    private func assertReadable(_ output: URL, format: String) async throws {
        switch format {
        case "pdf":
            let pdf = try XCTUnwrap(PDFDocument(url: output))
            XCTAssertGreaterThan(pdf.pageCount, 0)
            XCTAssertTrue(pdf.string?.contains(marker) == true, output.lastPathComponent)
        case "png", "jpg":
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: output)))
            XCTAssertGreaterThan(bitmap.pixelsWide, 100)
            XCTAssertGreaterThan(bitmap.pixelsHigh, 100)
            var hasInk = false
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 7) {
                for x in stride(from: 0, to: bitmap.pixelsWide, by: 7) {
                    if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                       min(color.redComponent, color.greenComponent, color.blueComponent) < 0.8 {
                        hasInk = true
                        break
                    }
                }
                if hasInk { break }
            }
            XCTAssertTrue(hasInk, "Page image must contain rendered text")
        case "docx":
            let text = try NSAttributedString(url: output, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil).string
            XCTAssertTrue(text.contains(marker), output.lastPathComponent)
        case "xlsx", "ods":
            let csv = try await officeFixture(output, target: "csv")
            XCTAssertTrue(try String(contentsOf: csv, encoding: .utf8).contains(marker))
        case "epub":
            let context = try ExecutionContext()
            let plain = context.temporaryURL(extension: "txt")
            let pandoc = try XCTUnwrap(ProcessRunner.locate("pandoc"))
            _ = try await context.runner.run(pandoc, arguments: ["--sandbox", output.path, "--to", "plain", "--output", plain.path])
            XCTAssertTrue(try String(contentsOf: plain, encoding: .utf8).contains(marker))
        default:
            XCTAssertTrue(try String(contentsOf: output, encoding: .utf8).contains(marker), output.lastPathComponent)
        }
    }

    private func snapshot(_ source: URL) throws -> [String: Data] {
        if try source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory != true { return ["": try Data(contentsOf: source)] }
        let children = try XCTUnwrap(FileManager.default.enumerator(at: source, includingPropertiesForKeys: [.isRegularFileKey]))
        var result: [String: Data] = [:]
        for case let child as URL in children where try child.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            result[String(child.path.dropFirst(source.path.count))] = try Data(contentsOf: child)
        }
        return result
    }
}
