import SwiftUI
import AppKit
import TangerineCore

struct PhotoCanvas: View {
    let image: NSImage
    let tool: ToolID
    @Binding var options: EditOptions
    @Binding var selected: UUID?
    let kind: String
    let annotationColor: ColorValue
    let annotationText: String
    let stamp: URL?
    @State private var drawing: Drawing?
    @State private var manipulation: Manipulation?
    @FocusState private var focused: Bool

    private struct Drawing {
        var start: CGPoint
        var points: [CanvasPoint]
        var rect: UnitRect
    }

    private struct Manipulation {
        var id: UUID?
        var rect: UnitRect
        var points: [CanvasPoint]
    }

    private struct Region: Identifiable {
        var id: UUID
        var rect: UnitRect
    }

    private enum Corner: Int, CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight
        var left: Bool { self == .topLeft || self == .bottomLeft }
        var top: Bool { self == .topLeft || self == .topRight }
    }

    private var editable: Bool { [.cropImage, .annotateImage, .redactImage].contains(tool) }
    private var regions: [Region] {
        tool == .annotateImage ? options.annotations.map { Region(id: $0.id, rect: $0.rect) } : options.redactions.map { Region(id: $0.id, rect: $0.rect) }
    }

    var body: some View {
        GeometryReader { geometry in
            let size = fittedSize(in: geometry.size)
            ZStack(alignment: .topLeading) {
                Image(nsImage: image).resizable().interpolation(.high).frame(width: size.width, height: size.height).allowsHitTesting(false)
                if editable {
                    Rectangle().fill(Color.clear).contentShape(Rectangle()).gesture(drawGesture(size: size))
                        .accessibilityLabel(tool == .cropImage ? "Draw a crop selection" : "Draw a new \(tool == .redactImage ? "redaction" : kind)")
                    if tool == .cropImage {
                        cropOverlay(size: size)
                    } else {
                        ForEach(regions) { region in regionOverlay(region, size: size) }
                    }
                    if let drawing {
                        let rect = screenRect(drawing.rect, size: size)
                        Rectangle().stroke(Color.orange, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                            .frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY).allowsHitTesting(false)
                        if kind == "pen", tool == .annotateImage {
                            Path { path in
                                for (index, point) in drawing.points.enumerated() {
                                    let position = CGPoint(x: point.x * size.width, y: point.y * size.height)
                                    if index == 0 { path.move(to: position) } else { path.addLine(to: position) }
                                }
                            }.stroke(Color(annotationColor), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)).allowsHitTesting(false)
                        }
                    }
                }
            }
            .frame(width: size.width, height: size.height).clipped()
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
        .focusable(editable).focused($focused)
        .onDeleteCommand(perform: deleteSelection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Photo canvas")
        .accessibilityHint(editable ? "Drag to create a selection. Drag a selected region or its handles to adjust it. Press Delete to remove the selected annotation or redaction." : "Image preview")
    }

    private func fittedSize(in available: CGSize) -> CGSize {
        guard image.size.width > 0, image.size.height > 0 else { return available }
        let scale = min(available.width / image.size.width, available.height / image.size.height)
        return CGSize(width: max(1, image.size.width * scale), height: max(1, image.size.height * scale))
    }

    private func screenRect(_ rect: UnitRect, size: CGSize) -> CGRect {
        CGRect(x: rect.x * size.width, y: rect.y * size.height, width: max(2, rect.width * size.width), height: max(2, rect.height * size.height))
    }

    private func cropOverlay(size: CGSize) -> some View {
        let rect = screenRect(options.crop, size: size)
        return ZStack(alignment: .topLeading) {
            Path { path in
                path.addRect(CGRect(origin: .zero, size: size)); path.addRect(rect)
            }.fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true)).allowsHitTesting(false)
            Rectangle().fill(Color.clear).contentShape(Rectangle())
                .overlay(Rectangle().stroke(Color.white, lineWidth: 1.5))
                .overlay(cropGrid.allowsHitTesting(false))
                .frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
                .gesture(moveGesture(id: nil, size: size)).accessibilityLabel("Move crop selection")
            handles(id: nil, rect: options.crop, size: size)
        }
    }

    private var cropGrid: some View {
        GeometryReader { geometry in
            Path { path in
                for fraction in [1.0 / 3, 2.0 / 3] {
                    path.move(to: CGPoint(x: geometry.size.width * fraction, y: 0))
                    path.addLine(to: CGPoint(x: geometry.size.width * fraction, y: geometry.size.height))
                    path.move(to: CGPoint(x: 0, y: geometry.size.height * fraction))
                    path.addLine(to: CGPoint(x: geometry.size.width, y: geometry.size.height * fraction))
                }
            }.stroke(Color.white.opacity(0.4), lineWidth: 0.5)
        }
    }

    private func regionOverlay(_ region: Region, size: CGSize) -> some View {
        let rect = screenRect(region.rect, size: size)
        let isSelected = selected == region.id
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(Color.clear).contentShape(Rectangle())
                .overlay(Rectangle().stroke(isSelected ? Color.orange : Color.white.opacity(0.5), style: StrokeStyle(lineWidth: isSelected ? 1.5 : 1, dash: isSelected ? [] : [3, 3])))
                .frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
                .onTapGesture { selected = region.id; focused = true }
                .gesture(moveGesture(id: region.id, size: size))
                .accessibilityLabel("\(tool == .redactImage ? "Redaction" : "Annotation") selection")
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                .accessibilityAction(named: "Select") { selected = region.id; focused = true }
                .accessibilityAction(named: "Delete") { selected = region.id; deleteSelection() }
            if isSelected { handles(id: region.id, rect: region.rect, size: size) }
        }
    }

    private func handles(id: UUID?, rect: UnitRect, size: CGSize) -> some View {
        let bounds = screenRect(rect, size: size)
        return ForEach(Corner.allCases, id: \.rawValue) { corner in
            RoundedRectangle(cornerRadius: 2).fill(Color.white).frame(width: 10, height: 10)
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.orange, lineWidth: 1))
                .contentShape(Rectangle().size(width: 18, height: 18))
                .position(x: min(size.width - 5, max(5, corner.left ? bounds.minX : bounds.maxX)), y: min(size.height - 5, max(5, corner.top ? bounds.minY : bounds.maxY)))
                .highPriorityGesture(resizeGesture(id: id, corner: corner, size: size))
                .accessibilityLabel("Resize \(corner.top ? "top" : "bottom") \(corner.left ? "left" : "right") corner")
        }
    }

    private func unitPoint(_ point: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(x: min(1, max(0, point.x / max(1, size.width))), y: min(1, max(0, point.y / max(1, size.height))))
    }

    private func boundingRect(_ a: CGPoint, _ b: CGPoint, size: CGSize) -> UnitRect {
        let minimumWidth = min(1, 2 / max(1, size.width))
        let minimumHeight = min(1, 2 / max(1, size.height))
        let width = max(minimumWidth, abs(a.x - b.x))
        let height = max(minimumHeight, abs(a.y - b.y))
        return UnitRect(x: min(1 - width, min(a.x, b.x)), y: min(1 - height, min(a.y, b.y)), width: width, height: height)
    }

    private func drawGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .local).onChanged { value in
            focused = true
            let point = unitPoint(value.location, size: size)
            if drawing == nil {
                let start = unitPoint(value.startLocation, size: size)
                drawing = Drawing(start: start, points: [CanvasPoint(x: start.x, y: start.y)], rect: boundingRect(start, point, size: size))
                selected = nil
            }
            guard var draft = drawing else { return }
            if kind == "pen" { draft.points.append(CanvasPoint(x: point.x, y: point.y)) }
            else { draft.points = [CanvasPoint(x: draft.start.x, y: draft.start.y), CanvasPoint(x: point.x, y: point.y)] }
            if kind == "pen", tool == .annotateImage {
                let xs = draft.points.map(\.x), ys = draft.points.map(\.y)
                draft.rect = boundingRect(CGPoint(x: xs.min() ?? point.x, y: ys.min() ?? point.y), CGPoint(x: xs.max() ?? point.x, y: ys.max() ?? point.y), size: size)
            } else { draft.rect = boundingRect(draft.start, point, size: size) }
            drawing = draft
            if tool == .cropImage { options.crop = draft.rect }
        }.onEnded { _ in
            guard let draft = drawing else { return }
            defer { drawing = nil }
            if tool == .annotateImage {
                guard kind != "image" || stamp != nil else { return }
                var annotation = Annotation(kind: kind, rect: draft.rect, text: annotationText, color: annotationColor)
                annotation.points = ["pen", "line", "arrow"].contains(kind) ? draft.points : []
                annotation.number = (options.annotations.filter { $0.kind == "number" }.map(\.number).max() ?? 0) + 1
                annotation.imageURL = stamp
                options.annotations.append(annotation); selected = annotation.id
            } else if tool == .redactImage {
                let redaction = Redaction(rect: draft.rect)
                options.redactions.append(redaction); selected = redaction.id
            }
        }
    }

    private func current(id: UUID?) -> Manipulation? {
        if tool == .cropImage { return Manipulation(id: nil, rect: options.crop, points: []) }
        if tool == .annotateImage, let annotation = options.annotations.first(where: { $0.id == id }) { return Manipulation(id: id, rect: annotation.rect, points: annotation.points) }
        if let redaction = options.redactions.first(where: { $0.id == id }) { return Manipulation(id: id, rect: redaction.rect, points: []) }
        return nil
    }

    private func moveGesture(id: UUID?, size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1).onChanged { value in
            focused = true; selected = id
            if manipulation == nil { manipulation = current(id: id) }
            guard let original = manipulation else { return }
            var rect = original.rect
            rect.x = min(max(0, original.rect.x + value.translation.width / size.width), max(0, 1 - rect.width))
            rect.y = min(max(0, original.rect.y + value.translation.height / size.height), max(0, 1 - rect.height))
            update(id: id, rect: rect, original: original)
        }.onEnded { _ in manipulation = nil }
    }

    private func resizeGesture(id: UUID?, corner: Corner, size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0).onChanged { value in
            focused = true; selected = id
            if manipulation == nil { manipulation = current(id: id) }
            guard let original = manipulation else { return }
            let rect = original.rect
            let movingX = (corner.left ? rect.x : rect.x + rect.width) + value.translation.width / size.width
            let movingY = (corner.top ? rect.y : rect.y + rect.height) + value.translation.height / size.height
            let anchor = CGPoint(x: corner.left ? rect.x + rect.width : rect.x, y: corner.top ? rect.y + rect.height : rect.y)
            let moving = CGPoint(x: min(1, max(0, movingX)), y: min(1, max(0, movingY)))
            update(id: id, rect: boundingRect(anchor, moving, size: size), original: original)
        }.onEnded { _ in manipulation = nil }
    }

    private func update(id: UUID?, rect: UnitRect, original: Manipulation) {
        if tool == .cropImage { options.crop = rect; return }
        if tool == .annotateImage, let index = options.annotations.firstIndex(where: { $0.id == id }) {
            options.annotations[index].rect = rect
            options.annotations[index].points = original.points.map { point in
                CanvasPoint(x: rect.x + (point.x - original.rect.x) / max(0.000001, original.rect.width) * rect.width,
                            y: rect.y + (point.y - original.rect.y) / max(0.000001, original.rect.height) * rect.height)
            }
        } else if let index = options.redactions.firstIndex(where: { $0.id == id }) { options.redactions[index].rect = rect }
    }

    private func deleteSelection() {
        guard let selected else { return }
        if tool == .annotateImage { options.annotations.removeAll { $0.id == selected } }
        if tool == .redactImage { options.redactions.removeAll { $0.id == selected } }
        self.selected = nil
    }
}
