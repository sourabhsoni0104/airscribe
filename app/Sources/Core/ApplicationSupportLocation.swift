import Foundation

/// Resolves the Application Support directory without force-unwrapping.
///
/// `FileManager.urls(for:in:)` is documented to return an empty array when a
/// directory cannot be located, which on unusual accounts turned every store's
/// initializer into a launch crash. The documented per-user path is used as a
/// fallback so the app degrades to a normal file error instead.
enum ApplicationSupportLocation {
    static func root(_ fileManager: FileManager = .default) -> URL {
        if let url = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            return url
        }
        return URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory)
            .appending(path: "Library/Application Support", directoryHint: .isDirectory)
    }

    /// The app's own container inside Application Support.
    static func airScribeRoot(_ fileManager: FileManager = .default) -> URL {
        root(fileManager).appending(path: "AirScribe", directoryHint: .isDirectory)
    }
}

/// Keeps recordings and transcripts readable only by their owner.
enum FilePermissions {
    static let ownerOnlyFile: NSNumber = 0o600
    static let ownerOnlyDirectory: NSNumber = 0o700

    /// Re-applies owner-only permissions to a file.
    ///
    /// Audio writers such as `AVAudioFile` create or truncate the file
    /// themselves, which can discard the mode set when the placeholder was
    /// created, so the mode has to be reasserted after the writer opens it.
    @discardableResult
    static func restrictToOwner(
        at url: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        guard fileManager.fileExists(atPath: url.path) else { return false }
        do {
            try fileManager.setAttributes(
                [.posixPermissions: ownerOnlyFile],
                ofItemAtPath: url.path
            )
            return true
        } catch {
            return false
        }
    }
}
