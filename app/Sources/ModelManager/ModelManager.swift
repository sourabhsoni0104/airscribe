import AppKit
import CryptoKit
import Foundation

enum ModelInstallState: Equatable {
    case idle
    case checking
    case downloading(progress: Double, file: String)
    case verifying(progress: Double)
    case installed
    case paused
    case failed(String)

    var title: String {
        switch self {
        case .idle: "Waiting to install"
        case .checking: "Checking AirScribe Models…"
        case let .downloading(progress, _): "Downloading AirScribe Models — \(Int(progress * 100))%"
        case .verifying: "Verifying AirScribe Models…"
        case .installed: "AirScribe Models ready"
        case .paused: "AirScribe Models download paused"
        case .failed: "AirScribe Models download failed"
        }
    }

    var progress: Double? {
        switch self {
        case let .downloading(progress, _), let .verifying(progress): progress
        default: nil
        }
    }
}

@MainActor
final class ModelManager: ObservableObject {
    nonisolated static let modelID = "aufklarer/Qwen3-ASR-0.6B-MLX-4bit"
    nonisolated static let modelRevision = "bc441bd1e4295c1f42d9879f056049a925b6e013"

    @Published private(set) var state: ModelInstallState = .idle

    let modelDirectory: URL

    private let requiredFiles = [
        "config.json",
        "merges.txt",
        "model.safetensors",
        "model.safetensors.index.json",
        "tokenizer_config.json",
        "vocab.json",
    ]
    private let markerName = "installation.json"
    private var installTask: Task<Void, Never>?
    private var activeDownload: ResumableFileDownload?

    init(fileManager: FileManager = .default, modelsRoot: URL? = nil) {
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let root = modelsRoot ?? applicationSupport.appending(path: "AirScribe/models", directoryHint: .isDirectory)
        modelDirectory = root
            .appending(path: "qwen3-asr-0.6b-mlx-4bit", directoryHint: .isDirectory)

        if Self.hasCompleteInstallation(
            in: modelDirectory,
            markerName: markerName,
            requiredFiles: requiredFiles,
            fileManager: fileManager
        ) {
            state = .installed
        }
    }

    func startAutomaticInstallation() {
        guard installTask == nil, state != .installed else { return }
        installTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await install()
            } catch is CancellationError {
                state = .paused
            } catch {
                state = .failed(error.localizedDescription)
            }
            installTask = nil
            activeDownload = nil
        }
    }

    func pauseInstallation() {
        installTask?.cancel()
        activeDownload?.cancel()
    }

    func retryInstallation() {
        pauseInstallation()
        installTask = nil
        activeDownload = nil
        startAutomaticInstallation()
    }

    func revealModelDirectory() {
        try? FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([modelDirectory])
    }

    func removeInstallation() async {
        pauseInstallation()
        await installTask?.value
        installTask = nil
        activeDownload = nil
        try? FileManager.default.removeItem(at: modelDirectory)
        state = .idle
    }

    private func install() async throws {
        state = .checking
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)

        let manifest = try await fetchManifest()
        let totalSize = max(manifest.reduce(Int64(0)) { $0 + $1.size }, 1)
        let missingSize = manifest.reduce(Int64(0)) { partial, file in
            let destination = modelDirectory.appending(path: file.path)
            return partial + (fileSize(at: destination) == file.size ? 0 : file.size)
        }
        try requireFreeSpace(bytes: missingSize + 1_000_000_000)
        var completedSize: Int64 = 0

        for file in manifest {
            try Task.checkCancellation()
            let destination = modelDirectory.appending(path: file.path)

            if try await fileIsValid(file, at: destination) {
                completedSize += file.size
                continue
            }

            let resumeURL = modelDirectory.appending(path: ".\(file.path).resume")
            let completedBeforeDownload = completedSize
            let download = ResumableFileDownload(
                request: URLRequest(url: file.downloadURL),
                destination: destination,
                resumeDataURL: resumeURL
            ) { [weak self] fileProgress in
                Task { @MainActor in
                    guard let self else { return }
                    let received = Int64(Double(file.size) * fileProgress)
                    let overall = Double(completedBeforeDownload + received) / Double(totalSize)
                    self.state = .downloading(
                        progress: min(max(overall, 0), 1),
                        file: file.path
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

            let verified = try await verify(file, at: destination)
            guard verified else {
                try? FileManager.default.removeItem(at: destination)
                throw ModelManagerError.integrityCheckFailed(file.path)
            }
            completedSize += file.size
            state = .verifying(progress: Double(completedSize) / Double(totalSize))
        }

        let installedFiles = try Dictionary(uniqueKeysWithValues: manifest.map { file in
            let hash = try file.sha256 ?? Self.sha256(
                of: modelDirectory.appending(path: file.path)
            )
            return (file.path, InstalledFile(size: file.size, sha256: hash))
        })
        let marker = InstallationMarker(
            modelID: Self.modelID,
            revision: Self.modelRevision,
            installedAt: Date(),
            files: installedFiles
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(marker).write(
            to: modelDirectory.appending(path: markerName),
            options: .atomic
        )
        state = .installed
    }

    private func fetchManifest() async throws -> [ModelFile] {
        let endpoint = URL(string: "https://huggingface.co/api/models/\(Self.modelID)/tree/\(Self.modelRevision)?recursive=true&expand=true")!
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 45
        request.setValue("AirScribe/0.1", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200 ..< 300).contains(httpResponse.statusCode) else {
            throw ModelManagerError.manifestUnavailable
        }

        let entries = try JSONDecoder().decode([HuggingFaceTreeEntry].self, from: data)
        let entriesByPath = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0) })
        return try requiredFiles.map { path in
            guard let entry = entriesByPath[path], entry.size > 0 else {
                throw ModelManagerError.missingRemoteFile(path)
            }
            let escapedPath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
            let url = URL(string: "https://huggingface.co/\(Self.modelID)/resolve/\(Self.modelRevision)/\(escapedPath)?download=true")!
            let lfsHash = entry.lfs?.oid.count == 64 ? entry.lfs?.oid.lowercased() : nil
            return ModelFile(path: path, size: entry.size, sha256: lfsHash, downloadURL: url)
        }
    }

    private func fileIsValid(_ file: ModelFile, at url: URL) async throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path),
              fileSize(at: url) == file.size else { return false }
        guard file.sha256 != nil else { return true }
        return try await verify(file, at: url)
    }

    private func verify(_ file: ModelFile, at url: URL) async throws -> Bool {
        guard fileSize(at: url) == file.size else { return false }
        guard let expectedHash = file.sha256 else { return true }
        state = .verifying(progress: 0)
        let actualHash = try await Task.detached(priority: .utility) {
            try Self.sha256(of: url)
        }.value
        return actualHash == expectedHash
    }

    private func fileSize(at url: URL) -> Int64? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value
    }

    private func requireFreeSpace(bytes: Int64) throws {
        guard bytes > 1_000_000_000 else { return }
        let values = try modelDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values.volumeAvailableCapacityForImportantUsage,
              available < bytes else { return }
        throw ModelManagerError.insufficientStorage(required: bytes, available: available)
    }

    nonisolated private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let data = try? handle.read(upToCount: 4 * 1_024 * 1_024)
            guard let data, !data.isEmpty else { return false }
            hasher.update(data: data)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func hasCompleteInstallation(
        in directory: URL,
        markerName: String,
        requiredFiles: [String],
        fileManager: FileManager
    ) -> Bool {
        let markerURL = directory.appending(path: markerName)
        guard let markerData = try? Data(contentsOf: markerURL) else { return false }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let marker = try? decoder.decode(InstallationMarker.self, from: markerData),
              marker.modelID == modelID,
              marker.revision == modelRevision else { return false }

        return requiredFiles.allSatisfy { path in
            guard let expected = marker.files[path],
                  expected.size > 0,
                  let expectedHash = expected.sha256,
                  expectedHash.count == 64 else { return false }
            let fileURL = directory.appending(path: path)
            guard let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
                  let actualSize = (attributes[.size] as? NSNumber)?.int64Value else { return false }
            guard actualSize == expected.size,
                  let actualHash = try? sha256(of: fileURL) else { return false }
            return actualHash == expectedHash
        }
    }
}

