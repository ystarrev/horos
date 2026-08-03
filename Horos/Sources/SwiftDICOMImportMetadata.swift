import Foundation
import simd

struct SwiftDICOMImportSettings: @unchecked Sendable {
    let commentsFromDICOMFiles: Bool
    let autoFillComments: Bool
    let commentTags: [(group: Int, element: Int)]
    let splitMultiEchoMR: Bool
    let useSeriesDescription: Bool
    let omitLocalizers: Bool
    let localizerTerms: [String]
    let oneFilePerUltrasoundSeries: Bool
    let combineProjectionSeries: Bool
    let combineProjectionSeriesMode: Int
    let usePatientNameForUID: Bool
    let usePatientIDForUID: Bool
    let usePatientBirthDateForUID: Bool
    let hiddenImageSOPClassUIDs: Set<String>

    init(defaults: UserDefaults = .standard) {
        commentsFromDICOMFiles = defaults.bool(forKey: "CommentsFromDICOMFiles")
        autoFillComments = defaults.bool(forKey: "COMMENTSAUTOFILL")
        commentTags = [
            (defaults.integer(forKey: "COMMENTSGROUP"), defaults.integer(forKey: "COMMENTSELEMENT")),
            (defaults.integer(forKey: "COMMENTSGROUP2"), defaults.integer(forKey: "COMMENTSELEMENT2")),
            (defaults.integer(forKey: "COMMENTSGROUP3"), defaults.integer(forKey: "COMMENTSELEMENT3")),
            (defaults.integer(forKey: "COMMENTSGROUP4"), defaults.integer(forKey: "COMMENTSELEMENT4"))
        ].filter { $0.group != 0 && $0.element != 0 }
        splitMultiEchoMR = defaults.bool(forKey: "splitMultiEchoMR")
        useSeriesDescription = defaults.bool(forKey: "useSeriesDescription")
        omitLocalizers = defaults.bool(forKey: "NOLOCALIZER")
        localizerTerms = (defaults.string(forKey: "NOLOCALIZER_Strings") ?? "")
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
        oneFilePerUltrasoundSeries = defaults.bool(forKey: "oneFileOnSeriesForUS")
        combineProjectionSeries = defaults.bool(forKey: "combineProjectionSeries")
        combineProjectionSeriesMode = defaults.integer(forKey: "combineProjectionSeriesMode")
        usePatientNameForUID = defaults.bool(forKey: "UsePatientNameForUID")
        usePatientIDForUID = defaults.bool(forKey: "UsePatientIDForUID")
        usePatientBirthDateForUID = defaults.bool(forKey: "UsePatientBirthDateForUID")
        hiddenImageSOPClassUIDs = Set(defaults.stringArray(forKey: "hiddenDisplayedStorageSOPClassUIDArray") ?? [])
    }
}

enum SwiftDICOMImportMetadata {
    static func dictionary(
        fileAtPath path: String,
        settings: SwiftDICOMImportSettings
    ) -> NSMutableDictionary? {
        do {
            let reader = try SwiftDICOMReader(contentsOfFile: path)
            return buildDictionary(reader: reader, path: path, settings: settings)
        } catch {
            NSLog("Swift DICOM import metadata: %@ (%@)", error.localizedDescription, path)
            return nil
        }
    }

