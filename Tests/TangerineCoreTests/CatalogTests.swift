import XCTest
import AppKit
@testable import TangerineCore

final class CatalogTests: XCTestCase {
    func testEveryPublicConversionRouteAndInputOnlyFormat() {
        XCTAssertEqual(Catalog.conversions.count, 45)
        XCTAssertEqual(Catalog.conversions.values.reduce(0) { $0 + $1.count }, 275)
        XCTAssertEqual(Catalog.outputs(for: [URL(fileURLWithPath: "/photo.svg")]), ["jpg", "png", "webp", "heic", "tiff", "avif", "bmp", "pdf"])
        XCTAssertFalse(Catalog.conversions.values.flatMap { $0 }.contains("rar"))
    }

    func testMixedSelectionOnlyOffersCommonOutputs() {
        XCTAssertEqual(Catalog.outputs(for: [URL(fileURLWithPath: "/x.jpg"), URL(fileURLWithPath: "/x.png")]), ["webp", "heic", "tiff", "avif", "bmp", "pdf"])
        XCTAssertTrue(Catalog.outputs(for: [URL(fileURLWithPath: "/x.jpg"), URL(fileURLWithPath: "/x.mp3")]).isEmpty)
        XCTAssertTrue(Catalog.outputs(for: [URL(fileURLWithPath: "/unknown.xyz")]).isEmpty)
    }

    func testRealRTFDPackageOffersDocumentConversionsWhileFoldersDoNot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let package = root.appendingPathComponent("rich.rtfd")
        let text = NSAttributedString(string: "Genuine RTFD package")
        let wrapper = try text.fileWrapper(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
        try wrapper.write(to: package, options: .atomic, originalContentsURL: nil)
        XCTAssertTrue(Catalog.outputs(for: [package]).contains("txt"))
        XCTAssertTrue(Catalog.outputs(for: [root]).isEmpty)
        XCTAssertTrue(Catalog.tools(for: [package]).isEmpty)
    }

    func testBatchToolsRequireCompatibleFiles() {
        XCTAssertEqual(Catalog.tools(for: [URL(fileURLWithPath: "/x.jpg"), URL(fileURLWithPath: "/y.png")]), [.compress, .metadata, .cropImage, .createPDF, .collage])
        XCTAssertTrue(Catalog.tools(for: [URL(fileURLWithPath: "/x.jpg"), URL(fileURLWithPath: "/y.pdf")]).isEmpty)
        XCTAssertEqual(Catalog.fileExtension(URL(fileURLWithPath: "/archive.TAR.GZ")), "gz")
    }
}
