import AppKit
import BrowserCore
import Observation
import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    let model: BrowserWindowModel
    let isFullScreen: Bool

    @State private var reorderState = SidebarReorderState()

    private var pinnedColumns: [GridItem] {
        let columnCount = model.pinnedTabs.count.isMultiple(of: 3) ? 3 : 2
        return Array(
            repeating: GridItem(.flexible(), spacing: 7),
            count: columnCount
        )
    }

    var body: some View {
        sidebarContent
            .coordinateSpace(name: SidebarCoordinateSpace.name)
            .onPreferenceChange(SidebarItemLayoutPreferenceKey.self) { layouts in
                reorderState.updateLayouts(layouts, model: model)
            }
            .onPreferenceChange(SidebarListBoundsPreferenceKey.self) { bounds in
                reorderState.listBounds = bounds
            }
            .overlay(alignment: .topLeading) {
                sidebarDragOverlay
            }
            .browserGlassSurface(cornerRadius: 20)
            .shadow(color: .black.opacity(0.16), radius: 24, x: 6, y: 8)
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .simultaneousGesture(sidebarReorderGesture)
    }

    private var sidebarContent: some View {
        VStack(spacing: 0) {
            navigationHeader
                .padding(.horizontal, 12)
                .padding(.top, isFullScreen ? 24 : 38)
                .padding(.bottom, 10)

            if model.isPrivate {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "eye.slash.fill")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Приватное окно")
                            .fontWeight(.semibold)
                        Text("Локальные данные исчезнут после закрытия. Режим не скрывает вас от сайтов и сети.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }

            if model.isDownloadsPresented {
                SidebarDownloadsView(
                    manager: model.downloadManager,
                    onResume: model.resumeDownload
                )
            } else {
                Button {
                    model.presentOmnibox(clearText: false)
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "magnifyingglass")
                        Text(model.activeTab?.domain ?? "Поиск или адрес")
                            .lineLimit(1)
                        Spacer()
                        Text("⌘L")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 11)
                    .frame(height: 34)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .accessibilityLabel("Адрес и поиск")

                VStack(spacing: 0) {
                    if !model.pinnedTabs.isEmpty {
                        LazyVGrid(columns: pinnedColumns, spacing: 8) {
                            ForEach(model.pinnedTabs) { tab in
                                PinnedTabCard(
                                    model: model,
                                    tab: tab,
                                    reorderState: reorderState
                                )
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 10)
                        .padding(.bottom, 5)
                    }

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            FolderTree(
                                model: model,
                                reorderState: reorderState,
                                parentID: nil,
                                depth: 0
                            )

                            NewTabRow(model: model, reorderState: reorderState)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 10)
                    }
                    .frame(maxHeight: .infinity)
                }
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: SidebarListBoundsPreferenceKey.self,
                            value: proxy.frame(in: .named(SidebarCoordinateSpace.name))
                        )
                    }
                }
                .contextMenu {
                    Button("Новая папка") {
                        model.createFolder()
                    }
                    if model.selectedTabCount > 0 {
                        Button("Новая папка из выбранных") {
                            model.createFolderFromSelection()
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var sidebarDragOverlay: some View {
        if let tab = reorderState.anchorTab,
           let frame = reorderState.overlayFrame {
            Group {
                switch reorderState.sourceVisual {
                case .regular:
                    FloatingTabRow(
                        model: model,
                        tab: tab,
                        count: reorderState.draggedTabIDs.count
                    )
                case .pinned:
                    FloatingPinnedTabCard(
                        model: model,
                        tab: tab,
                        count: reorderState.draggedTabIDs.count
                    )
                }
            }
            .frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY)
            .allowsHitTesting(false)
            .zIndex(100)
        }
    }

    private var navigationHeader: some View {
        HStack(spacing: 6) {
            Button {
                model.toggleSidebarMode()
            } label: {
                Image(systemName: "sidebar.left")
                    .frame(width: 24, height: 24)
            }
            .help(model.sidebarMode == .autoHide ? "Закрепить sidebar (⌘S)" : "Скрыть sidebar (⌘S)")
            .accessibilityLabel(model.sidebarMode == .autoHide ? "Закрепить боковую панель" : "Скрыть боковую панель")

            Button {
                guard let id = model.selectedTabID else { return }
                model.dispatch(.goBack(id))
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 24, height: 24)
            }
            .disabled(!(model.activeTab?.canGoBack ?? false))
            .help("Назад")

            Button {
                guard let id = model.selectedTabID else { return }
                model.dispatch(.goForward(id))
            } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 24, height: 24)
            }
            .disabled(!(model.activeTab?.canGoForward ?? false))
            .help("Вперёд")

            Button {
                guard let tab = model.activeTab else { return }
                if tab.isLoading {
                    model.dispatch(.stop(tab.id))
                } else {
                    model.dispatch(.reload(tab.id, bypassCache: false))
                }
            } label: {
                Image(systemName: model.activeTab?.isLoading == true ? "xmark" : "arrow.clockwise")
                    .frame(width: 24, height: 24)
            }
            .disabled(model.activeTab?.url == nil)
            .help(model.activeTab?.isLoading == true ? "Остановить" : "Обновить")

            Spacer()

            Button {
                model.toggleDownloads()
            } label: {
                Image(
                    systemName: model.isDownloadsPresented
                        ? "arrow.down.circle.fill"
                        : "arrow.down.circle"
                )
                .frame(width: 24, height: 24)
            }
            .help("Загрузки (⌘⇧J)")
            .accessibilityLabel("Загрузки")
        }
        .buttonStyle(.borderless)
    }

    private var sidebarReorderGesture: some Gesture {
        DragGesture(
            minimumDistance: 4,
            coordinateSpace: .named(SidebarCoordinateSpace.name)
        )
        .onChanged { value in
            reorderState.dragFromSidebar(
                startLocation: value.startLocation,
                location: value.location,
                model: model
            )
        }
        .onEnded { _ in
            reorderState.finish(model: model)
        }
    }

}

