import Foundation

struct AssistantInvocation: Equatable, Sendable {
    let command: String
}

struct AssistantEngine {
    private let languageModel = OnDeviceLanguageModel()

    /// The brand name spoken plainly, with or without a "hey" prefix.
    private static let wakePhrasePattern = try! NSRegularExpression(
        pattern: #"(?i)^\s*(?:hey[\s,;:!.?—–-]+)?air[\s-]*(?:scribe(?:s)?|scrib|stripe|script)\b[\s,;:!.?—–-]*(.*)$"#
    )

    /// "Scribe" and "a scribe" are ordinary English, so dictating "Scribe the
    /// meeting notes" must insert text rather than invoke the assistant. Those
    /// shortened forms only count as the wake word after an explicit "hey".
    private static let prefixedWakePhrasePattern = try! NSRegularExpression(
        pattern: #"(?i)^\s*hey[\s,;:!.?—–-]+(?:a[\s-]+)?scribe(?:s)?\b[\s,;:!.?—–-]*(.*)$"#
    )

    func invocation(in transcript: String) -> AssistantInvocation? {
        let cleaned = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(cleaned.startIndex..., in: cleaned)
        let rawCommand: String
        if let match = Self.wakePhrasePattern.firstMatch(in: cleaned, range: range),
           let commandRange = Range(match.range(at: 1), in: cleaned) {
            rawCommand = String(cleaned[commandRange])
        } else if let match = Self.prefixedWakePhrasePattern.firstMatch(in: cleaned, range: range),
                  let commandRange = Range(match.range(at: 1), in: cleaned) {
            rawCommand = String(cleaned[commandRange])
        } else if let fuzzyCommand = fuzzyWakePhraseCommand(in: cleaned) {
            rawCommand = fuzzyCommand
        } else {
            return nil
        }
        var command = rawCommand
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        if command.isEmpty { command = "How can you help with the current text?" }
        return AssistantInvocation(command: command)
    }

    private func fuzzyWakePhraseCommand(in transcript: String) -> String? {
        let words = transcript
            .split(whereSeparator: { $0.isWhitespace })
            .map { String($0).trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }
        let hasHey = words[0].lowercased() == "hey"
        let wakeWordStart = hasHey ? 1 : 0
        guard words.count > wakeWordStart else { return nil }

        let target = Array("airscribe")
        var best: (distance: Int, consumedWords: Int)?
        for consumedWords in 1 ... min(3, words.count - wakeWordStart) {
            let candidate = words[wakeWordStart ..< wakeWordStart + consumedWords]
                .joined()
                .lowercased()
                .filter(\.isLetter)
            guard (6 ... 11).contains(candidate.count) else { continue }
            let distance = Self.editDistance(Array(candidate), target)
            guard distance <= (hasHey ? 2 : 1) else { continue }
            if best == nil || distance < best!.distance {
                best = (distance, consumedWords)
            }
        }
        guard let best else { return nil }
        return words.dropFirst(wakeWordStart + best.consumedWords).joined(separator: " ")
    }

    private static func editDistance(_ lhs: [Character], _ rhs: [Character]) -> Int {
        var previous = Array(0 ... rhs.count)
        for (leftIndex, left) in lhs.enumerated() {
            var current = [leftIndex + 1]
            for (rightIndex, right) in rhs.enumerated() {
                let insertion = current[rightIndex] + 1
                let deletion = previous[rightIndex + 1] + 1
                let substitution = previous[rightIndex] + (left == right ? 0 : 1)
                current.append(min(min(insertion, deletion), substitution))
            }
            previous = current
        }
        return previous[rhs.count]
    }

    func isLikelyQuestion(_ transcript: String) -> Bool {
        let cleaned = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasSuffix("?") { return true }
        let words = cleaned
            .split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) }
        let greetingWords = ["hey", "hi", "hello"]
        let first = words.first.flatMap { greetingWords.contains($0) ? words.dropFirst().first : $0 } ?? ""
        return ["who", "what", "when", "where", "why", "how", "can", "could", "would", "will", "do", "does", "is", "are"].contains(first)
    }

    func respond(
        to invocation: AssistantInvocation,
        context: ContextSnapshot,
        recentText: [String]
    ) async throws -> String {
        let prompt = """
        Command: \(invocation.command)

        Current local context:
        \(context.promptContext.isEmpty ? "No app context was shared." : context.promptContext)

        Recent dictated text:
        \(recentText.isEmpty ? "None" : recentText.joined(separator: "\n"))
        """
        guard languageModel.isAvailable else {
            return deterministicFallback(invocation: invocation, context: context, recentText: recentText)
        }
        guard let value = try await languageModel.respond(
            instructions: """
            You are AirScribe's private inline writing assistant. Follow the user's command using only the supplied local context.
            Never claim to have opened, sent, deleted, or changed anything. Do not invent facts.
            Return only the text that should be inserted into the active app.
            """,
            to: prompt
        ) else { throw AssistantError.emptyResponse }
        return value
    }

    private func deterministicFallback(
        invocation: AssistantInvocation,
        context: ContextSnapshot,
        recentText: [String]
    ) -> String {
        let command = invocation.command.lowercased()
        if command.contains("what app"), let applicationName = context.applicationName {
            return "You are currently using \(applicationName)."
        }
        if command.contains("summar"), let source = context.focusedText ?? context.clipboardText ?? recentText.last {
            let sentences = source.split(whereSeparator: { ".!?".contains($0) }).prefix(3)
            return sentences.map { "- \($0.trimmingCharacters(in: .whitespacesAndNewlines))" }.joined(separator: "\n")
        }
        return recentText.last ?? context.focusedText ?? invocation.command
    }
}

enum AssistantError: LocalizedError {
    case emptyResponse

    var errorDescription: String? {
        "The on-device assistant returned no text."
    }
}