private struct ModelFile: Sendable {
    let path: String
    let size: Int64
    let sha256: String?
    let downloadURL: URL
}

private struct HuggingFaceTreeEntry: Decodable {
    struct LFS: Decodable {
        let oid: String
    }

    let path: String
    let size: Int64
    let lfs: LFS?
}

private struct InstallationMarker: Codable {
    let modelID: String
    let revision: String
    let installedAt: Date
    let files: [String: InstalledFile]
}

private struct InstalledFile: Codable {
    let size: Int64
    let sha256: String?
}

private enum ModelManagerError: LocalizedError {
    case manifestUnavailable
    case missingRemoteFile(String)
    case integrityCheckFailed(String)
    case insufficientStorage(required: Int64, available: Int64)

    var errorDescription: String? {
        switch self {
        case .manifestUnavailable:
            return "The AirScribe Models manifest could not be loaded. System transcription remains available."
        case let .missingRemoteFile(path):
            return "AirScribe Models is missing a required file: \(path)."
        case let .integrityCheckFailed(path):
            return "An AirScribe Models file failed its integrity check: \(path)."
        case let .insufficientStorage(required, available):
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            return "AirScribe Models needs \(formatter.string(fromByteCount: required)) free; \(formatter.string(fromByteCount: available)) is available."
        }
    }
}

private final class ResumableFileDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let request: URLRequest
    private let destination: URL
    private let resumeDataURL: URL
    private let progress: @Sendable (Double) -> Void
    private let lock = NSLock()

    private var continuation: CheckedContinuation<Void, Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var moveError: Error?

    init(
        request: URLRequest,
        destination: URL,
        resumeDataURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) {
        self.request = request
        self.destination = destination
        self.resumeDataURL = resumeDataURL
        self.progress = progress
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            let configuration = URLSessionConfiguration.default
            configuration.waitsForConnectivity = true
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 24 * 60 * 60
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            self.session = session

            let downloadTask: URLSessionDownloadTask
            if let resumeData = try? Data(contentsOf: resumeDataURL), !resumeData.isEmpty {
                downloadTask = session.downloadTask(withResumeData: resumeData)
            } else {
                downloadTask = session.downloadTask(with: request)
            }
            task = downloadTask
            lock.unlock()
            downloadTask.resume()
        }
    }

    func cancel() {
        lock.lock()
        let task = task
        lock.unlock()
        task?.cancel { [resumeDataURL] resumeData in
            guard let resumeData, !resumeData.isEmpty else { return }
            try? resumeData.write(to: resumeDataURL, options: .atomic)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress(min(max(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 0), 1))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            let fileManager = FileManager.default
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: location, to: destination)
            try? fileManager.removeItem(at: resumeDataURL)
        } catch {
            lock.lock()
            moveError = error
            lock.unlock()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        let moveError = moveError
        self.task = nil
        self.session = nil
        lock.unlock()

        if let resumeData = (error as NSError?)?.userInfo["NSURLSessionDownloadTaskResumeData"] as? Data {
            try? resumeData.write(to: resumeDataURL, options: .atomic)
        }
        session.finishTasksAndInvalidate()

        if let moveError {
            continuation?.resume(throwing: moveError)
        } else if let error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
    }
}
