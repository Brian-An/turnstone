import XCTest
import AppKit
import PDFKit
@testable import TangerineCore

final class DocumentEngineTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    func testTextToWordAndBackPreservesSourceAndUsesDistinctOutput() async throws {
        let input = directory.appendingPathComponent("Résumé.txt")
        let text = "Hello café\nSecond paragraph with <special> & characters."
        try text.write(to: input, atomically: true, encoding: .utf8)
        let word = try await convert(input, to: "docx")
        XCTAssertEqual(try Data(contentsOf: word).prefix(2), Data([0x50, 0x4b]))
        let recovered = try await convert(word, to: "txt")
        XCTAssertNotEqual(recovered, input)
        XCTAssertTrue(try String(contentsOf: recovered).contains("Hello café"))
        XCTAssertEqual(try String(contentsOf: input), text)
    }

    func testMarkdownRendersReadableMultipagePDFAndAllPageImages() async throws {
        let input = directory.appendingPathComponent("manual.md")
        try ("# Readable heading\n\n" + String(repeating: "A paragraph that must remain readable.\n\n", count: 160)).write(to: input, atomically: true, encoding: .utf8)
        let output = try await convert(input, to: "pdf")
        let pdf = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertGreaterThan(pdf.pageCount, 1)
        XCTAssertTrue(pdf.string?.contains("Readable heading") == true)
        let images = try await DocumentEngine().perform(JobRequest(files: [input], operation: .convert("png")), context: ExecutionContext())
        XCTAssertEqual(images?.count, 1)
        let folder = try XCTUnwrap(images?.first)
        XCTAssertEqual(try folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory, true)
        let pages = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        XCTAssertEqual(pages.count, pdf.pageCount)
        XCTAssertTrue(pages.allSatisfy { $0.pathExtension == "png" && NSImage(contentsOf: $0) != nil })
        XCTAssertEqual(pages.map(\.lastPathComponent).sorted(), (1...pdf.pageCount).map { String(format: "Page %03d.png", $0) })
    }

    func testEPUBRoundTripUsesRealArchive() async throws {
        guard ProcessRunner.locate("pandoc") != nil else { throw XCTSkip("Pandoc not installed") }
        let input = directory.appendingPathComponent("book.md")
        try "# Chapter One\n\nAn EPUB conversion fixture.".write(to: input, atomically: true, encoding: .utf8)
        let epub = try await convert(input, to: "epub")
        let restored = try await convert(epub, to: "txt")
        XCTAssertEqual(try Data(contentsOf: epub).prefix(2), Data([0x50, 0x4b]))
        XCTAssertTrue(try String(contentsOf: restored).contains("conversion fixture"))
    }

    func testPDFToEditableOfficeExportsContainText() async throws {
        let input = directory.appendingPathComponent("report.txt")
        try "Quarter\tRevenue\nQ1\t42\nQ2\t73".write(to: input, atomically: true, encoding: .utf8)
        let pdf = try await convert(input, to: "pdf")
        for ext in ["docx", "pptx", "xlsx"] {
            let output = try await convert(pdf, to: ext)
            let listing = try await ProcessRunner().run(URL(fileURLWithPath: "/usr/bin/unzip"), arguments: ["-p", output.path])
            XCTAssertTrue(listing.contains("Revenue"), "\(ext) loses PDF text")
        }
    }

    func testSpreadsheetConversionsRetainQuotedUnicodeCells() async throws {
        guard ProcessRunner.locate("soffice") != nil else { throw XCTSkip("LibreOffice not installed") }
        let input = directory.appendingPathComponent("cells.csv")
        try "Name,Value\n\"Café, Inc\",42\nOther,73\n".write(to: input, atomically: true, encoding: .utf8)
        let workbook = try await convert(input, to: "xlsx")
        let tsv = try await convert(workbook, to: "tsv")
        let values = try String(contentsOf: tsv, encoding: .utf8)
        XCTAssertTrue(values.contains("Café, Inc"))
        XCTAssertTrue(values.contains("\t42"))
        let ods = try await convert(workbook, to: "ods")
        XCTAssertEqual(try Data(contentsOf: ods).prefix(2), Data([0x50, 0x4b]))
    }

    func testGeneratedOfficeExportsOpenInLibreOffice() async throws {
        guard ProcessRunner.locate("soffice") != nil else { throw XCTSkip("LibreOffice not installed") }
        let input = directory.appendingPathComponent("office.txt")
        try "An editable slide or spreadsheet\nRevenue  42".write(to: input, atomically: true, encoding: .utf8)
        let pdf = try await convert(input, to: "pdf")
        for ext in ["pptx", "xlsx"] {
            let office = try await convert(pdf, to: ext)
            let restored = try await convert(office, to: "pdf")
            XCTAssertTrue(PDFDocument(url: restored)?.string?.contains("Revenue") == true)
        }
    }

    func testFixedEPUBHasUncompressedMimetypeAndEveryPage() async throws {
        let input = directory.appendingPathComponent("fixed.txt")
        try "Fixed layout document".write(to: input, atomically: true, encoding: .utf8)
        let pdf = try await convert(input, to: "pdf")
        var options = EditOptions(); options.epubLayout = "fixed"
        let result = try await DocumentEngine().perform(JobRequest(files: [pdf], operation: .convert("epub"), options: options), context: ExecutionContext())
        let output = try XCTUnwrap(result?.first)
        let data = try Data(contentsOf: output)
        XCTAssertEqual(Array(data[8..<10]), [0, 0])
        XCTAssertEqual(String(decoding: data[30..<38], as: UTF8.self), "mimetype")
        let listing = try await ProcessRunner().run(URL(fileURLWithPath: "/usr/bin/unzip"), arguments: ["-p", output.path, "EPUB/book.opf"])
        XCTAssertTrue(listing.contains("pre-paginated"))
        XCTAssertTrue(listing.contains("page0.xhtml"))
    }

    func testMixedScannedPDFRetainsOCRTextOnItsOwnSlide() async throws {
        let input = directory.appendingPathComponent("mixed.txt")
        try "First editable page".write(to: input, atomically: true, encoding: .utf8)
        let pdfURL = try await convert(input, to: "pdf")
        let pdf = try XCTUnwrap(PDFDocument(url: pdfURL))
        let image = NSImage(size: NSSize(width: 1400, height: 400))
        image.lockFocus()
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 1400, height: 400).fill()
        ("SCANNED REVENUE 817" as NSString).draw(at: NSPoint(x: 60, y: 180), withAttributes: [.font: NSFont.systemFont(ofSize: 72), .foregroundColor: NSColor.black])
        image.unlockFocus()
        let scanned = try XCTUnwrap(PDFPage(image: image))
        pdf.insert(scanned, at: pdf.pageCount)
        XCTAssertTrue(pdf.write(to: pdfURL))
        let output = try await convert(pdfURL, to: "pptx")
        let xml = try await ProcessRunner().run(URL(fileURLWithPath: "/usr/bin/unzip"), arguments: ["-p", output.path, "ppt/slides/slide2.xml"])
        XCTAssertTrue(xml.contains("817"))
        if ProcessRunner.locate("soffice") != nil {
            let folder = try await convert(output, to: "jpg")
            XCTAssertEqual(try folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory, true)
            let pages = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            XCTAssertEqual(pages.count, 2)
            XCTAssertTrue(pages.allSatisfy { $0.pathExtension == "jpg" && NSImage(contentsOf: $0) != nil })
        }
    }

    func testSinglePageDocumentImageExportRemainsAFile() async throws {
        let input = directory.appendingPathComponent("single.txt")
        try "One page".write(to: input, atomically: true, encoding: .utf8)
        let output = try await convert(input, to: "jpg")
        XCTAssertEqual(output.pathExtension, "jpg")
        XCTAssertEqual(try output.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile, true)
        XCTAssertNotNil(NSImage(contentsOf: output))
    }

    func testUTF16TextReadsWithoutLosingUnicode() async throws {
        let input = directory.appendingPathComponent("unicode.txt")
        try "Café 日本語".write(to: input, atomically: true, encoding: .utf16)
        let word = try await convert(input, to: "docx")
        let recovered = try await convert(word, to: "txt")
        XCTAssertTrue(try String(contentsOf: recovered).contains("Café 日本語"))
    }

    func testRTFDPackageAndModernTextClippingReadAsDocuments() async throws {
        let rich = NSAttributedString(string: "Rich text fixture", attributes: [.font: NSFont.systemFont(ofSize: 14)])
        let rtfd = directory.appendingPathComponent("rich.rtfd")
        let wrapper = try rich.fileWrapper(from: NSRange(location: 0, length: rich.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
        try wrapper.write(to: rtfd, options: .atomic, originalContentsURL: nil)
        let outputs = try await ConversionEngine().run(JobRequest(files: [rtfd], operation: .convert("txt")), context: ExecutionContext())
        XCTAssertTrue(try String(contentsOf: outputs[0]).contains("Rich text fixture"))
        let clipping = directory.appendingPathComponent("clipping.textClipping")
        let values = ["UTI-Data": ["public.utf8-plain-text": Data("Clipped café".utf8)]]
        try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0).write(to: clipping)
        let restored = try await convert(clipping, to: "docx")
        let text = try await convert(restored, to: "txt")
        XCTAssertTrue(try String(contentsOf: text).contains("Clipped café"))
    }

    func testMalformedDocumentFailsAndPreservesInput() async throws {
        let input = directory.appendingPathComponent("broken.docx")
        let bytes = Data("not an Office document".utf8)
        try bytes.write(to: input)
        do {
            _ = try await convert(input, to: "txt")
            XCTFail("Malformed DOCX must fail")
        } catch { XCTAssertEqual(try Data(contentsOf: input), bytes) }
    }

    func testUnrelatedRouteReturnsNil() async throws {
        let result = try await DocumentEngine().perform(JobRequest(files: [directory.appendingPathComponent("audio.mp3")], operation: .convert("wav")), context: ExecutionContext())
        XCTAssertNil(result)
    }

    private func convert(_ url: URL, to ext: String) async throws -> URL {
        let outputs = try await DocumentEngine().perform(JobRequest(files: [url], operation: .convert(ext)), context: ExecutionContext())
        return try XCTUnwrap(outputs?.first)
    }
}
