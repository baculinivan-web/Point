import BrowserCore
import BrowserPersistence
import Foundation
import Testing
@testable import BrowserUI

@Suite("Browser window tab navigation")
@MainActor
struct BrowserWindowNavigationTests {
    @Test
    func closingSelectedTabReturnsToMostRecentlyActiveTab() {
        let model = makeModel()
        let first = open(URL(string: "https://first.example")!, in: model)
        _ = open(URL(string: "https://second.example")!, in: model)
        let third = open(URL(string: "https://third.example")!, in: model)

        model.selectTab(first)
        model.selectTab(third)
        model.closeTab(third)

        #expect(model.selectedTabID == first)
    }

    @Test
    func selectingNestedTabExpandsItsFolderPath() {
        let model = makeModel()
        let nestedTab = open(URL(string: "https://nested.example")!, in: model)
        let otherTab = open(URL(string: "https://other.example")!, in: model)
        let parentID = model.createFolder(containing: [nestedTab])
        let childID = model.createFolder(inside: parentID, containing: [nestedTab])

        model.toggleFolder(childID)
        model.toggleFolder(parentID)
        model.selectTab(otherTab)
        model.selectTab(nestedTab)

        #expect(model.folders.first { $0.id == parentID }?.isExpanded == true)
        #expect(model.folders.first { $0.id == childID }?.isExpanded == true)
    }

    private func makeModel() -> BrowserWindowModel {
        BrowserWindowModel(
            repository: InMemorySessionRepository(),
            sitePermissionRepository: InMemorySitePermissionRepository(),
            browsingHistoryRepository: InMemoryBrowsingHistoryRepository(),
            isPrivate: true
        )
    }

    private func open(_ url: URL, in model: BrowserWindowModel) -> TabID {
        if model.selectedTabID == nil {
            model.navigate(to: url)
        } else {
            model.newTab()
            model.omniboxText = url.absoluteString
            model.submitOmnibox()
        }
        return model.selectedTabID!
    }
}
