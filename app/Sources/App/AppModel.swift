import AppKit
import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var phase: DictationPhase = .idle
    @Published var selectedSettingsSection: SettingsSection = .general
    @Published var selectedMode: WritingMode {
        didSet { defaults.set(selectedMode.rawValue, forKey: Keys.mode) }
    }
    @Published var dictationHotkey: DictationHotkey {
        didSet {
            defaults.set(dictationHotkey.rawValue, forKey: Keys.dictationHotkey)
            hotkey.selectedHotkey = dictationHotkey
            if didStart {
                restartHotkeyIfAuthorized()
            }
        }
    }
    @Published var partialTranscript = ""
    @Published var audioLevel: Float = 0
    @Published var localeIdentifier: String {
        didSet { defaults.set(localeIdentifier, forKey: Keys.locale) }
    }
    @Published var outputLanguageMode: OutputLanguageMode {
        didSet { defaults.set(outputLanguageMode.rawValue, forKey: Keys.outputLanguageMode) }
    }
    @Published var preferExtendedLanguages: Bool {
        didSet { defaults.set(preferExtendedLanguages, forKey: Keys.preferExtendedLanguages) }
    }
    @Published var useAppleIntelligence: Bool {
        didSet { defaults.set(useAppleIntelligence, forKey: Keys.appleIntelligence) }
    }
    @Published var customVocabulary: [String] {
        didSet { sensitivePreferences.setValue(customVocabulary, forKey: Keys.vocabulary) }
    }
    @Published var learnFromCorrections: Bool {
        didSet {
            defaults.set(learnFromCorrections, forKey: Keys.learnFromCorrections)
            if !learnFromCorrections {
                correctionLearningTasks.values.forEach { $0.cancel() }
                correctionLearningTasks = [:]
                correctionLearningTaskOrder = []
                clipboardCorrectionLearningTask?.cancel()
                clipboardCorrectionLearningTask = nil
            }
        }
    }
    @Published private(set) var learnedCorrections: [String: String] {
        didSet { sensitivePreferences.setValue(learnedCorrections, forKey: Keys.learnedCorrections) }
    }
    /// Insertion order of `learnedCorrections`, oldest first, so the dictionary
    /// can be capped instead of growing without bound for the app's lifetime.
    private var learnedCorrectionOrder: [String] {
        didSet { sensitivePreferences.setValue(learnedCorrectionOrder, forKey: Keys.learnedCorrectionOrder) }
    }
    /// Bundle identifier of the app each correction was taught in, so a house
    /// style learned in one place is not replayed across everything the user
    /// writes. See `BasicTextEnhancer.appliesInEveryApp`.
    @Published private(set) var learnedCorrectionScopes: [String: String] {
        didSet { sensitivePreferences.setValue(learnedCorrectionScopes, forKey: Keys.learnedCorrectionScopes) }
    }

    /// Ceiling on retained correction rules. Each rule is replayed against every
    /// later dictation, so the set has to stay small enough to stay predictable.
    static let maximumLearnedCorrections = 200
    @Published var onboardingComplete: Bool {
        didSet { defaults.set(onboardingComplete, forKey: Keys.onboardingComplete) }
    }
    @Published var modeInstructions: [String: String] {
        didSet { sensitivePreferences.setValue(modeInstructions, forKey: Keys.modeInstructions) }
    }
    @Published var automaticModeSelection: Bool {
        didSet { defaults.set(automaticModeSelection, forKey: Keys.automaticModeSelection) }
    }
    @Published var appModeMappings: [AppModeMapping] {
        didSet { persist(appModeMappings, key: Keys.appModeMappings) }
    }
    @Published private(set) var lastExternalApplicationName = ""
    @Published private(set) var lastExternalBundleIdentifier = ""
    @Published var cloudPolishEnabled: Bool {
        didSet { defaults.set(cloudPolishEnabled, forKey: Keys.cloudPolishEnabled) }
    }
    @Published var cloudEndpoint: String {
        didSet { defaults.set(cloudEndpoint, forKey: Keys.cloudEndpoint) }
    }
    @Published var cloudModel: String {
        didSet { defaults.set(cloudModel, forKey: Keys.cloudModel) }
    }
    /// Host the user confirmed as an acceptable destination for their API key.
    /// Required before polish will send a key to an unrecognised provider.
    @Published var acknowledgedCloudHost: String {
        didSet { defaults.set(acknowledgedCloudHost, forKey: Keys.acknowledgedCloudHost) }
    }
    /// When false, an insertion AirScribe cannot verify reports an error instead
    /// of overwriting whatever the user had on the clipboard.
    @Published var clipboardFallbackEnabled: Bool {
        didSet { defaults.set(clipboardFallbackEnabled, forKey: Keys.clipboardFallbackEnabled) }
    }
    /// Whether Email mode wraps a dictated body in a greeting and sign-off that
    /// match its register. See `EmailFraming`.
    @Published var emailFramingEnabled: Bool {
        didSet { defaults.set(emailFramingEnabled, forKey: Keys.emailFramingEnabled) }
    }

    var cloudEndpointHost: String {
        URL(string: cloudEndpoint)?.host?.lowercased() ?? ""
    }

    var cloudEndpointNeedsAcknowledgement: Bool {
        let host = cloudEndpointHost
        guard !host.isEmpty else { return false }
        return !CloudTextEnhancer.isKnownProviderHost(host) && acknowledgedCloudHost != host
    }

    func acknowledgeCloudEndpointHost() {
        acknowledgedCloudHost = cloudEndpointHost
    }
    @Published private(set) var cloudKeyConfigured = false
    @Published private(set) var isUsingCloud = false
    @Published private(set) var lastCloudError: String?
    @Published var waitForPolish: Bool {
        didSet { defaults.set(waitForPolish, forKey: Keys.waitForPolish) }
    }
    @Published var contextAwarenessEnabled: Bool {
        didSet { defaults.set(contextAwarenessEnabled, forKey: Keys.contextAwarenessEnabled) }
    }
    @Published var clipboardContextEnabled: Bool {
        didSet { defaults.set(clipboardContextEnabled, forKey: Keys.clipboardContextEnabled) }
    }
    @Published var screenContextEnabled: Bool {
        didSet { defaults.set(screenContextEnabled, forKey: Keys.screenContextEnabled) }
    }
    @Published var assistantEnabled: Bool {
        didSet { defaults.set(assistantEnabled, forKey: Keys.assistantEnabled) }
    }
    @Published var excludedContextApps: [String] {
        didSet { defaults.set(excludedContextApps, forKey: Keys.excludedContextApps) }
    }
    @Published private(set) var lastContextSummary = "No context captured"
    @Published private(set) var dataDeletionError: String?

    let history = HistoryStore()
    let permissions = PermissionManager()
    let modelManager = ModelManager()
    let languagePackManager = LanguagePackManager()
    let launchAtLogin = LaunchAtLoginManager()
    let updates = UpdateController()
    let recovery = RecoveryStore.shared
    lazy var meetings = MeetingCoordinator(speechEngine: speechEngine, permissions: permissions)

    private let defaults = UserDefaults.standard
    private let sensitivePreferences = SensitivePreferenceStore()
    private let hotkey = ControlHotkeyMonitor()
    private var peekDismissalTask: Task<Void, Never>?
    private let microphone = MicrophoneCapture()
    private lazy var speechEngine = ASREngineRouter(
        modelManager: modelManager,
        languagePackManager: languagePackManager
    )
    private let basicEnhancer = BasicTextEnhancer()
    private let correctionLearner = CorrectionLearner()
    private let foundationEnhancer = FoundationTextEnhancer()
    private let cloudEnhancer = CloudTextEnhancer()
    private let cloudAPIKeyStore = CloudAPIKeyStore()
    private let contextManager = ContextManager()
    private let assistantEngine = AssistantEngine()
    private let translator = OnDeviceTranslator()
    private let textInserter = TextInserter()
    private let notchPanel = NotchPanelController()

    private var activeSession: (any TranscriptionSession)?
    private var activeAudioURL: URL?
    private var dictationStartedAt: ContinuousClock.Instant?
    private var dictationStartupInFlight = false
    private var pendingDictationEnd = false
    private var didStart = false
    private var modelStateObservation: AnyCancellable?
    private var applicationObservation: AnyCancellable?
    private var permissionObservation: AnyCancellable?
    private var correctionLearningTasks: [UUID: Task<Void, Never>] = [:]
    private var correctionLearningTaskOrder: [UUID] = []
    private var clipboardCorrectionLearningTask: Task<Void, Never>?
    private var learningFeedbackTask: Task<Void, Never>?
    private var activeContext: ContextSnapshot = .empty

    private enum Keys {
        static let mode = "writingMode"
        static let dictationHotkey = "dictationHotkey"
        static let locale = "localeIdentifier"
        static let outputLanguageMode = "outputLanguageMode"
        static let preferExtendedLanguages = "preferExtendedLanguages"
        static let appleIntelligence = "useAppleIntelligence"
        static let vocabulary = "customVocabulary"
        static let learnFromCorrections = "learnFromCorrections"
        static let learnedCorrections = "learnedCorrections"
        static let learnedCorrectionOrder = "learnedCorrectionOrder"
        static let learnedCorrectionScopes = "learnedCorrectionScopes"
        static let onboardingComplete = "onboardingComplete"
        static let modeInstructions = "modeInstructions"
        static let automaticModeSelection = "automaticModeSelection"
        static let appModeMappings = "appModeMappings"
        static let cloudPolishEnabled = "cloudPolishEnabled"
        static let cloudEndpoint = "cloudEndpoint"
        static let cloudModel = "cloudModel"
        static let waitForPolish = "waitForPolish"
        static let contextAwarenessEnabled = "contextAwarenessEnabled"
        static let clipboardContextEnabled = "clipboardContextEnabled"
        static let screenContextEnabled = "screenContextEnabled"
        static let assistantEnabled = "assistantEnabled"
        static let excludedContextApps = "excludedContextApps"
        static let acknowledgedCloudHost = "acknowledgedCloudHost"
        static let clipboardFallbackEnabled = "clipboardFallbackEnabled"
        static let emailFramingEnabled = "emailFramingEnabled"

        /// Every key this app writes to its defaults domain.
        ///
        /// `removePersistentDomain(forName:)` is documented as being for *other*
        /// applications' domains and does not reliably clear the running
        /// process's own cached suite, so "delete all local data" removes each
        /// key explicitly before falling back to the domain wipe.
        static let all: [String] = [
            mode, dictationHotkey, locale, outputLanguageMode, preferExtendedLanguages,
            appleIntelligence, vocabulary, learnFromCorrections, learnedCorrections,
            learnedCorrectionOrder, learnedCorrectionScopes, onboardingComplete, modeInstructions,
            automaticModeSelection, appModeMappings, cloudPolishEnabled, cloudEndpoint,
            cloudModel, waitForPolish, contextAwarenessEnabled, clipboardContextEnabled,
            screenContextEnabled, assistantEnabled, excludedContextApps,
            acknowledgedCloudHost, clipboardFallbackEnabled, emailFramingEnabled
        ]
    }

    private init() {
        // Dictation content that used to sit in the defaults plist moves to the
        // owner-only store before any of it is read back.
        sensitivePreferences.migrateJSONValue(
            [String: String].self,
            forKey: Keys.learnedCorrections,
            from: defaults
        )
        sensitivePreferences.migrateJSONValue(
            [String: String].self,
            forKey: Keys.modeInstructions,
            from: defaults
        )
        sensitivePreferences.migrateStringArray(forKey: Keys.vocabulary, from: defaults)

        selectedMode = WritingMode(rawValue: defaults.string(forKey: Keys.mode) ?? "") ?? .general
        dictationHotkey = DictationHotkey(
            rawValue: defaults.string(forKey: Keys.dictationHotkey) ?? ""
        ) ?? .control
        localeIdentifier = defaults.string(forKey: Keys.locale) ?? "en-US"
        outputLanguageMode = OutputLanguageMode(
            rawValue: defaults.string(forKey: Keys.outputLanguageMode) ?? ""
        ) ?? .original
        preferExtendedLanguages = defaults.bool(forKey: Keys.preferExtendedLanguages)
        useAppleIntelligence = defaults.object(forKey: Keys.appleIntelligence) as? Bool ?? true
        customVocabulary = sensitivePreferences.value([String].self, forKey: Keys.vocabulary) ?? []
        learnFromCorrections = defaults.object(forKey: Keys.learnFromCorrections) as? Bool ?? true
        let storedCorrections = sensitivePreferences
            .value([String: String].self, forKey: Keys.learnedCorrections) ?? [:]
        learnedCorrections = storedCorrections
        learnedCorrectionOrder = (sensitivePreferences
            .value([String].self, forKey: Keys.learnedCorrectionOrder) ?? [])
            .filter { storedCorrections[$0] != nil }
        learnedCorrectionScopes = (sensitivePreferences
            .value([String: String].self, forKey: Keys.learnedCorrectionScopes) ?? [:])
            .filter { storedCorrections[$0.key] != nil }
        onboardingComplete = defaults.bool(forKey: Keys.onboardingComplete)
        modeInstructions = sensitivePreferences.value([String: String].self, forKey: Keys.modeInstructions)
            ?? Dictionary(uniqueKeysWithValues: WritingMode.allCases.map { ($0.rawValue, $0.enhancementInstruction) })
        automaticModeSelection = defaults.object(forKey: Keys.automaticModeSelection) as? Bool ?? true
        appModeMappings = Self.decode([AppModeMapping].self, from: defaults, key: Keys.appModeMappings) ?? []
        cloudPolishEnabled = defaults.bool(forKey: Keys.cloudPolishEnabled)
        cloudEndpoint = defaults.string(forKey: Keys.cloudEndpoint) ?? "https://api.openai.com/v1/responses"
        cloudModel = defaults.string(forKey: Keys.cloudModel) ?? ""
        cloudKeyConfigured = ((try? CloudAPIKeyStore().read()) ?? nil) != nil
        waitForPolish = defaults.bool(forKey: Keys.waitForPolish)
        contextAwarenessEnabled = defaults.bool(forKey: Keys.contextAwarenessEnabled)
        clipboardContextEnabled = defaults.object(forKey: Keys.clipboardContextEnabled) as? Bool ?? true
        screenContextEnabled = defaults.bool(forKey: Keys.screenContextEnabled)
        assistantEnabled = defaults.object(forKey: Keys.assistantEnabled) as? Bool ?? true
        excludedContextApps = defaults.stringArray(forKey: Keys.excludedContextApps) ?? []
        acknowledgedCloudHost = defaults.string(forKey: Keys.acknowledgedCloudHost) ?? ""
        clipboardFallbackEnabled = defaults.object(forKey: Keys.clipboardFallbackEnabled) as? Bool ?? true
        emailFramingEnabled = defaults.object(forKey: Keys.emailFramingEnabled) as? Bool ?? true

        hotkey.selectedHotkey = dictationHotkey
        hotkey.onBegin = { [weak self] in
            self?.requestHotkeyDictationBegin()
        }
        hotkey.onEnd = { [weak self] in
            self?.requestHotkeyDictationEnd()
        }
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        permissions.startMonitoring()
        permissionObservation = permissions.$accessibilityGranted
            .removeDuplicates()
            .sink { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    if granted {
                        self.restartHotkeyIfAuthorized()
                    } else {
                        self.hotkey.stop()
                    }
                }
            }
        notchPanel.show(model: self)
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            updates.start()
        }
        restartHotkeyIfAuthorized()
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            modelManager.startAutomaticInstallation()
        }
        modelStateObservation = modelManager.$state
            .removeDuplicates()
            .sink { [weak self] state in
                guard state == .installed else { return }
                Task { await self?.speechEngine.warmUpIfAvailable() }
            }
        applicationObservation = NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didActivateApplicationNotification)
            .sink { [weak self] notification in
                guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                Task { @MainActor in
                    guard let self else { return }
                    let wasGranted = self.permissions.globalHotkeyGranted
                    self.permissions.refresh()
                    if !wasGranted, self.permissions.globalHotkeyGranted {
                        self.restartHotkeyIfAuthorized()
                    }
                    self.activated(application)
                }
            }
        if let application = NSWorkspace.shared.frontmostApplication {
            activated(application)
        }
    }

    func restartHotkeyIfAuthorized() {
        permissions.refresh()
        hotkey.stop()
        guard permissions.globalHotkeyGranted else { return }
        do {
            try hotkey.start()
        } catch {
            show(error)
        }
    }

    func requestControlAndInsertionPermission() {
        _ = permissions.requestAccessibility()
        if permissions.globalHotkeyGranted {
            restartHotkeyIfAuthorized()
        }
    }

    func refreshPermissionsAndHotkey() {
        permissions.refresh()
        if permissions.globalHotkeyGranted {
            restartHotkeyIfAuthorized()
        } else {
            hotkey.stop()
        }
    }

    func showPeek() {
        peekDismissalTask?.cancel()
        peekDismissalTask = nil
        guard phase == .idle else { return }
        phase = .peek
    }

    func hidePeek() {
        guard phase == .peek else { return }
        phase = .idle
    }

    func schedulePeekDismissal() {
        peekDismissalTask?.cancel()
        peekDismissalTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let self else { return }
            self.peekDismissalTask = nil
            self.hidePeek()
        }
    }

    func chooseMode(_ mode: WritingMode) {
        selectedMode = mode
        if phase == .idle { phase = .peek }
    }

    private func requestHotkeyDictationBegin() {
        guard !dictationStartupInFlight else { return }
        dictationStartupInFlight = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.beginDictation()
            self.dictationStartupInFlight = false
            if self.pendingDictationEnd {
                self.pendingDictationEnd = false
                await self.endDictation()
            }
        }
    }

    private func requestHotkeyDictationEnd() {
        if dictationStartupInFlight {
            pendingDictationEnd = true
            return
        }
        Task { await self.endDictation() }
    }

    func beginDictation() async {
        guard activeSession == nil else { return }
        cancelPendingCorrectionLearning()
        phase = .listening
        partialTranscript = ""
        audioLevel = 0
        dictationStartedAt = .now

        guard await permissions.requestMicrophone() else {
            hotkey.reset()
            dictationStartupInFlight = false
            pendingDictationEnd = false
            show(AirScribeError.microphonePermissionDenied)
            return
        }

        var createdSession: (any TranscriptionSession)?
        do {
            let locale = Locale(identifier: localeIdentifier)
            if contextAwarenessEnabled {
                activeContext = await contextManager.capture(
                    options: ContextCaptureOptions(
                        includeClipboard: clipboardContextEnabled,
                        includeScreenText: screenContextEnabled,
                        excludedBundleIdentifiers: Set(excludedContextApps)
                    )
                )
                lastContextSummary = contextSummary(activeContext)
            } else {
                activeContext = .empty
                lastContextSummary = "Context awareness is off"
            }
            let vocabularyContext = transcriptionContext()
            let session = try await speechEngine.makeSession(
                locale: locale,
                context: vocabularyContext,
                preferExtendedLanguages: preferExtendedLanguages
            ) { [weak self] value in
                Task { @MainActor in self?.partialTranscript = value }
            }
            createdSession = session
            activeSession = session
            let audioURL = try history.newAudioURL()
            activeAudioURL = audioURL
            try microphone.start(
                targetFormat: session.requiredAudioFormat,
                recordingURL: audioURL,
                onBuffer: { buffer in session.append(buffer) },
                onLevel: { [weak self] level in
                    Task { @MainActor in self?.audioLevel = level }
                }
            )
            recovery.mark(.dictation, audioPaths: [audioURL.path])
        } catch {
            microphone.stop()
            await createdSession?.cancel()
            activeSession = nil
            removeActiveAudio()
            dictationStartupInFlight = false
            pendingDictationEnd = false
            show(error)
        }
    }

    func endDictation() async {
        guard let session = activeSession else {
            if dictationStartupInFlight {
                pendingDictationEnd = true
                return
            }
            if phase == .listening { phase = .idle }
            return
        }
        let audioRecordingError = microphone.stop()
        if audioRecordingError != nil {
            removeActiveAudio()
        }
        phase = .processing
        activeSession = nil

        do {
            let raw = try await session.finish()
            let engineName = session.engineName
            guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AirScribeError.emptyTranscription
            }

            let invocation = assistantEnabled
                ? assistantEngine.invocation(in: raw)
                : nil
            let isPlainQuestion = invocation == nil && assistantEngine.isLikelyQuestion(raw)
            let outputBase: String
            if invocation != nil {
                outputBase = raw
            } else {
                switch outputLanguageMode {
                case .original:
                    outputBase = raw
                case .romanizedHindi:
                    outputBase = await translator.romanizeHindi(raw)
                case .english:
                    outputBase = (try? await translator.translateToEnglish(raw)) ?? raw
                }
            }
            let immediateText: String
            if let invocation {
                immediateText = try await assistantEngine.respond(
                    to: invocation,
                    context: activeContext,
                    recentText: history.records.prefix(5).map(\.enhancedText)
                )
            } else {
                immediateText = basicEnhancer.enhance(
                    outputBase,
                    mode: selectedMode,
                    vocabulary: customVocabulary + contextualVocabularyTerms(),
                    learnedCorrections: applicableLearnedCorrections(
                        forBundleIdentifier: lastExternalBundleIdentifier
                    ),
                    framesEmail: emailFramingEnabled
                )
            }
            let modeUsesGenerativePolish = selectedMode != .general
            let emailPolishAvailable = selectedMode == .email
                && ((useAppleIntelligence && foundationEnhancer.isAvailable) || cloudPolishEnabled)
            let requiresPolishedInsertion = (waitForPolish && modeUsesGenerativePolish)
                || invocation != nil
                || emailPolishAvailable
            let initialInsertion: TextInserter.InsertionResult?
            if requiresPolishedInsertion {
                initialInsertion = nil
            } else {
                initialInsertion = try await textInserter.insert(
                    immediateText,
                    allowClipboardFallback: clipboardFallbackEnabled
                )
            }
            let insertionHandle = initialInsertion?.handle
            var copiedToClipboard = initialInsertion?.wasCopiedToClipboard ?? false
            let polishIsWanted = invocation == nil
                && modeUsesGenerativePolish
                && (!isPlainQuestion || selectedMode == .email)
            var enhanced = immediateText
            if polishIsWanted {
                enhanced = await onDevicePolished(enhanced)
                enhanced = await cloudPolished(enhanced)
            }

            var insertedText = immediateText
            var finalInsertionHandle = insertionHandle
            if requiresPolishedInsertion {
                let result = try await textInserter.insert(
                    enhanced,
                    allowClipboardFallback: clipboardFallbackEnabled
                )
                finalInsertionHandle = result.handle
                copiedToClipboard = result.wasCopiedToClipboard
                insertedText = enhanced
            } else if copiedToClipboard {
                if enhanced != immediateText {
                    try textInserter.copyToClipboard(enhanced)
                }
                insertedText = enhanced
            } else if enhanced != immediateText, let insertionHandle {
                // Let the original paste settle, then replace only if the same text and field are untouched.
                try? await Task.sleep(for: .milliseconds(220))
                if let replacementHandle = textInserter.replace(insertionHandle, with: enhanced) {
                    finalInsertionHandle = replacementHandle
                    insertedText = enhanced
                }
            }
            let latency = dictationStartedAt.map {
                let components = $0.duration(to: .now).components
                return Int(components.seconds * 1_000)
                    + Int(components.attoseconds / 1_000_000_000_000_000)
            } ?? 0
            try history.add(
                DictationRecord(
                    rawText: raw,
                    enhancedText: insertedText,
                    mode: selectedMode,
                    localeIdentifier: localeIdentifier,
                    engine: engineName,
                    latencyMilliseconds: latency,
                    audioPath: activeAudioURL?.path
                )
            )
            if invocation == nil, learnFromCorrections {
                if let finalInsertionHandle {
                    observeCorrection(to: finalInsertionHandle)
                } else if copiedToClipboard {
                    observeClipboardCorrection(to: insertedText)
                }
            }
            activeAudioURL = nil
            recovery.complete()
            activeContext = .empty
            partialTranscript = insertedText
            hotkey.reset()
            dictationStartupInFlight = false
            pendingDictationEnd = false
            if copiedToClipboard {
                phase = .copied
                try? await Task.sleep(for: .milliseconds(1_500))
                if phase == .copied {
                    if let audioRecordingError {
                        phase = .error("Text was copied, but its recording could not be saved: \(audioRecordingError.localizedDescription)")
                    } else {
                        phase = .idle
                    }
                }
            } else {
                phase = .done
                try? await Task.sleep(for: .milliseconds(650))
                if phase == .done {
                    if let audioRecordingError {
                        phase = .error("Text was inserted, but its recording could not be saved: \(audioRecordingError.localizedDescription)")
                    } else {
                        phase = .idle
                    }
                }
            }
        } catch {
            removeActiveAudio()
            recovery.complete()
            activeContext = .empty
            hotkey.reset()
            dictationStartupInFlight = false
            pendingDictationEnd = false
            show(error)
        }
    }

    /// Applies Apple Intelligence polish, keeping the input when the model is
    /// unavailable, fails, or returns text that no longer represents the speech.
    private func onDevicePolished(_ text: String) async -> String {
        guard useAppleIntelligence, foundationEnhancer.isAvailable else { return text }
        guard let polished = try? await foundationEnhancer.enhance(
            text,
            mode: selectedMode,
            instruction: polishInstruction(for: selectedMode),
            context: activeContext
        ), PolishGuard.isPlausible(polished, polishOf: text) else { return text }
        return polished
    }

    /// Applies the user's own cloud provider, if configured.
    ///
    /// A cloud outage, a truncated generation, or a result that dropped content
    /// must never block dictation: the error is surfaced in Settings and the
    /// on-device text is used instead.
    private func cloudPolished(_ text: String) async -> String {
        guard cloudPolishEnabled else { return text }
        isUsingCloud = true
        defer { isUsingCloud = false }
        do {
            guard let endpoint = URL(string: cloudEndpoint),
                  let apiKey = try cloudAPIKeyStore.read(),
                  !apiKey.isEmpty else { throw CloudPolishError.missingKey }
            let polished = try await cloudEnhancer.enhance(
                text,
                instruction: polishInstruction(for: selectedMode),
                configuration: CloudPolishConfiguration(
                    endpoint: endpoint,
                    model: cloudModel,
                    apiKey: apiKey,
                    acknowledgedHost: acknowledgedCloudHost
                )
            )
            guard PolishGuard.isPlausible(polished, polishOf: text) else {
                throw CloudPolishError.implausibleResult
            }
            lastCloudError = nil
            return polished
        } catch {
            lastCloudError = error.localizedDescription
            return text
        }
    }

    func cancelDictation() async {
        microphone.stop()
        let session = activeSession
        activeSession = nil
        await session?.cancel()
        removeActiveAudio()
        recovery.complete()
        partialTranscript = ""
        audioLevel = 0
        activeContext = .empty
        hotkey.reset()
        dictationStartupInFlight = false
        pendingDictationEnd = false
        phase = .idle
    }

    func addVocabularyTerm(_ term: String) {
        let cleaned = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty,
              !customVocabulary.contains(where: { $0.caseInsensitiveCompare(cleaned) == .orderedSame }) else { return }
        customVocabulary.append(cleaned)
    }

    func removeVocabularyTerms(at offsets: IndexSet) {
        customVocabulary.remove(atOffsets: offsets)
    }

    func removeLearnedCorrection(_ heard: String) {
        learnedCorrections.removeValue(forKey: heard)
        learnedCorrectionOrder.removeAll { $0 == heard }
        learnedCorrectionScopes.removeValue(forKey: heard)
    }

    /// Stores a correction rule, evicting the oldest once the cap is reached.
    private func recordLearnedCorrection(heard: String, correction: String) {
        guard !BasicTextEnhancer.shouldNotPropagate(heard: heard, correction: correction) else { return }
        if learnedCorrections[heard] == nil {
            while learnedCorrectionOrder.count >= Self.maximumLearnedCorrections,
                  let oldest = learnedCorrectionOrder.first {
                learnedCorrectionOrder.removeFirst()
                learnedCorrections.removeValue(forKey: oldest)
                learnedCorrectionScopes.removeValue(forKey: oldest)
            }
            learnedCorrectionOrder.append(heard)
        } else {
            learnedCorrectionOrder.removeAll { $0 == heard }
            learnedCorrectionOrder.append(heard)
        }
        learnedCorrections[heard] = correction
        learnedCorrectionScopes[heard] = lastExternalBundleIdentifier
    }

    /// The corrections that should be replayed for the app being written into.
    ///
    /// A correction taught in one app used to be applied to everything the user
    /// dictated afterwards. Editing "our" to "r" for a forum post then rewrote
    /// "our" everywhere. Transcription fixes such as a misheard name still apply
    /// everywhere; anything that looks like house style stays where it was taught.
    func applicableLearnedCorrections(
        forBundleIdentifier bundleIdentifier: String
    ) -> [String: String] {
        learnedCorrections.filter { heard, correction in
            if BasicTextEnhancer.appliesInEveryApp(heard: heard, correction: correction) {
                return true
            }
            guard let scope = learnedCorrectionScopes[heard], !scope.isEmpty else {
                // Learned before scopes were recorded, so the app it belongs to is
                // unknown. Replaying it everywhere is what caused the problem.
                return false
            }
            return scope == bundleIdentifier
        }
    }

    /// Human-readable scope for the Vocabulary settings list.
    func learnedCorrectionScopeDescription(for heard: String) -> String {
        guard let correction = learnedCorrections[heard] else { return "" }
        if BasicTextEnhancer.appliesInEveryApp(heard: heard, correction: correction) {
            return "Everywhere"
        }
        guard let scope = learnedCorrectionScopes[heard], !scope.isEmpty else {
            return "Inactive, re-teach in the app you want it"
        }
        if scope == lastExternalBundleIdentifier, !lastExternalApplicationName.isEmpty {
            return "Only in \(lastExternalApplicationName)"
        }
        return "Only in \(scope)"
    }

    private func observeClipboardCorrection(to copiedText: String) {
        clipboardCorrectionLearningTask?.cancel()
        clipboardCorrectionLearningTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.clipboardCorrectionLearningTask = nil }
            // The fallback may be pasted into a field after dictation completes.
            // Detect it immediately before the caret, then reuse the same bounded
            // correction observer as automatic insertion.
            for _ in 0 ..< 32 {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, self.learnFromCorrections else { return }
                if let handle = self.textInserter.insertionHandleForRecentlyPastedText(copiedText) {
                    self.observeCorrection(to: handle)
                    return
                }
            }
        }
    }

    private func observeCorrection(to handle: TextInserter.InsertionHandle) {
        if correctionLearningTasks.count >= 4,
           let oldestID = correctionLearningTaskOrder.first {
            correctionLearningTasks.removeValue(forKey: oldestID)?.cancel()
            correctionLearningTaskOrder.removeAll { $0 == oldestID }
        }
        correctionLearningTasks[handle.id]?.cancel()
        correctionLearningTaskOrder.removeAll { $0 == handle.id }
        correctionLearningTaskOrder.append(handle.id)
        correctionLearningTasks[handle.id] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.correctionLearningTasks[handle.id] = nil
                self.correctionLearningTaskOrder.removeAll { $0 == handle.id }
            }
            var lastObserved: String?
            var stableObservations = 0
            var unavailableObservations = 0
            // Learn only from an immediate edit in the same focused field.
            // A short grace period tolerates transient Accessibility reads, while
            // leaving the field or starting another dictation ends observation.
            for _ in 0 ..< 48 {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, self.learnFromCorrections else { return }
                guard self.textInserter.canObserveCorrection(handle) else {
                    unavailableObservations += 1
                    if unavailableObservations >= 2 { return }
                    continue
                }
                unavailableObservations = 0
                guard let observed = self.textInserter.correctedText(for: handle),
                      let learning = self.correctionLearner.learn(
                          from: handle.insertedText,
                          to: observed
                      ) else {
                    continue
                }
                if observed == lastObserved {
                    stableObservations += 1
                } else {
                    lastObserved = observed
                    stableObservations = 1
                }
                guard stableObservations >= 4 else { continue }
                for (heard, correction) in learning.replacements {
                    self.recordLearnedCorrection(heard: heard, correction: correction)
                }
                learning.vocabulary.forEach(self.addVocabularyTerm)
                if let learned = learning.replacements.sorted(by: { $0.key < $1.key }).first {
                    self.showLearnedFeedback(heard: learned.key, correction: learned.value)
                }
                return
            }
        }
    }

    private func cancelPendingCorrectionLearning() {
        correctionLearningTasks.values.forEach { $0.cancel() }
        correctionLearningTasks = [:]
        correctionLearningTaskOrder = []
        clipboardCorrectionLearningTask?.cancel()
        clipboardCorrectionLearningTask = nil
    }

    private func showLearnedFeedback(heard: String, correction: String) {
        learningFeedbackTask?.cancel()
        learningFeedbackTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Never cover recording or processing state. If learning completes at
            // that moment, show it as soon as dictation has finished.
            for _ in 0 ..< 40 {
                switch self.phase {
                case .listening, .processing:
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled else { return }
                default:
                    self.phase = .learned(heard: heard, correction: correction)
                    try? await Task.sleep(for: .seconds(2.4))
                    if self.phase == .learned(heard: heard, correction: correction) {
                        self.phase = .idle
                    }
                    return
                }
            }
        }
    }

    func instruction(for mode: WritingMode) -> String {
        let value = modeInstructions[mode.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.flatMap { $0.isEmpty ? nil : $0 } ?? mode.enhancementInstruction
    }

    private func polishInstruction(for mode: WritingMode) -> String {
        let customInstruction = instruction(for: mode)
        guard mode == .email else { return customInstruction }
        return """
        \(customInstruction)
        Actively improve casual or awkward phrasing in the main body. Do not merely return it unchanged when a clearer version is possible.
        A greeting line and a sign-off line may already be present. Reproduce those lines verbatim, on their own lines, and polish only the body between them.
        Never add a recipient name, a subject line, or a second greeting or sign-off.
        """
    }

    func resetInstruction(for mode: WritingMode) {
        modeInstructions[mode.rawValue] = mode.enhancementInstruction
    }

    func mapLastApplication(to mode: WritingMode) {
        guard !lastExternalBundleIdentifier.isEmpty else { return }
        let mapping = AppModeMapping(
            bundleIdentifier: lastExternalBundleIdentifier,
            applicationName: lastExternalApplicationName,
            mode: mode
        )
        if let index = appModeMappings.firstIndex(where: { $0.bundleIdentifier == mapping.bundleIdentifier }) {
            appModeMappings[index] = mapping
        } else {
            appModeMappings.append(mapping)
            appModeMappings.sort { $0.applicationName.localizedCaseInsensitiveCompare($1.applicationName) == .orderedAscending }
        }
    }

    func updateMapping(_ bundleIdentifier: String, mode: WritingMode) {
        guard let index = appModeMappings.firstIndex(where: { $0.bundleIdentifier == bundleIdentifier }) else { return }
        appModeMappings[index].mode = mode
    }

    func removeMappings(at offsets: IndexSet) {
        appModeMappings.remove(atOffsets: offsets)
    }

    func saveCloudAPIKey(_ value: String) throws {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw CloudPolishError.missingKey }
        try cloudAPIKeyStore.save(cleaned)
        cloudKeyConfigured = true
        lastCloudError = nil
    }

    func deleteCloudAPIKey() throws {
        try cloudAPIKeyStore.delete()
        cloudKeyConfigured = false
        cloudPolishEnabled = false
    }

    func deleteAllLocalData() async {
        dataDeletionError = nil
        await cancelDictation()
        await meetings.cancel()
        var supportDeletionFailures: [String] = []
        do {
            try history.deleteAll()
        } catch {
            supportDeletionFailures.append("dictation history: \(error.localizedDescription)")
        }
        do {
            try meetings.store.deleteAll()
        } catch {
            supportDeletionFailures.append("meeting history: \(error.localizedDescription)")
        }
        if !recovery.discardRecoveredFiles() {
            supportDeletionFailures.append(
                "recovered audio: \(recovery.lastError ?? "some files could not be removed")"
            )
        }
        await modelManager.removeInstallation()
        await languagePackManager.removeAndWait()
        launchAtLogin.disableForDataReset()

        var failures: [String] = []
        var keyRemains = false
        do {
            try cloudAPIKeyStore.delete()
            if try cloudAPIKeyStore.read() != nil {
                keyRemains = true
                failures.append("the cloud API key is still present in Keychain")
            }
        } catch {
            keyRemains = true
            failures.append("cloud API key: \(error.localizedDescription)")
        }

        let fileManager = FileManager.default
        let applicationSupportURL = ApplicationSupportLocation.airScribeRoot(fileManager)
        do {
            if fileManager.fileExists(atPath: applicationSupportURL.path) {
                try fileManager.removeItem(at: applicationSupportURL)
            }
        } catch {
            failures.append("application data: \(error.localizedDescription)")
        }
        let temporaryBuffers = fileManager.temporaryDirectory
            .appending(path: "AirScribe", directoryHint: .isDirectory)
            .appending(path: "TranscriptionBuffers", directoryHint: .isDirectory)
        do {
            if fileManager.fileExists(atPath: temporaryBuffers.path) {
                try fileManager.removeItem(at: temporaryBuffers)
            }
        } catch {
            failures.append("temporary transcription buffers: \(error.localizedDescription)")
        }

        if fileManager.fileExists(atPath: applicationSupportURL.path) {
            failures.append(contentsOf: supportDeletionFailures)
            failures.append("some AirScribe application data remains on disk")
        } else {
            // Keep the live stores consistent after the containing directory was
            // successfully removed, including stores that initially failed to
            // load. The managers were already torn down above, so only the
            // in-memory stores need clearing here.
            try? history.deleteAll()
            try? meetings.store.deleteAll()
            recovery.complete()
        }
        if fileManager.fileExists(atPath: temporaryBuffers.path) {
            failures.append("temporary transcription buffers remain on disk")
        }

        selectedSettingsSection = .general
        selectedMode = .general
        dictationHotkey = .control
        localeIdentifier = "en-US"
        outputLanguageMode = .original
        useAppleIntelligence = true
        cloudKeyConfigured = keyRemains
        cloudPolishEnabled = false
        cloudEndpoint = "https://api.openai.com/v1/responses"
        cloudModel = ""
        isUsingCloud = false
        lastCloudError = nil
        waitForPolish = false
        preferExtendedLanguages = false
        customVocabulary = []
        learnFromCorrections = true
        correctionLearningTasks.values.forEach { $0.cancel() }
        correctionLearningTasks = [:]
        correctionLearningTaskOrder = []
        clipboardCorrectionLearningTask?.cancel()
        clipboardCorrectionLearningTask = nil
        learningFeedbackTask?.cancel()
        learningFeedbackTask = nil
        learnedCorrections = [:]
        learnedCorrectionOrder = []
        learnedCorrectionScopes = [:]
        onboardingComplete = false
        modeInstructions = Dictionary(
            uniqueKeysWithValues: WritingMode.allCases.map {
                ($0.rawValue, $0.enhancementInstruction)
            }
        )
        automaticModeSelection = true
        appModeMappings = []
        lastExternalApplicationName = ""
        lastExternalBundleIdentifier = ""
        contextAwarenessEnabled = false
        clipboardContextEnabled = true
        screenContextEnabled = false
        assistantEnabled = true
        excludedContextApps = []
        acknowledgedCloudHost = ""
        clipboardFallbackEnabled = true
        emailFramingEnabled = true
        activeContext = .empty
        lastContextSummary = "No context captured"
        partialTranscript = ""
        audioLevel = 0
        phase = .idle

        // Settings reset above rewrote the owner-only preference file, so it is
        // cleared after them rather than before.
        sensitivePreferences.removeAll()

        // Remove every known key first: removePersistentDomain(forName:) is
        // documented for other applications' domains and leaves the running
        // process's own cached suite in place, so settings could reappear.
        for key in Keys.all {
            defaults.removeObject(forKey: key)
        }
        recovery.removePersistedState()
        defaults.removePersistentDomain(
            forName: Bundle.main.bundleIdentifier ?? "com.airscribe.mac"
        )
        var residualKeys = Keys.all.filter { defaults.object(forKey: $0) != nil }
        if !residualKeys.isEmpty {
            // A second explicit pass covers keys the domain wipe re-cached.
            for key in residualKeys { defaults.removeObject(forKey: key) }
            residualKeys = Keys.all.filter { defaults.object(forKey: $0) != nil }
        }
        if !residualKeys.isEmpty {
            failures.append("some AirScribe settings could not be cleared")
        }
        if let storeError = sensitivePreferences.lastError {
            failures.append("learning data: \(storeError)")
        }

        if !failures.isEmpty {
            let message = "Some private data could not be deleted: \(failures.joined(separator: "; ")). Try again after closing apps that may be using those files."
            dataDeletionError = message
            phase = .error(message)
        }
    }

    func excludeLastApplicationFromContext() {
        guard !lastExternalBundleIdentifier.isEmpty,
              !excludedContextApps.contains(lastExternalBundleIdentifier) else { return }
        excludedContextApps.append(lastExternalBundleIdentifier)
        excludedContextApps.sort()
    }

    func removeContextExclusions(at offsets: IndexSet) {
        excludedContextApps.remove(atOffsets: offsets)
    }

    func showOnboarding() {
        OnboardingWindowController.shared.show(model: self)
    }

    func showMeetings() {
        MeetingWindowController.shared.show(model: self)
    }

    func finishOnboarding() {
        onboardingComplete = true
        restartHotkeyIfAuthorized()
        OnboardingWindowController.shared.close()
    }

    func show(_ error: Error) {
        let message = error.localizedDescription
        phase = .error(message)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            // Only clear the error this call raised; a newer, different error
            // must stay on screen for its own full duration.
            guard self?.phase == .error(message) else { return }
            self?.phase = .idle
        }
    }

    private func removeActiveAudio() {
        guard let activeAudioURL else { return }
        try? FileManager.default.removeItem(at: activeAudioURL)
        self.activeAudioURL = nil
    }

    private func activated(_ application: NSRunningApplication) {
        guard let bundleIdentifier = application.bundleIdentifier,
              bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        lastExternalBundleIdentifier = bundleIdentifier
        lastExternalApplicationName = application.localizedName ?? bundleIdentifier
        guard automaticModeSelection,
              let mapping = appModeMappings.first(where: { $0.bundleIdentifier == bundleIdentifier }) else { return }
        selectedMode = mapping.mode
    }

    private func transcriptionContext() -> String? {
        var sections: [String] = []
        if assistantEnabled {
            sections.append("The speaker may begin with ‘AirScribe’ or ‘Hey AirScribe’. Transcribe the brand as AirScribe (pronounced ‘air scribe’).")
        }
        if !customVocabulary.isEmpty {
            sections.append("Preferred vocabulary: " + customVocabulary.joined(separator: ", "))
        }
        if !activeContext.isEmpty {
            sections.append(activeContext.promptContext)
        }
        return sections.isEmpty ? nil : sections.joined(separator: "\n")
    }

    /// Single-word terms harvested from the captured context, used to fix casing
    /// of names the speaker just read on screen.
    ///
    /// Each term costs regex work in `BasicTextEnhancer` during the insertion hot
    /// path, so the list is capped well below what phrase extraction yields.
    static let maximumContextualVocabularyTerms = 24

    private func contextualVocabularyTerms() -> [String] {
        guard !activeContext.isEmpty else { return [] }
        let candidates = SpeechContextPhrases.extract(from: activeContext.promptContext)
            .filter { phrase in
                !phrase.contains(where: \.isWhitespace)
                    && phrase.allSatisfy { $0.isLetter || $0 == "'" || $0 == "’" || $0 == "-" }
            }
        return BasicTextEnhancer.deduplicated(
            candidates,
            limit: Self.maximumContextualVocabularyTerms
        )
    }

    private func contextSummary(_ snapshot: ContextSnapshot) -> String {
        guard !snapshot.isEmpty else { return "No eligible context found" }
        var sources: [String] = []
        if snapshot.windowTitle != nil || snapshot.applicationName != nil { sources.append("app") }
        if snapshot.focusedText != nil { sources.append("focused text") }
        if snapshot.clipboardText != nil { sources.append("clipboard") }
        if snapshot.screenText != nil { sources.append("screen text") }
        return "Captured locally: " + sources.joined(separator: ", ")
    }

    private func persist<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, from defaults: UserDefaults, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
