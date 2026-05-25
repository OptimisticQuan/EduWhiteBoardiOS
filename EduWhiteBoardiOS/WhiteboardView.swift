import SwiftUI

extension View {
    func debugLayout(_ color: Color = .red) -> some View {
        self.overlay {
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .stroke(color, lineWidth: 2)

                    Text("\(Int(geo.size.width))×\(Int(geo.size.height))")
                        .font(.caption2)
                        .foregroundStyle(.white)
                        .padding(2)
                        .background(color)
                }
            }
        }
    }
}

struct WhiteboardScreen: View {
    @StateObject private var store = WhiteboardStore()
    @StateObject private var speech = SpeechTranscriptionManager()
    @State private var panOrigin: CGSize?
    @State private var zoomOrigin: CGFloat?
    @State private var canvasViewportSize: CGSize = .zero

    var body: some View {
        GeometryReader { proxy in
            let horizontalInset = WhiteboardScreenLayout.horizontalInset(for: proxy.size.width)
            let contentWidth = max(1, proxy.size.width - horizontalInset * 2)
            let contentHeight = max(1, proxy.size.height - WhiteboardScreenLayout.verticalSpacing)
            let activeCanvasSize = canvasViewportSize.width > 0 && canvasViewportSize.height > 0
                ? canvasViewportSize
                : CGSize(width: contentWidth, height: contentHeight)

            ZStack {
                WhiteboardBackdrop()
                    .ignoresSafeArea()

                VStack(spacing: WhiteboardScreenLayout.verticalSpacing) {
                    ToolbarStrip(store: store, viewportSize: activeCanvasSize)
                        .frame(width: contentWidth)

                    WhiteboardCanvas(
                        store: store,
                        viewportSize: activeCanvasSize,
                        panOrigin: $panOrigin,
                        zoomOrigin: $zoomOrigin
                    )
                    .frame(width: contentWidth)
                    .frame(maxHeight: .infinity)
                    .layoutPriority(1)
                    .overlay {
                        GeometryReader { canvasProxy in
                            Color.clear
                                .onAppear {
                                    updateCanvasViewportSize(canvasProxy.size)
                                }
                                .onChange(of: canvasProxy.size) { _, newSize in
                                    updateCanvasViewportSize(newSize)
                                }
                        }
                    }
                    .overlay(alignment: .bottom) {
                        VoiceDockButton(speech: speech) { text in
                            store.createTextFromAsr(text, in: activeCanvasSize)
                        } onToast: { message in
                            store.showToast(message)
                        }
                        .padding(.bottom, WhiteboardScreenLayout.voiceBottomInset)
                    }
                    .overlay(alignment: .top) {
                        ToastOverlay(messages: store.toasts)
                            .padding(.top, WhiteboardScreenLayout.verticalSpacing)
                    }
                }
                .frame(width: contentWidth, height: contentHeight, alignment: .top)
                .padding(.horizontal, horizontalInset)
                .padding(.top, WhiteboardScreenLayout.verticalSpacing)
                // .debugLayout(.red)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .sheet(isPresented: $store.isHelpPresented) {
                WhiteboardHelpSheet()
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .onAppear {
                store.configureInitialViewport(size: activeCanvasSize)
            }
            .onChange(of: activeCanvasSize) { _, newSize in
                store.configureInitialViewport(size: newSize)
            }
        }
        .ignoresSafeArea(.container, edges: .bottom)
    }

    private func updateCanvasViewportSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0, canvasViewportSize != size else {
            return
        }

        canvasViewportSize = size
    }
}

private struct WhiteboardCanvas: View {
    @ObservedObject var store: WhiteboardStore
    let viewportSize: CGSize
    @Binding var panOrigin: CGSize?
    @Binding var zoomOrigin: CGFloat?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .fill(WhiteboardPalette.panel)
                .overlay(
                    RoundedRectangle(cornerRadius: 32, style: .continuous)
                        .stroke(WhiteboardPalette.panelBorder, lineWidth: 1)
                )
                .shadow(color: WhiteboardPalette.ink.opacity(0.14), radius: 32, x: 0, y: 18)