private enum SidebarCoordinateSpace {
    static let name = "sidebar-reorder-space"
}

private enum SidebarDragVisual {
    case regular
    case pinned
}

private enum SidebarLayoutKey: Hashable {
    case tab(TabID)
    case folder(TabFolderID)
    case rootEnd
}

private enum SidebarItemKind: Equatable {
    case regularTab
    case pinnedTab
    case folder
    case rootEnd
}

private struct SidebarItemLayout: Equatable {
    let key: SidebarLayoutKey
    let kind: SidebarItemKind
    let parentID: TabFolderID?
    let depth: Int
    var frame: CGRect = .zero
}

private struct SidebarReorderTarget: Equatable {
    let key: SidebarLayoutKey
    let placement: SidebarDropPlacement
    let depth: Int
}

private struct SidebarItemLayoutPreferenceKey: PreferenceKey {
    static let defaultValue: [SidebarLayoutKey: SidebarItemLayout] = [:]

    static func reduce(
        value: inout [SidebarLayoutKey: SidebarItemLayout],
        nextValue: () -> [SidebarLayoutKey: SidebarItemLayout]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct SidebarListBoundsPreferenceKey: PreferenceKey {
    static let defaultValue = CGRect.zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if !next.isEmpty { value = next }
    }
}

private struct SidebarItemLayoutReader: View {
    let layout: SidebarItemLayout

    var body: some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .named(SidebarCoordinateSpace.name))
            Color.clear.preference(
                key: SidebarItemLayoutPreferenceKey.self,
                value: [layout.key: layoutWithFrame(frame)]
            )
        }
    }

    private func layoutWithFrame(_ frame: CGRect) -> SidebarItemLayout {
        var result = layout
        result.frame = frame
        return result
    }
}

@MainActor
@Observable
private final class SidebarReorderState {
    var listBounds = CGRect.zero
    private(set) var anchorTab: BrowserTab?
    private(set) var draggedTabIDs: Set<TabID> = []
    private(set) var sourceVisual: SidebarDragVisual = .regular

    private var layouts: [SidebarLayoutKey: SidebarItemLayout] = [:]
    private var target: SidebarReorderTarget?
    private var lastAppliedTarget: SidebarReorderTarget?
    private var sourceFrame = CGRect.zero
    private var currentLocation = CGPoint.zero
    private var grabOffsetY: CGFloat = 0

    var overlayFrame: CGRect? {
        guard anchorTab != nil, !sourceFrame.isEmpty else { return nil }
        let bounds = listBounds.isEmpty ? sourceFrame.insetBy(dx: -300, dy: -300) : listBounds
        let height = sourceFrame.height
        let unclampedY = currentLocation.y - grabOffsetY
        let y = min(max(unclampedY, bounds.minY), max(bounds.minY, bounds.maxY - height))

        switch sourceVisual {
        case .pinned:
            let x = min(
                max(sourceFrame.minX, bounds.minX + 8),
                max(bounds.minX + 8, bounds.maxX - sourceFrame.width - 8)
            )
            return CGRect(x: x, y: y, width: sourceFrame.width, height: height)
        case .regular:
            let destinationFrame = target.flatMap { layouts[$0.key]?.frame }
            let baseFrame = destinationFrame ?? sourceFrame
            let extraIndent: CGFloat = target?.placement == .inside ? 15 : 0
            let x = min(baseFrame.minX + extraIndent, bounds.maxX - 44)
            let width = max(44, min(baseFrame.width - extraIndent, bounds.maxX - x - 8))
            return CGRect(x: x, y: y, width: width, height: height)
        }
    }

    func placement(for key: SidebarLayoutKey) -> SidebarDropPlacement? {
        guard anchorTab != nil, target?.key == key else { return nil }
        return target?.placement
    }

