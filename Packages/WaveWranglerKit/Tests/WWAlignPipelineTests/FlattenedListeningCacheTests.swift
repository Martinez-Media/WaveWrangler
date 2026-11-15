import Foundation
import Testing
import WWCore
import WWDecode
import WWDerived
import WWTimeMap
@testable import WWAlignPipeline

@Suite("Shared persistent flattened listening cache", .serialized)
struct FlattenedListeningCacheTests {
    @Test func manyMapTilesRetireMetadataWithoutChangingSamples() async throws {
        let f = try await PipelineFixture([
            .init(name: "Reference", sources: [.init(name: "reference", seconds: 12, signal: .scene(seed: 91))]),
            .init(name: "Target", sources: [.init(name: "target", seconds: 12, signal: .scene(seed: 91))]),
        ], nativeAudio: true)
        let source = f.id("target"), url = f.url("target")
        let interpretation = try await f.decoder.withDecodingCursor(url, source: source) { $0.interpretation }
        let witness = try await f.decoder.captureRawIdentity(url, matching: interpretation.sourceFingerprint)
        let cache = AlignedAuditionPCMCache(maximumSampleBytes: 960_000, maximumEntries: 1, coordinator: f.coordinator)
        for generation in 0..<24 {
            let preparation = try await f.pipeline.prepareManual(model: f.model, episode: f.episodeID,
                sources: f.sources, authorizations: f.authorizations)
            _ = try await f.acceptAndActivate(preparation,
                [f.epochs[1]: .numeric(ppm: 125, offsetMilliseconds: Double(generation * 10))])
            let revision = MapRevisionReference(episode: f.episodeID,
                revision: try #require(f.model.episode(f.episodeID)?.alignment?.acceptedRevision))
            let map = try #require(try f.model.timeMap(revision: revision.revision, in: f.episodeID)
                .groups.first { $0.group == f.groups[1] })
            for tile in 0..<3 {
                let first = Int64(tile * 240_000), frames = first..<(first + 48_000)
                let cached = try await AlignedAuditionWindowReader.readWindow(sourceURL: url, source: source,
                    matching: witness, decoder: f.decoder, groupMap: map, decodedChannel: 0,
                    outputFrames: frames, cache: cache, revision: revision)
                if generation == 0 || generation == 23 {
                    let direct = try await AlignedAuditionWindowReader.readWindow(sourceURL: url, source: source,
                        matching: witness, decoder: f.decoder, groupMap: map, decodedChannel: 0, outputFrames: frames)
                    let unchanged = cached == direct
                    #expect(unchanged)
                }
                let counts = await f.coordinator.disposableMetadataCounts
                #expect(counts.slots == 0 && counts.recipes == 0 && counts.consumers == 0)
            }
        }
        let statistics = await cache.statistics
        #expect(statistics.entries <= 1 && statistics.sampleBytes <= 960_000)
        await f.pipeline.shutdown()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WW_REVIEW_TILE_MEASUREMENT"] == "1"))
    func generatedColdTilesMeasureMetadataBeyondPCMCapacity() async throws {
        let f = try await PipelineFixture([
            .init(name: "Reference", sources: [.init(name: "reference", seconds: 12, signal: .scene(seed: 91))]),
            .init(name: "Target", sources: [.init(name: "target", seconds: 12, signal: .scene(seed: 91))]),
        ], nativeAudio: true)
        let source = f.id("target"), url = f.url("target")
        let interpretation = try await f.decoder.withDecodingCursor(url, source: source) { $0.interpretation }
        let witness = try await f.decoder.captureRawIdentity(url, matching: interpretation.sourceFingerprint)
        let cache = AlignedAuditionPCMCache(maximumSampleBytes: 960_000, maximumEntries: 1, coordinator: f.coordinator)
        for generation in 0..<4 {
            let preparation = try await f.pipeline.prepareManual(model: f.model, episode: f.episodeID,
                sources: f.sources, authorizations: f.authorizations)
            _ = try await f.acceptAndActivate(preparation,
                [f.epochs[1]: .numeric(ppm: 125, offsetMilliseconds: Double(generation * 10))])
            let revision = MapRevisionReference(episode: f.episodeID,
                revision: try #require(f.model.episode(f.episodeID)?.alignment?.acceptedRevision))
            let map = try #require(try f.model.timeMap(revision: revision.revision, in: f.episodeID)
                .groups.first { $0.group == f.groups[1] })
            let start = ContinuousClock.now
            for tile in 0..<2 {
                let first = Int64(tile * 240_000)
                _ = try await AlignedAuditionWindowReader.readWindow(sourceURL: url, source: source,
                    matching: witness, decoder: f.decoder, groupMap: map, decodedChannel: 0,
                    outputFrames: first..<(first + 48_000), cache: cache, revision: revision)
            }
            let statistics = await cache.statistics
            let recipes = await f.coordinator.inputs.recipes.keys.filter { $0.hasPrefix("ww.aligned-listening-pcm;") }
            let slots = await f.coordinator.states().keys.filter { $0.name.hasPrefix("aligned-listening/") }
            print("R13-generation \(generation) recipes \(recipes.count) recipeBytes \(recipes.reduce(0) { $0 + $1.utf8.count }) slots \(slots.count) sampleBytes \(statistics.sampleBytes) duration \(start.duration(to: .now))")
            #expect(statistics.entries <= 1 && statistics.sampleBytes <= 960_000)
            #expect(recipes.isEmpty && slots.isEmpty)
        }
        let recipes = await f.coordinator.inputs.recipes.keys.filter { $0.hasPrefix("ww.aligned-listening-pcm;") }
        #expect(recipes.isEmpty, "Disposable metadata retires after the final tile consumer")
        await f.pipeline.shutdown()
    }

    @Test func affineWindowsReuseCanonicalBinaryTilesAcrossCacheInstancesAndRefuseChangedOriginals() async throws {
        let f = try await PipelineFixture([
            .init(name: "Reference", sources: [.init(name: "reference", seconds: 8, signal: .scene(seed: 91))]),
            .init(name: "Target", sources: [.init(name: "target", seconds: 8, signal: .scene(seed: 91))]),
        ], nativeAudio: true)
        let preparation = try await f.pipeline.prepareManual(model: f.model, episode: f.episodeID,
            sources: f.sources, authorizations: f.authorizations)
        _ = try await f.acceptAndActivate(preparation, [f.epochs[1]: .numeric(ppm: 125, offsetMilliseconds: 10)])
        let source = f.id("target"), url = f.url("target")
        let interpretation = try await f.decoder.withDecodingCursor(url, source: source) { $0.interpretation }
        let witness = try await f.decoder.captureRawIdentity(url, matching: interpretation.sourceFingerprint)
        let revision = MapRevisionReference(episode: f.episodeID,
            revision: try #require(f.model.episode(f.episodeID)?.alignment?.acceptedRevision))
        let map = try #require(try f.model.timeMap(revision: revision.revision, in: f.episodeID)
            .groups.first { $0.group == f.groups[1] })
        let original = try Data(contentsOf: url)
        var changes = f.coordinator.changes.makeAsyncIterator()
        let cache = AlignedAuditionPCMCache(coordinator: f.coordinator)
        let first = try await AlignedAuditionWindowReader.readWindow(sourceURL: url, source: source,
            matching: witness, decoder: f.decoder, groupMap: map, decodedChannel: 0,
            outputFrames: 0..<48_000, cache: cache, revision: revision)
        #expect(await cache.contextEncodingCount == 1)
        for index in 1..<5 {
            let frames = Int64(index * 48_000)..<Int64((index + 1) * 48_000)
            let warm = try await AlignedAuditionWindowReader.readWindow(sourceURL: url, source: source,
                matching: witness, decoder: f.decoder, groupMap: map, decodedChannel: 0,
                outputFrames: frames, cache: cache, revision: revision)
            #expect(warm.count == 48_000)
        }
        #expect(await cache.contextEncodingCount == 1,
                "Resident slices must not encode the complete group map again")
        let replay = AlignedAuditionPCMCache(coordinator: f.coordinator)
        #expect(try await AlignedAuditionWindowReader.readWindow(sourceURL: url, source: source,
            matching: witness, decoder: f.decoder, groupMap: map, decodedChannel: 0,
            outputFrames: 0..<48_000, cache: replay, revision: revision) == first)
        var publishedKey: DerivedAssetKey?
        while let change = await changes.next() {
            if case let .ready(key) = change.state, key.asset.kind == "ww.aligned-listening-pcm" {
                publishedKey = key
                break
            }
        }
        let persistedKey = try #require(publishedKey)
        #expect(await f.coordinator.state(of: DerivedSlot("aligned-listening/\(source)/0/0")) == .idle)
        let payload = try #require(f.coordinator.store.payload(for: persistedKey))
        #expect(payload.starts(with: ListeningPCM.magic))
        #expect(try ListeningPCM.decode(payload).channels[0].count == 240_000)
        #expect(try Data(contentsOf: url) == original)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0]))
        try handle.close()
        await #expect(throws: (any Error).self) {
            try await AlignedAuditionWindowReader.readWindow(sourceURL: url, source: source,
                matching: witness, decoder: f.decoder, groupMap: map, decodedChannel: 0,
                outputFrames: 0..<48_000, cache: replay, revision: revision)
        }
        await f.pipeline.shutdown()
    }

    @Test func adaptiveLegacyJSONIsMigratedToBinaryWithoutChangingSamples() async throws {
        let (f, correction) = try await AdaptiveAudioCacheTests.fixture()
        let url = f.url("target")
        let interpretation = try await f.decoder.withDecodingCursor(url, source: correction.source) { $0.interpretation }
        let witness = try await f.decoder.captureRawIdentity(url, matching: interpretation.sourceFingerprint)
        let original = try Data(contentsOf: url)
        let first = try await f.pipeline.adaptiveAudioWindow(model: f.model, episode: f.episodeID,
            source: correction.source, sourceURL: url, matching: witness, outputFrames: 0..<48_000)
        let slot = DerivedSlot("adaptive-audio/\(f.episodeID)/\(correction.source)/48000/0")
        let key = try #require(await f.coordinator.state(of: slot).key)
        #expect(key.asset.kind == "ww.adaptive-audio-pcm")
        let bytes = try #require(await f.coordinator.readyPayload(for: slot, matching: key))
        let binary = try ListeningPCM.decode(bytes)
        let legacy = AdaptivePCM(firstFrame: binary.firstFrame, channels: binary.channels)
        var oldKey = key
        oldKey.asset.kind = "ww.adaptive-audio-tile"
        await f.coordinator.setAssetRevision(oldKey.asset)
        let data = try JSONEncoder().encode(legacy)
        let seeded = await f.coordinator.submit(DerivedSlot("legacy-pcm-fixture"), key: oldKey) { data }
        #expect(await seeded.outcome == .published(oldKey))
        await f.pipeline.adaptivePCMCache.removeAll()
        await f.coordinator.invalidate(slot)
        #expect(try await f.pipeline.adaptiveAudioWindow(model: f.model, episode: f.episodeID,
            source: correction.source, sourceURL: url, matching: witness, outputFrames: 0..<48_000) == first)
        let migrated = try #require(await f.coordinator.readyPayload(for: slot, matching: key))
        #expect(migrated.starts(with: ListeningPCM.magic))
        #expect(try ListeningPCM.decode(migrated).channels == binary.channels)
        #expect(try Data(contentsOf: url) == original)
        await f.pipeline.shutdown()
    }
}
