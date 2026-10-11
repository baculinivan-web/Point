import BrowserCore
import SwiftUI

struct BrowserExtensionsSettingsView: View {
    let model: BrowserWindowModel
    private var manager: BrowserExtensionManager { model.extensionManager }

    @State private var storeLink = ""

    var body: some View {
        Form {
            Section {
                Text(BrowserLocalization.string("extensions_description"))
                    .font(.callout).foregroundStyle(.secondary)
                TextField(BrowserLocalization.string("extensions_store_link"), text: $storeLink)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { installStoreLink() }
                    .disabled(manager.isBusy || !manager.canModify || model.isPrivate)
                HStack {
                    Button(BrowserLocalization.string("extensions_store_install"), systemImage: "arrow.down.circle") {
                        installStoreLink()
                    }
                    .disabled(storeLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button(BrowserLocalization.string("extensions_store_browse")) {
                        model.openAssistantTab(url: URL(string: "https://chromewebstore.google.com/category/extensions")!,
                                               inBackground: false, isAICreated: false)
                    }
                }
                .disabled(manager.isBusy || !manager.canModify || model.isPrivate)
                Text(BrowserLocalization.string("extensions_store_original"))
                    .font(.caption).foregroundStyle(.secondary)
                Button(BrowserLocalization.string("extensions_install_folder"), systemImage: "folder.badge.plus") {
                    manager.chooseAndInstall()
                }
                .disabled(manager.isBusy || !manager.canModify || model.isPrivate)
                if let stage = manager.storeInstallationStage {
                    HStack {
                        if manager.isBusy { ProgressView().controlSize(.small) }
                        Text(BrowserLocalization.string(stage.rawValue)).font(.callout)
                    }
                } else if manager.isBusy { ProgressView().controlSize(.small) }
                if model.isPrivate {
                    Text(BrowserLocalization.string("extensions_private_disabled"))
                        .foregroundStyle(.secondary)
                }
                if let error = manager.errorMessage {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                    Button(BrowserLocalization.string("close")) { manager.errorMessage = nil }
                }
            }
            if manager.installed.isEmpty && !manager.isBusy {
                Section { Text(BrowserLocalization.string("extensions_empty")).foregroundStyle(.secondary) }
            }
            ForEach(manager.installed) { record in
                Section {
                    Toggle(isOn: Binding(get: { record.isEnabled }, set: { enabled in
                        Task { await manager.setEnabled(enabled, id: record.id) }
                    })) {
                        HStack {
                            if let image = manager.context(for: record.id)?.webExtension.icon(for: CGSize(width: 28, height: 28)) {
                                Image(nsImage: image).resizable().frame(width: 28, height: 28)
                            } else { Image(systemName: "puzzlepiece.extension").frame(width: 28, height: 28) }
                            VStack(alignment: .leading) {
                                Text(record.name).fontWeight(.medium)
                                Text(record.version).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(manager.isBusy || !manager.canModify || model.isPrivate)
                    if let notice = manager.compatibilityNotice(for: record.id) {
                        Text(notice).font(.caption).foregroundStyle(.secondary)
                    }
                    if let error = manager.diagnostics(for: record.id) {
                        Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    }
                    DisclosureGroup(BrowserLocalization.string("extensions_permissions")) {
                        let grants = record.permissions + record.sites
                        if grants.isEmpty { Text(BrowserLocalization.string("extensions_no_permissions")) }
                        ForEach(record.permissions, id: \.self) { permission in
                            permissionRow(permission) { manager.revokeAccess(id: record.id, permission: permission) }
                        }
                        ForEach(record.sites, id: \.self) { site in
                            permissionRow(site) { manager.revokeAccess(id: record.id, site: site) }
                        }
                        HStack {
                            Button(BrowserLocalization.string("extensions_review_access")) { manager.reviewAccess(id: record.id) }
                                .disabled(!record.isEnabled)
                            Button(BrowserLocalization.string("extensions_revoke_access")) { manager.revokeAccess(id: record.id) }
                                .disabled(grants.isEmpty)
                        }
                        .disabled(manager.isBusy || !manager.canModify || model.isPrivate)
                    }
                    HStack {
                        if manager.sidePanelURL(for: record.id) != nil {
                            Button(BrowserLocalization.string("extensions_open_side_panel")) {
                                manager.openSidePanel(id: record.id, model: model)
                            }
                        }
                        if manager.context(for: record.id)?.optionsPageURL != nil {
                            Button(BrowserLocalization.string("extensions_options")) { manager.openOptions(id: record.id, model: model) }
                        }
                        Spacer()
                        Button(BrowserLocalization.string("extensions_remove"), role: .destructive) { manager.remove(id: record.id) }
                    }
                    .disabled(manager.isBusy || !manager.canModify || model.isPrivate)
                }
            }
            Section {
                Text(BrowserLocalization.string("extensions_compatibility"))
                    .font(.caption).foregroundStyle(.secondary)
                Text(BrowserLocalization.string("extensions_css_limitation"))
                    .font(.caption).foregroundStyle(.secondary)
                Text(BrowserLocalization.string("extensions_reload_hint"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            if let url = model.currentPageURL, (try? ChromeWebStoreInstaller.extensionID(from: url.absoluteString)) != nil {
                storeLink = url.absoluteString
            }
            await manager.restore()
        }
    }

    private func installStoreLink() {
        guard !manager.isBusy, manager.canModify, !model.isPrivate else { return }
        Task { await manager.installFromWebStore(storeLink) }
    }

    private func permissionRow(_ value: String, revoke: @escaping () -> Void) -> some View {
        HStack {
            Text(value).font(.caption).textSelection(.enabled)
            Spacer()
            Button(action: revoke) { Image(systemName: "minus.circle") }
                .help(BrowserLocalization.string("extensions_revoke_access"))
                .accessibilityLabel(BrowserLocalization.string("extensions_revoke_access") + ": " + value)
                .disabled(manager.isBusy || !manager.canModify || model.isPrivate)
        }
    }
}

struct BrowserExtensionsMenu: View {
    let model: BrowserWindowModel
    private var manager: BrowserExtensionManager { model.extensionManager }

    var body: some View {
        Menu {
            if model.isPrivate {
                Text(BrowserLocalization.string("extensions_private_disabled"))
            } else {
                // Observe action updates even when the installed list hasn't changed.
                let _ = manager.actionRevision
                ForEach(manager.installed.filter(\.isEnabled)) { record in
                    let action = manager.action(for: record.id, model: model)
                    Button {
                        manager.performAction(id: record.id, model: model)
                    } label: {
                        let badge = action?.badgeText ?? ""
                        let title = action?.label.isEmpty == false ? action!.label : record.name
                        if let icon = action?.icon(for: CGSize(width: 20, height: 20)) {
                            Label { Text(badge.isEmpty ? title : "\(title) · \(badge)") } icon: { Image(nsImage: icon) }
                        } else { Text(badge.isEmpty ? title : "\(title) · \(badge)") }
                    }
                    .disabled(action?.isEnabled != true || model.activeTab == nil)
                }
                if manager.installed.filter(\.isEnabled).isEmpty {
                    Text(BrowserLocalization.string("extensions_empty"))
                }
            }
            Divider()
            Button(BrowserLocalization.string("extensions_manage")) { model.presentedSettingsSection = .extensions }
        } label: {
            Image(systemName: "puzzlepiece.extension").frame(width: 24, height: 24)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(BrowserLocalization.string("settings_section_extensions"))
        .accessibilityLabel(BrowserLocalization.string("settings_section_extensions"))
    }
}
