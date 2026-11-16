import AppKit
import Observation
import SwiftUI

@MainActor @Observable
final class EpisodeReviewPresentation {
    static let minimumContentSize = NSSize(width: 720, height: 300)
    weak var state: ShowWindowState?
    private(set) var detachedWindow: NSWindowController?
    private(set) var isClosed = false
    var isDetached: Bool { detachedWindow != nil }

    init(state: ShowWindowState) { self.state = state }

    func detach() {
        guard let state, state.selectedEpisode != nil, state.cleanupModel != nil, !isClosed else { return }
        if let existing = detachedWindow {
            existing.showWindow(nil)
            existing.window?.showWorkspaceWindow()
            return
        }
        let hosting = NSHostingController(rootView: DetachedReview(presentation: self).wwAppEnvironment())
        hosting.sizingOptions = []
        let window = EpisodeAuxiliaryWindow(contentViewController: hosting)
        window.originatingState = state
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.contentMinSize = Self.minimumContentSize
        window.setContentSize(NSSize(width: 1000, height: 500))
        window.restoreWorkspaceFrame(named: "WaveWrangler.workbench.Review")
        window.tabbingMode = .disallowed
        window.isRestorable = false
        window.setAccessibilityIdentifier("ww.review.window")
        let owner = ReviewWindowController(window: window)
        owner.presentation = self
        detachedWindow = owner
        ShowWindowRegistry.register(state, for: window)
        modelDidChange()
        owner.showWindow(nil)
        if state.bottomPaneContent == .review { state.bottomPanePresented = false }
        window.showWorkspaceWindow()
    }

    func reattach() {
        closeDetached()
        guard !isClosed, let state else { return }
        state.select(.alignment)
        state.reviewPanelPresented = true
        state.window?.makeKeyAndOrderFront(nil)
    }

    func closeDetached() {
        let owner = detachedWindow
        detachedWindow = nil
        owner?.window?.orderOut(nil)
        owner?.close()
    }

    func detachedDidClose() { detachedWindow = nil }

    func modelDidChange() {
        guard let state, let episode = state.selectedEpisode else {
            closeDetached()
            return
        }
        detachedWindow?.window?.title = "\(episode.title) - Transcript & Review"
        detachedWindow?.window?.subtitle = AppBuildIdentity.current.subtitle(context: state.store.residentModel.show.title)
    }

    func originDidClose() {
        guard !isClosed else { return }
        isClosed = true
        closeDetached()
    }
}

private struct DetachedReview: View {
    @Bindable var presentation: EpisodeReviewPresentation

    var body: some View {
        if let model = presentation.state?.cleanupModel {
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button("Reattach", systemImage: "rectangle.bottomthird.inset.filled") {
                        presentation.reattach()
                    }
                    .accessibilityIdentifier("ww.review.reattach")
                }.padding(8)
                Divider()
                FillerReviewPanel(model: model, detached: true)
            }
        } else {
            ContentUnavailableView("Review unavailable", systemImage: "text.bubble",
                description: Text("Reopen the episode workspace to review its saved transcript."))
        }
    }
}

@MainActor
private final class ReviewWindowController: NSWindowController, NSWindowDelegate {
    weak var presentation: EpisodeReviewPresentation?
    override init(window: NSWindow?) { super.init(window: window); window?.delegate = self }
    required init?(coder: NSCoder) { nil }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let minimum = sender.frameRect(forContentRect: NSRect(
            origin: .zero, size: EpisodeReviewPresentation.minimumContentSize)).size
        return NSSize(width: max(frameSize.width, minimum.width), height: max(frameSize.height, minimum.height))
    }

    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow { ShowWindowRegistry.unregister(window) }
        presentation?.detachedDidClose()
    }
}
