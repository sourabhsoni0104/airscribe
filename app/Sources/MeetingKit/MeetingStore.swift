import AppKit
import Foundation
import UniformTypeIdentifiers

enum MeetingSpeaker: String, Codable, Sendable {
    case you = "You"
    case computer = "Computer"
}

struct MeetingTranscriptSegment: Identifiable, Codable, Sendable {
    let id: UUID
    let speaker: MeetingSpeaker
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String

    init(
        id: UUID = UUID(),
        speaker: MeetingSpeaker,
        startTime: TimeInterval,
        endTime: TimeInterval,
        text: String
    ) {
        self.id = id
        self.speaker = speaker
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
    }
}

struct MeetingRecord: Identifiable, Codable, Sendable {
    let id: UUID
    var title: String
    let startedAt: Date
    let duration: TimeInterval
    let localeIdentifier: String
    let transcript: String
    let summary: String
    let segments: [MeetingTranscriptSegment]
    let microphoneAudioPath: String?
    let systemAudioPath: String?

    init(
        id: UUID = UUID(),
        title: String,
        startedAt: Date,
        duration: TimeInterval,
        localeIdentifier: String,
        transcript: String,
        summary: String,
        segments: [MeetingTranscriptSegment],
        microphoneAudioPath: String?,
        systemAudioPath: String?
    ) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.duration = duration
        self.localeIdentifier = localeIdentifier
        self.transcript = transcript
        self.summary = summary
        self.segments = segments
        self.microphoneAudioPath = microphoneAudioPath
        self.systemAudioPath = systemAudioPath
    }
}

@MainActor
final class MeetingStore: ObservableObject {
    @Published private(set) var records: [MeetingRecord] = []
    @Published private(set) var lastError: String?

    let audioDirectory: URL
    private let recordsURL: URL
    private let fileManager: FileManager
    private var loadFailure: Error?

    init(fileManager: FileManager = .default, applicationSupportRoot: URL? = nil) {
        self.fileManager = fileManager
        let root = applicationSupportRoot ?? ApplicationSupportLocation.airScribeRoot(fileManager)
        audioDirectory = root.appending(path: "MeetingAudio", directoryHint: .isDirectory)
        recordsURL = root.appending(path: "meetings.json")
        do {
            try secureDirectory(root)
            try secureDirectory(audioDirectory)
            secureExistingFiles()
            try load()
        } catch {
            loadFailure = error
            lastError = "Meeting history could not be loaded: \(error.localizedDescription)"
        }
    }

