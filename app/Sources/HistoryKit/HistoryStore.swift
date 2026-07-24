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
            try fileManager.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
            try load()
        } catch {
            lastError = "Dictation history could not be loaded: \(error.localizedDescription)"
        }
    }

    func add(_ record: DictationRecord) throws {
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
        let previousRecords = records
        records.removeAll { $0.id == record.id }
        do {
            try save()
        } catch {
            records = previousRecords
            lastError = "The dictation could not be deleted: \(error.localizedDescription)"
            return
        }

        do {
            try deleteAudio(for: record)
            lastError = nil
        } catch {
            lastError = "The dictation was deleted, but its recording could not be removed: \(error.localizedDescription)"
        }
    }

    func deleteAll() {
        let previousRecords = records
        records.removeAll()
        do {
            if fileManager.fileExists(atPath: fileURL.path) {
                try fileManager.removeItem(at: fileURL)
            }
        } catch {
            records = previousRecords
            lastError = "Dictation history could not be deleted: \(error.localizedDescription)"
            return
        }

        do {
            if fileManager.fileExists(atPath: audioDirectory.path) {
                try fileManager.removeItem(at: audioDirectory)
            }
            lastError = nil
        } catch {
            lastError = "Dictation history was deleted, but some recordings could not be removed: \(error.localizedDescription)"
        }
    }

    func newAudioURL() throws -> URL {
        try fileManager.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        return audioDirectory.appending(path: "\(UUID().uuidString).caf")
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
    }

    private func deleteAudio(for record: DictationRecord) throws {
        guard let audioPath = record.audioPath else { return }
        let url = URL(filePath: audioPath).standardizedFileURL
        guard url.deletingLastPathComponent() == audioDirectory.standardizedFileURL else { return }
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }
}
