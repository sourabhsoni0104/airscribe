import Foundation

/// Owner-only storage for preference values that contain the user's own speech.
///
/// Transcripts and recordings are kept at mode 0600 under Application Support,
/// but learned corrections, custom vocabulary, and per-mode instructions were
/// written to the app's `UserDefaults` plist, which carries default permissions
/// and is readable by any process running as the user. Those values are dictation
/// content, so they live beside the transcripts instead and are migrated out of
/// the defaults domain the first time this store is used.
final class SensitivePreferenceStore {
    static let fileName = "preferences.json"

    private let fileURL: URL
    private let fileManager: FileManager
    private var values: [String: Data] = [:]
    private(set) var lastError: String?

    init(fileManager: FileManager = .default, directory: URL? = nil) {
        self.fileManager = fileManager
        let root = directory ?? ApplicationSupportLocation.airScribeRoot(fileManager)
        fileURL = root.appending(path: Self.fileName)
        do {
            try fileManager.createDirectory(
                at: root,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: FilePermissions.ownerOnlyDirectory]
            )
            if fileManager.fileExists(atPath: fileURL.path) {
                let data = try Data(contentsOf: fileURL)
                values = try JSONDecoder().decode([String: Data].self, from: data)
                FilePermissions.restrictToOwner(at: fileURL, fileManager: fileManager)
            }
        } catch {
            // A damaged file must not wipe the user's settings on the next write,
            // so the failure is recorded and writes are refused until it clears.
            lastError = error.localizedDescription
        }
    }

    func value<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = values[key] else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    func setValue<T: Encodable>(_ value: T, forKey key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        values[key] = data
        persist()
    }

    func removeValue(forKey key: String) {
        guard values.removeValue(forKey: key) != nil else { return }
        persist()
    }

    func removeAll() {
        values.removeAll()
        lastError = nil
        do {
            if fileManager.fileExists(atPath: fileURL.path) {
                try fileManager.removeItem(at: fileURL)
            }
            // Leave nothing behind when this was the only file in the container.
            let directory = fileURL.deletingLastPathComponent()
            if let contents = try? fileManager.contentsOfDirectory(atPath: directory.path),
               contents.isEmpty {
                try? fileManager.removeItem(at: directory)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Moves a JSON-encoded value out of `UserDefaults` on first use.
    func migrateJSONValue<T: Codable>(
        _ type: T.Type,
        forKey key: String,
        from defaults: UserDefaults
    ) {
        guard values[key] == nil, let data = defaults.data(forKey: key) else { return }
        if (try? JSONDecoder().decode(type, from: data)) != nil {
            values[key] = data
            persist()
        }
        defaults.removeObject(forKey: key)
    }

    /// Moves a plain string array out of `UserDefaults` on first use.
    func migrateStringArray(forKey key: String, from defaults: UserDefaults) {
        guard values[key] == nil else {
            defaults.removeObject(forKey: key)
            return
        }
        guard let existing = defaults.stringArray(forKey: key) else { return }
        setValue(existing, forKey: key)
        defaults.removeObject(forKey: key)
    }

    private func persist() {
        guard lastError == nil else { return }
        do {
            // The container is removed by "delete all local data", and settings
            // reset to their defaults immediately afterwards, so the directory
            // has to be recreated rather than assumed present.
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: FilePermissions.ownerOnlyDirectory]
            )
            let data = try JSONEncoder().encode(values)
            try data.write(to: fileURL, options: .atomic)
            FilePermissions.restrictToOwner(at: fileURL, fileManager: fileManager)
        } catch {
            lastError = error.localizedDescription
        }
    }
}
