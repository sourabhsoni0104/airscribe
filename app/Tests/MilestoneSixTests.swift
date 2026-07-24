import XCTest
@testable import AirScribe

@MainActor
final class MilestoneSixTests: XCTestCase {
    func testOutputLanguageModesRoundTrip() throws {
        let encoded = try JSONEncoder().encode(OutputLanguageMode.english)
        XCTAssertEqual(try JSONDecoder().decode(OutputLanguageMode.self, from: encoded), .english)
        XCTAssertEqual(OutputLanguageMode.allCases, [.original, .romanizedHindi, .english])
    }

    func testRomanizesHindiWithoutTranslatingOrChangingEnglish() {
        XCTAssertEqual(
            HindiRomanizer.romanize("मेरा नाम सौरभ है और I use AirScribe।"),
            "mera naam saurabh hai aur I use AirScribe."
        )
        XCTAssertEqual(
            HindiRomanizer.romanize("मैं हिंदी में बोल रहा हूँ"),
            "main hindi mein bol raha hoon"
        )
        XCTAssertEqual(HindiRomanizer.romanize("Already English"), "Already English")
        XCTAssertEqual(
            HindiRomanizer.romanize("My name is Sourabh. मेरा नाम सौरभ है।"),
            "My name is Sourabh. mera naam saurabh hai."
        )
    }

    func testRejectsTranslationsThatDropNamesOrNumbers() {
        let original = "मैं AirScribe में 25 शब्द बोलता हूँ"
        XCTAssertTrue(
            PolishGuard.isPlausibleTranslation(
                "main AirScribe mein 25 shabd bolta hoon",
                of: original
            )
        )
        XCTAssertFalse(
            PolishGuard.isPlausibleTranslation(
                "I use another app for twenty five words",
                of: original
            )
        )
    }

    func testRomanizationDoesNotUseTranslationForDevanagari() async {
        let output = await OnDeviceTranslator().romanizeHindi("मेरा नाम सौरभ है")
        XCTAssertEqual(output, "mera naam saurabh hai")
        XCTAssertNotEqual(output, "My name is Sourabh")
    }

    func testInterruptedSessionIsRecoveredOnNextLaunch() throws {
        let suiteName = "AirScribeTests.Recovery.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = "recovery"

        let activeStore = RecoveryStore(defaults: defaults, key: key)
        activeStore.mark(.dictation, audioPaths: ["/tmp/example.caf"])
        XCTAssertNil(activeStore.interruptedSession)

        let relaunchedStore = RecoveryStore(defaults: defaults, key: key)
        XCTAssertEqual(relaunchedStore.interruptedSession?.kind, .dictation)
        XCTAssertEqual(relaunchedStore.interruptedSession?.audioPaths, ["/tmp/example.caf"])
        relaunchedStore.complete()
        XCTAssertNil(relaunchedStore.interruptedSession)
    }

    func testLanguagePackDetectsVerifiedMarkerAndCanRemoveIt() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "AirScribeTests-LanguagePack-\(UUID().uuidString)", directoryHint: .isDirectory)
        let pack = root.appending(path: "extended-language-pack", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: pack, withIntermediateDirectories: true)
        try Data("data".utf8).write(to: pack.appending(path: "model.bin"))
        let manifest = LanguagePackManifest(
            identifier: "test-language-pack",
            files: [
                PinnedLanguagePackFile(
                    repository: "example/test",
                    revision: "0123456789abcdef",
                    path: "model.bin",
                    size: 4,
                    sha256: "3a6eb0790f39ac87c94f3856b2dd2c5d110e6811602261a9a923d3bb23adc8b7"
                ),
            ]
        )
        try Data(
            #"{"identifier":"test-language-pack","files":{"model.bin":{"size":4,"sha256":"3a6eb0790f39ac87c94f3856b2dd2c5d110e6811602261a9a923d3bb23adc8b7"}}}"#.utf8
        )
            .write(to: pack.appending(path: ".airscribe-ready"))
        defer { try? FileManager.default.removeItem(at: root) }

        let manager = LanguagePackManager(modelsRoot: root, manifest: manifest)
        XCTAssertEqual(manager.state, .installed)
        try LanguagePackManager.validateInstallation(in: pack, manifest: manifest)
        await manager.removeAndWait()
        XCTAssertEqual(manager.state, .notInstalled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pack.path))
    }

    func testProductionLanguagePackUsesImmutableHashedFiles() {
        let manifest = LanguagePackManifest.production
        XCTAssertFalse(manifest.files.isEmpty)
        XCTAssertEqual(Set(manifest.files.map(\.path)).count, manifest.files.count)
        for file in manifest.files {
            XCTAssertEqual(file.revision.count, 40)
            XCTAssertTrue(file.revision.allSatisfy(\.isHexDigit))
            XCTAssertEqual(file.sha256.count, 64)
            XCTAssertTrue(file.sha256.allSatisfy(\.isHexDigit))
            XCTAssertFalse(file.downloadURL.absoluteString.contains("/resolve/main/"))
        }
    }

    func testCloudPolishRejectsCredentialBearingEndpoint() async {
        let enhancer = CloudTextEnhancer()
        do {
            _ = try await enhancer.enhance(
                "Hello",
                instruction: "",
                configuration: CloudPolishConfiguration(
                    endpoint: URL(string: "https://user:password@example.com/v1/responses")!,
                    model: "test",
                    apiKey: "not-a-real-key"
                )
            )
            XCTFail("A URL containing credentials must be rejected before any network request")
        } catch CloudPolishError.insecureEndpoint {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
