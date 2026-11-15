import AppKit
import Foundation
import Testing
import WWCore
import WWDecode
import WWEpisodeSetup
import WWPersistence
import WWSources
@testable import WaveWrangler

@MainActor
@Suite("Swift review recovery integrity", .serialized)
struct SwiftReviewRecoveryHostedTests {
    private final class Preference: SourceDownloadPreference {
        var downloadsAutomatically = false
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition())
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WW_REVIEW_PRESENTATION_MEASUREMENT"] == "1"))
    func generatedSourceMeterQueueWaitMeasurement() async throws {
        let sources = (0..<26).map { _ in SourceID() }
        let speakers = (0..<26).map { _ in SpeakerID() }
        let clips = Dictionary(uniqueKeysWithValues: sources.map {
            ($0, AlignmentAudioClip(sampleRate: 48_000, samples: Array(repeating: 0.01, count: 192_000)))
        })
        let meters = Dictionary(uniqueKeysWithValues: zip(speakers, sources).map { ($0.0, Set([$0.1])) })
        for repetition in 0..<5 {
            let output = AlignmentAudioPlayback()
            defer { output.stop() }
            try output.enqueue(clips, startSeconds: 0, first: true, availableSources: Set(sources),
                final: true, meterSpeakers: meters, onSourcesJoined: {},
                onBufferDeadline: { Issue.record("Generated final source audio unexpectedly starved") })
            try await wait { output.sourceMeters.levels.count >= 26 }
            var waits: [Double] = []
            for _ in 0..<20 {
                try await Task.sleep(for: .milliseconds(50))
                let start = ContinuousClock.now
                let snapshot = output.sourceMeters
                let elapsed = start.duration(to: .now).components
                waits.append(Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
                try #require(snapshot.levels.count >= 26)
                let heardFrame = Int64((try #require(output.clock).playhead() * 48_000).rounded(.down))
                #expect(snapshot.frame <= heardFrame && heardFrame - snapshot.frame < 7_200,
                        "Meter publication must advance with the watchdog, not retain a startup snapshot")
            }
            print("R06-26-lanes-queue-read-seconds repetition \(repetition) \(waits)")
        }
    }

    @Test func sourceMeterSnapshotResetAndStopDoNotRetainOldPeaks() async throws {
        let output = AlignmentAudioPlayback()
        defer { output.stop() }
        let source = SourceID(), speaker = SpeakerID()
        let clip = AlignmentAudioClip(sampleRate: 48_000,
            samples: Array(repeating: 0.5, count: 4_800) + Array(repeating: 0.01, count: 96_000))
        try output.enqueue([source: clip], startSeconds: 0, first: true, availableSources: [source],
            final: true, meterSpeakers: [speaker: [source]], onSourcesJoined: {}, onBufferDeadline: {})
        output.setGains([source: 1])
        try await wait {
            guard let level = output.sourceMeters.levels[.speaker(speaker)]?.first else { return false }
            return level.heldPeakDB > -10 && level.rmsDB < -30
        }
        output.resetSourceMeterPeaks(for: .speaker(speaker))
        let held = try #require(output.sourceMeters.levels[.speaker(speaker)]?.first?.heldPeakDB)
        #expect(held < -30)
        output.stop()
        #expect(output.sourceMeters.levels.isEmpty)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WW_REVIEW_PRESENTATION_MEASUREMENT"] == "1"))
    func generatedWaveformGroupingMeasurement() async throws {
        let f = try await AlignmentWaveformRetentionHostedTests().fixture(durationSeconds: 1, extraSources: 24)
        defer { f.close() }
        var model = f.document.store.residentModel
        var episode = try #require(model.episode(f.model.episodeID))
        let speakers = episode.sources.indices.map { Speaker(name: "Generated \($0)") }
        model.speakers = speakers
        for index in episode.sources.indices {
            episode.sources[index].role = .primary
            episode.sources[index].roleConfirmation = .userConfirmed
        }
        episode.speakerAssignments = zip(speakers, episode.sources).map {
            SpeakerAssignment(speakerID: $0.0.id,
                primary: ChannelReference(sourceID: $0.1.id, statedChannel: 0),
                primaryConfirmation: .userConfirmed)
        }
        model.episodes = [episode]
        f.document.store.replaceLoadedModel(model)
        let expected = episode.sources.map(\.id)
        var durations: [Double] = []
        for _ in 0..<5 {
            let start = ContinuousClock.now
            for _ in 0..<100 {
                let groups = f.model.primaryWaveformGroups
                try #require(groups.map(\.id) == speakers.map(\.id))
                try #require(groups.flatMap(\.tracks).map(\.id) == expected)
            }
            let elapsed = start.duration(to: .now).components
            durations.append(Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
        }
        print("R05-26-lanes-100-groupings-seconds \(durations)")
    }

    @Test func failedNativeRelinkUndoPreservesAppliedGrantAndOffersRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "RelinkUndo-\(UUID())")
        let records = root.appending(path: "records")
        try FileManager.default.createDirectory(at: records, withIntermediateDirectories: true)
        defer {
            do {
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: records.path)
                try FileManager.default.removeItem(at: root)
            } catch { Issue.record(error) }
        }
        let file = root.appending(path: "generated.wav")
        try Data(repeating: 1, count: 64).write(to: file)
        let store = FileDeviceAccessStore(fileURL: records.appending(path: "access.json"))
        let context = SourceAccessContext()
        let engine = WWSourcesSetupEngine(showID: ShowID(), store: store,
            context: context, preference: Preference(), captureRawIdentity: { url, fingerprint in
                try await SourceDecoder(access: context).captureRawIdentity(url, matching: fingerprint)
            })
        let source = SourceID()
        let comparison = await engine.compare(candidate: file, for: source)
        let undo = UndoManager()
        undo.groupsByEvent = false
        let registrar = RelinkUndoRegistrar(undoManager: undo, engine: engine)
        var failures: [String] = []
        registrar.onFailure = { Issue.record("Relink commit failed: \($0)") }
        registrar.onUndoFailure = { failures.append($0) }
        registrar.relink(source, to: file, identity: comparison.acceptedIdentity, actionName: "Relink Generated")
        await registrar.settle()
        let key = DeviceAccessKey(showID: engine.showID, sourceID: source)
        let applied = try await store.snapshot(for: key)
        try #require(applied != nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: records.path)
        undo.undo()
        await registrar.settle()
        let afterFailure = try await store.snapshot(for: key)
        let canUndo = undo.canUndo, canRedo = undo.canRedo, action = undo.undoActionName
        #expect(afterFailure == applied)
        #expect(failures.count == 1 && canUndo && !canRedo && action == "Relink Generated")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: records.path)
        undo.undo()
        await registrar.settle()
        let reverted = try await store.record(for: key)
        #expect(reverted == nil)
        #expect(undo.canRedo)
        await engine.shutdown()
    }

    @Test(arguments: [false, true])
    func explicitCheckpointDiscardDeletesOnlyTheOfferedRecord(refuseDeletion: Bool) async throws {
        try #require(PersistenceEnvironment.isUITestRun)
        let root = FileManager.default.temporaryDirectory.appending(path: "CheckpointDiscard-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = ShowDocumentModel(show: Show(title: "Generated"))
        let file = root.appending(path: "Generated.wwshow")
        let bytes = try ShowCatalogCoder().encode(ShowCatalog(original), revision: 1)
        try LocalFileOperations().writeNew(bytes, to: file)
        let document = ShowDocument()
        document.fileURL = file
        document.fileType = DocumentTypes.show
        try document.read(from: file, ofType: DocumentTypes.show)
        defer {
            document.updateChangeCount(.changeCleared)
            document.close()
            do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) }
        }
        let key = document.documentKey
        let candidate = try original.renamingShow(to: "Unsaved")
        let checkpoint = try ShowPackageCoder().encode(candidate, revision: 2)
        let recovery = PersistenceEnvironment.recovery
        try recovery.writeEditCheckpoint(snapshot: checkpoint, base: RevisionFingerprint(of: bytes),
            schemaVersion: SchemaVersion.show, for: key)
        try recovery.setAsideEditCheckpoints(for: key)
        document.refreshEditCheckpointOffer()
        let offered = try #require(document.status.editCheckpointOffer?.candidate?.url)
        let unrelatedKey = DocumentKey.show(ShowID())
        try recovery.writeEditCheckpoint(snapshot: checkpoint, base: RevisionFingerprint(of: bytes),
            schemaVersion: SchemaVersion.show, for: unrelatedKey)
        try recovery.setAsideEditCheckpoints(for: unrelatedKey)
        let unrelated = try #require(recovery.offeredEditCheckpoints(for: unrelatedKey).first?.url)
        defer {
            do { try recovery.discardOfferedEditCheckpoints([offered], for: key)
                 try recovery.discardOfferedEditCheckpoints([unrelated], for: unrelatedKey) }
            catch { Issue.record(error) }
        }
        let unrelatedBytes = try Data(contentsOf: unrelated)
        if refuseDeletion {
            let directory = offered.deletingLastPathComponent()
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
            defer {
                do { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }
                catch { Issue.record(error) }
            }
            var errorPresented = false
            let timer = Timer(timeInterval: 0.01, repeats: true) { _ in
                MainActor.assumeIsolated {
                    guard let alert = NSApp.modalWindow else { return }
                    errorPresented = true
                    NSApp.stopModal(withCode: .OK)
                    alert.orderOut(nil)
                }
            }
            RunLoop.main.add(timer, forMode: .modalPanel)
            RunLoop.main.add(timer, forMode: .common)
            defer { timer.invalidate() }
            document.discardOfferedEditCheckpoint()
            try await wait { errorPresented }
            #expect(FileManager.default.fileExists(atPath: offered.path))
            #expect(document.status.editCheckpointOffer?.candidate?.url == offered)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        }
        document.discardOfferedEditCheckpoint()
        try await wait { document.status.editCheckpointOffer == nil }
        #expect(!FileManager.default.fileExists(atPath: offered.path))
        #expect(try Data(contentsOf: unrelated) == unrelatedBytes)
        #expect(try LocalFileOperations().read(file) == bytes)
    }

    @Test func queuedDiscardDoesNotDeleteAnOfferThatArrivesLater() async throws {
        try #require(PersistenceEnvironment.isUITestRun)
        let root = FileManager.default.temporaryDirectory.appending(path: "LateCheckpoint-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = ShowDocumentModel(show: Show(title: "Generated"))
        let bytes = try ShowCatalogCoder().encode(ShowCatalog(original), revision: 1)
        let file = root.appending(path: "Generated.wwshow")
        try LocalFileOperations().writeNew(bytes, to: file)
        let document = ShowDocument()
        document.fileURL = file
        document.fileType = DocumentTypes.show
        try document.read(from: file, ofType: DocumentTypes.show)
        let gate = SaveWorkerGate()
        defer {
            gate.resume()
            document.updateChangeCount(.changeCleared)
            document.close()
            do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) }
        }
        let recovery = PersistenceEnvironment.recovery, key = document.documentKey
        func offer(_ title: String) throws {
            let candidate = try original.renamingShow(to: title)
            try recovery.writeEditCheckpoint(snapshot: ShowPackageCoder().encode(candidate, revision: 2),
                base: RevisionFingerprint(of: bytes), schemaVersion: SchemaVersion.show, for: key)
            try recovery.setAsideEditCheckpoints(for: key)
            document.refreshEditCheckpointOffer()
        }
        try offer("First")
        let first = try #require(document.status.editCheckpointOffer?.candidate?.url)
        ShowPersistenceLane.enqueue { gate.pauseOnce() }
        try await wait { gate.entered }
        document.discardOfferedEditCheckpoint()
        try offer("Later")
        let later = try #require(document.status.editCheckpointOffer?.candidate?.url)
        try #require(later != first)
        let laterBytes = try Data(contentsOf: later)
        defer {
            do { try recovery.discardOfferedEditCheckpoints([first, later], for: key) }
            catch { Issue.record(error) }
        }
        gate.resume()
        try await wait { !FileManager.default.fileExists(atPath: first.path) }
        #expect(try Data(contentsOf: later) == laterBytes)
        #expect(document.status.editCheckpointOffer?.candidate?.url == later)
        #expect(try LocalFileOperations().read(file) == bytes)
    }
}
