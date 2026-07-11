import Foundation

struct HorosManagedObjectReference: Hashable, Sendable {
    let uri: URL
}

enum HorosDatabaseEntity: String, CaseIterable, Sendable {
    case logEntry = "LogEntry"
    case study = "Study"
    case series = "Series"
    case image = "Image"
    case album = "Album"
}

struct HorosDatabaseCounts: Equatable, Sendable {
    let logEntries: Int
    let studies: Int
    let series: Int
    let images: Int
    let albums: Int
}

struct HorosStudyRecord: Equatable, Sendable {
    let reference: HorosManagedObjectReference
    let studyInstanceUID: String?
    let patientUID: String?
    let patientID: String?
    let patientName: String?
    let studyName: String?
    let modality: String?
    let date: Date?
    let numberOfImages: Int32?
    let comment: String?
    let comment2: String?
    let comment3: String?
    let comment4: String?
}

struct HorosSeriesRecord: Equatable, Sendable {
    let reference: HorosManagedObjectReference
    let studyReference: HorosManagedObjectReference
    let seriesInstanceUID: String?
    let seriesDICOMUID: String?
    let seriesDescription: String?
    let modality: String?
    let date: Date?
    let numberOfImages: Int32?
    let numberOfKeyImages: Int32?
}

struct HorosImageRecord: Equatable, Sendable {
    let reference: HorosManagedObjectReference
    let seriesReference: HorosManagedObjectReference?
    let pathString: String?
    let pathNumber: Int32?
    let frameID: Int32?
    let instanceNumber: Int32?
    let date: Date?
    let modality: String?
    let isKeyImage: Bool?
}

struct HorosAlbumRecord: Equatable, Sendable {
    let reference: HorosManagedObjectReference
    let name: String
    let predicateString: String?
    let isSmartAlbum: Bool
    let studyCount: Int
}

struct HorosStudyComments: Equatable, Sendable {
    let comment: String?
    let comment2: String?
    let comment3: String?
    let comment4: String?
}
