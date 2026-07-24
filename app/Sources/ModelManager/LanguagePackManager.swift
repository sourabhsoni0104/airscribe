@preconcurrency import AVFAudio
import AppKit
import CryptoKit
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
    private let manifest: LanguagePackManifest
    private let fileManager: FileManager
    private var installationTask: Task<Void, Never>?
    private var installationID: UUID?
    private var activeDownload: ResumableFileDownload?

    init(
        fileManager: FileManager = .default,
        modelsRoot: URL? = nil,
        manifest: LanguagePackManifest = .production
    ) {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.fileManager = fileManager
        let root = modelsRoot ?? support.appending(path: "AirScribe/models", directoryHint: .isDirectory)
        modelDirectory = root.appending(path: "extended-language-pack", directoryHint: .isDirectory)
        markerURL = modelDirectory.appending(path: ".airscribe-ready")
        self.manifest = manifest
        state = Self.hasCompleteInstallation(
            at: markerURL,
            in: modelDirectory,
            manifest: manifest,
            fileManager: fileManager
        ) ? .installed : .notInstalled
        let runtimeDirectory = modelDirectory
        runtime = ExtendedLanguageRuntime(modelDirectory: runtimeDirectory) {
            try Self.validateInstallation(in: runtimeDirectory, manifest: manifest)
        }
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
                try fileManager.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
                let assessment = try await assessPinnedFiles(id: id)
                if assessment.missingBytes > 0 {
                    try Self.requireFreeSpace(
                        at: modelDirectory,
                        minimumBytes: assessment.missingBytes + 500_000_000
                    )
                }
                try await downloadPinnedFiles(id: id, validFiles: assessment.validFiles)
                guard installationID == id else { throw CancellationError() }
                try Self.writeInstallationMarker(manifest: manifest, to: markerURL)
                try await runtime.prepare(offline: true)
                if installationID == id { state = .installed }
            } catch is CancellationError {
                if installationID == id { state = .paused }
            } catch {
                if installationID == id { state = .failed(error.localizedDescription) }
            }
            if installationID == id {
                installationTask = nil
                activeDownload = nil
            }
        }
    }

    func pause() {
        installationTask?.cancel()
        activeDownload?.cancel()
        if state != .installed { state = .paused }
    }

    func retry() {
        guard state != .installed else { return }
        let previousTask = installationTask
        previousTask?.cancel()
        activeDownload?.cancel()
        beginInstallation(waitingFor: previousTask)
    }

    func remove() {
        Task { await removeAndWait() }
    }

    func removeAndWait() async {
        let previousTask = installationTask
        previousTask?.cancel()
        activeDownload?.cancel()
        installationID = nil
        await previousTask?.value
        installationTask = nil
        activeDownload = nil
        await runtime.unload()
        do {
            if fileManager.fileExists(atPath: modelDirectory.path) {
                try fileManager.removeItem(at: modelDirectory)
            }
            state = .notInstalled
        } catch {
            state = .failed("The language pack could not be removed: \(error.localizedDescription)")
        }
    }

    func reveal() {
        try? fileManager.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([modelDirectory])
    }

    private func assessPinnedFiles(
        id: UUID
    ) async throws -> (validFiles: Set<String>, missingBytes: Int64) {
        var validFiles = Set<String>()
        var missingBytes: Int64 = 0
        for file in manifest.files {
            try Task.checkCancellation()
            guard installationID == id else { throw CancellationError() }
            let destination = modelDirectory.appending(path: file.path)
            if try await Self.fileIsValid(file, at: destination) {
                validFiles.insert(file.path)
            } else {
                missingBytes += file.size
            }
        }
        return (validFiles, missingBytes)
    }

    private func downloadPinnedFiles(id: UUID, validFiles: Set<String>) async throws {
        let totalSize = max(manifest.files.reduce(Int64(0)) { $0 + $1.size }, 1)
        var completedSize: Int64 = 0

        for file in manifest.files {
            try Task.checkCancellation()
            guard installationID == id else { throw CancellationError() }
            let destination = modelDirectory.appending(path: file.path)
            if validFiles.contains(file.path) {
                completedSize += file.size
                continue
            }

            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let resumeURL = destination.deletingLastPathComponent()
                .appending(path: ".\(destination.lastPathComponent).resume")
            let completedBeforeDownload = completedSize
            let download = ResumableFileDownload(
                request: URLRequest(url: file.downloadURL),
                destination: destination,
                resumeDataURL: resumeURL
            ) { [weak self] fileProgress in
                Task { @MainActor in
                    guard let self, self.installationID == id else { return }
                    let received = Int64(Double(file.size) * fileProgress)
                    self.state = .installing(
                        progress: Double(completedBeforeDownload + received) / Double(totalSize),
                        detail: "Downloading verified language files…"
                    )
                }
            }
            activeDownload = download
            try await withTaskCancellationHandler {
                try await download.start()
            } onCancel: {
                download.cancel()
            }
            activeDownload = nil
            guard try await Self.fileIsValid(file, at: destination) else {
                try? FileManager.default.removeItem(at: destination)
                throw LanguagePackError.integrityCheckFailed(file.path)
            }
            completedSize += file.size
        }
    }

    private static func writeInstallationMarker(
        manifest: LanguagePackManifest,
        to markerURL: URL
    ) throws {
        let files = Dictionary(uniqueKeysWithValues: manifest.files.map {
            ($0.path, VerifiedLanguagePackFile(size: $0.size, sha256: $0.sha256))
        })
        let marker = LanguagePackInstallationMarker(identifier: manifest.identifier, files: files)
        try JSONEncoder().encode(marker).write(to: markerURL, options: .atomic)
    }

    private static func hasCompleteInstallation(
        at markerURL: URL,
        in directory: URL,
        manifest: LanguagePackManifest,
        fileManager: FileManager
    ) -> Bool {
        guard let data = try? Data(contentsOf: markerURL),
              let marker = try? JSONDecoder().decode(LanguagePackInstallationMarker.self, from: data),
              marker.identifier == manifest.identifier,
              marker.files.count == manifest.files.count else { return false }
        return manifest.files.allSatisfy { file in
            guard marker.files[file.path] == VerifiedLanguagePackFile(
                size: file.size,
                sha256: file.sha256
            ) else { return false }
            let url = directory.appending(path: file.path)
            guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                  let size = (attributes[.size] as? NSNumber)?.int64Value else { return false }
            return file.size > 0 && size == file.size
        }
    }

    nonisolated static func validateInstallation(
        in directory: URL,
        manifest: LanguagePackManifest
    ) throws {
        for file in manifest.files {
            let url = directory.appending(path: file.path)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard (attributes[.size] as? NSNumber)?.int64Value == file.size,
                  try sha256(of: url) == file.sha256 else {
                throw LanguagePackError.integrityCheckFailed(file.path)
            }
        }
    }

    nonisolated private static func fileIsValid(
        _ file: PinnedLanguagePackFile,
        at url: URL
    ) async throws -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.size] as? NSNumber)?.int64Value == file.size else { return false }
        return try await Task.detached(priority: .utility) {
            try sha256(of: url) == file.sha256
        }.value
    }

    nonisolated private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 4 * 1_024 * 1_024), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
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
    private let validateInstallation: @Sendable () throws -> Void
    private var model: WhisperASRModel?

    init(
        modelDirectory: URL,
        validateInstallation: @escaping @Sendable () throws -> Void
    ) {
        self.modelDirectory = modelDirectory
        self.validateInstallation = validateInstallation
    }

    func prepare(
        offline: Bool,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) async throws {
        guard model == nil else {
            progress?(1, "Ready")
            return
        }
        try validateInstallation()
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
    case integrityCheckFailed(String)

    var errorDescription: String? {
        switch self {
        case .incompleteInstallation:
            return "The language pack did not finish writing all required files."
        case let .integrityCheckFailed(path):
            return "A language-pack file failed its integrity check: \(path)."
        case let .insufficientStorage(required, available):
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            return "The 100+ language pack needs \(formatter.string(fromByteCount: required)) free; \(formatter.string(fromByteCount: available)) is available."
        }
    }
}

