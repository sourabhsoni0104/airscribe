import Foundation
import FoundationModels

/// The single place that talks to Apple Intelligence.
///
/// `SystemLanguageModel` and `LanguageModelSession` exist only on macOS 26, so
/// every use of them was pinning the whole app to that release. Routing them
/// through one type keeps the availability check in a single file: callers ask
/// whether the model is usable and get `nil` back when it is not, on any OS.
///
/// Returning `nil` rather than throwing is deliberate. Every caller already has a
/// non-generative path to fall back to, so "unavailable" is a normal outcome and
/// not an error to report.
struct OnDeviceLanguageModel: Sendable {
    var isAvailable: Bool {
        guard #available(macOS 26, *) else { return false }
        return SystemLanguageModel.default.isAvailable
    }

    /// Runs one prompt against the on-device model.
    ///
    /// Returns `nil` when the model is unavailable, when it produces nothing, or
    /// when the OS predates Apple Intelligence. Throws only what the model itself
    /// throws, so callers can distinguish a real failure from absence.
    func respond(instructions: String, to prompt: String) async throws -> String? {
        guard #available(macOS 26, *) else { return nil }
        let model = SystemLanguageModel.default
        guard model.isAvailable else { return nil }
        let session = LanguageModelSession(model: model, instructions: instructions)
        let response = try await session.respond(to: prompt)
        let value = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Same as `respond`, but treats a thrown error as absence.
    ///
    /// Useful where a failed generation and an unavailable model lead to exactly
    /// the same fallback.
    func attemptResponse(instructions: String, to prompt: String) async -> String? {
        try? await respond(instructions: instructions, to: prompt)
    }
}
