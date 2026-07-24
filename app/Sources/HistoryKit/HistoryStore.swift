import Foundation

@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var records: [DictationRecord] = []
    @Published private(set) var lastError: String?

    private let fileURL: URL
    private let audioDirectory: URL
    private let fileManager: FileManager
    private let maximumRecordCount: Int
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var loadFailure: Error?

    init(
        fileManager: FileManager = .default,
        applicationSupportRoot: URL? = nil,
        maximumRecordCount: Int = 1_000
    ) {
        self.fileManager = fileManager
        self.maximumRecordCount = maximumRecordCount
        let base = applicationSupportRoot
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = base.appending(path: "AirScribe", directoryHint: .isDirectory)
        fileURL = directory.appending(path: "history.json")
        audioDirectory = directory.appending(path: "audio", directoryHint: .isDirectory)

        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        do {
            try secureDirectory(fileURL.deletingLastPathComponent())
            try secureDirectory(audioDirectory)
            secureExistingFiles()
            try load()
        } catch {
            loadFailure = error
            lastError = "Dictation history could not be loaded: \(error.localizedDescription)"
        }
    }

    func add(_ record: DictationRecord) throws {
        guard loadFailure == nil else {
            let error = HistoryStoreError.unavailableUntilRecovery
            lastError = error.localizedDescription
            throw error
        }
        let previousRecords = records
        records.insert(record, at: 0)
        let evictedRecords: ArraySlice<DictationRecord>
        if records.count > maximumRecordCount {
            evictedRecords = records.suffix(records.count - maximumRecordCount)
            records.removeLast(evictedRecords.count)
        } else {
            evictedRecords = []
        }
        do {
            try save()
        } catch {
            records = previousRecords
            lastError = "Dictation history could not be saved: \(error.localizedDescription)"
            throw error
        }

        lastError = nil
        for record in evictedRecords {
            do {
                try deleteAudio(for: record)
            } catch {
                lastError = "An old dictation recording could not be removed: \(error.localizedDescription)"
                break
            }
        }
    }

    func delete(_ record: DictationRecord) {
        do {
            try deleteAudio(for: record)
        } catch {
            lastError = "The dictation and its recording could not be deleted: \(error.localizedDescription)"
            return
        }

        let previousRecords = records
        records.removeAll { $0.id == record.id }
        do {
            try save()
            lastError = nil
        } catch {
            records = previousRecords
            lastError = "The dictation could not be deleted: \(error.localizedDescription)"
        }
    }

    func deleteAll() throws {
        let previousRecords = records
        do {
            if fileManager.fileExists(atPath: audioDirectory.path) {
                try fileManager.removeItem(at: audioDirectory)
            }
        } catch {
            lastError = "Dictation recordings could not be deleted: \(error.localizedDescription)"
            throw error
        }

        records.removeAll()
        do {
            if fileManager.fileExists(atPath: fileURL.path) {
                try fileManager.removeItem(at: fileURL)
            }
            loadFailure = nil
            lastError = nil
        } catch {
            records = previousRecords
            lastError = "Dictation history could not be deleted: \(error.localizedDescription)"
            throw error
        }
    }

    func newAudioURL() throws -> URL {
        try secureDirectory(audioDirectory)
        let url = audioDirectory.appending(path: "\(UUID().uuidString).caf")
        guard fileManager.createFile(
            atPath: url.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return url
    }

    func search(_ query: String) -> [DictationRecord] {
        guard !query.isEmpty else { return records }
        return records.filter {
            $0.enhancedText.localizedCaseInsensitiveContains(query)
                || $0.rawText.localizedCaseInsensitiveContains(query)
        }
    }

    private func load() throws {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        let data = try Data(contentsOf: fileURL)
        let decoded = try decoder.decode([DictationRecord].self, from: data)
        records = decoded.sorted { $0.createdAt > $1.createdAt }
    }

    private func save() throws {
        let data = try encoder.encode(records)
        try data.write(to: fileURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private func deleteAudio(for record: DictationRecord) throws {
        guard let audioPath = record.audioPath else { return }
        let url = URL(filePath: audioPath).standardizedFileURL
        guard url.deletingLastPathComponent() == audioDirectory.standardizedFileURL else { return }
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    private func secureDirectory(_ url: URL) throws {
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func secureExistingFiles() {
        if fileManager.fileExists(atPath: fileURL.path) {
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        }
        guard let enumerator = fileManager.enumerator(
            at: audioDirectory,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return }
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
        }
    }
}

private enum HistoryStoreError: LocalizedError {
    case unavailableUntilRecovery

    var errorDescription: String? {
        "Dictation history is damaged and was not overwritten. Delete all local data or restore the history file before saving another dictation."
    }
}
