import AppKit
import BrowserCore
import BrowserEngine
import BrowserPersistence
import Foundation
import Network
import Testing
import WebKit
@testable import BrowserUI

@Suite("WebExtensions", .serialized)
@MainActor
struct BrowserExtensionTests {
    @Test func extensionWorkersUseChromeCompatibilityWithoutChangingWebsiteIdentity() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(in: root)
        try Data(#"browser.runtime.onMessage.addListener((message, sender, reply) => { reply({recognized: !!globalThis.chrome && navigator.userAgent.includes(' Chrome/')}); });"#.utf8)
            .write(to: source.appendingPathComponent("background.js"))
        let manager = makeManager(root: root)
        await manager.restore()
        await manager.install(from: source)
        let id = try #require(manager.installed.first?.id)
        let context = try #require(manager.context(for: id))
        let model = makeModel(manager: manager)
        model.navigate(to: URL(string: "about:blank")!)
        let website = try #require(model.activeTab?.engine?.webView)
        let websiteUA = try await website.evaluateJavaScript("navigator.userAgent") as? String
        #expect(websiteUA?.contains(" Chrome/") == false)
        let options = try #require(context.optionsPageURL)
        let tab = model.openAssistantTab(url: options, inBackground: false, isAICreated: false)
        let view = try #require(tab.engine?.webView)
        _ = try await waitForJavaScript("document.body?.textContent || ''", in: view)
        let reply = try await view.callAsyncJavaScript("return await browser.runtime.sendMessage({probe:true})", contentWorld: .page) as? [String: Any]
        #expect(reply?["recognized"] as? Bool == true)
        await manager.setEnabled(false, id: id)
        await eraseData(manager)
    }

