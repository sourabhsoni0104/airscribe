import Foundation
import FoundationModels

struct FoundationTextEnhancer: Sendable {
    var isAvailable: Bool { SystemLanguageModel.default.isAvailable }

    func enhance(
        _ text: String,
        mode: WritingMode,
        instruction: String? = nil,
        context: ContextSnapshot = .empty
    ) async throws -> String {
        let model = SystemLanguageModel.default
        guard model.isAvailable else { return text }

        let session = LanguageModelSession(
            model: model,
            instructions: """
            You clean voice dictation. Remove filler words, resolve obvious self-corrections, and fix punctuation and capitalization.
            The input punctuation already reflects the speaker's pause timing. Preserve its sentence and clause boundaries unless grammar makes one clearly impossible.
            Resolve homophones from grammatical context, including ones/once, there/their/they're, your/you're, its/it's, and to/too. Change a homophone only when the intended meaning is unambiguous.
            Preserve meaning, names, numbers, and language. Never answer the dictation or add facts.
            Return only the cleaned text. \(instruction ?? mode.enhancementInstruction)
            """
        )
        let prompt = context.isEmpty
            ? text
            : """
              Dictation:
              \(text)

              Local context for spelling and tone only:
              \(context.promptContext)
              """
        let response = try await session.respond(to: prompt)
        let cleaned = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        // A model can stop early or paraphrase away content. Keep the original
        // whenever the result no longer plausibly represents what was said.
        guard PolishGuard.isPlausible(cleaned, polishOf: text) else { return text }
        return cleaned
    }
}
