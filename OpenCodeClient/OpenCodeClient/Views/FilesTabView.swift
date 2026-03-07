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

    private var hasAnyScopeCandidates: Bool {
        !state.desktopScopeCandidates.isEmpty || !state.aiTestScopeCandidates.isEmpty
    }

    private var hasFilteredScopeCandidates: Bool {
        !filteredDesktopScopeCandidates.isEmpty || !filteredAITestScopeCandidates.isEmpty
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
                await state.loadProjects()
                await state.loadScopeSwitchCandidates()
                await state.loadTargetTree()
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

                if state.targetTreeRoot.isEmpty {
                    Text(L10n.t(.fileLoading))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
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
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.8)
                    Text(L10n.t(.filesDetectingEnv))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if state.isLoadingScopeCandidates {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.8)
                    Text(L10n.t(.fileLoading))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if !state.isLoadingScopeCandidates && !state.isDetectingServerEnv {
                desktopCandidateGroup
                aiTestCandidateGroup
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

    // MARK: - Desktop Candidate Group

    @ViewBuilder
    private var desktopCandidateGroup: some View {
        if !filteredDesktopScopeCandidates.isEmpty {
            DisclosureGroup {
                ForEach(filteredDesktopScopeCandidates) { candidate in
                    ScopeCandidateRow(state: state, candidate: candidate)
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

    // MARK: - AI_test Candidate Group

    @ViewBuilder
    private var aiTestCandidateGroup: some View {
        if !filteredAITestScopeCandidates.isEmpty {
            DisclosureGroup {
                ForEach(filteredAITestScopeCandidates) { candidate in
                    ScopeCandidateRow(state: state, candidate: candidate)
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

        if !hasAnyScopeCandidates {
            Text(L10n.t(.filesNoCurrentTarget))
                .foregroundStyle(.secondary)
                .font(.footnote)
        }
    }

    private func filterCandidates(_ candidates: [AppState.ScopeSwitchCandidate]) -> [AppState.ScopeSwitchCandidate] {
        let query = normalizedCandidateSearch
        guard !query.isEmpty else { return candidates }
        return candidates.filter { candidate in
            let haystack = "\(candidate.name) \(candidate.path) \(candidate.type)".lowercased()
            return haystack.contains(query)
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

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "tif", "heic", "heif", "ico"
    ]

    private var fileExtension: String {
        node.name.lowercased().split(separator: ".").last.map(String.init) ?? ""
    }

    private var isMarkdown: Bool {
        fileExtension == "md" || fileExtension == "markdown"
    }

    private var isImage: Bool {
        Self.imageExtensions.contains(fileExtension)
    }

    private var isPreviewable: Bool {
        isMarkdown || isImage
    }

    private var iconName: String {
        if isMarkdown { return "doc.richtext" }
        if isImage { return "photo" }
        return "doc.text"
    }

    private var iconColor: Color {
        if isMarkdown { return .blue }
        if isImage { return .purple }
        return .secondary
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

// MARK: - Scope Candidate Row

private struct ScopeCandidateRow: View {
    @Bindable var state: AppState
    let candidate: AppState.ScopeSwitchCandidate

    private var isDirectory: Bool {
        candidate.type == "directory"
    }

    private var isSwitchingCurrent: Bool {
        state.targetScopeSwitchStatus.isBusy && state.targetScopeSwitchTargetPath == candidate.path
    }

    private var isCurrentTarget: Bool {
        state.serverCurrentProjectWorktree == candidate.path
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isDirectory ? "folder.fill" : "doc.text")
                .foregroundStyle(isCurrentTarget ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(isCurrentTarget ? .primary : .secondary)
                    .lineLimit(1)
            }
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
}
