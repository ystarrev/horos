import CoreData
import Foundation

enum HorosLegacyDataStoreAccess: Sendable {
    case readOnly
    case readWrite

    var allowsWrites: Bool {
        self == .readWrite
    }
}

enum HorosDataStoreError: Error {
    case invalidManagedObjectModel(URL)
    case persistentStoreDidNotLoad
    case missingPersistentStoreCoordinator
    case readOnlyStore
    case invalidObjectReference(URL)
    case unexpectedEntity(String)
}

final class HorosLegacyDataStore: @unchecked Sendable {
    let container: NSPersistentContainer
    let backgroundRepository: HorosBackgroundDataRepository

    private init(
        container: NSPersistentContainer,
        allowsWrites: Bool
    ) {
        self.container = container
        backgroundRepository = HorosBackgroundDataRepository(
            coordinator: container.persistentStoreCoordinator,
            allowsWrites: allowsWrites
        )
    }

    static func open(
        databaseURL: URL,
        modelURL: URL,
        access: HorosLegacyDataStoreAccess
    ) async throws -> HorosLegacyDataStore {
        guard let model = NSManagedObjectModel(contentsOf: modelURL) else {
            throw HorosDataStoreError.invalidManagedObjectModel(modelURL)
        }

        let container = NSPersistentContainer(
            name: "OsiriXDB_DataModel",
            managedObjectModel: model
        )
        let description = NSPersistentStoreDescription(url: databaseURL)
        description.type = NSSQLiteStoreType
        description.shouldAddStoreAsynchronously = true
        description.setOption(
            NSNumber(value: !access.allowsWrites),
            forKey: NSReadOnlyPersistentStoreOption
        )
        description.setOption(
            NSNumber(value: false),
            forKey: NSMigratePersistentStoresAutomaticallyOption
        )
        description.setOption(
            NSNumber(value: false),
            forKey: NSInferMappingModelAutomaticallyOption
        )
        description.setOption(
            ["journal_mode": "delete"] as NSDictionary,
            forKey: NSSQLitePragmasOption
        )
        container.persistentStoreDescriptions = [description]

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            container.loadPersistentStores { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }

        guard container.persistentStoreCoordinator.persistentStores.count == 1 else {
            throw HorosDataStoreError.persistentStoreDidNotLoad
        }

        await MainActor.run {
            let context = container.viewContext
            context.name = "Horos main-queue context"
            context.mergePolicy = NSMergePolicy(
                merge: .mergeByPropertyStoreTrumpMergePolicyType
            )
            context.undoManager = nil
            context.automaticallyMergesChangesFromParent = true
        }

        return HorosLegacyDataStore(
            container: container,
            allowsWrites: access.allowsWrites
        )
    }

    static func bundledModelURL(in bundle: Bundle = .main) -> URL? {
        bundle.url(
            forResource: "OsiriXDB_DataModel",
            withExtension: "momd"
        ) ?? bundle.url(
            forResource: "OsiriXDB_DataModel",
            withExtension: "mom"
        )
    }

    @MainActor
    func makeMainRepository() -> HorosMainDataRepository {
        HorosMainDataRepository(context: container.viewContext)
    }
}

/// Queue-confined repositories attached to an already-open Horos store.
///
/// This is the incremental integration path for the existing application: new
/// Swift code can share its persistent store coordinator without sharing any
/// of the legacy confinement contexts or their manual locks.
final class HorosDataRepositories: @unchecked Sendable {
    let background: HorosBackgroundDataRepository

    private let coordinator: NSPersistentStoreCoordinator

    init(
        attachingTo context: NSManagedObjectContext,
        access: HorosLegacyDataStoreAccess = .readOnly
    ) throws {
        guard let coordinator = context.persistentStoreCoordinator else {
            throw HorosDataStoreError.missingPersistentStoreCoordinator
        }

        self.coordinator = coordinator
        background = HorosBackgroundDataRepository(
            coordinator: coordinator,
            allowsWrites: access.allowsWrites
        )
    }

    @MainActor
    func makeMainRepository() -> HorosMainDataRepository {
        let context = NSManagedObjectContext(
            concurrencyType: .mainQueueConcurrencyType
        )
        context.name = "Horos attached main-queue repository context"
        context.persistentStoreCoordinator = coordinator
        context.mergePolicy = NSMergePolicy(
            merge: .mergeByPropertyStoreTrumpMergePolicyType
        )
        context.undoManager = nil
        return HorosMainDataRepository(context: context)
    }
}

