import AppKit
import Foundation
import PDFKit

public struct DocumentEngine {
    private let documents: Set<String> = ["docx", "pages", "md", "txt", "rtf", "rtfd", "textClipping", "epub", "html"]
    private let spreadsheets: Set<String> = ["xlsx", "xls", "ods", "csv", "tsv"]
    public init() {}

    public func perform(_ request: JobRequest, context: ExecutionContext) async throws -> [URL]? {
        guard case .convert(let target) = request.operation, !request.files.isEmpty else { return nil }
        let inputs = request.files.map { Catalog.fileExtension($0) }
        guard inputs.allSatisfy({ documents.contains($0) || spreadsheets.contains($0) || ["pdf", "ppt", "pptx"].contains($0) }),
              ["docx", "pages", "txt", "md", "rtf", "rtfd", "html", "epub", "pdf", "png", "jpg", "pptx", "xlsx", "ods", "csv", "tsv"].contains(target) else { return nil }
        if inputs.allSatisfy({ $0 == "pdf" }) && ["txt", "md", "png", "jpg"].contains(target) { return nil }
        var outputs: [URL] = []
        for source in request.files {
            try context.checkCancellation()
            context.report("Converting \(source.lastPathComponent) to \(target.uppercased())")
            let input = Catalog.fileExtension(source)
            if spreadsheets.contains(input) || ["ppt", "pptx"].contains(input) {
                let officeTarget = ["png", "jpg"].contains(target) ? "pdf" : target
                let converted = try await office(source, to: officeTarget, context: context)
                if officeTarget != target { outputs += try renderPDF(converted, beside: source, format: target, context: context) }
                else { outputs.append(try context.publish(converted, beside: source, extension: target)) }
                continue
            }
            if input == "pdf", target == "pptx" || target == "xlsx" {
                let output = context.temporaryURL(extension: target)
                let text = target == "xlsx" ? try await NativeEngine.pdfText(at: source) : ""
                try await writeEditableOffice(text: text, pdf: source, target: target, to: output, context: context)
                outputs.append(try context.publish(output, beside: source, extension: target))
                continue
            }
            if input == "pdf", target == "epub", request.options.epubLayout == "fixed" {
                let output = context.temporaryURL(extension: target)
                try fixedEPUB(source, to: output, context: context)
                outputs.append(try context.publish(output, beside: source, extension: target))
                continue
            }
            var readableSource = source
            if input == "pages" { readableSource = try await office(source, to: "docx", context: context) }
            let attributed: NSAttributedString
            if input == "pdf" { attributed = plain(try await NativeEngine.pdfText(at: source)) }
            else if input == "epub" || input == "md" || input == "html" {
                if let pandoc = ProcessRunner.locate("pandoc") {
                    let interim = context.temporaryURL(extension: "docx")
                    _ = try await context.runner.run(pandoc, arguments: ["--sandbox", readableSource.path, "--from", input == "epub" ? "epub" : pandocFormat(input), "--to", "docx", "--output", interim.path])
                    attributed = try read(interim)
                } else if input == "md" { attributed = plain(try String(contentsOf: source, encoding: .utf8)) }
                else { throw TangerineError.missingDependency("Pandoc") }
            } else { attributed = try read(readableSource) }
            let output = context.temporaryURL(extension: target == "pages" ? "docx" : target)
            switch target {
            case "txt": try attributed.string.write(to: output, atomically: true, encoding: .utf8)
            case "md", "html", "epub":
                guard let pandoc = ProcessRunner.locate("pandoc") else { throw TangerineError.missingDependency("Pandoc") }
                let interim = context.temporaryURL(extension: "docx")
                try write(attributed, to: interim, type: .officeOpenXML)
                _ = try await context.runner.run(pandoc, arguments: ["--sandbox", interim.path, "--from", "docx", "--to", pandocFormat(target), "--standalone", "--metadata", "title=\(source.deletingPathExtension().lastPathComponent)", "--output", output.path])
            case "docx", "pages": try write(attributed, to: output, type: .officeOpenXML)
            case "rtf": try write(attributed, to: output, type: .rtf)
            case "rtfd":
                let wrapper = try attributed.fileWrapper(from: NSRange(location: 0, length: attributed.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
                try wrapper.write(to: output, options: .atomic, originalContentsURL: nil)
            case "pdf", "png", "jpg":
                let pdf = target == "pdf" ? output : context.temporaryURL(extension: "pdf")
                try renderText(attributed, to: pdf, context: context)
                if target != "pdf" {
                    outputs += try renderPDF(pdf, beside: source, format: target, context: context)
                    continue
                }
            default: throw TangerineError.unsupported("This document conversion is unavailable.")
            }
            if target == "pages" {
                let pages = context.temporaryURL(extension: "pages")
                try await savePages(output, to: pages, context: context)
                outputs.append(try context.publish(pages, beside: source, extension: target))
            } else { outputs.append(try context.publish(output, beside: source, extension: target)) }
        }
        return outputs
    }

    private func pandocFormat(_ ext: String) -> String {
        ["md": "markdown", "txt": "plain", "html": "html5", "epub": "epub3"][ext] ?? ext
    }

    private func plain(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.black])
    }

