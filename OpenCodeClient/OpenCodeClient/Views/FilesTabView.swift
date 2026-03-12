//
//  FilesTabView.swift
//  OpenCodeClient
//

import SwiftUI

struct FilesTabView: View {
    @Bindable var state: AppState
    @State private var isLoadingTargetChildren: Set<String> = []
    @State private var candidateSearchText = ""

    private var normalizedCandidateSearch: String {
        candidateSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var filteredDesktopScopeCandidates: [AppState.ScopeSwitchCandidate] {
        filterCandidates(state.desktopScopeCandidates)
    }

    private var filteredAITestScopeCandidates: [AppState.ScopeSwitchCandidate] {
        filterCandidates(state.aiTestScopeCandidates)
    }

    private var filteredObsidianScopeCandidates: [AppState.ScopeSwitchCandidate] {
        filterCandidates(state.obsidianScopeCandidates)
    }

    private var hasAnyScopeCandidates: Bool {
        !state.desktopScopeCandidates.isEmpty || !state.aiTestScopeCandidates.isEmpty || !state.obsidianScopeCandidates.isEmpty
    }

    private var hasFilteredScopeCandidates: Bool {
        !filteredDesktopScopeCandidates.isEmpty || !filteredAITestScopeCandidates.isEmpty || !filteredObsidianScopeCandidates.isEmpty
    }

    private var targetEntryCount: Int {
        countNodes(state.targetTreeRoot)
    }

    private var candidateCount: Int {
        state.desktopScopeCandidates.count + state.aiTestScopeCandidates.count + state.obsidianScopeCandidates.count
    }

    private var targetStatusText: String? {
        if state.isLoadingTargetTree {
            return L10n.t(.filesLoadingTargetStatus, targetEntryCount)
        }
        guard targetEntryCount > 0 else { return nil }
        let age = relativeTimeString(from: state.targetTreeLastLoadedAt)
        return L10n.t(.filesTargetLoadedStatus, targetEntryCount, age)
    }

    private var candidateStatusText: String? {
        if state.isLoadingScopeCandidates || state.isDetectingServerEnv {
            return L10n.t(.filesLoadingCandidateStatus, candidateCount)
        }
        guard candidateCount > 0 else { return nil }
        return L10n.t(.filesCandidateLoadedStatus, candidateCount)
    }

    var body: some View {
        NavigationStack {
            List {
                targetSection
                connectionHistorySection
                candidateSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle(L10n.t(.navFiles))
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: String.self) { path in
                FileContentView(state: state, filePath: path)
            }
            .task {
                guard state.isConnected else { return }
                if state.projects.isEmpty && state.serverCurrentProjectWorktree == nil {
                    await state.loadProjects()
                }
                if hasAnyScopeCandidates == false && !state.isLoadingScopeCandidates {
                    await state.loadScopeSwitchCandidates()
                }
                if state.targetTreeRoot.isEmpty && !state.isLoadingTargetTree {
                    await state.loadTargetTree()
                }
            }
            .refreshable {
                await state.refresh()
                await state.loadScopeSwitchCandidates()
                await state.loadTargetTree()
            }
        }
    }

    // MARK: - Section 1: Current Target (expandable file tree)

    private var targetSection: some View {
        Section(L10n.t(.filesCurrentTargetsTitle)) {
            if state.targetScopeSwitchStatus == .connected,
               let target = state.targetScopeSwitchTargetPath,
               !target.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(L10n.t(.scopeSwitchStatusConnected))
                        .font(.footnote)
                        .foregroundStyle(.green)
                }
            }

            if let serverPath = state.serverCurrentProjectWorktree,
               !serverPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.t(.filesCurrentServerTarget))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(serverPath)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(2)
                }

                if let targetStatusText {
                    HStack(spacing: 8) {
                        Text(targetStatusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(L10n.t(.commonRefresh)) {
                            Task { await state.loadTargetTree() }
                        }
                        .font(.caption)
                    }
                }

                if state.isLoadingTargetTree && state.targetTreeRoot.isEmpty {
                    loadingPlaceholderBlock(title: L10n.t(.fileLoading), rowCount: 6)
                } else if let errorText = state.targetTreeErrorText,
                          !errorText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(errorText)
                            .font(.footnote)
                            .foregroundStyle(.red)
                        Button {
                            Task { await state.loadTargetTree() }
                        } label: {
                            Label(L10n.t(.scopeSwitchRetry), systemImage: "arrow.clockwise")
                                .font(.footnote)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                } else if state.targetTreeRoot.isEmpty {
                    Text(L10n.t(.appNoContent))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    if state.isLoadingTargetTree {
                        loadingInlineBanner(title: L10n.t(.fileLoading))
                    }
                    ForEach(targetVisibleNodes, id: \.path) { item in
                        if item.node.type == "directory" {
                            TargetDirectoryRow(
                                state: state,
                                node: item.node,
                                indent: item.indent,
                                isLoading: isLoadingTargetChildren.contains(item.node.path)
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                Task { await loadAndExpandTarget(item.node.path) }
                            }
                        } else {
                            NavigationLink(value: item.node.path) {
                                TargetFileRow(node: item.node, indent: item.indent)
                            }
                        }
                    }
                }
            } else {
                Text(L10n.t(.filesNoCurrentTarget))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var targetVisibleNodes: [TreeNodeItem] {
        func flatten(_ nodes: [FileNode], indent: Int) -> [TreeNodeItem] {
            var result: [TreeNodeItem] = []
            for node in nodes {
                result.append(TreeNodeItem(node: node, indent: indent))
                if node.type == "directory", state.isTargetExpanded(node.path),
                   let children = state.cachedTargetChildren(for: node.path) {
                    result.append(contentsOf: flatten(children, indent: indent + 1))
                }
            }
            return result
        }
        return flatten(state.targetTreeRoot, indent: 0)
    }

    private func loadAndExpandTarget(_ path: String) async {
        guard !isLoadingTargetChildren.contains(path) else { return }
        isLoadingTargetChildren.insert(path)
        state.toggleTargetExpanded(path)
        if state.cachedTargetChildren(for: path) == nil {
            _ = await state.loadTargetChildren(path: path)
        }
        isLoadingTargetChildren.remove(path)
    }

    // MARK: - Connection History (quick switch)

    @ViewBuilder
    private var connectionHistorySection: some View {
        let history = state.connectionHistoryForDisplay
        if !history.isEmpty {
            Section(L10n.t(.filesConnectionHistory)) {
                ForEach(history, id: \.self) { path in
                    ConnectionHistoryRow(state: state, path: path)
                }
            }
        }
    }

    // MARK: - Section 2: Candidate Projects

    private var candidateSection: some View {
        Section(L10n.t(.filesCandidateTitle)) {
            InlineSearchField(
                prompt: L10n.t(.filesSearchCandidatesPlaceholder),
                text: $candidateSearchText
            )

            if state.isDetectingServerEnv {
                loadingInlineBanner(title: L10n.t(.filesDetectingEnv))
            }

            if let candidateStatusText {
                HStack(spacing: 8) {
                    Text(candidateStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n.t(.commonRefresh)) {
                        Task { await state.loadScopeSwitchCandidates() }
                    }
                    .font(.caption)
                    .disabled(state.isLoadingScopeCandidates || state.isDetectingServerEnv)
                }
            }

            if state.isLoadingScopeCandidates {
                loadingPlaceholderBlock(title: L10n.t(.fileLoading), rowCount: 5)
            }

            if !state.isLoadingScopeCandidates && !state.isDetectingServerEnv {
                ScopeCandidateSectionsView(
                    state: state,
                    desktopCandidates: filteredDesktopScopeCandidates,
                    aiTestCandidates: filteredAITestScopeCandidates,
                    obsidianCandidates: filteredObsidianScopeCandidates,
                    showEmptyState: !hasAnyScopeCandidates
                )
                if hasAnyScopeCandidates && !hasFilteredScopeCandidates {
                    Text(L10n.t(.filesSearchCandidatesEmpty))
                        .foregroundStyle(.secondary)
                        .font(.footnote)
                }
            }

            if let text = state.targetScopeSwitchProgressText {
                HStack(spacing: 8) {
                    if state.targetScopeSwitchStatus.isBusy {
                        ProgressView()
                            .scaleEffect(0.8)
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
        .listRowBackground(Color.secondary.opacity(0.08))
    }

    private func filterCandidates(_ candidates: [AppState.ScopeSwitchCandidate]) -> [AppState.ScopeSwitchCandidate] {
        let query = normalizedCandidateSearch
        guard !query.isEmpty else { return candidates }
        return candidates.filter { candidate in
            let haystack = "\(candidate.name) \(candidate.path) \(candidate.type)".lowercased()
            return haystack.contains(query)
        }
    }

    private func countNodes(_ nodes: [FileNode]) -> Int {
        nodes.reduce(into: 0) { partial, node in
            partial += 1
            if let children = state.cachedTargetChildren(for: node.path) {
                partial += countNodes(children)
            }
        }
    }

    private func relativeTimeString(from date: Date?) -> String {
        guard let date else { return L10n.t(.filesUpdatedNow) }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    @ViewBuilder
    private func loadingInlineBanner(title: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().scaleEffect(0.8)
            Text(title)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func loadingPlaceholderBlock(title: String, rowCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            loadingInlineBanner(title: title)
            ForEach(0..<rowCount, id: \.self) { index in
                FileSkeletonRow(indent: index == 0 ? 0 : min(index, 2))
            }
        }
        .padding(.vertical, 4)
    }

}

private struct FileSkeletonRow: View {
    let indent: Int
    @State private var phase: CGFloat = -0.8

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.secondary.opacity(0.12))
                .frame(width: 12, height: 12)
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.secondary.opacity(0.12))
                .frame(width: 16, height: 16)
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.secondary.opacity(0.12))
                .frame(maxWidth: .infinity)
                .frame(height: 14)
        }
        .padding(.leading, CGFloat(indent * 16))
        .overlay {
            GeometryReader { geometry in
                let width = geometry.size.width
                LinearGradient(
                    colors: [
                        .clear,
                        Color.white.opacity(0.35),
                        .clear,
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: max(40, width * 0.45))
                .offset(x: width * phase)
                .blendMode(.plusLighter)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .onAppear {
            withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                phase = 1.2
            }
        }
    }
}

// MARK: - Target Tree Row Views

private struct TargetDirectoryRow: View {
    @Bindable var state: AppState
    let node: FileNode
    let indent: Int
    let isLoading: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: state.isTargetExpanded(node.path) ? "chevron.down" : "chevron.right")
                .font(.caption2)
                .frame(width: 12)
            if isLoading {
                ProgressView().scaleEffect(0.7)
            }
            Image(systemName: "folder.fill")
                .foregroundStyle(.yellow)
            Text(node.name)
                .lineLimit(1)
            Spacer()
        }
        .padding(.leading, CGFloat(indent * 16))
    }
}