            WhiteboardGrid(offset: store.cameraOffset, zoom: store.zoom)
                .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
                .gesture(panGesture)
                .simultaneousGesture(zoomGesture)
                .onTapGesture {
                    guard store.tool == .select else {
                        return
                    }

                    if store.editingItemID != nil {
                        store.commitCurrentEditing(keepSelection: false)
                    } else {
                        store.selectItem(nil)
                    }
                }

            ZStack(alignment: .topLeading) {
                ForEach(store.items) { item in
                    WhiteboardNoteCard(item: item, store: store, boardScale: store.zoom)
                        .frame(width: item.size.width, height: item.size.height)
                        .position(item.center.cgPoint)
                }
            }
            .scaleEffect(store.zoom, anchor: .topLeading)
            .offset(x: store.cameraOffset.width, y: store.cameraOffset.height)
            .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))

            CanvasBadgeOverlay(store: store)
                .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))

            if store.items.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "scribble.variable")
                        .font(.system(size: 38, weight: .medium))
                        .foregroundStyle(WhiteboardPalette.coral)
                    Text("开始板书")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .foregroundStyle(WhiteboardPalette.ink)
                    Text("点击工具栏文本按钮创建卡片，或按住底部麦克风开始本地转写。")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(WhiteboardPalette.inkMuted)
                        .multilineTextAlignment(.center)
                }
                .padding(28)
                .background(.white.opacity(0.76), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                .padding(.top, max(28, viewportSize.height * 0.18))
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard store.tool == .select else {
                    return
                }

                if panOrigin == nil {
                    panOrigin = store.cameraOffset
                }

                let origin = panOrigin ?? store.cameraOffset
                store.setCameraOffset(
                    CGSize(
                        width: origin.width + value.translation.width,
                        height: origin.height + value.translation.height
                    )
                )
            }
            .onEnded { _ in
                panOrigin = nil
            }
    }

    private var zoomGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                if zoomOrigin == nil {
                    zoomOrigin = store.zoom
                }

                let anchor = CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
                store.setZoom((zoomOrigin ?? store.zoom) * value, anchoredAt: anchor)
            }
            .onEnded { _ in
                zoomOrigin = nil
            }
    }
}

private struct WhiteboardNoteCard: View {
    let item: WhiteboardTextCard
    @ObservedObject var store: WhiteboardStore
    let boardScale: CGFloat

    @State private var dragOrigin: CGPoint?
    @State private var resizeOrigin: CGSize?

    init(item: WhiteboardTextCard, store: WhiteboardStore, boardScale: CGFloat) {
        self.item = item
        self.store = store
        self.boardScale = boardScale
    }

    private var isSelected: Bool {
        store.selectedItemID == item.id
    }

    private var isEditing: Bool {
        store.editingItemID == item.id
    }

    private var layout: TextLayoutResult {
        TextLayoutEngine.layout(
            text: item.text,
            cardWidth: item.size.width,
            fontSize: item.fontSize,
            lineHeight: item.lineHeight
        )
    }

    private var noteBackgroundColor: Color {
        if isEditing {
            return .white.opacity(0.14)
        }
        if isSelected {
            return WhiteboardPalette.paper.opacity(0.16)
        }
        return .clear
    }

    private var noteBorderColor: Color {
        if isSelected {
            return WhiteboardPalette.coral.opacity(0.42)
        }
        if isEditing {
            return WhiteboardPalette.coral.opacity(0.20)
        }
        return .clear
    }

    @ViewBuilder
    var body: some View {
        if store.tool == .select {
            noteContent
                .highPriorityGesture(moveGesture)
        } else {
            noteContent
        }
    }

