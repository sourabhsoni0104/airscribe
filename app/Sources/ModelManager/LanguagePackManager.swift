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

    init(fileManager: FileManager = .default, modelsRoot: URL? = nil) {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let root = modelsRoot ?? support.appending(path: "AirScribe/models", directoryHint: .isDirectory)
        modelDirectory = root.appending(path: "extended-language-pack", directoryHint: .isDirectory)
        markerURL = modelDirectory.appending(path: ".airscribe-ready")
        state = fileManager.fileExists(atPath: markerURL.path) ? .installed : .notInstalled
        runtime = ExtendedLanguageRuntime(modelDirectory: modelDirectory)
    }

    func install() {
        guard installationTask == nil, state != .installed else { return }
        installationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try Self.requireFreeSpace(at: modelDirectory, minimumBytes: 8_000_000_000)
                try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
                try await runtime.prepare(offline: false) { [weak self] progress, detail in
                    Task { @MainActor in
                        self?.state = .installing(
                            progress: min(max(progress, 0), 1),
                            detail: Self.publicDetail(for: detail)
                        )
                    }
                }
                try Data("ready".utf8).write(to: markerURL, options: .atomic)
                state = .installed
            } catch is CancellationError {
                state = .paused
            } catch {
                state = .failed(error.localizedDescription)
            }
            installationTask = nil
        }
    }

    func pause() {
        installationTask?.cancel()
        installationTask = nil
        if state != .installed { state = .paused }
    }

    func retry() { install() }

    func remove() {
        installationTask?.cancel()
        installationTask = nil
        try? FileManager.default.removeItem(at: modelDirectory)
        Task { await runtime.unload() }
        state = .notInstalled
    }

    func removeAndWait() async {
        installationTask?.cancel()
        await installationTask?.value
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

    var errorDescription: String? {
        switch self {
        case let .insufficientStorage(required, available):
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            return "The 100+ language pack needs \(formatter.string(fromByteCount: required)) free; \(formatter.string(fromByteCount: available)) is available."
        }
    }
}
