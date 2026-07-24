import Foundation

struct PauseAwarePunctuation {
    private struct Token {
        let word: String
        let normalized: String
        let range: NSRange
        let trailingPunctuation: String?
        let trailingPunctuationRange: NSRange?
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
        let thresholds = pauseThresholds(timings: timings)
        var punctuation = target.map(\.trailingPunctuation)

        for index in target.indices {
            if let guideIndex = targetToGuide[index] {
                punctuation[index] = punctuationAfter(
                    guideIndex: guideIndex,
                    guide: guide,
                    timingIndices: timingIndices,
                    timings: timings,
                    audioDuration: audioDuration,
                    thresholds: thresholds,
                    targetPunctuation: target[index].trailingPunctuation
                )
            }
        }

        let source = transcript as NSString
        var edits: [(range: NSRange, replacement: String)] = []
        var capitalizeNext = true
        for index in target.indices {
            let token = target[index]
            if capitalizeNext, let capitalized = capitalizedWord(token.word), capitalized != token.word {
                edits.append((token.range, capitalized))
            }

            if punctuation[index] != token.trailingPunctuation {
                if let punctuationRange = token.trailingPunctuationRange {
                    edits.append((punctuationRange, punctuation[index] ?? ""))
                } else if let desired = punctuation[index] {
                    edits.append((NSRange(location: NSMaxRange(token.range), length: 0), desired))
                }
            }

            let boundary = punctuation[index] ?? token.trailingPunctuation
            capitalizeNext = (boundary.map(isSentenceTerminal) ?? false)
                && !isAbbreviationEnding(at: index, tokens: target, source: source)
            if !capitalizeNext, index + 1 < target.count {
                let gapStart = NSMaxRange(token.range)
                let gapEnd = target[index + 1].range.location
                if gapEnd > gapStart {
                    let gap = source.substring(with: NSRange(location: gapStart, length: gapEnd - gapStart))
                    capitalizeNext = gap.contains("\n")
                }
            }
        }

        let output = NSMutableString(string: transcript)
        for edit in edits.sorted(by: {
            if $0.range.location == $1.range.location { return $0.range.length > $1.range.length }
            return $0.range.location > $1.range.location
        }) {
            output.replaceCharacters(in: edit.range, with: edit.replacement)
        }
        return output as String
    }

    private static func punctuationAfter(
        guideIndex: Int,
        guide: [Token],
        timingIndices: [Int: Int],
        timings: [TranscribedWordTiming],
        audioDuration: TimeInterval?,
        thresholds: (comma: TimeInterval, sentence: TimeInterval),
        targetPunctuation: String?
    ) -> String? {
        let existing = guide[guideIndex].trailingPunctuation
        if guideIndex == guide.count - 1,
           isHangingEnding(guide[guideIndex].normalized),
           let timingIndex = timingIndices[guideIndex],
           let audioDuration {
            let trailingSilence = audioDuration - timings[timingIndex].endTime
            if trailingSilence >= 0, trailingSilence < 0.38 { return "…" }
        }
        if let existing {
            if let targetPunctuation,
               targetPunctuation.contains(where: { "!?…".contains($0) }),
               !existing.contains(where: { "!?…".contains($0) }) {
                return targetPunctuation
            }
            // System transcription commonly turns any noticeable hesitation into
            // a period. Require both timing and a plausible grammatical boundary
            // before transferring that period into the on-device transcript.
            if existing == ".",
               guideIndex + 1 < guide.count,
               let timingIndex = timingIndices[guideIndex],
               let nextTimingIndex = timingIndices[guideIndex + 1],
               nextTimingIndex > timingIndex {
                let pause = timings[nextTimingIndex].startTime - timings[timingIndex].endTime
                guard pause.isFinite, pause >= 0 else { return targetPunctuation }
                if pause < thresholds.sentence {
                    return pause >= thresholds.comma
                        && clauseWordCount(endingAt: guideIndex, guide: guide) >= 3 ? "," : nil
                }
                if clauseStartsWithSubordinator(endingAt: guideIndex, guide: guide)
                    || tightlyConnected(word: guide[guideIndex + 1].normalized) {
                    return ","
                }
                if !strongSentenceStart(word: guide[guideIndex + 1].normalized) {
                    return ","
                }
            }
            return existing
        }
        guard guideIndex + 1 < guide.count,
              let timingIndex = timingIndices[guideIndex],
              let nextTimingIndex = timingIndices[guideIndex + 1],
              nextTimingIndex > timingIndex else { return targetPunctuation }

        let pause = timings[nextTimingIndex].startTime - timings[timingIndex].endTime
        guard pause.isFinite, pause >= 0 else { return targetPunctuation }
        let next = guide[guideIndex + 1].normalized
        let current = guide[guideIndex].normalized
        let incompleteBefore: Set<String> = [
            "a", "an", "the", "to", "of", "for", "with", "at", "in", "on", "from",
            "my", "your", "our", "their", "this", "that", "these", "those", "and", "or",
            "but", "because", "if", "when", "while", "although", "is", "are", "was", "were",
            "have", "has", "had", "will", "would", "can", "could", "should"
        ]
        if pause >= thresholds.sentence, !incompleteBefore.contains(current) {
            if tightlyConnected(word: next)
                || clauseStartsWithSubordinator(endingAt: guideIndex, guide: guide) {
                return targetPunctuation ?? ","
            }
            if strongSentenceStart(word: next) {
                return terminalPunctuation(before: guideIndex, guide: guide)
            }
            return targetPunctuation ?? ","
        }
        if pause >= thresholds.comma,
           !incompleteBefore.contains(current),
           !tightlyConnected(word: next),
           clauseWordCount(endingAt: guideIndex, guide: guide) >= 3 {
            return targetPunctuation ?? ","
        }
        return targetPunctuation
    }