    private var noteContent: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(noteBackgroundColor)
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(
                            noteBorderColor,
                            lineWidth: isSelected || isEditing ? max(1.2, 2.2 / max(boardScale, 0.1)) : 0
                        )
                )
                .shadow(color: WhiteboardPalette.ink.opacity(isSelected ? 0.08 : 0), radius: 16, x: 0, y: 10)

            ForEach(item.annotations) { annotation in
                ForEach(TextLayoutEngine.annotationRects(in: layout.characterBoxes, annotation: annotation), id: \.self) { lineRect in
                    let highlightRect = highlightDisplayRect(for: lineRect)
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(annotation.color.fillColor)
                        .frame(width: highlightRect.width, height: highlightRect.height)
                        .offset(x: highlightRect.minX, y: highlightRect.minY)
                        .allowsHitTesting(false)
                }
            }

            if isEditing {
                TextEditor(text: $store.editingText)
                    .font(TextLayoutEngine.displayFont(size: item.fontSize))
                    .foregroundStyle(WhiteboardPalette.ink)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
                    .background(Color.clear)

                if store.editingText.isEmpty {
                    Text("输入文本...")
                        .font(.system(size: 18, weight: .medium, design: .rounded))
                        .foregroundStyle(WhiteboardPalette.ink.opacity(0.35))
                        .padding(.horizontal, 22)
                        .padding(.vertical, 24)
                        .allowsHitTesting(false)
                }
            } else {
                Group {
                    if item.text.isEmpty {
                        Text("空白文本")
                            .font(.system(size: 18, weight: .medium, design: .rounded))
                            .foregroundStyle(WhiteboardPalette.ink.opacity(0.35))
                    } else {
                        Text(item.text)
                            .font(TextLayoutEngine.displayFont(size: item.fontSize))
                            .lineSpacing(item.fontSize * max(item.lineHeight - 1, 0))
                            .foregroundStyle(WhiteboardPalette.ink)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(WhiteboardConstants.textPadding)
                .allowsHitTesting(false)
            }

            if store.tool == .highlight {
                StrokeCaptureOverlay(color: store.modeColor, lineWidth: max(12, 24 / max(boardScale, 0.1))) { points in
                    let hitIndexes = TextLayoutEngine.strokeSelectionIndexes(
                        points: points,
                        boxes: layout.characterBoxes,
                        padding: max(WhiteboardConstants.markHitPadding * 0.9, 8 / max(boardScale, 0.1))
                    )

                    guard let start = hitIndexes.first, let end = hitIndexes.last else {
                        return
                    }

                    store.createAnnotation(on: item.id, start: start, end: end + 1)
                }
                .zIndex(20)
            } else if store.tool == .erase {
                StrokeCaptureOverlay(color: WhiteboardPalette.ink.opacity(0.48), lineWidth: max(6, 18 / max(boardScale, 0.1)), dashed: true) { points in
                    guard TextLayoutEngine.strokeIntersectsRect(points: points, rect: CGRect(origin: .zero, size: item.size.cgSize), padding: 2) else {
                        return
                    }

                    store.deleteItem(item.id)
                }
                .zIndex(20)
            }

            if isSelected && store.tool == .select {
                NoteActionStrip(isEditing: isEditing) {
                    store.cancelEditing()
                } onConfirm: {
                    store.commitCurrentEditing()
                } onEdit: {
                    store.beginEditing(item.id)
                } onDelete: {
                    store.deleteItem(item.id)
                }
                .offset(x: item.size.width - 112, y: -14)

                if !isEditing {
                    ResizeHandle(boardScale: boardScale)
                        .offset(x: item.size.width - 20, y: item.size.height - 20)
                        .gesture(resizeGesture)
                }
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .onTapGesture {
            guard store.tool == .select else {
                return
            }

            store.selectItem(item.id)
        }
    }

    private func highlightDisplayRect(for lineRect: LineRect) -> CGRect {
        let horizontalInset: CGFloat = 3
        let height = max(lineRect.rect.height * 0.7, 16)
        let y = max(0, lineRect.rect.minY + lineRect.rect.height * 0.0)
        return CGRect(
            x: lineRect.rect.minX - horizontalInset,
            y: y,
            width: lineRect.rect.width + horizontalInset * 2,
            height: height
        )
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { value in
                guard store.tool == .select, isSelected, !isEditing else {
                    return
                }

                if dragOrigin == nil {
                    dragOrigin = item.center.cgPoint
                    store.beginInteractiveChange()
                }

                let origin = dragOrigin ?? item.center.cgPoint
                store.moveItem(
                    item.id,
                    to: CGPoint(
                        x: origin.x + value.translation.width / max(boardScale, 0.01),
                        y: origin.y + value.translation.height / max(boardScale, 0.01)
                    )
                )
            }
            .onEnded { _ in
                if dragOrigin != nil {
                    dragOrigin = nil
                    store.commitInteractiveChange()
                }
            }
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                guard store.tool == .select, isSelected, !isEditing else {
                    return
                }

                if resizeOrigin == nil {
                    resizeOrigin = item.size.cgSize
                    store.beginInteractiveChange()
                }

                let origin = resizeOrigin ?? item.size.cgSize
                store.resizeItem(
                    item.id,
                    to: CGSize(
                        width: origin.width + value.translation.width / max(boardScale, 0.01),
                        height: origin.height + value.translation.height / max(boardScale, 0.01)
                    )
                )
            }
            .onEnded { _ in
                if resizeOrigin != nil {
                    resizeOrigin = nil
                    store.commitInteractiveChange()
                }
            }
    }
}

