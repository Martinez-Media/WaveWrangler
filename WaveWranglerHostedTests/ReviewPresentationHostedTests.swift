import AppKit
import Foundation
import Testing
import WWCore
import WWOrganizer
import WWPersistence
@testable import WaveWrangler

@MainActor
@Suite("Episode-owned detachable transcript review", .serialized)
struct ReviewPresentationHostedTests {
    @Test func schema14ShowStaysReadOnlyUntilExplicitVerifiedUpdate() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "WWFillerMigration-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Previous.wwshow")
        let showID = ShowID()
        // Independent previous-schema bytes, never encoded by the current model/coder.
        let catalog = Data("""
        {"history":{"cursor":0,"entries":[]},"schemaVersion":14,"show":{"id":"\(showID)","notes":"Original notes","title":"Previous show"},"speakers":[]}
        """.utf8)
        let digest = RevisionFingerprint.digest(catalog)
        let index: [String: Any] = [
            "catalog": ["digest": digest, "byteCount": catalog.count, "encoding": "raw"], "episodes": [],
        ]
        let indexBytes = try JSONSerialization.data(withJSONObject: index, options: [.sortedKeys, .withoutEscapingSlashes])
        let manifest: [String: Any] = [
            "format": "com.brandonmartinez.wavewrangler.show-package", "schemaVersion": 2, "modelSchemaVersion": 14,
            "revision": 7, "publicationID": UUID().uuidString, "index": index,
            "checksum": "sha256:" + RevisionFingerprint.digest(Data("WWShowCatalog2\0".utf8) + indexBytes),
        ]
        let wrapper = FileWrapper(directoryWithFileWrappers: [
            "Manifest.json": FileWrapper(regularFileWithContents: try JSONSerialization.data(withJSONObject: manifest, options: .sortedKeys)),
            "Components": FileWrapper(directoryWithFileWrappers: [digest: FileWrapper(regularFileWithContents: catalog)]),
        ])
        try wrapper.write(to: url, options: .atomic, originalContentsURL: nil)
        let original = try LocalFileOperations().read(url)
        let document = try #require(NSDocumentController.shared.makeDocument(withContentsOf: url, ofType: DocumentTypes.show) as? ShowDocument)
        defer { document.close() }
        let awaiting = document.isAwaitingFormatUpdate
        let editableBefore = document.store.canEdit
        #expect(awaiting && !editableBefore)
        #expect(try LocalFileOperations().read(url) == original)
        document.updateFormat()
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while document.isAwaitingFormatUpdate, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let editableAfter = document.store.canEdit && !document.isAwaitingFormatUpdate
        try #require(editableAfter)
        let decoded = try ShowPackageCoder().decode(LocalFileOperations().read(url))
        #expect(decoded.payload.schemaVersion == 15 && decoded.payload.show.notes == "Original notes")
        #expect(decoded.payload.show.fillerWords == nil && decoded.revision == 8)
        let backups = try PersistenceEnvironment.recovery.migrationBackups(for: .show(showID))
        #expect(try backups.contains { try Data(contentsOf: $0) == original })
        let reopened = try #require(NSDocumentController.shared.makeDocument(withContentsOf: url, ofType: DocumentTypes.show) as? ShowDocument)
        defer { reopened.close() }
        let reopenedEditable = reopened.store.canEdit && !reopened.isAwaitingFormatUpdate
        #expect(reopenedEditable)
    }

    @Test func fillerWordOverridesAreSharedUndoableAndPersistWithoutChangingReviews() async throws {
        let restoreDefaults = useDefaultFillerWords()
        defer { restoreDefaults() }
        let (f, cleanup, state) = try await ReviewPanelHostedTests().fixture()
        defer { cleanup.cancel(); f.close() }
        let store = f.document.store
        let before = store.residentModel
        let review = try #require(cleanup.fillerReviews.first)
        let words = try FillerWords(["well"])
        let other = ShowWindowState(store: store, episodeID: cleanup.episodeID)
        let undo = try #require(f.document.undoManager)
        while undo.groupingLevel > 0 { undo.endUndoGrouping() }
        undo.removeAllActions()
        undo.groupsByEvent = false
        defer { undo.groupsByEvent = true }
        undo.beginUndoGrouping()
        let applied = store.apply("Change Show Filler Words") { model throws(DomainError) in
            try model.settingFillerWords(words)
        }
        undo.endUndoGrouping()
        #expect(applied)
        let sharedWords = other.store.residentModel.show.fillerWords
        let originalReviews = cleanup.fillerReviews == before.episode(cleanup.episodeID)?.cleanup?.fillerReviews
        #expect(sharedWords == words && originalReviews)
        undo.undo()
        let restored = state.store.residentModel == before
        #expect(restored)
        undo.redo()
        let restoredWords = store.residentModel.show.fillerWords
        #expect(restoredWords == words)
        let disabled = try FillerWords([])
        let speakerApplied = store.apply("Change Speaker Filler Words") { model throws(DomainError) in
            try model.settingFillerWords(disabled, for: review.speaker)
        }
        #expect(speakerApplied)
        let configured = try cleanup.configuredFillerWords(in: store.residentModel, speakers: [review.speaker])
        #expect(configured[review.speaker] == disabled)
        let expected = store.residentModel
        try await f.document.save(to: #require(f.document.fileURL), ofType: DocumentTypes.show, for: .saveOperation)
        let reopened = try WWPersistence.ShowPackageCoder().decode(WWPersistence.LocalFileOperations().read(#require(f.document.fileURL)))
        let persisted = reopened.payload == expected
        #expect(persisted)
    }

    @Test func fillerRescanUsesSpeakerRulesAndRejectsLatePublicationAfterRuleEdits() async throws {
        let restoreDefaults = useDefaultFillerWords()
        defer { restoreDefaults() }
        let (f, cleanup, _) = try await ReviewPanelHostedTests().fixture()
        defer { cleanup.cancel(); f.close() }
        let store = f.document.store
        let before = store.residentModel
        let transcripts = try #require(before.episode(cleanup.episodeID)?.cleanup?.transcripts)
        let speaker = try #require(transcripts.first?.speaker)
        let words = try FillerWords(["uh"])
        let applied = store.apply("Change Speaker Filler Words") { model throws(DomainError) in
            try model.settingFillerWords(words, for: speaker)
        }
        #expect(applied)
        let current = store.residentModel
        let refused = try !cleanup.publishTranscripts(transcripts, expecting: before)
        #expect(refused)
        cleanup.proposeFillers()
        let reviews = cleanup.fillerReviews
        #expect(reviews.count == 1 && reviews.first?.word?.text == "uh" && reviews.first?.detectorWords == words)
        let rawUnchanged = store.residentModel.episode(cleanup.episodeID)?.cleanup?.transcripts
            == current.episode(cleanup.episodeID)?.cleanup?.transcripts
        #expect(rawUnchanged)
        let scanned = store.residentModel
        cleanup.proposeFillers()
        let idempotent = store.residentModel == scanned
        #expect(idempotent)
    }

    private func useDefaultFillerWords() -> @MainActor () -> Void {
        let defaults = UserDefaults.standard
        let stored = defaults.object(forKey: PreferenceKey.fillerWords)
        AppSettings.shared.setFillerWords(.defaults)
        return {
            if let stored { defaults.set(stored, forKey: PreferenceKey.fillerWords) }
            else { defaults.removeObject(forKey: PreferenceKey.fillerWords) }
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        }
    }

    private func settle() async throws { try await Task.sleep(for: .milliseconds(150)) }

    private func capture(_ window: NSWindow, name: String) throws {
        let view = try #require(window.contentView)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        Attachment.record(data, named: "\(name).png")
    }

    @Test func settingsCategoriesFitNativeWindowAndKeepNumericFieldsReachable() async throws {
        defer { NSApp.windows.first { $0.accessibilityIdentifier() == "ww.settings.window" }?.close() }
        for pane in SettingsPane.allCases {
            SettingsWindowController.show(pane: pane)
            let window = try #require(NSApp.windows.first { $0.accessibilityIdentifier() == "ww.settings.window" })
            try await settle()
            #expect(window.isVisible && window.title == pane.title)
            let content = try #require(window.contentView)
            #expect(content.bounds.width >= 600 && content.bounds.height > 100)
            func editableFields(in view: NSView) -> [NSTextField] {
                if let field = view as? NSTextField, field.isEditable { return [field] }
                return view.subviews.flatMap { editableFields(in: $0) }
            }
            for field in editableFields(in: content) where !field.isHidden {
                let rect = field.convert(field.bounds, to: content)
                let contained = content.bounds.insetBy(dx: -1, dy: -1).contains(rect)
                #expect(contained, "Settings numeric fields must remain reachable in the native content area.")
            }
            try capture(window, name: "Settings - \(pane.title)")
        }
    }

    @Test func recordingsWorkbenchReusesItsSetupControllerAcrossWindows() async throws {
        let (f, cleanup, state) = try await ReviewPanelHostedTests().fixture()
        defer { cleanup.cancel(); f.close() }
        let owner = EpisodeWindowController(state: state)
        f.document.addWindowController(owner)
        owner.showWindow(nil)
        state.inspectorPresented = false
        state.openWorkspace(.recordings, separateWindow: false)
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while state.setupController == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let controller = try #require(state.setupController)
        let before = f.document.store.residentModel
        state.detachWorkspace(.recordings)
        let window = try #require(state.workbenchPresentation.window(for: .recordings))
        let attachedDeadline = ContinuousClock.now.advanced(by: .seconds(8))
        while controller.window !== window, ContinuousClock.now < attachedDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let shared = state.setupController === controller && controller.window === window
        #expect(shared)
        #expect(window.undoManager === f.document.undoManager && window.isVisible)
        try await settle()
        try capture(window, name: "Detached Recordings and Speakers")
        state.reattachWorkspace(.recordings)
        try await settle()
        let reattached = state.setupController === controller && controller.window === owner.window
        let unchanged = f.document.store.residentModel == before
        #expect(reattached && unchanged)
        #expect(state.bottomPaneContent == .recordings && state.bottomPanePresented && !window.isVisible)
        owner.close()
    }

    @Test func alignmentWorkbenchUsesOneRuntimeAndReattachesWithoutDocumentEdits() async throws {
        let (f, cleanup, state) = try await ReviewPanelHostedTests().fixture()
        defer { cleanup.cancel(); f.close() }
        let owner = EpisodeWindowController(state: state)
        f.document.addWindowController(owner)
        owner.showWindow(nil)
        try await settle()
        let before = f.document.store.residentModel
        state.openWorkspace(.alignment, separateWindow: false)
        #expect(state.bottomPaneContent == .alignment && state.bottomPanePresented)
        let inspector = state.workspaceInspector
        state.detachWorkspace(.alignment)
        let first = try #require(state.workbenchPresentation.window(for: .alignment))
        try await settle()
        #expect(first.isVisible && first.undoManager === f.document.undoManager)
        #expect(ShowWindowRegistry.state(for: first) === state)
        let sharedModels = state.alignmentModel === f.model && state.cleanupModel === cleanup
        #expect(sharedModels)
        try capture(first, name: "Detached Alignment")
        #expect(state.workspaceInspector == inspector && !state.bottomPanePresented)
        state.openWorkspace(.alignment, separateWindow: false)
        #expect(state.workbenchPresentation.window(for: .alignment) === first)
        state.reattachWorkspace(.alignment)
        #expect(!state.workspaceIsDetached(.alignment) && !first.isVisible)
        #expect(state.bottomPaneContent == .alignment && state.bottomPanePresented)
        let sameRuntime = state.alignmentModel === f.model
        let unchanged = f.document.store.residentModel == before
        #expect(sameRuntime && unchanged)
        let settings = AppSettings.shared
        let originalPreference = settings.workspacesInSeparateWindows
        defer { settings.workspacesInSeparateWindows = originalPreference }
        settings.workspacesInSeparateWindows = true
        #expect(!state.workspaceIsDetached(.alignment), "A default change must not move an already-open workspace.")
        state.openWorkspace(.alignment)
        #expect(state.workspaceIsDetached(.alignment))
        owner.close()
        #expect(!state.workspaceIsDetached(.alignment))
    }

    @Test func reviewSelectionDoesNotOpenHiddenInspectorOrReplaceEpisodeContext() async throws {
        let (f, cleanup, state) = try await ReviewPanelHostedTests().fixture()
        defer { cleanup.cancel(); f.close() }
        let review = try #require(cleanup.fillerReviews.first)
        state.workspaceInspector = .episode
        state.inspectorPresented = false
        cleanup.focusReviewRow(review.id)
        #expect(state.workspaceInspector == .episode && !state.inspectorPresented)
        #expect(cleanup.selectedReviewRowID == review.id)
    }

    @Test func detachAndReattachKeepFiltersSelectionRuntimeAndTheOriginalDocument() async throws {
        let (f, cleanup, state) = try await ReviewPanelHostedTests().fixture()
        defer { cleanup.cancel(); f.close() }
        let owner = EpisodeWindowController(state: state)
        f.document.addWindowController(owner)
        owner.showWindow(nil)
        try await settle()
        let before = f.document.store.residentModel
        let review = try #require(cleanup.fillerReviews.first)
        cleanup.reviewSearch = "um"
        cleanup.reviewStatusFilter = .pending
        cleanup.focusReviewRow(review.id)
        state.reviewPanelPresented = true
        let presentation = state.reviewPresentation
        presentation.detach()
        let first = try #require(presentation.detachedWindow?.window)
        try await settle()
        #expect(first.isVisible && first.styleMask.contains(.resizable))
        #expect(first.accessibilityIdentifier() == "ww.review.window")
        #expect(ShowWindowRegistry.state(for: first) === state)
        #expect(first.undoManager === f.document.undoManager)
        #expect(state.cleanupModel === cleanup && state.alignmentModel === f.model)
        #expect(cleanup.reviewSearch == "um" && cleanup.reviewStatusFilter == .pending)
        #expect(cleanup.selectedReviewRowID == review.id)
        #expect(!f.model.canStopAudition && f.document.store.residentModel == before)
        presentation.detach()
        #expect(presentation.detachedWindow?.window === first)
        func indicator(in view: NSView?) -> ReviewPlaybackIndicator.IndicatorView? {
            guard let view else { return nil }
            if let indicator = view as? ReviewPlaybackIndicator.IndicatorView { return indicator }
            return view.subviews.lazy.compactMap { indicator(in: $0) }.first
        }
        cleanup.play(interval: 0...6, loop: false)
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !cleanup.isPlaying, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(cleanup.isPlaying)
        try await settle()
        let detachedIndicator = try #require(indicator(in: first.contentView))
        #expect(!detachedIndicator.line.isHidden)
        presentation.reattach()
        try await settle()
        #expect(!presentation.isDetached && !first.isVisible)
        #expect(state.reviewPanelPresented && state.bottomPaneContent == .review)
        #expect(cleanup.reviewSearch == "um" && cleanup.selectedReviewRowID == review.id)
        #expect(f.document.store.residentModel == before)
        #expect(ShowWindowRegistry.state(for: first) == nil)
        #expect(cleanup.isPlaying, "Reattaching the review does not restart or stop the shared transport.")
        let dockedIndicator = try #require(indicator(in: owner.window?.contentView))
        #expect(!dockedIndicator.line.isHidden)
        cleanup.stopPlayback()
        try await settle()
        #expect(dockedIndicator.line.isHidden)
    }

    @Test func detachedEditsUseTheSameUndoHistoryAndClosingTheWindowDoesNotCloseTheEpisode() async throws {
        let (f, cleanup, state) = try await ReviewPanelHostedTests().fixture()
        defer { cleanup.cancel(); f.close() }
        let owner = EpisodeWindowController(state: state)
        f.document.addWindowController(owner)
        owner.showWindow(nil)
        try await settle()
        let before = f.document.store.residentModel
        let review = try #require(cleanup.fillerReviews.first)
        state.reviewPresentation.detach()
        let window = try #require(state.reviewPresentation.detachedWindow?.window)
        let undo = try #require(window.undoManager)
        while undo.groupingLevel > 0 { undo.endUndoGrouping() }
        undo.removeAllActions()
        undo.groupsByEvent = false
        defer { undo.groupsByEvent = true }
        undo.beginUndoGrouping()
        cleanup.resizeReviewInterval(review.id, expanding: true)
        undo.endUndoGrouping()
        let changed = f.document.store.residentModel
        #expect(changed != before)
        #expect(window.undoManager === f.document.undoManager)
        undo.undo()
        #expect(f.document.store.residentModel == before)
        undo.redo()
        #expect(f.document.store.residentModel == changed)
        window.close()
        #expect(!state.reviewPresentation.isDetached && !state.reviewPresentation.isClosed)
        #expect(state.cleanupModel === cleanup && owner.window?.isVisible == true)
        #expect(ShowWindowRegistry.state(for: window) == nil)
        state.reviewPresentation.detach()
        #expect(state.reviewPresentation.isDetached)
        owner.close()
        try await settle()
        #expect(state.reviewPresentation.isClosed && !state.reviewPresentation.isDetached)
    }

    @Test func deletingTheOriginEpisodeClosesOnlyItsOwnDetachedReview() async throws {
        let (first, firstCleanup, firstState) = try await ReviewPanelHostedTests().fixture()
        let (other, otherCleanup, otherState) = try await ReviewPanelHostedTests().fixture()
        defer { firstCleanup.cancel(); otherCleanup.cancel(); first.close(); other.close() }
        firstState.reviewPresentation.detach()
        otherState.reviewPresentation.detach()
        let firstWindow = try #require(firstState.reviewPresentation.detachedWindow?.window)
        let otherWindow = try #require(otherState.reviewPresentation.detachedWindow?.window)
        #expect(firstWindow !== otherWindow)
        #expect(firstWindow.undoManager !== otherWindow.undoManager)
        let registered = ShowWindowRegistry.state(for: firstWindow) === firstState
        let observed = ShowWindowRegistry.states(for: first.document.store).contains { $0 === firstState }
        #expect(registered && observed)
        let removed = first.document.store.removeEpisode(first.model.episodeID)
        try #require(removed)
        let episodeRemoved = !first.document.store.containsEpisode(first.model.episodeID)
        #expect(episodeRemoved)
        let closeDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while firstWindow.isVisible, ContinuousClock.now < closeDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        Attachment.record(Data("""
            catalogContainsEpisode=\(first.document.store.containsEpisode(first.model.episodeID))
            residentContainsEpisode=\(first.document.store.residentModel.episode(first.model.episodeID) != nil)
            selectedEpisodePresent=\(firstState.selectedEpisode != nil)
            detached=\(firstState.reviewPresentation.isDetached)
            visible=\(firstWindow.isVisible)
            registered=\(ShowWindowRegistry.state(for: firstWindow) === firstState)
            """.utf8), named: "Deleted episode window lifecycle.txt")
        #expect(!firstWindow.isVisible && !firstState.reviewPresentation.isDetached)
        #expect(otherWindow.isVisible && otherState.reviewPresentation.isDetached)
        otherState.reviewPresentation.reattach()
    }
}
