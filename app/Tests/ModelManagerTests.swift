import Foundation
import XCTest
@testable import AirScribe

@MainActor
final class ModelManagerTests: XCTestCase {
    func testDownloadStateExposesProgress() {
        let state = ModelInstallState.downloading(progress: 0.42, file: "model.safetensors")
        XCTAssertEqual(state.progress, 0.42)
        XCTAssertEqual(state.title, "Downloading AirScribe Models — 42%")
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

        let manager = ModelManager(modelsRoot: root)
        XCTAssertEqual(manager.state, .installed)
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

        XCTAssertEqual(ModelManager(modelsRoot: root).state, .idle)
    }
}