    private static func isHangingEnding(_ word: String) -> Bool {
        [
            "a", "an", "the", "any", "some", "to", "of", "for", "with", "and", "or",
            "but", "because", "if", "when", "that", "which", "who", "my", "your", "our",
            "their", "this", "these", "those"
        ].contains(word)
    }

    private static func pauseThresholds(
        timings: [TranscribedWordTiming]
    ) -> (comma: TimeInterval, sentence: TimeInterval) {
        let gaps = zip(timings, timings.dropFirst())
            .map { $1.startTime - $0.endTime }
            .filter { $0.isFinite && $0 >= 0 && $0 < 1.5 }
            .sorted()
        guard !gaps.isEmpty else { return (0.5, 1.15) }
        let median = gaps[gaps.count / 2]
        return (
            comma: min(0.72, max(0.42, median * 2.6)),
            sentence: min(1.5, max(0.9, median * 5.0))
        )
    }

    private static func tightlyConnected(word: String) -> Bool {
        [
            "to", "of", "for", "with", "that", "which", "who", "because", "if", "when",
            "whenever", "wherever", "while", "than", "and", "or", "but", "so", "yet"
        ].contains(word)
    }

    private static func strongSentenceStart(word: String) -> Bool {
        [
            "i", "you", "we", "they", "he", "she", "it", "this", "that", "these", "those",
            "please", "who", "what", "when", "where", "why", "how", "can", "could", "would",
            "will", "should", "do", "does", "did", "is", "are", "was", "were", "have", "has"
        ].contains(word)
    }

    private static func clauseStartsWithSubordinator(
        endingAt guideIndex: Int,
        guide: [Token]
    ) -> Bool {
        var start = guideIndex
        while start > 0 {
            if guide[start - 1].trailingPunctuation != nil { break }
            start -= 1
        }
        return [
            "although", "because", "if", "since", "unless", "until", "when", "whenever",
            "where", "wherever", "while"
        ].contains(guide[start].normalized)
    }

    private static func terminalPunctuation(before guideIndex: Int, guide: [Token]) -> String {
        var sentenceStart = guideIndex
        while sentenceStart > 0 {
            if guide[sentenceStart - 1].trailingPunctuation.map(isSentenceTerminal) == true {
                break
            }
            sentenceStart -= 1
        }
        let first = guide[sentenceStart].normalized
        let questionStarters: Set<String> = [
            "who", "what", "when", "where", "why", "how", "can", "could", "would", "will",
            "should", "do", "does", "did", "is", "are", "am", "was", "were", "have", "has", "had"
        ]
        return questionStarters.contains(first) ? "?" : "."
    }

    private static func clauseWordCount(endingAt guideIndex: Int, guide: [Token]) -> Int {
        var start = guideIndex
        while start > 0 {
            if guide[start - 1].trailingPunctuation != nil { break }
            start -= 1
        }
        return guideIndex - start + 1
    }

    private static func isSentenceTerminal(_ punctuation: String) -> Bool {
        punctuation.contains { ".!?…".contains($0) }
    }