    func updateLayouts(
        _ layouts: [SidebarLayoutKey: SidebarItemLayout],
        model: BrowserWindowModel
    ) {
        self.layouts = layouts
        guard let anchorTab else { return }
        if let currentFrame = layouts[.tab(anchorTab.id)]?.frame,
           sourceFrame.isEmpty {
            sourceFrame = currentFrame
        }
    }

    func dragFromSidebar(
        startLocation: CGPoint,
        location: CGPoint,
        model: BrowserWindowModel
    ) {
        if anchorTab == nil {
            let hoveredTabs = layouts.values.filter { layout in
                guard layout.kind == .regularTab || layout.kind == .pinnedTab else {
                    return false
                }
                return layout.frame.contains(startLocation)
            }
            guard let layout = hoveredTabs.min(by: { lhs, rhs in
                abs(lhs.frame.midX - startLocation.x) < abs(rhs.frame.midX - startLocation.x)
            }),
            case let .tab(id) = layout.key,
            let tab = model.tabs.first(where: { $0.id == id })
            else { return }
            let ids = model.selectedTabIDs.contains(id) ? model.selectedTabIDs : [id]
            begin(
                tab: tab,
                ids: ids,
                sourceVisual: layout.kind == .pinnedTab ? .pinned : .regular,
                startLocation: startLocation,
                model: model
            )
        }
        guard anchorTab != nil else { return }
        currentLocation = location
        updateTarget(at: location, model: model)
    }

    func finish(model: BrowserWindowModel) {
        guard anchorTab != nil else { return }
        model.finishDragReordering()
        anchorTab = nil
        draggedTabIDs = []
        target = nil
        lastAppliedTarget = nil
        sourceFrame = .zero
        currentLocation = .zero
        grabOffsetY = 0
    }

    private func begin(
        tab: BrowserTab,
        ids: Set<TabID>,
        sourceVisual: SidebarDragVisual,
        startLocation: CGPoint,
        model: BrowserWindowModel
    ) {
        guard let frame = layouts[.tab(tab.id)]?.frame else { return }
        anchorTab = tab
        draggedTabIDs = ids
        self.sourceVisual = sourceVisual
        sourceFrame = frame
        currentLocation = startLocation
        grabOffsetY = min(max(startLocation.y - frame.minY, 0), frame.height)
        model.beginDraggingTabs(ids)
    }

    private func updateTarget(at location: CGPoint, model: BrowserWindowModel) {
        guard !draggedTabIDs.isEmpty else { return }
        let candidates = layouts.values.filter { layout in
            guard !layout.frame.isEmpty else { return false }
            if case let .tab(id) = layout.key {
                return !draggedTabIDs.contains(id)
            }
            return true
        }
        guard let layout = closestLayout(to: location, in: candidates) else { return }
        let placement = placement(at: location, over: layout)
        let proposedTarget = SidebarReorderTarget(
            key: layout.key,
            placement: placement,
            depth: placement == .inside ? layout.depth + 1 : layout.depth
        )
        target = proposedTarget
        guard proposedTarget != lastAppliedTarget else { return }
        lastAppliedTarget = proposedTarget

        withAnimation(.snappy(duration: 0.14)) {
            switch layout.key {
            case let .tab(id):
                model.moveTabs(
                    draggedTabIDs,
                    relativeTo: id,
                    insertAfter: placement == .after,
                    persistChange: false
                )
            case let .folder(id):
                if placement == .inside {
                    model.moveTabs(draggedTabIDs, to: id, persistChange: false)
                } else {
                    model.moveTabs(
                        draggedTabIDs,
                        relativeTo: id,
                        insertAfter: placement == .after,
                        persistChange: false
                    )
                }
            case .rootEnd:
                model.moveTabs(draggedTabIDs, to: nil, persistChange: false)
            }
        }
    }

    private func closestLayout(
        to location: CGPoint,
        in layouts: [SidebarItemLayout]
    ) -> SidebarItemLayout? {
        let rootEnd = layouts.first { $0.kind == .rootEnd }
        if let rootEnd, location.y >= rootEnd.frame.minY - 4 {
            return rootEnd
        }

        let directlyHovered = layouts.filter { layout in
            layout.frame.minY...layout.frame.maxY ~= location.y
        }
        if !directlyHovered.isEmpty {
            return directlyHovered.min { lhs, rhs in
                abs(lhs.frame.midX - location.x) < abs(rhs.frame.midX - location.x)
            }
        }

        return layouts
            .filter { $0.kind != .rootEnd }
            .min { lhs, rhs in
                verticalDistance(from: location.y, to: lhs.frame)
                    < verticalDistance(from: location.y, to: rhs.frame)
            }
    }

    private func placement(
        at location: CGPoint,
        over layout: SidebarItemLayout
    ) -> SidebarDropPlacement {
        switch layout.kind {
        case .folder:
            SidebarDropPlacement.overFolder(
                at: location.y - layout.frame.minY,
                height: layout.frame.height
            )
        case .pinnedTab:
            location.x < layout.frame.midX ? .before : .after
        case .regularTab:
            SidebarDropPlacement.besideItem(
                at: location.y - layout.frame.minY,
                height: layout.frame.height
            )
        case .rootEnd:
            .inside
        }
    }

