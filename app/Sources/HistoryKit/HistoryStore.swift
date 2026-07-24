import Foundation

@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var records: [DictationRecord] = []

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
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appending(path: "history.json")
        audioDirectory = directory.appending(path: "audio", directoryHint: .isDirectory)
        try? fileManager.createDirectory(at: audioDirectory, withIntermediateDirectories: true)

        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        load()
    }

    func add(_ record: DictationRecord) {
        records.insert(record, at: 0)
        if records.count > maximumRecordCount {
            let evictedRecords = records.suffix(records.count - maximumRecordCount)
            evictedRecords.forEach(deleteAudio)
            records.removeLast(evictedRecords.count)
        }
        save()
    }

    func delete(_ record: DictationRecord) {
        deleteAudio(for: record)
        records.removeAll { $0.id == record.id }
        save()
    }

    func deleteAll() {
        records.removeAll()
        try? fileManager.removeItem(at: audioDirectory)
        try? fileManager.removeItem(at: fileURL)
    }

    func newAudioURL() -> URL {
        try? fileManager.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        return audioDirectory.appending(path: "\(UUID().uuidString).caf")
    }

    func search(_ query: String) -> [DictationRecord] {
        guard !query.isEmpty else { return records }
        return records.filter {
            $0.enhancedText.localizedCaseInsensitiveContains(query)
                || $0.rawText.localizedCaseInsensitiveContains(query)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? decoder.decode([DictationRecord].self, from: data) else { return }
        records = decoded.sorted { $0.createdAt > $1.createdAt }
    }

    private func save() {
        guard let data = try? encoder.encode(records) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func deleteAudio(for record: DictationRecord) {
        guard let audioPath = record.audioPath else { return }
        let url = URL(filePath: audioPath).standardizedFileURL
        guard url.deletingLastPathComponent() == audioDirectory.standardizedFileURL else { return }
        try? fileManager.removeItem(at: url)
    }
}
