import BrowserCore
import BrowserPersistence
import Foundation
import Testing
@testable import BrowserUI

@Suite("Ctrl Tab switcher")
@MainActor
struct TabSwitcherTests {
    @Test
    func previewKeepsSelectionAndOrderUntilCommit() {
        let model = makeModel()
        let first = open("https://first.example", in: model)
        let second = open("https://second.example", in: model)
        let third = open("https://third.example", in: model)
        model.selectTab(first)
        let state = TabSwitcherState()
        state.advance(in: model)
        #expect(state.ids == [first, third, second])
        #expect(state.selectedID == third)
        #expect(model.selectedTabID == first)
        state.advance(in: model)
        #expect(state.selectedID == second)
        #expect(model.tabSwitcherIDs == [first, third, second])
        state.commit(in: model)
        #expect(model.selectedTabID == second)
        #expect(!state.isPresented)
        #expect(model.tabSwitcherIDs.first == second)
    }

    @Test
    func reverseWrapsAndCancelDoesNotSelect() {
        let model = makeModel()
        let first = open("https://first.example", in: model)
        let second = open("https://second.example", in: model)
        let state = TabSwitcherState()
        state.advance(in: model, backwards: true)
        #expect(state.selectedID == first)
        state.advance(in: model, backwards: true)
        #expect(state.selectedID == second)
        state.cancel()
        #expect(model.selectedTabID == second)
        #expect(!state.isPresented)
    }

    @Test
    func includesCollapsedFolderAndPinnedTabsButNotOtherSpaces() {
        let model = makeModel()
        let nested = open("https://nested.example", in: model)
        let folder = model.createFolder(containing: [nested])
        model.toggleFolder(folder)
        let pinned = open("https://pinned.example", in: model)
        model.tabs.first { $0.id == pinned }?.isPinned = true
        let originalSpace = model.selectedSpaceID
        let otherSpace = model.createSpace()
        model.selectSpace(otherSpace)
        let other = open("https://other.example", in: model)
        model.selectSpace(originalSpace)
        let state = TabSwitcherState()
        state.advance(in: model)
        #expect(Set(state.ids) == Set([nested, pinned]))
        #expect(!state.ids.contains(other))
        state.commit(in: model)
        #expect(model.selectedTabID == nested)
        #expect(model.folders.first { $0.id == folder }?.isExpanded == true)
    }

    @Test
    func singleTabDoesNotPresentAndClosedCandidateCannotBeSelected() {
        let model = makeModel()
        let first = open("https://first.example", in: model)
        let state = TabSwitcherState()
        state.advance(in: model)
        #expect(!state.isPresented)
        _ = open("https://second.example", in: model)
        state.advance(in: model)
        #expect(state.selectedID == first)
        model.closeTab(first)
        let selected = model.selectedTabID
        state.commit(in: model)
        #expect(model.selectedTabID == selected)
        #expect(!state.isPresented)
    }

    private func makeModel() -> BrowserWindowModel {
        BrowserWindowModel(
            repository: InMemorySessionRepository(),
            sitePermissionRepository: InMemorySitePermissionRepository(),
            browsingHistoryRepository: InMemoryBrowsingHistoryRepository(),
            isPrivate: true
        )
    }

    private func open(_ url: String, in model: BrowserWindowModel) -> TabID {
        if model.selectedTabID == nil {
            model.navigate(to: URL(string: url)!)
        } else {
            model.newTab()
            model.omniboxText = url
            model.submitOmnibox()
        }
        return model.selectedTabID!
    }
}
