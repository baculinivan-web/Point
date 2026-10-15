import AppKit
import BrowserCore
import Observation
import SwiftUI

@MainActor
@Observable
final class TabSwitcherState {
    private(set) var ids: [TabID] = []
    private(set) var selectedIndex = 0
    var isPresented: Bool { !ids.isEmpty }
    var selectedID: TabID? { ids.indices.contains(selectedIndex) ? ids[selectedIndex] : nil }

    func advance(in model: BrowserWindowModel, backwards: Bool = false) {
        if !isPresented {
            ids = model.tabSwitcherIDs
            guard ids.count > 1 else { cancel(); return }
            selectedIndex = ids.firstIndex { $0 == model.selectedTabID } ?? 0
        }
        selectedIndex = (selectedIndex + (backwards ? ids.count - 1 : 1)) % ids.count
    }

    func commit(in model: BrowserWindowModel) {
        let id = selectedID
        cancel()
        if let id, model.tabs.contains(where: { $0.id == id }) { model.selectTab(id) }
    }

    func cancel() {
        ids = []
        selectedIndex = 0
    }
}

struct TabSwitcherOverlay: View {
    let model: BrowserWindowModel
    let isEnabled: Bool
    @State private var state = TabSwitcherState()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if state.isPresented {
                Color.black.opacity(0.12)
                    .ignoresSafeArea()
                    .onTapGesture { state.cancel() }
                GeometryReader { geometry in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(BrowserLocalization.string("tab_switcher_title"))
                            .font(.headline)
                            .padding(.horizontal, 8)
                        ScrollViewReader { proxy in
                            ScrollView {
                                VStack(spacing: 3) {
                                    ForEach(state.ids, id: \.self) { id in
                                        if let tab = model.tabs.first(where: { $0.id == id }) {
                                            Button {
                                                state.cancel()
                                                model.selectTab(id)
                                            } label: {
                                                HStack(spacing: 10) {
                                                    TabFavicon(tab: tab, size: 28)
                                                    VStack(alignment: .leading, spacing: 3) {
                                                        Text(tab.displayTitle)
                                                            .lineLimit(1)
                                                        if let domain = tab.domain {
                                                            Text(domain)
                                                                .font(.caption)
                                                                .foregroundStyle(.secondary)
                                                                .lineLimit(1)
                                                        }
                                                    }
                                                    Spacer(minLength: 8)
                                                    if tab.isPinned {
                                                        Image(systemName: "pin.fill")
                                                            .font(.caption)
                                                            .foregroundStyle(.secondary)
                                                    }
                                                }
                                                .padding(.horizontal, 10)
                                                .frame(height: 52)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .contentShape(Rectangle())
                                                .background {
                                                    RoundedRectangle(cornerRadius: 10)
                                                        .fill(state.selectedID == id
                                                            ? Color.accentColor.opacity(0.22) : .clear)
                                                }
                                            }
                                            .buttonStyle(.plain)
                                            .accessibilityAddTraits(state.selectedID == id ? .isSelected : [])
                                            .id(id)
                                        }
                                    }
                                }
                            }
                            .frame(height: min(CGFloat(state.ids.count) * 55, max(110, geometry.size.height - 160)))
                            .onChange(of: state.selectedID, initial: true) {
                                if let id = state.selectedID { proxy.scrollTo(id) }
                            }
                        }
                        Text(BrowserLocalization.string("tab_switcher_hint"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                    }
                    .padding(14)
                    .frame(width: min(500, geometry.size.width - 40))
                    .browserGlassSurface(cornerRadius: 20)
                    .shadow(color: .black.opacity(0.2), radius: 24, y: 10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: state.isPresented)
        .background {
            TabSwitcherKeyMonitor(model: model, state: state, isEnabled: isEnabled)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .allowsHitTesting(state.isPresented)
        .onChange(of: isEnabled) { _, enabled in
            if !enabled { state.cancel() }
        }
        .onChange(of: model.selectedSpaceID) { state.cancel() }
        .onChange(of: model.tabs.map(\.id)) { state.cancel() }
    }
}

private struct TabSwitcherKeyMonitor: NSViewRepresentable {
    let model: BrowserWindowModel
    let state: TabSwitcherState
    let isEnabled: Bool

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.model = model
        view.state = state
        view.isEnabled = isEnabled
    }

    static func dismantleNSView(_ view: MonitorView, coordinator: ()) { view.stop() }

    @MainActor
    final class MonitorView: NSView {
        weak var model: BrowserWindowModel?
        var state: TabSwitcherState?
        var isEnabled = true
        private var monitor: Any?
        private var resignObserver: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard let window else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
                guard let self else { return event }
                return self.handle(event)
            }
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.state?.cancel() }
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
            monitor = nil
            resignObserver = nil
            state?.cancel()
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard let window, window.isKeyWindow, NSApp.isActive,
                  event.window == nil || event.window === window,
                  isEnabled, let state, let model else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.type == .flagsChanged {
                if state.isPresented && !flags.contains(.control) { state.commit(in: model) }
                return event
            }
            if event.keyCode == 48, flags.contains(.control),
               !flags.contains(.command), !flags.contains(.option) {
                state.advance(in: model, backwards: flags.contains(.shift))
                return nil
            }
            guard state.isPresented else { return event }
            switch event.keyCode {
            case 53: state.cancel()
            case 36, 76: state.commit(in: model)
            case 123, 126: state.advance(in: model, backwards: true)
            case 124, 125: state.advance(in: model)
            default:
                // Keep unrelated keystrokes from reaching the web page behind the menu.
                return nil
            }
            return nil
        }
    }
}