    private func read(_ url: URL) throws -> NSAttributedString {
        let ext = Catalog.fileExtension(url)
        if ext == "txt" { return plain(try String(contentsOf: url)) }
        if ext == "textClipping" {
            let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
            guard let dictionary = plist as? [String: NSObject], let values = dictionary["UTI-Data"] as? [String: NSObject] else {
                throw TangerineError.unsupported("This text clipping has no readable text representation.")
            }
            for key in ["public.utf8-plain-text", "NSStringPboardType"] {
                if let text = values[key] as? String { return plain(text) }
                if let data = values[key] as? Data, let text = String(data: data, encoding: .utf8) { return plain(text) }
            }
            if let data = values["public.rtf"] as? Data { return try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) }
            throw TangerineError.unsupported("This text clipping has no supported text representation.")
        }
        let type: NSAttributedString.DocumentType
        switch ext {
        case "docx":
            guard try Data(contentsOf: url).prefix(2) == Data([0x50, 0x4b]) else { throw TangerineError.invalid("The Word document is not a valid DOCX archive.") }
            type = .officeOpenXML
        case "rtf": type = .rtf
        case "rtfd": type = .rtfd
        default: throw TangerineError.unsupported("Cannot read \(ext.uppercased()) as a text document.")
        }
        return try NSAttributedString(url: url, options: [.documentType: type], documentAttributes: nil)
    }

    private func write(_ text: NSAttributedString, to url: URL, type: NSAttributedString.DocumentType) throws {
        try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: type]).write(to: url)
    }

    private func renderText(_ text: NSAttributedString, to url: URL, context: ExecutionContext) throws {
        let content = NSMutableAttributedString(attributedString: text)
        if content.length == 0 { content.append(plain(" ")) }
        let storage = NSTextStorage(attributedString: content)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(url: url as CFURL), let pdf = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw TangerineError.failed("Could not create the PDF document.")
        }
        var drawn = 0
        repeat {
            try context.checkCancellation()
            let container = NSTextContainer(containerSize: CGSize(width: 504, height: 684))
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            let range = layout.glyphRange(for: container)
            guard range.length > 0 else { break }
            pdf.beginPDFPage([kCGPDFContextMediaBox as String: NSValue(rect: page)] as CFDictionary)
            pdf.saveGState()
            pdf.translateBy(x: 0, y: page.height)
            pdf.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: pdf, flipped: true)
            layout.drawBackground(forGlyphRange: range, at: CGPoint(x: 54, y: 54))
            layout.drawGlyphs(forGlyphRange: range, at: CGPoint(x: 54, y: 54))
            NSGraphicsContext.restoreGraphicsState()
            pdf.restoreGState()
            pdf.endPDFPage()
            drawn = NSMaxRange(range)
        } while drawn < layout.numberOfGlyphs
        pdf.closePDF()
        guard drawn > 0 else { throw TangerineError.failed("The document contains no renderable content.") }
    }

    private func renderPDF(_ url: URL, beside source: URL, format: String, context: ExecutionContext) throws -> [URL] {
        guard let pdf = PDFDocument(url: url), pdf.pageCount > 0 else { throw TangerineError.invalid("The generated PDF has no readable pages.") }
        let folder = context.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        if pdf.pageCount > 1 { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        var singlePage: URL?
        for index in 0..<pdf.pageCount {
            try context.checkCancellation()
            guard let page = pdf.page(at: index) else { throw TangerineError.failed("Could not read page \(index + 1).") }
            let image = page.thumbnail(of: CGSize(width: page.bounds(for: .mediaBox).width * 300 / 72, height: page.bounds(for: .mediaBox).height * 300 / 72), for: .mediaBox)
            guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                  let data = bitmap.representation(using: format == "jpg" ? .jpeg : .png, properties: [.compressionFactor: 0.9]) else { throw TangerineError.failed("Could not render page \(index + 1).") }
            let output = pdf.pageCount > 1 ? folder.appendingPathComponent(String(format: "Page %03d.%@", index + 1, format)) : context.temporaryURL(extension: format)
            try data.write(to: output)
            singlePage = output
        }
        if pdf.pageCount > 1 { return [try context.publish(folder, beside: source, extension: "", suffix: format.uppercased() + " Pages")] }
        guard let output = singlePage else { throw TangerineError.failed("The document contains no renderable pages.") }
        return [try context.publish(output, beside: source, extension: format)]
    }

    private func office(_ source: URL, to target: String, context: ExecutionContext) async throws -> URL {
        guard let executable = ProcessRunner.locate("soffice") else { throw TangerineError.missingDependency("LibreOffice") }
        let directory = context.temporaryURL(extension: "office")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let profile = context.temporaryURL(extension: "profile")
        let filters = ["xlsx": "xlsx:Calc MS Excel 2007 XML", "ods": "ods:calc8", "csv": "csv:Text - txt - csv (StarCalc):44,34,76,1,,0,false,true,true,false,false,0", "tsv": "tsv:Text - txt - csv (StarCalc):9,34,76,1,,0,false,true,true,false,false,0", "docx": "docx:Office Open XML Text"]
        var args = ["-env:UserInstallation=\(profile.absoluteString)", "--headless", "--nologo", "--nodefault", "--norestore"]
        let input = Catalog.fileExtension(source)
        if input == "csv" || input == "tsv" { args += ["--infilter=Text - txt - csv (StarCalc):\(input == "tsv" ? 9 : 44),34,76,1,,0,false,true,true,false,false,0"] }
        args += ["--convert-to", filters[target] ?? target, "--outdir", directory.path, source.path]
        let log = try await context.runner.run(executable, arguments: args)
        let result = directory.appendingPathComponent(source.deletingPathExtension().lastPathComponent).appendingPathExtension(target)
        guard FileManager.default.fileExists(atPath: result.path), (try result.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 0 else {
            throw TangerineError.failed("LibreOffice could not convert this document. \(log.suffix(700))")
        }
        return result
    }

    private func savePages(_ source: URL, to output: URL, context: ExecutionContext) async throws {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iWork.Pages") != nil else { throw TangerineError.missingDependency("Apple Pages") }
        // File paths travel as argv values so document names cannot become AppleScript code.
        let script = """
        on run argv
            with timeout of 120 seconds
                tell application id "com.apple.iWork.Pages"
                    set convertedDocument to open (POSIX file (item 1 of argv))
                    try
                        save convertedDocument in (POSIX file (item 2 of argv)) as Pages Format
                        close convertedDocument saving no
                    on error errorText number errorNumber
                        try
                            close convertedDocument saving no
                        end try
                        error errorText number errorNumber
                    end try
                end tell
            end timeout
        end run
        """
        let file = context.temporaryURL(extension: "applescript")
        try script.write(to: file, atomically: true, encoding: .utf8)
        _ = try await context.runner.run(URL(fileURLWithPath: "/usr/bin/osascript"), arguments: [file.path, source.path, output.path])
        guard FileManager.default.fileExists(atPath: output.path) else { throw TangerineError.failed("Pages did not save the converted document.") }
    }

    private func xml(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .unicodeScalars.filter { $0.value >= 32 || [9, 10, 13].contains($0.value) }.map(String.init).joined()
    }

    private func writeEditableOffice(text: String, pdf url: URL, target: String, to output: URL, context: ExecutionContext) async throws {
        let declaration = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
        let relationships = "http://schemas.openxmlformats.org/package/2006/relationships"
        let officeRelationships = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        var files: [String: Data] = [:]
        func add(_ name: String, _ value: String) { files[name] = Data((declaration + value).utf8) }
        if target == "xlsx" {
            add("_rels/.rels", "<Relationships xmlns=\"\(relationships)\"><Relationship Id=\"rId1\" Type=\"\(officeRelationships)/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>")
            add("xl/workbook.xml", "<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"\(officeRelationships)\"><sheets><sheet name=\"Extracted PDF\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>")
            add("xl/_rels/workbook.xml.rels", "<Relationships xmlns=\"\(relationships)\"><Relationship Id=\"rId1\" Type=\"\(officeRelationships)/worksheet\" Target=\"worksheets/sheet1.xml\"/></Relationships>")
            var rows = ""
            for (row, line) in text.components(separatedBy: .newlines).enumerated() {
                // PDF text has no spreadsheet schema; tabs and repeated spaces are the only inferred column separators.
                let cells = line.components(separatedBy: "\t").flatMap { $0.components(separatedBy: "  ").filter { !$0.isEmpty } }
                var values = ""
                for (column, value) in cells.enumerated() {
                    var number = column + 1
                    var letters = ""
                    while number > 0 { number -= 1; letters = String(UnicodeScalar(65 + number % 26)!) + letters; number /= 26 }
                    values += "<c r=\"\(letters)\(row + 1)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(xml(value))</t></is></c>"
                }
                rows += "<row r=\"\(row + 1)\">\(values)</row>"
            }
            add("xl/worksheets/sheet1.xml", "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData>\(rows)</sheetData></worksheet>")
            add("[Content_Types].xml", "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/><Override PartName=\"/xl/worksheets/sheet1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/></Types>")
        } else {
            guard let pdf = PDFDocument(url: url), pdf.pageCount > 0 else { throw TangerineError.invalid("The PDF contains no pages.") }
            var pageTexts: [String] = []
            for index in 0..<pdf.pageCount {
                try context.checkCancellation()
                guard let page = pdf.page(at: index) else { continue }
                if let text = page.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { pageTexts.append(text) }
                else {
                    let singlePage = PDFDocument()
                    singlePage.insert(page, at: 0)
                    let temporary = context.temporaryURL(extension: "pdf")
                    guard singlePage.write(to: temporary) else { throw TangerineError.failed("Could not read the scanned PDF page.") }
                    pageTexts.append(try await NativeEngine.pdfText(at: temporary))
                }
            }
            // The PPTX is editable text reflow. Complex graphics and precise PDF typography are not reconstructed.
            add("_rels/.rels", "<Relationships xmlns=\"\(relationships)\"><Relationship Id=\"rId1\" Type=\"\(officeRelationships)/officeDocument\" Target=\"ppt/presentation.xml\"/></Relationships>")
            var slides = "", relations = "", overrides = ""
            for (index, pageText) in pageTexts.enumerated() {
                let number = index + 1
                slides += "<p:sldId id=\"\(255 + number)\" r:id=\"rId\(number)\"/>"
                relations += "<Relationship Id=\"rId\(number)\" Type=\"\(officeRelationships)/slide\" Target=\"slides/slide\(number).xml\"/>"
                overrides += "<Override PartName=\"/ppt/slides/slide\(number).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slide+xml\"/>"
                let paragraphs = pageText.components(separatedBy: .newlines).map { "<a:p><a:r><a:rPr lang=\"en-US\" sz=\"1400\"/><a:t>\(xml($0))</a:t></a:r></a:p>" }.joined()
                add("ppt/slides/slide\(number).xml", "<p:sld xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:r=\"\(officeRelationships)\" xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\"><p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"0\" cy=\"0\"/><a:chOff x=\"0\" y=\"0\"/><a:chExt cx=\"0\" cy=\"0\"/></a:xfrm></p:grpSpPr><p:sp><p:nvSpPr><p:cNvPr id=\"2\" name=\"Extracted page text\"/><p:cNvSpPr txBox=\"1\"/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x=\"457200\" y=\"457200\"/><a:ext cx=\"8229600\" cy=\"5943600\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></p:spPr><p:txBody><a:bodyPr wrap=\"square\"><a:normAutofit/></a:bodyPr><a:lstStyle/>\(paragraphs)</p:txBody></p:sp></p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>")
            }
            add("ppt/presentation.xml", "<p:presentation xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:r=\"\(officeRelationships)\" xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\"><p:sldIdLst>\(slides)</p:sldIdLst><p:sldSz cx=\"9144000\" cy=\"6858000\"/><p:notesSz cx=\"6858000\" cy=\"9144000\"/></p:presentation>")
            add("ppt/_rels/presentation.xml.rels", "<Relationships xmlns=\"\(relationships)\">\(relations)</Relationships>")
            add("[Content_Types].xml", "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/ppt/presentation.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml\"/>\(overrides)</Types>")
        }
        try archive(files, to: output)
    }

    private func fixedEPUB(_ url: URL, to output: URL, context: ExecutionContext) throws {
        guard let pdf = PDFDocument(url: url), pdf.pageCount > 0 else { throw TangerineError.invalid("The PDF contains no pages.") }
        var files: [String: Data] = ["mimetype": Data("application/epub+zip".utf8)]
        files["META-INF/container.xml"] = Data("<?xml version=\"1.0\"?><container version=\"1.0\" xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\"><rootfiles><rootfile full-path=\"EPUB/book.opf\" media-type=\"application/oebps-package+xml\"/></rootfiles></container>".utf8)
        var manifest = "<item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>", spine = "", navigation = ""
        for index in 0..<pdf.pageCount {
            try context.checkCancellation()
            guard let page = pdf.page(at: index) else { continue }
            let size = page.bounds(for: .mediaBox).size
            let image = page.thumbnail(of: CGSize(width: size.width * 2, height: size.height * 2), for: .mediaBox)
            guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let data = bitmap.representation(using: .png, properties: [:]) else { throw TangerineError.failed("Could not render an EPUB page.") }
            files["EPUB/page\(index).png"] = data
            let pageHTML = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>Page \(index + 1)</title><meta name=\"viewport\" content=\"width=\(Int(size.width)),height=\(Int(size.height))\"/></head><body style=\"margin:0\"><img src=\"page\(index).png\" alt=\"Page \(index + 1)\" style=\"width:100%;height:100%\"/></body></html>"
            files["EPUB/page\(index).xhtml"] = Data(pageHTML.utf8)
            manifest += "<item id=\"p\(index)\" href=\"page\(index).xhtml\" media-type=\"application/xhtml+xml\"/><item id=\"i\(index)\" href=\"page\(index).png\" media-type=\"image/png\"/>"
            spine += "<itemref idref=\"p\(index)\"/>"
            navigation += "<li><a href=\"page\(index).xhtml\">Page \(index + 1)</a></li>"
        }
        files["EPUB/nav.xhtml"] = Data("<?xml version=\"1.0\"?><html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\"><head><title>Contents</title></head><body><nav epub:type=\"toc\"><ol>\(navigation)</ol></nav></body></html>".utf8)
        let title = xml(url.deletingPathExtension().lastPathComponent)
        let modified = ISO8601DateFormatter().string(from: Date())
        files["EPUB/book.opf"] = Data("<?xml version=\"1.0\"?><package xmlns=\"http://www.idpf.org/2007/opf\" version=\"3.0\" unique-identifier=\"id\"><metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:identifier id=\"id\">urn:uuid:\(UUID().uuidString)</dc:identifier><dc:title>\(title)</dc:title><dc:language>en</dc:language><meta property=\"dcterms:modified\">\(modified)</meta><meta property=\"rendition:layout\">pre-paginated</meta><meta property=\"rendition:orientation\">auto</meta></metadata><manifest>\(manifest)</manifest><spine>\(spine)</spine></package>".utf8)
        try archive(files, to: output)
    }

    private func archive(_ files: [String: Data], to output: URL) throws {
        // Stored ZIP entries keep EPUB's required first mimetype entry uncompressed.
        var bytes = Data(), central = Data()
        func word(_ value: UInt16) -> Data { var little = value.littleEndian; return withUnsafeBytes(of: &little) { Data($0) } }
        func dword(_ value: UInt32) -> Data { var little = value.littleEndian; return withUnsafeBytes(of: &little) { Data($0) } }
        let names = (files["mimetype"] == nil ? [] : ["mimetype"]) + files.keys.filter { $0 != "mimetype" }.sorted()
        guard names.count < Int(UInt16.max) else { throw TangerineError.invalid("The document has too many archive entries.") }
        for name in names {
            guard let contents = files[name], contents.count < Int(UInt32.max), bytes.count < Int(UInt32.max) else { throw TangerineError.invalid("The document exceeds ZIP size limits.") }
            let nameData = Data(name.utf8), size = UInt32(contents.count), offset = UInt32(bytes.count)
            var crc: UInt32 = 0xffffffff
            for byte in contents { crc ^= UInt32(byte); for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xedb88320 : 0) } }
            crc ^= 0xffffffff
            for part in [dword(0x04034b50), word(20), word(0x0800), word(0), word(0), word(0), dword(crc), dword(size), dword(size), word(UInt16(nameData.count)), word(0), nameData, contents] { bytes.append(part) }
            for part in [dword(0x02014b50), word(20), word(20), word(0x0800), word(0), word(0), word(0), dword(crc), dword(size), dword(size), word(UInt16(nameData.count)), word(0), word(0), word(0), word(0), dword(0), dword(offset), nameData] { central.append(part) }
        }
        guard bytes.count < Int(UInt32.max), central.count < Int(UInt32.max) else { throw TangerineError.invalid("The document exceeds ZIP size limits.") }
        let offset = UInt32(bytes.count)
        bytes += central
        for part in [dword(0x06054b50), word(0), word(0), word(UInt16(names.count)), word(UInt16(names.count)), dword(UInt32(central.count)), dword(offset), word(0)] { bytes.append(part) }
        try bytes.write(to: output, options: .atomic)
    }
}