    private static func isAbbreviationEnding(
        at index: Int,
        tokens: [Token],
        source: NSString
    ) -> Bool {
        let common: Set<String> = [
            "mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st", "vs", "etc", "fig", "dept", "inc"
        ]
        if common.contains(tokens[index].normalized) { return true }
        guard tokens[index].word.count == 1, index > 0, tokens[index - 1].word.count == 1 else {
            return false
        }
        let gapStart = NSMaxRange(tokens[index - 1].range)
        let gapEnd = tokens[index].range.location
        guard gapEnd > gapStart else { return false }
        return source.substring(
            with: NSRange(location: gapStart, length: gapEnd - gapStart)
        ).contains(".")
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
            let punctuation = trailingPunctuation(
                in: between,
                globalLocation: end,
                isFinalToken: index == matches.count - 1
            )
            return Token(
                word: word,
                normalized: word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current),
                range: match.range,
                trailingPunctuation: punctuation?.value,
                trailingPunctuationRange: punctuation?.range
            )
        }
    }

    private static func trailingPunctuation(
        in gap: String,
        globalLocation: Int,
        isFinalToken: Bool
    ) -> (value: String, range: NSRange)? {
        guard let expression = try? NSRegularExpression(pattern: #"[,:;.!?…]+"#) else { return nil }
        let nsGap = gap as NSString
        guard let match = expression.firstMatch(
            in: gap,
            range: NSRange(location: 0, length: nsGap.length)
        ) else { return nil }
        let remainderStart = NSMaxRange(match.range)
        let remainder = remainderStart < nsGap.length
            ? nsGap.substring(from: remainderStart)
            : ""
        let value = nsGap.substring(with: match.range)
        let isBoundary = isFinalToken
            || remainder.contains(where: \.isWhitespace)
            || value.contains(where: { "!?…".contains($0) })
        guard isBoundary else { return nil }
        return (
            value,
            NSRange(location: globalLocation + match.range.location, length: match.range.length)
        )
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

    private static func capitalizedWord(_ word: String) -> String? {
        guard let index = word.firstIndex(where: \Character.isLetter) else { return word }
        var output = word
        output.replaceSubrange(index ... index, with: String(word[index]).uppercased())
        return output
    }
}

struct BasicTextEnhancer: Sendable {
    static let maximumVocabularyTerms = 60

    static func deduplicated(_ terms: [String], limit: Int) -> [String] {
        var seen = Set<String>()
        var output: [String] = []
        for term in terms where !term.isEmpty {
            guard seen.insert(term.lowercased()).inserted else { continue }
            output.append(term)
            if output.count >= limit { break }
        }
        return output
    }

    private static let fillerRules: [(pattern: String, replacement: String)] = [
        (#"\b(?:um+|uh+|erm+|ah+)\b[,.]?\s*"#, ""),
        (#"^\s*(?:you know|like|let['’]s say)[,.]?\s+"#, ""),
        (#"(?<=,)\s*(?:you know|I mean|like|let['’]s say)[,.]?\s*"#, " "),
        (#"\bwith\s+like\s+"#, "with ")
    ]

    func enhance(
        _ source: String,
        mode: WritingMode,
        vocabulary: [String] = [],
        learnedCorrections: [String: String] = [:]
    ) -> String {
        var text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return text }

        // Resolve an explicit repair before removing discourse markers such as
        // “I mean”; otherwise both the mistaken and corrected word survive.
        text = resolveSelfCorrections(in: text)

        for rule in Self.fillerRules {
            text = text.replacingOccurrences(
                of: rule.pattern,
                with: rule.replacement,
                options: [.regularExpression, .caseInsensitive]
            )
        }

        text = replaceSpokenSymbols(in: text)
        // Expand a standalone "u" only when it cannot be an initial or an
        // abbreviation component. A neighbouring period means "U.S." or "a. u.",
        // where "you" would corrupt the text.
        text = text.replacingOccurrences(
            of: #"(?<![\p{L}\p{N}.])u(?![\p{L}\p{N}.])"#,
            with: "you",
            options: [.regularExpression, .caseInsensitive]
        )
        text = removeStrandedDeterminers(in: text)
        text = text.replacingOccurrences(of: #"\s+([,.;:!?])"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"[ \t]*\n[ \t]*"#, with: "\n", options: .regularExpression)

        for (heard, correction) in learnedCorrections.sorted(by: { $0.key.count > $1.key.count }) {
            guard !heard.isEmpty, !correction.isEmpty else { continue }
            guard !Self.shouldNotPropagate(heard: heard, correction: correction) else {
                continue
            }
            let escaped = heard
                .split(whereSeparator: \.isWhitespace)
                .map { NSRegularExpression.escapedPattern(for: String($0)) }
                .joined(separator: #"\s+"#)
            text = text.replacingOccurrences(
                of: #"(?i)(?<![\p{L}\p{N}])"# + escaped + #"(?![\p{L}\p{N}])"#,
                with: correction,
                options: .regularExpression
            )
        }

        // Each `replacingOccurrences(options: .regularExpression)` compiles a new
        // expression, and the split-variant loop multiplies that by term length.
        // Gate every pass behind a cheap literal search so an unrelated
        // vocabulary list costs one substring scan per term instead of a
        // compiled regex sweep.
        for term in Self.deduplicated(vocabulary, limit: Self.maximumVocabularyTerms) {
            if text.range(of: term, options: .caseInsensitive) != nil {
                let escaped = NSRegularExpression.escapedPattern(for: term)
                text = text.replacingOccurrences(
                    of: "(?i)\\b\(escaped)\\b",
                    with: term,
                    options: .regularExpression
                )
            }
            guard term.count >= 6, term.allSatisfy(\.isLetter) else { continue }
            for split in 3 ... (term.count - 3) {
                let index = term.index(term.startIndex, offsetBy: split)
                let head = String(term[..<index])
                let tail = String(term[index...])
                guard text.range(of: head, options: .caseInsensitive) != nil,
                      text.range(of: tail, options: .caseInsensitive) != nil else { continue }
                let spaced = NSRegularExpression.escapedPattern(for: head)
                    + #"\s+"#
                    + NSRegularExpression.escapedPattern(for: tail)
                text = text.replacingOccurrences(
                    of: #"(?i)\b"# + spaced + #"\b"#,
                    with: term,
                    options: .regularExpression
                )
            }
        }

        text = resolveContextualHomophones(in: text)
        text = uppercaseFirstLetter(in: text)
        text = punctuateConversationalOpener(in: text)

        let endsWithEmailSignOff = mode == .email && hasEmailSignOff(text)
        if let last = text.last, !".!?…".contains(last), !endsWithEmailSignOff {
            // Question wins over tone: a short chat question takes "?", not "!".
            if looksLikeQuestion(text[...]) {
                text.append("?")
            } else if mode == .chat, text.count < 24 {
                text.append("!")
            } else {
                text.append(".")
            }
        }

        text = punctuateDirectSpeech(in: text)

        return text
    }

    /// Drops a determiner left stranded in front of a word it cannot modify.
    ///
    /// Restarting a phrase mid-sentence leaves the article behind, as in "the it
    /// shouldn't be hardcoded". No determiner can precede a pronoun or an
    /// auxiliary verb, so the leftover word is safe to remove and the sentence
    /// reads correctly again.
    private func removeStrandedDeterminers(in source: String) -> String {
        let followers = [
            "it", "he", "she", "they", "we", "you", "its", "his", "her", "their",
            "our", "my", "your", "is", "are", "was", "were", "am", "be", "been",
            "should", "shouldn't", "would", "wouldn't", "could", "couldn't",
            "can", "can't", "will", "won't", "do", "does", "did", "don't",
            "doesn't", "didn't", "has", "have", "had", "hasn't", "haven't"
        ].joined(separator: "|")
        return source.replacingOccurrences(
            of: #"(?i)(?<![\p{L}\p{N}])(?:the|an|a)\s+(?=(?:"# + followers + #")(?![\p{L}\p{N}]))"#,
            with: "",
            options: .regularExpression
        )
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
        let literalFullStopMarker = "\u{E003}"
        let capitalizeAfterMarker = "\u{E004}"
        var protected = source

        // Preserve “full stop” when grammar shows that the speaker is talking
        // about the word or punctuation mark. Unclear uses remain words; only
        // an unambiguous dictation command is converted below.
        protected = protected.replacingOccurrences(
            of: #"(\b(?:a|an|the|this|that|another|literal|word|words|phrase|term|text|string|say|says|said|saying|hear|hears|heard|write|writes|wrote|writing|type|types|typed|typing|print|prints|printed|printing|spell|spells|spelled|spelling|pronounce|pronounces|pronounced|pronouncing|call|calls|called|mean|means|meaning|read|reads|show|shows|showed|display|displays|displayed|want|wants|wanted)\s+)full\s+stop\b"#,
            with: "$1\(literalFullStopMarker)",
            options: [.regularExpression, .caseInsensitive]
        )
        protected = protected.replacingOccurrences(
            of: #"\bfull\s+stop\b(?=\s+(?:is|isn't|isnt|means|meant|refers|sounds|spells|should|must|can|could|would|was|were|to\s+be|as\s+a)\b)"#,
            with: literalFullStopMarker,
            options: [.regularExpression, .caseInsensitive]
        )
        protected = protected.replacingOccurrences(
            of: #"\b((?:what\s+(?:is|does)|(?:word|words|phrase|term|text|string)\s+is)\s+)full\s+stop\b"#,
            with: "$1\(literalFullStopMarker)",
            options: [.regularExpression, .caseInsensitive]
        )
        protected = protected.replacingOccurrences(
            of: #"^\s*full\s+stop\s*$"#,
            with: literalFullStopMarker,
            options: [.regularExpression, .caseInsensitive]
        )

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
            (#"\bfull\s+stop\s+(?:symbol|mark)\b"#, ".\(capitalizeAfterMarker)"),
            (
                #"\bfull\s+stop\b(?=\s+(?:(?:then|next)\s+)?(?:I|you|we|they|he|she|it|this|that|these|those|please|who|what|when|where|why|how|can|could|would|will|should|do|does|did|is|are|was|were|have|has|start|continue|add|make|put|open|close|create|go|take|give|tell|write|read|show|use|keep|move|call|email|send)\b)"#,
                ".\(capitalizeAfterMarker)"
            ),
            (#"\bfull\s+stop\b(?=\s*$)"#, "."),
        ]
        var text = directReplacements.reduce(protected) { result, rule in
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
        text = text.replacingOccurrences(of: literalFullStopMarker, with: "full stop")
        while let markerRange = text.range(of: capitalizeAfterMarker) {
            let markerOffset = text.distance(from: text.startIndex, to: markerRange.lowerBound)
            text.removeSubrange(markerRange)
            let searchStart = text.index(
                text.startIndex,
                offsetBy: min(markerOffset, text.count)
            )
            if let nextLetter = text[searchStart...].firstIndex(where: \.isLetter) {
                text.replaceSubrange(
                    nextLetter ... nextLetter,
                    with: String(text[nextLetter]).uppercased()
                )
            }
        }
        return text
    }

    private func resolveSelfCorrections(in source: String) -> String {
        let explicitRepairRules: [(pattern: String, replacement: String)] = [
            (
                #"\b([\p{L}\p{N}'’\-]+)\s*[,—-]?\s+(?:no\s*,?\s*wait|sorry\s*,?\s*(?:I\s+mean)?|I\s+mean|rather|correction)\s*[,—-]?\s+([\p{L}\p{N}'’\-]+)\b"#,
                "$2"
            ),
            (
                #"\b([\p{L}\p{N}'’\-]+)\s*,?\s+but\s+I\s+meant\s+([\p{L}\p{N}'’\-]+)\b"#,
                "$2"
            ),
            (
                #"\b([\p{L}\p{N}'’\-]+)\s+(?:because\s+)?([\p{L}\p{N}'’\-]+)\s+is\s+what\s+I\s+meant(?:\s+to\s+say)?\b"#,
                "$2"
            ),
        ]
        let text = explicitRepairRules.reduce(source) { result, rule in
            result.replacingOccurrences(
                of: rule.pattern,
                with: rule.replacement,
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return Self.collapsingStutters(in: text)
    }

    /// English repeats some words legitimately ("had had", "very very good"), so
    /// a blanket adjacent-duplicate collapse changes meaning. Only collapse
    /// repeats of words that are not idiomatically doubled.
    static func collapsingStutters(in source: String) -> String {
        guard let expression = try? NSRegularExpression(
            pattern: #"(?i)\b([\p{L}\p{N}'’\-]+)((?:[\s,]+\1\b){1,})"#
        ) else { return source }
        let text = source as NSString
        let matches = expression.matches(
            in: source,
            range: NSRange(location: 0, length: text.length)
        )
        let output = NSMutableString(string: source)
        for match in matches.reversed() {
            let word = text.substring(with: match.range(at: 1))
            guard !Self.repeatableWords.contains(word.lowercased()) else { continue }
            output.replaceCharacters(in: match.range, with: word)
        }
        return output as String
    }

    /// Words whose immediate repetition is grammatical or conventional.
    static let repeatableWords: Set<String> = [
        "had", "that", "very", "no", "yes", "ha", "hah", "so", "bye", "hey",
        "well", "really", "many", "long", "far", "again", "more", "less", "good"
    ]

    private func uppercaseFirstLetter(in source: String) -> String {
        guard let index = source.firstIndex(where: { $0.isLetter }) else { return source }
        var result = source
        result.replaceSubrange(index...index, with: String(source[index]).uppercased())
        return result
    }

    /// A learned correction is replayed against every later dictation, so a rule
    /// keyed on an everyday word ("to" → "too") would rewrite unrelated text
    /// forever. Only distinctive keys (names, jargon, multi-word phrases) are
    /// safe to propagate.
    /// Whether a correction is safe to replay in apps other than the one it was
    /// taught in.
    ///
    /// Fixing a name or a piece of jargon is a transcription fix and belongs
    /// everywhere. Rewriting a word to a shorter, lowercase form is a house style
    /// ("our" to "r" for a forum post), and applying that everywhere silently
    /// mangles ordinary writing. Style therefore stays local to its app.
    static func appliesInEveryApp(heard: String, correction: String) -> Bool {
        guard let first = correction.first(where: \.isLetter) else { return false }
        guard first.isUppercase else { return false }
        // A shortening is an abbreviation, not a spelling fix, whatever its case.
        return correction.count >= heard.count
    }

    static func shouldNotPropagate(heard: String, correction: String) -> Bool {
        let normalizedHeard = heard.lowercased()
        let heardWords = normalizedHeard.split(whereSeparator: \.isWhitespace)
        if heardWords.count <= 1, CorrectionLearner.commonWords.contains(normalizedHeard) {
            return true
        }
        if heard.count <= 2 { return true }
        guard heard.caseInsensitiveCompare(correction) == .orderedSame,
              heard != correction else {
            return false
        }
        return CorrectionLearner.commonWords.contains(normalizedHeard)
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
    /// Everyday words that must never key a learned correction.
    ///
    /// A rule is replayed against every later dictation, so one edit of a word
    /// this common would silently rewrite unrelated text forever. The list
    /// deliberately includes both sides of the homophone pairs a speaker is most
    /// likely to correct by hand (there/their, your/you're, its/it's, to/too)
    /// because those are exactly the edits that must stay local to one dictation.
    /// Distinctive keys and multi-word phrases are still learned normally.
    static let commonWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "been", "being", "but", "by", "for", "from",
        "has", "had", "have", "he", "her", "here", "hear", "his", "how", "i", "if", "in", "into",
        "is", "it", "its", "it's", "me", "my", "no", "nor", "not", "of", "on", "once", "one",
        "ones", "or", "our", "out", "over", "she", "so", "some", "than", "that", "the", "their",
        "them", "then", "there", "these", "they", "they're", "this", "those", "to", "too", "two",
        "under", "up", "was", "we", "were", "what", "when", "where", "which", "while", "who",
        "whose", "who's", "why", "will", "with", "would", "yes", "you", "your", "you're"
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
        guard !added.isEmpty, added.count <= 4, removed.count <= 4 else { return nil }
        // An insertion bounded by unchanged words on both sides can be a missing
        // name or term. Text added before or after the dictation is ordinary
        // continued typing and must not be learned.
        if removed.isEmpty, prefixCount == 0 || suffixCount == 0 {
            return nil
        }

        var replacements: [String: String] = [:]
        if !removed.isEmpty {
            let heard = removed.joined(separator: " ").lowercased()
            let correction = added.joined(separator: " ")
            // Never record a rule that a later dictation would replay across
            // ordinary words; the same guard gates playback in BasicTextEnhancer.
            if BasicTextEnhancer.shouldNotPropagate(heard: heard, correction: correction) {
                return nil
            }
            replacements[heard] = correction
        }
        let vocabularyCandidates = removed.isEmpty ? [added.joined(separator: " ")] : added
        let vocabulary = vocabularyCandidates.filter { word in
            let normalized = word.lowercased()
            return word.count >= 2
                && word.allSatisfy { $0.isLetter || $0.isWhitespace || $0 == "'" || $0 == "’" || $0 == "-" }
                && !Self.commonWords.contains(normalized)
                && word != normalized
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
