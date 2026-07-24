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
        case let .downloading(progress, _): "Downloading AirScribe Models \(Int(progress * 100))%"
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

    nonisolated static let pinnedManifest = [
        ModelFile(path: "config.json", size: 7_187, sha256: "923618cf5ca452fda0253a6be5c1a17f94a2e4851d3b98beb45848565587bd72"),
        ModelFile(path: "merges.txt", size: 1_671_853, sha256: "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5"),
        ModelFile(path: "model.safetensors", size: 708_236_945, sha256: "70c7e67e588062adce4f10796e47ad42ead51c6671eda61a0987eae38ca95ddf"),
        ModelFile(path: "model.safetensors.index.json", size: 71_814, sha256: "e3bb80ef0fd42a5be07b04e90c97d60460bbde8af3531e0bfe9100a61404d81a"),
        ModelFile(path: "tokenizer_config.json", size: 12_487, sha256: "4942d005604266809309cabc9f4e9cb89ce855d59b14681fdc0e1cc62ea26c4c"),
        ModelFile(path: "vocab.json", size: 2_776_833, sha256: "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"),
    ]
    private let fileManager: FileManager
    private let manifest: [ModelFile]
    private let markerName = "installation.json"
    private var installTask: Task<Void, Never>?
    private var activeDownload: ResumableFileDownload?
    private var installationID: UUID?

    init(
        fileManager: FileManager = .default,
        modelsRoot: URL? = nil,
        manifest: [ModelFile] = ModelManager.pinnedManifest
    ) {
        self.fileManager = fileManager
        self.manifest = manifest
        let applicationSupport = ApplicationSupportLocation.root(fileManager)
        let root = modelsRoot ?? applicationSupport.appending(path: "AirScribe/models", directoryHint: .isDirectory)
        modelDirectory = root
            .appending(path: "qwen3-asr-0.6b-mlx-4bit", directoryHint: .isDirectory)

        if Self.hasCompleteInstallation(
            in: modelDirectory,
            markerName: markerName,
            manifest: manifest,
            fileManager: fileManager
        ) {
            state = .installed
        }
    }

    func startAutomaticInstallation() {
        guard installTask == nil, state != .installed else { return }
        beginInstallation(waitingFor: nil)
    }

    private func beginInstallation(waitingFor previousTask: Task<Void, Never>?) {
        let id = UUID()
        installationID = id
        installTask = Task { [weak self] in
            guard let self else { return }
            await previousTask?.value
            guard self.installationID == id else { return }
            guard !Task.isCancelled else {
                state = .paused
                installTask = nil
                activeDownload = nil
                return
            }
            do {
                try await install(id: id)
            } catch is CancellationError {
                if self.installationID == id { state = .paused }
            } catch {
                if self.installationID == id { state = .failed(error.localizedDescription) }
            }
            if self.installationID == id {
                installTask = nil
                activeDownload = nil
            }
        }
    }

    func pauseInstallation() {
        installTask?.cancel()
        activeDownload?.cancel()
    }

    func retryInstallation() {
        guard state != .installed else { return }
        let previousTask = installTask
        previousTask?.cancel()
        activeDownload?.cancel()
        beginInstallation(waitingFor: previousTask)
    }

    func revealModelDirectory() {
        try? fileManager.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([modelDirectory])
    }

    func removeInstallation() async {
        let previousTask = installTask
        previousTask?.cancel()
        activeDownload?.cancel()
        installationID = nil
        await previousTask?.value
        installTask = nil
        activeDownload = nil
        do {
            if fileManager.fileExists(atPath: modelDirectory.path) {
                try fileManager.removeItem(at: modelDirectory)
            }
            state = .idle
        } catch {
            state = .failed("AirScribe Models could not be removed: \(error.localizedDescription)")
        }
    }

    private func install(id: UUID) async throws {
        guard installationID == id else { throw CancellationError() }
        state = .checking
        try fileManager.createDirectory(at: modelDirectory, withIntermediateDirectories: true)

        let totalSize = max(manifest.reduce(Int64(0)) { $0 + $1.size }, 1)
        var validFiles = Set<String>()
        var missingSize: Int64 = 0
        for file in manifest {
            try Task.checkCancellation()
            let destination = modelDirectory.appending(path: file.path)
            if try await fileIsValid(file, at: destination) {
                validFiles.insert(file.path)
            } else {
                missingSize += file.size
            }
        }
        if missingSize > 0 {
            try requireFreeSpace(bytes: missingSize + 1_000_000_000)
        }
        var completedSize: Int64 = 0

        for file in manifest {
            try Task.checkCancellation()
            let destination = modelDirectory.appending(path: file.path)

            if validFiles.contains(file.path) {
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
                    guard let self, self.installationID == id else { return }
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

            guard installationID == id else { throw CancellationError() }
            let verified = try await verify(file, at: destination)
            guard installationID == id else { throw CancellationError() }
            guard verified else {
                try? fileManager.removeItem(at: destination)
                throw ModelManagerError.integrityCheckFailed(file.path)
            }
            completedSize += file.size
            state = .verifying(progress: Double(completedSize) / Double(totalSize))
        }

        guard installationID == id else { throw CancellationError() }
        let installedFiles = Dictionary(uniqueKeysWithValues: manifest.map { file in
            (file.path, InstalledFile(size: file.size, sha256: file.sha256))
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
        if installationID == id { state = .installed }
    }

    private func fileIsValid(_ file: ModelFile, at url: URL) async throws -> Bool {
        guard fileManager.fileExists(atPath: url.path),
              fileSize(at: url) == file.size else { return false }
        // The pre-download scan must not publish progress; doing so made the UI
        // flip between "Checking" and "Verifying 0%" once per manifest entry.
        return try await verify(file, at: url, reportsProgress: false)
    }

    private func verify(
        _ file: ModelFile,
        at url: URL,
        reportsProgress: Bool = true
    ) async throws -> Bool {
        guard fileSize(at: url) == file.size else { return false }
        if reportsProgress { state = .verifying(progress: 0) }
        let actualHash = try await Task.detached(priority: .utility) {
            try Self.sha256(of: url)
        }.value
        return actualHash == file.sha256
    }

    private func fileSize(at url: URL) -> Int64? {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
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

    nonisolated static func validateInstallation(
        in directory: URL,
        manifest: [ModelFile] = pinnedManifest,
        fileManager: FileManager = .default
    ) throws {
        guard hasCompleteInstallation(
            in: directory,
            markerName: "installation.json",
            manifest: manifest,
            fileManager: fileManager
        ) else {
            throw ModelManagerError.incompleteInstallation
        }
        for file in manifest {
            let url = directory.appending(path: file.path)
            guard try sha256(of: url) == file.sha256 else {
                throw ModelManagerError.integrityCheckFailed(file.path)
            }
        }
    }

    nonisolated private static func hasCompleteInstallation(
        in directory: URL,
        markerName: String,
        manifest: [ModelFile],
        fileManager: FileManager
    ) -> Bool {
        let markerURL = directory.appending(path: markerName)
        guard let markerData = try? Data(contentsOf: markerURL) else { return false }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let marker = try? decoder.decode(InstallationMarker.self, from: markerData),
              marker.modelID == modelID,
              marker.revision == modelRevision,
              marker.files.count == manifest.count else { return false }

        return manifest.allSatisfy { file in
            guard let expected = marker.files[file.path],
                  expected.size == file.size,
                  expected.sha256 == file.sha256 else { return false }
            let fileURL = directory.appending(path: file.path)
            guard let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
                  let actualSize = (attributes[.size] as? NSNumber)?.int64Value else { return false }
            return actualSize == file.size
        }
    }
}

struct ModelFile: Sendable, Equatable {
    let path: String
    let size: Int64
    let sha256: String

    var downloadURL: URL {
        let escapedPath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        return URL(
            string: "https://huggingface.co/\(ModelManager.modelID)/resolve/\(ModelManager.modelRevision)/\(escapedPath)?download=true"
        )!
    }
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
    case incompleteInstallation
    case integrityCheckFailed(String)
    case insufficientStorage(required: Int64, available: Int64)

    var errorDescription: String? {
        switch self {
        case .incompleteInstallation:
            return "AirScribe Models is incomplete or its installation record is invalid."
        case let .integrityCheckFailed(path):
            return "An AirScribe Models file failed its integrity check: \(path)."
        case let .insufficientStorage(required, available):
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            return "AirScribe Models needs \(formatter.string(fromByteCount: required)) free; \(formatter.string(fromByteCount: available)) is available."
        }
    }
}

enum ResumableDownloadError: LocalizedError {
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case let .httpStatus(status):
            "The download server replied with HTTP status \(status). Check your network or try again later."
        }
    }
}

final class ResumableFileDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let request: URLRequest
    private let destination: URL
    private let resumeDataURL: URL
    private let progress: @Sendable (Double) -> Void
    private let lock = NSLock()

    private var continuation: CheckedContinuation<Void, Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var moveError: Error?
    private var cancelled = false

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
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            guard !cancelled else {
                lock.unlock()
                continuation.resume(throwing: CancellationError())
                return
            }
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
        cancelled = true
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
        // URLSession delivers error pages as a successful download. Without a
        // status check an HTML 404 body is installed as the model file and only
        // surfaces later as a misleading integrity failure.
        if let http = downloadTask.response as? HTTPURLResponse,
           !(200 ..< 300).contains(http.statusCode) {
            lock.lock()
            moveError = ResumableDownloadError.httpStatus(http.statusCode)
            lock.unlock()
            try? FileManager.default.removeItem(at: resumeDataURL)
            return
        }
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
