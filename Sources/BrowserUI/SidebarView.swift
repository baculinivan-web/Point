import BrowserCore
import SwiftUI

struct SidebarView: View {
    let model: BrowserWindowModel
    let isFullScreen: Bool

    private var pinnedColumns: [GridItem] {
        let columnCount = model.pinnedTabs.count.isMultiple(of: 3) ? 3 : 2
        return Array(
            repeating: GridItem(.flexible(), spacing: 7),
            count: columnCount
        )
    }

    var body: some View {
        sidebarContent
            .browserGlassSurface(cornerRadius: 20)
            .shadow(color: .black.opacity(0.16), radius: 24, x: 6, y: 8)
    }

    private var sidebarContent: some View {
        VStack(spacing: 0) {
            navigationHeader
                .padding(.horizontal, 12)
                .padding(.top, isFullScreen ? 24 : 38)
                .padding(.bottom, 10)

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

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        if !model.pinnedTabs.isEmpty {
                            LazyVGrid(columns: pinnedColumns, spacing: 8) {
                                ForEach(model.pinnedTabs) { tab in
                                    PinnedTabCard(model: model, tab: tab)
                                }
                            }
                            .padding(.horizontal, 4)
                            .padding(.bottom, 5)
                        }

                        ForEach(model.regularTabs) { tab in
                            TabRow(model: model, tab: tab)
                        }

                        NewTabRow(model: model)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 10)
                }
            }
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

}

private struct PinnedTabCard: View {
    let model: BrowserWindowModel
    let tab: BrowserTab

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button {
                model.selectTab(tab.id)
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
        .draggable(tab.id.rawValue.uuidString)
        .dropDestination(for: String.self) { items, _ in
            guard let value = items.first,
                  let uuid = UUID(uuidString: value)
            else { return false }
            model.moveTab(TabID(uuid), before: tab.id)
            return true
        }
        .contextMenu {
            Button("Открепить") {
                model.setPinned(false, for: tab.id)
            }
            Button("Закрыть") {
                model.closeTab(tab.id)
            }
        }
        .help(tab.url?.absoluteString ?? tab.displayTitle)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(model.selectedTabID == tab.id ? .isSelected : [])
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
        model.selectedTabID == tab.id
            ? Color.primary.opacity(0.12)
            : Color.primary.opacity(0.055)
    }
}

private struct TabRow: View {
    let model: BrowserWindowModel
    let tab: BrowserTab

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        Button {
            model.selectTab(tab.id)
        } label: {
            HStack(spacing: 9) {
                TabFavicon(tab: tab, size: 22)

                VStack(alignment: .leading, spacing: 1) {
                    Text(tab.displayTitle)
                        .lineLimit(1)
                    if let domain = tab.domain, isHovering {
                        Text(domain)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .transition(
                                .opacity.combined(with: .move(edge: .top))
                            )
                    }
                }

                Spacer(minLength: 4)

                if tab.isLoading {
                    ProgressView()
                        .controlSize(.mini)
                } else if isHovering || model.selectedTabID == tab.id {
                    Button {
                        model.closeTab(tab.id)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.semibold))
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Закрыть \(tab.displayTitle)")
                }
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 36)
            .contentShape(Rectangle())
            .background {
                if model.selectedTabID == tab.id {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(.primary.opacity(0.09))
                }
            }
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isHovering)
        .onHover { isHovering = $0 }
        .draggable(tab.id.rawValue.uuidString)
        .dropDestination(for: String.self) { items, _ in
            guard let value = items.first,
                  let uuid = UUID(uuidString: value)
            else { return false }
            model.moveTab(TabID(uuid), before: tab.id)
            return true
        }
        .contextMenu {
            Button(tab.isPinned ? "Открепить" : "Закрепить") {
                model.setPinned(!tab.isPinned, for: tab.id)
            }
            Button("Закрыть") {
                model.closeTab(tab.id)
            }
        }
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(model.selectedTabID == tab.id ? .isSelected : [])
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
}

private struct NewTabRow: View {
    let model: BrowserWindowModel

    @State private var isHovering = false

    var body: some View {
        Button {
            model.newTab()
        } label: {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.quaternary)
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 22, height: 22)

                Text("Новая вкладка")
                    .lineLimit(1)

                Spacer(minLength: 4)

                Text("⌘T")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 36)
            .contentShape(Rectangle())
            .background {
                if isHovering {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(.primary.opacity(0.055))
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
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
