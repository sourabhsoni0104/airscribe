import Foundation

/// Decides whether a dictated email should be wrapped in a greeting and a
/// sign-off, and which register to use.
///
/// Dictating an email out loud gives you the body and nothing else. Adding the
/// wrapper by hand afterwards is the annoying part, but the wrapper has to match
/// how the message reads: "quick question, can we meet today" wants "Hi" and
/// "Regards", while "I would be grateful if you could review the attached
/// proposal" wants "Dear Sir/Madam" and "Yours sincerely".
///
/// Nothing is added when the speaker already dictated a greeting or a sign-off,
/// and no recipient name is ever invented.
enum EmailFraming {
    enum Register: Equatable {
        case formal
        case informal
    }

    /// Words and turns of phrase that place a message at one end of the range.
    /// Deliberately narrow: an unrecognised message is treated as informal,
    /// because "Hi" reads acceptably in a formal thread while "Dear Sir/Madam"
    /// on a quick note to a colleague does not.
    private static let formalMarkers = [
        #"\bkindly\b"#,
        #"\bplease find\b"#,
        #"\bwith reference to\b"#,
        #"\bwith regard to\b"#,
        #"\bas per\b"#,
        #"\bi would be grateful\b"#,
        #"\bi would like to (?:request|inform|bring)\b"#,
        #"\bi am writing to\b"#,
        #"\brequest you to\b"#,
        #"\bat your earliest convenience\b"#,
        #"\byour good ?self\b"#,
        #"\bthe undersigned\b"#,
        #"\bhereby\b"#,
        #"\bhenceforth\b"#,
        #"\bfurthermore\b"#,
        #"\bwe regret to\b"#,
        #"\bapologies for (?:any|the) inconvenience\b"#,
        #"\bawaiting your (?:response|reply|confirmation)\b"#,
        #"\bdo the needful\b"#,
        #"\b(?:sir|madam)\b"#,
        #"\bsubmission\b"#,
        #"\bin (?:this|that) regard\b"#
    ]

    private static let informalMarkers = [
        #"\b(?:hey|yeah|yep|nope|ok|okay|cool|awesome|sure)\b"#,
        #"\b(?:gonna|wanna|gotta|kinda|dunno)\b"#,
        #"\bno worries\b"#,
        #"\b(?:thanks|thx|cheers)\b"#,
        #"\bcatch up\b"#,
        #"\blet's\b"#,
        #"\bquick (?:question|call|one|chat)\b"#,
        #"\bheads up\b"#,
        #"\bping\b"#,
        #"\bguys\b"#
    ]

    /// A greeting the speaker dictated themselves, at the start of the message.
    private static let greetingPattern =
        #"(?i)\A\s*(?:hi|hey|hello|dear|respected|greetings|good\s+(?:morning|afternoon|evening|day))\b"#

    /// A sign-off on its own at the end of the message.
    private static let signOffPattern =
        #"(?i)(?:\A|\n|[.!?]\s+)(?:thanks(?:\s+(?:a\s+lot|so\s+much|again))?|thank\s+you|thanking\s+you|many\s+thanks|cheers|regards|warm\s+regards|kind\s+regards|best\s+regards|best|sincerely|yours\s+(?:sincerely|truly|faithfully))[,!.]?\s*\z"#

    static func register(of body: String) -> Register {
        let formalHits = formalMarkers.count { matches($0, in: body) }
        let informalHits = informalMarkers.count { matches($0, in: body) }
        if formalHits > informalHits { return .formal }
        if informalHits > formalHits { return .informal }
        // Even on markers, fall back to sentence shape. Formal writing avoids
        // contractions and runs longer.
        let hasContraction = matches(#"\b\w+['’](?:s|t|re|ve|ll|d|m)\b"#, in: body)
        let wordCount = body.split(whereSeparator: \.isWhitespace).count
        if !hasContraction, wordCount >= 45 { return .formal }
        return .informal
    }

    static func hasGreeting(_ text: String) -> Bool {
        matches(greetingPattern, in: text)
    }

    static func hasSignOff(_ text: String) -> Bool {
        matches(signOffPattern, in: text)
    }

    static func greeting(for register: Register) -> String {
        switch register {
        case .formal: "Dear Sir/Madam,"
        case .informal: "Hi,"
        }
    }

    static func signOff(for register: Register) -> String {
        switch register {
        case .formal: "Thanking you,\n\nYours sincerely,"
        case .informal: "Regards,"
        }
    }

    /// Wraps a dictated body in a greeting and sign-off that suit its register.
    ///
    /// Returns the body unchanged when it is empty, or when the speaker already
    /// provided the part that would be added.
    static func framed(_ body: String) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return body }

        let register = register(of: trimmed)
        var lines: [String] = []
        if !hasGreeting(trimmed) {
            lines.append(greeting(for: register))
        }
        lines.append(trimmed)
        if !hasSignOff(trimmed) {
            lines.append(signOff(for: register))
        }
        guard lines.count > 1 else { return trimmed }
        return lines.joined(separator: "\n\n")
    }

    private static func matches(_ pattern: String, in text: String) -> Bool {
        text.range(
            of: pattern,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }
}
