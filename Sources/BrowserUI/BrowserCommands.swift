import BrowserCore
import SwiftUI

private struct BrowserWindowModelKey: FocusedValueKey {
    typealias Value = BrowserWindowModel
}

extension FocusedValues {
    var browserWindowModel: BrowserWindowModel? {
        get { self[BrowserWindowModelKey.self] }
        set { self[BrowserWindowModelKey.self] = newValue }
    }
}

public struct BrowserCommands: Commands {
    @FocusedValue(\.browserWindowModel) private var model

    public init() {}

    public var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Сделать браузером по умолчанию") {
                model?.makeDefaultBrowser()
            }

            Button("Разрешить ключи входа…") {
                model?.requestPasskeyAccess()
            }

            Button("Разрешения сайтов…") {
                model?.presentSitePermissions()
            }

            Button("Очистить данные браузера…") {
                model?.presentClearBrowsingData()
            }
            .keyboardShortcut(.delete, modifiers: [.command, .shift])
        }

        CommandGroup(replacing: .newItem) {
            Button("Новая вкладка") {
                model?.newTab()
            }
            .keyboardShortcut("t")

            Button("Новое окно") {
                NSApp.sendAction(#selector(NSWindowController.newWindowForTab(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("n")
        }

        CommandMenu("Вкладки") {
            Button("Закрыть вкладку") {
                guard let id = model?.selectedTabID else { return }
                model?.closeTab(id)
            }
            .keyboardShortcut("w")

            Button("Открыть закрытую вкладку") {
                model?.reopenClosedTab()
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])

            Divider()

            Button("Адрес и поиск") {
                model?.presentOmnibox()
            }
            .keyboardShortcut("l")

            Button("Найти на странице") {
                model?.isFindPresented = true
            }
            .keyboardShortcut("f")

            Button("Загрузки") {
                model?.toggleDownloads()
            }
            .keyboardShortcut("j", modifiers: [.command, .shift])

            Button("Показать или скрыть sidebar") {
                model?.toggleSidebarMode()
            }
            .keyboardShortcut("s", modifiers: [.command])
        }

        CommandMenu("История") {
            Button("Показать всю историю…") {
                model?.presentBrowsingHistory()
            }
            .keyboardShortcut("y")
        }

        CommandMenu("Переход") {
            Button("Назад") {
                guard let id = model?.selectedTabID else { return }
                model?.dispatch(.goBack(id))
            }
            .keyboardShortcut("[")

            Button("Вперёд") {
                guard let id = model?.selectedTabID else { return }
                model?.dispatch(.goForward(id))
            }
            .keyboardShortcut("]")

            Button("Обновить") {
                guard let id = model?.selectedTabID else { return }
                model?.dispatch(.reload(id, bypassCache: false))
            }
            .keyboardShortcut("r")

            Button("Обновить без кэша") {
                guard let id = model?.selectedTabID else { return }
                model?.dispatch(.reload(id, bypassCache: true))
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
        }
    }
}
