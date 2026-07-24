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
        didSet { defaults.set(customVocabulary, forKey: Keys.vocabulary) }
    }
    @Published var learnFromCorrections: Bool {
        didSet {
            defaults.set(learnFromCorrections, forKey: Keys.learnFromCorrections)
            if !learnFromCorrections {
                correctionLearningTasks.values.forEach { $0.cancel() }
                correctionLearningTasks = [:]
                correctionLearningTaskOrder = []
            }
        }
    }
    @Published private(set) var learnedCorrections: [String: String] {
        didSet { persist(learnedCorrections, key: Keys.learnedCorrections) }
    }
    @Published var onboardingComplete: Bool {
        didSet { defaults.set(onboardingComplete, forKey: Keys.onboardingComplete) }
    }
    @Published var modeInstructions: [String: String] {
        didSet { persist(modeInstructions, key: Keys.modeInstructions) }
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

    let history = HistoryStore()
    let permissions = PermissionManager()
    let modelManager = ModelManager()
    let languagePackManager = LanguagePackManager()
    let launchAtLogin = LaunchAtLoginManager()
    let updates = UpdateController()
    let recovery = RecoveryStore.shared
    lazy var meetings = MeetingCoordinator(speechEngine: speechEngine, permissions: permissions)

    private let defaults = UserDefaults.standard
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
    }

    private init() {
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
        customVocabulary = defaults.stringArray(forKey: Keys.vocabulary) ?? []
        learnFromCorrections = defaults.object(forKey: Keys.learnFromCorrections) as? Bool ?? true
        learnedCorrections = Self.decode([String: String].self, from: defaults, key: Keys.learnedCorrections) ?? [:]
        onboardingComplete = defaults.bool(forKey: Keys.onboardingComplete)
        modeInstructions = Self.decode([String: String].self, from: defaults, key: Keys.modeInstructions)
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
            if invocation == nil, outputLanguageMode == .english {
                outputBase = (try? await translator.translateToEnglish(raw)) ?? raw
            } else {
                outputBase = raw
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
                    vocabulary: customVocabulary,
                    learnedCorrections: learnedCorrections
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
                initialInsertion = try await textInserter.insert(immediateText)
            }
            let insertionHandle = initialInsertion?.handle
            var copiedToClipboard = initialInsertion?.wasCopiedToClipboard ?? false
            var enhanced = immediateText
            let shouldPolishQuestion = selectedMode == .email
            if invocation == nil,
               modeUsesGenerativePolish,
               (!isPlainQuestion || shouldPolishQuestion),
               useAppleIntelligence,
               foundationEnhancer.isAvailable {
                if let polished = try? await foundationEnhancer.enhance(
                    enhanced,
                    mode: selectedMode,
                    instruction: polishInstruction(for: selectedMode),
                    context: activeContext
                ) {
                    enhanced = polished
                }
            }
            if invocation == nil,
               modeUsesGenerativePolish,
               (!isPlainQuestion || shouldPolishQuestion),
               cloudPolishEnabled {
                isUsingCloud = true
                do {
                    guard let endpoint = URL(string: cloudEndpoint),
                          let apiKey = try cloudAPIKeyStore.read(),
                          !apiKey.isEmpty else { throw CloudPolishError.missingKey }
                    enhanced = try await cloudEnhancer.enhance(
                        enhanced,
                        instruction: polishInstruction(for: selectedMode),
                        configuration: CloudPolishConfiguration(
                            endpoint: endpoint,
                            model: cloudModel,
                            apiKey: apiKey
                        )
                    )
                    lastCloudError = nil
                } catch {
                    // A cloud outage must never block dictation. The on-device result is inserted instead.
                    lastCloudError = error.localizedDescription
                }
                isUsingCloud = false
            }

            var insertedText = immediateText
            var finalInsertionHandle = insertionHandle
            if requiresPolishedInsertion {
                let result = try await textInserter.insert(enhanced)
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
            if invocation == nil, learnFromCorrections, let finalInsertionHandle {
                observeCorrection(to: finalInsertionHandle)
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
            // Keep a small number of independent observations alive so starting a
            // later dictation does not discard a correction still being edited.
            for _ in 0 ..< 400 {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled, self.learnFromCorrections else { return }
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
                guard stableObservations >= 5 else { continue }
                for (heard, correction) in learning.replacements {
                    self.learnedCorrections[heard] = correction
                }
                learning.vocabulary.forEach(self.addVocabularyTerm)
                if let learned = learning.replacements.sorted(by: { $0.key < $1.key }).first {
                    self.showLearnedFeedback(heard: learned.key, correction: learned.value)
                }
                return
            }
        }
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
        Actively improve casual or awkward phrasing in the main body. Do not merely return it unchanged when a clearer professional version is possible.
        Never add a greeting, recipient, subject line, signature, or sign-off.
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
        await cancelDictation()
        await meetings.cancel()
        history.deleteAll()
        meetings.store.deleteAll()
        recovery.discardRecoveredFiles()
        await modelManager.removeInstallation()
        await languagePackManager.removeAndWait()
        launchAtLogin.disableForDataReset()
        try? cloudAPIKeyStore.delete()

        let fileManager = FileManager.default
        if let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first {
            try? fileManager.removeItem(
                at: applicationSupport.appending(path: "AirScribe", directoryHint: .isDirectory)
            )
        }
        try? fileManager.removeItem(
            at: fileManager.temporaryDirectory
                .appending(path: "AirScribe", directoryHint: .isDirectory)
                .appending(path: "TranscriptionBuffers", directoryHint: .isDirectory)
        )

        selectedSettingsSection = .general
        selectedMode = .general
        dictationHotkey = .control
        localeIdentifier = "en-US"
        outputLanguageMode = .original
        useAppleIntelligence = true
        cloudKeyConfigured = false
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
        learningFeedbackTask?.cancel()
        learningFeedbackTask = nil
        learnedCorrections = [:]
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
        activeContext = .empty
        lastContextSummary = "No context captured"
        partialTranscript = ""
        audioLevel = 0
        phase = .idle

        defaults.removePersistentDomain(
            forName: Bundle.main.bundleIdentifier ?? "com.airscribe.mac"
        )
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
        phase = .error(error.localizedDescription)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            if case .error = self?.phase { self?.phase = .idle }
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