    private static func buildDictionary(
        reader: SwiftDICOMReader,
        path: String,
        settings: SwiftDICOMImportSettings
    ) -> NSMutableDictionary? {
        var values: [String: Any] = [
            "fileType": "DICOM",
            "filePath": path,
            "numberOfFrames": reader.numberOfFrames,
            "numberOfSeries": 1,
            "hasDICOM": true
        ]

        let sopClassUID = reader.stringValue(forTag: "0008,0016")
        let sopInstanceUID = reader.stringValue(forTag: "0008,0018")
        if let sopClassUID { values["SOPClassUID"] = sopClassUID }
        if let sopInstanceUID { values["SOPUID"] = sopInstanceUID }
        if let creatorUID = reader.stringValue(forTag: "0002,0100") {
            values["PrivateInformationCreatorUID"] = creatorUID
        }

        let imageTypeComponents = (reader.stringValue(forTag: "0008,0008") ?? "")
            .components(separatedBy: "\\")
            .filter { $0.isEmpty == false }
        let imageType = imageTypeComponents.count > 2 ? imageTypeComponents[2] : nil
        if let imageType { values["imageType"] = imageType }

        let patientName = sanitized(reader.stringValue(forTag: "0010,0010"))
        let patientID = reader.stringValue(forTag: "0010,0020")
        let displayName = patientName ?? patientID ?? "No name"
        if let patientName { values["patientName"] = patientName }
        if let patientID { values["patientID"] = patientID }

        let patientBirthDateText = reader.stringValue(forTag: "0010,0030")
        let patientBirthDate = parsedDate(date: patientBirthDateText, time: nil, defaultHour: 0)
        if let patientBirthDate { values["patientBirthDate"] = patientBirthDate }
        if let patientAge = reader.stringValue(forTag: "0010,1010") { values["patientAge"] = patientAge }
        if let patientSex = reader.stringValue(forTag: "0010,0040") { values["patientSex"] = patientSex }

        let studyDescription = sanitized(reader.stringValue(forTag: "0008,1030")) ?? "unnamed"
        values["studyDescription"] = studyDescription

        let structuredReport = isStructuredReport(sopClassUID)
        let modality = reader.stringValue(forTag: "0008,0060") ?? (structuredReport ? "SR" : "OT")
        values["modality"] = modality

        let studyDateText = firstValue(reader, tags: ["0008,0022", "0008,0023", "0008,0021", "0008,0020"])
        let studyTimeText = firstNonzeroTime(reader, tags: ["0008,0032", "0008,0033", "0008,0031", "0008,0030"])
        let studyDate = parsedDate(date: studyDateText, time: studyTimeText, defaultHour: 12) ?? fallbackDate()
        values["studyDate"] = studyDate

        var parsedSeriesDescription = sanitized(firstValue(reader, tags: ["0008,103e", "0040,0254", "0018,1400"]))
        if parsedSeriesDescription == nil && structuredReport {
            parsedSeriesDescription = "Structured Report"
        }
        let seriesDescription = parsedSeriesDescription ?? "unnamed"
        values["seriesDescription"] = seriesDescription

        if let institution = sanitized(reader.stringValue(forTag: "0008,0080")) {
            values["institutionName"] = institution
        }
        if let referringPhysician = sanitized(reader.stringValue(forTag: "0008,0090")) {
            values["referringPhysician"] = referringPhysician
            values["referringPhysiciansName"] = referringPhysician
        }
        if let performingPhysician = sanitized(reader.stringValue(forTag: "0008,1050")) {
            values["performingPhysician"] = performingPhysician
            values["performingPhysiciansName"] = performingPhysician
        }
        if let accessionNumber = sanitized(reader.stringValue(forTag: "0008,0050")) {
            values["accessionNumber"] = accessionNumber
        }
        if let scanOptions = reader.stringValue(forTag: "0018,0022") { values["scanOptions"] = scanOptions }
        if let protocolName = sanitized(reader.stringValue(forTag: "0018,1030")) { values["protocolName"] = protocolName }
        let echoTime = reader.stringValue(forTag: "0018,0081")
        if let echoTime { values["echoTime"] = echoTime }

        let rows = reader.integerValue(forTag: "0028,0010") ?? 0
        let columns = reader.integerValue(forTag: "0028,0011") ?? 0
        let nonImageObject = isDatabaseNonImageObject(
            sopClassUID,
            hiddenImageSOPClassUIDs: settings.hiddenImageSOPClassUIDs
        )
        let height = rows > 0 ? rows : (nonImageObject ? 1 : 0)
        let width = columns > 0 ? columns : (nonImageObject ? 1 : 0)
        guard height > 0, width > 0 else {
            return nil
        }
        values["height"] = height
        values["width"] = width

        let firstGeometry = reader.frameGeometryAttributes(at: 0)
        let sliceLocation = firstGeometry.map(location) ?? 0
        values["sliceLocation"] = sliceLocation

        var imageIDString = reader.stringValue(forTag: "0020,0013")
        var imageID = integerPrefix(imageIDString)
        if imageIDString == nil || imageID >= 99_999 {
            if ["MR", "CT", "US"].contains(modality),
               let declaredLocation = reader.numberValue(forTag: "0020,1041") {
                imageID = 10_000 + Int(declaredLocation * 10)
                imageIDString = String(format: "%5d", imageID)
            }
        }
        if imageIDString == nil || imageID >= 99_999 {
            imageID = 10_000 + Int(sliceLocation * 10)
            imageIDString = String(format: "%5d", imageID)
        }
        values["imageID"] = imageID

        let seriesNumberString = reader.stringValue(forTag: "0020,0011") ?? "0"
        let seriesNumber = integerPrefix(seriesNumberString)
        values["seriesNumber"] = seriesNumber

        let rawSeriesUID = reader.stringValue(forTag: "0020,000e")
        if let rawSeriesUID { values["seriesDICOMUID"] = rawSeriesUID }
        var seriesID = rawSeriesUID ?? displayName
        seriesID = String(format: "%08d", seriesNumber) + " " + seriesID
        if settings.useSeriesDescription, let imageType {
            seriesID += " " + imageType
        }
        if settings.useSeriesDescription {
            seriesID += " " + seriesDescription
        }
        if let sopClassUID, settings.hiddenImageSOPClassUIDs.contains(sopClassUID) {
            seriesID += " " + sopClassUID
        }
        if settings.splitMultiEchoMR, let echoTime {
            seriesID += " TE-" + echoTime
        }

        let studyID = reader.stringValue(forTag: "0020,000d") ?? displayName
        values["studyID"] = studyID
        values["studyNumber"] = reader.stringValue(forTag: "0020,0010") ?? "0"

        if reader.numberOfFrames > 1 {
            seriesID += "-\(imageIDString ?? String(imageID))-\(sopInstanceUID ?? "(null)")"
        }

        let isLocalizer = settings.omitLocalizers
            && reader.numberOfFrames <= 1
            && (imageTypeComponents.contains("LOCALIZER")
                || imageTypeComponents.contains("REF")
                || settings.localizerTerms.contains { term in
                    seriesDescription.range(of: term, options: .caseInsensitive) != nil
                })
            && rows > 0 && columns > 0
        if isLocalizer {
            seriesID = "LOCALIZER"
            values["seriesDescription"] = "Localizers"
            values["seriesDICOMUID"] = "LOCALIZER" + studyID
        }

        if modality == "US" && settings.oneFilePerUltrasoundSeries {
            values["seriesID"] = seriesID + URL(fileURLWithPath: path).lastPathComponent
        } else if settings.combineProjectionSeries && projectionModalities.contains(modality) {
            switch settings.combineProjectionSeriesMode {
            case 0:
                let hiddenImage = sopClassUID.map { settings.hiddenImageSOPClassUIDs.contains($0) } ?? false
                values["seriesID"] = hiddenImage ? seriesID : studyID
                values["imageID"] = integerPrefix(seriesID) * 1_000 + imageID
            case 1:
                values["seriesID"] = seriesID + (imageIDString ?? String(imageID))
            default:
                values["seriesID"] = seriesID
            }
        } else {
            values["seriesID"] = seriesID
        }

        values["patientUID"] = patientUID(
            patientName: patientName,
            patientID: patientID,
            patientBirthDate: patientBirthDate,
            settings: settings
        )

        appendFrameMetadata(reader: reader, to: &values)
        appendComments(reader: reader, settings: settings, to: &values)
        appendStructuredReportReference(reader: reader, structuredReport: structuredReport, to: &values)

        return NSMutableDictionary(dictionary: values)
    }