private struct TargetFileRow: View {
    let node: FileNode
    let indent: Int

    private var previewType: FilePreviewType {
        FilePreviewType.detect(path: node.name)
    }

    private var isPreviewable: Bool {
        previewType.isPreviewable
    }

    private var iconName: String {
        switch previewType {
        case .markdown:
            return "doc.richtext"
        case .image:
            return "photo"
        case .html:
            return "globe"
        case .text:
            return "doc.text"
        }
    }

    private var iconColor: Color {
        switch previewType {
        case .markdown:
            return .blue
        case .image:
            return .purple
        case .html:
            return .teal
        case .text:
            return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.caption2)
                .opacity(0)
                .frame(width: 12)
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
            Text(node.name)
                .lineLimit(1)
                .foregroundStyle(isPreviewable ? .primary : .secondary)
            Spacer()
        }
        .padding(.leading, CGFloat(indent * 16))
    }
}

// MARK: - Connection History Row

private struct ConnectionHistoryRow: View {
    @Bindable var state: AppState
    let path: String

    private var folderName: String {
        (path as NSString).lastPathComponent
    }

    private var isSwitching: Bool {
        state.targetScopeSwitchStatus.isBusy && state.targetScopeSwitchTargetPath == path
    }

    var body: some View {
        HStack(spacing: 10) {
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
}
