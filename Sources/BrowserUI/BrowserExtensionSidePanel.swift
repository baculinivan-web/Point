import BrowserCore
import BrowserEngine
import SwiftUI
import WebKit

@MainActor
struct BrowserExtensionSidePanel: Identifiable {
    let id: UUID
    let title: String
    let webView: WKWebView
    let compatibilityNotice: String?
}

struct BrowserExtensionSidePanelView: View {
    let model: BrowserWindowModel
    let panel: BrowserExtensionSidePanel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "puzzlepiece.extension")
                Text(panel.title).font(.headline).lineLimit(1)
                Spacer()
                Button {
                    panel.webView.stopLoading()
                    model.extensionSidePanel = nil
                } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .help(BrowserLocalization.string("close"))
            }
            .padding(12)
            if let notice = panel.compatibilityNotice {
                Text(notice).font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.bottom, 10)
            }
            Divider()
            WKWebViewHost(webView: panel.webView, onSwipeBack: { false }, onSwipeForward: { false })
        }
        .background(.background)
    }
}

/// Browser-owned UI, outside the store's web content and its install buttons.
struct ChromeWebStoreInstallBanner: View {
    let model: BrowserWindowModel
    @State private var dismissedID: String?
    private var manager: BrowserExtensionManager { model.extensionManager }

    var body: some View {
        Group {
            if let id = model.chromeWebStoreExtensionID, dismissedID != id {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "puzzlepiece.extension").font(.title2)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(BrowserLocalization.string("extensions_store_offer")).font(.headline)
                        if manager.storeInstallationID == id, let error = manager.errorMessage {
                            Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                        } else if manager.storeInstallationID == id, let stage = manager.storeInstallationStage {
                            Text(BrowserLocalization.string(stage.rawValue)).font(.caption)
                        } else {
                            Text(BrowserLocalization.string("extensions_store_original")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                    if manager.isBusy { ProgressView().controlSize(.small) }
                    if manager.installed.contains(where: { $0.chromeWebStoreID == id }) {
                        Label(BrowserLocalization.string("extensions_store_installed"), systemImage: "checkmark.circle")
                            .font(.callout)
                    } else {
                        Button(BrowserLocalization.string("extensions_install")) {
                            Task { await manager.installFromWebStore(id) }
                        }
                        .disabled(manager.isBusy || !manager.canModify)
                    }
                    Button { dismissedID = id } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).help(BrowserLocalization.string("close"))
                }
                .padding(14)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator.opacity(0.5)))
                .padding(14)
            }
        }
        .onChange(of: model.chromeWebStoreExtensionID) { _, _ in dismissedID = nil }
    }
}
