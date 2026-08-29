import Foundation
import MemoryStore

public enum ArchiveDeletionVectorCompactionComposition {
    public static func make(database: ArchiveDatabase) throws -> ArchiveDeletionVectorCompactor {
        let model = try VisualEmbeddingProducerIdentity.archiveVectorModel()
        let store = try ArchiveVectorStore(database: database)
        return ArchiveDeletionVectorCompactor { modelHashes in
            guard modelHashes == [model.modelHashHex] else {
                throw ArchiveVectorStoreError.wrongModel
            }
            _ = try store.compact(model: model)
        }
    }
}
