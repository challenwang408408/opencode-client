//
//  SplitSidebarView.swift
//  OpenCodeClient
//

import SwiftUI

/// iPad / Vision Pro split layout sidebar:
/// - Top: File tree
/// - Bottom: Sessions list (selecting switches the chat on the right)
struct SplitSidebarView: View {
    @Bindable var state: AppState

    private let minPaneHeight: CGFloat = 220
    private let dividerHeight: CGFloat = 1

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let available = max(0, geo.size.height - dividerHeight)
                let half = max(minPaneHeight, available / 2)
                let filesHeight = half
                let sessionsHeight = max(minPaneHeight, available - half)

                VStack(spacing: 0) {
                    FileTreeView(state: state, forceSplitPreview: true)
                        .searchable(text: $state.fileSearchQuery, prompt: L10n.t(.appSearchFiles))
                        .onSubmit(of: .search) {
                            Task { await state.searchFiles(query: state.fileSearchQuery) }
                        }
                        .onChange(of: state.fileSearchQuery) { _, newValue in
                            if newValue.isEmpty {
                                state.fileSearchResults = []
                            } else {
                                Task {
                                    try? await Task.sleep(for: .milliseconds(300))
                                    guard !Task.isCancelled else { return }
                                    await state.searchFiles(query: newValue)
                                }
                            }
                        }
                        .frame(height: filesHeight)
                        .refreshable {
                            await state.loadFileTree()
                            await state.loadFileStatus()
                        }

                    Divider()
                        .frame(height: dividerHeight)

                    SessionsSidebarList(state: state)
                        .frame(height: sessionsHeight)
                }
            }
            .navigationTitle(L10n.t(.navWorkspace))
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct SessionsSidebarList: View {
    @Bindable var state: AppState
    @State private var pendingDeleteSession: Session?
    @State private var deletingSessionID: String?
    @State private var deleteError: String?
    @State private var expandedParentIDs: Set<String> = []
    @State private var sessionSearchText = ""

    private var normalizedSessionSearch: String {
        sessionSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var isSearchingSessions: Bool {
        !normalizedSessionSearch.isEmpty
    }

    private var filteredSessionGroups: [AppState.SessionGroup] {
        guard isSearchingSessions else { return state.groupedSessions }
        return state.groupedSessions.compactMap { group in
            let sessions = group.sessions.filter { session in
                matchesSessionSearch(session) || !matchingChildren(for: session).isEmpty
            }
            guard !sessions.isEmpty else { return nil }
            return AppState.SessionGroup(id: group.id, title: group.title, sessions: sessions)
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            InlineSearchField(
                prompt: L10n.t(.sessionsSearchPlaceholder),
                text: $sessionSearchText
            )
            .padding(.horizontal, 8)

            if filteredSessionGroups.isEmpty {
                ContentUnavailableView(
                    L10n.t(.sessionsSearchEmptyTitle),
                    systemImage: "magnifyingglass",
                    description: Text(L10n.t(.sessionsSearchEmptyDescription))
                )
            } else {
                List {
                    ForEach(filteredSessionGroups) { group in
                        Section(header: Text(group.title)) {
                            ForEach(group.sessions) { session in
                                sessionRow(session)
                                ForEach(visibleChildren(for: session)) { child in
                                    sessionRow(child)
                                        .padding(.leading, 28)
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .tint(.secondary)
                .refreshable {
                    await state.refreshSessions()
                }
            }
        }
        .alert(
            L10n.t(.sessionsDeleteConfirmTitle),
            isPresented: Binding(
                get: { pendingDeleteSession != nil },
                set: { if !$0 { pendingDeleteSession = nil } }
            ),
            presenting: pendingDeleteSession
        ) { session in
            Button(L10n.t(.commonCancel), role: .cancel) {}
            Button(L10n.t(.sessionsDelete), role: .destructive) {
                confirmDelete(session)
            }
        } message: { session in
            Text(L10n.t(.sessionsDeleteConfirmMessage))
        }
        .alert(
            L10n.t(.sessionsDeleteFailedTitle),
            isPresented: Binding(
                get: { deleteError != nil },
                set: { if !$0 { deleteError = nil } }
            )
        ) {
            Button(L10n.t(.commonOk)) {
                deleteError = nil
            }
        } message: {
            if let deleteError {
                Text(deleteError)
            }
        }
    }

    @ViewBuilder
    private func sessionRow(_ session: Session) -> some View {
        let children = visibleChildren(for: session)
        let hasChildren = !children.isEmpty
        let isExpanded = isSearchingSessions ? hasChildren : expandedParentIDs.contains(session.id)

        SessionRowView(
            session: session,
            status: state.sessionStatuses[session.id],
            isSelected: state.currentSessionID == session.id,
            isDeleting: deletingSessionID == session.id,
            childCount: children.count,
            isExpanded: isExpanded,
            isChild: session.parentID != nil && !session.parentID!.isEmpty,
            searchQuery: normalizedSessionSearch
        ) {
            state.selectSession(session)
        } onToggleExpand: {
            guard !isSearchingSessions else { return }
            if hasChildren {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if isExpanded {
                        expandedParentIDs.remove(session.id)
                    } else {
                        expandedParentIDs.insert(session.id)
                    }
                }
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                pendingDeleteSession = session
            } label: {
                Label(L10n.t(.sessionsDelete), systemImage: "trash")
            }
            .tint(.red)
            .disabled(deletingSessionID != nil)
        }
    }

    private func visibleChildren(for session: Session) -> [Session] {
        let children = state.childSessions(for: session.id)
        guard isSearchingSessions else {
            return expandedParentIDs.contains(session.id) ? children : []
        }
        return matchingChildren(for: session)
    }

    private func matchingChildren(for session: Session) -> [Session] {
        state.childSessions(for: session.id).filter(matchesSessionSearch)
    }

    private func matchesSessionSearch(_ session: Session) -> Bool {
        let query = normalizedSessionSearch
        guard !query.isEmpty else { return true }
        let title = session.title.isEmpty ? L10n.t(.sessionsUntitled) : session.title
        let text = "\(title) \(session.directory) \(session.slug)".lowercased()
        return text.contains(query)
    }

    private func confirmDelete(_ session: Session) {
        guard deletingSessionID == nil else { return }
        deletingSessionID = session.id
        Task {
            do {
                try await state.deleteSession(sessionID: session.id)
            } catch {
                deleteError = error.localizedDescription
            }
            deletingSessionID = nil
        }
    }
}
