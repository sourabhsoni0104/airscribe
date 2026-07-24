import Foundation

struct PauseAwarePunctuation {
    private struct Token {
        let word: String
        let normalized: String
        let trailingPunctuation: Character?
    }

    static func apply(
        to transcript: String,
        using timingGuide: String,
        timings: [TranscribedWordTiming],
        audioDuration: TimeInterval? = nil
    ) -> String {
        let target = tokens(in: transcript)
        let guide = tokens(in: timingGuide)
        guard target.count >= 2, guide.count >= 2 else { return transcript }

        let matches = alignedMatches(target: target, guide: guide)
        let matchedRatio = Double(matches.count) / Double(max(target.count, guide.count))
        guard matchedRatio >= 0.55 else { return transcript }

        let timingIndices = alignGuideToTimings(guide: guide, timings: timings)
        let targetToGuide = Dictionary(uniqueKeysWithValues: matches.map { ($0.target, $0.guide) })
        var rendered: [String] = []
        rendered.reserveCapacity(target.count)

        for index in target.indices {
            var word = target[index].word
            let guideIndex = targetToGuide[index]
            let punctuation: Character?
            if let guideIndex {
                punctuation = punctuationAfter(
                    guideIndex: guideIndex,
                    guide: guide,
                    timingIndices: timingIndices,
                    timings: timings,
                    audioDuration: audioDuration
                )
            } else {
                punctuation = target[index].trailingPunctuation
            }

            if index == 0 || rendered.last?.last.map({ ".!?".contains($0) }) == true {
                word = uppercaseFirstLetter(in: word)
            }
            if let punctuation { word.append(punctuation) }
            rendered.append(word)
        }
        return rendered.joined(separator: " ")
    }

    private static func punctuationAfter(
        guideIndex: Int,
        guide: [Token],
        timingIndices: [Int: Int],
        timings: [TranscribedWordTiming],
        audioDuration: TimeInterval?
    ) -> Character? {
        let existing = guide[guideIndex].trailingPunctuation
        if guideIndex == guide.count - 1,
           isHangingEnding(guide[guideIndex].normalized),
           let timingIndex = timingIndices[guideIndex],
           let audioDuration {
            let trailingSilence = audioDuration - timings[timingIndex].endTime
            if trailingSilence >= 0, trailingSilence < 0.38 { return "…" }
        }
        if existing.map({ "!?;:".contains($0) }) == true { return existing }
        guard guideIndex + 1 < guide.count,
              let timingIndex = timingIndices[guideIndex],
              let nextTimingIndex = timingIndices[guideIndex + 1],
              nextTimingIndex > timingIndex else { return existing }

        let pause = timings[nextTimingIndex].startTime - timings[timingIndex].endTime
        guard pause.isFinite, pause >= 0 else { return existing }
        let next = guide[guideIndex + 1].normalized
        let incompleteBefore = [
            "a", "an", "the", "to", "of", "for", "with", "at", "in", "on", "from",
            "my", "your", "our", "their", "this", "that", "these", "those"
        ].contains(guide[guideIndex].normalized)
        let tightlyConnectedAfter = [
            "to", "of", "for", "with", "that", "which", "who", "because", "if", "when"
        ].contains(next)

        if pause >= 1.05, !incompleteBefore {
            if ["and", "but", "or", "so", "because"].contains(next) || tightlyConnectedAfter {
                return existing ?? ","
            }
            return existing == "?" ? "?" : "."
        }
        if pause >= 0.48, !incompleteBefore, !tightlyConnectedAfter {
            return existing ?? ","
        }
        return existing
    }

    private static func isHangingEnding(_ word: String) -> Bool {
        [
            "a", "an", "the", "any", "some", "to", "of", "for", "with", "and", "or",
            "but", "because", "if", "when", "that", "which", "who", "my", "your", "our",
            "their", "this", "these", "those"
        ].contains(word)
    }

