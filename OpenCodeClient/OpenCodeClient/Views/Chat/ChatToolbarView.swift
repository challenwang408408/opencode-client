//
//  ChatToolbarView.swift
//  OpenCodeClient
//

import SwiftUI

struct ChatToolbarView: View {
    @Bindable var state: AppState
    @Binding var showSessionList: Bool
    @Binding var showRenameAlert: Bool
    @Binding var renameText: String
    @Binding var showTechnicalDetails: Bool
    var showSettingsInToolbar: Bool
    var onSettingsTap: (() -> Void)?
    
    @State private var showCreateDisabledAlert = false
    @State private var showModelPicker = false
    @State private var showScopeSheet = false
    @State private var modelSearchText = ""
    @State private var collapsedProviderIDs: Set<String> = []
    @Environment(\.horizontalSizeClass) private var sizeClass
    
    private var useCompactLabels: Bool {
#if canImport(UIKit)
        return UIDevice.current.userInterfaceIdiom == .phone
#else
        return false
#endif
    }
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                sessionButtons
                Spacer()
                rightButtons
            }
            .padding(.horizontal, LayoutConstants.Spacing.spacious)
            .padding(.vertical, LayoutConstants.MessageList.verticalPadding)

        }
    }
    
    // MARK: - Session Operation Buttons
    private var sessionButtons: some View {
        HStack(spacing: LayoutConstants.Toolbar.buttonSpacing) {
            Button {
                showSessionList = true
            } label: {
                Image(systemName: "list.bullet.circle.fill")
                    .font(.title3)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundColor(.accentColor)
            }
            
            Button {
                renameText = state.currentSession?.title ?? ""
                showRenameAlert = true
            } label: {
                Image(systemName: "pencil.circle.fill")
                    .font(.title3)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundColor(.accentColor)
            }
            
            Button {
                Task { await state.createSession() }
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundColor(state.canCreateSession ? .accentColor : .gray)
            }
            .disabled(!state.canCreateSession)

            if !state.canCreateSession {
                Button {
                    showCreateDisabledAlert = true
                } label: {
                    Image(systemName: "info.circle")
                        .font(.title3)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .alert(L10n.t(.chatCreateDisabledHint), isPresented: $showCreateDisabledAlert) {
            Button(L10n.t(.commonOk)) {}
        }
    }
    
    // MARK: - Right Side Buttons (Connect + Model + Agent + Settings)
    private var rightButtons: some View {
        HStack(spacing: LayoutConstants.Toolbar.modelButtonSpacing) {
            scopeConnectButton
            Button {
                showTechnicalDetails.toggle()
            } label: {
                Image(systemName: showTechnicalDetails ? "slider.horizontal.3" : "line.3.horizontal.decrease.circle")
                    .font(.title3)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundColor(showTechnicalDetails ? .accentColor : .secondary)
            }
            .accessibilityLabel(L10n.t(.chatTechnicalDetailsToggle))
            modelMenu
            agentMenu
            ContextUsageButton(state: state)
            
            if showSettingsInToolbar, let onSettingsTap {
                Button {
                    onSettingsTap()
                } label: {
                    Image(systemName: "gear")
                        .font(.title3)
                        .symbolRenderingMode(.hierarchical)
                }
            }
        }
    }
    
    // MARK: - Model Selection Menu
    private var modelMenu: some View {
        Button {
            showModelPicker = true
        } label: {
            HStack(spacing: 4) {
                Text(useCompactLabels ? (state.selectedModel?.shortName ?? "Model") : (state.selectedModel?.displayName ?? "Model"))
                    .font(.caption.weight(.semibold))
                Image(systemName: "chevron.down")
                    .font(.caption2)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.accentColor.gradient)
            .foregroundColor(.white)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showModelPicker) {
            modelPickerSheet
                .onAppear {
                    resetCollapsedProviders()
                }
        }
    }

    private var modelPickerSheet: some View {
        NavigationStack {
            List {
                Section {
                    Text("Models shown reflect your account permissions and subscription availability.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if !filteredRecentPresets.isEmpty {
                    Section("Recent") {
                        ForEach(filteredRecentPresets) { preset in
                            modelRow(preset)
                        }
                    }
                }

                ForEach(filteredModelPresetGroups, id: \.group.id) { entry in
                    DisclosureGroup(isExpanded: isGroupExpandedBinding(entry.group.providerID)) {
                        ForEach(entry.presets) { preset in
                            modelRow(preset)
                        }
                    } label: {
                        Text(entry.group.displayName)
                            .fontWeight(entry.group.providerID == "openai" ? .bold : .regular)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Models")
            .searchable(text: $modelSearchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search models or providers")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        showModelPicker = false
                    }
                }
            }
        }
    }

    private func modelRow(_ preset: ModelPreset) -> some View {
        Button {
            if let index = state.modelPresets.firstIndex(where: { $0.id == preset.id }) {
                state.setSelectedModelIndex(index)
                showModelPicker = false
            }
        } label: {
            HStack {
                Text(preset.displayName)
                Spacer()
                if state.selectedModel?.id == preset.id {
                    Image(systemName: "checkmark")
                        .foregroundColor(.accentColor)
                }
            }
        }
    }

    private var filteredRecentPresets: [ModelPreset] {
        let query = normalizedSearch
        guard !query.isEmpty else { return state.recentModelPresets }
        return state.recentModelPresets.filter { preset in
            let providerName = providerNameByPresetID[preset.id] ?? ""
            let text = "\(preset.displayName) \(preset.shortName) \(providerName)".lowercased()
            return text.contains(query)
        }
    }

    private var filteredModelPresetGroups: [(group: AppState.ModelProviderGroup, presets: [ModelPreset])] {
        let query = normalizedSearch
        let recentIDs = Set(filteredRecentPresets.map { $0.id })
        return state.modelPresetGroups.compactMap { group in
            let groupMatches = query.isEmpty ? true : group.displayName.lowercased().contains(query)
            let presets = group.presets.filter { preset in
                if recentIDs.contains(preset.id) { return false }
                if query.isEmpty { return true }
                if groupMatches { return true }
                let text = "\(preset.displayName) \(preset.shortName)".lowercased()
                return text.contains(query)
            }
            return presets.isEmpty ? nil : (group: group, presets: presets)
        }
    }

    private var providerNameByPresetID: [String: String] {
        var map: [String: String] = [:]
        for group in state.modelPresetGroups {
            for preset in group.presets {
                map[preset.id] = group.displayName
            }
        }
        return map
    }

    private var normalizedSearch: String {
        modelSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func resetCollapsedProviders() {
        let providerIDs = state.modelPresetGroups.map { $0.providerID }
        collapsedProviderIDs = Set(providerIDs.filter { $0 != "openai" })
    }

    private func isGroupExpandedBinding(_ providerID: String) -> Binding<Bool> {
        Binding(
            get: { !collapsedProviderIDs.contains(providerID) },
            set: { isExpanded in
                if isExpanded {
                    collapsedProviderIDs.remove(providerID)
                } else {
                    collapsedProviderIDs.insert(providerID)
                }
            }
        )
    }
    
    // MARK: - Scope Connect Button
    private var scopeConnectButton: some View {
        Button {
            showScopeSheet = true
        } label: {
            HStack(spacing: 4) {
                if state.targetScopeSwitchStatus.isBusy {
                    ProgressView()
                        .scaleEffect(0.6)
                        .tint(.white)
                } else {
                    Image(systemName: "link")
                        .font(.caption2.weight(.bold))
                }
                Text(scopeConnectLabel)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(scopeConnectBackground)
            .foregroundColor(scopeConnectForeground)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showScopeSheet) {
            ScopeConnectSheet(state: state)
        }
    }

    private var scopeConnectLabel: String {
        if state.targetScopeSwitchStatus.isBusy {
            return L10n.t(.filesConnectInProgress)
        }
        if let worktree = state.serverCurrentProjectWorktree,
           !worktree.isEmpty, worktree != "/" {
            return (worktree as NSString).lastPathComponent
        }
        return L10n.t(.chatConnectButton)
    }

    private var scopeConnectBackground: some ShapeStyle {
        if state.targetScopeSwitchStatus == .connected {
            return AnyShapeStyle(Color.green.gradient)
        }
        if state.targetScopeSwitchStatus.isBusy {
            return AnyShapeStyle(Color.orange.gradient)
        }
        return AnyShapeStyle(Color(.systemGray5))
    }

    private var scopeConnectForeground: Color {
        if state.targetScopeSwitchStatus == .connected || state.targetScopeSwitchStatus.isBusy {
            return .white
        }
        return .secondary
    }

    // MARK: - Agent Selection Menu
    private var agentMenu: some View {
        Menu {
            if state.isLoadingAgents {
                ProgressView()
            } else if state.visibleAgents.isEmpty {
                Text("No agents available")
            } else {
                ForEach(Array(state.visibleAgents.enumerated()), id: \.element.id) { index, agent in
                    Button {
                        state.setSelectedAgentIndex(index)
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(agent.shortName)
                                if !useCompactLabels, let desc = agent.description, !desc.isEmpty {
                                    Text(desc)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            if state.selectedAgentIndex == index {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(useCompactLabels ? (state.selectedAgent?.shortName ?? "Agent") : (state.selectedAgent?.name ?? "Agent"))
                    .font(.caption.weight(.semibold))
                Image(systemName: "chevron.down")
                    .font(.caption2)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color(.systemGray5))
            .foregroundColor(.secondary)
            .clipShape(Capsule())
        }
        .menuStyle(.borderlessButton)
    }
}

// MARK: - Scope Connect Sheet

struct ScopeConnectSheet: View {
    @Bindable var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                sessionDirectorySection
                currentTargetSection
                connectionHistorySection
                candidateSection
                statusSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle(L10n.t(.chatConnectSheetTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t(.commonOk)) { dismiss() }
                }
            }
            .task {
                await state.loadScopeSwitchCandidates()
            }
        }
    }

    // MARK: - Session Directories
    @ViewBuilder
    private var sessionDirectorySection: some View {
        let dirs = state.uniqueSessionDirectories
        if !dirs.isEmpty {
            Section(L10n.t(.chatSessionDirectories)) {
                ForEach(dirs, id: \.self) { dir in
                    sessionDirectoryRow(dir)
                }
            }
        }
    }

    private func sessionDirectoryRow(_ dir: String) -> some View {
        let folderName = (dir as NSString).lastPathComponent
        let isCurrentTarget = state.serverCurrentProjectWorktree == dir
        let isSwitching = state.targetScopeSwitchStatus.isBusy && state.targetScopeSwitchTargetPath == dir

        return HStack(spacing: 10) {
            Image(systemName: "folder.fill")
                .foregroundStyle(isCurrentTarget ? .green : .blue)
            VStack(alignment: .leading, spacing: 2) {
                Text(folderName)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(dir)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer()
            if isCurrentTarget {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button {
                    state.startTargetScopeSwitch(path: dir)
                } label: {
                    if isSwitching {
                        HStack(spacing: 4) {
                            ProgressView().scaleEffect(0.7)
                            Text(L10n.t(.filesConnectInProgress))
                        }
                    } else {
                        Text(L10n.t(.filesSwitch))
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(state.targetScopeSwitchStatus.isBusy)
            }
        }
    }

    // MARK: - Current Target
    private var currentTargetSection: some View {
        Section(L10n.t(.filesCurrentTargetsTitle)) {
            if let worktree = state.serverCurrentProjectWorktree,
               !worktree.isEmpty, worktree != "/" {
                HStack(spacing: 8) {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text((worktree as NSString).lastPathComponent)
                            .font(.body.weight(.medium))
                        Text(worktree)
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                    }
                }
            } else {
                Text(L10n.t(.filesNoCurrentTarget))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Connection History
    @ViewBuilder
    private var connectionHistorySection: some View {
        let history = state.connectionHistoryForDisplay
        if !history.isEmpty {
            Section(L10n.t(.filesConnectionHistory)) {
                ForEach(history, id: \.self) { path in
                    historyRow(path)
                }
            }
        }
    }

    private func historyRow(_ path: String) -> some View {
        let folderName = (path as NSString).lastPathComponent
        let isSwitching = state.targetScopeSwitchStatus.isBusy && state.targetScopeSwitchTargetPath == path
        return HStack(spacing: 10) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(folderName)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                state.startTargetScopeSwitch(path: path)
            } label: {
                if isSwitching {
                    HStack(spacing: 4) {
                        ProgressView().scaleEffect(0.7)
                        Text(L10n.t(.filesConnectInProgress))
                    }
                } else {
                    Text(L10n.t(.filesSwitch))
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(state.targetScopeSwitchStatus.isBusy)
        }
    }

    // MARK: - Candidate Projects
    private var candidateSection: some View {
        Section(L10n.t(.filesCandidateTitle)) {
            if state.isDetectingServerEnv {
                loadingRow(L10n.t(.filesDetectingEnv))
            }

            if state.isLoadingScopeCandidates {
                loadingRow(L10n.t(.fileLoading))
            }

            if !state.isLoadingScopeCandidates && !state.isDetectingServerEnv {
                desktopGroup
                aiTestGroup
            }
        }
    }

    @ViewBuilder
    private var desktopGroup: some View {
        if !state.desktopScopeCandidates.isEmpty {
            DisclosureGroup {
                ForEach(state.desktopScopeCandidates) { candidate in
                    candidateRow(candidate)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "desktopcomputer")
                        .foregroundStyle(.blue)
                    Text(L10n.t(.filesDesktopGroup))
                        .font(.body.weight(.medium))
                }
            }
        }
    }

    @ViewBuilder
    private var aiTestGroup: some View {
        if !state.aiTestScopeCandidates.isEmpty {
            DisclosureGroup {
                ForEach(state.aiTestScopeCandidates) { candidate in
                    candidateRow(candidate)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder.fill.badge.gearshape")
                        .foregroundStyle(.orange)
                    Text(L10n.t(.filesAITestGroup))
                        .font(.body.weight(.medium))
                }
            }
        }

        if state.desktopScopeCandidates.isEmpty && state.aiTestScopeCandidates.isEmpty {
            Text(L10n.t(.filesNoCurrentTarget))
                .foregroundStyle(.secondary)
                .font(.footnote)
        }
    }

    private func candidateRow(_ candidate: AppState.ScopeSwitchCandidate) -> some View {
        let isDirectory = candidate.type == "directory"
        let isSwitchingCurrent = state.targetScopeSwitchStatus.isBusy && state.targetScopeSwitchTargetPath == candidate.path
        let isCurrentTarget = state.serverCurrentProjectWorktree == candidate.path

        return HStack(spacing: 10) {
            Image(systemName: isDirectory ? "folder.fill" : "doc.text")
                .foregroundStyle(isCurrentTarget ? .green : .secondary)
            Text(candidate.name)
                .font(.body.weight(.medium))
                .foregroundStyle(isCurrentTarget ? .primary : .secondary)
                .lineLimit(1)
            Spacer()
            if isDirectory {
                if isCurrentTarget {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Button {
                        state.startTargetScopeSwitch(path: candidate.path)
                    } label: {
                        if isSwitchingCurrent {
                            HStack(spacing: 4) {
                                ProgressView().scaleEffect(0.7)
                                Text(L10n.t(.filesConnectInProgress))
                            }
                        } else {
                            Text(L10n.t(.filesConnect))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(state.targetScopeSwitchStatus.isBusy)
                }
            }
        }
    }

    // MARK: - Status Section
    @ViewBuilder
    private var statusSection: some View {
        let hasProgress = state.targetScopeSwitchProgressText != nil
        let hasError = {
            guard let err = state.targetScopeSwitchErrorText else { return false }
            return !err.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }()

        if hasProgress || hasError {
            Section {
                if let text = state.targetScopeSwitchProgressText {
                    HStack(spacing: 8) {
                        if state.targetScopeSwitchStatus.isBusy {
                            ProgressView().scaleEffect(0.8)
                        }
                        Text(text)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if state.targetScopeSwitchStatus.isBusy {
                            Button {
                                state.cancelTargetScopeSwitch()
                            } label: {
                                Text(L10n.t(.commonCancel))
                                    .font(.footnote)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .tint(.red)
                        }
                    }
                }

                if let err = state.targetScopeSwitchErrorText,
                   !err.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(err)
                            .font(.footnote)
                            .foregroundStyle(.red)
                        if state.targetScopeSwitchStatus == .failed,
                           let path = state.targetScopeSwitchTargetPath {
                            Button {
                                state.startTargetScopeSwitch(path: path)
                            } label: {
                                Label(L10n.t(.scopeSwitchRetry), systemImage: "arrow.clockwise")
                                    .font(.footnote)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
            }
        }
    }

    private func loadingRow(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().scaleEffect(0.8)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