actor HorosBackgroundDataRepository {
    private let context: NSManagedObjectContext
    private let coordinator: NSPersistentStoreCoordinator
    private let allowsWrites: Bool

    init(
        coordinator: NSPersistentStoreCoordinator,
        allowsWrites: Bool
    ) {
        context = NSManagedObjectContext(
            concurrencyType: .privateQueueConcurrencyType
        )
        context.name = "Horos background repository context"
        context.persistentStoreCoordinator = coordinator
        context.mergePolicy = NSMergePolicy(
            merge: .mergeByPropertyObjectTrumpMergePolicyType
        )
        context.undoManager = nil
        self.coordinator = coordinator
        self.allowsWrites = allowsWrites
    }

    func databaseCounts() async throws -> HorosDatabaseCounts {
        return try await context.perform {
            HorosDatabaseCounts(
                logEntries: try count(.logEntry, in: self.context),
                studies: try count(.study, in: self.context),
                series: try count(.series, in: self.context),
                images: try count(.image, in: self.context),
                albums: try count(.album, in: self.context)
            )
        }
    }

    func fetchStudies(limit: Int? = nil) async throws -> [HorosStudyRecord] {
        return try await context.perform {
            let request = NSFetchRequest<NSManagedObject>(
                entityName: HorosDatabaseEntity.study.rawValue
            )
            request.sortDescriptors = [
                NSSortDescriptor(key: "date", ascending: false),
            ]
            if let limit {
                request.fetchLimit = limit
            }

            return try self.context.fetch(request).map(makeStudyRecord)
        }
    }

    func fetchSeries(
        for study: HorosManagedObjectReference
    ) async throws -> [HorosSeriesRecord] {
        let context = context
        let coordinator = coordinator
        return try await context.perform {
            let studyObject = try managedObject(
                for: study,
                coordinator: coordinator,
                context: context
            )
            let request = NSFetchRequest<NSManagedObject>(
                entityName: HorosDatabaseEntity.series.rawValue
            )
            request.predicate = NSPredicate(format: "study == %@", studyObject)
            request.sortDescriptors = [
                NSSortDescriptor(key: "date", ascending: true),
                NSSortDescriptor(key: "id", ascending: true),
            ]

            return try self.context.fetch(request).map(makeSeriesRecord)
        }
    }

    func fetchImages(
        for series: HorosManagedObjectReference
    ) async throws -> [HorosImageRecord] {
        let context = context
        let coordinator = coordinator
        return try await context.perform {
            let seriesObject = try managedObject(
                for: series,
                coordinator: coordinator,
                context: context
            )
            let request = NSFetchRequest<NSManagedObject>(
                entityName: HorosDatabaseEntity.image.rawValue
            )
            request.predicate = NSPredicate(format: "series == %@", seriesObject)
            request.sortDescriptors = [
                NSSortDescriptor(key: "instanceNumber", ascending: true),
                NSSortDescriptor(key: "frameID", ascending: true),
            ]

            return try self.context.fetch(request).map(makeImageRecord)
        }
    }

    func fetchAlbums() async throws -> [HorosAlbumRecord] {
        try await context.perform {
            let request = NSFetchRequest<NSManagedObject>(
                entityName: HorosDatabaseEntity.album.rawValue
            )
            request.sortDescriptors = [
                NSSortDescriptor(key: "index", ascending: true),
                NSSortDescriptor(key: "name", ascending: true),
            ]

            return try self.context.fetch(request).map(makeAlbumRecord)
        }
    }

    func updateStudyComments(
        _ comments: HorosStudyComments,
        for study: HorosManagedObjectReference
    ) async throws {
        guard allowsWrites else {
            throw HorosDataStoreError.readOnlyStore
        }

        let context = context
        let coordinator = coordinator
        try await context.perform {
            let object = try managedObject(
                for: study,
                coordinator: coordinator,
                context: context
            )
            guard object.entity.name == HorosDatabaseEntity.study.rawValue else {
                throw HorosDataStoreError.unexpectedEntity(
                    object.entity.name ?? "nil"
                )
            }

            object.setValue(comments.comment, forKey: "comment")
            object.setValue(comments.comment2, forKey: "comment2")
            object.setValue(comments.comment3, forKey: "comment3")
            object.setValue(comments.comment4, forKey: "comment4")
            try context.save()
        }
    }
}

@MainActor
final class HorosMainDataRepository {
    private let context: NSManagedObjectContext

    init(context: NSManagedObjectContext) {
        precondition(
            context.concurrencyType == .mainQueueConcurrencyType,
            "HorosMainDataRepository requires a main-queue context"
        )
        self.context = context
    }