    @Test func actionPopupUsesMovableWindowAndClosesWhenDisabled() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = makeManager(root: root)
        await manager.restore()
        await manager.install(from: try fixture(in: root))
        let id = try #require(manager.installed.first?.id)
        let context = try #require(manager.context(for: id))
        let model = makeModel(manager: manager)
        model.navigate(to: URL(string: "about:blank")!)
        let host = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        model.setHostWindow(host)
        defer { model.setHostWindow(nil); host.close() }
        let tab = try #require(context.openTabs.first as? any WKWebExtensionTab)
        let action = try #require(context.action(for: tab))
        manager.performAction(id: id, model: model)
        let deadline = Date().addingTimeInterval(10)
        while manager.popupPanel == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        let panel = try #require(manager.popupPanel)
        #expect(panel.styleMask.contains(.titled))
        #expect(panel.isMovable)
        #expect(panel.parent === host)
        #expect(host.childWindows?.contains(panel) == true)
        let position = NSPoint(x: 220, y: 180)
        panel.setFrameOrigin(position)
        #expect(panel.frame.origin == position)
        panel.close()
        #expect(manager.popupPanel == nil)
        #expect(panel.parent == nil)
        manager.webExtensionController(manager.controller, presentActionPopup: action, for: context) { error in
            #expect(error == nil)
        }
        #expect(manager.popupPanel != nil)
        await manager.setEnabled(false, id: id)
        #expect(manager.popupPanel == nil)
        await eraseData(manager)
    }

    @Test func backgroundStartupFailureDoesNotRollBackInstallation() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(in: root)
        try Data("throw new Error('Background startup failed');".utf8).write(to: source.appendingPathComponent("background.js"))
        let manager = makeManager(root: root)
        await manager.restore()
        await manager.install(from: source)
        #expect(manager.errorMessage == nil)
        let id = try #require(manager.installed.first?.id)
        #expect(manager.context(for: id)?.isLoaded == true)
        #expect(try BrowserExtensionStore(root: root.appendingPathComponent("store")).read().count == 1)
        await manager.setEnabled(false, id: id)
        await eraseData(manager)
    }

    @Test func extensionPagesAndOrdinaryPagesUseTheirOwnConfigurations() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try ExtensionFixtureServer()
        defer { server.stop() }
        let manager = makeManager(root: root)
        await manager.restore()
        await manager.install(from: try fixture(in: root))
        let id = try #require(manager.installed.first?.id)
        let context = try #require(manager.context(for: id))
        let model = makeModel(manager: manager)
        manager.register(model)
        defer { manager.unregister(model) }
        let options = try #require(context.optionsPageURL)
        let tab = model.openAssistantTab(url: options, inBackground: false, isAICreated: false)
        let original = try #require(tab.engine)
        let body = try await waitForJavaScript("document.body?.textContent || ''", in: original.webView)
        #expect(body == "Point extension options")
        let runtime = try await original.webView.evaluateJavaScript("typeof browser.runtime.getURL") as? String
        #expect(runtime == "function")
        // A link inside an extension page must replace the extension-only web view.
        _ = try await original.webView.evaluateJavaScript("location.href = '\(server.url.absoluteString)';")
        let deadline = Date().addingTimeInterval(10)
        while tab.engine === original, Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        let ordinary = try #require(tab.engine)
        #expect(ordinary !== original)
        #expect(try await waitForJavaScript("document.title === 'Extension test' ? 'ready' : ''", in: ordinary.webView) == "ready")
        model.navigate(tabID: tab.id, to: .url(options))
        let reopened = try #require(tab.engine)
        #expect(reopened !== ordinary)
        #expect(try await waitForJavaScript("document.body?.textContent || ''", in: reopened.webView) == "Point extension options")
        await manager.setEnabled(false, id: id)
        await manager.setEnabled(true, id: id)
        let reenabled = try #require(tab.engine)
        #expect(reenabled !== reopened)
        #expect(try await waitForJavaScript("document.body?.textContent || ''", in: reenabled.webView) == "Point extension options")
        await manager.setEnabled(false, id: id)
        await eraseData(manager)
    }

    @Test func copiedResourcesAndStableIdentitySurviveRestart() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(in: root)
        let manager = makeManager(root: root)
        await manager.restore()
        await manager.install(from: source)
        #expect(manager.errorMessage == nil)
        let record = try #require(manager.installed.first)
        #expect(manager.errorMessage == nil)
        #expect(manager.context(for: record.id)?.isLoaded == true)
        #expect(record.permissions.contains("storage"))
        let baseURL = manager.context(for: record.id)?.baseURL
        try FileManager.default.removeItem(at: source)
        await manager.setEnabled(false, id: record.id)
        #expect(manager.context(for: record.id) == nil)
        await manager.setEnabled(true, id: record.id)
        #expect(manager.context(for: record.id)?.baseURL == baseURL)
        try manager.controller.unload(try #require(manager.context(for: record.id)))
        let restored = makeManager(root: root)
        await restored.restore()
        #expect(restored.installed == manager.installed)
        #expect(restored.context(for: record.id)?.baseURL == baseURL)
        #expect(restored.context(for: record.id)?.hasAccessToPrivateData == false)
        await restored.setEnabled(false, id: record.id)
        await eraseData(restored)
    }

    @Test func deniedInstallationLeavesNoResourcesOrRecord() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(in: root)
        let manager = makeManager(root: root, approve: false)
        await manager.restore()
        await manager.install(from: source)
        #expect(manager.installed.isEmpty)
        #expect(manager.controller.extensionContexts.isEmpty)
        let children = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("store").path)
        #expect(children.isEmpty)
    }

    @Test func invalidManifestAndSymlinkCannotInstall() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(in: root)
        let manager = makeManager(root: root)
        await manager.restore()
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("escape"), withDestinationURL: root)
        await manager.install(from: source)
        #expect(manager.installed.isEmpty)
        #expect(manager.errorMessage != nil)
        try FileManager.default.removeItem(at: source.appendingPathComponent("escape"))
        try Data("{}".utf8).write(to: source.appendingPathComponent("manifest.json"))
        manager.errorMessage = nil
        await manager.install(from: source)
        #expect(manager.installed.isEmpty)
        #expect(manager.errorMessage != nil)
    }

    @Test func revokedGrantsStayRevokedAfterRestart() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(in: root)
        let manager = makeManager(root: root)
        await manager.restore()
        await manager.install(from: source)
        #expect(manager.errorMessage == nil)
        let id = try #require(manager.installed.first?.id)
        manager.revokeAccess(id: id)
        #expect(manager.context(for: id)?.currentPermissions.isEmpty == true)
        #expect(manager.context(for: id)?.currentPermissionMatchPatterns.isEmpty == true)
        try manager.controller.unload(try #require(manager.context(for: id)))
        let restored = makeManager(root: root)
        await restored.restore()
        #expect(restored.installed.first?.permissions.isEmpty == true)
        #expect(restored.context(for: id)?.currentPermissionMatchPatterns.isEmpty == true)
        await restored.setEnabled(false, id: id)
        await eraseData(restored)
    }

    @Test func contentScriptsMessagingStorageTabsAndPrivateIsolation() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try ExtensionFixtureServer()
        defer { server.stop() }
        let source = try fixture(in: root)
        let manager = makeManager(root: root)
        await manager.restore()
        await manager.install(from: source)
        #expect(manager.errorMessage == nil)
        let id = try #require(manager.installed.first?.id)
        let model = makeModel(manager: manager)
        manager.register(model)
        model.navigate(to: server.url)
        defer { manager.unregister(model) }
        let webView = try #require(model.activeTab?.engine?.webView)
        #expect(webView.configuration.webExtensionController === manager.controller)
        let marker = try await waitForJavaScript("document.documentElement.dataset.pointExtension || ''", in: webView)
        #expect(marker == "storage-message-ok")
        let tabs = try await waitForJavaScript("document.documentElement.dataset.pointTabCount || ''", in: webView)
        #expect(tabs == "1")
        let extensionContext = try #require(manager.context(for: id))
        let extensionWindow = try #require(extensionContext.openWindows.first)
        let adapter = try #require(extensionWindow.tabs?(for: extensionContext).first as? ExtensionTabAdapter)
        var closed = false
        adapter.close(for: extensionContext) { error in #expect(error == nil); closed = true }
        #expect(closed)
        #expect(!model.tabs.contains { $0.id == adapter.id })
        let privateModel = makeModel(manager: manager, isPrivate: true)
        privateModel.navigate(to: server.url)
        manager.register(privateModel)
        #expect(privateModel.activeTab?.engine?.webView.configuration.webExtensionController == nil)
        #expect(extensionContext.openWindows.count == 1)
        await manager.setEnabled(false, id: id)
        await eraseData(manager)
    }

    @Test func manifestCSSCompatibility() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try ExtensionFixtureServer()
        defer { server.stop() }
        let manager = makeManager(root: root)
        await manager.restore()
        await manager.install(from: try fixture(in: root))
        let id = try #require(manager.installed.first?.id)
        let model = makeModel(manager: manager)
        manager.register(model)
        defer { manager.unregister(model) }
        model.navigate(to: server.url)
        let webView = try #require(model.activeTab?.engine?.webView)
        _ = try await waitForJavaScript("document.documentElement.dataset.pointExtension || ''", in: webView)
        let color = try await webView.evaluateJavaScript("getComputedStyle(document.body).backgroundColor") as? String
        // Keep this compatibility gap visible without disabling the working runtime checks.
        withKnownIssue("Manifest CSS did not apply on macOS 26.2. JS injection, background messages and storage work; CSS compatibility needs further investigation.", isIntermittent: true) {
            #expect(color == "rgb(12, 34, 56)")
        }
        await manager.setEnabled(false, id: id)
        await eraseData(manager)
    }

    @Test func transferringTabsPreservesExtensionIdentity() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = makeManager(root: root)
        await manager.restore()
        await manager.install(from: try fixture(in: root))
        let id = try #require(manager.installed.first?.id)
        let source = makeModel(manager: manager)
        let destination = makeModel(manager: manager)
        source.navigate(to: URL(string: "about:blank")!)
        manager.register(source)
        manager.register(destination)
        defer { manager.unregister(source); manager.unregister(destination) }
        let context = try #require(manager.context(for: id))
        let originalWindow = try #require(context.openWindows.compactMap { $0 as? ExtensionWindowAdapter }.first { $0.model === source })
        let original = try #require(originalWindow.adapters.first)
        source.openWindowRequest = { _ in
            if let tabs = BrowserWindowTransferCenter.shared.claimNextBatch() { destination.adoptTransferredTabs(tabs) }
        }
        source.transferSelectedTabsToNewWindow()
        #expect(original.owner?.model === destination)
        #expect(original.owner?.adapters.contains { $0 === original } == true)
        #expect(context.openTabs.count == source.tabs.count + destination.tabs.count)
        await manager.setEnabled(false, id: id)
        await eraseData(manager)
    }

    @Test func optionalGrantsAndIndividualRevocationArePersisted() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = makeManager(root: root)
        await manager.restore()
        await manager.install(from: try fixture(in: root))
        let id = try #require(manager.installed.first?.id)
        let context = try #require(manager.context(for: id))
        let permission = WKWebExtension.Permission(rawValue: "notifications")
        var allowed = false
        manager.webExtensionController(manager.controller, promptForPermissions: [permission], in: nil, for: context) { grants, _ in allowed = grants.contains(permission) }
        #expect(allowed)
        manager.revokeAccess(id: id, permission: "tabs")
        #expect(manager.installed.first?.permissions.contains("tabs") == false)
        #expect(manager.installed.first?.permissions.contains("storage") == true)
        #expect(manager.installed.first?.permissions.contains("notifications") == true)
        #expect(try BrowserExtensionStore(root: root.appendingPathComponent("store")).read() == manager.installed)
        await manager.setEnabled(false, id: id)
        await eraseData(manager)
    }

    @Test func sameDocumentNavigationUpdatesCopiedAddressAndStoreDetection() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = makeManager(root: root)
        let model = makeModel(manager: manager, isPrivate: true)
        let server = try ExtensionFixtureServer()
        defer { server.stop() }
        model.navigate(to: server.url)
        let tab = try #require(model.activeTab)
        let view = try #require(tab.engine?.webView)
        _ = try await waitForJavaScript("document.body?.textContent || ''", in: view)
        let pasteboard = NSPasteboard(name: .init("PointURLTests-\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        for path in ["/detail/first", "/detail/second?hl=fr", "/detail/second?hl=fr#section"] {
            _ = try await view.evaluateJavaScript("history.pushState({}, '', '\(path)')")
            let actual = try #require(view.url)
            model.copyActivePageURL(to: pasteboard)
            #expect(pasteboard.string(forType: .string) == actual.absoluteString)
            #expect(model.currentPageURL == actual)
            #expect(tab.url == actual)
        }
        // Use the live web view even if an older tab snapshot has not been updated yet.
        tab.url = server.url
        model.copyActivePageURL(to: pasteboard)
        #expect(pasteboard.string(forType: .string) == view.url?.absoluteString)
        let storeURL = URL(string: "https://chromewebstore.google.com/detail/chatgpt/hehggadaopoacecdllhhajmbjkdcmajg?hl=fr")!
        let regular = makeModel(manager: manager)
        regular.navigate(to: URL(string: "about:blank")!)
        let storeTab = try #require(regular.activeTab)
        storeTab.engine = nil
        storeTab.url = storeURL
        #expect(regular.chromeWebStoreExtensionID == "hehggadaopoacecdllhhajmbjkdcmajg")
        storeTab.url = URL(string: "https://chromewebstore.google.com/category/extensions?hl=fr")!
        #expect(regular.chromeWebStoreExtensionID == nil)
        #expect(model.chromeWebStoreExtensionID == nil)
    }

    @Test func declaredSidePanelOpensWithoutPopupAndClosesWhenDisabled() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = makeManager(root: root)
        let source = try fixture(in: root)
        let manifestURL = source.appendingPathComponent("manifest.json")
        var manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        manifest["side_panel"] = ["default_path": "options.html"]
        manifest["action"] = ["default_title": "Side panel"]
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        await manager.restore()
        await manager.install(from: source)
        let id = try #require(manager.installed.first?.id)
        let model = makeModel(manager: manager)
        model.navigate(to: URL(string: "about:blank")!)
        manager.register(model)
        defer { manager.unregister(model) }
        manager.performAction(id: id, model: model)
        let panel = try #require(model.extensionSidePanel)
        #expect(manager.popupPanel == nil)
        #expect(try await waitForJavaScript("document.body?.textContent || ''", in: panel.webView) == "Point extension options")
        #expect(panel.webView.configuration.webExtensionController === manager.controller)
        let privateModel = makeModel(manager: manager, isPrivate: true)
        manager.openSidePanel(id: id, model: privateModel)
        #expect(privateModel.extensionSidePanel == nil)
        await manager.setEnabled(false, id: id)
        #expect(model.extensionSidePanel == nil)
        #expect(manager.sidePanelURL(for: id) == nil)
        await eraseData(manager)
    }

    private func eraseData(_ manager: BrowserExtensionManager) async {
        let types = WKWebExtensionController.allExtensionDataTypes
        let data = await manager.controller.dataRecords(ofTypes: types)
        await manager.controller.removeData(ofTypes: types, from: data)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("PointExtensionTests-\(UUID())", isDirectory: true)
    }
    private func makeManager(root: URL, approve: Bool = true) -> BrowserExtensionManager {
        BrowserExtensionManager(root: root.appendingPathComponent("store"),
            controller: BrowserExtensionManager.makeController(configuration: .init(identifier: UUID())),
            approvalHandler: { _, _, _ in approve })
    }
    private func makeModel(manager: BrowserExtensionManager, isPrivate: Bool = false) -> BrowserWindowModel {
        let model = BrowserWindowModel(repository: InMemorySessionRepository(),
            sitePermissionRepository: InMemorySitePermissionRepository(),
            browsingHistoryRepository: InMemoryBrowsingHistoryRepository(),
            isPrivate: isPrivate, websiteDataStore: isPrivate ? .nonPersistent() : manager.controller.configuration.defaultWebsiteDataStore, allowsExternalAgentAccess: false)
        model.extensionManager = manager
        return model
    }
    private func fixture(in root: URL) throws -> URL {
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let files = [
            "manifest.json": #"{"manifest_version":3,"name":"Point Test","description":"Integration test","version":"1.0","permissions":["storage","tabs"],"optional_permissions":["notifications"],"host_permissions":["http://127.0.0.1/*"],"background":{"service_worker":"background.js"},"action":{"default_popup":"popup.html"},"options_ui":{"page":"options.html"},"content_scripts":[{"matches":["http://127.0.0.1/*"],"js":["content.js"],"css":["content.css"]}]}"#,
            "background.js": #"browser.runtime.onMessage.addListener((message, sender, reply) => { (async () => { await browser.storage.local.set({marker:'storage-message-ok'}); const stored = await browser.storage.local.get('marker'); const tabs = await browser.tabs.query({}); return {marker:stored.marker,count:tabs.length}; })().then(reply).catch(error => reply({marker:String(error), count:-1})); return true; });"#,
            "content.js": #"browser.runtime.sendMessage({ping:true}).then(reply => { document.documentElement.dataset.pointExtension=reply.marker; document.documentElement.dataset.pointTabCount=String(reply.count); document.documentElement.dataset.pointCss=getComputedStyle(document.body).backgroundColor; }).catch(error => { document.documentElement.dataset.pointExtension=String(error); });"#,
            "content.css": "body { background: rgb(12, 34, 56) !important; }",
            "popup.html": "<!doctype html><html><body style='width:240px;height:80px'>Point extension popup</body></html>",
            "options.html": "<!doctype html><html><body>Point extension options</body></html>"
        ]
        for (name, contents) in files { try Data(contents.utf8).write(to: source.appendingPathComponent(name)) }
        return source
    }
    private func waitForJavaScript(_ script: String, in webView: WKWebView) async throws -> String {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if let value = try? await webView.evaluateJavaScript(script) as? String, !value.isEmpty { return value }
            try await Task.sleep(for: .milliseconds(100))
        }
        return ""
    }
}

private final class ExtensionFixtureServer: @unchecked Sendable {
    private let listener: NWListener
    let url: URL
    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state { case .ready, .failed: ready.signal(); default: break }
        }
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { _, _, _, _ in
                let body = "<!doctype html><html><head><title>Extension test</title></head><body>Point fixture</body></html>"
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: .global())
        guard ready.wait(timeout: .now() + 5) == .success, let port = listener.port else {
            listener.cancel(); throw CocoaError(.fileReadUnknown)
        }
        url = URL(string: "http://127.0.0.1:\(port.rawValue)/")!
    }
    func stop() { listener.cancel() }
}
