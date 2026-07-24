import Foundation

/// Validates generative polish before it replaces what the speaker actually said.
///
/// A language model can return text that is shorter than the input for two very
/// different reasons: it removed filler words, or its output was cut off by a
/// token limit. The second case silently deletes the end of a dictation, so
/// candidates that lose too much content — or that drop numbers — are rejected
/// and the unpolished text is kept instead.
enum PolishGuard {
    /// Polish may compress, but losing nearly half the words means the tail is
    /// missing rather than tightened.
    static let minimumRetainedWordRatio = 0.55

    static func isPlausible(_ candidate: String, polishOf original: String) -> Bool {
        let cleanedCandidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedOriginal = original.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedCandidate.isEmpty else { return false }
        guard !cleanedOriginal.isEmpty else { return true }

        let originalWords = words(in: cleanedOriginal)
        let candidateWords = words(in: cleanedCandidate)
        guard !originalWords.isEmpty else { return true }

        let floorCount = max(1, Int((Double(originalWords.count) * minimumRetainedWordRatio).rounded(.down)))
        guard candidateWords.count >= floorCount else { return false }

        // Runaway output means the model answered or padded the dictation.
        guard cleanedCandidate.count <= max(cleanedOriginal.count * 3, cleanedOriginal.count + 200) else {
            return false
        }

        // Numbers carry meaning that paraphrasing must not drop.
        let originalNumbers = cleanedOriginal.matches(of: /\p{Nd}+/).map { String($0.output) }
        return originalNumbers.allSatisfy { cleanedCandidate.contains($0) }
    }

    /// Validates a generated translation of a transcript.
    ///
    /// Translation legitimately rewrites almost every word, so length alone says
    /// nothing. What must survive is the material the speaker did not translate:
    /// Latin-script names and terms they said verbatim, and every number.
    static func isPlausibleTranslation(_ candidate: String, of original: String) -> Bool {
        let cleanedCandidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedOriginal = original.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedCandidate.isEmpty else { return false }
        guard !cleanedOriginal.isEmpty else { return true }
        guard cleanedCandidate.count >= max(1, cleanedOriginal.count / 3),
              cleanedCandidate.count <= max(cleanedOriginal.count * 3, cleanedOriginal.count + 40) else {
            return false
        }

        let originalLatinTerms = cleanedOriginal.matches(
            of: /[A-Za-z][A-Za-z0-9'’._-]*/
        ).map { String($0.output).lowercased() }
        let foldedCandidate = cleanedCandidate.lowercased()
        guard originalLatinTerms.allSatisfy({ foldedCandidate.contains($0) }) else {
            return false
        }

        let originalNumbers = cleanedOriginal.matches(of: /\p{Nd}+/).map { String($0.output) }
        return originalNumbers.allSatisfy { cleanedCandidate.contains($0) }
    }

    private static func words(in value: String) -> [String] {
        value.split(whereSeparator: \.isWhitespace).map(String.init)
    }
}
