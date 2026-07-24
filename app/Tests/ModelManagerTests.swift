import Foundation
import XCTest
@testable import AirScribe

@MainActor
final class ModelManagerTests: XCTestCase {
    func testDownloadStateExposesProgress() {
        let state = ModelInstallState.downloading(progress: 0.42, file: "model.safetensors")
        XCTAssertEqual(state.progress, 0.42)
        XCTAssertEqual(state.title, "Downloading AirScribe Models 42%")
    }

    func testCompletedLocalSnapshotIsRecognizedWithoutNetwork() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "AirScribeModelManagerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let modelDirectory = root.appending(path: "qwen3-asr-0.6b-mlx-4bit", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let files = [
            "config.json",
            "merges.txt",
            "model.safetensors",
            "model.safetensors.index.json",
            "tokenizer_config.json",
            "vocab.json",
        ]
        let manifest = files.map {
            ModelFile(
                path: $0,
                size: 5,
                sha256: "ec654fac9599f62e79e2706abef23dfb7c07c08185aa86db4d8695f0b718d1b3"
            )
        }
        for file in files {
            XCTAssertTrue(FileManager.default.createFile(
                atPath: modelDirectory.appending(path: file).path,
                contents: Data("valid".utf8)
            ))
        }
        let marker = """
        {
          "modelID": "\(ModelManager.modelID)",
          "revision": "\(ModelManager.modelRevision)",
          "installedAt": "2026-07-24T00:00:00Z",
          "files": {
            \(files.map { "\"\($0)\":{\"size\":5,\"sha256\":\"ec654fac9599f62e79e2706abef23dfb7c07c08185aa86db4d8695f0b718d1b3\"}" }.joined(separator: ","))
          }
        }
        """
        try Data(marker.utf8).write(to: modelDirectory.appending(path: "installation.json"))

        let manager = ModelManager(modelsRoot: root, manifest: manifest)
        XCTAssertEqual(manager.state, .installed)
        XCTAssertNoThrow(try ModelManager.validateInstallation(in: modelDirectory, manifest: manifest))
    }

    func testTruncatedLocalSnapshotIsRejected() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "AirScribeModelManagerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let modelDirectory = root.appending(path: "qwen3-asr-0.6b-mlx-4bit", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let files = [
            "config.json", "merges.txt", "model.safetensors",
            "model.safetensors.index.json", "tokenizer_config.json", "vocab.json",
        ]
        let manifest = files.map {
            ModelFile(
                path: $0,
                size: 5,
                sha256: "ec654fac9599f62e79e2706abef23dfb7c07c08185aa86db4d8695f0b718d1b3"
            )
        }
        for file in files {
            try Data("valid".utf8).write(to: modelDirectory.appending(path: file))
        }
        try Data().write(to: modelDirectory.appending(path: "model.safetensors"))
        let marker = """
        {
          "modelID": "\(ModelManager.modelID)",
          "revision": "\(ModelManager.modelRevision)",
          "installedAt": "2026-07-24T00:00:00Z",
          "files": {
            \(files.map { "\"\($0)\":{\"size\":5,\"sha256\":\"ec654fac9599f62e79e2706abef23dfb7c07c08185aa86db4d8695f0b718d1b3\"}" }.joined(separator: ","))
          }
        }
        """
        try Data(marker.utf8).write(to: modelDirectory.appending(path: "installation.json"))

        XCTAssertEqual(ModelManager(modelsRoot: root, manifest: manifest).state, .idle)
    }

    func testInstallationMarkerCannotRedefinePinnedHash() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "AirScribeModelManagerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let modelDirectory = root.appending(path: "qwen3-asr-0.6b-mlx-4bit", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let file = ModelFile(
            path: "model.safetensors",
            size: 5,
            sha256: "ec654fac9599f62e79e2706abef23dfb7c07c08185aa86db4d8695f0b718d1b3"
        )
        try Data("evil!".utf8).write(to: modelDirectory.appending(path: file.path))
        let marker = """
        {
          "modelID": "\(ModelManager.modelID)",
          "revision": "\(ModelManager.modelRevision)",
          "installedAt": "2026-07-24T00:00:00Z",
          "files": {
            "\(file.path)": {
              "size": 5,
              "sha256": "45fb21aba54b2386b0a8b91d0a3c0d9e32a09688ac62ce6feb13b4351dfd46c6"
            }
          }
        }
        """
        try Data(marker.utf8).write(to: modelDirectory.appending(path: "installation.json"))

        XCTAssertEqual(ModelManager(modelsRoot: root, manifest: [file]).state, .idle)
        XCTAssertThrowsError(
            try ModelManager.validateInstallation(in: modelDirectory, manifest: [file])
        )

        let pinnedMarker = marker.replacingOccurrences(
            of: "45fb21aba54b2386b0a8b91d0a3c0d9e32a09688ac62ce6feb13b4351dfd46c6",
            with: file.sha256
        )
        try Data(pinnedMarker.utf8).write(to: modelDirectory.appending(path: "installation.json"))

        XCTAssertEqual(ModelManager(modelsRoot: root, manifest: [file]).state, .installed)
        XCTAssertThrowsError(
            try ModelManager.validateInstallation(in: modelDirectory, manifest: [file])
        )
    }

    func testDownloadCancelledBeforeStartNeverBegins() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "AirScribeDownloadTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "source")
        let destination = root.appending(path: "destination")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("payload".utf8).write(to: source)
        let download = ResumableFileDownload(
            request: URLRequest(url: source),
            destination: destination,
            resumeDataURL: root.appending(path: "resume")
        ) { _ in }

        download.cancel()

        do {
            try await download.start()
            XCTFail("A pre-cancelled download should not start")
        } catch is CancellationError {
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
    }
}
