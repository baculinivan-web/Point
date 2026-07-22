import AppKit
import BrowserCore
import BrowserEngine
import SwiftUI

struct OmniboxOverlay: View {
    @Bindable var model: BrowserWindowModel
    @FocusState private var isFocused: Bool
    @State private var highlightedTabID: TabID?

    private var visibleMatchingTabs: [BrowserTab] {
        Array(model.matchingTabs.prefix(6))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Menu {
                    Section("Поисковая система по умолчанию") {
                        ForEach(SearchEngine.allCases) { searchEngine in
                            Button {
                                model.selectSearchEngine(searchEngine)
                            } label: {
                                if model.searchEngine == searchEngine {
                                    Label(searchEngine.displayName, systemImage: "checkmark")
                                } else {
                                    Text(searchEngine.displayName)
                                }
                            }
                        }
                    }
                } label: {
                    SearchEngineIcon(searchEngine: model.searchEngine)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Поиск: \(model.searchEngine.displayName)")
                .accessibilityLabel(
                    "Поисковая система: \(model.searchEngine.displayName)"
                )
                TextField("Адрес или поисковый запрос", text: $model.omniboxText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18))
                    .focused($isFocused)
                    .onSubmit { activateHighlightedTabOrSubmit() }
                    .onKeyPress(.downArrow) {
                        moveHighlight(by: 1)
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        moveHighlight(by: -1)
                        return .handled
                    }
                    .onExitCommand { model.dismissOmnibox() }
                if !model.omniboxText.isEmpty {
                    Button {
                        model.omniboxText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Очистить")
                }
            }
            .padding(.horizontal, 18)
            .frame(height: 56)

            if let error = model.omniboxError {
                Divider()
                Label(error, systemImage: "exclamationmark.shield")
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            } else if !visibleMatchingTabs.isEmpty {
                Divider()
                VStack(spacing: 2) {
                    ForEach(visibleMatchingTabs) { tab in
                        Button {
                            activate(tab)
                        } label: {
                            HStack(spacing: 10) {
                                TabFavicon(tab: tab, size: 22)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(tab.displayTitle).lineLimit(1)
                                    if let url = tab.url {
                                        Text(url.absoluteString)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer()
                                Text("Открытая вкладка")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                            .padding(.horizontal, 14)
                            .frame(height: 46)
                            .background {
                                if highlightedTabID == tab.id {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(Color.accentColor.opacity(0.14))
                                        .padding(.horizontal, 6)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .onHover { isHovering in
                            if isHovering {
                                highlightedTabID = tab.id
                            }
                        }
                        .accessibilityAddTraits(
                            highlightedTabID == tab.id ? .isSelected : []
                        )
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .frame(width: 620)
        .browserGlassSurface(cornerRadius: 20)
        .shadow(color: .black.opacity(0.18), radius: 30, y: 14)
        .task {
            await Task.yield()
            isFocused = true
        }
        .onChange(of: model.omniboxText) {
            highlightedTabID = nil
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Адрес и поиск")
    }

    private func moveHighlight(by offset: Int) {
        let tabs = visibleMatchingTabs
        guard !tabs.isEmpty else {
            highlightedTabID = nil
            return
        }

        guard let highlightedTabID,
              let index = tabs.firstIndex(where: { $0.id == highlightedTabID })
        else {
            self.highlightedTabID = offset > 0 ? tabs.first?.id : tabs.last?.id
            return
        }

        let nextIndex = (index + offset + tabs.count) % tabs.count
        self.highlightedTabID = tabs[nextIndex].id
    }

    private func activateHighlightedTabOrSubmit() {
        guard let highlightedTabID,
              let tab = visibleMatchingTabs.first(where: { $0.id == highlightedTabID })
        else {
            model.submitOmnibox()
            return
        }
        activate(tab)
    }

    private func activate(_ tab: BrowserTab) {
        model.selectOpenTabFromOmnibox(tab.id)
    }
}

private struct SearchEngineIcon: View {
    let searchEngine: SearchEngine

    var body: some View {
        Group {
            if let image = searchEngine.iconImage {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(searchEngine.fallbackColor)
                    Text(searchEngine.monogram)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: 22, height: 22)
        .clipped()
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private extension SearchEngine {
    @MainActor
    var iconImage: NSImage? {
        SearchEngineIconCache.images[self]
    }

    var iconResourceName: String {
        switch self {
        case .duckDuckGo: "duckduckgo"
        case .google: "google"
        case .bing: "bing"
        case .brave: "brave"
        case .yandex: "yandex"
        }
    }

    var monogram: String {
        switch self {
        case .duckDuckGo: "D"
        case .google: "G"
        case .bing: "b"
        case .brave: "B"
        case .yandex: "Я"
        }
    }

    var fallbackColor: Color {
        switch self {
        case .duckDuckGo: Color(red: 0.86, green: 0.30, blue: 0.16)
        case .google: Color(red: 0.20, green: 0.50, blue: 0.92)
        case .bing: Color(red: 0.00, green: 0.52, blue: 0.51)
        case .brave: Color(red: 0.95, green: 0.29, blue: 0.18)
        case .yandex: Color(red: 0.94, green: 0.16, blue: 0.15)
        }
    }
}

@MainActor
private enum SearchEngineIconCache {
    static let bundle: Bundle = {
        if let resourcesURL = Bundle.main.resourceURL,
           let bundle = Bundle(
               url: resourcesURL.appending(path: "Browser_BrowserUI.bundle")
           ) {
            return bundle
        }
        return Bundle.module
    }()

    static let images: [SearchEngine: NSImage] = Dictionary(
        uniqueKeysWithValues: SearchEngine.allCases.compactMap { searchEngine in
            let url = bundle.url(
                forResource: searchEngine.iconResourceName,
                withExtension: "svg",
                subdirectory: "SearchEngines"
            ) ?? bundle.url(
                forResource: searchEngine.iconResourceName,
                withExtension: "svg"
            )
            guard let url, let image = NSImage(contentsOf: url) else { return nil }
            if searchEngine.needsIntrinsicSizeNormalization {
                let sourceSize = image.size
                let scale = 22 / max(sourceSize.width, sourceSize.height)
                image.size = NSSize(
                    width: sourceSize.width * scale,
                    height: sourceSize.height * scale
                )
            }
            return (searchEngine, image)
        }
    )
}

private extension SearchEngine {
    var needsIntrinsicSizeNormalization: Bool {
        switch self {
        case .google, .bing, .duckDuckGo: true
        case .brave, .yandex: false
        }
    }
}

struct FindOverlay: View {
    @Bindable var model: BrowserWindowModel
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Найти на странице", text: $model.findText)
                .textFieldStyle(.plain)
                .frame(width: 210)
                .focused($isFocused)
                .onSubmit { model.submitFind() }
                .onExitCommand { model.isFindPresented = false }
            Button {
                model.isFindPresented = false
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Закрыть поиск")
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
        .browserGlassSurface(cornerRadius: 13)
        .shadow(color: .black.opacity(0.14), radius: 16, y: 8)
        .task {
            await Task.yield()
            isFocused = true
        }
    }
}

struct MediaPermissionOverlay: View {
    let prompt: MediaPermissionPrompt
    let onResolve: (MediaPermissionAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 13) {
                Image(systemName: prompt.kind.systemImage)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 5) {
                    Text(prompt.kind.title)
                        .font(.headline)
                    Text(prompt.origin.displayName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            if prompt.origin != prompt.topLevelOrigin {
                Text("Запрос встроен в страницу \(prompt.topLevelOrigin.displayName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 9) {
                Button("Не разрешать") {
                    onResolve(.deny)
                }
                .keyboardShortcut(.cancelAction)

                Spacer(minLength: 8)

                Button("Разрешать всегда") {
                    onResolve(.alwaysAllow)
                }
                .disabled(!prompt.canAlwaysAllow)
                .help(
                    prompt.canAlwaysAllow
                        ? "Сохранить решение для этого сайта"
                        : "Постоянное разрешение доступно только для HTTPS"
                )

                Button("Разрешить один раз") {
                    onResolve(.allowOnce)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 470)
        .browserGlassSurface(cornerRadius: 20)
        .shadow(color: .black.opacity(0.18), radius: 24, y: 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(prompt.kind.title)
    }
}

private extension MediaPermissionKind {
    var title: String {
        switch self {
        case .camera:
            "Разрешить доступ к камере?"
        case .microphone:
            "Разрешить доступ к микрофону?"
        case .cameraAndMicrophone:
            "Разрешить доступ к камере и микрофону?"
        }
    }

    var systemImage: String {
        switch self {
        case .camera:
            "video"
        case .microphone:
            "mic"
        case .cameraAndMicrophone:
            "video.badge.waveform"
        }
    }

    var managementTitle: String {
        switch self {
        case .camera:
            "Камера"
        case .microphone:
            "Микрофон"
        case .cameraAndMicrophone:
            "Камера и микрофон"
        }
    }
}

struct SitePermissionsOverlay: View {
    @Bindable var model: BrowserWindowModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 560, height: 460)
        .browserGlassSurface(cornerRadius: 20)
        .shadow(color: .black.opacity(0.18), radius: 28, y: 14)
        .onExitCommand { model.dismissSitePermissions() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Разрешения сайтов")
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Разрешения сайтов")
                .font(.headline)
            if model.isLoadingSitePermissions {
                ProgressView()
                    .controlSize(.small)
            }
            Spacer()
            Button {
                model.dismissSitePermissions()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Закрыть")
        }
        .padding(.horizontal, 18)
        .frame(height: 54)
    }

    @ViewBuilder
    private var content: some View {
        if let error = model.sitePermissionsError {
            ContentUnavailableView(
                "Разрешения недоступны",
                systemImage: "exclamationmark.triangle",
                description: Text(error)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.sitePermissions.isEmpty {
            ContentUnavailableView(
                "Нет сохранённых разрешений",
                systemImage: "hand.raised",
                description: Text("Новые решения появятся после запроса сайта")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.sitePermissions, id: \.self) { permission in
                        SitePermissionRow(permission: permission) {
                            model.revokeSitePermission(permission)
                        }
                        Divider()
                            .padding(.leading, 54)
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("Persistent allow доступен только для HTTPS")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Очистить все") {
                model.clearSitePermissions()
            }
            .disabled(model.sitePermissions.isEmpty || model.isLoadingSitePermissions)
        }
        .padding(.horizontal, 18)
        .frame(height: 54)
    }
}

private struct SitePermissionRow: View {
    let permission: StoredSitePermission
    let onRevoke: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: permission.kind.systemImage)
                .font(.system(size: 17, weight: .medium))
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 3) {
                Text(permission.origin.displayName)
                    .lineLimit(1)
                    .textSelection(.enabled)
                Text(permission.kind.managementTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Text(permission.decision == .allow ? "Разрешено" : "Запрещено")
                .font(.caption.weight(.medium))
                .foregroundStyle(permission.decision == .allow ? Color.green : Color.secondary)

            Button(action: onRevoke) {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .help("Удалить сохранённое решение")
            .accessibilityLabel("Отозвать разрешение для \(permission.origin.displayName)")
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 58)
    }
}

struct BrowsingHistoryOverlay: View {
    @Bindable var model: BrowserWindowModel
    @State private var confirmsClear = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 640, height: 520)
        .browserGlassSurface(cornerRadius: 20)
        .shadow(color: .black.opacity(0.18), radius: 28, y: 14)
        .onExitCommand { model.dismissBrowsingHistory() }
        .confirmationDialog(
            "Очистить всю историю посещений?",
            isPresented: $confirmsClear,
            titleVisibility: .visible
        ) {
            Button("Очистить историю", role: .destructive) {
                model.clearBrowsingHistory()
            }
        } message: {
            Text("Вкладки, cookies и данные сайтов останутся без изменений.")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("История посещений")
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("История")
                .font(.headline)
            if model.isLoadingBrowsingHistory {
                ProgressView()
                    .controlSize(.small)
            }
            Spacer()
            Button {
                model.dismissBrowsingHistory()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Закрыть")
        }
        .padding(.horizontal, 18)
        .frame(height: 54)
    }

    @ViewBuilder
    private var content: some View {
        if let error = model.browsingHistoryError {
            ContentUnavailableView(
                "История недоступна",
                systemImage: "exclamationmark.triangle",
                description: Text(error)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.browsingHistory.isEmpty, !model.isLoadingBrowsingHistory {
            ContentUnavailableView(
                "История пуста",
                systemImage: "clock.arrow.circlepath",
                description: Text("Посещённые страницы появятся здесь")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.browsingHistory) { entry in
                        BrowsingHistoryRow(
                            entry: entry,
                            favicon: model.browsingHistoryFavicons[entry.id]
                        ) {
                            model.openBrowsingHistoryEntry(entry)
                        }
                        Divider()
                            .padding(.leading, 58)
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("Favicons загружаются только из локального кэша")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Очистить историю") {
                confirmsClear = true
            }
            .disabled(model.browsingHistory.isEmpty || model.isLoadingBrowsingHistory)
        }
        .padding(.horizontal, 18)
        .frame(height: 54)
    }
}

private struct BrowsingHistoryRow: View {
    let entry: BrowsingHistoryEntry
    let favicon: NSImage?
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                faviconView

                VStack(alignment: .leading, spacing: 3) {
                    Text(displayTitle)
                        .lineLimit(1)
                    Text(entry.url.absoluteString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 12)

                Text(entry.visitedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(displayTitle), \(entry.url.absoluteString)")
    }

    @ViewBuilder
    private var faviconView: some View {
        if let favicon {
            Image(nsImage: favicon)
                .resizable()
                .scaledToFit()
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .frame(width: 30, height: 30)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(monogramColor.opacity(0.18))
                Text(monogram)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(monogramColor)
            }
            .frame(width: 30, height: 30)
        }
    }

    private var displayTitle: String {
        let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty, title != "Новая вкладка" { return title }
        return entry.url.host ?? entry.url.absoluteString
    }

    private var monogram: String {
        String((entry.url.host ?? "?").prefix(1)).uppercased()
    }

    private var monogramColor: Color {
        let seed = (entry.url.host ?? entry.url.absoluteString).unicodeScalars.reduce(0) {
            ($0 &* 31 &+ Int($1.value)) % 360
        }
        return Color(hue: Double(seed) / 360, saturation: 0.58, brightness: 0.72)
    }
}

struct ClearBrowsingDataOverlay: View {
    @Bindable var model: BrowserWindowModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(BrowsingDataCategory.allCases) { category in
                        Toggle(isOn: selectionBinding(for: category)) {
                            HStack(spacing: 12) {
                                Image(systemName: category.systemImage)
                                    .font(.system(size: 17, weight: .medium))
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(category.title)
                                    Text(category.detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                        .padding(.horizontal, 18)
                        .frame(minHeight: 60)
                        .disabled(model.isClearingBrowsingData)

                        if category != BrowsingDataCategory.allCases.last {
                            Divider()
                                .padding(.leading, 62)
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            Divider()
            footer
        }
        .frame(width: 600, height: 590)
        .browserGlassSurface(cornerRadius: 20)
        .shadow(color: .black.opacity(0.18), radius: 28, y: 14)
        .onExitCommand { model.dismissClearBrowsingData() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Очистка данных браузера")
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Очистить данные браузера")
                .font(.headline)
            if model.isClearingBrowsingData {
                ProgressView()
                    .controlSize(.small)
            }
            Spacer()
            Button {
                model.dismissClearBrowsingData()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .disabled(model.isClearingBrowsingData)
            .accessibilityLabel("Закрыть")
        }
        .padding(.horizontal, 18)
        .frame(height: 54)
    }

    private var footer: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Период: за всё время")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(allSelected ? "Снять выбор" : "Выбрать всё") {
                    model.selectedBrowsingDataCategories = allSelected
                        ? []
                        : Set(BrowsingDataCategory.allCases)
                }
                .buttonStyle(.plain)
                .disabled(model.isClearingBrowsingData)
            }

            HStack {
                if let status = model.clearBrowsingDataStatus {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(
                            status.hasPrefix("Часть") ? Color.red : Color.secondary
                        )
                        .lineLimit(2)
                } else {
                    Text("Cookies и данные сайтов потребуют повторного входа")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Очистить", role: .destructive) {
                    model.clearSelectedBrowsingData()
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    model.selectedBrowsingDataCategories.isEmpty
                        || model.isClearingBrowsingData
                )
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 86)
    }

    private var allSelected: Bool {
        model.selectedBrowsingDataCategories.count == BrowsingDataCategory.allCases.count
    }

    private func selectionBinding(for category: BrowsingDataCategory) -> Binding<Bool> {
        Binding(
            get: { model.selectedBrowsingDataCategories.contains(category) },
            set: { selected in
                if selected {
                    model.selectedBrowsingDataCategories.insert(category)
                } else {
                    model.selectedBrowsingDataCategories.remove(category)
                }
                model.clearBrowsingDataStatus = nil
            }
        )
    }
}

private extension BrowsingDataCategory {
    var title: String {
        switch self {
        case .history: "История посещений"
        case .cookies: "Cookies"
        case .cache: "Web-кэш"
        case .localStorage: "Локальные данные сайтов"
        case .serviceWorkers: "Service workers"
        case .sitePermissions: "Разрешения сайтов"
        case .downloadHistory: "История загрузок"
        case .favicons: "Favicons"
        }
    }

    var detail: String {
        switch self {
        case .history: "Список посещённых страниц"
        case .cookies: "Сеансы входа и предпочтения сайтов"
        case .cache: "Disk, memory и offline web cache"
        case .localStorage: "Local Storage, IndexedDB и WebSQL"
        case .serviceWorkers: "Фоновые регистрации сайтов"
        case .sitePermissions: "Сохранённые решения камеры и микрофона"
        case .downloadHistory: "Завершённые записи; активные загрузки сохранятся"
        case .favicons: "Memory/disk-кэш иконок сайтов"
        }
    }

    var systemImage: String {
        switch self {
        case .history: "clock.arrow.circlepath"
        case .cookies: "circle.grid.2x2"
        case .cache: "externaldrive"
        case .localStorage: "cylinder"
        case .serviceWorkers: "gearshape.2"
        case .sitePermissions: "hand.raised"
        case .downloadHistory: "arrow.down.circle"
        case .favicons: "photo"
        }
    }
}

struct SidebarDownloadsView: View {
    @Bindable var manager: DownloadManager
    let onResume: (UUID) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Загрузки")
                    .font(.headline)
                Spacer()
                Button("Очистить") {
                    manager.clearInactive()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(!manager.items.contains { !$0.state.isActive })
            }
            .padding(14)

            Divider()

            if manager.items.isEmpty {
                ContentUnavailableView(
                    "Нет загрузок",
                    systemImage: "arrow.down.circle",
                    description: Text("Загрузки текущего запуска появятся здесь")
                )
                .frame(height: 180)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(manager.items) { item in
                            DownloadRow(
                                item: item,
                                onCancel: { manager.cancel(item.id) },
                                onResume: { onResume(item.id) },
                                onRemove: { manager.remove(item.id) }
                            )
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 420)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct DownloadRow: View {
    let item: DownloadItem
    let onCancel: () -> Void
    let onResume: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: stateSymbol)
                .font(.title3)
                .foregroundStyle(stateColor)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 5) {
                Text(item.suggestedFilename)
                    .lineLimit(1)
                stateDetail
                if item.state == .downloading {
                    if let progress = item.fractionCompleted {
                        ProgressView(value: progress)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }

            Spacer(minLength: 6)
            actionButton
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 58)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var stateDetail: some View {
        switch item.state {
        case .awaitingDestination:
            Text("Выбор места…")
                .foregroundStyle(.secondary)
        case .downloading:
            Text(progressLabel)
                .foregroundStyle(.secondary)
        case .finished:
            Text("Завершено")
                .foregroundStyle(.secondary)
        case .cancelled:
            Text("Отменено")
                .foregroundStyle(.secondary)
        case let .failed(message):
            Text(message)
                .foregroundStyle(.red)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch item.state {
        case .awaitingDestination, .downloading:
            Button(action: onCancel) {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Отменить загрузку")
        case .finished:
            Button {
                if let destination = item.destinationURL {
                    NSWorkspace.shared.activateFileViewerSelecting([destination])
                }
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.plain)
            .disabled(item.destinationURL == nil)
            .accessibilityLabel("Показать в Finder")
        case .cancelled, .failed:
            if item.resumeData != nil {
                Button(action: onResume) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Продолжить загрузку")
            } else {
                Button(action: onRemove) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Удалить из списка")
            }
        }
    }

    private var progressLabel: String {
        guard let progress = item.fractionCompleted else { return "Загрузка…" }
        return progress.formatted(.percent.precision(.fractionLength(0)))
    }

    private var stateSymbol: String {
        switch item.state {
        case .awaitingDestination, .downloading: "arrow.down.circle"
        case .finished: "checkmark.circle.fill"
        case .cancelled: "xmark.circle"
        case .failed: "exclamationmark.triangle"
        }
    }

    private var stateColor: Color {
        switch item.state {
        case .finished: .green
        case .failed: .red
        default: .secondary
        }
    }
}
