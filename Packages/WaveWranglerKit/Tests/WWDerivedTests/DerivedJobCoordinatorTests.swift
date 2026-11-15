import Darwin
import Foundation
import Testing
import WWCore
@testable import WWDerived
import WWPersistence

/// Gate-ordered, deterministic tests of the job layer. No wall-clock assertions: every interleaving is forced
/// with latches, and nothing blocks a cooperative-pool thread.
@Suite("Derived job coordinator")
struct DerivedJobCoordinatorTests {
    let source = SourceID()
    let episode = EpisodeID()
    let slot = DerivedSlot("waveform/host")

    var inputs: DerivedInputs {
        var inputs = DerivedInputs()
        inputs.sources[source] = "t1"
        inputs.acceptedMaps[episode] = 1
        inputs.recipes["align"] = 1
        inputs.assets["waveform"] = 1
        inputs.assets["onsets"] = 1
        return inputs
    }

    func key(kind: String = "waveform", token: String = "t1", channel: Int? = 0, mapRevision: Int = 1, upstream: [DerivedAssetKey] = []) -> DerivedAssetKey {
        .sample(
            kind: kind,
            sources: [SourceRevision(source: source, token: token)],
            channel: channel,
            map: MapRevisionReference(episode: episode, revision: mapRevision),
            recipe: RecipeReference(name: "align", revision: 1),
            upstream: upstream
        )
    }

    func coordinator(_ directory: TemporaryDirectory, hooks: DerivedCoordinatorTestHooks = DerivedCoordinatorTestHooks()) throws -> DerivedJobCoordinator {
        DerivedJobCoordinator(store: try makeStore(directory), inputs: inputs, testHooks: hooks)
    }

    func disposableKey(_ index: Int, upstream: [DerivedAssetKey] = []) -> DerivedAssetKey {
        var result = key(channel: index)
        result.recipe = RecipeReference(name: "listening-tile/\(index)", revision: 1)
        result.setUpstream(upstream)
        return result
    }

