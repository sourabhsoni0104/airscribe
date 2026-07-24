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

    let audioDirectory: URL
    private let recordsURL: URL
    private let fileManager: FileManager

    init(fileManager: FileManager = .default, applicationSupportRoot: URL? = nil) {
        self.fileManager = fileManager
        let root = applicationSupportRoot
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appending(path: "AirScribe", directoryHint: .isDirectory)
        audioDirectory = root.appending(path: "MeetingAudio", directoryHint: .isDirectory)
        recordsURL = root.appending(path: "meetings.json")
        try? fileManager.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        load()
    }

    func newAudioURL(source: MeetingSpeaker) -> URL {
        try? fileManager.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        return audioDirectory.appending(path: "\(UUID().uuidString)-\(source.rawValue.lowercased()).caf")
    }

    func add(_ record: MeetingRecord) {
        records.insert(record, at: 0)
        save()
    }

    func updateTitle(for recordID: UUID, title: String) {
        guard let index = records.firstIndex(where: { $0.id == recordID }) else { return }
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        records[index].title = cleaned
        save()
    }

    func delete(_ record: MeetingRecord) {
        deleteManagedAudio(at: record.microphoneAudioPath)
        deleteManagedAudio(at: record.systemAudioPath)
        records.removeAll { $0.id == record.id }
        save()
    }

    func deleteAll() {
        records.removeAll()
        try? fileManager.removeItem(at: audioDirectory)
        try? fileManager.removeItem(at: recordsURL)
    }

    func export(_ record: MeetingRecord, format: MeetingExportFormat) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = sanitized(record.title) + "." + format.fileExtension
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? format.render(record).write(to: url, atomically: true, encoding: .utf8)
    }

    private func load() {
        guard let data = try? Data(contentsOf: recordsURL),
              let decoded = try? JSONDecoder().decode([MeetingRecord].self, from: data) else { return }
        records = decoded.sorted { $0.startedAt > $1.startedAt }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? fileManager.createDirectory(at: recordsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: recordsURL, options: .atomic)
    }

    private func deleteManagedAudio(at path: String?) {
        guard let path else { return }
        let url = URL(filePath: path).standardizedFileURL
        let root = audioDirectory.standardizedFileURL.path + "/"
        guard url.path.hasPrefix(root) else { return }
        try? fileManager.removeItem(at: url)
    }

    private func sanitized(_ value: String) -> String {
        value.replacingOccurrences(of: #"[^A-Za-z0-9 _-]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: " ", with: "-")
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
