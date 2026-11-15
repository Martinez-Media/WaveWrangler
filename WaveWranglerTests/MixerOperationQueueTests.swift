import Foundation
import Testing

@MainActor
@Suite("Mixer transaction ordering", .serialized)
struct MixerOperationQueueTests {
    @MainActor private final class Gate {
        var entered = false
        var released = false
        var continuation: CheckedContinuation<Void, Never>?
        func wait() async {
            entered = true
            guard !released else { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func release() { released = true; continuation?.resume(); continuation = nil }
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(predicate(), "Mixer request did not enter before the deadline")
    }

    @Test func suspendedCaptureDrainsBeforeCloseAndReplacement() async throws {
        let queue = MixerOperationQueue()
        let gate = Gate()
        var writes: [String] = []
        let capture = Task {
            try await queue.run {
                await gate.wait()
                writes.append("capture")
            }
        }
        var tasks = [capture]
        do {
            try await waitUntil { gate.entered }
            tasks.append(Task { try await queue.run { writes.append("close") } })
            try await waitUntil { queue.pending == 2 }
            tasks.append(Task { try await queue.run { writes.append("replacement") } })
            try await waitUntil { queue.pending == 3 }
            #expect(writes.isEmpty)
            capture.cancel()
            gate.release()
            for task in tasks { try await task.value }
        } catch {
            gate.release()
            for task in tasks { _ = await task.result }
            throw error
        }
        #expect(writes == ["capture", "close", "replacement"])
        #expect(queue.pending == 0)
    }

    @Test func refusedOperationDoesNotPoisonFollowingBarrier() async throws {
        enum Refusal: Error { case refused }
        let queue = MixerOperationQueue()
        do {
            try await queue.run { throw Refusal.refused }
            Issue.record("Refusal should propagate")
        } catch Refusal.refused {}
        let result = try await queue.run { 42 }
        #expect(result == 42 && queue.pending == 0)
    }
}