private struct StrokeCaptureOverlay: View {
    let color: Color
    let lineWidth: CGFloat
    var dashed = false
    let onCommit: ([CGPoint]) -> Void

    @State private var points: [CGPoint] = []

    var body: some View {
        GeometryReader { _ in
            ZStack {
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                if points.isEmpty {
                                    points = [value.location]
                                } else {
                                    points.append(value.location)
                                }
                            }
                            .onEnded { _ in
                                let committedPoints = points
                                points = []
                                onCommit(committedPoints)
                            }
                    )

                if points.count == 1, let point = points.first {
                    Circle()
                        .fill(color.opacity(0.28))
                        .frame(width: lineWidth, height: lineWidth)
                        .position(point)
                        .allowsHitTesting(false)
                }

                if points.count > 1 {
                    Path { path in
                        path.addLines(points)
                    }
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round, dash: dashed ? [14 / max(lineWidth, 1), 10 / max(lineWidth, 1)] : []))
                    .shadow(color: color.opacity(0.18), radius: lineWidth * 0.25, x: 0, y: 0)
                    .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct CanvasBadgeOverlay: View {
    @ObservedObject var store: WhiteboardStore
    @State private var activeEntry: ActiveBadge?

    struct ActiveBadge: Equatable {
        let itemID: UUID
        let annotationID: UUID
    }

    private let badgeSize: CGFloat = 46
    private let badgeGap: CGFloat = 14
    private let menuWidth: CGFloat = 252
    private let menuApproxHeight: CGFloat = 220

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if activeEntry != nil {
                    Color.clear
                        .contentShape(Rectangle())
                        .frame(width: geo.size.width, height: geo.size.height)
                        .onTapGesture {
                            withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) {
                                activeEntry = nil
                            }
                        }
                }