    private static func appendFrameMetadata(reader: SwiftDICOMReader, to values: inout [String: Any]) {
        guard reader.numberOfFrames > 1 else { return }

        var locations: [NSNumber] = []
        var triggers: [String] = []
        for frameIndex in 0..<reader.numberOfFrames {
            let dynamic = reader.dynamicFrameAttributes(at: frameIndex)
            if dynamic?.position != nil, let geometry = reader.frameGeometryAttributes(at: frameIndex) {
                locations.append(NSNumber(value: location(geometry)))
            }
            if let trigger = dynamic?.triggerMilliseconds {
                triggers.append(String(format: "%f", trigger))
            }
        }
        if locations.count == reader.numberOfFrames {
            values["sliceLocationArray"] = locations
        }
        if triggers.count == reader.numberOfFrames {
            values["imageCommentPerFrame"] = triggers
        }
    }

    private static func appendComments(
        reader: SwiftDICOMReader,
        settings: SwiftDICOMImportSettings,
        to values: inout [String: Any]
    ) {
        if settings.autoFillComments {
            let parts = settings.commentTags.compactMap { tag -> String? in
                let tagString = String(format: "%04X,%04X", tag.group, tag.element)
                return sanitized(reader.stringValue(forTag: tagString))
            }
            if parts.isEmpty == false {
                values["commentsAutoFill"] = parts.joined(separator: " / ")
            }
        }

        if settings.commentsFromDICOMFiles {
            if let studyComments = reader.stringValue(forTag: "0032,4000") {
                values["studyComments"] = studyComments
            }
            if let seriesComments = reader.stringValue(forTag: "0020,4000") {
                values["seriesComments"] = seriesComments
            }
            if let state = reader.integerValue(forTag: "4008,0212") {
                values["stateText"] = state
            }
        }
    }

