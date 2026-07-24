import AppKit
import Foundation

struct InterruptedSession: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case dictation, meeting }
    let kind: Kind
    let startedAt: Date
    let audioPaths: [String]
}

@MainActor
final class RecoveryStore: ObservableObject {
    static let shared = RecoveryStore()

    @Published private(set) var interruptedSession: InterruptedSession?
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "activeRecoverySession") {
        self.defaults = defaults
        self.key = key
        interruptedSession = nil
        interruptedSession = decode()
    }

    func mark(_ kind: InterruptedSession.Kind, audioPaths: [String]) {
        let session = InterruptedSession(kind: kind, startedAt: Date(), audioPaths: audioPaths)
        if let data = try? JSONEncoder().encode(session) { defaults.set(data, forKey: key) }
        interruptedSession = nil
    }

    func complete() {
        defaults.removeObject(forKey: key)
        interruptedSession = nil
    }

    func revealRecoveredFiles() {
        guard let session = interruptedSession else { return }
        let files = session.audioPaths
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        if let first = files.first { NSWorkspace.shared.activateFileViewerSelecting([first]) }
    }

    func discardRecoveredFiles() {
        guard let session = interruptedSession else { return }
        for path in session.audioPaths {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appending(path: "AirScribe", directoryHint: .isDirectory).standardizedFileURL.path + "/"
            guard url.path.hasPrefix(support) else { continue }
            try? FileManager.default.removeItem(at: url)
        }
        complete()
    }

    private func decode() -> InterruptedSession? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(InterruptedSession.self, from: data)
    }
}