                ForEach(store.items) { item in
                    let layout = TextLayoutEngine.layout(
                        text: item.text,
                        cardWidth: item.size.width,
                        fontSize: item.fontSize,
                        lineHeight: item.lineHeight
                    )
                    ForEach(item.annotations) { annotation in
                        let rects = TextLayoutEngine.annotationRects(in: layout.characterBoxes, annotation: annotation)
                        if let localAnchor = TextLayoutEngine.anchor(for: rects) {
                            let anchorScreen = WhiteboardCanvasGeometry.screenPoint(
                                item: item,
                                localPoint: localAnchor,
                                zoom: store.zoom,
                                cameraOffset: store.cameraOffset
                            )
                            let badgeCenter = WhiteboardCanvasGeometry.badgeCenter(
                                for: anchorScreen,
                                badgeSize: badgeSize,
                                gap: badgeGap
                            )
                            let badgeFrame = CGRect(
                                x: badgeCenter.x - badgeSize / 2,
                                y: badgeCenter.y - badgeSize / 2,
                                width: badgeSize,
                                height: badgeSize
                            )
                            let isBadgeVisible = badgeFrame.intersects(CGRect(origin: .zero, size: geo.size))
                            let isActive = activeEntry == ActiveBadge(itemID: item.id, annotationID: annotation.id)

                            Button {
                                withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) {
                                    let entry = ActiveBadge(itemID: item.id, annotationID: annotation.id)
                                    activeEntry = (activeEntry == entry) ? nil : entry
                                }
                            } label: {
                                ZStack {
                                    Circle()
                                        .fill(.white.opacity(0.98))
                                        .frame(width: badgeSize, height: badgeSize)
                                        .overlay(Circle().stroke(annotation.color.accentColor.opacity(0.26), lineWidth: 1.4))
                                        .shadow(color: WhiteboardPalette.ink.opacity(0.14), radius: 10, x: 0, y: 6)
                                    Text(annotation.alias ?? "✦")
                                        .font(.system(size: 20, weight: .black, design: .rounded))
                                        .foregroundStyle(annotation.color.accentColor)
                                }
                            }
                            .buttonStyle(.plain)
                            .position(badgeCenter)
                            .zIndex(isActive ? 50 : 10)

                            if isActive && isBadgeVisible {
                                let menuXMin = menuWidth / 2 + 8
                                let menuXMax = max(menuXMin, geo.size.width - menuWidth / 2 - 8)
                                let menuCX = badgeCenter.x.clamped(to: menuXMin...menuXMax)
                                let preferAbove = badgeCenter.y - badgeSize / 2 - 12 >= menuApproxHeight
                                let proposedMenuCY = preferAbove
                                    ? badgeCenter.y - badgeSize / 2 - 12 - menuApproxHeight / 2
                                    : badgeCenter.y + badgeSize / 2 + 12 + menuApproxHeight / 2
                                let menuYMin = menuApproxHeight / 2 + 8
                                let menuYMax = max(menuYMin, geo.size.height - menuApproxHeight / 2 - 8)
                                let menuCY = proposedMenuCY.clamped(to: menuYMin...menuYMax)
                                HighlightAnnotationMenu(
                                    annotation: annotation,
                                    onChooseAlias: { alias in
                                        store.setAnnotationAlias(itemID: item.id, annotationID: annotation.id, alias: alias)
                                        withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) { activeEntry = nil }
                                    },
                                    onClearAlias: {
                                        store.clearAnnotationAlias(itemID: item.id, annotationID: annotation.id)
                                        withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) { activeEntry = nil }
                                    },
                                    onDelete: {
                                        store.deleteAnnotation(itemID: item.id, annotationID: annotation.id)
                                        withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) { activeEntry = nil }
                                    }
                                )
                                .frame(width: menuWidth)
                                .position(x: menuCX, y: menuCY)
                                .transition(.scale(scale: 0.94).combined(with: .opacity))
                                .zIndex(60)
                            }
                        }
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

private struct HighlightAnnotationMenu: View {
    let annotation: TextAnnotation
    let onChooseAlias: (String) -> Void
    let onClearAlias: () -> Void
    let onDelete: () -> Void

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Circle()
                    .fill(annotation.color.accentColor.opacity(0.14))
                    .frame(width: 34, height: 34)
                    .overlay(
                        Image(systemName: "highlighter")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(annotation.color.accentColor)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(annotation.alias ?? "高亮标记")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(WhiteboardPalette.ink)
                    Text("选择代称或管理这段高亮")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(WhiteboardPalette.inkMuted)
                }
            }

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(WhiteboardConstants.aliasOptions, id: \.self) { alias in
                    Button {
                        onChooseAlias(alias)
                    } label: {
                        Text(alias)
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(annotation.alias == alias ? .white : annotation.color.accentColor)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(annotation.alias == alias ? annotation.color.accentColor : annotation.color.accentColor.opacity(0.10))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 8) {
                if annotation.alias != nil {
                    AnnotationMenuButton(title: "移除代称", systemImage: "text.badge.minus", tint: WhiteboardPalette.inkMuted) {
                        onClearAlias()
                    }
                }

                AnnotationMenuButton(title: "删除高亮", systemImage: "trash", tint: Color.red.opacity(0.90)) {
                    onDelete()
                }
            }
        }
        .padding(14)
        .background(.white.opacity(0.97), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(annotation.color.accentColor.opacity(0.16), lineWidth: 1)
        )
        .shadow(color: WhiteboardPalette.ink.opacity(0.14), radius: 18, x: 0, y: 10)
    }
}