struct PinnedLanguagePackFile: Sendable, Equatable {
    let repository: String
    let revision: String
    let path: String
    let size: Int64
    let sha256: String

    var downloadURL: URL {
        let escaped = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        return URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(escaped)?download=true")!
    }
}

struct LanguagePackManifest: Sendable, Equatable {
    let identifier: String
    let files: [PinnedLanguagePackFile]

    static let production: LanguagePackManifest = {
        let modelRepository = "aufklarer/Whisper-Large-v3-Turbo-CoreML"
        let modelRevision = "a8e93b2084b3d0a09765b2e3a5602a3d2b8f8d25"
        let tokenizerRepository = "openai/whisper-large-v3"
        let tokenizerRevision = "06f233fe06e710322aca913c1bc4249a0d71fce1"
        func model(_ path: String, _ size: Int64, _ sha256: String) -> PinnedLanguagePackFile {
            PinnedLanguagePackFile(
                repository: modelRepository,
                revision: modelRevision,
                path: path,
                size: size,
                sha256: sha256
            )
        }
        func tokenizer(_ path: String, _ size: Int64, _ sha256: String) -> PinnedLanguagePackFile {
            PinnedLanguagePackFile(
                repository: tokenizerRepository,
                revision: tokenizerRevision,
                path: path,
                size: size,
                sha256: sha256
            )
        }
        return LanguagePackManifest(
            identifier: "\(modelRepository)@\(modelRevision)+\(tokenizerRepository)@\(tokenizerRevision)",
            files: [
                model("AudioEncoder.mlmodelc/analytics/coremldata.bin", 243, "b58d36a7f4a729570b46b424ed8d847baefa07580e6cb9d47773ae738f8b845a"),
                model("AudioEncoder.mlmodelc/coremldata.bin", 348, "ffa9eb76e8e9d9be75a4d527e5249e61d67fd43081c5aa110fd24efa6c8c5ea3"),
                model("AudioEncoder.mlmodelc/metadata.json", 1_824, "3f8920fecd553c40dfc978e1b2664cefbac80d97937c2c160e079b37cfa95e13"),
                model("AudioEncoder.mlmodelc/model.mil", 7_175_750, "9aac7799f12bc5fc414cb0bd6b60536d4fb7723d8bb0d879e3c0ceb220b224aa"),
                model("AudioEncoder.mlmodelc/model.mlmodel", 441_653, "c5eb570c19871d7b0c59e0a84718cc9c8cde77a94273886de87e866961262e2c"),
                model("AudioEncoder.mlmodelc/weights/weight.bin", 1_273_974_400, "98daf651a919978e28fe185daf55ce2f70085a8e59fa07fe8a4d08c87d368ae4"),
                model("MelSpectrogram.mlmodelc/analytics/coremldata.bin", 243, "c5be419f8622083ac7046306400643539f0e7577c843448c36defc090d41e7ce"),
                model("MelSpectrogram.mlmodelc/coremldata.bin", 329, "98efa1e351b759e078c4044668926d32bee886caf7596ae897e08e21da45565a"),
                model("MelSpectrogram.mlmodelc/metadata.json", 1_850, "2bc552e09a6f124d9e6c178dd1a6979e010206acb26308b2224887c9dcbeb35f"),
                model("MelSpectrogram.mlmodelc/model.mil", 10_143, "c270b95b5f81d7f7d0b8a3e8f991d4e5812a37cad29349868a35b91f3a6a4463"),
                model("MelSpectrogram.mlmodelc/weights/weight.bin", 373_376, "009d9fb8f6b589accfa08cebf1c712ef07c3405229ce3cfb3a57ee033c9d8a49"),
                model("TextDecoder.mlmodelc/analytics/coremldata.bin", 243, "47703aed03fbfa5128e118cfe6519024006f953a53e921d66003f1412c27996c"),
                model("TextDecoder.mlmodelc/coremldata.bin", 633, "605dad4099a82cf2c7afe93e6d8e322f1c16d4160ab27bd017ec2517b81c1bdd"),
                model("TextDecoder.mlmodelc/metadata.json", 4_756, "de6afb1e8fa1d01568b8d96283ca17af19f6124f151d0fdbdbd5917edc7b4836"),
                model("TextDecoder.mlmodelc/model.mil", 132_680, "1a1c2ec962fc7c9d2de9e2e4cf2d3827c8671f86a918b5698c00bf62c322ed3f"),
                model("TextDecoder.mlmodelc/model.mlmodel", 113_164, "03b79e4355e814c56239ea809e5d8f6432d70d74256bc9d70c27184fe9fcec48"),
                model("TextDecoder.mlmodelc/weights/weight.bin", 343_933_748, "47b2703aa37448e09cf2f06e45984fabd5ded4c34ba3400cec38a5294af39dc1"),
                model("TextDecoderContextPrefill.mlmodelc/analytics/coremldata.bin", 243, "97639d36c7b137ea51c3c39b175911788f4d4a601ab03cd67a4b14164c3145e1"),
                model("TextDecoderContextPrefill.mlmodelc/coremldata.bin", 380, "2c159f5c862ec187092ea58e755d8c0b298952e22f3d75da023d7693c1c7389e"),
                model("TextDecoderContextPrefill.mlmodelc/metadata.json", 2_240, "eb88dc350fa6748a8bc3fa5fb10958152c138752ebbbac1824d2f99b4c9fc068"),
                model("TextDecoderContextPrefill.mlmodelc/model.mil", 4_092, "990ff5052fd817e28ba7c34d9d06d324c69c7c0630b6eaac9cfdf08329dbcb34"),
                model("TextDecoderContextPrefill.mlmodelc/weights/weight.bin", 12_288_192, "1310070082639173e9d81508c5f220692d489e85655aa6883cc1c7506da7fcfd"),
                model("generation_config.json", 2_767, "7fbb053a023be11fbeccd8421811610308143daa93d9617c52aab4a0fa1491c6"),
                tokenizer("tokenizer.json", 2_480_617, "6d8cbd7cd0d8d5815e478dac67b85a26bbe77c1f5e0c6d76d1ce2abc0e5f21ca"),
                tokenizer("tokenizer_config.json", 282_843, "844b642c73a91359722f47b35705f7174686df33d252695d8572cf9ac03a6389"),
            ]
        )
    }()
}

private struct LanguagePackInstallationMarker: Codable {
    let identifier: String
    let files: [String: VerifiedLanguagePackFile]
}

private struct VerifiedLanguagePackFile: Codable, Equatable {
    let size: Int64
    let sha256: String
}