    func fetchStudy(
        _ reference: HorosManagedObjectReference
    ) async throws -> HorosStudyRecord? {
        try await context.perform {
            guard let objectID = self.context.persistentStoreCoordinator?
                .managedObjectID(forURIRepresentation: reference.uri)
            else {
                throw HorosDataStoreError.invalidObjectReference(reference.uri)
            }

            let object = try self.context.existingObject(with: objectID)
            guard object.entity.name == HorosDatabaseEntity.study.rawValue else {
                throw HorosDataStoreError.unexpectedEntity(
                    object.entity.name ?? "nil"
                )
            }

            return makeStudyRecord(object)
        }
    }
}

private func count(
    _ entity: HorosDatabaseEntity,
    in context: NSManagedObjectContext
) throws -> Int {
    let request = NSFetchRequest<NSFetchRequestResult>(
        entityName: entity.rawValue
    )
    return try context.count(for: request)
}

private func managedObject(
    for reference: HorosManagedObjectReference,
    coordinator: NSPersistentStoreCoordinator,
    context: NSManagedObjectContext
) throws -> NSManagedObject {
    guard let objectID = coordinator.managedObjectID(
        forURIRepresentation: reference.uri
    ) else {
        throw HorosDataStoreError.invalidObjectReference(reference.uri)
    }

    return try context.existingObject(with: objectID)
}

private func makeReference(
    _ object: NSManagedObject
) -> HorosManagedObjectReference {
    HorosManagedObjectReference(uri: object.objectID.uriRepresentation())
}

private func makeStudyRecord(
    _ object: NSManagedObject
) -> HorosStudyRecord {
    HorosStudyRecord(
        reference: makeReference(object),
        studyInstanceUID: object.value(forKey: "studyInstanceUID") as? String,
        patientUID: object.value(forKey: "patientUID") as? String,
        patientID: object.value(forKey: "patientID") as? String,
        patientName: object.value(forKey: "name") as? String,
        studyName: object.value(forKey: "studyName") as? String,
        modality: object.value(forKey: "modality") as? String,
        date: object.value(forKey: "date") as? Date,
        numberOfImages: int32Value(object, key: "numberOfImages"),
        comment: object.value(forKey: "comment") as? String,
        comment2: object.value(forKey: "comment2") as? String,
        comment3: object.value(forKey: "comment3") as? String,
        comment4: object.value(forKey: "comment4") as? String
    )
}

private func makeSeriesRecord(
    _ object: NSManagedObject
) -> HorosSeriesRecord {
    let study = object.value(forKey: "study") as! NSManagedObject
    return HorosSeriesRecord(
        reference: makeReference(object),
        studyReference: makeReference(study),
        seriesInstanceUID: object.value(forKey: "seriesInstanceUID") as? String,
        seriesDICOMUID: object.value(forKey: "seriesDICOMUID") as? String,
        seriesDescription: object.value(forKey: "seriesDescription") as? String,
        modality: object.value(forKey: "modality") as? String,
        date: object.value(forKey: "date") as? Date,
        numberOfImages: int32Value(object, key: "numberOfImages"),
        numberOfKeyImages: int32Value(object, key: "numberOfKeyImages")
    )
}

private func makeImageRecord(
    _ object: NSManagedObject
) -> HorosImageRecord {
    let series = object.value(forKey: "series") as? NSManagedObject
    return HorosImageRecord(
        reference: makeReference(object),
        seriesReference: series.map(makeReference),
        pathString: object.value(forKey: "pathString") as? String,
        pathNumber: int32Value(object, key: "pathNumber"),
        frameID: int32Value(object, key: "frameID"),
        instanceNumber: int32Value(object, key: "instanceNumber"),
        date: object.value(forKey: "date") as? Date,
        modality: object.value(forKey: "storedModality") as? String,
        isKeyImage: boolValue(object, key: "storedIsKeyImage")
    )
}

private func makeAlbumRecord(
    _ object: NSManagedObject
) -> HorosAlbumRecord {
    let studies = object.value(forKey: "studies") as? Set<NSManagedObject>
    return HorosAlbumRecord(
        reference: makeReference(object),
        name: object.value(forKey: "name") as? String ?? "",
        predicateString: object.value(forKey: "predicateString") as? String,
        isSmartAlbum: boolValue(object, key: "smartAlbum") ?? false,
        studyCount: studies?.count ?? 0
    )
}

private func int32Value(
    _ object: NSManagedObject,
    key: String
) -> Int32? {
    (object.value(forKey: key) as? NSNumber)?.int32Value
}

private func boolValue(
    _ object: NSManagedObject,
    key: String
) -> Bool? {
    (object.value(forKey: key) as? NSNumber)?.boolValue
}
