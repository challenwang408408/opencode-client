//
//  AppState.swift
//  OpenCodeClient
//

import Foundation
import CryptoKit
import Observation
import os

@Observable
@MainActor
final class AppState {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "OpenCodeClient",
        category: "AppState"
    )

    /// Debug log to a file in the app's Documents directory for easy retrieval
    nonisolated static func scopeLog(_ message: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "[\(ts)] \(message)\n"
        let fm = FileManager.default
        if let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
            let logFile = docs.appendingPathComponent("scope_debug.log")
            if let handle = try? FileHandle(forWritingTo: logFile) {
                handle.seekToEndOfFile()
                handle.write(line.data(using: .utf8) ?? Data())
                handle.closeFile()
            } else {
                try? line.data(using: .utf8)?.write(to: logFile)
            }
        }
    }

    struct ServerURLInfo {
        let raw: String
        let normalized: String?
        let scheme: String?
        let host: String?
        let isLocal: Bool
        let isAllowed: Bool
        let warning: String?
    }

    enum TargetScopeSwitchStatus: Equatable {
        case idle
        case switching
        case disconnected
        case reconnecting
        case connected
        case failed

        var isBusy: Bool {
            switch self {
            case .switching, .disconnected, .reconnecting:
                return true
            default:
                return false
            }
        }
    }

    struct ScopeSwitchCandidate: Identifiable, Hashable {
        let id: String
        let name: String
        let path: String
        let type: String
    }

    /// LAN allows HTTP; WAN requires HTTPS.
    nonisolated static func serverURLInfo(_ raw: String) -> ServerURLInfo {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .init(raw: raw, normalized: nil, scheme: nil, host: nil, isLocal: true, isAllowed: false, warning: L10n.t(.errorServerAddressEmpty))
        }

        func parseHost(_ s: String) -> String? {
            if let u = URL(string: s), let h = u.host { return h }
            if let u = URL(string: "http://\(s)"), let h = u.host { return h }
            return nil
        }

        func isPrivateIPv4(_ host: String) -> Bool {
            let parts = host.split(separator: ".")
            guard parts.count == 4,
                  let a = Int(parts[0]), let b = Int(parts[1]) else { return false }
            if a == 10 || a == 127 { return true }
            if a == 192 && b == 168 { return true }
            if a == 172 && (16...31).contains(b) { return true }
            if a == 169 && b == 254 { return true }
            if host == "0.0.0.0" { return true }
            return false
        }

        let hasScheme = trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")
        let host = parseHost(trimmed)
        let isLocal: Bool = {
            guard let host else { return true }
            if host == "localhost" { return true }
            if host.hasSuffix(".local") { return true }
            if isPrivateIPv4(host) { return true }
            return false
        }()

        let scheme: String = {
            if let u = URL(string: trimmed), let s = u.scheme { return s }
            return isLocal ? "http" : "https"
        }()

        if scheme == "http", !isLocal {
            return .init(
                raw: raw,
                normalized: hasScheme ? trimmed : nil,
                scheme: "http",
                host: host,
                isLocal: false,
                isAllowed: false,
                warning: L10n.t(.errorWanRequiresHttps)
            )
        }

        let normalized = hasScheme ? trimmed : "\(scheme)://\(trimmed)"
        let parsed = URL(string: normalized)
        return .init(
            raw: raw,
            normalized: normalized,
            scheme: parsed?.scheme,
            host: parsed?.host,
            isLocal: isLocal,
            isAllowed: parsed != nil,
            warning: parsed == nil ? L10n.t(.errorInvalidBaseURL) : (scheme == "http" ? L10n.t(.errorUsingLanHttp) : nil)
        )
    }
    private var _serverURL: String = APIClient.defaultServer
    var serverURL: String {
        get { _serverURL }
        set {
            _serverURL = newValue
            UserDefaults.standard.set(newValue, forKey: Self.serverURLKey)
        }
    }

    private var _username: String = ""
    var username: String {
        get { _username }
        set {
            _username = newValue
            UserDefaults.standard.set(newValue, forKey: Self.usernameKey)
        }
    }

    private var _password: String = ""
    var password: String {
        get { _password }
        set {
            _password = newValue
            if newValue.isEmpty {
                KeychainHelper.delete(Self.passwordKeychainKey)
            } else {
                KeychainHelper.save(newValue, forKey: Self.passwordKeychainKey)
            }
        }
    }

    private static let serverURLKey = "serverURL"
    private static let usernameKey = "username"
    private static let passwordKeychainKey = "password"
    private static let aiBuilderBaseURLKey = "aiBuilderBaseURL"
    private static let aiBuilderTokenKeychainKey = "aiBuilderToken"
    private static let aiBuilderCustomPromptKey = "aiBuilderCustomPrompt"
    private static let aiBuilderTerminologyKey = "aiBuilderTerminology"
    private static let aiBuilderLastOKSignatureKey = "aiBuilderLastOKSignature"
    private static let aiBuilderLastOKTestedAtKey = "aiBuilderLastOKTestedAt"
    private static let draftInputsBySessionKey = "draftInputsBySession"
    private static let selectedModelBySessionKey = "selectedModelBySession"
    private static let recentModelsKey = "recentModels"
    private static let showArchivedSessionsKey = "showArchivedSessions"
    private static let selectedProjectWorktreeKey = "selectedProjectWorktree"
    private static let customProjectPathKey = "customProjectPath"
    private static let scopeConnectionHistoryKey = "scopeConnectionHistory"

    private static let openAIProviderID = "openai"
    private static let preferredOpenAIModelIDs = [
        "gpt-5.3-codex",
        "gpt-5.3-codex-spark",
        "gpt-5.2",
    ]

    init() {
        if let storedServer = UserDefaults.standard.string(forKey: Self.serverURLKey) {
            if storedServer == APIConstants.legacyDefaultServer {
                _serverURL = APIClient.defaultServer
                UserDefaults.standard.set(APIClient.defaultServer, forKey: Self.serverURLKey)
            } else {
                _serverURL = storedServer
            }
        } else {
            _serverURL = APIClient.defaultServer
        }
        _username = UserDefaults.standard.string(forKey: Self.usernameKey) ?? ""
        _password = KeychainHelper.load(forKey: Self.passwordKeychainKey) ?? ""

        _aiBuilderBaseURL = UserDefaults.standard.string(forKey: Self.aiBuilderBaseURLKey) ?? "https://space.ai-builders.com/backend"
        _aiBuilderToken = KeychainHelper.load(forKey: Self.aiBuilderTokenKeychainKey) ?? ""
        _aiBuilderCustomPrompt = UserDefaults.standard.string(forKey: Self.aiBuilderCustomPromptKey) ?? Self.defaultAIBuilderCustomPrompt
        _aiBuilderTerminology = UserDefaults.standard.string(forKey: Self.aiBuilderTerminologyKey) ?? Self.defaultAIBuilderTerminology
        _showArchivedSessions = UserDefaults.standard.bool(forKey: Self.showArchivedSessionsKey)
        _selectedProjectWorktree = UserDefaults.standard.string(forKey: Self.selectedProjectWorktreeKey)
        _customProjectPath = UserDefaults.standard.string(forKey: Self.customProjectPathKey) ?? ""

        // Restore last known-good AI Builder connection state if token/baseURL unchanged.
        let storedSig = UserDefaults.standard.string(forKey: Self.aiBuilderLastOKSignatureKey)
        let currentSig = Self.aiBuilderSignature(baseURL: _aiBuilderBaseURL, token: _aiBuilderToken)
        if let storedSig, storedSig == currentSig, !currentSig.isEmpty {
            aiBuilderConnectionOK = true
            if let ts = UserDefaults.standard.object(forKey: Self.aiBuilderLastOKTestedAtKey) as? Double {
                aiBuilderLastTestedAt = Date(timeIntervalSince1970: ts)
            }
        }

        if let data = UserDefaults.standard.data(forKey: Self.draftInputsBySessionKey),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            draftInputsBySessionID = decoded
        }

        if let data = UserDefaults.standard.data(forKey: Self.selectedModelBySessionKey),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            selectedModelIDBySessionID = decoded
        }

        if let data = UserDefaults.standard.data(forKey: Self.recentModelsKey),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            recentModelIDs = decoded
        }
    }

    // Unsent composer drafts per session.
    private var draftInputsBySessionID: [String: String] = [:]

    // Selected model (providerID/modelID) per session.
    private var selectedModelIDBySessionID: [String: String] = [:]
    private var recentModelIDs: [String] = []

    private func persistSelectedModelMap() {
        if selectedModelIDBySessionID.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.selectedModelBySessionKey)
            return
        }
        if let data = try? JSONEncoder().encode(selectedModelIDBySessionID) {
            UserDefaults.standard.set(data, forKey: Self.selectedModelBySessionKey)
        }
    }

    private func persistRecentModels() {
        if recentModelIDs.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.recentModelsKey)
            return
        }
        if let data = try? JSONEncoder().encode(recentModelIDs) {
            UserDefaults.standard.set(data, forKey: Self.recentModelsKey)
        }
    }

    func draftText(for sessionID: String?) -> String {
        guard let sessionID else { return "" }
        return draftInputsBySessionID[sessionID] ?? ""
    }

    func setDraftText(_ text: String, for sessionID: String?) {
        guard let sessionID else { return }
        let cleaned = text
        if cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draftInputsBySessionID[sessionID] = nil
        } else {
            draftInputsBySessionID[sessionID] = cleaned
        }

        if draftInputsBySessionID.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.draftInputsBySessionKey)
            return
        }
        if let data = try? JSONEncoder().encode(draftInputsBySessionID) {
            UserDefaults.standard.set(data, forKey: Self.draftInputsBySessionKey)
        }
    }

    private static func aiBuilderSignature(baseURL: String, token: String) -> String {
        let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let tok = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty, !tok.isEmpty else { return "" }
        let input = "\(base)|\(tok)"
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private var _aiBuilderBaseURL: String = "https://space.ai-builders.com/backend"
    var aiBuilderBaseURL: String {
        get { _aiBuilderBaseURL }
        set {
            _aiBuilderBaseURL = newValue
            UserDefaults.standard.set(newValue, forKey: Self.aiBuilderBaseURLKey)
            aiBuilderConnectionOK = false
            aiBuilderConnectionError = nil
            aiBuilderLastTestedAt = nil
            UserDefaults.standard.removeObject(forKey: Self.aiBuilderLastOKSignatureKey)
            UserDefaults.standard.removeObject(forKey: Self.aiBuilderLastOKTestedAtKey)
        }
    }

    private var _aiBuilderToken: String = ""
    var aiBuilderToken: String {
        get { _aiBuilderToken }
        set {
            _aiBuilderToken = newValue
            if newValue.isEmpty {
                KeychainHelper.delete(Self.aiBuilderTokenKeychainKey)
            } else {
                KeychainHelper.save(newValue, forKey: Self.aiBuilderTokenKeychainKey)
            }
            aiBuilderConnectionOK = false
            aiBuilderConnectionError = nil
            aiBuilderLastTestedAt = nil
            UserDefaults.standard.removeObject(forKey: Self.aiBuilderLastOKSignatureKey)
            UserDefaults.standard.removeObject(forKey: Self.aiBuilderLastOKTestedAtKey)
        }
    }

    /// Default custom prompt for speech recognition. Instructs engine on filename style.
    private static let defaultAIBuilderCustomPrompt = "All file and directory names should use snake_case (lowercase with underscores)."

    /// Default terminology (comma-separated) from workspace routing.
    private static let defaultAIBuilderTerminology = "adhoc_jobs, life_consulting, survey_sessions, thought_review"

    private var _aiBuilderCustomPrompt: String = ""
    var aiBuilderCustomPrompt: String {
        get { _aiBuilderCustomPrompt }
        set {
            _aiBuilderCustomPrompt = newValue
            UserDefaults.standard.set(newValue, forKey: Self.aiBuilderCustomPromptKey)
        }
    }

    private var _aiBuilderTerminology: String = ""
    var aiBuilderTerminology: String {
        get { _aiBuilderTerminology }
        set {
            _aiBuilderTerminology = newValue
            UserDefaults.standard.set(newValue, forKey: Self.aiBuilderTerminologyKey)
        }
    }

    var aiBuilderConnectionError: String? = nil
    var aiBuilderConnectionOK: Bool = false
    var aiBuilderLastTestedAt: Date? = nil
    var isTestingAIBuilderConnection: Bool = false
    var isConnected: Bool = false
    var serverVersion: String?
    var connectionError: String?
    var sendError: String?

    // Session activity (rendered in transcript; session-scoped)
    var sessionActivities: [String: SessionActivity] = [:]

    // Track when a session status was last updated via SSE.
    private var sessionStatusUpdatedAt: [String: Date] = [:]

    // Debounce session activity text changes (avoid rapid flipping).
    private var activityTextLastChangeAt: [String: Date] = [:]
    private var activityTextPendingTask: [String: Task<Void, Never>] = [:]

    var currentSessionActivity: SessionActivity? {
        guard let sid = currentSessionID else { return nil }
        return sessionActivities[sid]
    }

    func activityTextForSession(_ sessionID: String) -> String {
        ActivityTracker.bestSessionActivityText(
            sessionID: sessionID,
            currentSessionID: currentSessionID,
            sessionStatuses: sessionStatuses,
            messages: messages,
            streamingReasoningPart: streamingReasoningPart,
            streamingPartTexts: streamingPartTexts
        )
    }
    
    /// Unified error handling
    var lastAppError: AppError?
    
    func setError(_ error: Error, type: ErrorType = .connection) {
        let appError = AppError.from(error)
        lastAppError = appError
        
        switch type {
        case .connection:
            connectionError = appError.localizedDescription
        case .send:
            sendError = appError.localizedDescription
        }
    }
    
    func clearError() {
        lastAppError = nil
        connectionError = nil
        sendError = nil
    }
    
    enum ErrorType {
        case connection
        case send
    }

    private let sessionStore = SessionStore()
    private let messageStore = MessageStore()
    private let fileStore = FileStore()
    private let todoStore = TodoStore()

    var sessions: [Session] { get { sessionStore.sessions } set { sessionStore.sessions = newValue } }
    private static let internalSessionTitles: Set<String> = ["Scope Switch"]

    var sortedSessions: [Session] {
        sessions
            .filter { showArchivedSessions || $0.time.archived == nil }
            .filter { !Self.internalSessionTitles.contains($0.title) }
            .sorted { $0.time.updated > $1.time.updated }
    }

    struct SessionGroup: Identifiable {
        let id: String
        let title: String
        let sessions: [Session]
    }

    var groupedSessions: [SessionGroup] {
        let parentSessions = sortedSessions.filter { $0.parentID == nil || $0.parentID!.isEmpty }
        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)
        let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday)!
        let startOfWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? startOfToday

        var today: [Session] = []
        var yesterday: [Session] = []
        var thisWeek: [Session] = []
        var earlier: [Session] = []

        for session in parentSessions {
            let date = Date(timeIntervalSince1970: TimeInterval(session.time.updated) / 1000)
            if date >= startOfToday {
                today.append(session)
            } else if date >= startOfYesterday {
                yesterday.append(session)
            } else if date >= startOfWeek {
                thisWeek.append(session)
            } else {
                earlier.append(session)
            }
        }

        var groups: [SessionGroup] = []
        if !today.isEmpty { groups.append(SessionGroup(id: "today", title: L10n.t(.sessionsGroupToday), sessions: today)) }
        if !yesterday.isEmpty { groups.append(SessionGroup(id: "yesterday", title: L10n.t(.sessionsGroupYesterday), sessions: yesterday)) }
        if !thisWeek.isEmpty { groups.append(SessionGroup(id: "thisWeek", title: L10n.t(.sessionsGroupThisWeek), sessions: thisWeek)) }
        if !earlier.isEmpty { groups.append(SessionGroup(id: "earlier", title: L10n.t(.sessionsGroupEarlier), sessions: earlier)) }
        return groups
    }

    func childSessions(for parentID: String) -> [Session] {
        sessions
            .filter { $0.parentID == parentID }
            .sorted { $0.time.updated > $1.time.updated }
    }

    var currentSessionID: String? { get { sessionStore.currentSessionID } set { sessionStore.currentSessionID = newValue } }
    var sessionStatuses: [String: SessionStatus] { get { sessionStore.sessionStatuses } set { sessionStore.sessionStatuses = newValue } }

    var messages: [MessageWithParts] { get { messageStore.messages } set { messageStore.messages = newValue } }
    var partsByMessage: [String: [Part]] { get { messageStore.partsByMessage } set { messageStore.partsByMessage = newValue } }
    var streamingPartTexts: [String: String] { get { messageStore.streamingPartTexts } set { messageStore.streamingPartTexts = newValue } }

    var modelPresets: [ModelPreset] = [
        ModelPreset(displayName: "GPT-5.3 Codex", providerID: "openai", modelID: "gpt-5.3-codex"),
        ModelPreset(displayName: "GPT-5.3 Codex Spark", providerID: "openai", modelID: "gpt-5.3-codex-spark"),
        ModelPreset(displayName: "GPT-5.2", providerID: "openai", modelID: "gpt-5.2"),
    ]
    var selectedModelIndex: Int = 0
    
    var agents: [AgentInfo] = [
        AgentInfo(name: "OpenCode-Builder", description: "Build agent (OpenCode default)", mode: "all", hidden: false, native: false),
        AgentInfo(name: "Sisyphus (Ultraworker)", description: "Powerful AI orchestrator", mode: "primary", hidden: false, native: false),
        AgentInfo(name: "Hephaestus (Deep Agent)", description: "Autonomous Deep Worker", mode: "primary", hidden: false, native: false),
        AgentInfo(name: "Prometheus (Plan Builder)", description: "Plan agent", mode: "all", hidden: false, native: false),
        AgentInfo(name: "Atlas (Plan Executor)", description: "Plan Executor", mode: "primary", hidden: false, native: false),
    ]
    var selectedAgentIndex: Int = 0
    var isLoadingAgents: Bool = false

    var showArchivedSessions: Bool {
        get { _showArchivedSessions }
        set {
            _showArchivedSessions = newValue
            UserDefaults.standard.set(newValue, forKey: Self.showArchivedSessionsKey)
        }
    }
    private var _showArchivedSessions: Bool = false

    var projects: [Project] = []
    var isLoadingProjects: Bool = false
    /// Server's current project worktree (from GET /project/current). Used to detect mismatch with user selection.
    var serverCurrentProjectWorktree: String? = nil

    /// When user selected a project but server's default differs: new sessions will be created in server's project.
    /// User should switch project in Web client first.
    var projectMismatchWarning: String? {
        guard let effective = effectiveProjectDirectory, !effective.isEmpty else { return nil }
        guard let server = serverCurrentProjectWorktree else { return nil }
        guard effective != server else { return nil }
        let effectiveName = (effective as NSString).lastPathComponent
        let serverName = (server as NSString).lastPathComponent
        return L10n.t(.settingsProjectMismatchWarning).replacingOccurrences(of: "{effective}", with: effectiveName).replacingOccurrences(of: "{server}", with: serverName)
    }

    /// Only allow creating sessions when using server default project. When a specific project is selected,
    /// new sessions would go to server default (API limitation), so we disable create and show hint.
    var canCreateSession: Bool {
        effectiveProjectDirectory == nil
    }

    /// Hint shown when create is disabled (user selected a project ≠ server default).
    var createSessionDisabledHint: String {
        L10n.t(.chatCreateDisabledHint)
    }

    var selectedProjectWorktree: String? {
        get { _selectedProjectWorktree }
        set {
            _selectedProjectWorktree = newValue
            UserDefaults.standard.set(newValue, forKey: Self.selectedProjectWorktreeKey)
        }
    }
    private var _selectedProjectWorktree: String?

    var customProjectPath: String {
        get { _customProjectPath }
        set {
            _customProjectPath = newValue
            UserDefaults.standard.set(newValue, forKey: Self.customProjectPathKey)
        }
    }
    private var _customProjectPath: String = ""

    /// Effective directory for session fetch: selected project or custom path, nil = server default
    var effectiveProjectDirectory: String? {
        guard let sel = selectedProjectWorktree, !sel.isEmpty else { return nil }
        if sel == Self.customProjectSentinel {
            let path = customProjectPath.trimmingCharacters(in: .whitespacesAndNewlines)
            return path.isEmpty ? nil : path
        }
        return sel
    }
    /// Sentinel value when user selects "Custom path" option
    static let customProjectSentinel = "__custom__"

    var pendingPermissions: [PendingPermission] = []

    var themePreference: String = "auto"  // "auto" | "light" | "dark"

    var sessionDiffs: [FileDiff] { get { fileStore.sessionDiffs } set { fileStore.sessionDiffs = newValue } }
    var selectedDiffFile: String? { get { fileStore.selectedDiffFile } set { fileStore.selectedDiffFile = newValue } }
    var selectedTab: Int = 0  // 0=Chat, 1=Files, 2=Settings
    var fileToOpenInFilesTab: String?  // 从 Chat 中 tool 点击跳转时设置，Files tab 或 sheet 展示

    /// iPad 三栏布局：中间栏文件预览
    var previewFilePath: String?

    var sessionTodos: [String: [TodoItem]] { get { todoStore.sessionTodos } set { todoStore.sessionTodos = newValue } }

    var fileTreeRoot: [FileNode] { get { fileStore.fileTreeRoot } set { fileStore.fileTreeRoot = newValue } }
    var fileStatusMap: [String: String] { get { fileStore.fileStatusMap } set { fileStore.fileStatusMap = newValue } }
    var expandedPaths: Set<String> { get { fileStore.expandedPaths } set { fileStore.expandedPaths = newValue } }
    var fileChildrenCache: [String: [FileNode]] { get { fileStore.fileChildrenCache } set { fileStore.fileChildrenCache = newValue } }
    var fileSearchQuery: String { get { fileStore.fileSearchQuery } set { fileStore.fileSearchQuery = newValue } }
    var fileSearchResults: [String] { get { fileStore.fileSearchResults } set { fileStore.fileSearchResults = newValue } }

    // MARK: - Server Environment (detected at runtime, not persisted)
    var serverHomePath: String?
    var serverOpencodeBinary: String?
    var serverUsesLaunchd: Bool = false
    var isDetectingServerEnv: Bool = false
    private var hasDetectedServerEnv: Bool = false

    // MARK: - Target File Tree (for Section 1 display)
    var targetTreeRoot: [FileNode] = []
    var targetExpandedPaths: Set<String> = []
    var targetChildrenCache: [String: [FileNode]] = [:]

    // MARK: - Scope Switch
    var desktopScopeCandidates: [ScopeSwitchCandidate] = []
    var aiTestScopeCandidates: [ScopeSwitchCandidate] = []
    var isLoadingScopeCandidates: Bool = false
    var targetScopeSwitchStatus: TargetScopeSwitchStatus = .idle
    var targetScopeSwitchProgressText: String?
    var targetScopeSwitchErrorText: String?
    var targetScopeSwitchTargetPath: String?
    var targetScopeSwitchSessionID: String?
    var targetScopeSwitchUpdatedAt: Date?

    private var targetScopeSwitchTask: Task<Void, Never>?

    /// Dynamic desktop path derived from server HOME
    var desktopRootPath: String? { serverHomePath.map { $0 + "/Desktop" } }
    /// Dynamic AI_test folder path derived from server HOME
    var aiTestFolderPath: String? { serverHomePath.map { $0 + "/Desktop/AI_test" } }

    /// Connection history: only manual Connect operations, persisted in UserDefaults (max 10)
    var scopeConnectionHistory: [String] {
        get { UserDefaults.standard.stringArray(forKey: Self.scopeConnectionHistoryKey) ?? [] }
        set { UserDefaults.standard.set(Array(newValue.prefix(10)), forKey: Self.scopeConnectionHistoryKey) }
    }

    // Provider config cache (for context usage ring)
    var providersResponse: ProvidersResponse? = nil
    var providerModelsIndex: [String: ProviderModel] = [:]
    var providerConfigError: String? = nil

    private let apiClient = APIClient()
    private let sseClient = SSEClient()
    let sshTunnelManager = SSHTunnelManager()
    private var sseTask: Task<Void, Never>?

    /// Guard against race conditions when rapidly switching sessions.
    /// Each selectSession call generates a new ID; async tasks check if they're still current.
    private var sessionLoadingID = UUID()

    // WAN optimization: page message history in fixed-size message batches.
    private static let messagePageSize = APIConstants.messagePageSize
    private var loadedMessageLimitBySessionID: [String: Int] = [:]
    private var hasMoreHistoryBySessionID: [String: Bool] = [:]
    private var loadingOlderMessagesSessionIDs: Set<String> = []

    /// Latest streaming reasoning part (for typewriter thinking display)
    var streamingReasoningPart: Part? = nil
    private var streamingDraftMessageIDs: Set<String> = []

    var selectedModel: ModelPreset? {
        guard modelPresets.indices.contains(selectedModelIndex) else { return nil }
        return modelPresets[selectedModelIndex]
    }

    struct ModelProviderGroup: Identifiable {
        var id: String { providerID }
        let providerID: String
        let displayName: String
        let presets: [ModelPreset]
    }

    var modelPresetGroups: [ModelProviderGroup] {
        let grouped = Dictionary(grouping: modelPresets, by: { $0.providerID })
        let names = providerDisplayNamesByID
        return grouped
            .map { providerID, presets in
                ModelProviderGroup(
                    providerID: providerID,
                    displayName: names[providerID] ?? providerID,
                    presets: presets
                )
            }
            .sorted { Self.providerSortKey($0.providerID) < Self.providerSortKey($1.providerID) }
    }

    var recentModelPresets: [ModelPreset] {
        recentModelIDs
            .compactMap { id in modelPresets.first(where: { $0.id == id }) }
    }
    
    var selectedAgent: AgentInfo? {
        let visibleAgents = agents.filter { $0.isVisible }
        guard visibleAgents.indices.contains(selectedAgentIndex) else { return nil }
        return visibleAgents[selectedAgentIndex]
    }
    
    var visibleAgents: [AgentInfo] {
        agents.filter { $0.isVisible }
    }

    var isCurrentSessionHistoryTruncated: Bool {
        guard let sessionID = currentSessionID else { return false }
        return hasMoreHistoryBySessionID[sessionID] ?? false
    }

    var isLoadingOlderMessagesInCurrentSession: Bool {
        guard let sessionID = currentSessionID else { return false }
        return loadingOlderMessagesSessionIDs.contains(sessionID)
    }

    nonisolated static func normalizedMessageFetchLimit(
        current: Int?,
        pageSize: Int = APIConstants.messagePageSize
    ) -> Int {
        let fallback = max(pageSize, 1)
        guard let current else { return fallback }
        return max(current, fallback)
    }

    nonisolated static func nextMessageFetchLimit(
        current: Int?,
        pageSize: Int = APIConstants.messagePageSize
    ) -> Int {
        normalizedMessageFetchLimit(current: current, pageSize: pageSize) + max(pageSize, 1)
    }

    nonisolated static func nextSessionIDAfterDeleting(
        deletedSessionID: String,
        currentSessionID: String?,
        remainingSessions: [Session]
    ) -> String? {
        guard currentSessionID == deletedSessionID else { return currentSessionID }
        return remainingSessions
            .sorted { $0.time.updated > $1.time.updated }
            .first?
            .id
    }

    func setSelectedModelIndex(_ index: Int) {
        guard modelPresets.indices.contains(index) else { return }
        selectedModelIndex = index
        noteModelUsage(modelPresets[index].id)
        guard let sessionID = currentSessionID else { return }
        selectedModelIDBySessionID[sessionID] = modelPresets[index].id
        persistSelectedModelMap()
    }
    
    func setSelectedAgentIndex(_ index: Int) {
        let visibleAgents = agents.filter { $0.isVisible }
        guard visibleAgents.indices.contains(index) else { return }
        selectedAgentIndex = index
    }

    private func applySavedModelForCurrentSession() {
        guard let sessionID = currentSessionID else { return }
        guard let saved = selectedModelIDBySessionID[sessionID] else {
            selectedModelIndex = Self.preferredModelIndex(in: modelPresets)
            return
        }
        guard let idx = modelPresets.firstIndex(where: { $0.id == saved }) else {
            selectedModelIndex = Self.preferredModelIndex(in: modelPresets)
            noteModelUsage(modelPresets[selectedModelIndex].id)
            selectedModelIDBySessionID[sessionID] = modelPresets[selectedModelIndex].id
            persistSelectedModelMap()
            return
        }
        selectedModelIndex = idx
        noteModelUsage(modelPresets[idx].id)
    }

    private func inferAndStoreModelForCurrentSessionIfMissing() {
        guard let sessionID = currentSessionID else { return }
        guard selectedModelIDBySessionID[sessionID] == nil else { return }

        guard let info = messages.reversed().compactMap({ $0.info.resolvedModel }).first else { return }
        guard let idx = modelPresetIndex(providerID: info.providerID, modelID: info.modelID) else { return }

        selectedModelIndex = idx
        noteModelUsage(modelPresets[idx].id)
        selectedModelIDBySessionID[sessionID] = modelPresets[idx].id
        persistSelectedModelMap()
    }

    var currentSession: Session? {
        guard let id = currentSessionID else { return nil }
        return sessions.first { $0.id == id }
    }

    var currentSessionStatus: SessionStatus? {
        guard let id = currentSessionID else { return nil }
        return sessionStatuses[id]
    }

    var isBusy: Bool {
        isBusySession(currentSessionStatus)
    }

    var currentTodos: [TodoItem] {
        guard let id = currentSessionID else { return [] }
        return sessionTodos[id] ?? []
    }

    func configure(serverURL: String, username: String? = nil, password: String? = nil) {
        let urlChanged = self.serverURL != serverURL
        self.serverURL = serverURL
        self.username = username ?? ""
        self.password = password ?? ""
        if urlChanged {
            resetServerEnvironment()
        }
    }

    /// Reset all cached server environment state. Call when the underlying
    /// machine changes (e.g. SSH tunnel switches to a different port/machine)
    /// even if the server URL stays the same.
    func resetServerEnvironment() {
        serverHomePath = nil
        hasDetectedServerEnv = false
        _dedicatedScopeSwitchSessionID = nil
        serverCurrentProjectWorktree = nil
        serverOpencodeBinary = nil
        serverUsesLaunchd = false
        desktopScopeCandidates = []
        aiTestScopeCandidates = []
        targetTreeRoot = []
        targetExpandedPaths = []
        targetChildrenCache = [:]
    }

    func testConnection() async {
        connectionError = nil

        let info = Self.serverURLInfo(serverURL)
        guard info.isAllowed, let baseURL = info.normalized else {
            isConnected = false
            connectionError = info.warning ?? L10n.t(.errorInvalidBaseURL)
            return
        }

        await apiClient.configure(baseURL: baseURL, username: username.isEmpty ? nil : username, password: password.isEmpty ? nil : password)
        do {
            let health = try await apiClient.health()
            isConnected = health.healthy
            serverVersion = health.version
        } catch {
            isConnected = false
            connectionError = error.localizedDescription
        }
    }

    func loadProjects() async {
        guard isConnected else { return }
        isLoadingProjects = true
        do {
            projects = try await apiClient.projects()
            serverCurrentProjectWorktree = (try? await apiClient.projectCurrent())?.worktree
            inferServerHomePath()
        } catch {
            Self.logger.warning("loadProjects failed: \(error.localizedDescription)")
            projects = []
        }
        isLoadingProjects = false
    }

    func loadSessions() async {
        guard isConnected else { return }
        do {
            let directory = effectiveProjectDirectory
            let loaded = try await apiClient.sessions(directory: directory, limit: 500)
            let archivedCount = loaded.filter { $0.time.archived != nil }.count
            Self.logger.debug("loadSessions: directory=\(directory ?? "nil", privacy: .public) count=\(loaded.count, privacy: .public) archived=\(archivedCount, privacy: .public) ids=\(loaded.prefix(5).map(\.id).joined(separator: ","), privacy: .public)")

            sessions = loaded

            // Only auto-select first session if there's no persisted selection at all
            // This handles the case of fresh install or after all sessions are deleted
            if currentSessionID == nil,
               let first = sessions.first(where: { !Self.internalSessionTitles.contains($0.title) }) {
                currentSessionID = first.id
                applySavedModelForCurrentSession()
            }
        } catch {
            connectionError = error.localizedDescription
        }
    }
    
    func loadAgents() async {
        guard isConnected else { return }
        isLoadingAgents = true
        do {
            let loaded = try await apiClient.agents()
            agents = loaded
            if selectedAgentIndex >= visibleAgents.count && !visibleAgents.isEmpty {
                selectedAgentIndex = 0
            }
        } catch {
            Self.logger.warning("loadAgents failed: \(error.localizedDescription)")
        }
        isLoadingAgents = false
    }

    func refreshSessions() async {
        guard isConnected else { return }
        await loadSessions()
        await syncSessionStatusesFromPoll()
    }

    func selectSession(_ session: Session) {
        guard currentSessionID != session.id else { return }
        
        // Generate new loading ID to invalidate any in-flight tasks from previous session
        let loadingID = UUID()
        sessionLoadingID = loadingID
        
        streamingReasoningPart = nil
        streamingPartTexts = [:]
        messages = []
        partsByMessage = [:]
        currentSessionID = session.id
        applySavedModelForCurrentSession()
        
        Task { [weak self] in
            guard let self else { return }
            // Check if this task is still current before proceeding
            guard self.sessionLoadingID == loadingID else { return }
            
            await self.refreshSessions()
            guard self.sessionLoadingID == loadingID else { return }
            
            await self.loadMessages()
            guard self.sessionLoadingID == loadingID else { return }

            await self.refreshPendingPermissions()
            guard self.sessionLoadingID == loadingID else { return }
            
            self.inferAndStoreModelForCurrentSessionIfMissing()
            await self.loadSessionDiff()
            guard self.sessionLoadingID == loadingID else { return }
            
            await self.loadSessionTodos()
            guard self.sessionLoadingID == loadingID else { return }

        }
    }

    private func isBusySession(_ status: SessionStatus?) -> Bool {
        guard let type = status?.type else { return false }
        return type == "busy" || type == "retry"
    }

    func loadSessionTodos() async {
        guard let sessionID = currentSessionID else { return }
        do {
            let todos = try await apiClient.sessionTodos(sessionID: sessionID)
            sessionTodos[sessionID] = todos
        } catch {
            if await recoverFromMissingCurrentSessionIfNeeded(error: error, requestedSessionID: sessionID) {
                return
            }
            // keep previous value if any
        }
    }

    func createSession() async {
        guard isConnected else { return }
        
        let loadingID = UUID()
        sessionLoadingID = loadingID
        
        do {
            let session = try await apiClient.createSession()
            guard sessionLoadingID == loadingID else { return }
            
            Self.logger.debug("createSession: created id=\(session.id, privacy: .public) directory=\(session.directory, privacy: .public) effectiveProjectDir=\(self.effectiveProjectDirectory ?? "nil", privacy: .public)")
            
            sessions.insert(session, at: 0)
            currentSessionID = session.id
            if let m = selectedModel {
                noteModelUsage(m.id)
                selectedModelIDBySessionID[session.id] = m.id
                persistSelectedModelMap()
            }
            messages = []
            partsByMessage = [:]
        } catch {
            guard sessionLoadingID == loadingID else { return }
            connectionError = error.localizedDescription
        }
    }

    func deleteSession(sessionID: String) async throws {
        let previousCurrentSessionID = currentSessionID
        try await apiClient.deleteSession(sessionID: sessionID)

        sessions.removeAll { $0.id == sessionID }
        clearSessionScopedCaches(sessionID: sessionID)

        let nextSessionID = Self.nextSessionIDAfterDeleting(
            deletedSessionID: sessionID,
            currentSessionID: previousCurrentSessionID,
            remainingSessions: sessions
        )

        guard previousCurrentSessionID == sessionID else {
            currentSessionID = nextSessionID
            return
        }

        clearCurrentSessionViewState()
        if let nextSessionID {
            currentSessionID = nextSessionID
            applySavedModelForCurrentSession()
            await loadMessages()
            await refreshPendingPermissions()
            await loadSessionDiff()
            await loadSessionTodos()
            inferAndStoreModelForCurrentSessionIfMissing()
        } else {
            currentSessionID = nil
            pendingPermissions = []
        }
    }

    func loadMessages() async {
        guard let sessionID = currentSessionID else { return }
        do {
            let fetchLimit = Self.normalizedMessageFetchLimit(current: loadedMessageLimitBySessionID[sessionID])
            loadedMessageLimitBySessionID[sessionID] = fetchLimit
            let loaded = try await apiClient.messages(sessionID: sessionID, limit: fetchLimit)
            guard Self.shouldApplySessionScopedResult(requestedSessionID: sessionID, currentSessionID: currentSessionID) else {
                Self.logger.debug("drop stale loadMessages result requested=\(sessionID, privacy: .public) current=\(self.currentSessionID ?? "nil", privacy: .public)")
                return
            }

            hasMoreHistoryBySessionID[sessionID] = loaded.count >= fetchLimit

            let loadedMessageIDs = Set(loaded.map { $0.info.id })
            let keepPending = isBusySession(currentSessionStatus)
            let pendingMessages: [MessageWithParts] = {
                guard keepPending else { return [] }
                let pending = messages.filter({ $0.info.id.hasPrefix("temp-user-") })
                guard let lastLoadedUser = loaded.last(where: { $0.info.isUser }) else { return pending }

                func normalizeEpochMs(_ raw: Int) -> Int {
                    // Server timestamps may be seconds or milliseconds.
                    if raw > 0 && raw < 10_000_000_000 { return raw * 1000 }
                    return raw
                }

                let lastLoadedText = (lastLoadedUser.parts.first(where: { $0.isText })?.text ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let lastLoadedCreated = normalizeEpochMs(lastLoadedUser.info.time.created)

                return pending.filter { m in
                    guard m.info.isUser else { return true }
                    let text = (m.parts.first(where: { $0.isText })?.text ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty, text == lastLoadedText else { return true }

                    let created = normalizeEpochMs(m.info.time.created)
                    if created == 0 || lastLoadedCreated == 0 { return false }
                    return abs(lastLoadedCreated - created) > 10 * 60 * 1000
                }
            }()

            let draftMessages = messages.filter {
                streamingDraftMessageIDs.contains($0.info.id) && !loadedMessageIDs.contains($0.info.id)
            }

            var merged: [MessageWithParts] = loaded
            for message in pendingMessages where !loadedMessageIDs.contains(message.info.id) {
                merged.append(message)
            }
            for message in draftMessages where !merged.contains(where: { $0.info.id == message.info.id }) {
                merged.append(message)
            }

            // Defensively dedupe by message id. Keep the latest occurrence.
            var dedupedMessages: [MessageWithParts] = []
            var dedupedIndexByMessageID: [String: Int] = [:]
            for message in merged {
                if let existingIndex = dedupedIndexByMessageID[message.info.id] {
                    dedupedMessages[existingIndex] = message
                } else {
                    dedupedIndexByMessageID[message.info.id] = dedupedMessages.count
                    dedupedMessages.append(message)
                }
            }

            messages = dedupedMessages

            var partsByMessageID: [String: [Part]] = [:]
            for message in messages {
                partsByMessageID[message.info.id] = message.parts
            }
            partsByMessage = partsByMessageID
            streamingDraftMessageIDs.subtract(loadedMessageIDs)

            if isBusySession(currentSessionStatus) {
                refreshSessionActivityText(sessionID: sessionID)
            }
        } catch let error as DecodingError {
            Self.logger.error("loadMessages decode failed: session=\(sessionID, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        } catch {
            if await recoverFromMissingCurrentSessionIfNeeded(error: error, requestedSessionID: sessionID) {
                return
            }
            guard Self.shouldApplySessionScopedResult(requestedSessionID: sessionID, currentSessionID: currentSessionID) else {
                Self.logger.debug("ignore stale loadMessages error requested=\(sessionID, privacy: .public) current=\(self.currentSessionID ?? "nil", privacy: .public)")
                return
            }
            connectionError = error.localizedDescription
            Self.logger.error("loadMessages failed: session=\(sessionID, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    func loadOlderMessagesForCurrentSession() async {
        guard let sessionID = currentSessionID else { return }
        guard hasMoreHistoryBySessionID[sessionID] ?? true else { return }
        guard !loadingOlderMessagesSessionIDs.contains(sessionID) else { return }

        loadingOlderMessagesSessionIDs.insert(sessionID)
        loadedMessageLimitBySessionID[sessionID] = Self.nextMessageFetchLimit(current: loadedMessageLimitBySessionID[sessionID])
        await loadMessages()
        loadingOlderMessagesSessionIDs.remove(sessionID)
    }

    func loadSessionDiff() async {
        guard let sessionID = currentSessionID else { sessionDiffs = []; return }
        do {
            let loaded = try await apiClient.sessionDiff(sessionID: sessionID)
            guard Self.shouldApplySessionScopedResult(requestedSessionID: sessionID, currentSessionID: currentSessionID) else {
                Self.logger.debug("drop stale loadSessionDiff result requested=\(sessionID, privacy: .public) current=\(self.currentSessionID ?? "nil", privacy: .public)")
                return
            }
            sessionDiffs = loaded
        } catch {
            if await recoverFromMissingCurrentSessionIfNeeded(error: error, requestedSessionID: sessionID) {
                return
            }
            guard Self.shouldApplySessionScopedResult(requestedSessionID: sessionID, currentSessionID: currentSessionID) else { return }
            sessionDiffs = []
        }
    }

    func loadFileTree() async {
        do {
            fileTreeRoot = try await apiClient.fileList(path: "")
            fileChildrenCache = [:]
        } catch {
            fileTreeRoot = []
        }
    }

    func loadFileStatus() async {
        do {
            let entries = try await apiClient.fileStatus()
            var nextStatusMap: [String: String] = [:]
            for entry in entries {
                guard let path = entry.path else { continue }
                nextStatusMap[path] = entry.status ?? ""
            }
            fileStatusMap = nextStatusMap
        } catch {
            fileStatusMap = [:]
        }
    }

    func loadFileChildren(path: String) async -> [FileNode] {
        do {
            let children = try await apiClient.fileList(path: path)
            fileChildrenCache[path] = children
            return children
        } catch {
            fileChildrenCache[path] = []
            return []
        }
    }

    func cachedChildren(for path: String) -> [FileNode]? {
        fileChildrenCache[path]
    }

    func searchFiles(query: String) async {
        guard !query.isEmpty else { fileSearchResults = []; return }
        do {
            fileSearchResults = try await apiClient.findFile(query: query)
        } catch {
            fileSearchResults = []
        }
    }

    // MARK: - Server Environment Detection

    /// Derive server HOME from a known absolute path like "/Users/xxx/Desktop/..."
    nonisolated static func deriveHomePath(from absolutePath: String?) -> String? {
        guard let path = absolutePath else { return nil }
        let prefix = "/Users/"
        guard path.hasPrefix(prefix) else { return nil }
        let afterUsers = path.dropFirst(prefix.count)
        guard let slashIndex = afterUsers.firstIndex(of: "/") else {
            return String(path)
        }
        return String(path.prefix(upTo: slashIndex))
    }

    /// Infer serverHomePath from worktree. Re-derives on every call so that
    /// switching between machines (different /Users/xxx) is handled correctly.
    ///
    /// When the worktree cannot derive a home path (e.g. worktree is "/"),
    /// we keep the existing serverHomePath (which may have been set by
    /// detectServerEnvironment via `echo $HOME`) to avoid an infinite loop
    /// between loadScopeSwitchCandidates ↔ detectServerEnvironment.
    private func inferServerHomePath() {
        guard let home = Self.deriveHomePath(from: serverCurrentProjectWorktree) else {
            // Worktree is nil, empty, or not under /Users/xxx — nothing to infer.
            // Preserve any serverHomePath already set by detectServerEnvironment.
            return
        }
        if home != serverHomePath {
            let prev = serverHomePath
            serverHomePath = home
            hasDetectedServerEnv = false
            _dedicatedScopeSwitchSessionID = nil
            Self.logger.notice("env.infer home=\(home, privacy: .public) (prev=\(prev ?? "nil", privacy: .public)) from worktree")
        }
    }

    func detectServerEnvironment() async {
        guard isConnected, !hasDetectedServerEnv else { return }

        inferServerHomePath()

        isDetectingServerEnv = true
        defer { isDetectingServerEnv = false }

        do {
            let sessionID = try await ensureScopeSwitchSessionID()

            if serverHomePath == nil {
                let homeOutput = try await runScopeSwitchShellCommand(
                    sessionID: sessionID,
                    command: "echo $HOME"
                )
                serverHomePath = homeOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            let binaryOutput = try await runScopeSwitchShellCommand(
                sessionID: sessionID,
                command: "which opencode 2>/dev/null || find $HOME/.npm-global -name opencode -path '*/bin/opencode' 2>/dev/null | head -1 || find $HOME/.opencode -name opencode -path '*/bin/opencode' 2>/dev/null | head -1"
            )
            let binary = binaryOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            if !binary.isEmpty {
                serverOpencodeBinary = binary
            }

            let launchdOutput = try await runScopeSwitchShellCommand(
                sessionID: sessionID,
                command: "launchctl list 2>/dev/null | grep com.opencode.server || echo ''"
            )
            serverUsesLaunchd = !launchdOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

            hasDetectedServerEnv = true
            Self.logger.notice("env.detect home=\(self.serverHomePath ?? "nil", privacy: .public) binary=\(self.serverOpencodeBinary ?? "nil", privacy: .public) launchd=\(self.serverUsesLaunchd, privacy: .public)")
        } catch {
            Self.logger.warning("detectServerEnvironment shell probe failed: \(error.localizedDescription)")
            if serverHomePath != nil {
                hasDetectedServerEnv = true
            }
        }
    }

    // MARK: - Target File Tree

    func loadTargetTree() async {
        guard let worktree = serverCurrentProjectWorktree, !worktree.isEmpty else {
            targetTreeRoot = []
            return
        }
        do {
            targetTreeRoot = try await apiClient.fileList(path: "")
            targetExpandedPaths = []
            targetChildrenCache = [:]
        } catch {
            Self.logger.warning("loadTargetTree failed for worktree=\(worktree, privacy: .public): \(error.localizedDescription, privacy: .public)")
            targetTreeRoot = []
        }
    }

    func loadTargetChildren(path: String) async -> [FileNode] {
        do {
            let children = try await apiClient.fileList(path: path)
            targetChildrenCache[path] = children
            return children
        } catch {
            targetChildrenCache[path] = []
            return []
        }
    }

    func toggleTargetExpanded(_ path: String) {
        if targetExpandedPaths.contains(path) {
            targetExpandedPaths.remove(path)
        } else {
            targetExpandedPaths.insert(path)
        }
    }

    func isTargetExpanded(_ path: String) -> Bool {
        targetExpandedPaths.contains(path)
    }

    func cachedTargetChildren(for path: String) -> [FileNode]? {
        targetChildrenCache[path]
    }

    // MARK: - Connection History

    func addToConnectionHistory(_ path: String) {
        var history = scopeConnectionHistory
        history.removeAll { $0 == path }
        history.insert(path, at: 0)
        scopeConnectionHistory = history
    }

    /// Translate a path's /Users/xxx prefix to match the current server home.
    func translatePathToCurrentServer(_ path: String) -> String {
        guard let currentHome = serverHomePath else { return path }
        guard let pathHome = Self.deriveHomePath(from: path) else { return path }
        if pathHome == currentHome { return path }
        return currentHome + path.dropFirst(pathHome.count)
    }

    /// Connection history excluding current worktree, with paths translated to the current server.
    var connectionHistoryForDisplay: [String] {
        let current = serverCurrentProjectWorktree ?? ""
        var seen = Set<String>()
        var result: [String] = []
        for raw in scopeConnectionHistory {
            let translated = translatePathToCurrentServer(raw)
            if translated == current { continue }
            if seen.insert(translated).inserted {
                result.append(translated)
            }
        }
        return result
    }

    // MARK: - Scope Switch Candidates

    /// Parse `ls -1p` output into ScopeSwitchCandidate array.
    /// `ls -1p` appends "/" to directory names.
    private func parseLsOutput(_ output: String, parentPath: String) -> [ScopeSwitchCandidate] {
        output
            .split(separator: "\n")
            .compactMap { line -> ScopeSwitchCandidate? in
                let raw = String(line).trimmingCharacters(in: .whitespaces)
                guard !raw.isEmpty else { return nil }
                let isDir = raw.hasSuffix("/")
                let name = isDir ? String(raw.dropLast()) : raw
                guard !name.isEmpty else { return nil }
                let path = parentPath + "/" + name
                return ScopeSwitchCandidate(
                    id: path, name: name, path: path,
                    type: isDir ? "directory" : "file"
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func loadScopeSwitchCandidates() async {
        guard isConnected else { return }
        guard !isLoadingScopeCandidates else { return }

        inferServerHomePath()

        isLoadingScopeCandidates = true
        defer { isLoadingScopeCandidates = false }

        guard let home = serverHomePath else {
            if !hasDetectedServerEnv { await detectServerEnvironment() }
            guard let home = serverHomePath else { return }
            // Fall through to use the home that detectServerEnvironment just set,
            // instead of recursing (which risked an infinite loop).
            let desktopPath = home + "/Desktop"
            let aiTestPath = home + "/Desktop/AI_test"
            do {
                let sessionID = try await ensureScopeSwitchSessionID()
                let desktopOutput = try await runScopeSwitchShellCommand(
                    sessionID: sessionID,
                    command: "ls -1p '\(desktopPath)' 2>/dev/null"
                )
                desktopScopeCandidates = parseLsOutput(desktopOutput, parentPath: desktopPath)
                let aiTestOutput = try await runScopeSwitchShellCommand(
                    sessionID: sessionID,
                    command: "ls -1p '\(aiTestPath)' 2>/dev/null"
                )
                aiTestScopeCandidates = parseLsOutput(aiTestOutput, parentPath: aiTestPath)
                    .filter { $0.type == "directory" }
            } catch {
                Self.logger.warning("loadScopeSwitchCandidates shell failed: \(error.localizedDescription)")
            }
            return
        }

        let desktopPath = home + "/Desktop"
        let aiTestPath = home + "/Desktop/AI_test"

        do {
            let sessionID = try await ensureScopeSwitchSessionID()

            let desktopOutput = try await runScopeSwitchShellCommand(
                sessionID: sessionID,
                command: "ls -1p '\(desktopPath)' 2>/dev/null"
            )
            desktopScopeCandidates = parseLsOutput(desktopOutput, parentPath: desktopPath)

            let aiTestOutput = try await runScopeSwitchShellCommand(
                sessionID: sessionID,
                command: "ls -1p '\(aiTestPath)' 2>/dev/null"
            )
            aiTestScopeCandidates = parseLsOutput(aiTestOutput, parentPath: aiTestPath)
                .filter { $0.type == "directory" }
        } catch {
            Self.logger.warning("loadScopeSwitchCandidates shell failed: \(error.localizedDescription)")
        }
    }

    func startTargetScopeSwitch(path: String) {
        let normalized = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        guard !targetScopeSwitchStatus.isBusy else { return }

        Self.logger.notice("scope.switch start requested path=\(normalized, privacy: .public)")
        Self.scopeLog("[SCOPE] start requested path=\(normalized)")

        targetScopeSwitchTask?.cancel()
        targetScopeSwitchTask = Task { [weak self] in
            await self?.runTargetScopeSwitch(path: normalized)
        }
    }

    func cancelTargetScopeSwitch() {
        Self.scopeLog("[SCOPE] user cancelled scope switch")
        targetScopeSwitchTask?.cancel()
        targetScopeSwitchTask = nil
        targetScopeSwitchStatus = .idle
        targetScopeSwitchProgressText = nil
        targetScopeSwitchErrorText = nil
        targetScopeSwitchTargetPath = nil
        targetScopeSwitchSessionID = nil
    }

    private func runTargetScopeSwitch(path: String) async {
        Self.scopeLog("[SCOPE] ========== START scope switch ==========")
        Self.scopeLog("[SCOPE] target path=\(path)")
        Self.scopeLog("[SCOPE] current worktree=\(serverCurrentProjectWorktree ?? "nil")")
        Self.scopeLog("[SCOPE] serverHomePath=\(serverHomePath ?? "nil")")
        Self.scopeLog("[SCOPE] hasDetectedServerEnv=\(hasDetectedServerEnv)")
        Self.scopeLog("[SCOPE] serverUsesLaunchd=\(serverUsesLaunchd)")
        Self.scopeLog("[SCOPE] serverOpencodeBinary=\(serverOpencodeBinary ?? "nil")")

        if serverCurrentProjectWorktree == path {
            Self.scopeLog("[SCOPE] already at target path, marking connected")
            targetScopeSwitchStatus = .connected
            targetScopeSwitchTargetPath = path
            targetScopeSwitchProgressText = L10n.t(.scopeSwitchStatusConnected)
            targetScopeSwitchErrorText = nil
            targetScopeSwitchUpdatedAt = Date()
            addToConnectionHistory(path)
            return
        }

        targetScopeSwitchStatus = .switching
        targetScopeSwitchTargetPath = path
        targetScopeSwitchProgressText = L10n.t(.scopeSwitchStatusSwitching)
        targetScopeSwitchErrorText = nil
        targetScopeSwitchUpdatedAt = Date()

        if !hasDetectedServerEnv {
            Self.scopeLog("[SCOPE] step 0: detecting server environment...")
            await detectServerEnvironment()
            Self.scopeLog("[SCOPE] step 0: env detected. home=\(serverHomePath ?? "nil") launchd=\(serverUsesLaunchd) binary=\(serverOpencodeBinary ?? "nil")")
        }

        // --- Step 1: Verify target path ---
        var sessionID: String
        do {
            targetScopeSwitchProgressText = L10n.t(.scopeSwitchStepVerifyPath)
            sessionID = try await ensureScopeSwitchSessionID()
            targetScopeSwitchSessionID = sessionID
            Self.scopeLog("[SCOPE] step 1: session=\(sessionID)")

            let lsCommand = "ls -d \(shellQuote(path))"
            let lsResult = try await runScopeSwitchShellCommand(
                sessionID: sessionID,
                command: lsCommand,
                mustContain: path
            )
            Self.scopeLog("[SCOPE] step 1: path verified. ls output=\(lsResult)")
        } catch {
            setScopeSwitchFailed(error.localizedDescription, path: path)
            Self.scopeLog("[SCOPE] FAILED at step 1 (verify path): \(error)")
            return
        }

        // --- Step 2: Find server process ---
        var pid: Int
        do {
            targetScopeSwitchProgressText = L10n.t(.scopeSwitchStepFindProcess)
            let psCommand = "ps aux | grep \"[o]pencode.*serve\""
            let processOutput = try await runScopeSwitchShellCommand(
                sessionID: sessionID,
                command: psCommand
            )
            Self.scopeLog("[SCOPE] step 2: ps output=\(processOutput)")

            guard let found = extractServePID(from: processOutput)
                    ?? extractFirstInteger(from: processOutput) else {
                throw NSError(
                    domain: "ScopeSwitch", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: L10n.t(.scopeSwitchProcessNotFound)]
                )
            }
            pid = found
            Self.scopeLog("[SCOPE] step 2: PID=\(pid)")
        } catch {
            setScopeSwitchFailed(error.localizedDescription, path: path)
            Self.scopeLog("[SCOPE] FAILED at step 2 (find process): \(error)")
            return
        }

        // --- Step 3: Write restart script to /tmp ---
        do {
            targetScopeSwitchProgressText = L10n.t(.scopeSwitchStepWriteScript)
            let scriptLines = buildScopeRestartScript(path: path, pid: pid)
            let printfContent = scriptLines.replacingOccurrences(of: "'", with: "'\\''")
            let writeCommand = "printf '\(printfContent)\\n' > /tmp/opencode-restart.sh && chmod +x /tmp/opencode-restart.sh && cat /tmp/opencode-restart.sh | head -1"
            Self.scopeLog("[SCOPE] step 3: write command=\(writeCommand)")
            let writeOutput = try await runScopeSwitchShellCommand(
                sessionID: sessionID,
                command: writeCommand
            )
            Self.scopeLog("[SCOPE] step 3: script written. output=\(writeOutput)")

            if !writeOutput.contains("#!/bin/bash") {
                throw NSError(
                    domain: "ScopeSwitch", code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Restart script is empty or malformed: \(writeOutput)"]
                )
            }
        } catch {
            setScopeSwitchFailed(error.localizedDescription, path: path)
            Self.scopeLog("[SCOPE] FAILED at step 3 (write script): \(error)")
            return
        }

        // --- Step 4: Execute restart script in background ---
        do {
            targetScopeSwitchProgressText = L10n.t(.scopeSwitchStepRestart)
            let execOutput: String
            do {
                execOutput = try await runScopeSwitchShellCommand(
                    sessionID: sessionID,
                    command: "nohup /tmp/opencode-restart.sh >/dev/null 2>&1 &"
                )
                Self.scopeLog("[SCOPE] step 4: exec returned output=\(execOutput)")
            } catch {
                Self.scopeLog("[SCOPE] step 4: exec threw (expected after kill): \(error)")
            }
        }

        // --- Step 5: Monitor for server restart ---
        disconnectSSE()
        targetScopeSwitchStatus = .disconnected
        targetScopeSwitchProgressText = L10n.t(.scopeSwitchStatusDisconnected)
        Self.scopeLog("[SCOPE] step 5: entering monitor phase...")

        await monitorTargetScopeSwitchProgress(expectedPath: path, sessionID: sessionID)
        Self.scopeLog("[SCOPE] ========== END scope switch, final status=\(targetScopeSwitchStatus) ==========")
    }

    private func buildScopeRestartScript(path: String, pid: Int) -> String {
        let plistPath = "$HOME/Library/LaunchAgents/com.opencode.server.plist"
        if serverUsesLaunchd {
            return [
                "#!/bin/bash",
                "sleep 1",
                "plutil -replace WorkingDirectory -string \(shellQuote(path)) \"\(plistPath)\"",
                "launchctl unload \"\(plistPath)\"",
                "sleep 1",
                "launchctl load \"\(plistPath)\"",
            ].joined(separator: "\\n")
        }
        let binary = serverOpencodeBinary ?? "opencode"
        return [
            "#!/bin/bash",
            "sleep 1",
            "kill \(pid)",
            "sleep 2",
            "cd \(shellQuote(path)) || exit 1",
            "exec \(shellQuote(binary)) serve --port 4096 >/tmp/opencode-server.log 2>&1",
        ].joined(separator: "\\n")
    }

    private func setScopeSwitchFailed(_ message: String, path: String) {
        targetScopeSwitchStatus = .failed
        targetScopeSwitchErrorText = message
        targetScopeSwitchProgressText = L10n.t(.scopeSwitchStatusFailed)
        targetScopeSwitchUpdatedAt = Date()
    }

    private var _dedicatedScopeSwitchSessionID: String?

    private func ensureScopeSwitchSessionID() async throws -> String {
        if let existing = _dedicatedScopeSwitchSessionID {
            do {
                _ = try await apiClient.session(sessionID: existing)
                return existing
            } catch {
                Self.scopeLog("[SCOPE] dedicated scope session \(existing) invalid, will create new one")
                _dedicatedScopeSwitchSessionID = nil
            }
        }

        let created = try await apiClient.createSession(title: "Scope Switch")
        _dedicatedScopeSwitchSessionID = created.id
        Self.scopeLog("[SCOPE] created dedicated scope session \(created.id)")
        return created.id
    }

    private func monitorTargetScopeSwitchProgress(expectedPath: String, sessionID: String) async {
        let maxTicks = 30
        let verifyAfterTick = 3
        var observedDisconnect = false

        Self.scopeLog("[SCOPE-MON] starting monitor loop, expecting path=\(expectedPath)")

        for tick in 0..<maxTicks {
            if Task.isCancelled {
                Self.scopeLog("[SCOPE-MON] task cancelled at tick=\(tick)")
                return
            }
            try? await Task.sleep(for: .seconds(1))

            await testConnection()
            targetScopeSwitchUpdatedAt = Date()
            targetScopeSwitchProgressText = L10n.t(.scopeSwitchStepWaiting, tick)

            if tick % 5 == 0 || tick < 4 {
                Self.scopeLog("[SCOPE-MON] tick=\(tick) isConnected=\(isConnected) observedDisconnect=\(observedDisconnect)")
            }

            if !isConnected {
                observedDisconnect = true
                targetScopeSwitchStatus = .disconnected
                disconnectSSE()
                continue
            }

            let shouldVerify = observedDisconnect || tick >= verifyAfterTick
            guard shouldVerify else { continue }

            Self.scopeLog("[SCOPE-MON] verifying CWD at tick=\(tick)...")
            let verified = await verifyScopeSwitchCWD(expectedPath: expectedPath, sessionID: sessionID)
            if verified {
                serverCurrentProjectWorktree = expectedPath
                targetScopeSwitchStatus = .connected
                targetScopeSwitchProgressText = L10n.t(.scopeSwitchStatusConnected)
                targetScopeSwitchErrorText = nil
                targetScopeSwitchUpdatedAt = Date()
                Self.logger.notice("scope.switch status=connected target=\(expectedPath, privacy: .public)")

                addToConnectionHistory(expectedPath)
                connectSSE()
                await refreshAfterScopeSwitch(preservedWorktree: expectedPath)
                await loadScopeSwitchCandidates()
                await loadTargetTree()
                return
            }
            Self.scopeLog("[SCOPE-MON] CWD verification failed, continuing...")
        }

        targetScopeSwitchStatus = .failed
        targetScopeSwitchProgressText = L10n.t(.scopeSwitchStatusFailed)
        targetScopeSwitchErrorText = L10n.t(.scopeSwitchTimeoutDetail)
        targetScopeSwitchUpdatedAt = Date()
        Self.logger.error("scope.switch timeout target=\(expectedPath, privacy: .public) session=\(sessionID, privacy: .public)")
    }

    private func verifyScopeSwitchCWD(expectedPath: String, sessionID: String) async -> Bool {
        do {
            let newSID = try await ensureScopeSwitchSessionID()
            let output = try await runScopeSwitchShellCommand(
                sessionID: newSID,
                command: "plutil -extract WorkingDirectory raw $HOME/Library/LaunchAgents/com.opencode.server.plist 2>/dev/null || pwd"
            )
            let cwd = output.trimmingCharacters(in: .whitespacesAndNewlines)
            Self.scopeLog("[SCOPE-MON] verifyCWD: plist/pwd=\(cwd) expected=\(expectedPath)")
            return cwd == expectedPath
        } catch {
            Self.scopeLog("[SCOPE-MON] verifyCWD failed: \(error)")
            return false
        }
    }

    private func runScopeSwitchShellCommand(
        sessionID: String,
        command: String,
        mustContain token: String? = nil
    ) async throws -> String {
        let agent = selectedAgent?.name ?? "build"
        var effectiveSessionID = sessionID

        do {
            let result = try await apiClient.shell(sessionID: effectiveSessionID, command: command, agent: agent)
            let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if let token, !output.contains(token) {
                throw NSError(
                    domain: "ScopeSwitch",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: output.isEmpty ? L10n.t(.scopeSwitchStatusFailed) : output]
                )
            }
            return output
        } catch let error as APIError {
            guard case .httpError(let statusCode, _) = error, statusCode == 404 else {
                throw error
            }
            Self.scopeLog("[SCOPE] shell 404 for session=\(effectiveSessionID), creating fresh scope session...")
            let created = try await apiClient.createSession(title: "Scope Switch")
            effectiveSessionID = created.id
            _dedicatedScopeSwitchSessionID = created.id
        }

        let result = try await apiClient.shell(sessionID: effectiveSessionID, command: command, agent: agent)
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if let token, !output.contains(token) {
            throw NSError(
                domain: "ScopeSwitch",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: output.isEmpty ? L10n.t(.scopeSwitchStatusFailed) : output]
            )
        }
        return output
    }

    private func shellQuote(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "'\\\"'\\\"'")
        return "'\(escaped)'"
    }

    private func extractServePID(from text: String) -> Int? {
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.contains("opencode"), trimmed.contains("serve") else { continue }
            let columns = trimmed.split(whereSeparator: { $0.isWhitespace })
            guard columns.count > 1, let pid = Int(columns[1]) else { continue }
            return pid
        }
        return nil
    }

    private func extractFirstInteger(from text: String) -> Int? {
        for token in text.split(whereSeparator: { !$0.isNumber }) {
            if let value = Int(token) {
                return value
            }
        }
        return nil
    }

    func loadFileContent(path: String) async throws -> FileContent {
        let resolved = PathNormalizer.resolveWorkspaceRelativePath(path, workspaceDirectory: currentSession?.directory)
        let fc = try await apiClient.fileContent(path: resolved)
        if fc.type == "text" {
            let text = fc.content ?? ""
            if text.isEmpty {
                let base = Self.serverURLInfo(serverURL).normalized ?? "nil"
                Self.logger.warning(
                    "Empty file content. base=\(base, privacy: .public) raw=\(path, privacy: .public) resolved=\(resolved, privacy: .public) session=\(self.currentSessionID ?? "nil", privacy: .public)"
                )
            }
        }
        return fc
    }

    /// Optimized image loading: all base64/JSON heavy lifting stays on APIClient actor.
    /// Only the decoded binary Data crosses the actor boundary back to MainActor.
    func loadImageData(path: String) async throws -> Data {
        let resolved = PathNormalizer.resolveWorkspaceRelativePath(path, workspaceDirectory: currentSession?.directory)
        return try await apiClient.imageData(path: resolved)
    }

    func transcribeAudio(audioFileURL: URL, language: String? = nil) async throws -> String {
        let token = aiBuilderToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw AIBuildersAudioError.missingToken }

        let base = aiBuilderBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = aiBuilderCustomPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let terms = aiBuilderTerminology.trimmingCharacters(in: .whitespacesAndNewlines)
        let resp = try await AIBuildersAudioClient.transcribe(
            baseURL: base,
            token: token,
            audioFileURL: audioFileURL,
            language: language,
            prompt: prompt.isEmpty ? nil : prompt,
            terms: terms.isEmpty ? nil : terms
        )
        return resp.text
    }

    func testAIBuilderConnection() async {
        guard !isTestingAIBuilderConnection else { return }
        isTestingAIBuilderConnection = true
        defer { isTestingAIBuilderConnection = false }

        aiBuilderConnectionError = nil
        aiBuilderConnectionOK = false
        let token = aiBuilderToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            aiBuilderConnectionError = L10n.t(.errorAiBuilderTokenEmpty)
            aiBuilderLastTestedAt = Date()
            return
        }
        let base = aiBuilderBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await AIBuildersAudioClient.testConnection(baseURL: base, token: token)
            aiBuilderConnectionOK = true
            aiBuilderLastTestedAt = Date()

            let sig = Self.aiBuilderSignature(baseURL: base, token: token)
            UserDefaults.standard.set(sig, forKey: Self.aiBuilderLastOKSignatureKey)
            UserDefaults.standard.set(aiBuilderLastTestedAt?.timeIntervalSince1970, forKey: Self.aiBuilderLastOKTestedAtKey)
        } catch {
            aiBuilderLastTestedAt = Date()
            aiBuilderConnectionOK = false
            UserDefaults.standard.removeObject(forKey: Self.aiBuilderLastOKSignatureKey)
            UserDefaults.standard.removeObject(forKey: Self.aiBuilderLastOKTestedAtKey)
            switch error {
            case AIBuildersAudioError.missingToken:
                aiBuilderConnectionError = L10n.t(.errorAiBuilderTokenEmpty)
            case AIBuildersAudioError.invalidBaseURL:
                aiBuilderConnectionError = L10n.t(.errorInvalidBaseURL)
            case AIBuildersAudioError.httpError(let statusCode, _):
                aiBuilderConnectionError = L10n.errorMessage(.errorServerError, String(statusCode))
            default:
                aiBuilderConnectionError = error.localizedDescription
            }
        }
    }

    func toggleFileExpanded(_ path: String) {
        if expandedPaths.contains(path) {
            expandedPaths.remove(path)
        } else {
            expandedPaths.insert(path)
        }
    }

    func isFileExpanded(_ path: String) -> Bool {
        expandedPaths.contains(path)
    }

    func sendMessage(_ text: String) async -> Bool {
        sendError = nil
        guard let sessionID = currentSessionID else {
            sendError = L10n.t(.chatSelectSessionFirst)
            return false
        }
        let tempMessageID = appendOptimisticUserMessage(text)
        let model = selectedModel.map { Message.ModelInfo(providerID: $0.providerID, modelID: $0.modelID) }
        let agentName = selectedAgent?.name ?? "build"
        do {
            try await apiClient.promptAsync(sessionID: sessionID, text: text, agent: agentName, model: model)
            return true
        } catch {
            let recovered = await recoverFromMissingCurrentSessionIfNeeded(error: error, requestedSessionID: sessionID)
            sendError = recovered ? L10n.t(.errorSessionNotFound) : error.localizedDescription
            removeMessage(id: tempMessageID)
            return false
        }
    }

    @discardableResult
    func appendOptimisticUserMessage(_ text: String) -> String {
        guard let sessionID = currentSessionID else { return "" }
        let now = Int(Date().timeIntervalSince1970 * 1000)
        let messageID = "temp-user-\(UUID().uuidString)"
        let partID = "temp-part-\(messageID)"
        let message = Message(
            id: messageID,
            sessionID: sessionID,
            role: "user",
            parentID: messages.last?.info.id,
            providerID: nil,
            modelID: nil,
            model: nil,
            error: nil,
            time: Message.TimeInfo(created: now, completed: now),
            finish: nil,
            tokens: nil,
            cost: nil
        )
        let part = Part(
            id: partID,
            messageID: messageID,
            sessionID: sessionID,
            type: "text",
            text: text,
            tool: nil,
            callID: nil,
            state: nil,
            metadata: nil,
            files: nil
        )
        let row = MessageWithParts(info: message, parts: [part])
        messages.append(row)
        partsByMessage[messageID] = [part]
        return messageID
    }

    func removeMessage(id: String) {
        messages.removeAll { $0.info.id == id }
        partsByMessage[id] = nil
    }

    private func bootstrapSyncCurrentSession(reason: String) async {
        guard currentSessionID != nil else { return }
        let start = Date()
        await loadMessages()
        await refreshPendingPermissions()
        await syncSessionStatusesFromPoll()
        let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
        Self.logger.debug("bootstrapSync reason=\(reason, privacy: .public) elapsedMs=\(elapsedMs, privacy: .public) messages=\(self.messages.count, privacy: .public) permissions=\(self.pendingPermissions.count, privacy: .public)")
    }

    private func syncSessionStatusesFromPoll(markMissingBusyAsIdle: Bool = true) async {
        guard isConnected else { return }
        guard let statuses = try? await apiClient.sessionStatus() else { return }
        mergePolledSessionStatuses(statuses, markMissingBusyAsIdle: markMissingBusyAsIdle)
    }

    func abortSession() async {
        guard let sessionID = currentSessionID else { return }
        do {
            try await apiClient.abort(sessionID: sessionID)
        } catch {
            if await recoverFromMissingCurrentSessionIfNeeded(error: error, requestedSessionID: sessionID) {
                return
            }
            connectionError = error.localizedDescription
        }

        await syncSessionStatusesFromPoll(markMissingBusyAsIdle: true)
        await loadMessages()
        await loadSessionDiff()
    }

    func updateSessionTitle(sessionID: String, title: String) async {
        do {
            _ = try await apiClient.updateSession(sessionID: sessionID, title: title)
            await refreshSessions()
        } catch {
            if await recoverFromMissingCurrentSessionIfNeeded(error: error, requestedSessionID: sessionID) {
                return
            }
            connectionError = error.localizedDescription
        }
    }

    func respondPermission(_ perm: PendingPermission, response: APIClient.PermissionResponse) async {
        do {
            try await apiClient.respondPermission(sessionID: perm.sessionID, permissionID: perm.permissionID, response: response)
            pendingPermissions.removeAll { $0.id == perm.id }
            await refreshPendingPermissions()
        } catch {
            connectionError = error.localizedDescription
        }
    }

    /// SSE permission events are not replayed; poll pending permissions so users can enter
    /// an in-progress session and still see the warning.
    func refreshPendingPermissions() async {
        guard isConnected else { return }
        do {
            let requests = try await apiClient.pendingPermissions()
            pendingPermissions = PermissionController.fromPendingRequests(requests)
        } catch {
            // Keep the current list on errors.
        }
    }

    func connectSSE() {
        sseTask?.cancel()
        sseTask = Task {
            var attempt = 0
            while !Task.isCancelled {
                let info = Self.serverURLInfo(serverURL)
                guard info.isAllowed, let baseURL = info.normalized else {
                    return
                }

                let stream = await sseClient.connect(
                    baseURL: baseURL,
                    username: username.isEmpty ? nil : username,
                    password: password.isEmpty ? nil : password
                )

                do {
                    await bootstrapSyncCurrentSession(reason: "sse.reconnect")
                    for try await event in stream {
                        attempt = 0
                        await handleSSEEvent(event)
                    }
                } catch {
                    // Reconnect with exponential backoff
                    attempt += 1
                    let base = min(30.0, pow(2.0, Double(attempt)))
                    try? await Task.sleep(for: .seconds(base))
                }
            }
        }
    }

    func disconnectSSE() {
        sseTask?.cancel()
        sseTask = nil
    }
    
    // Note: AppState is typically held for the app's lifetime (as @State in root view),
    // so deinit-based cleanup is not critical. The disconnectSSE() method above
    // should be called explicitly when needed (e.g., on background/terminate).

    /// 是否应处理 message.updated：必须有明确的 sessionID 且匹配当前 session
    nonisolated static func shouldProcessMessageEvent(eventSessionID: String?, currentSessionID: String?) -> Bool {
        guard let currentSessionID else { return false }
        guard let sid = eventSessionID else { return false }
        return sid == currentSessionID
    }

    /// Async request result should only apply when requested session is still current.
    nonisolated static func shouldApplySessionScopedResult(requestedSessionID: String, currentSessionID: String?) -> Bool {
        requestedSessionID == currentSessionID
    }

    private func handleSSEEvent(_ event: SSEEvent) async {
        let type = event.payload.type
        let props = event.payload.properties ?? [:]

        switch type {
        case "server.connected":
            await syncSessionStatusesFromPoll(markMissingBusyAsIdle: true)
        case "session.status":
            if let sessionID = props["sessionID"]?.value as? String,
                let statusObj = props["status"]?.value as? [String: Any] {
                if let status = try? JSONSerialization.data(withJSONObject: statusObj),
                    let decoded = try? JSONDecoder().decode(SessionStatus.self, from: status) {
                    let prev = sessionStatuses[sessionID]

                    sessionStatuses[sessionID] = decoded
                    sessionStatusUpdatedAt[sessionID] = Date()

                    if prev?.type != decoded.type || prev?.message != decoded.message {
                        Self.logger.debug(
                            "session.status(sse) session=\(sessionID, privacy: .public) prev=\(prev?.type ?? "nil", privacy: .public) next=\(decoded.type, privacy: .public)"
                        )
                    }

                    updateSessionActivity(sessionID: sessionID, previous: prev, current: decoded)

                    if sessionID == currentSessionID, !isBusySession(decoded) {
                        streamingReasoningPart = nil
                        streamingPartTexts = [:]
                        streamingDraftMessageIDs.removeAll()

                        if isBusySession(prev) {
                            await loadMessages()
                            await loadSessionDiff()
                        }
                    }
                }
            }
        case "session.updated":
            let infoVal = props["info"]?.value ?? props["session"]?.value
            if let infoObj = infoVal,
               JSONSerialization.isValidJSONObject(infoObj),
               let data = try? JSONSerialization.data(withJSONObject: infoObj),
               let session = try? JSONDecoder().decode(Session.self, from: data) {
                let dir = effectiveProjectDirectory
                let isCurrent = (session.id == currentSessionID)
                let matchesProject = dir == nil || session.directory == dir
                let shouldApply = matchesProject || isCurrent
                if shouldApply {
                    let wasUpdate = sessions.contains(where: { $0.id == session.id })
                    Self.logger.debug("session.updated id=\(session.id, privacy: .public) archived=\(session.time.archived.map { String($0) } ?? "nil", privacy: .public) dir=\(session.directory, privacy: .public) op=\(wasUpdate ? "replace" : "insert", privacy: .public)")
                    if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
                        sessions[idx] = session
                    } else {
                        sessions.insert(session, at: 0)
                    }
                } else {
                    Self.logger.debug("session.updated skip id=\(session.id, privacy: .public) dir=\(session.directory, privacy: .public) effectiveDir=\(dir ?? "nil", privacy: .public)")
                }
            }
        case "session.deleted":
            if let sessionID = (props["sessionID"]?.value as? String) ?? (props["id"]?.value as? String) {
                Self.logger.debug("session.deleted id=\(sessionID, privacy: .public)")
                await handleRemoteSessionDeleted(sessionID: sessionID)
            } else {
                await loadSessions()
            }
        case "message.updated":
            let eventSessionID = props["sessionID"]?.value as? String
            if Self.shouldProcessMessageEvent(eventSessionID: eventSessionID, currentSessionID: currentSessionID) {
                if isBusy {
                    streamingReasoningPart = nil
                    streamingPartTexts = [:]
                    streamingDraftMessageIDs.removeAll()
                    await loadMessages()
                    await loadSessionDiff()
                } else {
                    await loadSessionDiff()
                }
            }
        case "message.part.updated":
            if let sessionID = props["sessionID"]?.value as? String,
               sessionID == currentSessionID,
               isBusy {
                let partObj = props["part"]?.value as? [String: Any]
                let msgID = partObj?["messageID"] as? String
                let partID = partObj?["id"] as? String
                let partType = (partObj?["type"] as? String) ?? "text"

                if let msgID,
                   let partID {
                    let key = "\(msgID):\(partID)"

                    if let delta = props["delta"]?.value as? String,
                       !delta.isEmpty {
                        let text = (streamingPartTexts[key] ?? "") + delta
                        streamingPartTexts[key] = text
                        if partType == "reasoning" {
                            streamingReasoningPart = Part(
                                id: partID,
                                messageID: msgID,
                                sessionID: sessionID,
                                type: "reasoning",
                                text: nil,
                                tool: nil,
                                callID: nil,
                                state: nil,
                                metadata: nil,
                                files: nil
                            )
                        } else {
                            upsertStreamingMessage(
                                messageID: msgID,
                                partID: partID,
                                sessionID: sessionID,
                                type: partType,
                                text: text
                            )
                        }

                        refreshSessionActivityText(sessionID: sessionID)
                    } else {
                        clearStreamingState(messageID: msgID)
                        await loadMessages()
                        await loadSessionDiff()
                    }
                }
            }
        case "permission.asked":
            if let perm = PermissionController.parseAskedEvent(properties: props),
               !pendingPermissions.contains(where: { $0.id == perm.id }) {
                pendingPermissions.append(perm)
            }
        case "permission.replied":
            PermissionController.applyRepliedEvent(properties: props, to: &pendingPermissions)
        case "todo.updated":
            if let sessionID = props["sessionID"]?.value as? String,
               let todosObj = props["todos"]?.value,
               JSONSerialization.isValidJSONObject(todosObj),
               let todosData = try? JSONSerialization.data(withJSONObject: todosObj),
               let decoded = try? JSONDecoder().decode([TodoItem].self, from: todosData) {
                sessionTodos[sessionID] = decoded
            }
        default:
            break
        }
    }

    private func updateSessionActivity(sessionID: String, previous: SessionStatus?, current: SessionStatus) {
        sessionActivities[sessionID] = ActivityTracker.updateSessionActivity(
            sessionID: sessionID,
            previous: previous,
            current: current,
            existing: sessionActivities[sessionID],
            messages: messages,
            currentSessionID: currentSessionID,
            hasActiveStreaming: streamingReasoningPart?.sessionID == sessionID
                || !streamingPartTexts.isEmpty
                || !streamingDraftMessageIDs.isEmpty
        )
    }

    private func mergePolledSessionStatuses(_ statuses: [String: SessionStatus]) {
        mergePolledSessionStatuses(statuses, markMissingBusyAsIdle: true)
    }

    private func mergePolledSessionStatuses(
        _ statuses: [String: SessionStatus],
        markMissingBusyAsIdle: Bool
    ) {
        let now = Date()
        for (sid, st) in statuses {
            if let updatedAt = sessionStatusUpdatedAt[sid], now.timeIntervalSince(updatedAt) < 5 {
                continue
            }
            let prev = sessionStatuses[sid]
            sessionStatuses[sid] = st
            updateSessionActivity(sessionID: sid, previous: prev, current: st)
            if sid == currentSessionID, !isBusySession(st) {
                streamingReasoningPart = nil
                streamingPartTexts = [:]
                streamingDraftMessageIDs.removeAll()
            }
            if prev?.type != st.type {
                Self.logger.debug(
                    "session.status(poll) session=\(sid, privacy: .public) prev=\(prev?.type ?? "nil", privacy: .public) next=\(st.type, privacy: .public)"
                )
            }
        }

        guard markMissingBusyAsIdle else { return }

        let existingSnapshot = sessionStatuses
        for (sid, prev) in existingSnapshot {
            guard statuses[sid] == nil else { continue }
            guard prev.type == "busy" || prev.type == "retry" else { continue }
            if let updatedAt = sessionStatusUpdatedAt[sid], now.timeIntervalSince(updatedAt) < 5 {
                continue
            }

            let idle = SessionStatus(type: "idle", attempt: nil, message: nil, next: nil)
            sessionStatuses[sid] = idle
            updateSessionActivity(sessionID: sid, previous: prev, current: idle)
            if sid == currentSessionID {
                streamingReasoningPart = nil
                streamingPartTexts = [:]
                streamingDraftMessageIDs.removeAll()
            }

            Self.logger.debug(
                "session.status(poll) session=\(sid, privacy: .public) prev=\(prev.type, privacy: .public) next=idle (missing from poll)"
            )
        }
    }

    private func refreshSessionActivityText(sessionID: String) {
        guard isBusySession(sessionStatuses[sessionID]) else { return }
        guard sessionActivities[sessionID]?.state == .running else { return }
        let next = ActivityTracker.bestSessionActivityText(
            sessionID: sessionID,
            currentSessionID: currentSessionID,
            sessionStatuses: sessionStatuses,
            messages: messages,
            streamingReasoningPart: streamingReasoningPart,
            streamingPartTexts: streamingPartTexts
        )
        setSessionActivityText(sessionID: sessionID, next)
    }

    private func setSessionActivityText(sessionID: String, _ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard var a = sessionActivities[sessionID], a.state == .running else { return }
        if a.text == trimmed { return }

        let now = Date()
        let delay = ActivityTracker.debounceDelay(lastChangeAt: activityTextLastChangeAt[sessionID], now: now)
        if delay == 0 {
            a.text = trimmed
            sessionActivities[sessionID] = a
            activityTextLastChangeAt[sessionID] = now
            activityTextPendingTask[sessionID]?.cancel()
            activityTextPendingTask[sessionID] = nil
            return
        }

        activityTextPendingTask[sessionID]?.cancel()
        activityTextPendingTask[sessionID] = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            guard self.isBusySession(self.sessionStatuses[sessionID]) else { return }
            let best = ActivityTracker.bestSessionActivityText(
                sessionID: sessionID,
                currentSessionID: self.currentSessionID,
                sessionStatuses: self.sessionStatuses,
                messages: self.messages,
                streamingReasoningPart: self.streamingReasoningPart,
                streamingPartTexts: self.streamingPartTexts
            )
            self.setSessionActivityText(sessionID: sessionID, best)
        }
    }

    private func upsertStreamingMessage(
        messageID: String,
        partID: String,
        sessionID: String,
        type: String,
        text: String
    ) {
        let part = Part(
            id: partID,
            messageID: messageID,
            sessionID: sessionID,
            type: type,
            text: text,
            tool: nil,
            callID: nil,
            state: nil,
            metadata: nil,
            files: nil
        )

        if let idx = messages.firstIndex(where: { $0.info.id == messageID }) {
            let current = messages[idx]
            var updatedParts = current.parts
            if let partIdx = updatedParts.firstIndex(where: { $0.id == partID }) {
                updatedParts[partIdx] = part
            } else {
                updatedParts.append(part)
            }

            messages[idx] = MessageWithParts(info: current.info, parts: updatedParts)
            partsByMessage[messageID] = updatedParts
            streamingDraftMessageIDs.insert(messageID)
            return
        }

        let now = Int(Date().timeIntervalSince1970 * 1000)
        let message = Message(
            id: messageID,
            sessionID: sessionID,
            role: "assistant",
            parentID: messages.last?.info.id,
            providerID: nil,
            modelID: nil,
            model: nil,
            error: nil,
            time: Message.TimeInfo(created: now, completed: now),
            finish: nil,
            tokens: nil,
            cost: nil
        )

        messages.append(MessageWithParts(info: message, parts: [part]))
        partsByMessage[messageID] = [part]
        streamingDraftMessageIDs.insert(messageID)
    }

    private func clearStreamingState(messageID: String) {
        for key in streamingPartTexts.keys where key.hasPrefix("\(messageID):") {
            streamingPartTexts.removeValue(forKey: key)
        }

        if streamingReasoningPart?.messageID == messageID {
            streamingReasoningPart = nil
        }
        streamingDraftMessageIDs.remove(messageID)
    }

    private func clearCurrentSessionViewState() {
        sessionLoadingID = UUID()
        streamingReasoningPart = nil
        streamingPartTexts = [:]
        streamingDraftMessageIDs = []
        messages = []
        partsByMessage = [:]
        sessionDiffs = []
    }

    private func clearSessionScopedCaches(sessionID: String) {
        sessionStatuses[sessionID] = nil
        sessionTodos[sessionID] = nil
        sessionActivities[sessionID] = nil
        sessionStatusUpdatedAt[sessionID] = nil
        activityTextLastChangeAt[sessionID] = nil
        activityTextPendingTask[sessionID]?.cancel()
        activityTextPendingTask[sessionID] = nil
        loadedMessageLimitBySessionID[sessionID] = nil
        hasMoreHistoryBySessionID[sessionID] = nil
        loadingOlderMessagesSessionIDs.remove(sessionID)
        pendingPermissions.removeAll { $0.sessionID == sessionID }

        if streamingReasoningPart?.sessionID == sessionID {
            streamingReasoningPart = nil
        }

        draftInputsBySessionID[sessionID] = nil
        if draftInputsBySessionID.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.draftInputsBySessionKey)
        } else if let data = try? JSONEncoder().encode(draftInputsBySessionID) {
            UserDefaults.standard.set(data, forKey: Self.draftInputsBySessionKey)
        }

        selectedModelIDBySessionID[sessionID] = nil
        persistSelectedModelMap()
    }

    private func isSessionNotFoundError(_ error: Error) -> Bool {
        guard case APIError.httpError(let statusCode, _) = error else { return false }
        return statusCode == 404
    }

    private func recoverFromMissingCurrentSessionIfNeeded(
        error: Error,
        requestedSessionID: String
    ) async -> Bool {
        guard requestedSessionID == currentSessionID else { return false }
        guard isSessionNotFoundError(error) else { return false }

        await loadSessions()

        guard currentSessionID != nil else {
            pendingPermissions = []
            return true
        }

        await loadMessages()
        await refreshPendingPermissions()
        await loadSessionDiff()
        await loadSessionTodos()
        inferAndStoreModelForCurrentSessionIfMissing()
        return true
    }

    private func handleRemoteSessionDeleted(sessionID: String) async {
        let deletedCurrentSession = (sessionID == currentSessionID)

        sessions.removeAll { $0.id == sessionID }
        clearSessionScopedCaches(sessionID: sessionID)

        if deletedCurrentSession {
            clearCurrentSessionViewState()
        }

        await loadSessions()

        if deletedCurrentSession, currentSessionID != nil {
            await loadMessages()
            await refreshPendingPermissions()
            await loadSessionDiff()
            await loadSessionTodos()
            inferAndStoreModelForCurrentSessionIfMissing()
        } else if currentSessionID == nil {
            pendingPermissions = []
        } else {
            let validSessionIDs = Set(sessions.map(\.id))
            pendingPermissions.removeAll { !validSessionIDs.contains($0.sessionID) }
        }
    }

    func refresh() async {
        await testConnection()
        if isConnected {
            async let agentsResult = loadAgents()
            async let providersResult = loadProvidersConfig()
            async let projectsResult = loadProjects()
            await loadSessions()
            _ = await agentsResult
            _ = await providersResult
            _ = await projectsResult
            await loadMessages()
            await refreshPendingPermissions()
            await loadSessionDiff()
            await loadSessionTodos()
            await loadFileTree()
            await loadFileStatus()
            await loadScopeSwitchCandidates()
            await loadTargetTree()
            await syncSessionStatusesFromPoll()
        }
    }

    /// Refresh after scope switch, preserving the worktree that we just verified.
    private func refreshAfterScopeSwitch(preservedWorktree: String) async {
        await testConnection()
        if isConnected {
            async let agentsResult = loadAgents()
            async let providersResult = loadProvidersConfig()
            await loadSessions()
            _ = await agentsResult
            _ = await providersResult
            // Skip loadProjects() — it would overwrite serverCurrentProjectWorktree
            // with the server's git-root-based worktree (often "/"), losing our scope path.
            serverCurrentProjectWorktree = preservedWorktree
            await loadMessages()
            await refreshPendingPermissions()
            await loadSessionDiff()
            await loadSessionTodos()
            await loadFileTree()
            await loadFileStatus()
            await syncSessionStatusesFromPoll()
        }
    }

    func loadProvidersConfig() async {
        do {
            let resp = try await apiClient.providers()
            providersResponse = resp
            providerConfigError = nil
            var idx: [String: ProviderModel] = [:]
            for p in resp.providers {
                for (modelID, m) in p.models {
                    let key = "\(p.id)/\(modelID)"
                    idx[key] = m
                }
            }
            providerModelsIndex = idx
            applyModelPresets(buildModelPresets(from: resp))
        } catch {
            providerConfigError = error.localizedDescription
        }
    }

    private var providerDisplayNamesByID: [String: String] {
        guard let providersResponse else { return [:] }
        return providersResponse.providers.reduce(into: [:]) { result, provider in
            let name = provider.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let name, !name.isEmpty {
                result[provider.id] = name
            }
        }
    }

    private func applyModelPresets(_ presets: [ModelPreset]) {
        guard !presets.isEmpty else { return }

        let oldSelectedID = selectedModel?.id
        modelPresets = presets

        if let sessionID = currentSessionID,
           let savedID = selectedModelIDBySessionID[sessionID],
           let savedIndex = modelPresets.firstIndex(where: { $0.id == savedID }) {
            selectedModelIndex = savedIndex
            noteModelUsage(modelPresets[savedIndex].id)
            return
        }

        if let oldSelectedID,
           let oldIndex = modelPresets.firstIndex(where: { $0.id == oldSelectedID }) {
            selectedModelIndex = oldIndex
        } else {
            selectedModelIndex = Self.preferredModelIndex(in: modelPresets)
        }
        noteModelUsage(modelPresets[selectedModelIndex].id)

        if let sessionID = currentSessionID {
            selectedModelIDBySessionID[sessionID] = modelPresets[selectedModelIndex].id
            persistSelectedModelMap()
        }
    }

    private func noteModelUsage(_ modelPresetID: String) {
        guard !modelPresetID.isEmpty else { return }
        recentModelIDs.removeAll { $0 == modelPresetID }
        recentModelIDs.insert(modelPresetID, at: 0)
        if recentModelIDs.count > 6 {
            recentModelIDs = Array(recentModelIDs.prefix(6))
        }
        persistRecentModels()
    }

    private func buildModelPresets(from response: ProvidersResponse) -> [ModelPreset] {
        var providers = response.providers.filter { !$0.models.isEmpty }
        providers.sort { Self.providerSortKey($0.id) < Self.providerSortKey($1.id) }

        var presets: [ModelPreset] = []
        presets.reserveCapacity(providers.reduce(0) { $0 + $1.models.count })

        for provider in providers {
            let models = provider.models.values.sorted {
                Self.modelSortKey(providerID: provider.id, modelID: $0.id, name: $0.name) < Self.modelSortKey(providerID: provider.id, modelID: $1.id, name: $1.name)
            }

            for model in models {
                let modelID = model.id.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !modelID.isEmpty else { continue }
                presets.append(
                    ModelPreset(
                        displayName: Self.displayName(providerID: provider.id, modelID: modelID, rawName: model.name),
                        providerID: provider.id,
                        modelID: modelID
                    )
                )
            }
        }

        var seen: Set<String> = []
        var deduped: [ModelPreset] = []
        deduped.reserveCapacity(presets.count)
        for preset in presets {
            if seen.insert(preset.id).inserted {
                deduped.append(preset)
            }
        }

        return deduped.isEmpty ? modelPresets : deduped
    }

    private func modelPresetIndex(providerID: String, modelID: String) -> Int? {
        if let exact = modelPresets.firstIndex(where: { $0.providerID == providerID && $0.modelID == modelID }) {
            return exact
        }

        guard providerID == Self.openAIProviderID else { return nil }

        if Self.preferredOpenAIModelIDs.contains(modelID) {
            let preferredID = Self.preferredOpenAIModelIDs.first ?? "gpt-5.3-codex"
            return modelPresets.firstIndex(where: {
                $0.providerID == Self.openAIProviderID && $0.modelID == preferredID
            })
        }

        return nil
    }

    private static func preferredModelIndex(in presets: [ModelPreset]) -> Int {
        guard !presets.isEmpty else { return 0 }
        for preferredID in preferredOpenAIModelIDs {
            if let idx = presets.firstIndex(where: { $0.providerID == openAIProviderID && $0.modelID == preferredID }) {
                return idx
            }
        }
        if let firstOpenAI = presets.firstIndex(where: { $0.providerID == openAIProviderID }) {
            return firstOpenAI
        }
        return 0
    }

    private static func providerSortKey(_ providerID: String) -> String {
        providerID == openAIProviderID ? "0_\(providerID)" : "1_\(providerID)"
    }

    private static func modelSortKey(providerID: String, modelID: String, name: String?) -> String {
        if providerID == openAIProviderID,
           let rank = preferredOpenAIModelIDs.firstIndex(of: modelID) {
            return String(format: "%02d_%@", rank, modelID)
        }

        let title = displayName(providerID: providerID, modelID: modelID, rawName: name)
        return "99_\(title.lowercased())"
    }

    private static func displayName(providerID: String, modelID: String, rawName: String?) -> String {
        let normalized = modelID.lowercased()
        if providerID == openAIProviderID {
            if normalized == "gpt-5.3-codex-spark" {
                return "GPT-5.3 Codex Spark"
            }
            if normalized == "gpt-5.3-codex" {
                return "GPT-5.3 Codex"
            }
            if normalized == "gpt-5.2" {
                return "GPT-5.2"
            }
        }

        if let rawName {
            let cleaned = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty { return cleaned }
        }
        return modelID
    }
}

struct PendingPermission: Identifiable {
    var id: String { "\(sessionID)/\(permissionID)" }
    let sessionID: String
    let permissionID: String
    let permission: String?
    let patterns: [String]
    let allowAlways: Bool
    let tool: String?
    let description: String
}

struct SessionActivity: Identifiable {
    enum State {
        case running
        case completed
    }

    var id: String { sessionID }
    let sessionID: String
    var state: State
    var text: String
    let startedAt: Date
    var endedAt: Date?
    var anchorMessageID: String?

    func elapsedSeconds(now: Date = Date()) -> Int {
        let end = endedAt ?? now
        return max(0, Int(end.timeIntervalSince(startedAt)))
    }

    func elapsedString(now: Date = Date()) -> String {
        let secs = elapsedSeconds(now: now)
        return String(format: "%d:%02d", secs / 60, secs % 60)
    }
}
