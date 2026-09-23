import Foundation

// Standalone fixtures; no patient data or database access.
@main
enum ClinicAlbumMatchingTests {
    static func main() {
        precondition(ClinicAlbumMatching.searchName("Example, Alice B.") == "EXAMPLE ALICE")
        precondition(ClinicAlbumMatching.searchName("De la Cruz, Anna M.") == "DE LA CRUZ ANNA")
        precondition(ClinicAlbumMatching.searchName("Example, A.") == "EXAMPLE A")
        precondition(ClinicAlbumMatching.searchName("123456") == "123456")
        precondition(ClinicAlbumMatching.searchName("Example-Sample, Anne-Marie B.") == "EXAMPLE-SAMPLE ANNE-MARIE")
        precondition(ClinicAlbumMatching.searchName("   ").isEmpty)
        let calendar = Calendar.current
        let birth = calendar.date(from: DateComponents(year: 1980, month: 2, day: 3))!
        let reference = calendar.date(from: DateComponents(year: 2026, month: 9, day: 23))!
        let study = ClinicStudy(uri: "one", name: "EXAMPLE ALICE", patientID: "100", patientUID: "uid", birthDate: birth, sex: "F")
        var source = ClinicName(name: "Example, Alice", age: 46, sex: "F", confidence: 1)
        precondition(ClinicAlbumMatching.warnings(for: source, studies: [study], on: reference).isEmpty)
        source.age = 45
        precondition(ClinicAlbumMatching.warnings(for: source, studies: [study, study], on: reference).count == 1)
        source.sex = "M"
        precondition(ClinicAlbumMatching.warnings(for: source, studies: [study], on: reference).contains("Sex differs"))
        let parsed = ClinicAlbumMatching.names(from: [
            ("Patient name", 1), ("Example, Alice B.", 1), ("46 y.o. / F", 1),
            ("Sample, Bob 72 y.o. / M", 1), ("12:30", 1), ("Another, Carol", 0.8)
        ])
        precondition(parsed.count == 3)
        precondition(parsed[0].age == 46 && parsed[0].sex == "F")
        precondition(parsed[1].name == "Sample, Bob" && parsed[1].age == 72)
        precondition(parsed[2].age == nil && parsed[2].confidence == 0.8)
        precondition(ClinicAlbumMatching.names(from: [("46 y.o. / F", 1)]).isEmpty)
        let numbered = ClinicAlbumMatching.names(from: [
            ("1. Example, Alice. ULI: 001234567", 1),
            ("2. Sample, Anne-Marie ULI: 123456789", 1),
            ("0. Other, Robert T. ULI: 987654321", 1),
            ("4) Separate, Carol", 1), ("ULI: 111222333", 0.8)
        ])
        precondition(numbered.count == 4)
        precondition(numbered[0].name == "Example, Alice" && numbered[0].patientID == "001234567")
        precondition(numbered[1].name == "Sample, Anne-Marie")
        precondition(numbered[2].name == "Other, Robert T")
        precondition(numbered[3].patientID == "111222333" && numbered[3].confidence == 0.8)
        precondition(ClinicAlbumMatching.names(from: [(numbered[0].searchQuery, 1)]).first?.patientID == "001234567")
        precondition(ClinicAlbumMatching.names(from: [("ULI: 123456789", 1)]).isEmpty)
        precondition(ClinicAlbumMatching.names(from: [("1. Example, Alice ULI: 123X567", 1)]).isEmpty)
        precondition(ClinicAlbumMatching.warnings(for: numbered[0], studies: [study], on: reference).contains("ULI not found; matched by name"))
        print("Clinic album matching fixtures passed")
    }
}