    private func verticalDistance(from y: CGFloat, to frame: CGRect) -> CGFloat {
        if y < frame.minY { return frame.minY - y }
        if y > frame.maxY { return y - frame.maxY }
        return 0
    }
}

private struct PinnedTabCard: View {
    let model: BrowserWindowModel
    let tab: BrowserTab
    let reorderState: SidebarReorderState

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button {
                model.selectTab(
                    tab.id,
                    extendingSelection: NSEvent.modifierFlags.contains(.shift)
                )
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(cardFill)

                    TabFavicon(tab: tab, size: 24)
                        .offset(y: isHovering && tab.domain != nil ? -7 : 0)

                    if let domain = tab.domain {
                        Text(domain)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .frame(maxWidth: .infinity)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                            .padding(.bottom, 5)
                            .opacity(isHovering ? 1 : 0)
                            .offset(y: isHovering ? 0 : 3)
                    }
                }
                .frame(height: 54)
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)

            if tab.isLoading {
                ProgressView()
                    .controlSize(.mini)
                    .padding(7)
            } else if isHovering {
                Button {
                    model.closeTab(tab.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.semibold))
                        .frame(width: 18, height: 18)
                        .background(.thinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .padding(5)
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
                .accessibilityLabel("Закрыть \(tab.displayTitle)")
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: isHovering)
        .onHover { isHovering = $0 }
        .opacity(reorderState.draggedTabIDs.contains(tab.id) ? 0 : 1)
        .background(itemLayoutReader)
        .overlay {
            SidebarDropIndicator(
                placement: reorderState.placement(for: .tab(tab.id)),
                cornerRadius: 12
            )
        }
        .contextMenu { pinnedContextMenu }
        .help(tab.url?.absoluteString ?? tab.displayTitle)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(model.selectedTabIDs.contains(tab.id) ? .isSelected : [])
    }

    private var accessibilityLabel: String {
        [
            tab.displayTitle,
            tab.domain,
            "закреплена",
            tab.isLoading ? "загружается" : nil
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
    }

    private var cardFill: Color {
        model.selectedTabIDs.contains(tab.id)
            ? Color.primary.opacity(0.12)
            : Color.primary.opacity(0.055)
    }

    @ViewBuilder
    private var pinnedContextMenu: some View {
        if model.selectedTabIDs.contains(tab.id), model.selectedTabCount > 1 {
            Button("Новая папка из выбранных") {
                model.createFolderFromSelection()
            }
        } else {
            Button("Новая папка с вкладкой") {
                model.createFolder(containing: [tab.id])
            }
        }
        Menu("Переместить в папку") {
            ForEach(sortedFolders) { folder in
                Button(model.folderPath(folder.id)) {
                    model.moveTab(tab.id, to: folder.id)
                }
            }
        }
        Divider()
        if !model.isPrivate {
            Button("Переместить в новое окно") {
                if !model.selectedTabIDs.contains(tab.id) {
                    model.selectTab(tab.id)
                }
                model.transferSelectedTabsToNewWindow()
            }
        }
        Button("Открепить") { model.setPinned(false, for: tab.id) }
        Button("Закрыть") { model.closeTab(tab.id) }
    }

    private var sortedFolders: [TabFolder] {
        model.folders.sorted { model.folderPath($0.id) < model.folderPath($1.id) }
    }

    private var itemLayoutReader: some View {
        SidebarItemLayoutReader(
            layout: SidebarItemLayout(
                key: .tab(tab.id),
                kind: .pinnedTab,
                parentID: nil,
                depth: 0
            )
        )
    }
}

