import Combine
import Foundation
import SwiftUI

@MainActor
final class WhiteboardStore: ObservableObject {
    @Published private(set) var items: [WhiteboardTextCard]
    @Published var selectedItemID: UUID?
    @Published var editingItemID: UUID?
    @Published var editingText = ""
    @Published var tool: WhiteboardTool
    @Published var cameraOffset: CGSize
    @Published var zoom: CGFloat
    @Published var toasts: [ToastMessage]
    @Published var isHelpPresented = false
    @Published var clearConfirmArmed = false

    private var highlightCursor: Int
    private var undoStack: [WhiteboardDocument] = []
    private var redoStack: [WhiteboardDocument] = []
    private var interactiveSnapshot: WhiteboardDocument?
    private var clearResetTask: Task<Void, Never>?
    private var toastTasks: [UUID: Task<Void, Never>] = [:]
    private var hasConfiguredViewport = false

    init() {
        if let document = Self.loadDocument() {
            items = document.items
            selectedItemID = document.selectedItemID
            editingItemID = nil
            editingText = ""
            tool = .select
            cameraOffset = CGSize(width: document.cameraOffset.x, height: document.cameraOffset.y)
            zoom = document.zoom.clamped(to: WhiteboardConstants.minZoom...WhiteboardConstants.maxZoom)
            toasts = []
            highlightCursor = document.highlightCursor
            hasConfiguredViewport = true
        } else {
            items = []
            selectedItemID = nil
            editingItemID = nil
            editingText = ""
            tool = .select
            cameraOffset = .zero
            zoom = 1
            toasts = []
            highlightCursor = 0
        }
    }

    deinit {
        clearResetTask?.cancel()
        toastTasks.values.forEach { $0.cancel() }
    }

    var canUndo: Bool {
        !undoStack.isEmpty
    }

    var canRedo: Bool {
        !redoStack.isEmpty
    }

    var modeLabel: String {
        switch tool {
        case .select:
            return "选择模式"
        case .highlight:
            return "高亮模式"
        case .erase:
            return "橡皮擦模式"
        }
    }

    var modeColor: Color {
        switch tool {
        case .select:
            return WhiteboardPalette.ink.opacity(0.76)
        case .highlight:
            return HighlightColorToken.allCases[highlightCursor % HighlightColorToken.allCases.count].fillColor
        case .erase:
            return WhiteboardPalette.ink.opacity(0.76)
        }
    }

    func configureInitialViewport(size: CGSize) {
        guard !hasConfiguredViewport else {
            return
        }

        cameraOffset = CGSize(width: size.width / 2, height: size.height / 2)
        hasConfiguredViewport = true
        persist()
    }

    func selectItem(_ itemID: UUID?) {
        if tool == .select {
            selectedItemID = itemID
        }
    }

    func beginEditing(_ itemID: UUID) {
        selectedItemID = itemID
        editingItemID = itemID
        editingText = items.first(where: { $0.id == itemID })?.text ?? ""
        clearConfirmArmed = false
    }

    func cancelEditing() {
        editingItemID = nil
        editingText = ""
    }

    func commitCurrentEditing(keepSelection: Bool = true) {
        guard let editingItemID else {
            if !keepSelection {
                selectedItemID = nil
            }
            return
        }

        commitEditing(itemID: editingItemID, text: editingText, keepSelection: keepSelection)
    }

    func commitEditing(itemID: UUID, text: String, keepSelection: Bool = true) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else {
            editingItemID = nil
            editingText = ""
            if !keepSelection {
                selectedItemID = nil
            }
            return
        }

        let existing = items[index]
        let layout = TextLayoutEngine.layout(
            text: text,
            cardWidth: existing.size.width,
            fontSize: existing.fontSize,
            lineHeight: existing.lineHeight
        )
        let textChanged = existing.text != text

        performRecordedChange {
            items[index].text = text
            items[index].size.height = max(WhiteboardConstants.minimumCardHeight, layout.contentHeight)
            if textChanged {
                items[index].annotations = []
            }
            selectedItemID = keepSelection ? itemID : nil
            editingItemID = nil
            editingText = ""
            clearConfirmArmed = false
        }

