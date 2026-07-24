import Foundation
import Security

struct CloudPolishConfiguration: Sendable {
    let endpoint: URL
    let model: String
    let apiKey: String
}

actor CloudTextEnhancer {
    private static let maximumResponseBytes = 1_048_576

    func enhance(
        _ text: String,
        instruction: String,
        configuration: CloudPolishConfiguration
    ) async throws -> String {
        guard configuration.endpoint.scheme?.lowercased() == "https",
              configuration.endpoint.host != nil,
              configuration.endpoint.user == nil,
              configuration.endpoint.password == nil else {
            throw CloudPolishError.insecureEndpoint
        }
        guard !configuration.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CloudPolishError.missingModel
        }

        var request = URLRequest(url: configuration.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            ResponseRequest(
                model: configuration.model,
                instructions: """
                You clean voice dictation. Remove filler words, resolve obvious self-corrections, and fix punctuation and capitalization.
                The input punctuation already reflects the speaker's pause timing. Preserve its sentence and clause boundaries unless grammar makes one clearly impossible.
                Resolve homophones from grammatical context, including ones/once, there/their/they're, your/you're, its/it's, and to/too. Change a homophone only when the intended meaning is unambiguous.
                Preserve meaning, names, numbers, and language. Never answer the dictation or add facts.
                Return only the cleaned text. \(instruction)
                """,
                input: text,
                store: false,
                maxOutputTokens: 1_024
            )
        )

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.urlCache = nil
        sessionConfiguration.httpCookieStorage = nil
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(
            configuration: sessionConfiguration,
            delegate: NoRedirectURLSessionDelegate(),
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw CloudPolishError.invalidResponse }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw CloudPolishError.requestFailed(status: http.statusCode)
        }
        if response.expectedContentLength > Self.maximumResponseBytes {
            throw CloudPolishError.responseTooLarge
        }
        var data = Data()
        data.reserveCapacity(Int(max(response.expectedContentLength, 0)))
        for try await byte in bytes {
            guard data.count < Self.maximumResponseBytes else {
                throw CloudPolishError.responseTooLarge
            }
            data.append(byte)
        }
        let payload = try JSONDecoder().decode(ResponsePayload.self, from: data)
        let result = payload.resolvedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { throw CloudPolishError.emptyResponse }
        return result
    }
}

struct CloudAPIKeyStore: Sendable {
    private let service = "com.airscribe.mac.cloud-polish"
    private let account = "byok"

    func read() throws -> String? {
        let query = readQuery(dataProtection: true)
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            var legacyItem: CFTypeRef?
            let legacyStatus = SecItemCopyMatching(
                readQuery(dataProtection: false) as CFDictionary,
                &legacyItem
            )
            if legacyStatus == errSecItemNotFound { return nil }
            guard legacyStatus == errSecSuccess,
                  let data = legacyItem as? Data,
                  let value = String(data: data, encoding: .utf8) else {
                throw CloudPolishError.keychain(status: legacyStatus)
            }
            try save(value)
            return value
        }
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw CloudPolishError.keychain(status: status)
        }
        return value
    }

    func save(_ value: String) throws {
        let data = Data(value.utf8)
        let query = baseQuery(dataProtection: true)
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw CloudPolishError.keychain(status: addStatus) }
        } else if status != errSecSuccess {
            throw CloudPolishError.keychain(status: status)
        }
        let legacyStatus = SecItemDelete(baseQuery(dataProtection: false) as CFDictionary)
        guard legacyStatus == errSecSuccess || legacyStatus == errSecItemNotFound else {
            throw CloudPolishError.keychain(status: legacyStatus)
        }
    }

    func delete() throws {
        let protectedStatus = SecItemDelete(baseQuery(dataProtection: true) as CFDictionary)
        let legacyStatus = SecItemDelete(baseQuery(dataProtection: false) as CFDictionary)
        for status in [protectedStatus, legacyStatus]
        where status != errSecSuccess && status != errSecItemNotFound {
            throw CloudPolishError.keychain(status: status)
        }
    }

    private func baseQuery(dataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    private func readQuery(dataProtection: Bool) -> [String: Any] {
        var query = baseQuery(dataProtection: dataProtection)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return query
    }
}

private final class NoRedirectURLSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

private struct ResponseRequest: Encodable {
    let model: String
    let instructions: String
    let input: String
    let store: Bool
    let maxOutputTokens: Int

    enum CodingKeys: String, CodingKey {
        case model, instructions, input, store
        case maxOutputTokens = "max_output_tokens"
    }
}

private struct ResponsePayload: Decodable {
    struct Output: Decodable {
        struct Content: Decodable {
            let type: String?
            let text: String?
        }
        let content: [Content]?
    }

    let outputText: String?
    let output: [Output]?

    enum CodingKeys: String, CodingKey {
        case outputText = "output_text"
        case output
    }

    var resolvedText: String {
        if let outputText, !outputText.isEmpty { return outputText }
        guard let output else { return "" }
        var parts: [String] = []
        for item in output {
            for content in item.content ?? [] {
                if content.type == nil || content.type == "output_text",
                   let value = content.text {
                    parts.append(value)
                }
            }
        }
        return parts.joined(separator: "\n")
    }
}

enum CloudPolishError: LocalizedError {
    case insecureEndpoint
    case missingModel
    case missingKey
    case invalidResponse
    case requestFailed(status: Int)
    case responseTooLarge
    case emptyResponse
    case keychain(status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .insecureEndpoint: "Cloud polish requires an HTTPS endpoint."
        case .missingModel: "Enter the model ID supplied by your API provider."
        case .missingKey: "Save an API key before enabling cloud polish."
        case .invalidResponse: "The cloud polish provider returned an invalid response."
        case let .requestFailed(status): "Cloud polish failed with HTTP status \(status)."
        case .responseTooLarge: "Cloud polish returned more data than AirScribe can safely process."
        case .emptyResponse: "Cloud polish returned no text."
        case .keychain: "The API key could not be stored securely in Keychain."
        }
    }
}
