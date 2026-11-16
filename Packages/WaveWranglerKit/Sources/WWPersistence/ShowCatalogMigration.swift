import Foundation
import WWCore

public enum ShowCatalogMigration {
    /// Strict original-schema decoding for the consent screen and independent migration expectations.
    public static func original(_ data: Data) throws -> DecodedDocument<ShowDocumentModel> {
        try ShowPackage.decode(data, allowingPreviousModel: true)
    }

    /// Read-only preview; only DocumentMigrator may publish this upgrade after consent.
    public static func preview(_ data: Data) throws -> DecodedDocument<ShowDocumentModel> {
        let decoded = try original(data)
        var model = decoded.payload
        model.schemaVersion = SchemaVersion.show
        return DecodedDocument(payload: model, publication: decoded.publication)
    }

    /// Exceptional read-only recovery can materialize older supported records without publishing them.
    public static func recoveryCatalog(_ data: Data) throws -> DecodedDocument<ShowCatalog> {
        let storage = try ShowPackage.storageVersion(of: data)
        if RevisionFingerprint(of: data).schemaVersion == 14 || storage == 1 {
            let decoded = try preview(data)
            return DecodedDocument(payload: try ShowCatalog(decoded.payload), publication: decoded.publication)
        }
        return try ShowCatalogCoder().decode(data)
    }
}

extension DocumentMigrator where Coder == ShowCatalogCoder {
    /// Explicit supported model/storage upgrades, retaining exact originals before publication.
    /// Register future package/model upgrades here with independent expectations. The shared migrator
    /// owns consent-time base checks, nonoverwriting backups and verified publication.
    public static func show(publisher: DocumentPublisher<ShowCatalogCoder>) -> Self {
        let upgrade = MigrationStep<ShowCatalog>(fromSchema: 14, migrate: { original in
            let decoded = try ShowCatalogMigration.preview(original)
            return (try ShowCatalog(decoded.payload), decoded.revision)
        }, expectations: { original, catalog in
            do {
                let before = try ShowCatalogMigration.original(original).payload
                var after = try catalog.materializedModel()
                guard after.schemaVersion == 15, after.show.fillerWords == nil,
                      after.speakers.allSatisfy({ $0.fillerWords == nil }) else {
                    return ["Filler-word migration invented configuration or used the wrong schema"]
                }
                after.schemaVersion = 14
                return before == after ? [] : ["Filler-word migration changed existing document content"]
            } catch {
                return ["Cannot independently verify filler-word migration: \(error.localizedDescription)"]
            }
        })
        let storage = MigrationStep<ShowCatalog>(fromSchema: SchemaVersion.show, migrate: { original in
            guard try ShowPackage.storageVersion(of: original) == 1 else {
                throw PersistenceError.malformed("Expected a version-1 show package")
            }
            let decoded = try ShowPackageCoder().decode(original)
            return (try ShowCatalog(decoded.payload), decoded.revision)
        }, expectations: { original, catalog in
            do {
                let before = try ShowPackageCoder().decode(original).payload
                let after = try catalog.materializedModel()
                return before == after ? [] : ["Indexed package conversion changed document content"]
            } catch {
                return ["Cannot independently verify indexed package conversion: \(error.localizedDescription)"]
            }
        })
        return Self(publisher: publisher, steps: [upgrade, storage],
            identify: { (try? ShowCatalogMigration.original($0)).map { .show($0.payload.show.id) } })
    }
}