        if textChanged && !existing.annotations.isEmpty {
            showToast("文本已变更，已清除高亮")
        }
    }

    func setTool(_ tool: WhiteboardTool) {
        self.tool = tool
        clearConfirmArmed = false
        editingItemID = nil
        if tool != .select {
            selectedItemID = nil
        }
        persist()
    }

    func createManualText(in viewportSize: CGSize) {
        createText(text: "", in: viewportSize, editImmediately: true, preferredSize: CGSize(width: WhiteboardConstants.defaultCardWidth, height: WhiteboardConstants.defaultCardHeight))
    }

    func createTextFromAsr(_ rawText: String, in viewportSize: CGSize) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            showToast("无有效语音")
            return
        }

        let estimated = TextLayoutEngine.estimatedCardSize(for: text, viewportWidth: viewportSize.width / max(zoom, 0.01))
        createText(text: text, in: viewportSize, editImmediately: false, preferredSize: estimated)
    }

    func requestClearCanvas() -> ClearCanvasResult {
        if !clearConfirmArmed {
            clearConfirmArmed = true
            clearResetTask?.cancel()
            clearResetTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2.4))
                guard !Task.isCancelled else {
                    return
                }
                await MainActor.run {
                    self?.clearConfirmArmed = false
                }
            }
            return .armed
        }

        clearConfirmArmed = false
        clearResetTask?.cancel()

        guard !items.isEmpty else {
            return .alreadyEmpty
        }

        let count = items.count
        performRecordedChange {
            items.removeAll()
            selectedItemID = nil
            editingItemID = nil
        }

        return .cleared(count)
    }

    func deleteItem(_ itemID: UUID) {
        guard items.contains(where: { $0.id == itemID }) else {
            return
        }

        performRecordedChange {
            items.removeAll { $0.id == itemID }
            if selectedItemID == itemID {
                selectedItemID = nil
            }
            if editingItemID == itemID {
                editingItemID = nil
            }
            clearConfirmArmed = false
        }
    }

    func beginInteractiveChange() {
        if interactiveSnapshot == nil {
            interactiveSnapshot = currentDocument()
        }
    }

    func commitInteractiveChange() {
        guard let snapshot = interactiveSnapshot else {
            return
        }

        interactiveSnapshot = nil
        commitSnapshotIfNeeded(snapshot)
    }

    func cancelInteractiveChange() {
        guard let snapshot = interactiveSnapshot else {
            return
        }

        interactiveSnapshot = nil
        apply(document: snapshot)
        persist()
    }

    func moveItem(_ itemID: UUID, to center: CGPoint) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else {
            return
        }

        items[index].center = BoardPoint(center)
    }

    func resizeItem(_ itemID: UUID, to size: CGSize) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else {
            return
        }

        items[index].size = BoardSize(
            width: max(WhiteboardConstants.minimumCardWidth, size.width),
            height: max(WhiteboardConstants.minimumCardHeight, size.height)
        )
    }

    func createAnnotation(on itemID: UUID, start: Int, end: Int) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else {
            return
        }

        let item = items[index]
        guard let trimmed = TextLayoutEngine.trimmedRange(in: item.text, start: start, end: end) else {
            return
        }

        if TextLayoutEngine.hasAnnotationConflict(start: trimmed.lowerBound, end: trimmed.upperBound, annotations: item.annotations) {
            showToast("这里已有高亮")
            return
        }

        let color = HighlightColorToken.allCases[highlightCursor % HighlightColorToken.allCases.count]
        let annotation = TextAnnotation(start: trimmed.lowerBound, end: trimmed.upperBound, color: color)

        performRecordedChange {
            items[index].annotations.append(annotation)
            selectedItemID = itemID
            highlightCursor += 1
        }
    }

    func setAnnotationAlias(itemID: UUID, annotationID: UUID, alias: String) {
        guard let itemIndex = items.firstIndex(where: { $0.id == itemID }), let annotationIndex = items[itemIndex].annotations.firstIndex(where: { $0.id == annotationID }) else {
            return
        }

        performRecordedChange {
            items[itemIndex].annotations[annotationIndex].alias = alias
            items[itemIndex].annotations[annotationIndex].updatedAt = Date()
        }
    }

    func clearAnnotationAlias(itemID: UUID, annotationID: UUID) {
        guard let itemIndex = items.firstIndex(where: { $0.id == itemID }), let annotationIndex = items[itemIndex].annotations.firstIndex(where: { $0.id == annotationID }) else {
            return
        }

        performRecordedChange {
            items[itemIndex].annotations[annotationIndex].alias = nil
            items[itemIndex].annotations[annotationIndex].updatedAt = Date()
        }
    }

    func deleteAnnotation(itemID: UUID, annotationID: UUID) {
        guard let itemIndex = items.firstIndex(where: { $0.id == itemID }) else {
            return
        }

        performRecordedChange {
            items[itemIndex].annotations.removeAll { $0.id == annotationID }
        }
    }

    func undo() {
        guard let snapshot = undoStack.popLast() else {
            return
        }

        redoStack.append(currentDocument())
        apply(document: snapshot)
        persist()
    }

    func redo() {
        guard let snapshot = redoStack.popLast() else {
            return
        }

        undoStack.append(currentDocument())
        apply(document: snapshot)
        persist()
    }

    func updateCamera(by translation: CGSize) {
        cameraOffset.width += translation.width
        cameraOffset.height += translation.height
        persist()
    }

    func setCameraOffset(_ offset: CGSize) {
        cameraOffset = offset
        persist()
    }

    func setZoom(_ nextZoom: CGFloat, anchoredAt screenPoint: CGPoint) {
        let clampedZoom = nextZoom.clamped(to: WhiteboardConstants.minZoom...WhiteboardConstants.maxZoom)
        let boardX = (screenPoint.x - cameraOffset.width) / max(zoom, 0.01)
        let boardY = (screenPoint.y - cameraOffset.height) / max(zoom, 0.01)
        zoom = clampedZoom
        cameraOffset = CGSize(width: screenPoint.x - boardX * clampedZoom, height: screenPoint.y - boardY * clampedZoom)
        persist()
    }

    func showToast(_ message: String) {
        let toast = ToastMessage(message: message)
        toasts.append(toast)

        toastTasks[toast.id]?.cancel()
        toastTasks[toast.id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.6))
            guard !Task.isCancelled else {
                return
            }
            await MainActor.run {
                self?.toasts.removeAll { $0.id == toast.id }
                self?.toastTasks[toast.id] = nil
            }
        }
    }

    private func createText(text: String, in viewportSize: CGSize, editImmediately: Bool, preferredSize: CGSize) {
        let center = boardPoint(atScreenPoint: CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2))
        // Cap width so the card always fits within the visible canvas (24pt margin each side).
        let maxCardWidth = max(WhiteboardConstants.minimumCardWidth, viewportSize.width - 24)
        let card = WhiteboardTextCard(
            center: BoardPoint(center),
            size: BoardSize(
                width: min(max(preferredSize.width, WhiteboardConstants.minimumCardWidth), maxCardWidth),
                height: max(preferredSize.height, WhiteboardConstants.minimumCardHeight)
            ),
            text: text
        )

        performRecordedChange {
            items.append(card)
            selectedItemID = card.id
            editingItemID = editImmediately ? card.id : nil
            tool = .select
            clearConfirmArmed = false
        }
    }

    private func boardPoint(atScreenPoint point: CGPoint) -> CGPoint {
        CGPoint(
            x: (point.x - cameraOffset.width) / max(zoom, 0.01),
            y: (point.y - cameraOffset.height) / max(zoom, 0.01)
        )
    }

    private func performRecordedChange(_ changes: () -> Void) {
        let snapshot = currentDocument()
        changes()
        commitSnapshotIfNeeded(snapshot)
    }

    private func commitSnapshotIfNeeded(_ snapshot: WhiteboardDocument) {
        let current = currentDocument()
        guard current != snapshot else {
            persist()
            return
        }

        undoStack.append(snapshot)
        if undoStack.count > 80 {
            undoStack.removeFirst(undoStack.count - 80)
        }
        redoStack.removeAll()
        persist()
    }

    private func currentDocument() -> WhiteboardDocument {
        WhiteboardDocument(
            items: items,
            selectedItemID: selectedItemID,
            cameraOffset: BoardPoint(x: cameraOffset.width, y: cameraOffset.height),
            zoom: zoom,
            highlightCursor: highlightCursor
        )
    }

    private func apply(document: WhiteboardDocument) {
        items = document.items
        selectedItemID = document.selectedItemID
        editingItemID = nil
        cameraOffset = CGSize(width: document.cameraOffset.x, height: document.cameraOffset.y)
        zoom = document.zoom.clamped(to: WhiteboardConstants.minZoom...WhiteboardConstants.maxZoom)
        highlightCursor = document.highlightCursor
        clearConfirmArmed = false
        tool = .select
    }

    private func persist() {
        let document = currentDocument()
        do {
            let data = try JSONEncoder().encode(document)
            UserDefaults.standard.set(data, forKey: WhiteboardConstants.documentStorageKey)
        } catch {
            assertionFailure("Failed to persist document: \(error)")
        }
    }

    private static func loadDocument() -> WhiteboardDocument? {
        guard let data = UserDefaults.standard.data(forKey: WhiteboardConstants.documentStorageKey) else {
            return nil
        }

        return try? JSONDecoder().decode(WhiteboardDocument.self, from: data)
    }
}