@preconcurrency import AVFAudio
import AppKit
import Foundation
import WhisperASR

enum LanguagePackState: Equatable, Sendable {
    case notInstalled
    case installing(progress: Double, detail: String)
    case installed
    case paused
    case failed(String)

    var title: String {
        switch self {
        case .notInstalled: "Optional"
        case let .installing(progress, _): "Installing — \(Int(progress * 100))%"
        case .installed: "Installed"
        case .paused: "Paused"
        case .failed: "Installation failed"
        }
    }

    var progress: Double? {
        if case let .installing(progress, _) = self { progress } else { nil }
    }
}

@MainActor
final class LanguagePackManager: ObservableObject {
    @Published private(set) var state: LanguagePackState

    let modelDirectory: URL
    let runtime: ExtendedLanguageRuntime

    private let markerURL: URL
    private var installationTask: Task<Void, Never>?
    private var installationID: UUID?

    init(fileManager: FileManager = .default, modelsRoot: URL? = nil) {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let root = modelsRoot ?? support.appending(path: "AirScribe/models", directoryHint: .isDirectory)
        modelDirectory = root.appending(path: "extended-language-pack", directoryHint: .isDirectory)
        markerURL = modelDirectory.appending(path: ".airscribe-ready")
        state = Self.hasCompleteInstallation(
            at: markerURL,
            in: modelDirectory,
            fileManager: fileManager
        ) ? .installed : .notInstalled
        runtime = ExtendedLanguageRuntime(modelDirectory: modelDirectory)
    }

    func install() {
        guard installationTask == nil, state != .installed else { return }
        beginInstallation(waitingFor: nil)
    }

    private func beginInstallation(waitingFor previousTask: Task<Void, Never>?) {
        let id = UUID()
        installationID = id
        installationTask = Task { [weak self] in
            guard let self else { return }
            await previousTask?.value
            guard self.installationID == id else { return }
            guard !Task.isCancelled else {
                state = .paused
                installationTask = nil
                return
            }
            do {
                try Self.requireFreeSpace(at: modelDirectory, minimumBytes: 8_000_000_000)
                try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
                try await runtime.prepare(offline: false) { [weak self] progress, detail in
                    Task { @MainActor in
                        guard let self, self.installationID == id else { return }
                        self.state = .installing(
                            progress: min(max(progress, 0), 1),
                            detail: Self.publicDetail(for: detail)
                        )
                    }
                }
                guard installationID == id else { throw CancellationError() }
                try Self.writeInstallationMarker(in: modelDirectory, to: markerURL)
                if installationID == id { state = .installed }
            } catch is CancellationError {
                if installationID == id { state = .paused }
            } catch {
                if installationID == id { state = .failed(error.localizedDescription) }
            }
            if installationID == id {
                installationTask = nil
            }
        }
    }

    func pause() {
        installationTask?.cancel()
        if state != .installed { state = .paused }
    }

    func retry() {
        guard state != .installed else { return }
        let previousTask = installationTask
        previousTask?.cancel()
        beginInstallation(waitingFor: previousTask)
    }

    func remove() {
        Task { await removeAndWait() }
    }

    func removeAndWait() async {
        let previousTask = installationTask
        previousTask?.cancel()
        installationID = nil
        await previousTask?.value
        installationTask = nil
        try? FileManager.default.removeItem(at: modelDirectory)
        await runtime.unload()
        state = .notInstalled
    }

    func reveal() {
        try? FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([modelDirectory])
    }

    private static func publicDetail(for _: String) -> String {
        "Preparing language files locally…"
    }

    private static func writeInstallationMarker(in directory: URL, to markerURL: URL) throws {
        let fileManager = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            throw LanguagePackError.incompleteInstallation
        }
        var files: [String: Int64] = [:]
        for case let url as URL in enumerator where url != markerURL {
            let values = try url.resourceValues(forKeys: keys)
            guard values.isRegularFile == true, let size = values.fileSize, size > 0 else { continue }
            let relativePath = String(url.path.dropFirst(directory.path.count + 1))
            files[relativePath] = Int64(size)
        }
        guard !files.isEmpty else { throw LanguagePackError.incompleteInstallation }
        try JSONEncoder().encode(LanguagePackInstallationMarker(files: files))
            .write(to: markerURL, options: .atomic)
    }

    private static func hasCompleteInstallation(
        at markerURL: URL,
        in directory: URL,
        fileManager: FileManager
    ) -> Bool {
        guard let data = try? Data(contentsOf: markerURL),
              let marker = try? JSONDecoder().decode(LanguagePackInstallationMarker.self, from: data),
              !marker.files.isEmpty else { return false }
        return marker.files.allSatisfy { path, expectedSize in
            let url = directory.appending(path: path)
            guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                  let size = (attributes[.size] as? NSNumber)?.int64Value else { return false }
            return expectedSize > 0 && size == expectedSize
        }
    }

    private static func requireFreeSpace(at url: URL, minimumBytes: Int64) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let values = try parent.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let available = values.volumeAvailableCapacityForImportantUsage,
           available < minimumBytes {
            throw LanguagePackError.insufficientStorage(required: minimumBytes, available: available)
        }
    }
}

actor ExtendedLanguageRuntime {
    private let modelDirectory: URL
    private var model: WhisperASRModel?

    init(modelDirectory: URL) {
        self.modelDirectory = modelDirectory
    }

    func prepare(
        offline: Bool,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) async throws {
        guard model == nil else {
            progress?(1, "Ready")
            return
        }
        model = try await WhisperASRModel.fromPretrained(
            cacheDir: modelDirectory,
            offlineMode: offline,
            progressHandler: progress
        )
    }

    func transcribe(samples: [Float], sampleRate: Int, language: String?) async throws -> String {
        try await prepare(offline: true)
        guard let model else { throw AirScribeError.speechUnavailable }
        return try await model.transcribeAudio(samples, sampleRate: sampleRate, language: language)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func unload() { model = nil }
}

private enum LanguagePackError: LocalizedError {
    case insufficientStorage(required: Int64, available: Int64)
    case incompleteInstallation

    var errorDescription: String? {
        switch self {
        case .incompleteInstallation:
            return "The language pack did not finish writing all required files."
        case let .insufficientStorage(required, available):
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            return "The 100+ language pack needs \(formatter.string(fromByteCount: required)) free; \(formatter.string(fromByteCount: available)) is available."
        }
    }
}

private struct LanguagePackInstallationMarker: Codable {
    let files: [String: Int64]
}