    private static func tokens(in text: String) -> [Token] {
        let pattern = #"[\p{L}\p{N}]+(?:['’\-][\p{L}\p{N}]+)*"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let string = text as NSString
        let matches = expression.matches(in: text, range: NSRange(location: 0, length: string.length))
        return matches.enumerated().map { index, match in
            let word = string.substring(with: match.range)
            let end = NSMaxRange(match.range)
            let nextStart = index + 1 < matches.count ? matches[index + 1].range.location : string.length
            let between = end < nextStart
                ? string.substring(with: NSRange(location: end, length: nextStart - end))
                : ""
            let punctuation = between.last(where: { ",;:.!?…".contains($0) })
            return Token(
                word: word,
                normalized: word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current),
                trailingPunctuation: punctuation
            )
        }
    }

    private static func alignedMatches(
        target: [Token],
        guide: [Token]
    ) -> [(target: Int, guide: Int)] {
        var lengths = Array(
            repeating: Array(repeating: 0, count: guide.count + 1),
            count: target.count + 1
        )
        for targetIndex in target.indices.reversed() {
            for guideIndex in guide.indices.reversed() {
                if target[targetIndex].normalized == guide[guideIndex].normalized {
                    lengths[targetIndex][guideIndex] = lengths[targetIndex + 1][guideIndex + 1] + 1
                } else {
                    lengths[targetIndex][guideIndex] = max(
                        lengths[targetIndex + 1][guideIndex],
                        lengths[targetIndex][guideIndex + 1]
                    )
                }
            }
        }

        var output: [(target: Int, guide: Int)] = []
        var targetIndex = 0
        var guideIndex = 0
        while targetIndex < target.count, guideIndex < guide.count {
            if target[targetIndex].normalized == guide[guideIndex].normalized {
                output.append((targetIndex, guideIndex))
                targetIndex += 1
                guideIndex += 1
            } else if lengths[targetIndex + 1][guideIndex] >= lengths[targetIndex][guideIndex + 1] {
                targetIndex += 1
            } else {
                guideIndex += 1
            }
        }
        return output
    }

    private static func alignGuideToTimings(
        guide: [Token],
        timings: [TranscribedWordTiming]
    ) -> [Int: Int] {
        let timingTokens = timings.map {
            $0.text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        }
        var output: [Int: Int] = [:]
        var timingIndex = 0
        for guideIndex in guide.indices {
            while timingIndex < timingTokens.count {
                if guide[guideIndex].normalized == timingTokens[timingIndex] {
                    output[guideIndex] = timingIndex
                    timingIndex += 1
                    break
                }
                timingIndex += 1
            }
        }
        return output
    }

    private static func uppercaseFirstLetter(in word: String) -> String {
        guard let index = word.firstIndex(where: \Character.isLetter) else { return word }
        var output = word
        output.replaceSubrange(index ... index, with: String(word[index]).uppercased())
        return output
    }
}

struct BasicTextEnhancer: Sendable {
    private static let fillerPatterns = [
        #"\b(?:um+|uh+|erm+|ah+)\b[,.]?\s*"#,
        #"\b(?:you know|I mean)\b[,.]?\s*"#,
        #"\bwith\s+like\s+"#
    ]

    func enhance(
        _ source: String,
        mode: WritingMode,
        vocabulary: [String] = [],
        learnedCorrections: [String: String] = [:]
    ) -> String {
        var text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return text }

        for pattern in Self.fillerPatterns {
            text = text.replacingOccurrences(
                of: pattern,
                with: pattern.contains("with") ? "with " : "",
                options: [.regularExpression, .caseInsensitive]
            )
        }

        text = replaceSpokenSymbols(in: text)
        text = text.replacingOccurrences(of: #"\bu\b"#, with: "you", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"\s+([,.;:!?])"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s*\n\s*"#, with: "\n", options: .regularExpression)

        for (heard, correction) in learnedCorrections.sorted(by: { $0.key.count > $1.key.count }) {
            guard !heard.isEmpty, !correction.isEmpty else { continue }
            guard !Self.isCaseOnlyCorrectionThatShouldNotPropagate(heard: heard, correction: correction) else {
                continue
            }
            let escaped = NSRegularExpression.escapedPattern(for: heard)
            text = text.replacingOccurrences(
                of: "(?i)\\b\(escaped)\\b",
                with: correction,
                options: .regularExpression
            )
        }

        for term in vocabulary where !term.isEmpty {
            let escaped = NSRegularExpression.escapedPattern(for: term)
            text = text.replacingOccurrences(of: "(?i)\\b\(escaped)\\b", with: term, options: .regularExpression)
        }

        text = resolveContextualHomophones(in: text)
        text = resolveSimpleSelfCorrections(in: text)
        text = uppercaseFirstLetter(in: text)
        text = punctuateConversationalOpener(in: text)

        let endsWithEmailSignOff = mode == .email && hasEmailSignOff(text)
        if let last = text.last, !".!?…".contains(last), !endsWithEmailSignOff {
            text.append(mode == .chat && text.count < 24 ? "!" : "?")
            if !looksLikeQuestion(text.dropLast()) {
                text.removeLast()
                text.append(".")
            }
        }

        text = punctuateDirectSpeech(in: text)

        return text
    }

