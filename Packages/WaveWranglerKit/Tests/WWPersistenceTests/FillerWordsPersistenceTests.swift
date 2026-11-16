import Foundation
import Testing
import WWCore
@testable import WWPersistence

@Suite("Filler-word persistence and schema-14 migration", .serialized)
struct FillerWordsPersistenceTests {
    private let showID = ShowID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let speakerID = SpeakerID(uuidString: "22222222-2222-2222-2222-222222222222")!

    /// Independently specified schema-14 canonical bytes, not encoded by the current model/coder.
    private let oldCatalog = Data(#"{"history":{"cursor":0,"entries":[]},"schemaVersion":14,"show":{"id":"11111111-1111-1111-1111-111111111111","notes":"Keep original notes","title":"Previous show"},"speakers":[{"id":"22222222-2222-2222-2222-222222222222","name":"Host","notes":"Keep speaker notes"}]}"#.utf8)

    private func previousPackage(storage: Int, extraShowField: Bool = false) throws -> Data {
        var object = try #require(JSONSerialization.jsonObject(with: oldCatalog) as? [String: Any])
        if storage == 1 { object["episodes"] = [] }
        if extraShowField {
            var show = try #require(object["show"] as? [String: Any])
            show["futureField"] = true
            object["show"] = show
        }
        let catalog = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        let digest = RevisionFingerprint.digest(catalog)
        let reference: [String: Any] = ["digest": digest, "byteCount": catalog.count, "encoding": "raw"]
        var manifest: [String: Any] = [
            "format": "com.brandonmartinez.wavewrangler.show-package", "schemaVersion": storage,
            "modelSchemaVersion": 14, "revision": 7,
            "publicationID": "33333333-3333-3333-3333-333333333333",
        ]
        if storage == 1 {
            manifest["catalog"] = reference
            manifest["episodes"] = []
            manifest["checksum"] = "sha256:" + RevisionFingerprint.digest(catalog)
        } else {
            let index: [String: Any] = ["catalog": reference, "episodes": []]
            let bytes = try JSONSerialization.data(withJSONObject: index, options: [.sortedKeys, .withoutEscapingSlashes])
            manifest["index"] = index
            manifest["checksum"] = "sha256:" + RevisionFingerprint.digest(Data("WWShowCatalog2\0".utf8) + bytes)
        }
        return try ShowPackage.frame(.init(manifest: JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]),
            files: [digest: catalog]))
    }

    @Test(arguments: [1, 2])
    func explicitUpgradePreservesOriginalBytesAndAllExistingFields(storage: Int) throws {
        let directory = TempDirectory()
        let url = directory.url.appending(path: "Previous.wwshow")
        let ops = LocalFileOperations()
        let original = try previousPackage(storage: storage)
        try ops.writeNew(original, to: url)
        #expect(throws: PersistenceError.unsupportedOlderSchema(found: 14, minimum: 15)) {
            try ShowPackageCoder().decode(original)
        }
        let recovery = RecoveryStore(root: directory.sub("recovery"))
        _ = try recovery.retainCheckpoint(original, for: .show(showID))
        let checkpoints = try recovery.validatedCheckpoints(for: .show(showID), decode: ShowCatalogMigration.recoveryCatalog)
        #expect(checkpoints.count == 1)
        #expect(try checkpoints.first?.document.payload.materializedModel().show.title == "Previous show")
        let publisher = DocumentPublisher(coder: ShowCatalogCoder(), coordination: AlreadyCoordinated(), recovery: recovery)
        let migration = DocumentMigrator.show(publisher: publisher)
        #expect(throws: PublicationError.canceled) {
            try migration.migrate(url, key: .show(showID), expectedOriginal: original, isCanceled: { true })
        }
        #expect(try ops.read(url) == original)
        let receipt = try migration.migrate(url, key: .show(showID), expectedOriginal: original)
        #expect(try Data(contentsOf: receipt.backup) == original)
        let expected = ShowDocumentModel(show: Show(id: showID, title: "Previous show", notes: "Keep original notes"),
            speakers: [Speaker(id: speakerID, name: "Host", notes: "Keep speaker notes")])
        let decoded = try ShowPackageCoder().decode(ops.read(url))
        #expect(decoded.payload == expected)
        #expect(decoded.revision == 8)
        #expect(decoded.payload.show.fillerWords == nil && decoded.payload.speakers[0].fillerWords == nil)
        #expect(try recovery.migrationBackups(for: .show(showID)).count == 1)
        #expect(try recovery.validatedCheckpoints(for: .show(showID), coder: ShowCatalogCoder()).isEmpty)
    }

    @Test func strictPreviousReaderRefusesUnknownFieldsBeforeMigration() throws {
        #expect(throws: PersistenceError.unrecognizedContent) {
            try ShowCatalogMigration.preview(previousPackage(storage: 2, extraShowField: true))
        }
    }

    @Test func packageRoundTripPreservesOverridesAndRejectsMalformedVocabulary() throws {
        let speaker = Speaker(id: speakerID, name: "Host", fillerWords: try FillerWords([]))
        var model = ShowDocumentModel(show: Show(id: showID, title: "Show", fillerWords: try FillerWords(["like"])),
            speakers: [speaker])
        model.episodes = [Episode(title: "Synthetic", cleanup: .init(transcripts: []))]
        let coder = ShowCatalogCoder()
        let encoded = try coder.encode(ShowCatalog(model), revision: 1)
        #expect(try coder.decode(encoded).payload.materializedModel() == model)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(FillerWords.self, from: Data(#"{"words":["Like","um"]}"#.utf8))
        }
    }
}
