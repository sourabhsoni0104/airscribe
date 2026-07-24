import Foundation

enum WritingMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case email = "Email"
    case chat = "Chat"
    case post = "Post"
    case general = "General"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .email: "envelope"
        case .chat: "bubble.left.and.bubble.right"
        case .post: "megaphone"
        case .general: "text.cursor"
        }
    }

    var enhancementInstruction: String {
        switch self {
        case .email:
            "Rewrite only the main body as concise, professional email prose. Do not add a greeting, subject, signature, or sign-off. Preserve the speaker's intent and do not add facts."
        case .chat:
            "Write concise, natural chat prose. Keep the tone conversational and do not add facts."
        case .post:
            "Write clear, engaging social-post prose. Preserve the meaning and do not add claims."
        case .general:
            "Write clear general-purpose prose. Preserve meaning and do not add facts."
        }
    }
}

enum OutputLanguageMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case original = "Original language"
    case english = "Translate to English"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .original: "character.book.closed"
        case .english: "translate"
        }
    }
}

struct AppModeMapping: Identifiable, Codable, Equatable, Sendable {
    var id: String { bundleIdentifier }
    let bundleIdentifier: String
    var applicationName: String
    var mode: WritingMode
}

enum DictationPhase: Equatable, Sendable {
    case idle
    case peek
    case listening
    case processing
    case done
    case error(String)

    var isExpanded: Bool {
        switch self {
        case .peek, .listening, .processing, .done, .error: true
        case .idle: false
        }
    }
}

struct DictationRecord: Identifiable, Codable, Sendable {
    let id: UUID
    let createdAt: Date
    let rawText: String
    let enhancedText: String
    let mode: WritingMode
    let localeIdentifier: String
    let engine: String
    let latencyMilliseconds: Int
    let audioPath: String?

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        rawText: String,
        enhancedText: String,
        mode: WritingMode,
        localeIdentifier: String,
        engine: String,
        latencyMilliseconds: Int,
        audioPath: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.rawText = rawText
        self.enhancedText = enhancedText
        self.mode = mode
        self.localeIdentifier = localeIdentifier
        self.engine = engine
        self.latencyMilliseconds = latencyMilliseconds
        self.audioPath = audioPath
    }
}

enum AirScribeError: LocalizedError {
    case microphonePermissionDenied
    case accessibilityPermissionDenied
    case secureInputActive
    case speechUnavailable
    case unsupportedLocale(String)
    case emptyTranscription
    case audioConfiguration(String)

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            "Microphone access is required for dictation."
        case .accessibilityPermissionDenied:
            "Accessibility access is required for the Control shortcut and text insertion."
        case .secureInputActive:
            "Dictation is disabled while a secure text field is active."
        case .speechUnavailable:
            "The on-device speech engine is unavailable."
        case let .unsupportedLocale(identifier):
            "The selected language (\(identifier)) is not installed or supported yet."
        case .emptyTranscription:
            "No speech was detected."
        case let .audioConfiguration(message):
            "The microphone could not be configured: \(message)"
        }
    }
}