    @Test func disposableChurnRetiresMetadataAndReusesVerifiedFiles() async throws {
        let directory = try TemporaryDirectory("disposable-churn")
        let coordinator = try coordinator(directory)
        for index in 0..<160 {
            let slot = DerivedSlot("listening/\(index)"), key = disposableKey(index)
            let payload = Data("tile-\(index)".utf8)
            try await coordinator.withDisposableSlot(slot, key: key) {
                #expect(await coordinator.submit(slot, key: key) { payload }.outcome == .published(key))
                #expect(await coordinator.readyPayload(for: slot, matching: key) == payload)
            }
            let counts = await coordinator.disposableMetadataCounts
            #expect(counts.slots == 0 && counts.recipes == 0 && counts.consumers == 0)
            #expect(await coordinator.state(of: slot) == .idle)
            #expect(coordinator.store.payload(for: key) == payload)
        }
        let slot = DerivedSlot("listening/0"), key = disposableKey(0)
        try await coordinator.withDisposableSlot(slot, key: key) {
            #expect(await coordinator.submit(slot, key: key) {
                Issue.record("Retiring metadata must not discard verified tile files")
                return Data()
            }.outcome == .reused(key))
            #expect(await coordinator.readyPayload(for: slot, matching: key) == Data("tile-0".utf8))
        }
        await coordinator.shutdown()
    }

    @Test func disposableOwnershipCannotAdoptCanonicalSlotsOrRecipes() async throws {
        let directory = try TemporaryDirectory("disposable-ownership")
        let coordinator = try coordinator(directory)
        let key = key()
        #expect(await coordinator.submit(slot, key: key) { Data([1]) }.outcome == .published(key))
        for candidate in [slot, DerivedSlot("new-slot-with-canonical-recipe")] {
            await #expect(throws: DisposableDerivedFailure.ownershipConflict) {
                try await coordinator.withDisposableSlot(candidate, key: key) {
                    Issue.record("Disposable ownership must not take over canonical state")
                }
            }
        }
        #expect(await coordinator.readyPayload(for: slot, matching: key) == Data([1]))
        #expect(await coordinator.inputs.recipes["align"] == 1)
        let counts = await coordinator.disposableMetadataCounts
        #expect(counts.slots == 0 && counts.recipes == 0 && counts.consumers == 0)
        await coordinator.shutdown()
    }

    @Test(arguments: [false, true])
    func disposableInvalidationRemovesUnsafeFilesOrFailsVisiblyAndRetries(refuseRemoval: Bool) async throws {
        let directory = try TemporaryDirectory("disposable-invalidated")
        let coordinator = try coordinator(directory)
        let slot = DerivedSlot("invalidated"), key = disposableKey(0)
        let assets = coordinator.store.assetsDirectory
        defer { chmod(assets.path, 0o755) }
        @Sendable func publishAndInvalidate() async throws {
            try await coordinator.withDisposableSlot(slot, key: key) {
                #expect(await coordinator.submit(slot, key: key) { Data([1]) }.outcome == .published(key))
                await coordinator.invalidate(slot)
                if refuseRemoval { #expect(chmod(assets.path, 0o555) == 0) }
            }
        }
        if refuseRemoval {
            await #expect(throws: DisposableDerivedFailure.self) { try await publishAndInvalidate() }
            let counts = await coordinator.disposableMetadataCounts
            #expect(counts.slots == 1 && counts.keys == 1 && counts.recipes == 1 && counts.consumers == 0)
            let failed: Bool = if case .failed = await coordinator.state(of: slot) { true } else { false }
            #expect(failed)
            #expect(coordinator.store.payload(for: key) == Data([1]))
            #expect(chmod(assets.path, 0o755) == 0)
        } else {
            try await publishAndInvalidate()
            #expect(coordinator.store.payload(for: key) == nil)
        }
        let runs = Counter()
        try await coordinator.withDisposableSlot(slot, key: key) {
            #expect(await coordinator.submit(slot, key: key) {
                runs.increment()
                return Data([1])
            }.outcome == .published(key))
        }
        #expect(runs.value == 1, "Retired explicit invalidation cannot revive the old cached payload")
        let after = await coordinator.disposableMetadataCounts
        #expect(after.slots == 0 && after.keys == 0 && after.recipes == 0 && after.consumers == 0)
        await coordinator.shutdown()
    }

    @Test func disposableInvalidationCannotDeleteAnotherReadyOwnersPayload() async throws {
        let directory = try TemporaryDirectory("disposable-shared-invalidation")
        let coordinator = try coordinator(directory)
        let slot = DerivedSlot("disposable"), key = disposableKey(0)
        let other = DerivedSlot("ordinary-owner")
        try await coordinator.withDisposableSlot(slot, key: key) {
            _ = await coordinator.submit(slot, key: key) { Data([1]) }.outcome
            #expect(await coordinator.submit(other, key: key) { Data() }.outcome == .reused(key))
            await coordinator.invalidate(slot)
        }
        #expect(await coordinator.readyPayload(for: other, matching: key) == Data([1]))
        #expect(await coordinator.readyPayload(for: slot, matching: key) == nil)
        let held = await coordinator.disposableMetadataCounts
        #expect(held.slots == 1 && held.keys == 1 && held.consumers == 0)
        await coordinator.invalidate(other)
        #expect(coordinator.store.payload(for: key) == nil)
        #expect(await coordinator.state(of: slot) == .idle)
        await coordinator.shutdown()
    }

    @Test(arguments: [false, true])
    func disposableInvalidationPreservesOrdinaryHistory(rekey: Bool) async throws {
        let directory = try TemporaryDirectory("disposable-shared-history")
        let coordinator = try coordinator(directory)
        let slot = DerivedSlot("disposable"), first = disposableKey(0)
        let other = DerivedSlot("ordinary-owner")
        var changed = key(mapRevision: 2)
        changed.recipe = first.recipe
        let second = changed
        try await coordinator.withDisposableSlot(slot, key: first) {
            _ = await coordinator.submit(slot, key: first) { Data([1]) }.outcome
            #expect(await coordinator.submit(other, key: first) { Data() }.outcome == .reused(first))
            await coordinator.acceptMap(MapRevisionReference(episode: episode, revision: 2))
            if rekey {
                #expect(await coordinator.submit(other, key: second) { Data([2]) }.outcome == .published(second))
            }
            await coordinator.invalidate(slot)
        }
        #expect(coordinator.store.payload(for: first) == Data([1]))
        let held = await coordinator.disposableMetadataCounts
        #expect(held.slots == 1 && held.keys == 1 && held.consumers == 0)
        await coordinator.acceptMap(MapRevisionReference(episode: episode, revision: 1))
        await coordinator.restoreCachedCurrentSlots()
        #expect(await coordinator.readyPayload(for: other, matching: first) == Data([1]))
        #expect(await coordinator.readyPayload(for: slot, matching: first) == nil)
        await coordinator.invalidate(other)
        #expect(coordinator.store.payload(for: first) == nil)
        #expect(await coordinator.state(of: slot) == .idle)
        await coordinator.shutdown()
    }

    @Test func oneRecipeCannotAccumulateUnboundedInvalidatedSourceKeys() async throws {
        let directory = try TemporaryDirectory("disposable-key-bound")
        let coordinator = try coordinator(directory)
        let slot = DerivedSlot("one-tile"), original = disposableKey(0)
        let ready = Latch(), release = Latch()
        let held = Task {
            try await coordinator.withDisposableSlot(slot, key: original) {
                _ = await coordinator.submit(slot, key: original) { Data([1]) }.outcome
                await coordinator.invalidate(slot)
                await ready.open()
                await release.wait()
            }
        }
        await ready.wait()
        let limit = DerivedJobCoordinator.maximumDisposableMetadataEntries
        for index in 1..<limit {
            let revision = SourceRevision(source: source, token: "generation-\(index)")
            await coordinator.updateSource(revision)
            var changed = disposableKey(0)
            changed.setSources([revision])
            let key = changed
            try await coordinator.withDisposableSlot(slot, key: key) {
                _ = await coordinator.submit(slot, key: key) { Data([1]) }.outcome
                await coordinator.invalidate(slot)
            }
        }
        let counts = await coordinator.disposableMetadataCounts
        #expect(counts.slots == 1 && counts.keys == limit && counts.recipes == 1 && counts.consumers == 1)
        let revision = SourceRevision(source: source, token: "generation-\(limit)")
        await coordinator.updateSource(revision)
        var changed = disposableKey(0)
        changed.setSources([revision])
        let next = changed
        await #expect(throws: DisposableDerivedFailure.capacityExceeded) {
            try await coordinator.withDisposableSlot(slot, key: next) {
                Issue.record("Recipe-name reuse must not bypass the full-key metadata bound")
            }
        }
        await release.open()
        try await held.value
        let released = await coordinator.disposableMetadataCounts
        #expect(released.slots == 0 && released.keys == 0 && released.recipes == 0 && released.consumers == 0)
        try await coordinator.withDisposableSlot(slot, key: next) {
            #expect(await coordinator.submit(slot, key: next) { Data([1]) }.outcome == .published(next))
        }
        await coordinator.shutdown()
    }

    @Test func heldDisposableConsumerSurvivesChurnAndCancellationReleasesItsMetadata() async throws {
        let directory = try TemporaryDirectory("disposable-consumer")
        let coordinator = try coordinator(directory)
        let slot = DerivedSlot("held"), key = disposableKey(-1)
        let ready = Latch(), release = Latch()
        let consumer = Task {
            try await coordinator.withDisposableSlot(slot, key: key) {
                #expect(await coordinator.submit(slot, key: key) { Data("held".utf8) }.outcome == .published(key))
                await ready.open()
                await release.wait()
                #expect(await coordinator.readyPayload(for: slot, matching: key) == Data("held".utf8))
            }
        }
        await ready.wait()
        for index in 0..<100 {
            let next = DerivedSlot("churn/\(index)"), nextKey = disposableKey(index)
            try await coordinator.withDisposableSlot(next, key: nextKey) {
                _ = await coordinator.submit(next, key: nextKey) { Data([1]) }.outcome
            }
        }
        let heldCounts = await coordinator.disposableMetadataCounts
        #expect(heldCounts.slots == 1 && heldCounts.recipes == 1 && heldCounts.consumers == 1)
        consumer.cancel()
        await release.open()
        await #expect(throws: CancellationError.self) { try await consumer.value }
        let released = await coordinator.disposableMetadataCounts
        #expect(released.slots == 0 && released.recipes == 0 && released.consumers == 0)
        await coordinator.shutdown()
    }

    @Test func liveUpstreamDependenciesPinDisposableMetadataUntilInvalidation() async throws {
        let directory = try TemporaryDirectory("disposable-dependencies")
        let coordinator = try coordinator(directory)
        let parent = DerivedSlot("held-upstream"), parentKey = disposableKey(-1)
        let child = DerivedSlot("dependent"), childKey = key(kind: "onsets", upstream: [parentKey])
        try await coordinator.withDisposableSlot(parent, key: parentKey) {
            #expect(await coordinator.submit(parent, key: parentKey) { Data([1]) }.outcome == .published(parentKey))
            #expect(await coordinator.submit(child, key: childKey) { Data([2]) }.outcome == .published(childKey))
        }
        for index in 0..<100 {
            let slot = DerivedSlot("churn/\(index)"), key = disposableKey(index)
            try await coordinator.withDisposableSlot(slot, key: key) {
                _ = await coordinator.submit(slot, key: key) { Data([3]) }.outcome
            }
        }
        #expect(await coordinator.readyPayload(for: parent, matching: parentKey) == Data([1]))
        #expect(await coordinator.readyPayload(for: child, matching: childKey) == Data([2]))
        let pinned = await coordinator.disposableMetadataCounts
        #expect(pinned.slots == 1 && pinned.recipes == 1 && pinned.consumers == 0)
        await coordinator.invalidate(child)
        let released = await coordinator.disposableMetadataCounts
        #expect(released.slots == 0 && released.recipes == 0)
        #expect(await coordinator.staleReasons(for: childKey).contains(.upstreamChanged))
        await coordinator.shutdown()
    }

    @Test func pinnedDisposableMetadataHasAnExplicitAdmissionBoundAndRetry() async throws {
        let directory = try TemporaryDirectory("disposable-bound")
        let coordinator = try coordinator(directory)
        let limit = DerivedJobCoordinator.maximumDisposableMetadataEntries
        for index in 0..<limit {
            let parent = DerivedSlot("parent/\(index)"), parentKey = disposableKey(index)
            let child = DerivedSlot("child/\(index)"), childKey = key(kind: "onsets", upstream: [parentKey])
            try await coordinator.withDisposableSlot(parent, key: parentKey) {
                _ = await coordinator.submit(parent, key: parentKey) { Data([1]) }.outcome
                _ = await coordinator.submit(child, key: childKey) { Data([2]) }.outcome
            }
        }
        let counts = await coordinator.disposableMetadataCounts
        #expect(counts.slots == limit && counts.recipes == limit && counts.consumers == 0)
        let next = DerivedSlot("overflow"), nextKey = disposableKey(limit)
        let nextRecipe = try #require(nextKey.recipe)
        await #expect(throws: DisposableDerivedFailure.capacityExceeded) {
            try await coordinator.withDisposableSlot(next, key: nextKey) {
                Issue.record("Full pinned metadata must refuse before work or registration")
            }
        }
        #expect(await coordinator.state(of: next) == .idle)
        #expect(await coordinator.inputs.recipes[nextRecipe.name] == nil)
        await coordinator.invalidate(DerivedSlot("child/0"))
        try await coordinator.withDisposableSlot(next, key: nextKey) {
            #expect(await coordinator.submit(next, key: nextKey) { Data([3]) }.outcome == .published(nextKey))
        }
        let after = await coordinator.disposableMetadataCounts
        #expect(after.slots == limit - 1 && after.recipes == limit - 1)
        await coordinator.shutdown()
    }

    @Test func sharedDisposableSlotAlsoBoundsActiveConsumers() async throws {
        let directory = try TemporaryDirectory("disposable-consumer-bound")
        let coordinator = try coordinator(directory)
        let slot = DerivedSlot("shared"), key = disposableKey(0)
        @Sendable func hold(_ remaining: Int) async throws {
            if remaining > 0 {
                try await coordinator.withDisposableSlot(slot, key: key) {
                    try await hold(remaining - 1)
                }
            } else {
                let counts = await coordinator.disposableMetadataCounts
                #expect(counts.slots == 1 && counts.recipes == 1)
                #expect(counts.consumers == DerivedJobCoordinator.maximumDisposableMetadataEntries)
                await #expect(throws: DisposableDerivedFailure.capacityExceeded) {
                    try await coordinator.withDisposableSlot(slot, key: key) {
                        Issue.record("Same-key consumers must not bypass the shared admission bound")
                    }
                }
            }
        }
        try await hold(DerivedJobCoordinator.maximumDisposableMetadataEntries)
        let after = await coordinator.disposableMetadataCounts
        #expect(after.slots == 0 && after.recipes == 0 && after.consumers == 0)
        await coordinator.shutdown()
    }

    @Test func releasingATerminalConsumerRetiresItsDisposableDependencyChain() async throws {
        let directory = try TemporaryDirectory("disposable-chain")
        let coordinator = try coordinator(directory)
        let first = DerivedSlot("first"), firstKey = disposableKey(0)
        let middle = DerivedSlot("middle"), middleKey = disposableKey(1, upstream: [firstKey])
        let last = DerivedSlot("last"), lastKey = disposableKey(2, upstream: [middleKey])
        let ready = Latch(), release = Latch()
        let terminal = try await coordinator.withDisposableSlot(first, key: firstKey) {
            _ = await coordinator.submit(first, key: firstKey) { Data([1]) }.outcome
            return try await coordinator.withDisposableSlot(middle, key: middleKey) {
                _ = await coordinator.submit(middle, key: middleKey) { Data([2]) }.outcome
                let terminal = Task {
                    try await coordinator.withDisposableSlot(last, key: lastKey) {
                        _ = await coordinator.submit(last, key: lastKey) { Data([3]) }.outcome
                        await ready.open()
                        await release.wait()
                        #expect(await coordinator.readyPayload(for: first, matching: firstKey) == Data([1]))
                        #expect(await coordinator.readyPayload(for: middle, matching: middleKey) == Data([2]))
                        #expect(await coordinator.readyPayload(for: last, matching: lastKey) == Data([3]))
                    }
                }
                await ready.wait()
                return terminal
            }
        }
        let held = await coordinator.disposableMetadataCounts
        #expect(held.slots == 3 && held.recipes == 3 && held.consumers == 1)
        await release.open()
        try await terminal.value
        let after = await coordinator.disposableMetadataCounts
        #expect(after.slots == 0 && after.recipes == 0 && after.consumers == 0)
        await coordinator.shutdown()
    }

    @Test(arguments: [false, true])
    func disposableMetadataWaitsForCanceledOrStaleWorkToFinish(invalidateSource: Bool) async throws {
        let directory = try TemporaryDirectory("disposable-unfinished")
        let coordinator = try coordinator(directory)
        let slot = DerivedSlot("unfinished"), key = disposableKey(0)
        let started = Latch(), release = Latch()
        let consumer = Task {
            try await coordinator.withDisposableSlot(slot, key: key) {
                let job = await coordinator.submit(slot, key: key) {
                    await started.open()
                    await release.wait()
                    return Data([1])
                }
                let outcome = await job.outcome
                #expect(outcome == (invalidateSource ? .discardedStale([.sourceChanged(source)]) : .canceled))
                #expect(await coordinator.readyPayload(for: slot, matching: key) == nil)
            }
        }
        await started.wait()
        if invalidateSource { await coordinator.updateSource(SourceRevision(source: source, token: "replacement")) }
        else { await coordinator.cancel(slot) }
        let held = await coordinator.disposableMetadataCounts
        #expect(held.slots == 1 && held.recipes == 1 && held.consumers == 1)
        await release.open()
        try await consumer.value
        let after = await coordinator.disposableMetadataCounts
        #expect(after.slots == 0 && after.recipes == 0 && after.consumers == 0)
        #expect(coordinator.store.payload(for: key) == nil)
        await coordinator.shutdown()
    }

    @MainActor
    @Test func workRunsOffTheMainThreadAndPublishes() async throws {
        let directory = try TemporaryDirectory("jobs")
        let coordinator = try coordinator(directory)
        let key = key()
        let job = await coordinator.submit(slot, key: key) {
            #expect(pthread_main_np() == 0, "derived work never runs on the main thread")
            return Data("peaks".utf8)
        }
        #expect(await job.outcome == .published(key))
        #expect(await coordinator.state(of: slot) == .ready(key))
        #expect(await coordinator.readyPayload(for: slot) == Data("peaks".utf8))
        #expect(coordinator.store.payload(for: key) == Data("peaks".utf8))
    }

    @Test func cancelingAnOldSubmissionCannotCancelANewerJobWithTheSameKey() async throws {
        let directory = try TemporaryDirectory("same-key-cancellation")
        let coordinator = try coordinator(directory)
        let key = key()
        let firstStarted = Latch(), releaseFirst = Latch()
        let secondStarted = Latch(), releaseSecond = Latch()
        let first = await coordinator.submit(slot, key: key) {
            await firstStarted.open()
            await releaseFirst.wait()
            return Data("first".utf8)
        }
        await firstStarted.wait()
        let second = await coordinator.submit(slot, key: key) {
            await secondStarted.open()
            await releaseSecond.wait()
            return Data("second".utf8)
        }
        await secondStarted.wait()
        await coordinator.cancel(first)
        await releaseSecond.open()
        #expect(await second.outcome == .published(key))
        await releaseFirst.open()
        _ = await first.outcome
        #expect(await coordinator.readyPayload(for: slot) == Data("second".utf8))
    }

    @Test func completeOverviewReusesAcrossOpensAndRebuildsAfterMapOrSourceChanges() async throws {
        let directory = try TemporaryDirectory("overview-cache")
        var current = DerivedInputs()
        current.sources[source] = "metadata:original"
        current.acceptedMaps[episode] = 1
        current.assets["ww.waveform.overview"] = 1
        func overviewKey(token: String, revision: Int) -> DerivedAssetKey {
            DerivedAssetKey(
                asset: AssetSpec(kind: "ww.waveform.overview", revision: 1),
                sources: [SourceRevision(source: source, token: token)],
                format: .current,
                map: MapRevisionReference(episode: episode, revision: revision)
            )
        }
        let first = overviewKey(token: "metadata:original", revision: 1)
        let store = try makeStore(directory)
        let initial = DerivedJobCoordinator(store: store, inputs: current)
        #expect(await initial.submit(slot, key: first) { Data("measured bins".utf8) }.outcome == .published(first))
        await initial.shutdown()

        let reopened = DerivedJobCoordinator(store: store, inputs: current)
        #expect(await reopened.submit(slot, key: first) {
            Issue.record("A verified cached overview should not rescan audio")
            return Data()
        }.outcome == .reused(first))
        #expect(await reopened.readyPayload(for: slot) == Data("measured bins".utf8))
        #expect(await reopened.readyPayload(for: slot, matching: first) == Data("measured bins".utf8))

        await reopened.acceptMap(MapRevisionReference(episode: episode, revision: 2))
        #expect(await reopened.readyPayload(for: slot) == nil)
        let remapped = overviewKey(token: "metadata:original", revision: 2)
        #expect(await reopened.submit(slot, key: remapped) { Data("remapped bins".utf8) }.outcome == .published(remapped))
        #expect(await reopened.readyPayload(for: slot, matching: first) == nil)
        #expect(await reopened.readyPayload(for: slot, matching: remapped) == Data("remapped bins".utf8))
        await reopened.updateSource(SourceRevision(source: source, token: "metadata:replacement"))
        #expect(await reopened.readyPayload(for: slot) == nil)
        let replaced = overviewKey(token: "metadata:replacement", revision: 2)
        #expect(await reopened.submit(slot, key: replaced) { Data("replacement bins".utf8) }.outcome == .published(replaced))
    }

    @Test func sourceCoverageCacheSurvivesMapRevisionsButRejectsDifferentCoverage() async throws {
        let directory = try TemporaryDirectory("coverage-overview-cache")
        var current = DerivedInputs()
        current.sources[source] = "metadata:original"
        current.acceptedMaps[episode] = 1
        current.assets["ww.waveform.overview"] = 2
        let asset = AssetSpec(kind: "ww.waveform.overview", revision: 2)
        let first = DerivedAssetKey(
            asset: asset, sources: [SourceRevision(source: source, token: "metadata:original")],
            format: .current, coverage: "covered-source-frames-a"
        )
        let revised = DerivedAssetKey(
            asset: asset, sources: [SourceRevision(source: source, token: "metadata:original")],
            format: .current, coverage: "covered-source-frames-b"
        )
        let store = try makeStore(directory)
        let slot = DerivedSlot("source-overview")
        let coordinator = DerivedJobCoordinator(store: store, inputs: current)
        #expect(await coordinator.submit(slot, key: first) {
            Data("source extrema".utf8)
        }.outcome == .published(first))
        await coordinator.acceptMap(MapRevisionReference(episode: episode, revision: 2))
        #expect(await coordinator.submit(slot, key: first) {
            Issue.record("Changing only aligned positions must not decode the source again")
            return Data()
        }.outcome == .reused(first))
        #expect(await coordinator.submit(slot, key: revised) {
            Data("new coverage".utf8)
        }.outcome == .published(revised))
        #expect(await coordinator.readyPayload(for: slot, matching: first) == nil)
        #expect(await coordinator.readyPayload(for: slot, matching: revised) == Data("new coverage".utf8))
        await coordinator.updateSource(SourceRevision(source: source, token: "metadata:replacement"))
        #expect(await coordinator.readyPayload(for: slot) == nil)
    }

    /// REF-019: accepting a different map while a job is computing makes its late result stale; it is never
    /// published, served or cached.
    @Test func lateResultAfterAMapChangeIsNeverPublished() async throws {
        let directory = try TemporaryDirectory("jobs")
        let coordinator = try coordinator(directory)
        let key = key()
        let started = Latch()
        let release = Latch()
        let job = await coordinator.submit(slot, key: key) {
            await started.open()
            await release.wait()
            return Data("late".utf8)
        }
        await started.wait()
        await coordinator.acceptMap(MapRevisionReference(episode: episode, revision: 2))
        #expect(await coordinator.state(of: slot) == .stale(key, reasons: [.mapChanged(episode)]))
        await release.open()
        #expect(await job.outcome == .discardedStale([.mapChanged(episode)]))
        #expect(await coordinator.state(of: slot) == .stale(key, reasons: [.mapChanged(episode)]))
        #expect(await coordinator.readyPayload(for: slot) == nil)
        #expect(coordinator.store.payload(for: key) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: coordinator.store.stagingDirectory.path).isEmpty)
    }

    /// The invalidation lands after the result is staged and verified but before the commit turn: the
    /// coordinator-side currency check refuses it.
    @Test(arguments: [false, true])
    func invalidationBetweenStagingAndCommitIsRefused(negativeControl: Bool) async throws {
        let directory = try TemporaryDirectory("jobs")
        let staged = Latch()
        let release = Latch()
        let hooks = DerivedCoordinatorTestHooks(beforeCommit: { _, _ in
            await staged.open()
            await release.wait()
        }, skipCurrencyCheck: negativeControl)
        let coordinator = try coordinator(directory, hooks: hooks)
        let key = key()
        let job = await coordinator.submit(slot, key: key) { Data("late".utf8) }
        await staged.wait()
        await coordinator.acceptMap(MapRevisionReference(episode: episode, revision: 2))
        await release.open()
        let outcome = await job.outcome
        if negativeControl {
            // Without the check, the stale result is published: the ordering test above can fail.
            #expect(outcome == .published(key))
            #expect(coordinator.store.payload(for: key) != nil)
        } else {
            #expect(outcome == .discardedStale([.mapChanged(episode)]))
            #expect(coordinator.store.payload(for: key) == nil)
            #expect(await coordinator.readyPayload(for: slot) == nil)
        }
    }

    /// The invalidation lands after publication: the published result is marked stale and no longer served.
    @Test func invalidationAfterPublicationMarksTheResultStale() async throws {
        let directory = try TemporaryDirectory("jobs")
        let coordinator = try coordinator(directory)
        let key = key()
        #expect(await coordinator.submit(slot, key: key) { Data("a".utf8) }.outcome == .published(key))
        await coordinator.acceptMap(MapRevisionReference(episode: episode, revision: 2))
        #expect(await coordinator.state(of: slot) == .stale(key, reasons: [.mapChanged(episode)]))
        #expect(await coordinator.readyPayload(for: slot) == nil)
    }

    @Test func intentionalHistoryMoveRestoresTheCachedKeyThatIsCurrentAgain() async throws {
        let directory = try TemporaryDirectory("jobs")
        let coordinator = try coordinator(directory)
        let first = key(mapRevision: 1)
        let second = key(mapRevision: 2)
        #expect(await coordinator.submit(slot, key: first) { Data("first".utf8) }.outcome == .published(first))

        await coordinator.acceptMap(MapRevisionReference(episode: episode, revision: 2))
        #expect(await coordinator.submit(slot, key: second) { Data("second".utf8) }.outcome == .published(second))

        await coordinator.acceptMap(MapRevisionReference(episode: episode, revision: 1))
        await coordinator.restoreCachedCurrentSlots()
        #expect(await coordinator.state(of: slot) == .ready(first))
        #expect(await coordinator.readyPayload(for: slot) == Data("first".utf8))

        await coordinator.acceptMap(MapRevisionReference(episode: episode, revision: 2))
        await coordinator.restoreCachedCurrentSlots()
        #expect(await coordinator.state(of: slot) == .ready(second))
        #expect(await coordinator.readyPayload(for: slot) == Data("second".utf8))
    }

    @Test func explicitInvalidationIsNeverUndoneByHistoryReconciliation() async throws {
        let directory = try TemporaryDirectory("jobs")
        let coordinator = try coordinator(directory)
        let key = key()
        #expect(await coordinator.submit(slot, key: key) { Data("cached".utf8) }.outcome == .published(key))
        await coordinator.invalidate(slot)
        await coordinator.restoreCachedCurrentSlots()
        #expect(await coordinator.state(of: slot) == .stale(key, reasons: [.superseded]))
        #expect(await coordinator.readyPayload(for: slot) == nil)
    }

    @Test func explicitInvalidationOfAnAlreadyStaleSlotIsNeverUndone() async throws {
        let directory = try TemporaryDirectory("jobs")
        let coordinator = try coordinator(directory)
        let key = key(mapRevision: 1)
        #expect(await coordinator.submit(slot, key: key) { Data("cached".utf8) }.outcome == .published(key))

        await coordinator.acceptMap(MapRevisionReference(episode: episode, revision: 2))
        await coordinator.invalidate(slot)
        await coordinator.acceptMap(MapRevisionReference(episode: episode, revision: 1))
        await coordinator.restoreCachedCurrentSlots()

        guard case .stale = await coordinator.state(of: slot) else {
            Issue.record("explicit invalidation revived an already-stale slot")
            return
        }
        #expect(await coordinator.readyPayload(for: slot) == nil)
    }

    @Test func rejectedStaleSubmissionDoesNotReviveExplicitlyInvalidatedCache() async throws {
        let directory = try TemporaryDirectory("jobs")
        let coordinator = try coordinator(directory)
        let original = key()
        let rejected = key(token: "outdated")
        #expect(await coordinator.submit(slot, key: original) { Data("cached".utf8) }.outcome == .published(original))
        await coordinator.invalidate(slot)
        #expect(await coordinator.submit(slot, key: rejected) { Data("never".utf8) }.outcome
                == .discardedStale([.sourceChanged(source)]))
        await coordinator.restoreCachedCurrentSlots()
        #expect(await coordinator.readyPayload(for: slot) == nil)
        guard case .stale = await coordinator.state(of: slot) else {
            Issue.record("rejected stale submission revived explicitly invalidated cache")
            return
        }
    }

    @Test func invalidatedKeyIsRecomputedBeforeItsCachedPayloadCanBeServed() async throws {
        let directory = try TemporaryDirectory("jobs")
        let coordinator = try coordinator(directory)
        let key = key()
        #expect(await coordinator.submit(slot, key: key) { Data("old".utf8) }.outcome == .published(key))
        await coordinator.invalidate(slot)
        let started = Latch()
        let release = Latch()
        let recompute = await coordinator.submit(slot, key: key) {
            await started.open()
            await release.wait()
            return Data("new".utf8)
        }
        await started.wait()
        await coordinator.restoreCachedCurrentSlots()
        #expect(await coordinator.readyPayload(for: slot) == nil)
        await release.open()
        #expect(await recompute.outcome == .published(key))
        #expect(await coordinator.readyPayload(for: slot) == Data("new".utf8))
    }

    @Test func aSupersededJobNeverOverwritesItsSuccessor() async throws {
        let directory = try TemporaryDirectory("jobs")
        let coordinator = try coordinator(directory)
        let old = key(channel: 0)
        let new = key(channel: 1)
        let started = Latch()
        let release = Latch()
        let first = await coordinator.submit(slot, key: old) {
            await started.open()
            await release.wait()
            return Data("old".utf8)
        }
        await started.wait()
        let second = await coordinator.submit(slot, key: new) { Data("new".utf8) }
        #expect(await second.outcome == .published(new))
        await release.open()
        #expect(await first.outcome == .discardedStale([.superseded]))
        #expect(await coordinator.state(of: slot) == .ready(new))
        #expect(await coordinator.readyPayload(for: slot) == Data("new".utf8))
        #expect(coordinator.store.payload(for: old) == nil)
    }

    @Test func cancellationStopsTheJobWithoutPublishing() async throws {
        let directory = try TemporaryDirectory("jobs")
        let coordinator = try coordinator(directory)
        let key = key()
        let started = Latch()
        let job = await coordinator.submit(slot, key: key) {
            await started.open()
            // Cancellable wait: returns only through cancellation.
            let (stream, continuation) = AsyncStream<Void>.makeStream()
            await withTaskCancellationHandler {
                for await _ in stream {}
            } onCancel: {
                continuation.finish()
            }
            try Task.checkCancellation()
            return Data("never".utf8)
        }
        await started.wait()
        await coordinator.cancel(slot)
        #expect(await job.outcome == .canceled)
        #expect(await coordinator.state(of: slot) == .canceled(key))
        #expect(coordinator.store.payload(for: key) == nil)
    }

    @Test func aKeyThatIsStaleAtSubmissionNeverRuns() async throws {
        let directory = try TemporaryDirectory("jobs")
        let coordinator = try coordinator(directory)
        let runs = Counter()
        let stale = key(token: "old")
        let job = await coordinator.submit(slot, key: stale) {
            runs.increment()
            return Data()
        }
        #expect(await job.outcome == .discardedStale([.sourceChanged(source)]))
        #expect(runs.value == 0)
        #expect(await coordinator.state(of: slot) == .stale(stale, reasons: [.sourceChanged(source)]))
        // The slot never entered `running`: the job was refused before any task could start its work.
        var changes = coordinator.changes.makeAsyncIterator()
        #expect(await changes.next() == DerivedSlotChange(slot: slot, state: .stale(stale, reasons: [.sourceChanged(source)])))
    }

    enum Change: String, CaseIterable, Sendable {
        case sourceRevision, sourceRemoved, format, acceptedMap, clearedMap, recipe, assetRevision, slotInvalidated
    }

    /// Every input a key names invalidates the slot when it changes.
    @Test(arguments: Change.allCases)
    func everyInputChangeMarksDependentWorkStale(_ change: Change) async throws {
        let directory = try TemporaryDirectory("jobs")
        let coordinator = try coordinator(directory)
        let key = key()
        #expect(await coordinator.submit(slot, key: key) { Data("a".utf8) }.outcome == .published(key))
        let expected: StaleReason
        switch change {
        case .sourceRevision:
            await coordinator.updateSource(SourceRevision(source: source, token: "t2")); expected = .sourceChanged(source)
        case .sourceRemoved:
            await coordinator.removeSource(source); expected = .sourceChanged(source)
        case .format:
            await coordinator.setFormat(FormatRevision(interpretationVersion: 99, envelopeVersion: 1)); expected = .formatChanged
        case .acceptedMap:
            await coordinator.acceptMap(MapRevisionReference(episode: episode, revision: 3)); expected = .mapChanged(episode)
        case .clearedMap:
            await coordinator.clearAcceptedMap(episode: episode); expected = .mapChanged(episode)
        case .recipe:
            await coordinator.setRecipe(RecipeReference(name: "align", revision: 2)); expected = .recipeChanged("align")
        case .assetRevision:
            await coordinator.setAssetRevision(AssetSpec(kind: "waveform", revision: 2)); expected = .assetRevisionChanged("waveform")
        case .slotInvalidated:
            await coordinator.invalidate(slot); expected = .superseded
        }
        #expect(await coordinator.state(of: slot) == .stale(key, reasons: [expected]))
        #expect(await coordinator.readyPayload(for: slot) == nil)
        // Unrelated changes leave a fresh result alone.
        let fresh = DerivedJobCoordinator(store: coordinator.store, inputs: inputs)
        #expect(await fresh.submit(slot, key: key) { Data("a".utf8) }.outcome == .reused(key))
        await fresh.setRecipe(RecipeReference(name: "unrelated", revision: 9))
        await fresh.updateSource(SourceRevision(source: SourceID(), token: "x"))
        #expect(await fresh.state(of: slot) == .ready(key))
    }

    @Test func staleUpstreamCascadesToDependents() async throws {
        let directory = try TemporaryDirectory("jobs")
        let coordinator = try coordinator(directory)
        let upstreamSlot = DerivedSlot("waveform")
        let dependentSlot = DerivedSlot("onsets")
        let upstream = key()
        // Names no source itself: it can only become stale through its upstream.
        let dependent = DerivedAssetKey.sample(kind: "onsets", upstream: [upstream])

        // A dependent cannot publish before its upstream is ready.
        #expect(await coordinator.submit(dependentSlot, key: dependent) { Data() }.outcome == .discardedStale([.upstreamChanged]))

        #expect(await coordinator.submit(upstreamSlot, key: upstream) { Data("w".utf8) }.outcome == .published(upstream))
        #expect(await coordinator.submit(dependentSlot, key: dependent) { Data("o".utf8) }.outcome == .published(dependent))
        await coordinator.updateSource(SourceRevision(source: source, token: "t2"))
        #expect(await coordinator.state(of: upstreamSlot) == .stale(upstream, reasons: [.sourceChanged(source)]))
        #expect(await coordinator.state(of: dependentSlot) == .stale(dependent, reasons: [.upstreamChanged]))
    }

    @Test func largeReadyHistoryDoesNotRehashOrRefreshForUnchangedTranscriptionInputs() async throws {
        let directory = try TemporaryDirectory("large-ready-history")
        let coordinator = try coordinator(directory)
        let reference = key(channel: nil)
        let referenceSlot = DerivedSlot("reference")
        #expect(await coordinator.submit(referenceSlot, key: reference) { Data("reference".utf8) }.outcome == .published(reference))
        let tiles = (0..<128).map { index in
            (DerivedSlot("tile/\(index)"), key(kind: "onsets", channel: index, upstream: [reference]))
        }
        for (slot, key) in tiles {
            #expect(await coordinator.submit(slot, key: key) { Data("tile".utf8) }.outcome == .published(key))
        }
        let refreshes = await coordinator.dependencyRefreshCount
        let digests = await coordinator.readyDigestComputationCount
        #expect(digests == tiles.count + 1)
        let began = ContinuousClock.now
        for index in 0..<256 {
            await coordinator.setAssetRevision(AssetSpec(kind: "onsets", revision: 1))
            await coordinator.setRecipe(RecipeReference(name: "align", revision: 1))
            await coordinator.updateSource(SourceRevision(source: source, token: "t1"))
            await coordinator.setFormat(.current)
            await coordinator.acceptMap(MapRevisionReference(episode: episode, revision: 1))
            #expect(await coordinator.staleReasons(for: tiles[index % tiles.count].1).isEmpty)
        }
        await coordinator.removeSource(SourceID())
        await coordinator.clearAcceptedMap(episode: EpisodeID())
        let elapsed = began.duration(to: .now)
        #expect(await coordinator.dependencyRefreshCount == refreshes)
        #expect(await coordinator.readyDigestComputationCount == digests,
                "Warm tile dependency checks must not re-encode/hash every previously rendered tile")
        print("DERIVED_WARM_HISTORY ready=\(tiles.count + 1) checks=256 refreshes=0 digestComputations=0 elapsed=\(elapsed)")

        await coordinator.updateSource(SourceRevision(source: source, token: "changed"))
        for (slot, key) in tiles {
            #expect(await coordinator.state(of: slot) == .stale(key, reasons: [.sourceChanged(source), .upstreamChanged]))
        }
        #expect(await coordinator.staleReasons(for: tiles[0].1).contains(.upstreamChanged))
        await coordinator.updateSource(SourceRevision(source: source, token: "t1"))
        #expect(await coordinator.staleReasons(for: tiles[0].1).contains(.upstreamChanged),
                "Restoring inputs alone must not revive an unverified cached dependency")
        await coordinator.restoreCachedCurrentSlots()
        #expect(await coordinator.state(of: referenceSlot) == .ready(reference))
        for (slot, key) in tiles { #expect(await coordinator.state(of: slot) == .ready(key)) }
        #expect(await coordinator.readyDigestComputationCount == 2 * digests)
        await coordinator.shutdown()
    }

    @Test func duplicateReadyKeysKeepDependenciesCurrentUntilTheirLastSlotIsInvalidated() async throws {
        let directory = try TemporaryDirectory("ready-aliases")
        let coordinator = try coordinator(directory)
        let first = DerivedSlot("first"), second = DerivedSlot("second"), child = DerivedSlot("child")
        let upstream = key()
        let dependent = key(kind: "onsets", upstream: [upstream])
        #expect(await coordinator.submit(first, key: upstream) { Data("source".utf8) }.outcome == .published(upstream))
        #expect(await coordinator.submit(second, key: upstream) { Data() }.outcome == .reused(upstream))
        #expect(await coordinator.submit(child, key: dependent) { Data("child".utf8) }.outcome == .published(dependent))
        await coordinator.invalidate(first)
        #expect(await coordinator.state(of: child) == .ready(dependent))
        #expect(await coordinator.staleReasons(for: dependent).isEmpty)
        await coordinator.invalidate(second)
        #expect(await coordinator.state(of: child) == .stale(dependent, reasons: [.upstreamChanged]))
        await coordinator.restoreCachedCurrentSlots()
        #expect(await coordinator.staleReasons(for: dependent) == [.upstreamChanged])
        #expect(await coordinator.submit(first, key: upstream) { Data("source".utf8) }.outcome == .published(upstream))
        await coordinator.restoreCachedCurrentSlots()
        #expect(await coordinator.state(of: child) == .ready(dependent))

        let entered = Latch(), release = Latch()
        await coordinator.invalidate(first)
        let replacement = await coordinator.submit(first, key: upstream) {
            await entered.open()
            await release.wait()
            return Data("source".utf8)
        }
        await entered.wait()
        #expect(await coordinator.staleReasons(for: dependent) == [.upstreamChanged],
                "A running replacement is not a ready dependency even when its key matches the old result")
        await coordinator.cancel(first)
        await release.open()
        #expect(await replacement.outcome == .canceled)
        #expect(await coordinator.staleReasons(for: dependent) == [.upstreamChanged])
        await coordinator.shutdown()
    }

    @Test func aRunningDependentIsInvalidatedWithItsUpstream() async throws {
        let directory = try TemporaryDirectory("jobs")
        let coordinator = try coordinator(directory)
        let upstreamSlot = DerivedSlot("waveform")
        let dependentSlot = DerivedSlot("onsets")
        let upstream = key()
        #expect(await coordinator.submit(upstreamSlot, key: upstream) { Data("w".utf8) }.outcome == .published(upstream))
        let dependent = DerivedAssetKey.sample(kind: "onsets", upstream: [upstream])
        let started = Latch()
        let release = Latch()
        let job = await coordinator.submit(dependentSlot, key: dependent) {
            await started.open()
            await release.wait()
            return Data("o".utf8)
        }
        await started.wait()
        await coordinator.invalidate(upstreamSlot)
        await release.open()
        #expect(await job.outcome == .discardedStale([.upstreamChanged]))
        #expect(coordinator.store.payload(for: dependent) == nil)
    }

    @Test func aVerifiedCachedAssetIsReusedWithoutRunningWork() async throws {
        let directory = try TemporaryDirectory("jobs")
        let key = key()
        let first = try coordinator(directory)
        #expect(await first.submit(slot, key: key) { Data("cached".utf8) }.outcome == .published(key))

        let runs = Counter()
        let second = try coordinator(directory)
        let job = await second.submit(slot, key: key) {
            runs.increment()
            return Data()
        }
        #expect(await job.outcome == .reused(key))
        #expect(runs.value == 0)
        #expect(await second.readyPayload(for: slot) == Data("cached".utf8))
    }

    @Test func failedWorkPublishesNothing() async throws {
        struct Boom: Error {}
        let directory = try TemporaryDirectory("jobs")
        let coordinator = try coordinator(directory)
        let key = key()
        let job = await coordinator.submit(slot, key: key) { throw Boom() }
        guard case .failed = await job.outcome else {
            Issue.record("expected failure")
            return
        }
        guard case .failed(key, _) = await coordinator.state(of: slot) else {
            Issue.record("expected failed state")
            return
        }
        #expect(coordinator.store.payload(for: key) == nil)
    }

    /// Many slots in flight; a map change mid-flight leaves only current results published, whatever order the
    /// late results arrive in.
    @Test func concurrentLateResultsNeverPublishStaleAssets() async throws {
        let directory = try TemporaryDirectory("jobs")
        let coordinator = try coordinator(directory)
        let release = Latch()
        var jobs: [DerivedJob] = []
        var started: [Latch] = []
        for channel in 0..<16 {
            let latch = Latch()
            started.append(latch)
            jobs.append(await coordinator.submit(DerivedSlot("ch\(channel)"), key: key(channel: channel)) {
                await latch.open()
                await release.wait()
                return Data([UInt8(channel)])
            })
        }
        for latch in started { await latch.wait() }
        await coordinator.acceptMap(MapRevisionReference(episode: episode, revision: 2))
        let current = (0..<16).map { key(channel: $0, mapRevision: 2) }
        var fresh: [DerivedJob] = []
        for channel in 0..<8 {
            fresh.append(await coordinator.submit(DerivedSlot("ch\(channel)"), key: current[channel]) { Data([UInt8(100 + channel)]) })
        }
        await release.open()
        for (channel, job) in jobs.enumerated() {
            // Re-submitted slots report the late job as superseded; the rest as stale through the map change.
            let reason: StaleReason = channel < 8 ? .superseded : .mapChanged(episode)
            #expect(await job.outcome == .discardedStale([reason]))
            #expect(coordinator.store.payload(for: job.key) == nil)
        }
        for (channel, job) in fresh.enumerated() {
            #expect(await job.outcome == .published(current[channel]))
            #expect(await coordinator.readyPayload(for: DerivedSlot("ch\(channel)")) == Data([UInt8(100 + channel)]))
        }
        for channel in 8..<16 {
            #expect(await coordinator.readyPayload(for: DerivedSlot("ch\(channel)")) == nil)
        }
    }

    // MARK: - Lifetime (review #182 finding 3)

    /// A job whose work ignores cancellation until `release` opens, then records whether it was canceled.
    struct GatedWork {
        let started = Latch()
        let release = Latch()
        let sawCancellation = Flag()

        var work: @Sendable () async throws -> Data {
            { [started, release, sawCancellation] in
                await started.open()
                await release.wait()
                sawCancellation.set(Task.isCancelled)
                return Data("late".utf8)
            }
        }
    }

    @Test func shutdownCancelsRunningWorkAndNothingIsStaged() async throws {
        let directory = try TemporaryDirectory("jobs")
        let coordinator = try coordinator(directory)
        let key = key()
        let gated = GatedWork()
        let job = await coordinator.submit(slot, key: key, work: gated.work)
        await gated.started.wait()

        let shutdown = Task { await coordinator.shutdown() }
        // Deterministic point: shutdown has canceled every job and marked the running slot canceled.
        for await change in coordinator.changes where change.slot == slot && change.state == .canceled(key) { break }
        await gated.release.open()
        await shutdown.value

        #expect(gated.sawCancellation.value, "the running work observes cancellation")
        #expect(await job.outcome == .canceled)
        #expect(await coordinator.state(of: slot) == .canceled(key))
        #expect(coordinator.store.payload(for: key) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: coordinator.store.stagingDirectory.path).isEmpty, "nothing staged")
    }

    @Test func aSubmitAfterShutdownNeverRuns() async throws {
        let directory = try TemporaryDirectory("jobs")
        let coordinator = try coordinator(directory)
        await coordinator.shutdown()
        await coordinator.shutdown() // idempotent
        let runs = Counter()
        let job = await coordinator.submit(slot, key: key()) {
            runs.increment()
            return Data("never".utf8)
        }
        #expect(await job.outcome == .canceled)
        #expect(runs.value == 0, "work submitted after shutdown never runs")
        #expect(await coordinator.state(of: slot) == .idle)
        #expect(await coordinator.isShutdown)
    }

    @Test func releasingTheCoordinatorCancelsRunningWork() async throws {
        let directory = try TemporaryDirectory("jobs")
        var coordinator: DerivedJobCoordinator? = try coordinator(directory)
        let store = try #require(coordinator).store
        let key = key()
        let gated = GatedWork()
        let job = await coordinator!.submit(slot, key: key, work: gated.work)
        await gated.started.wait()

        weak let released = coordinator
        coordinator = nil
        // Liveness guard (no wall clock): the last reference is gone, so deinit runs promptly.
        var yields = 0
        while released != nil, yields < 100_000 { await Task.yield(); yields += 1 }
        #expect(released == nil, "the coordinator was released")
        await gated.release.open()

        #expect(await job.outcome == .canceled)
        #expect(gated.sawCancellation.value, "deinit cancels the running work")
        #expect(store.payload(for: key) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.stagingDirectory.path).isEmpty, "nothing staged")
    }
}
