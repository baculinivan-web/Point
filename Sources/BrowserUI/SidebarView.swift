import BrowserCore
import SwiftUI

struct SidebarView: View {
    let model: BrowserWindowModel

    var body: some View {
        sidebarContent
            .browserGlassSurface(cornerRadius: 20)
            .shadow(color: .black.opacity(0.16), radius: 24, x: 6, y: 8)
    }

    private var sidebarContent: some View {
        VStack(spacing: 0) {
            navigationHeader
                .padding(.horizontal, 12)
                .padding(.top, 38)
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
                            sectionTitle("Закреплённые")
                            ForEach(model.pinnedTabs) { tab in
                                TabRow(model: model, tab: tab)
                            }
                        }

                        sectionTitle("Вкладки")
                        ForEach(model.regularTabs) { tab in
                            TabRow(model: model, tab: tab)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 10)
                }

                Divider()
                    .opacity(0.6)

                HStack {
                    Button {
                        model.newTab()
                    } label: {
                        Label("Новая вкладка", systemImage: "plus")
                    }
                    .buttonStyle(.plain)

                    Spacer()
                }
                .padding(12)
            }
        }
    }

    private var navigationHeader: some View {
        HStack(spacing: 6) {
            Button {
                model.toggleSidebarMode()
            } label: {
                Image(systemName: model.sidebarMode == .autoHide ? "pin" : "sidebar.left")
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

    private func sectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct TabRow: View {
    let model: BrowserWindowModel
    let tab: BrowserTab
    @State private var isHovering = false

    var body: some View {
        Button {
            model.selectTab(tab.id)
        } label: {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.quaternary)
                    if tab.lifecycleState == .crashed {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.orange)
                    } else if let favicon = tab.favicon {
                        Image(nsImage: favicon)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .padding(3)
                    } else {
                        Image(systemName: "globe")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: 1) {
                    Text(tab.displayTitle)
                        .lineLimit(1)
                    if let domain = tab.domain, isHovering {
                        Text(domain)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
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
