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
            Button(BrowserLocalization.string("make_default_browser")) {
                model?.makeDefaultBrowser()
            }

            Button(BrowserLocalization.string("allow_passkeys")) {
                model?.requestPasskeyAccess()
            }

            Button(BrowserLocalization.string("site_permissions")) {
                model?.presentSitePermissions()
            }

            Button(BrowserLocalization.string("clear_browser_data")) {
                model?.presentClearBrowsingData()
            }
            .keyboardShortcut(.delete, modifiers: [.command, .shift])
        }

        CommandGroup(replacing: .newItem) {
            Button(BrowserLocalization.string("new_tab")) {
                model?.newTab()
            }
            .keyboardShortcut("t")

            Button(BrowserLocalization.string("new_window")) {
                if let model {
                    model.openWindowRequest?(false)
                } else {
                    NSApp.sendAction(
                        #selector(NSWindowController.newWindowForTab(_:)),
                        to: nil,
                        from: nil
                    )
                }
            }
            .keyboardShortcut("n")

            Button(BrowserLocalization.string("new_private_window")) {
                model?.openWindowRequest?(true)
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
        }

        CommandMenu(BrowserLocalization.string("tabs")) {
            Button(BrowserLocalization.string("close_tab")) {
                guard let id = model?.selectedTabID else { return }
                model?.closeTab(id)
            }
            .keyboardShortcut("w")

            Button(BrowserLocalization.string("reopen_closed_tab")) {
                model?.reopenClosedTab()
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])

            Button(BrowserLocalization.string("move_to_new_window")) {
                model?.transferSelectedTabsToNewWindow()
            }
            .disabled(model?.isPrivate != false || model?.selectedTabID == nil)

            Divider()

            Button(BrowserLocalization.string("address_and_search")) {
                model?.presentOmnibox()
            }
            .keyboardShortcut("l")

            Button(BrowserLocalization.string("find_on_page")) {
                model?.isFindPresented = true
            }
            .keyboardShortcut("f")

            Button(BrowserLocalization.string("downloads")) {
                model?.toggleDownloads()
            }
            .keyboardShortcut("j", modifiers: [.command, .shift])

            Button(BrowserLocalization.string("toggle_sidebar")) {
                model?.toggleSidebarMode()
            }
            .keyboardShortcut("s", modifiers: [.command])

            Divider()

            Toggle(
                BrowserLocalization.string("show_memory_usage"),
                isOn: Binding(
                    get: { model?.showsMemoryUsage ?? false },
                    set: { _ in model?.toggleMemoryUsageDisplay() }
                )
            )
            .disabled(model == nil)
        }

        CommandMenu(BrowserLocalization.string("history")) {
            Button(BrowserLocalization.string("show_full_history")) {
                model?.presentBrowsingHistory()
            }
            .keyboardShortcut("y")
        }

        CommandMenu(BrowserLocalization.string("navigation")) {
            Button(BrowserLocalization.string("back")) {
                guard let id = model?.selectedTabID else { return }
                model?.dispatch(.goBack(id))
            }
            .keyboardShortcut("[")

            Button(BrowserLocalization.string("forward")) {
                guard let id = model?.selectedTabID else { return }
                model?.dispatch(.goForward(id))
            }
            .keyboardShortcut("]")

            Button(BrowserLocalization.string("reload")) {
                guard let id = model?.selectedTabID else { return }
                model?.dispatch(.reload(id, bypassCache: false))
            }
            .keyboardShortcut("r")

            Button(BrowserLocalization.string("reload_bypass_cache")) {
                guard let id = model?.selectedTabID else { return }
                model?.dispatch(.reload(id, bypassCache: true))
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
        }
    }
}