private struct AnnotationMenuButton: View {
    let title: String
    let systemImage: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(tint.opacity(0.08))
                )
        }
        .buttonStyle(.plain)
    }
}

private struct ToolbarStrip: View {
    @ObservedObject var store: WhiteboardStore
    let viewportSize: CGSize

    var body: some View {
        VStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ToolbarButton(label: "选择", systemImage: "cursorarrow", active: store.tool == .select) {
                        store.setTool(.select)
                    }
                    ToolbarButton(label: "高亮", systemImage: "highlighter", active: store.tool == .highlight, accent: true) {
                        store.setTool(.highlight)
                    }
                    ToolbarButton(label: "橡皮擦", systemImage: "eraser", active: store.tool == .erase, accent: true) {
                        store.setTool(.erase)
                    }
                    ToolbarButton(label: "文本", systemImage: "text.cursor") {
                        store.createManualText(in: viewportSize)
                    }
                    ToolbarButton(label: store.clearConfirmArmed ? "确认清空" : "清空", systemImage: "trash", active: store.clearConfirmArmed, accent: true) {
                        switch store.requestClearCanvas() {
                        case .armed:
                            store.showToast("再点一次清空画布")
                        case .alreadyEmpty:
                            store.showToast("画布已空")
                        case .cleared:
                            store.showToast("已清空画布")
                        }
                    }
                    Divider()
                        .frame(height: 18)
                    ToolbarButton(label: "撤销", systemImage: "arrow.uturn.backward", disabled: !store.canUndo) {
                        store.undo()
                    }
                    ToolbarButton(label: "重做", systemImage: "arrow.uturn.forward", disabled: !store.canRedo) {
                        store.redo()
                    }
                    ToolbarButton(label: "帮助", systemImage: "questionmark.circle") {
                        store.isHelpPresented = true
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .background(.white.opacity(0.88), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(WhiteboardPalette.panelBorder, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(color: WhiteboardPalette.ink.opacity(0.12), radius: 18, x: 0, y: 10)

            HStack {
                HStack(spacing: 8) {
                    Circle()
                        .fill(store.modeColor)
                        .frame(width: 8, height: 8)
                    Text(store.modeLabel)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(WhiteboardPalette.inkMuted)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.white.opacity(0.74), in: Capsule())
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
        .clipped()
    }
}

private struct ToolbarButton: View {
    let label: String
    let systemImage: String
    var active = false
    var accent = false
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(textColor)
                .frame(width: 40, height: 40)
                .background(backgroundColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(borderColor, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.42 : 1)
        .accessibilityLabel(label)
        .help(label)
    }

    private var backgroundColor: Color {
        if active {
            return accent ? WhiteboardPalette.coral : WhiteboardPalette.ink
        }
        return .white.opacity(0.92)
    }

    private var borderColor: Color {
        if active {
            return (accent ? WhiteboardPalette.coral : WhiteboardPalette.ink).opacity(0.42)
        }
        return WhiteboardPalette.ink.opacity(0.10)
    }

    private var textColor: Color {
        active ? .white : WhiteboardPalette.inkMuted
    }
}

private struct NoteActionStrip: View {
    let isEditing: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if isEditing {
                MiniActionButton(systemImage: "xmark") { onCancel() }
                MiniActionButton(systemImage: "checkmark") { onConfirm() }
            } else {
                MiniActionButton(systemImage: "pencil") { onEdit() }
                MiniActionButton(systemImage: "trash") { onDelete() }
            }
        }
        .padding(6)
        .background(.white.opacity(0.96), in: Capsule())
        .shadow(color: WhiteboardPalette.ink.opacity(0.12), radius: 10, x: 0, y: 6)
    }
}

private struct MiniActionButton: View {
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(WhiteboardPalette.ink)
                .frame(width: 30, height: 30)
                .background(WhiteboardPalette.paper, in: Circle())
        }
        .buttonStyle(.plain)
    }
}