private struct TabRow: View {
    let model: BrowserWindowModel
    let tab: BrowserTab
    let reorderState: SidebarReorderState
    let depth: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        Button {
            model.selectTab(
                tab.id,
                extendingSelection: NSEvent.modifierFlags.contains(.shift)
            )
        } label: { rowLabel }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isHovering)
        .onHover { isHovering = $0 }
        .opacity(reorderState.draggedTabIDs.contains(tab.id) ? 0 : 1)
        .background(itemLayoutReader)
        .overlay {
            SidebarDropIndicator(
                placement: reorderState.placement(for: .tab(tab.id)),
                cornerRadius: 9
            )
        }
        .contextMenu { tabContextMenu }
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(model.selectedTabIDs.contains(tab.id) ? .isSelected : [])
    }

    private var rowLabel: some View {
        HStack(spacing: 9) {
            TabFavicon(tab: tab, size: 22)
            tabTitle
            Spacer(minLength: 4)
            trailingControl
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 36)
        .contentShape(Rectangle())
        .background { selectionBackground }
    }

    private var tabTitle: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(tab.displayTitle).lineLimit(1)
            if let domain = tab.domain, isHovering {
                Text(domain)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    @ViewBuilder
    private var trailingControl: some View {
        if tab.isLoading {
            ProgressView().controlSize(.mini)
        } else if showsCloseButton {
            Button {
                model.closeTab(tab.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(closeAccessibilityLabel)
        }
    }

    @ViewBuilder
    private var selectionBackground: some View {
        if model.selectedTabIDs.contains(tab.id) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(
                    model.selectedTabID == tab.id
                        ? Color.primary.opacity(0.11)
                        : Color.accentColor.opacity(0.13)
                )
        }
    }

    @ViewBuilder
    private var tabContextMenu: some View {
        if model.selectedTabIDs.contains(tab.id), model.selectedTabCount > 1 {
            Button("Новая папка из выбранных") {
                model.createFolderFromSelection()
            }
        } else {
            Button("Новая папка с вкладкой") {
                model.createFolder(containing: [tab.id])
            }
        }
        Menu("Переместить в папку") {
            Button("Без папки") { model.moveTab(tab.id, to: nil) }
            Divider()
            ForEach(sortedFolders) { folder in
                Button(model.folderPath(folder.id)) {
                    model.moveTab(tab.id, to: folder.id)
                }
            }
        }
        Divider()
        if !model.isPrivate {
            Button("Переместить в новое окно") {
                if !model.selectedTabIDs.contains(tab.id) {
                    model.selectTab(tab.id)
                }
                model.transferSelectedTabsToNewWindow()
            }
        }
        Button(tab.isPinned ? "Открепить" : "Закрепить") {
            model.setPinned(!tab.isPinned, for: tab.id)
        }
        Button("Закрыть") { model.closeTab(tab.id) }
    }

    private var accessibilityLabel: String {
        [
            tab.displayTitle,
            tab.domain,
            tab.isPinned ? "закреплена" : nil,
            tab.isLoading ? "загружается" : nil
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
    }

    private var showsCloseButton: Bool {
        isHovering || model.selectedTabID == tab.id
    }

    private var closeAccessibilityLabel: String {
        "Закрыть \(tab.displayTitle)"
    }

    private var sortedFolders: [TabFolder] {
        model.folders.sorted { model.folderPath($0.id) < model.folderPath($1.id) }
    }

    private var itemLayoutReader: some View {
        SidebarItemLayoutReader(
            layout: SidebarItemLayout(
                key: .tab(tab.id),
                kind: .regularTab,
                parentID: tab.folderID,
                depth: depth
            )
        )
    }
}

private struct FolderTree: View {
    let model: BrowserWindowModel
    let reorderState: SidebarReorderState
    let parentID: TabFolderID?
    let depth: Int
    var visibleItemCount: Int? = nil

    var body: some View {
        let items = model.sidebarItems(in: parentID)
        let displayedItems = Array(items.prefix(min(visibleItemCount ?? items.count, items.count)))
        ForEach(Array(displayedItems.enumerated()), id: \.element.id) { _, item in
            switch item {
            case let .tab(tab):
                TabRow(
                    model: model,
                    tab: tab,
                    reorderState: reorderState,
                    depth: depth
                )
                    .padding(.leading, CGFloat(depth) * 15)
                    .transition(.staggeredFolderItem)
            case let .folder(folder):
                FolderRow(
                    model: model,
                    folder: folder,
                    reorderState: reorderState,
                    depth: depth
                )
                    .transition(.staggeredFolderItem)
            }
        }
    }
}

private extension AnyTransition {
    static var staggeredFolderItem: AnyTransition {
        .asymmetric(
            insertion: .opacity
                .combined(with: .offset(y: -6))
                .combined(with: .scale(scale: 0.975, anchor: .top)),
            removal: .opacity
                .combined(with: .offset(y: -3))
                .combined(with: .scale(scale: 0.99, anchor: .top))
        )
    }
}

private struct FolderRow: View {
    let model: BrowserWindowModel
    let folder: TabFolder
    let reorderState: SidebarReorderState
    let depth: Int

    @State private var draftName = ""
    @FocusState private var isRenameFocused: Bool
    @State private var dropPlacement: SidebarDropPlacement?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsChildren = false
    @State private var visibleChildCount = 0
    @State private var childAnimationTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Button {
                    model.toggleFolder(folder.id)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(folder.isExpanded ? 90 : 0))
                        .frame(width: 13, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .animation(
                    reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.72),
                    value: folder.isExpanded
                )

                Image(systemName: folder.symbolName)
                    .font(.system(size: 15, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.accentColor)
                    .scaleEffect(folder.isExpanded ? 1.06 : 1)
                    .animation(
                        reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.68),
                        value: folder.isExpanded
                    )

                if model.renamingFolderID == folder.id {
                    TextField("Название папки", text: $draftName)
                        .textFieldStyle(.plain)
                        .font(.callout.weight(.medium))
                        .focused($isRenameFocused)
                        .onSubmit { finishRenaming() }
                        .onExitCommand { cancelRenaming() }
                        .onChange(of: isRenameFocused) { wasFocused, isFocused in
                            if wasFocused, !isFocused, model.renamingFolderID == folder.id {
                                finishRenaming()
                            }
                        }
                        .task {
                            draftName = folder.name
                            isRenameFocused = true
                        }
                } else {
                    Text(folder.name)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Text("\(model.tabCount(in: folder.id))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .background(.quaternary, in: Capsule())
                    .contentTransition(.numericText())
            }
            .padding(.horizontal, 7)
            .frame(minHeight: 34)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(
                        (reorderState.placement(for: .folder(folder.id)) ?? dropPlacement) == .inside
                            ? Color.accentColor.opacity(0.16)
                            : Color.primary.opacity(0.035)
                    )
            }
            .overlay {
                SidebarDropIndicator(
                    placement: reorderState.placement(for: .folder(folder.id)) ?? dropPlacement,
                    cornerRadius: 9
                )
            }
            .background {
                SidebarItemLayoutReader(
                    layout: SidebarItemLayout(
                        key: .folder(folder.id),
                        kind: .folder,
                        parentID: folder.parentID,
                        depth: depth
                    )
                )
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                beginRenaming()
            }
            .onDrag {
                model.beginDraggingFolder(folder.id)
                return .sidebarItem(.folder(folder.id))
            } preview: {
                FolderDragPreview(folder: folder)
            }
            .onDrop(
                of: [.browserSidebarItem],
                delegate: FolderLiveDropDelegate(
                    model: model,
                    targetID: folder.id,
                    targetHeight: 34,
                    placement: $dropPlacement
                )
            )
            .contextMenu {
                Button("Переименовать") {
                    beginRenaming()
                }
                Menu("Значок папки") {
                    ForEach(FolderSymbolOption.popular) { option in
                        Button {
                            model.setFolderSymbol(option.symbolName, for: folder.id)
                        } label: {
                            Label(option.title, systemImage: option.symbolName)
                        }
                    }
                }
                Button("Новая вложенная папка") {
                    model.createFolder(inside: folder.id)
                }
                if model.selectedTabCount > 0 {
                    Button("Поместить выбранные сюда") {
                        model.moveSelectedTabs(to: folder.id)
                    }
                }
                Menu("Переместить папку") {
                    Button("На верхний уровень") {
                        model.moveFolder(folder.id, inside: nil)
                    }
                    Divider()
                    ForEach(
                        model.folders
                            .filter { model.canMoveFolder(folder.id, inside: $0.id) }
                            .sorted { model.folderPath($0.id) < model.folderPath($1.id) }
                    ) { destination in
                        Button(model.folderPath(destination.id)) {
                            model.moveFolder(folder.id, inside: destination.id)
                        }
                    }
                }
                Divider()
                Button("Удалить папку", role: .destructive) {
                    model.deleteFolder(folder.id)
                }
                Button("Удалить папку и содержимое", role: .destructive) {
                    model.deleteFolderWithContents(folder.id)
                }
            }

            if showsChildren {
                FolderTree(
                    model: model,
                    reorderState: reorderState,
                    parentID: folder.id,
                    depth: depth + 1,
                    visibleItemCount: visibleChildCount
                )
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(Color.primary.opacity(0.08))
                            .frame(width: 1)
                            .padding(.leading, 13)
                    }
                    .transition(.opacity)
            }
        }
        .padding(.leading, CGFloat(depth) * 15)
        .onAppear {
            showsChildren = folder.isExpanded
            visibleChildCount = folder.isExpanded ? childCount : 0
        }
        .onChange(of: folder.isExpanded) { _, isExpanded in
            animateChildren(expanding: isExpanded)
        }
        .onChange(of: childCount) { _, count in
            guard folder.isExpanded, showsChildren else { return }
            visibleChildCount = count
        }
        .onDisappear {
            childAnimationTask?.cancel()
        }
    }

    private func beginRenaming() {
        draftName = folder.name
        model.renamingFolderID = folder.id
        isRenameFocused = true
    }

    private func finishRenaming() {
        model.renameFolder(folder.id, to: draftName)
        isRenameFocused = false
    }

    private func cancelRenaming() {
        model.renamingFolderID = nil
        isRenameFocused = false
    }

    private var childCount: Int {
        model.sidebarItems(in: folder.id).count
    }

    private func animateChildren(expanding: Bool) {
        childAnimationTask?.cancel()
        if reduceMotion {
            showsChildren = expanding
            visibleChildCount = expanding ? childCount : 0
            return
        }

        let total = childCount
        if expanding {
            showsChildren = true
            visibleChildCount = 0
            guard total > 0 else { return }
            childAnimationTask = Task { @MainActor in
                for count in 1...total {
                    guard !Task.isCancelled else { return }
                    withAnimation(.spring(response: 0.24, dampingFraction: 0.82)) {
                        visibleChildCount = count
                    }
                    try? await Task.sleep(for: .milliseconds(38))
                }
            }
        } else {
            visibleChildCount = min(visibleChildCount, total)
            childAnimationTask = Task { @MainActor in
                for count in stride(from: visibleChildCount, to: 0, by: -1) {
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeOut(duration: 0.16)) {
                        visibleChildCount = count - 1
                    }
                    try? await Task.sleep(for: .milliseconds(30))
                }
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    showsChildren = false
                }
            }
        }
    }
}

