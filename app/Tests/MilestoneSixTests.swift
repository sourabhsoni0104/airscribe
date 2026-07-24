import XCTest
@testable import AirScribe

@MainActor
final class MilestoneSixTests: XCTestCase {
    func testOutputLanguageModesRoundTrip() throws {
        let encoded = try JSONEncoder().encode(OutputLanguageMode.english)
        XCTAssertEqual(try JSONDecoder().decode(OutputLanguageMode.self, from: encoded), .english)
        XCTAssertEqual(OutputLanguageMode.allCases, [.original, .english])
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

    func testLanguagePackDetectsVerifiedMarkerAndCanRemoveIt() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "AirScribeTests-LanguagePack-\(UUID().uuidString)", directoryHint: .isDirectory)
        let pack = root.appending(path: "extended-language-pack", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: pack, withIntermediateDirectories: true)
        try Data("ready".utf8).write(to: pack.appending(path: ".airscribe-ready"))
        defer { try? FileManager.default.removeItem(at: root) }

        let manager = LanguagePackManager(modelsRoot: root)
        XCTAssertEqual(manager.state, .installed)
        manager.remove()
        XCTAssertEqual(manager.state, .notInstalled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pack.path))
    }
}