private struct ResizeHandle: View {
    let boardScale: CGFloat

    var body: some View {
        Circle()
            .fill(WhiteboardPalette.ink)
            .frame(width: max(14, 20 / max(boardScale, 0.1)), height: max(14, 20 / max(boardScale, 0.1)))
            .overlay(
                Circle()
                    .stroke(.white.opacity(0.92), lineWidth: max(1, 2 / max(boardScale, 0.1)))
            )
    }
}

private struct WhiteboardGrid: View {
    let offset: CGSize
    let zoom: CGFloat

    var body: some View {
        Canvas { context, size in
            let minorStep = max(22, 48 * zoom)
            let majorStep = minorStep * 4
            let startMinorX = offset.width.truncatingRemainder(dividingBy: minorStep)
            let startMinorY = offset.height.truncatingRemainder(dividingBy: minorStep)
            let startMajorX = offset.width.truncatingRemainder(dividingBy: majorStep)
            let startMajorY = offset.height.truncatingRemainder(dividingBy: majorStep)

            var minorPath = Path()
            for x in stride(from: startMinorX, through: size.width, by: minorStep) {
                minorPath.move(to: CGPoint(x: x, y: 0))
                minorPath.addLine(to: CGPoint(x: x, y: size.height))
            }
            for y in stride(from: startMinorY, through: size.height, by: minorStep) {
                minorPath.move(to: CGPoint(x: 0, y: y))
                minorPath.addLine(to: CGPoint(x: size.width, y: y))
            }

            var majorPath = Path()
            for x in stride(from: startMajorX, through: size.width, by: majorStep) {
                majorPath.move(to: CGPoint(x: x, y: 0))
                majorPath.addLine(to: CGPoint(x: x, y: size.height))
            }
            for y in stride(from: startMajorY, through: size.height, by: majorStep) {
                majorPath.move(to: CGPoint(x: 0, y: y))
                majorPath.addLine(to: CGPoint(x: size.width, y: y))
            }

            context.stroke(minorPath, with: .color(WhiteboardPalette.grid.opacity(0.55)), lineWidth: 0.7)
            context.stroke(majorPath, with: .color(WhiteboardPalette.grid.opacity(0.95)), lineWidth: 1)
        }
        .background(
            LinearGradient(
                colors: [
                    .white.opacity(0.94),
                    WhiteboardPalette.paper.opacity(0.92),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
    }
}

private struct WhiteboardBackdrop: View {
    var body: some View {
        ZStack {
            WhiteboardPalette.paper
            Circle()
                .fill(WhiteboardPalette.coral.opacity(0.18))
                .frame(width: 420, height: 420)
                .blur(radius: 20)
                .offset(x: -140, y: -280)
            Circle()
                .fill(WhiteboardPalette.lake.opacity(0.20))
                .frame(width: 320, height: 320)
                .blur(radius: 16)
                .offset(x: 180, y: -180)
        }
    }
}

private struct VoiceDockButton: View {
    @ObservedObject var speech: SpeechTranscriptionManager
    let onCommit: (String) -> Void
    let onToast: (String) -> Void

    @State private var isPressing = false
    @State private var startTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 10) {
            if let hint = speech.hint {
                Text(hint)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(WhiteboardPalette.ink)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.white.opacity(0.96), in: Capsule())
                    .shadow(color: WhiteboardPalette.ink.opacity(0.12), radius: 10, x: 0, y: 6)
                    .frame(maxWidth: 300)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 10) {
                Circle()
                    .fill(speech.isBusy ? .white.opacity(0.16) : WhiteboardPalette.coral.opacity(0.14))
                    .frame(width: 34, height: 34)
                    .overlay(
                        Image(systemName: "mic.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(speech.isBusy ? .white : WhiteboardPalette.coral)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(speech.buttonTitle)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(speech.isBusy ? .white : WhiteboardPalette.ink)
                    Text(speech.secondaryTitle)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(speech.isBusy ? .white.opacity(0.82) : WhiteboardPalette.inkMuted)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(backgroundColor, in: Capsule())
            .overlay(
                Capsule()
                    .stroke(borderColor, lineWidth: 1)
            )
            .shadow(color: WhiteboardPalette.ink.opacity(0.16), radius: 18, x: 0, y: 12)
            .contentShape(Capsule())
            .gesture(pressGesture)
        }
    }

    private var backgroundColor: Color {
        speech.isBusy ? WhiteboardPalette.coral : .white.opacity(0.94)
    }

    private var borderColor: Color {
        speech.isBusy ? WhiteboardPalette.coral.opacity(0.42) : WhiteboardPalette.panelBorder
    }

    private var pressGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !isPressing {
                    isPressing = true
                    startTask = Task {
                        do {
                            try await speech.startRecording()
                        } catch {
                            await MainActor.run {
                                isPressing = false
                                startTask = nil
                            }
                            await MainActor.run {
                                onToast(error.localizedDescription)
                            }
                        }
                    }
                }

                speech.setCancellationArmed(value.translation.height <= -64)
            }
            .onEnded { _ in
                guard isPressing else {
                    return
                }

                isPressing = false
                let shouldCommit = !speech.isCancellationArmed

                Task {
                    let pendingStartTask = startTask
                    await pendingStartTask?.value
                    await MainActor.run {
                        startTask = nil
                    }

                    guard speech.isBusy else {
                        return
                    }

                    do {
                        if let text = try await speech.finishRecording(commit: shouldCommit) {
                            await MainActor.run {
                                onCommit(text)
                            }
                        } else if shouldCommit {
                            await MainActor.run {
                                onToast("未识别到语音")
                            }
                        } else if !shouldCommit {
                            await MainActor.run {
                                onToast("已取消")
                            }
                        }
                    } catch {
                        await MainActor.run {
                            onToast(error.localizedDescription)
                        }
                    }
                }
            }
    }
}

private struct ToastOverlay: View {
    let messages: [ToastMessage]

