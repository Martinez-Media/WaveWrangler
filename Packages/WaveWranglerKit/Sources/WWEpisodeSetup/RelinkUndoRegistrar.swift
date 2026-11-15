import Foundation
import WWCore

/// Registers the device-local "Relink “file”" action on the document's undo manager.
///
/// Every inverse is registered **synchronously** inside the undo/redo handler (while `isUndoing` /
/// `isRedoing` is true), so it lands on the correct stack. The asynchronous engine work (commit or
/// revert) is then queued and runs in order. Nothing here touches either file; it only moves the
/// source's device-local access record.
@MainActor
public final class RelinkUndoRegistrar {
    /// One relink commit; undo waits for its receipt before reverting.
    private final class Operation {
        var receipt: Task<RelinkReceipt?, Never>?
        var invalidated = false
    }

    private struct Request {
        var sourceID: SourceID
        var url: URL
        var identity: IdentityStatus
        var actionName: String
    }

    public let undoManager: UndoManager
    public let engine: any SourceSetupEngine
    /// Called on the main actor when a commit fails; the failed action is removed from undo.
    public var onFailure: (String) -> Void = { _ in }
    public var onUndoFailure: (String) -> Void = { _ in }
    private var tail: Task<Void, Never>?
    /// `UndoManager` doesn't retain targets; registered operations are kept alive here.
    private var targets: [ObjectIdentifier: Operation] = [:]

    public init(undoManager: UndoManager, engine: any SourceSetupEngine) {
        self.undoManager = undoManager
        self.engine = engine
    }

    /// Commits a user-confirmed relink and registers its undo step immediately.
    public func relink(_ sourceID: SourceID, to url: URL, identity: IdentityStatus, actionName: String) {
        let request = Request(sourceID: sourceID, url: url, identity: identity, actionName: actionName)
        let operation = Operation()
        grouped { registerUndo(of: operation, request) }
        enqueueCommit(operation, request)
    }

    /// Waits until all queued engine work has finished (tests, and before reading engine state).
    public func settle() async {
        while let current = tail {
            await current.value
            if tail == current { return }
        }
    }

    private func registerUndo(of operation: Operation, _ request: Request) {
        targets[ObjectIdentifier(operation)] = operation
        undoManager.registerUndo(withTarget: operation) { [weak self] operation in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Inverse first, synchronously, so it is recorded as the redo of this undo.
                let redo = self.registerRedo(request)
                self.enqueue { [weak self, engine = self.engine] in
                    guard let receipt = await operation.receipt?.value else { return }
                    do {
                        try await engine.revertRelink(receipt)
                    } catch {
                        guard let self else { return }
                        redo.invalidated = true
                        self.undoManager.removeAllActions(withTarget: redo)
                        self.targets[ObjectIdentifier(redo)] = nil
                        self.grouped { self.registerUndo(of: operation, request) }
                        self.onUndoFailure((error as? SourceEngineError)?.reason ?? error.localizedDescription)
                    }
                }
            }
        }
        undoManager.setActionName(request.actionName)
    }

    private func registerRedo(_ request: Request) -> Operation {
        let marker = Operation()
        targets[ObjectIdentifier(marker)] = marker
        undoManager.registerUndo(withTarget: marker) { [weak self] marker in
            MainActor.assumeIsolated {
                guard let self else { return }
                let operation = Operation()
                self.registerUndo(of: operation, request)
                self.enqueueCommit(operation, request, redo: marker)
            }
        }
        undoManager.setActionName(request.actionName)
        return marker
    }

    private func enqueueCommit(_ operation: Operation, _ request: Request, redo: Operation? = nil) {
        let previous = tail
        let commit = Task { [engine, weak self] () -> RelinkReceipt? in
            await previous?.value
            guard redo?.invalidated != true else {
                self?.undoManager.removeAllActions(withTarget: operation)
                self?.targets[ObjectIdentifier(operation)] = nil
                return nil
            }
            do {
                return try await engine.commitRelink(request.sourceID, to: request.url, identity: request.identity)
            } catch {
                self?.undoManager.removeAllActions(withTarget: operation)
                self?.targets[ObjectIdentifier(operation)] = nil
                self?.onFailure((error as? SourceEngineError)?.reason ?? error.localizedDescription)
                return nil
            }
        }
        operation.receipt = commit
        tail = Task { _ = await commit.value }
    }

    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = tail
        tail = Task {
            await previous?.value
            await work()
        }
    }

    private func grouped(_ body: () -> Void) {
        let open = undoManager.groupingLevel == 0
        if open { undoManager.beginUndoGrouping() }
        body()
        if open { undoManager.endUndoGrouping() }
    }
}