    private static func appendStructuredReportReference(
        reader: SwiftDICOMReader,
        structuredReport: Bool,
        to values: inout [String: Any]
    ) {
        guard structuredReport,
              var referencedUID = reader.firstStringValue(forTag: "0008,1155") else {
            return
        }
        if let frame = reader.firstStringValue(forTag: "0008,1160"), integerPrefix(frame) > 0 {
            referencedUID += "-\(integerPrefix(frame))"
        }
        values["referencedSOPInstanceUID"] = referencedUID
    }

    private static func firstValue(_ reader: SwiftDICOMReader, tags: [String]) -> String? {
        for tag in tags {
            if let value = reader.stringValue(forTag: tag) {
                return value
            }
        }
        return nil
    }

    private static func firstNonzeroTime(_ reader: SwiftDICOMReader, tags: [String]) -> String? {
        for tag in tags {
            if let value = reader.stringValue(forTag: tag),
               (Double(value.replacingOccurrences(of: ":", with: "")) ?? 0) > 0 {
                return value
            }
        }
        return nil
    }

    private static func parsedDate(date: String?, time: String?, defaultHour: Int) -> Date? {
        guard var date else { return nil }
        if date.count != 8 {
            date = date.replacingOccurrences(of: ".", with: "")
        }
        guard date.count >= 8,
              let year = Int(date.prefix(4)),
              let month = Int(date.dropFirst(4).prefix(2)),
              let day = Int(date.dropFirst(6).prefix(2)) else {
            return nil
        }

        let normalizedTime = time?.replacingOccurrences(of: ":", with: "") ?? ""
        let hour = normalizedTime.count >= 2 ? Int(normalizedTime.prefix(2)) ?? defaultHour : defaultHour
        let minute = normalizedTime.count >= 4 ? Int(normalizedTime.dropFirst(2).prefix(2)) ?? 0 : 0
        let second = normalizedTime.count >= 6 ? Int(normalizedTime.dropFirst(4).prefix(2)) ?? 0 : 0
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        var components = DateComponents()
        components.timeZone = .current
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        return calendar.date(from: components)
    }

    private static func fallbackDate() -> Date {
        parsedDate(date: "19010101", time: nil, defaultHour: 0) ?? Date(timeIntervalSinceReferenceDate: 0)
    }

