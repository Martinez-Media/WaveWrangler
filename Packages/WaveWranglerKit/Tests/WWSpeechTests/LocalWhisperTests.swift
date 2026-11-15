import AVFoundation
import CryptoKit
import Foundation
import Synchronization
import Testing
import WWWhisperNative
@testable import WWSpeech

@Suite("Pinned local Whisper", .serialized)
struct LocalWhisperTests {
    @Test func catalogOffersOnlyPinnedQualifiedModelsWithExplicitHTTPSDownloads() {
        #expect(LocalWhisperWeights.allCases == [.baseEnglish, .smallEnglish, .turbo, .largeV3])
        for weights in LocalWhisperWeights.allCases {
            #expect(weights.downloadURL.scheme == "https")
            #expect(weights.downloadURL.host == "huggingface.co")
            #expect(weights.downloadURL.lastPathComponent == weights.filename)
            #expect(weights.downloadURL.pathComponents.contains(LocalWhisperWeights.sourceRevision))
            #expect(!weights.downloadURL.pathComponents.contains("main"))
            #expect(weights.sha256.count == 64 && weights.byteCount > 100_000_000)
            #expect(!weights.title.isEmpty && !weights.detail.isEmpty)
        }
        #expect(LocalWhisperWeights.turbo.title.contains("recommended"))
        #expect(LocalWhisperWeights.allCases.filter { $0.title.contains("recommended") } == [.turbo])
        #expect(LocalWhisperWeights.baseEnglish.rawValue == "baseEnglish")
        #expect(LocalWhisperWeights.turbo.rawValue == "turbo")
        #expect(Set(LocalWhisperWeights.allCases.map(\.filename)).count == 4)
        #expect(Set(LocalWhisperWeights.allCases.map(\.sha256)).count == 4)
        #expect(LocalWhisperWeights.smallEnglish.byteCount == 487_614_201)
        #expect(LocalWhisperWeights.smallEnglish.sha256 == "c6138d6d58ecc8322097e0f987c32f1be8bb0a18532a3f88f734d1bbf9c41e5d")
        #expect(LocalWhisperWeights.largeV3.byteCount == 1_081_140_203)
        #expect(LocalWhisperWeights.largeV3.sha256 == "d75795ecff3f83b5faa89d1900604ad8c780abd5739fae406de19f23ecd98ad1")
    }
    @Test(arguments: LocalWhisperWeights.allCases)
    func missingAndWrongSizeModelsRefuseBeforeInference(_ weights: LocalWhisperWeights) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: SpeechModelError.missingModel) {
            try LocalWhisper.load(path: url.path, weights: weights)
        }
        try Data([1]).write(to: url)
        #expect(throws: SpeechModelError.invalidSize) {
            try LocalWhisper.load(path: url.path, weights: weights)
        }
    }

    @Test(arguments: [false, true])
    func refusedNativeMeasurementsDoNotRetainPreviousLifecycleEvidence(canceled: Bool) {
        var metrics = WWWhisperLifecycleMetrics(initialization_wait_seconds: 1, context_setup_seconds: 1,
            inference_seconds: 1, context_disposal_seconds: 1, inference_aborted: 1)
        var flag: Int32 = canceled ? 1 : 0
        let native = withUnsafeMutablePointer(to: &flag) { pointer in
            ww_whisper_infer_window_measured(nil, 0, nil, 0,
                WWWhisperConfiguration(use_metal: 0, threads: 2), {
                    $0?.assumingMemoryBound(to: Int32.self).pointee ?? 1
                }, pointer, &metrics)
        }
        #expect(native.status == (canceled ? WW_INFERENCE_CANCELED : WW_INFERENCE_INVALID_INPUT))
        #expect(metrics.initialization_wait_seconds == 0 && metrics.context_setup_seconds == 0
                && metrics.inference_seconds == 0 && metrics.context_disposal_seconds == 0
                && metrics.inference_aborted == 0)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WW_WHISPER_QUALIFICATION_MODEL"] != nil))
    func optedInGeneratedSpeechQualifiesPinnedModelAndBackend() async throws {
        let env = ProcessInfo.processInfo.environment
        let weights = try #require(env["WW_WHISPER_QUALIFICATION_MODEL"].flatMap(LocalWhisperWeights.init(rawValue:)))
        let backend = try #require(env["WW_WHISPER_QUALIFICATION_BACKEND"].flatMap(TranscriptionBackend.init(rawValue:)))
        let root = URL(fileURLWithPath: try #require(env["WW_WHISPER_QUALIFICATION_DIRECTORY"]))
        let configuration = try TranscriptionConfiguration.resolve(backend: backend, threads: .two)
        let pool = TranscriptionWorkerPool()
        let cost = try TranscriptionResources(weights: weights, configuration: configuration)
        try await pool.withAdmission(resources: cost) {
            let engine = try await LocalWhisper.load(url: root.appendingPathComponent(weights.filename),
                                                    weights: weights, configuration: configuration)
            let audio = try AVAudioFile(forReading: root.appendingPathComponent("generated-control.wav"))
            try #require(audio.processingFormat.channelCount == 1 && audio.processingFormat.sampleRate == 48_000)
            try #require(audio.length > 4_800 && audio.length <= 30 * 48_000)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: audio.processingFormat,
                                                      frameCapacity: AVAudioFrameCount(audio.length)))
            try audio.read(into: buffer)
            let samples = try #require(buffer.floatChannelData?[0])
            let pcm = Array(UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength)))
            let result = try await engine.transcribeWindow(pcm: pcm, sampleRate: 48_000)
            let text = result.segments.map(\.text).joined(separator: " ").lowercased()
            #expect(text.contains("review") && text.contains("meeting") && text.contains("notes"))
            #expect(result.segments.contains { $0.startSeconds != nil })
            for segment in result.segments {
                #expect(!segment.text.isEmpty)
                #expect((segment.startSeconds == nil) == (segment.endSeconds == nil))
                if let start = segment.startSeconds, let end = segment.endSeconds {
                    #expect(start >= 0 && end > start && end <= Double(pcm.count) / 48_000)
                }
            }
            #expect(engine.revision == configuration.revision(weights: weights))
            #expect(try engine.transcribe(pcm: [Float](repeating: 0, count: 16_000), sampleRate: 16_000).segments.isEmpty)
            #expect(throws: PCMInferenceRefusal.canceled) {
                try engine.transcribe(pcm: pcm, sampleRate: 48_000, isCanceled: { true })
            }
            #expect(throws: PCMInferenceRefusal.invalidPCM) {
                try engine.transcribe(pcm: [Float](repeating: 0, count: 480_001), sampleRate: 16_000)
            }
            print("WHISPER-MODEL-QUALIFICATION \(weights.rawValue) \(configuration.backend.rawValue): \(text); recipe=\(engine.revision)")
        }
        #expect(await pool.snapshot.reservedBytes == 0)
    }

    private final class CancellationPolls: Sendable {
        let count = Mutex(0)
        func cancelDuringInference() -> Bool {
            count.withLock { value in
                value += 1
                return value >= 6
            }
        }
    }

    private struct LifecycleSample: Sendable {
        let transcript: PCMTranscript
        let total: Double
        let wait: Double
        let setup: Double
        let inference: Double
        let disposal: Double
    }

    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    @concurrent
    private func measure(_ engine: LocalWhisper, pcm: [Float]) async throws -> LifecycleSample {
        var metrics = WWWhisperLifecycleMetrics()
        let start = ContinuousClock.now
        let transcript = try withUnsafeMutablePointer(to: &metrics) {
            try engine.transcribe(pcm: pcm, sampleRate: 48_000,
                                  isCanceled: { Task<Never, Never>.isCancelled }, nativeMetrics: $0)
        }
        return LifecycleSample(transcript: transcript, total: Self.seconds(start.duration(to: .now)),
            wait: metrics.initialization_wait_seconds, setup: metrics.context_setup_seconds,
            inference: metrics.inference_seconds, disposal: metrics.context_disposal_seconds)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WW_WHISPER_LIFECYCLE_MODEL"] != nil),
          .timeLimit(.minutes(3)))
    func optedInGeneratedSpeechMeasuresIndependentContextLifecycle() async throws {
        let env = ProcessInfo.processInfo.environment
        let path = try #require(env["WW_WHISPER_LIFECYCLE_MODEL"])
        let weights = try #require(LocalWhisperWeights.allCases.first {
            $0.filename == URL(fileURLWithPath: path).lastPathComponent
        })
        let backend = try #require(env["WW_WHISPER_LIFECYCLE_BACKEND"].flatMap(TranscriptionBackend.init(rawValue:)))
        let configuration = try TranscriptionConfiguration.resolve(backend: backend, threads: .two)
        let audio = try AVAudioFile(forReading: URL(fileURLWithPath: #require(env["WW_WHISPER_LIFECYCLE_CONTROL"])))
        try #require(audio.processingFormat.channelCount == 1 && audio.processingFormat.sampleRate == 48_000)
        try #require(audio.length > 4_800 && audio.length <= 30 * 48_000)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: audio.processingFormat,
            frameCapacity: AVAudioFrameCount(audio.length)))
        try audio.read(into: buffer)
        let channel = try #require(buffer.floatChannelData?[0])
        let pcm = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        let pcmHash = pcm.withUnsafeBytes { SHA256.hash(data: Data($0)).map { String(format: "%02x", $0) }.joined() }
        let pool = TranscriptionWorkerPool()
        let workerStart = ContinuousClock.now
        try await pool.withAdmission(resources: TranscriptionResources(weights: weights, configuration: configuration)) {
            print("WHISPER-LIFECYCLE worker_admission_elapsed seconds=\(Self.seconds(workerStart.duration(to: .now)))")
            let admissionStart = ContinuousClock.now
            let engine = try await LocalWhisper.load(url: URL(fileURLWithPath: path),
                                                    weights: weights, configuration: configuration)
            print("WHISPER-LIFECYCLE model_admission model=\(weights.rawValue) backend=\(backend.rawValue) seconds=\(Self.seconds(admissionStart.duration(to: .now))) pcmSHA256=\(pcmHash) frames=\(pcm.count) revision=\(engine.revision)")
            var reference: PCMTranscript?
            for repetition in 0..<3 {
                let sample = try await measure(engine, pcm: pcm)
                let text = sample.transcript.segments.map(\.text).joined(separator: " ").lowercased()
                #expect(text.contains("review") && text.contains("meeting") && text.contains("notes"))
                #expect(sample.setup > 0 && sample.inference > 0 && sample.disposal > 0 && sample.wait >= 0)
                #expect(sample.total >= sample.wait + sample.setup + sample.inference + sample.disposal)
                for segment in sample.transcript.segments {
                    if let start = segment.startSeconds, let end = segment.endSeconds {
                        #expect(start >= 0 && end > start && end <= Double(pcm.count) / 48_000)
                    }
                }
                if let reference { #expect(sample.transcript == reference) }
                reference = sample.transcript
                print("WHISPER-LIFECYCLE context repetition=\(repetition) total=\(sample.total) wait=\(sample.wait) setup=\(sample.setup) inference=\(sample.inference) disposal=\(sample.disposal) text=\(text)")
            }
            let unmeasured = try await engine.transcribeWindow(pcm: pcm, sampleRate: 48_000)
            #expect(unmeasured == reference)
            let polls = CancellationPolls()
            var canceledMetrics = WWWhisperLifecycleMetrics()
            #expect(throws: PCMInferenceRefusal.canceled) {
                try withUnsafeMutablePointer(to: &canceledMetrics) {
                    try engine.transcribe(pcm: pcm, sampleRate: 48_000,
                        isCanceled: { polls.cancelDuringInference() }, nativeMetrics: $0)
                }
            }
            #expect(canceledMetrics.inference_aborted == 1 && canceledMetrics.inference_seconds > 0
                    && canceledMetrics.context_disposal_seconds > 0)
            print("WHISPER-LIFECYCLE canceled setup=\(canceledMetrics.context_setup_seconds) inference=\(canceledMetrics.inference_seconds) disposal=\(canceledMetrics.context_disposal_seconds)")
            let afterCancellation = try await engine.transcribeWindow(pcm: pcm, sampleRate: 48_000)
            #expect(afterCancellation == reference)
        }
        let released = await pool.snapshot
        #expect(released.active == 0 && released.waiting == 0 && released.reservedBytes == 0
                && released.activeCPUThreads == 0 && released.activeMetalWorkers == 0)
        if env["WW_WHISPER_LIFECYCLE_CONCURRENT"] == "1" {
            let pairConfiguration = try TranscriptionConfiguration.resolve(backend: backend, threads: .one)
            let pairPool = TranscriptionWorkerPool(concurrency: .two)
            let resources = try TranscriptionResources(weights: weights, configuration: pairConfiguration)
            async let left = pairPool.withAdmission(resources: resources) {
                let engine = try await LocalWhisper.load(url: URL(fileURLWithPath: path),
                    weights: weights, configuration: pairConfiguration)
                return try await measure(engine, pcm: pcm)
            }
            async let right = pairPool.withAdmission(resources: resources) {
                let engine = try await LocalWhisper.load(url: URL(fileURLWithPath: path),
                    weights: weights, configuration: pairConfiguration)
                return try await measure(engine, pcm: pcm)
            }
            let pair = try await (left, right)
            #expect(pair.0.transcript == pair.1.transcript)
            for (index, sample) in [pair.0, pair.1].enumerated() {
                print("WHISPER-LIFECYCLE pair index=\(index) total=\(sample.total) wait=\(sample.wait) setup=\(sample.setup) inference=\(sample.inference) disposal=\(sample.disposal)")
            }
            let snapshot = await pairPool.snapshot
            #expect(snapshot.peakActive == 2 && snapshot.active == 0 && snapshot.reservedBytes == 0
                    && snapshot.activeCPUThreads == 0 && snapshot.activeMetalWorkers == 0)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WW_LOCAL_ASR_MODEL"] != nil
                   && ProcessInfo.processInfo.environment["WW_LOCAL_ASR_PUBLIC_WAV"] != nil))
    func explicitlyOptedInPublicSpeechRunsThroughTheActualNativeBackend() async throws {
        let env = ProcessInfo.processInfo.environment
        let path = try #require(env["WW_LOCAL_ASR_MODEL"])
        let weights = try #require(LocalWhisperWeights.allCases.first { $0.filename == URL(fileURLWithPath: path).lastPathComponent })
        let engine = try await LocalWhisper.load(url: URL(fileURLWithPath: path), weights: weights)
        #expect(engine.revision == TranscriptionConfiguration.cpu.revision(weights: weights))
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: #require(env["WW_LOCAL_ASR_PUBLIC_WAV"])))
        #expect(file.processingFormat.channelCount == 1)
        #expect(file.length < 30 * Int64(file.processingFormat.sampleRate))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let channel = try #require(buffer.floatChannelData?[0])
        let input = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        #expect(file.processingFormat.sampleRate == 16_000)
        // Exercise the app's 48 kHz input path, not only the recognizer's native 16 kHz path.
        let pcm = input.flatMap { [$0, $0, $0] }
        let result = try await engine.transcribeWindow(pcm: pcm, sampleRate: 48_000)
        let text = result.segments.map(\.text).joined(separator: " ").lowercased()
        print("LOCAL-WHISPER-PUBLIC-CONTROL \(weights.rawValue): \(text)")
        #expect(text.contains("gospel"))
        #expect(text.contains("middle"))
        #expect(!result.segments.isEmpty)
        #expect(throws: PCMInferenceRefusal.canceled) {
            try engine.transcribe(pcm: pcm, sampleRate: 48_000, isCanceled: { true })
        }
        #expect(try engine.transcribe(pcm: [Float](repeating: 0, count: 16000), sampleRate: 16000).segments.isEmpty)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WW_LOCAL_ASR_CONCURRENT"] == "1"
                   && ProcessInfo.processInfo.environment["WW_LOCAL_ASR_MODEL"] != nil
                   && ProcessInfo.processInfo.environment["WW_LOCAL_ASR_PUBLIC_WAV"] != nil))
    func optedInNativeContextsActuallyOverlapAndPreserveRecognitionAndTimestamps() async throws {
        let env = ProcessInfo.processInfo.environment
        let path = try #require(env["WW_LOCAL_ASR_MODEL"])
        let weights = try #require(LocalWhisperWeights.allCases.first { $0.filename == URL(fileURLWithPath: path).lastPathComponent })
        let engine = try await LocalWhisper.load(url: URL(fileURLWithPath: path), weights: weights)
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: #require(env["WW_LOCAL_ASR_PUBLIC_WAV"])))
        try #require(file.processingFormat.channelCount == 1 && file.processingFormat.sampleRate == 16_000)
        try #require(file.length > 0 && file.length <= 30 * 16_000)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let samples = try #require(buffer.floatChannelData?[0])
        let pcm = Array(UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength))).flatMap { [$0, $0, $0] }
        let reference = try await engine.transcribeWindow(pcm: pcm, sampleRate: 48_000)
        #expect(reference.segments.map(\.text).joined(separator: " ").lowercased().contains("gospel"))
        for policy in [TranscriptionConcurrency.two, .four] {
            let barrier = NativeInferenceBarrier(expected: policy.rawValue)
            let pool = TranscriptionWorkerPool(concurrency: policy)
            try await withThrowingTaskGroup(of: PCMTranscript.self) { group in
                for _ in 0..<policy.rawValue {
                    group.addTask {
                        try await pool.withAdmission {
                            try await Self.nativeControl(engine, pcm: pcm, barrier: barrier)
                        }
                    }
                }
                var count = 0
                for try await result in group {
                    #expect(result == reference, "Parallel decoding must not change text or approximate timestamps")
                    count += 1
                }
                #expect(count == policy.rawValue)
            }
            #expect(barrier.overlapped, "Every worker must reach native graph computation before any is released")
            #expect(await pool.snapshot.active == 0)
            print("LOCAL-WHISPER-CONCURRENT-CONTROL \(weights.rawValue): \(policy.rawValue) overlapping native contexts; serial text/timestamps preserved")
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WW_ASR_ACCELERATION_FIXTURES"] != nil),
          arguments: [LocalWhisperWeights.baseEnglish, .turbo])
    func optedInBundledMetalAndCPUUseVerifiedPublicAudio(_ weights: LocalWhisperWeights) async throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["WW_ASR_ACCELERATION_FIXTURES"]))
        let audio = root.appendingPathComponent("clips/ami-01.wav")
        #expect(SHA256.hash(data: try Data(contentsOf: audio)).map { String(format: "%02x", $0) }.joined()
                == "56f4b4abd278c61426b7ec4c844c5aff1420204a7b18ac7976321f8dc26c9b83")
        let file = try AVAudioFile(forReading: audio)
        try #require(file.processingFormat.channelCount == 1 && file.processingFormat.sampleRate == 16_000)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let samples = try #require(buffer.floatChannelData?[0])
        let pcm = Array(UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength))).flatMap { [$0, $0, $0] }
        try #require(TranscriptionConfiguration.metalAvailable, "This opt-in qualification requires supported Apple silicon")
        for backend in [TranscriptionBackend.cpu, .metal] {
            let configuration = try TranscriptionConfiguration.resolve(backend: backend, threads: .four)
            let engine = try await LocalWhisper.load(url: root.appendingPathComponent("downloads/\(weights.filename)"),
                                                    weights: weights, configuration: configuration)
            let heartbeat = Task { @MainActor in
                var last = ProcessInfo.processInfo.systemUptime, maximumGap = 0.0, count = 0
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(20)) }
                    catch is CancellationError { break }
                    let now = ProcessInfo.processInfo.systemUptime
                    maximumGap = max(maximumGap, now - last)
                    last = now
                    count += 1
                }
                return (maximumGap, count)
            }
            defer { heartbeat.cancel() }
            let reference = try await engine.transcribeWindow(pcm: pcm, sampleRate: 48_000)
            let text = reference.segments.map(\.text).joined(separator: " ").lowercased()
            #expect(text.contains("kick") && text.contains("meeting"))
            #expect(reference.segments.contains { $0.startSeconds != nil })
            for segment in reference.segments {
                if let start = segment.startSeconds, let end = segment.endSeconds {
                    #expect(start >= 0 && end > start && end <= Double(pcm.count) / 48_000)
                }
            }
            let barrier = NativeInferenceBarrier(expected: 2)
            let pool = TranscriptionWorkerPool(concurrency: .two)
            let cost = try TranscriptionResources(weights: weights, configuration: configuration)
            try await withThrowingTaskGroup(of: PCMTranscript.self) { group in
                for _ in 0..<2 {
                    group.addTask {
                        try await pool.withAdmission(resources: cost) {
                            try await Self.nativeControl(engine, pcm: pcm, barrier: barrier)
                        }
                    }
                }
                for try await result in group { #expect(result == reference) }
            }
            #expect(barrier.overlapped)
            #expect(await pool.snapshot.reservedBytes == 0)
            let checks = NativeInferenceStart()
            let canceled = Task { try await Self.nativeCancelControl(engine, pcm: pcm, checks: checks) }
            defer { canceled.cancel() }
            let deadline = Date().addingTimeInterval(30)
            while !checks.started, Date() < deadline { try await Task.sleep(for: .milliseconds(2)) }
            try #require(checks.started, "Wait for a native graph checkpoint, not just model initialization")
            try await Task.sleep(for: .milliseconds(20))
            let cancelStart = ProcessInfo.processInfo.systemUptime
            canceled.cancel()
            await #expect(throws: PCMInferenceRefusal.canceled) { try await canceled.value }
            let cancelWall = ProcessInfo.processInfo.systemUptime - cancelStart
            #expect(cancelWall < 30, "Native graph/command buffers must drain; cancellation is not instantaneous")
            heartbeat.cancel()
            let (gap, ticks) = try await heartbeat.value
            #expect(ticks > 0 && gap < 1, "Native inference must not block the MainActor heartbeat")
            #expect(try engine.transcribe(pcm: [Float](repeating: 0, count: 16_000), sampleRate: 16_000).segments.isEmpty)
            print("BUNDLED-ACCELERATION \(weights.rawValue) \(backend.rawValue): overlap=2; cancellation_wall=\(cancelWall); main_actor_max_gap=\(gap); ticks=\(ticks); text=\(text)")
        }
    }

    @concurrent
    private static func nativeCancelControl(
        _ engine: LocalWhisper, pcm: [Float], checks: NativeInferenceStart
    ) async throws -> PCMTranscript {
        try engine.transcribe(pcm: pcm, sampleRate: 48_000, isCanceled: { checks.check() })
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WW_ASR_FULL_CORPUS"] == "1"))
    func optedInProductionCorpusPersistsActualAdapterOutputs() async throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["WW_ASR_ACCELERATION_FIXTURES"]))
        let manifest = try JSONDecoder().decode(NativeCorpusManifest.self,
            from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
        try #require(manifest.clips.count == 7 && manifest.clips.first?.id == "ami-01")
        var inputs: [[Float]] = []
        for clip in manifest.clips {
            let url = root.appendingPathComponent(clip.audio)
            try #require(SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
                         == clip.audio_sha256)
            let file = try AVAudioFile(forReading: url)
            try #require(file.processingFormat.channelCount == 1 && file.processingFormat.sampleRate == 16_000)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(file.length)))
            try file.read(into: buffer)
            let samples = try #require(buffer.floatChannelData?[0])
            inputs.append(Array(UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength))).flatMap { [$0, $0, $0] })
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        for weights in [LocalWhisperWeights.baseEnglish, .turbo] {
            for backend in [TranscriptionBackend.cpu, .metal] {
                let configuration = try TranscriptionConfiguration.resolve(backend: backend, threads: .four)
                let loadStart = ProcessInfo.processInfo.systemUptime
                let engine = try await LocalWhisper.load(url: root.appendingPathComponent("downloads/\(weights.filename)"),
                                                        weights: weights, configuration: configuration)
                let load = ProcessInfo.processInfo.systemUptime - loadStart
                var rounds: [NativeCorpusRound] = []
                for _ in 0..<2 {
                    let start = ProcessInfo.processInfo.systemUptime
                    var clips: [NativeCorpusOutput] = []
                    for (index, pcm) in inputs.enumerated() {
                        let result = try await engine.transcribeWindow(pcm: pcm, sampleRate: 48_000)
                        clips.append(NativeCorpusOutput(index: index, segments: result.segments.map {
                            NativeCorpusSegment(text: $0.text, start: $0.startSeconds, end: $0.endSeconds)
                        }))
                    }
                    #expect(clips.last?.segments.isEmpty == true, "Production bypasses exact digital zero")
                    rounds.append(NativeCorpusRound(wall_seconds: ProcessInfo.processInfo.systemUptime - start, clips: clips))
                }
                let evidence = NativeCorpusEvidence(recipe: engine.revision, model_load_seconds: load, rounds: rounds)
                try encoder.encode(evidence).write(to: root.appendingPathComponent("acceleration/production-\(weights.rawValue)-\(backend.rawValue).json"))
            }
        }
    }

    @concurrent
    private static func nativeControl(
        _ engine: LocalWhisper, pcm: [Float], barrier: NativeInferenceBarrier
    ) async throws -> PCMTranscript {
        let checks = NativeCancellationChecks(barrier: barrier)
        return try engine.transcribe(pcm: pcm, sampleRate: 48_000, isCanceled: { checks.check() })
    }
}