private struct FolderSymbolOption: Identifiable {
    let symbolName: String
    let title: String

    var id: String { symbolName }

    static let popular: [FolderSymbolOption] = [
        FolderSymbolOption(symbolName: "folder.fill", title: "Папка"),
        FolderSymbolOption(symbolName: "briefcase.fill", title: "Работа"),
        FolderSymbolOption(symbolName: "book.closed.fill", title: "Чтение"),
        FolderSymbolOption(symbolName: "graduationcap.fill", title: "Учёба"),
        FolderSymbolOption(symbolName: "star.fill", title: "Избранное"),
        FolderSymbolOption(symbolName: "heart.fill", title: "Личное"),
        FolderSymbolOption(symbolName: "person.2.fill", title: "Команда"),
        FolderSymbolOption(symbolName: "cart.fill", title: "Покупки"),
        FolderSymbolOption(symbolName: "airplane", title: "Путешествия"),
        FolderSymbolOption(symbolName: "gamecontroller.fill", title: "Игры"),
        FolderSymbolOption(symbolName: "play.rectangle.fill", title: "Видео"),
        FolderSymbolOption(symbolName: "terminal.fill", title: "Разработка"),
        FolderSymbolOption(symbolName: "doc.text.fill", title: "Документы"),
        FolderSymbolOption(symbolName: "tray.full.fill", title: "Архив")
    ]
}

