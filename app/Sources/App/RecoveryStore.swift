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
    @Published private(set) var lastError: String?
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
        lastError = nil
    }

    func presentMarkedSession() {
        interruptedSession = decode()
    }

    func revealRecoveredFiles() {
        guard let session = interruptedSession else { return }
        let files = session.audioPaths
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        if let first = files.first { NSWorkspace.shared.activateFileViewerSelecting([first]) }
    }

    @discardableResult
    func discardRecoveredFiles() -> Bool {
        guard let session = interruptedSession else { return true }
        var failures: [String] = []
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            lastError = "Recovered audio could not be deleted because Application Support could not be located."
            return false
        }
        let support = applicationSupport
            .appending(path: "AirScribe", directoryHint: .isDirectory)
            .standardizedFileURL.path + "/"
        for path in session.audioPaths {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard url.path.hasPrefix(support) else { continue }
            do {
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
            } catch {
                failures.append(url.lastPathComponent)
            }
        }
        guard failures.isEmpty else {
            lastError = "Some recovered audio could not be deleted: \(failures.joined(separator: ", "))."
            return false
        }
        complete()
        return true
    }

    private func decode() -> InterruptedSession? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(InterruptedSession.self, from: data)
    }
}