    private static func patientUID(
        patientName: String?,
        patientID: String?,
        patientBirthDate: Date?,
        settings: SwiftDICOMImportSettings
    ) -> String {
        var name = settings.usePatientNameForUID ? patientName : ""
        name = name?.replacingOccurrences(of: "-", with: " ")
        name = name?.components(separatedBy: "=").first
        let namePart = settings.usePatientNameForUID ? (name ?? "(null)") : ""
        let idPart = settings.usePatientIDForUID ? (patientID ?? "(null)") : ""

        let birthPart: String
        if settings.usePatientBirthDateForUID {
            let date = patientBirthDate ?? Date(timeIntervalSinceReferenceDate: 0)
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .current
            let components = calendar.dateComponents([.year, .month, .day], from: date)
            birthPart = String(format: "%04d%02d%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
        } else {
            birthPart = ""
        }
        return sanitized("\(namePart)-\(idPart)-\(birthPart)")?.uppercased() ?? ""
    }

    private static func sanitized(_ value: String?) -> String? {
        guard var value else { return nil }
        value = value.replacingOccurrences(of: ",", with: " ")
        value = value.replacingOccurrences(of: "^", with: " ")
        value = value.replacingOccurrences(of: "/", with: "-")
        value = value.replacingOccurrences(of: "\r", with: "")
        value = value.replacingOccurrences(of: "\n", with: "")
        value = value.replacingOccurrences(of: "\"", with: "'")
        while value.contains("  ") {
            value = value.replacingOccurrences(of: "  ", with: " ")
        }
        while value.hasSuffix(" ") {
            value.removeLast()
        }
        return value.isEmpty ? nil : value
    }

    private static func integerPrefix(_ value: String?) -> Int {
        guard let value else { return 0 }
        let trimmed = value.drop(while: { $0.isWhitespace })
        var characters = ""
        for character in trimmed {
            if character == "-" && characters.isEmpty {
                characters.append(character)
            } else if character.isNumber {
                characters.append(character)
            } else {
                break
            }
        }
        return Int(characters) ?? 0
    }

    private static func location(_ geometry: SwiftDICOMFrameGeometryAttributes) -> Double {
        let normal = simd_cross(geometry.row, geometry.column)
        let absolute = SIMD3<Double>(abs(normal.x), abs(normal.y), abs(normal.z))
        if absolute.x > absolute.y && absolute.x > absolute.z { return geometry.origin.x }
        if absolute.y > absolute.x && absolute.y > absolute.z { return geometry.origin.y }
        if absolute.z > absolute.x && absolute.z > absolute.y { return geometry.origin.z }
        return 0
    }

    private static func isStructuredReport(_ sopClassUID: String?) -> Bool {
        sopClassUID?.hasPrefix("1.2.840.10008.5.1.4.1.1.88.") == true
    }

    private static func isEncapsulatedDocument(_ sopClassUID: String?) -> Bool {
        sopClassUID?.hasPrefix("1.2.840.10008.5.1.4.1.1.104.") == true
    }

    private static func isDatabaseNonImageObject(
        _ sopClassUID: String?,
        hiddenImageSOPClassUIDs: Set<String>
    ) -> Bool {
        guard let sopClassUID else { return false }
        if hiddenImageSOPClassUIDs.contains(sopClassUID) { return true }
        if isStructuredReport(sopClassUID) || isEncapsulatedDocument(sopClassUID) { return true }

        let storageRoot = "1.2.840.10008.5.1.4.1.1."
        return sopClassUID == "1.2.840.10008.1.3.10"                    // DICOMDIR
            || sopClassUID.hasPrefix(storageRoot + "9.")               // Waveforms
            || sopClassUID == storageRoot + "8"                        // Standalone overlay
            || sopClassUID == storageRoot + "10"                       // Standalone curve/LUT
            || sopClassUID == storageRoot + "11"                       // Standalone VOI LUT
            || sopClassUID.hasPrefix(storageRoot + "11.")              // Presentation states
            || sopClassUID == storageRoot + "129"                      // Standalone PET curve
            || sopClassUID.hasPrefix(storageRoot + "481.")             // Radiotherapy objects
            || sopClassUID == storageRoot + "4.2"                      // MR spectroscopy
            || sopClassUID == storageRoot + "66"                       // Raw data
            || sopClassUID.hasPrefix(storageRoot + "66.")              // Registration/fiducials/surfaces
    }

    private static let projectionModalities: Set<String> = ["MG", "CR", "DR", "DX", "RF"]
}