private enum SidebarDragPayload {
    case folder(TabFolderID)

    var rawValue: String {
        switch self {
        case let .folder(id):
            "folder:" + id.rawValue.uuidString
        }
    }
}

private extension UTType {
    static let browserSidebarItem = UTType(
        exportedAs: "com.browser.sidebar-item"
    )
}

private extension NSItemProvider {
    static func sidebarItem(_ payload: SidebarDragPayload) -> NSItemProvider {
        let provider = NSItemProvider()
        let data = Data(payload.rawValue.utf8)
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.browserSidebarItem.identifier,
            visibility: .ownProcess
        ) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }
}

enum SidebarDropPlacement: Equatable {
    case before
    case inside
    case after

    static func besideItem(at y: CGFloat, height: CGFloat) -> Self {
        y < height / 2 ? .before : .after
    }

    static func overFolder(at y: CGFloat, height: CGFloat) -> Self {
        let edge = height * 0.25
        if y <= edge { return .before }
        if y >= height - edge { return .after }
        return .inside
    }
}

private struct SidebarDropIndicator: View {
    let placement: SidebarDropPlacement?
    let cornerRadius: CGFloat

    var body: some View {
        ZStack {
            if placement == .inside {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.72), lineWidth: 1.5)
                    .background(
                        Color.accentColor.opacity(0.07),
                        in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    )
            }

            if placement == .before || placement == .after {
                insertionLine
                    .frame(maxHeight: .infinity, alignment: placement == .before ? .top : .bottom)
            }
        }
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.1), value: placement)
    }

    private var insertionLine: some View {
        HStack(spacing: 0) {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 6, height: 6)
            Capsule()
                .fill(Color.accentColor)
                .frame(height: 2)
        }
        .padding(.horizontal, 3)
    }
}

private struct FolderLiveDropDelegate: DropDelegate {
    let model: BrowserWindowModel
    let targetID: TabFolderID
    let targetHeight: CGFloat
    let placement: Binding<SidebarDropPlacement?>