    func newAudioURL(source: MeetingSpeaker) throws -> URL {
        try secureDirectory(audioDirectory)
        let url = audioDirectory.appending(path: "\(UUID().uuidString)-\(source.rawValue.lowercased()).caf")
        guard fileManager.createFile(
            atPath: url.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return url
    }

    func add(_ record: MeetingRecord) throws {
        guard loadFailure == nil else {
            let error = MeetingStoreError.unavailableUntilRecovery
            lastError = error.localizedDescription
            throw error
        }
        let previousRecords = records
        records.insert(record, at: 0)
        do {
            try save()
            lastError = nil
        } catch {
            records = previousRecords
            lastError = "The meeting could not be saved: \(error.localizedDescription)"
            throw error
        }
    }

    func updateTitle(for recordID: UUID, title: String) {
        guard let index = records.firstIndex(where: { $0.id == recordID }) else { return }
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        let previousTitle = records[index].title
        records[index].title = cleaned
        do {
            try save()
            lastError = nil
        } catch {
            records[index].title = previousTitle
            lastError = "The meeting title could not be saved: \(error.localizedDescription)"
        }
    }

    func delete(_ record: MeetingRecord) {
        do {
            try deleteManagedAudio(at: record.microphoneAudioPath)
            try deleteManagedAudio(at: record.systemAudioPath)
        } catch {
            lastError = "The meeting and its audio could not be deleted: \(error.localizedDescription)"
            return
        }

        let previousRecords = records
        records.removeAll { $0.id == record.id }
        do {
            try save()
            lastError = nil
        } catch {
            records = previousRecords
            lastError = "The meeting could not be deleted: \(error.localizedDescription)"
        }
    }

    func deleteAll() throws {
        let previousRecords = records
        do {
            if fileManager.fileExists(atPath: audioDirectory.path) {
                try fileManager.removeItem(at: audioDirectory)
            }
        } catch {
            lastError = "Meeting audio could not be deleted: \(error.localizedDescription)"
            throw error
        }

        records.removeAll()
        do {
            if fileManager.fileExists(atPath: recordsURL.path) {
                try fileManager.removeItem(at: recordsURL)
            }
            loadFailure = nil
            lastError = nil
        } catch {
            records = previousRecords
            lastError = "Meeting history could not be deleted: \(error.localizedDescription)"
            throw error
        }
    }

    func export(_ record: MeetingRecord, format: MeetingExportFormat) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = sanitized(record.title) + "." + format.fileExtension
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try format.render(record).write(to: url, atomically: true, encoding: .utf8)
            lastError = nil
        } catch {
            lastError = "The meeting export failed: \(error.localizedDescription)"
        }
    }

    private func load() throws {
        guard fileManager.fileExists(atPath: recordsURL.path) else { return }
        let data = try Data(contentsOf: recordsURL)
        let decoded = try JSONDecoder().decode([MeetingRecord].self, from: data)
        records = decoded.sorted { $0.startedAt > $1.startedAt }
    }

    private func save() throws {
        let data = try JSONEncoder().encode(records)
        try secureDirectory(recordsURL.deletingLastPathComponent())
        try data.write(to: recordsURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recordsURL.path)
    }

    private func deleteManagedAudio(at path: String?) throws {
        guard let path else { return }
        let url = URL(filePath: path).standardizedFileURL
        let root = audioDirectory.standardizedFileURL.path + "/"
        guard url.path.hasPrefix(root) else { return }
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
        if fileManager.fileExists(atPath: recordsURL.path) {
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recordsURL.path)
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

    private func sanitized(_ value: String) -> String {
        let cleaned = value
            .replacingOccurrences(of: #"[^A-Za-z0-9 _-]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: " ", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        // A title made entirely of stripped characters would leave the save panel
        // proposing a bare extension such as ".md".
        return cleaned.isEmpty ? "Meeting" : cleaned
    }
}

private enum MeetingStoreError: LocalizedError {
    case unavailableUntilRecovery

    var errorDescription: String? {
        "Meeting history is damaged and was not overwritten. Delete all local data or restore the meetings file before saving another meeting."
    }
}

enum MeetingExportFormat: String, CaseIterable, Identifiable {
    case text = "Text"
    case markdown = "Markdown"
    case subtitles = "SRT"

    var id: String { rawValue }
    var fileExtension: String { self == .markdown ? "md" : rawValue.lowercased() }
    var contentType: UTType {
        switch self {
        case .text: .plainText
        case .markdown: .init(filenameExtension: "md") ?? .plainText
        case .subtitles: .init(filenameExtension: "srt") ?? .plainText
        }
    }

    func render(_ record: MeetingRecord) -> String {
        switch self {
        case .text:
            return "\(record.title)\n\nSummary\n\(record.summary)\n\nTranscript\n\(record.transcript)\n"
        case .markdown:
            return "# \(record.title)\n\n## Summary\n\n\(record.summary)\n\n## Transcript\n\n\(record.transcript)\n"
        case .subtitles:
            return record.segments.enumerated().map { index, segment in
                "\(index + 1)\n\(srtTime(segment.startTime)) --> \(srtTime(segment.endTime))\n\(segment.speaker.rawValue): \(segment.text)"
            }.joined(separator: "\n\n") + "\n"
        }
    }

    private func srtTime(_ interval: TimeInterval) -> String {
        let milliseconds = max(Int(interval * 1_000), 0)
        let hours = milliseconds / 3_600_000
        let minutes = (milliseconds / 60_000) % 60
        let seconds = (milliseconds / 1_000) % 60
        let remainder = milliseconds % 1_000
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, seconds, remainder)
    }
}
