import AppKit
import Observation
import SwiftUI

/// Presentation ownership only; both workspaces reuse the originating editor's models.
@MainActor @Observable
final class EpisodeWorkbenchPresentation {
    weak var state: ShowWindowState?
    private var windows: [EpisodeBottomPaneContent: WorkbenchWindowController] = [:]
    private var isClosed = false

    init(state: ShowWindowState) { self.state = state }

    func isDetached(_ content: EpisodeBottomPaneContent) -> Bool { windows[content] != nil }
    func window(for content: EpisodeBottomPaneContent) -> NSWindow? { windows[content]?.window }

    func detach(_ content: EpisodeBottomPaneContent) {
        guard content == .alignment || content == .recordings,
              !isClosed, let state, state.selectedEpisodeID != nil else { return }
        if let existing = windows[content]?.window {
            existing.showWorkspaceWindow()
            return
        }
        let hosting = NSHostingController(rootView: DetachedWorkbench(state: state, content: content).wwAppEnvironment())
        hosting.sizingOptions = []
        let window = EpisodeAuxiliaryWindow(contentViewController: hosting)
        window.originatingState = state
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.contentMinSize = NSSize(width: 760, height: 440)
        window.setContentSize(NSSize(width: 1040, height: 680))
        window.tabbingMode = .disallowed
        window.isRestorable = false
        window.restoreWorkspaceFrame(named: "WaveWrangler.workbench.\(content.rawValue)")
        window.setAccessibilityIdentifier("ww.workbench.\(content == .alignment ? "alignment" : "recordings").window")
        let owner = WorkbenchWindowController(window: window)
        owner.presentation = self
        owner.content = content
        windows[content] = owner
        ShowWindowRegistry.register(state, for: window)
        modelDidChange()
        if state.bottomPaneContent == content { state.bottomPanePresented = false }
        owner.showWindow(nil)
        window.showWorkspaceWindow()
    }

    func reattach(_ content: EpisodeBottomPaneContent) {
        let owner = windows.removeValue(forKey: content)
        owner?.close()
        guard !isClosed, let state else { return }
        state.select(.alignment)
        state.bottomPaneContent = content
        state.bottomPanePresented = true
        state.window?.makeKeyAndOrderFront(nil)
    }

    func didClose(_ content: EpisodeBottomPaneContent) { windows[content] = nil }

    func modelDidChange() {
        guard let episode = state?.selectedEpisode else {
            closeWindows()
            return
        }
        for (content, owner) in windows {
            owner.window?.title = "\(episode.title) - \(content.rawValue)"
            owner.window?.subtitle = state?.store.residentModel.show.title ?? ""
        }
    }

    func originDidClose() {
        isClosed = true
        closeWindows()
    }

    private func closeWindows() {
        let owners = Array(windows.values)
        windows.removeAll()
        for owner in owners { owner.close() }
    }
}

struct EpisodeWorkbenchContent: View {
    @Bindable var state: ShowWindowState
    let content: EpisodeBottomPaneContent

    var body: some View {
        if content == .recordings, let episode = state.selectedEpisode {
            SetupContainerView(state: state, episode: episode)
        } else if content == .alignment, let model = state.alignmentModel {
            AlignmentDetailInspector(model: model)
                .disabled(TrackProcessingOperation.current(alignment: model, cleanup: state.cleanupModel) != nil)
        } else {
            ContentUnavailableView("Preparing workspace", systemImage: content.symbol,
                description: Text("The workspace uses this episode's shared editor."))
        }
    }
}

private struct DetachedWorkbench: View {
    @Bindable var state: ShowWindowState
    let content: EpisodeBottomPaneContent

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(content.rawValue).font(.headline)
                Spacer()
                Button("Bring Episode to Front") {
                    state.window?.deminiaturize(nil)
                    state.window?.makeKeyAndOrderFront(nil)
                }
                Button("Reattach", systemImage: "rectangle.bottomthird.inset.filled") {
                    state.reattachWorkspace(content)
                }
            }.padding(8)
            Divider()
            EpisodeWorkbenchContent(state: state, content: content)
        }
    }
}

@MainActor
private final class WorkbenchWindowController: NSWindowController, NSWindowDelegate {
    weak var presentation: EpisodeWorkbenchPresentation?
    var content = EpisodeBottomPaneContent.alignment
    override init(window: NSWindow?) { super.init(window: window); window?.delegate = self }
    required init?(coder: NSCoder) { nil }

    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow { ShowWindowRegistry.unregister(window) }
        presentation?.didClose(content)
    }
}
