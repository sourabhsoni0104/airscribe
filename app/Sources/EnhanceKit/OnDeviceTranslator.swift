import Foundation
import FoundationModels

struct OnDeviceTranslator: Sendable {
    var isAvailable: Bool { SystemLanguageModel.default.isAvailable }

    func translateToEnglish(_ text: String) async throws -> String {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return text }
        let model = SystemLanguageModel.default
        guard model.isAvailable else { throw TranslationError.unavailable }

        let session = LanguageModelSession(
            model: model,
            instructions: """
            Translate the supplied speech transcript faithfully into natural English.
            Preserve every fact, name, number, URL, list, and formatting choice. Do not summarize, answer, explain, or add information.
            If the text is already English, return it unchanged. Return only the resulting text.
            """
        )
        let response = try await session.respond(to: value)
        let translated = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !translated.isEmpty else { throw TranslationError.emptyResponse }
        return translated
    }
}

enum TranslationError: LocalizedError {
    case unavailable
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "On-device English translation is not available on this Mac. The original transcript was kept."
        case .emptyResponse:
            "On-device translation returned no text. The original transcript was kept."
        }
    }
}