    func dropEntered(info: DropInfo) {
        updateTarget(for: info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        updateTarget(for: info)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        Task { @MainActor in
            placement.wrappedValue = nil
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        Task { @MainActor in
            placement.wrappedValue = nil
            model.finishDragReordering()
        }
        return true
    }

    private func updateTarget(for info: DropInfo) {
        let proposedPlacement = SidebarDropPlacement.overFolder(
            at: info.location.y,
            height: targetHeight
        )
        Task { @MainActor in
            guard placement.wrappedValue != proposedPlacement else { return }
            if !model.draggingTabIDs.isEmpty {
                placement.wrappedValue = proposedPlacement
                withAnimation(.snappy(duration: 0.12)) {
                    if proposedPlacement == .inside {
                        model.moveTabs(
                            model.draggingTabIDs,
                            to: targetID,
                            persistChange: false
                        )
                    } else {
                        model.moveTabs(
                            model.draggingTabIDs,
                            relativeTo: targetID,
                            insertAfter: proposedPlacement == .after,
                            persistChange: false
                        )
                    }
                }
            } else if let draggingFolderID = model.draggingFolderID,
                      draggingFolderID != targetID {
                guard proposedPlacement != .inside
                        || model.canMoveFolder(draggingFolderID, inside: targetID)
                else {
                    placement.wrappedValue = nil
                    return
                }
                placement.wrappedValue = proposedPlacement
                if proposedPlacement == .inside {
                    model.moveFolder(draggingFolderID, inside: targetID)
                } else {
                    withAnimation(.snappy(duration: 0.12)) {
                        _ = model.moveFolder(
                            draggingFolderID,
                            relativeTo: targetID,
                            insertAfter: proposedPlacement == .after,
                            persistChange: false
                        )
                    }
                }
            } else {
                placement.wrappedValue = nil
            }
        }
    }
}

private struct RootAppendDropDelegate: DropDelegate {
    let model: BrowserWindowModel
    let isTargeted: Binding<Bool>

    func dropEntered(info: DropInfo) {
        Task { @MainActor in
            isTargeted.wrappedValue = true
            if !model.draggingTabIDs.isEmpty {
                withAnimation(.snappy(duration: 0.12)) {
                    model.moveTabs(model.draggingTabIDs, to: nil, persistChange: false)
                }
            } else if let folderID = model.draggingFolderID {
                model.moveFolder(folderID, inside: nil)
            }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        Task { @MainActor in isTargeted.wrappedValue = false }
    }

    func performDrop(info: DropInfo) -> Bool {
        Task { @MainActor in
            isTargeted.wrappedValue = false
            model.finishDragReordering()
        }
        return true
    }
}

private struct FloatingTabRow: View {
    let model: BrowserWindowModel
    let tab: BrowserTab
    let count: Int

    var body: some View {
        HStack(spacing: 9) {
            TabFavicon(tab: tab, size: 22)
            Text(tab.displayTitle)
                .lineLimit(1)
            Spacer(minLength: 4)
            if count > 1 {
                Text("\(count)")
                    .font(.caption2.bold().monospacedDigit())
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .background(.quaternary, in: Capsule())
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 36)
        .background {
            if model.selectedTabIDs.contains(tab.id) {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(
                        model.selectedTabID == tab.id
                            ? Color.primary.opacity(0.11)
                            : Color.accentColor.opacity(0.13)
                    )
            }
        }
    }
}

private struct FloatingPinnedTabCard: View {
    let model: BrowserWindowModel
    let tab: BrowserTab
    let count: Int

    var body: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    model.selectedTabIDs.contains(tab.id)
                        ? Color.primary.opacity(0.12)
                        : Color.primary.opacity(0.055)
                )

            TabFavicon(tab: tab, size: 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if count > 1 {
                Text("\(count)")
                    .font(.caption2.bold().monospacedDigit())
                    .padding(.horizontal, 5)
                    .frame(height: 17)
                    .background(.regularMaterial, in: Capsule())
                    .padding(5)
            }
        }
    }
}

private struct FolderDragPreview: View {
    let folder: TabFolder

    var body: some View {
        Label(folder.name, systemImage: folder.symbolName)
            .lineLimit(1)
            .padding(.horizontal, 11)
            .frame(height: 38)
            .frame(maxWidth: 220)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 12, y: 5)
    }
}

private struct NewTabRow: View {
    let model: BrowserWindowModel
    let reorderState: SidebarReorderState

    @State private var isHovering = false
    @State private var isDropTargeted = false

    var body: some View {
        let isReorderTargeted = reorderState.placement(for: .rootEnd) != nil
        let showsDropTarget = isDropTargeted || isReorderTargeted
        Button {
            model.newTab()
        } label: {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.quaternary)
                    Image(systemName: showsDropTarget ? "arrow.down" : "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 22, height: 22)

                Text(showsDropTarget ? "Переместить на верхний уровень" : "Новая вкладка")
                    .lineLimit(1)

                Spacer(minLength: 4)

                if !showsDropTarget {
                    Text("⌘T")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 36)
            .contentShape(Rectangle())
            .background {
                if showsDropTarget {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.accentColor.opacity(0.14))
                        .overlay {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .stroke(Color.accentColor.opacity(0.45), lineWidth: 1)
                        }
                } else if isHovering {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(.primary.opacity(0.055))
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .background {
            SidebarItemLayoutReader(
                layout: SidebarItemLayout(
                    key: .rootEnd,
                    kind: .rootEnd,
                    parentID: nil,
                    depth: 0
                )
            )
        }
        .onDrop(
            of: [.browserSidebarItem],
            delegate: RootAppendDropDelegate(
                model: model,
                isTargeted: $isDropTargeted
            )
        )
        .accessibilityLabel("Новая вкладка")
    }
}

struct TabFavicon: View {
    let tab: BrowserTab
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                .fill(.quaternary)
            if tab.lifecycleState == .crashed {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: size * 0.5, weight: .medium))
                    .foregroundStyle(.orange)
            } else if let favicon = tab.favicon {
                Image(nsImage: favicon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(size * 0.14)
            } else {
                Image(systemName: "globe")
                    .font(.system(size: size * 0.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
    }
}