private struct NativeCorpusManifest: Decodable {
    struct Clip: Decodable {
        let id: String
        let audio: String
        let audio_sha256: String
    }
    let clips: [Clip]
}
private struct NativeCorpusSegment: Encodable {
    let text: String
    let start: Double?
    let end: Double?
}
private struct NativeCorpusOutput: Encodable {
    let index: Int
    let segments: [NativeCorpusSegment]
}
private struct NativeCorpusRound: Encodable {
    let wall_seconds: Double
    let clips: [NativeCorpusOutput]
}
private struct NativeCorpusEvidence: Encodable {
    let recipe: String
    let model_load_seconds: Double
    let rounds: [NativeCorpusRound]
}

private final class NativeInferenceStart: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    var started: Bool { lock.withLock { calls >= 5 } }
    func check() -> Bool {
        lock.withLock { calls += 1 }
        return Task<Never, Never>.isCancelled
    }
}

// All mutable state is protected by the corresponding lock/condition; callbacks are synchronous C calls.
private final class NativeCancellationChecks: @unchecked Sendable {
    let barrier: NativeInferenceBarrier
    private let lock = NSLock()
    private var calls = 0
    init(barrier: NativeInferenceBarrier) { self.barrier = barrier }
    func check() -> Bool {
        let call = lock.withLock { calls += 1; return calls }
        // The pinned adapter makes one Swift and three C preflight checks. The fifth is inside
        // whisper_full's CPU graph, so this detects the former full-inference mutex, not just Swift overlap.
        if call == 5 { barrier.enter() }
        return Task<Never, Never>.isCancelled
    }
}

private final class NativeInferenceBarrier: @unchecked Sendable {
    private let condition = NSCondition()
    private let expected: Int
    private var entered = 0
    private var timedOut = false
    init(expected: Int) { self.expected = expected }
    var overlapped: Bool {
        condition.lock()
        defer { condition.unlock() }
        return entered == expected && !timedOut
    }
    func enter() {
        condition.lock()
        defer { condition.unlock() }
        entered += 1
        condition.broadcast()
        let deadline = Date().addingTimeInterval(30)
        while entered < expected && !timedOut {
            if !condition.wait(until: deadline) {
                timedOut = true
                condition.broadcast()
            }
        }
    }
}