    var body: some View {
        VStack(spacing: 10) {
            ForEach(messages) { message in
                Text(message.message)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(WhiteboardPalette.ink)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(.white.opacity(0.95), in: Capsule())
                    .shadow(color: WhiteboardPalette.ink.opacity(0.12), radius: 10, x: 0, y: 6)
            }
        }
    }
}

private struct WhiteboardHelpSheet: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    helpCard(title: "文本", lines: [
                        "点击工具栏“文本”会在当前视口中心创建文本卡片。",
                        "选中文本后可拖动、缩放和编辑。",
                    ])
                    helpCard(title: "高亮与代称", lines: [
                        "切到高亮模式后，在文本上拖动即可选出字符区间。",
                        "点高亮上方的小圆点可设置 A-F 代称，或删除高亮。",
                    ])
                    helpCard(title: "橡皮擦", lines: [
                        "切到橡皮擦模式后，在文本卡片上划一下即可删除整张卡片。",
                    ])
                    helpCard(title: "语音", lines: [
                        "底部语音按钮使用 iOS 本地 Speech 流式转写。",
                        "按住说话，松开发送，上滑后松开取消。",
                    ])
                }
                .padding(20)
            }
            .navigationTitle("帮助")
        }
    }

    private func helpCard(title: String, lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(WhiteboardPalette.ink)

            ForEach(lines, id: \.self) { line in
                Text(line)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(WhiteboardPalette.inkMuted)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WhiteboardPalette.paper.opacity(0.70), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}