    private func resolveContextualHomophones(in source: String) -> String {
        let replacements: [(pattern: String, replacement: String)] = [
            (#"\b(the|these|those|which|favorite|best|good|bad|new|old|right|wrong|other)\s+once\b"#, "$1 ones"),
            (#"\b(at|for)\s+ones\b"#, "$1 once"),
            (#"\bones\s+(a|an|again|more|before|after|when|if|I|you|we|they|he|she|it)\b"#, "once $1"),
            (#"\byour\s+(welcome|right|wrong|sure|going|doing|looking|trying|using)\b"#, "you're $1"),
            (#"\byou['’]re\s+(name|email|message|phone|idea|work|app|computer|text|voice)\b"#, "your $1"),
            (#"\btheir\s+(is|are|was|were)\b"#, "there $1"),
            (#"\bthere\s+(name|email|message|idea|team|work|app|computer|text|voice)\b"#, "their $1"),
            (#"\bits\s+(a|an|not|very|really|going|been)\b"#, "it's $1"),
            (#"\bit['’]s\s+(name|color|purpose|value|size|shape|way)\b"#, "its $1"),
            (#"\bto\s+(many|much|late|early|fast|slow|long|short|often)\b"#, "too $1"),
            (#"\btoo\s+(the|a|an|my|your|our|their|this|that)\b"#, "to $1"),
            (#"\b(should|could|would|might|must)\s+of\b"#, "$1 have"),
        ]
        return replacements.reduce(source) { result, rule in
            result.replacingOccurrences(
                of: rule.pattern,
                with: rule.replacement,
                options: [.regularExpression, .caseInsensitive]
            )
        }
    }

    private func replaceSpokenSymbols(in source: String) -> String {
        let atMarker = "\u{E000}"
        let dotMarker = "\u{E001}"
        let hashMarker = "\u{E002}"
        let directReplacements: [(pattern: String, replacement: String)] = [
            (#"\b(?:at\s+the\s+rate|at\s+rate|at)\s+(?:symbol|sign)\b"#, atMarker),
            (#"\b(?:dot|period)\s+symbol\b"#, dotMarker),
            (#"\b(?:hash|hashtag)\s+(?:symbol|sign)\b"#, hashMarker),
            (#"\bcomma\s+symbol\b"#, ","),
            (#"\bquestion\s+mark(?:\s+symbol)?\b"#, "?"),
            (#"\bexclamation\s+mark(?:\s+symbol)?\b"#, "!"),
            (#"\bcolon\s+symbol\b"#, ":"),
            (#"\bsemicolon\s+symbol\b"#, ";"),
            (#"\bunderscore\s+symbol\b"#, "_"),
            (#"\b(?:slash|forward\s+slash)\s+symbol\b"#, "/"),
        ]
        var text = directReplacements.reduce(source) { result, rule in
            result.replacingOccurrences(
                of: rule.pattern,
                with: rule.replacement,
                options: [.regularExpression, .caseInsensitive]
            )
        }

        text = text.replacingOccurrences(
            of: #"\s*"# + NSRegularExpression.escapedPattern(for: atMarker) + #"\s*"#,
            with: "@",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"\s*"# + NSRegularExpression.escapedPattern(for: dotMarker) + #"\s*"#,
            with: ".",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: NSRegularExpression.escapedPattern(for: hashMarker) + #"\s*"#,
            with: "#",
            options: .regularExpression
        )
        return text
    }

    private func resolveSimpleSelfCorrections(in source: String) -> String {
        source.replacingOccurrences(
            of: #"\b[^,.!?]{1,40}\b\s+(?:no,?\s+wait|sorry,?\s+I mean)\s+"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
    }

    private func uppercaseFirstLetter(in source: String) -> String {
        guard let index = source.firstIndex(where: { $0.isLetter }) else { return source }
        var result = source
        result.replaceSubrange(index...index, with: String(source[index]).uppercased())
        return result
    }

    private static func isCaseOnlyCorrectionThatShouldNotPropagate(
        heard: String,
        correction: String
    ) -> Bool {
        guard heard.caseInsensitiveCompare(correction) == .orderedSame,
              heard != correction else {
            return false
        }
        let normalizedHeard = heard.lowercased()
        return heard.count <= 2 || CorrectionLearner.commonWords.contains(normalizedHeard)
    }

    private func punctuateConversationalOpener(in source: String) -> String {
        source.replacingOccurrences(
            of: #"^(Hey|Hi|Hello)\s+(?=(?:can|could|would|will|do|does|is|are)\b)"#,
            with: "$1, ",
            options: [.regularExpression, .caseInsensitive]
        )
    }

    private func punctuateDirectSpeech(in source: String) -> String {
        guard !source.contains("“"), !source.contains("\"") else { return source }
        let pattern = #"(?i)^(.{1,100}\b(?:said|asked|replied|wrote|texted|shouted|whispered)(?:\s+to\s+[\p{L}\p{N}'’\-]+|\s+me)?)[,:]?\s+(.+?)([.!?…])$"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return source }
        let nsSource = source as NSString
        guard let match = expression.firstMatch(
            in: source,
            range: NSRange(location: 0, length: nsSource.length)
        ), match.numberOfRanges == 4 else { return source }

        let attribution = nsSource.substring(with: match.range(at: 1))
        var spoken = nsSource.substring(with: match.range(at: 2))
        let terminal = nsSource.substring(with: match.range(at: 3))
        let firstSpokenWord = spoken
            .split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
            .first?
            .lowercased() ?? ""
        let directSpeechStarters: Set<String> = [
            "i", "you", "we", "they", "he", "she", "it", "this", "that", "these", "those",
            "who", "what", "when", "where", "why", "how", "can", "could", "would", "will",
            "do", "does", "did", "is", "are", "was", "were", "have", "has", "should", "please"
        ]
        guard firstSpokenWord != "that", directSpeechStarters.contains(firstSpokenWord) else { return source }

        spoken = uppercaseFirstLetter(in: spoken)
        return "\(attribution), “\(spoken)\(terminal)”"
    }

    private func hasEmailSignOff(_ text: String) -> Bool {
        text.range(
            of: #"(?i)(?:^|\n|[.!?]\s+)(?:best|best regards|kind regards|regards|thanks|thank you|sincerely|cheers)[,!]?\s*$"#,
            options: .regularExpression
        ) != nil
    }

    private func looksLikeQuestion(_ source: Substring) -> Bool {
        let words = source
            .split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .map { $0.lowercased() }
        let greetingWords = ["hey", "hi", "hello"]
        let first = words.first.flatMap { greetingWords.contains($0) ? words.dropFirst().first : $0 } ?? ""
        return ["who", "what", "when", "where", "why", "how", "can", "could", "would", "will", "do", "does", "is", "are"].contains(first)
    }
}

struct CorrectionLearningResult: Equatable, Sendable {
    let replacements: [String: String]
    let vocabulary: [String]
}

struct CorrectionLearner: Sendable {
    static let commonWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "but", "by", "for", "from", "has", "have",
        "he", "her", "his", "i", "in", "is", "it", "its", "me", "my", "not", "of", "on", "or",
        "our", "she", "so", "that", "the", "their", "them", "they", "this", "to", "too", "was",
        "we", "were", "will", "with", "you", "your"
    ]

    func learn(from original: String, to corrected: String) -> CorrectionLearningResult? {
        let originalWords = words(in: original)
        let correctedWords = words(in: corrected)
        guard !originalWords.isEmpty,
              !correctedWords.isEmpty,
              abs(originalWords.count - correctedWords.count) <= 2,
              corrected.count <= max(original.count * 2, original.count + 24) else { return nil }

        var prefixCount = 0
        while prefixCount < min(originalWords.count, correctedWords.count),
              equal(originalWords[prefixCount], correctedWords[prefixCount]) {
            prefixCount += 1
        }

        var suffixCount = 0
        while suffixCount < min(originalWords.count, correctedWords.count) - prefixCount,
              equal(
                  originalWords[originalWords.count - suffixCount - 1],
                  correctedWords[correctedWords.count - suffixCount - 1]
              ) {
            suffixCount += 1
        }

        let originalEnd = originalWords.count - suffixCount
        let correctedEnd = correctedWords.count - suffixCount
        let removed = Array(originalWords[prefixCount ..< originalEnd])
        let added = Array(correctedWords[prefixCount ..< correctedEnd])
        guard !added.isEmpty, added.count <= 3, removed.count <= 3 else { return nil }

        var replacements: [String: String] = [:]
        if removed.count == 1, added.count == 1, !equal(removed[0], added[0]) {
            let heard = removed[0].lowercased()
            let correction = added[0]
            let caseOnlyChange = removed[0].caseInsensitiveCompare(correction) == .orderedSame
                && removed[0] != correction
            if caseOnlyChange, (heard.count <= 2 || Self.commonWords.contains(heard)) {
                return nil
            }
            replacements[removed[0].lowercased()] = added[0]
        }
        let vocabulary = added.filter { word in
            let normalized = word.lowercased()
            return word.count >= 2
                && word.allSatisfy { $0.isLetter || $0 == "'" || $0 == "’" || $0 == "-" }
                && !Self.commonWords.contains(normalized)
        }
        guard !replacements.isEmpty || !vocabulary.isEmpty else { return nil }
        return CorrectionLearningResult(replacements: replacements, vocabulary: vocabulary)
    }

    private func words(in value: String) -> [String] {
        value.split { character in
            !character.isLetter && character != "'" && character != "’" && character != "-"
        }.map(String.init)
    }

    private func equal(_ lhs: String, _ rhs: String) -> Bool {
        lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }
}
