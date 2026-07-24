import XCTest
@testable import AirScribe

final class SensitivePreferenceStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "AirScribeTests-Preferences-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testValuesRoundTripAndPersistAcrossInstances() {
        let store = SensitivePreferenceStore(directory: directory)
        store.setValue(["Kadenze", "Soniqo"], forKey: "vocabulary")
        store.setValue(["cadence": "Kadenze"], forKey: "corrections")

        let reopened = SensitivePreferenceStore(directory: directory)
        XCTAssertEqual(reopened.value([String].self, forKey: "vocabulary"), ["Kadenze", "Soniqo"])
        XCTAssertEqual(
            reopened.value([String: String].self, forKey: "corrections"),
            ["cadence": "Kadenze"]
        )
        XCTAssertNil(reopened.lastError)
    }

    func testFileIsReadableOnlyByItsOwner() throws {
        let store = SensitivePreferenceStore(directory: directory)
        store.setValue(["Kadenze"], forKey: "vocabulary")

        let fileURL = directory.appending(path: SensitivePreferenceStore.fileName)
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.int16Value, 0o600)

        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.int16Value, 0o700)
    }

    func testMigratesDictationDataOutOfUserDefaults() throws {
        let suiteName = "AirScribeTests.Preferences.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(["Kadenze", "Soniqo"], forKey: "customVocabulary")
        defaults.set(
            try JSONEncoder().encode(["cadence": "Kadenze"]),
            forKey: "learnedCorrections"
        )

        let store = SensitivePreferenceStore(directory: directory)
        store.migrateStringArray(forKey: "customVocabulary", from: defaults)
        store.migrateJSONValue([String: String].self, forKey: "learnedCorrections", from: defaults)

        XCTAssertEqual(store.value([String].self, forKey: "customVocabulary"), ["Kadenze", "Soniqo"])
        XCTAssertEqual(
            store.value([String: String].self, forKey: "learnedCorrections"),
            ["cadence": "Kadenze"]
        )
        // The plaintext plist copies must be gone once migrated.
        XCTAssertNil(defaults.object(forKey: "customVocabulary"))
        XCTAssertNil(defaults.object(forKey: "learnedCorrections"))
    }

    func testMigrationDoesNotOverwriteExistingValues() throws {
        let suiteName = "AirScribeTests.Preferences.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(["Stale"], forKey: "customVocabulary")

        let store = SensitivePreferenceStore(directory: directory)
        store.setValue(["Current"], forKey: "customVocabulary")
        store.migrateStringArray(forKey: "customVocabulary", from: defaults)

        XCTAssertEqual(store.value([String].self, forKey: "customVocabulary"), ["Current"])
        XCTAssertNil(defaults.object(forKey: "customVocabulary"))
    }

    func testRemoveAllDeletesTheFileAndAllowsLaterWrites() {
        let store = SensitivePreferenceStore(directory: directory)
        store.setValue(["Kadenze"], forKey: "vocabulary")
        store.removeAll()

        let fileURL = directory.appending(path: SensitivePreferenceStore.fileName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertNil(store.value([String].self, forKey: "vocabulary"))

        // Resetting settings after a full deletion must not be treated as an error.
        store.setValue(["Fresh"], forKey: "vocabulary")
        XCTAssertNil(store.lastError)
        XCTAssertEqual(store.value([String].self, forKey: "vocabulary"), ["Fresh"])
    }
}
