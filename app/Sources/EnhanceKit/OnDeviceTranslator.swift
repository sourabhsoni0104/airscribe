import Foundation

struct OnDeviceTranslator: Sendable {
    private let model = OnDeviceLanguageModel()

    func translateToEnglish(_ text: String) async throws -> String {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return text }
        guard model.isAvailable else { throw TranslationError.unavailable }

        guard let translated = try await model.respond(
            instructions: """
            Translate the supplied speech transcript faithfully into natural English.
            Preserve every fact, name, number, URL, list, and formatting choice. Do not summarize, answer, explain, or add information.
            If the text is already English, return it unchanged. Return only the resulting text.
            """,
            to: value
        ) else { throw TranslationError.emptyResponse }
        // Names, identifiers, and numbers the speaker said verbatim must survive
        // translation. Callers keep the original transcript when this throws.
        guard PolishGuard.isPlausibleTranslation(translated, of: value) else {
            throw TranslationError.implausibleResult
        }
        return translated
    }

    func romanizeHindi(_ text: String) async -> String {
        // Transliteration must never become translation. Keep this path
        // deterministic and only transform Devanagari runs; Latin text,
        // including English code-switching, passes through byte-for-byte.
        HindiRomanizer.romanize(text)
    }
}

enum HindiRomanizer {
    private static let commonWords: [String: String] = [
        "और": "aur", "मेरा": "mera", "मेरी": "meri", "मेरे": "mere", "नाम": "naam",
        "मैं": "main", "में": "mein", "हूँ": "hoon", "हूं": "hoon", "है": "hai",
        "हैं": "hain", "हो": "ho", "का": "ka", "की": "ki", "के": "ke", "यह": "yeh",
        "ये": "ye", "वह": "woh", "वो": "wo", "क्या": "kya", "नहीं": "nahi",
        "बहुत": "bahut", "अच्छा": "achha", "अच्छी": "achhi", "आप": "aap",
        "हम": "hum", "तुम": "tum", "मुझे": "mujhe", "चाहिए": "chahiye",
        "रहा": "raha", "रही": "rahi", "रहे": "rahe", "करता": "karta",
        "करती": "karti", "करते": "karte", "लड़का": "ladka", "लड़की": "ladki",
        "बोल": "bol", "बोलना": "bolna",
    ]

    private static let devanagariConsonants = CharacterSet(
        charactersIn: "\u{0915}\u{0916}\u{0917}\u{0918}\u{0919}\u{091A}\u{091B}\u{091C}\u{091D}\u{091E}\u{091F}\u{0920}\u{0921}\u{0922}\u{0923}\u{0924}\u{0925}\u{0926}\u{0927}\u{0928}\u{0929}\u{092A}\u{092B}\u{092C}\u{092D}\u{092E}\u{092F}\u{0930}\u{0931}\u{0932}\u{0933}\u{0934}\u{0935}\u{0936}\u{0937}\u{0938}\u{0939}\u{0958}\u{0959}\u{095A}\u{095B}\u{095C}\u{095D}\u{095E}\u{095F}"
    )

    static func containsDevanagari(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x0900 ... 0x097F).contains($0.value) }
    }

    static func romanize(_ text: String) -> String {
        guard containsDevanagari(text),
              let expression = try? NSRegularExpression(pattern: #"[\u0900-\u097F]+"#) else {
            return text
        }
        let output = NSMutableString(string: text)
        let source = text as NSString
        let matches = expression.matches(
            in: text,
            range: NSRange(location: 0, length: source.length)
        )
        for match in matches.reversed() {
            let token = source.substring(with: match.range)
            let replacement = commonWords[token] ?? romanizeToken(token)
            output.replaceCharacters(in: match.range, with: replacement)
        }
        return (output as String)
            .replacingOccurrences(of: "॥", with: ".")
            .replacingOccurrences(of: "।", with: ".")
    }

    private static func romanizeToken(_ token: String) -> String {
        guard var value = token.applyingTransform(
            StringTransform(rawValue: "Devanagari-Latin"),
            reverse: false
        ) else {
            return token
        }
        value = value.precomposedStringWithCanonicalMapping

        if value.hasSuffix("ā") {
            value.removeLast()
            value.append("a")
        } else if value.hasSuffix("ī") {
            value.removeLast()
            value.append("i")
        } else if value.hasSuffix("ū") {
            value.removeLast()
            value.append("u")
        } else if value.hasSuffix("ē") {
            value.removeLast()
            value.append("e")
        } else if value.hasSuffix("ō") {
            value.removeLast()
            value.append("o")
        }

        let replacements: [(String, String)] = [
            ("m\u{0310}", "n"), ("ṁ", "n"), ("ṃ", "n"),
            ("ā", "aa"), ("ī", "ee"), ("ū", "oo"), ("ē", "e"), ("ō", "o"),
            ("ṭh", "th"), ("ḍh", "dh"), ("ṭ", "t"), ("ḍ", "d"), ("ṛ", "d"),
            ("ṇ", "n"), ("ś", "sh"), ("ṣ", "sh"), ("ñ", "ny"), ("ṅ", "ng"),
            ("ḥ", "h"),
        ]
        for (source, replacement) in replacements {
            value = value.replacingOccurrences(of: source, with: replacement)
        }
        value = value.folding(
            options: [.diacriticInsensitive],
            locale: Locale(identifier: "hi-IN")
        )

        if let finalScalar = token.unicodeScalars.last,
           devanagariConsonants.contains(finalScalar),
           value.hasSuffix("a") {
            value.removeLast()
        }
        return value
    }
}

enum TranslationError: LocalizedError {
    case unavailable
    case emptyResponse
    case implausibleResult

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "On-device English translation is not available on this Mac. The original transcript was kept."
        case .emptyResponse:
            "On-device translation returned no text. The original transcript was kept."
        case .implausibleResult:
            "On-device translation dropped names or numbers, so the original transcript was kept."
        }
    }
}
