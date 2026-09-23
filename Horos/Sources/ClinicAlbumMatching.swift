import Foundation

struct ClinicStudy: Sendable, Equatable {
    let uri: String
    let name: String
    let patientID: String
    let patientUID: String
    let birthDate: Date?
    let sex: String
}

struct ClinicName: Sendable {
    var name: String
    var patientID: String? = nil
    var age: Int?
    var sex: String?
    var confidence: Float

    var searchQuery: String {
        patientID.map { "\(name) ULI: \($0)" } ?? name
    }
}

enum ClinicAlbumMatching {
    static func nameKey(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                      locale: Locale(identifier: "en_US_POSIX"))
            .uppercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func searchName(_ query: String) -> String {
        // Preserve hyphens and apostrophes: the database predicate matches those literally.
        let normalized = query.replacingOccurrences(of: "^", with: " ")
            .replacingOccurrences(of: ",", with: " ").replacingOccurrences(of: ".", with: " ")
            .uppercased()
        var tokens = normalized.split(whereSeparator: { $0.isWhitespace })
        // Clinic lists often include middle initials absent from the DICOM name.
        while tokens.count > 2 && tokens.last?.count == 1 { tokens.removeLast() }
        return tokens.joined(separator: " ")
    }

    static func warnings(for source: ClinicName, studies: [ClinicStudy], on date: Date) -> [String] {
        var result = Set<String>()
        if source.confidence < 0.9 { result.insert("Check OCR") }
        if let id = source.patientID, !studies.isEmpty, !studies.contains(where: { $0.patientID == id }) {
            result.insert("ULI not found; matched by name")
        }
        for record in studies {
            if record.patientID.isEmpty { result.insert("Patient ID missing") }
            if source.age != nil && record.birthDate == nil { result.insert("DOB unavailable") }
            if let sex = source.sex, !record.sex.isEmpty,
               sex.uppercased() != record.sex.uppercased() { result.insert("Sex differs") }
            if let age = source.age, let birth = record.birthDate,
               let years = Calendar.current.dateComponents([.year], from: birth, to: date).year,
               years != age { result.insert("Age differs (database: \(years))") }
        }
        return result.sorted()
    }

    static func names(from lines: [(String, Float)]) -> [ClinicName] {
        let numbering = try! NSRegularExpression(pattern: #"^\s*\d+[.)]\s*"#)
        let identifier = try! NSRegularExpression(pattern: #"(?i)\bULI\s*:\s*([0-9]+)\s*[.]?\s*$"#)
        let demographics = try! NSRegularExpression(
            pattern: #"(?i)\b(\d{1,3})\s*(?:y\s*\.?\s*o\s*\.?|years?\s*old|yrs?)\s*/\s*([MF])\b"#)
        var result: [ClinicName] = []
        for (raw, confidence) in lines {
            let text = numbering.stringByReplacingMatches(in: raw, range: NSRange(raw.startIndex..., in: raw), withTemplate: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let range = NSRange(text.startIndex..., in: text)
            if let match = identifier.firstMatch(in: text, range: range),
               let idRange = Range(match.range(at: 1), in: text),
               let fullRange = Range(match.range, in: text) {
                let name = String(text[..<fullRange.lowerBound]).trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".")))
                if isName(name) {
                    result.append(ClinicName(name: name, patientID: String(text[idRange]), confidence: confidence))
                } else if name.isEmpty, let last = result.indices.last, result[last].patientID == nil {
                    // OCR can put the identifier on a separate line immediately after the name.
                    result[last].patientID = String(text[idRange])
                    result[last].confidence = min(result[last].confidence, confidence)
                }
            } else if let match = demographics.firstMatch(in: text, range: range),
               let ageRange = Range(match.range(at: 1), in: text),
               let sexRange = Range(match.range(at: 2), in: text),
               let fullRange = Range(match.range, in: text) {
                let preceding = String(text[..<fullRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                if isName(preceding) {
                    result.append(ClinicName(name: preceding, confidence: confidence))
                }
                if let last = result.indices.last, result[last].age == nil {
                    result[last].age = Int(text[ageRange])
                    result[last].sex = String(text[sexRange]).uppercased()
                    result[last].confidence = min(result[last].confidence, confidence)
                }
            } else if isName(text) {
                result.append(ClinicName(name: text, confidence: confidence))
            }
        }
        return result
    }

    private static func isName(_ text: String) -> Bool {
        // Keep unrecognized rows available for review, but discard times, dates and headers.
        guard !text.unicodeScalars.contains(where: CharacterSet.decimalDigits.contains),
              nameKey(text).split(separator: " ").count >= 2 else { return false }
        return !["PATIENT NAME", "CLINIC LIST", "APPOINTMENT LIST", "DATE OF BIRTH"].contains(nameKey(text))
    }
}
