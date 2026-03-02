//
//  SessionListView.swift
//  OpenCodeClient
//

import SwiftUI

struct SessionListView: View {
    @Bindable var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var pendingDeleteSession: Session?
    @State private var deletingSessionID: String?
    @State private var deleteError: String?
    @State private var showCreateDisabledAlert = false
    @State private var expandedParentIDs: Set<String> = []

    var body: some View {
        NavigationStack {
            Group {
                if state.sessions.isEmpty {
                    ContentUnavailableView(
                        L10n.t(.sessionsEmptyTitle),
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text(L10n.t(.sessionsEmptyDescription))
                    )
                } else {
                    List {
                        ForEach(state.groupedSessions) { group in
                            Section(header: Text(group.title)) {
                                ForEach(group.sessions) { session in
                                    sessionRow(session)
                                    if expandedParentIDs.contains(session.id) {
                                        ForEach(state.childSessions(for: session.id)) { child in
                                            sessionRow(child)
                                                .padding(.leading, 28)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .refreshable {
                        await state.refreshSessions()
                    }
                }
            }
            .navigationTitle(L10n.t(.sessionsTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t(.sessionsClose)) { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: 8) {
                        Button {
                            Task {
                                await state.createSession()
                                dismiss()
                            }
                        } label: {
                            Image(systemName: "plus.circle.fill")
                        }
                        .disabled(!state.canCreateSession)
                        .foregroundColor(state.canCreateSession ? .accentColor : .gray)

                        if !state.canCreateSession {
                            Button {
                                showCreateDisabledAlert = true
                            } label: {
                                Image(systemName: "info.circle")
                            }
                            .foregroundColor(.secondary)
                        }
                    }
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
        .task {
            await state.refreshSessions()
        }
        .alert(L10n.t(.chatCreateDisabledHint), isPresented: $showCreateDisabledAlert) {
            Button(L10n.t(.commonOk)) {}
        }
    }

    @ViewBuilder
    private func sessionRow(_ session: Session) -> some View {
        let children = state.childSessions(for: session.id)
        let hasChildren = !children.isEmpty
        let isExpanded = expandedParentIDs.contains(session.id)

        SessionRowView(
            session: session,
            status: state.sessionStatuses[session.id],
            isSelected: state.currentSessionID == session.id,
            isDeleting: deletingSessionID == session.id,
            childCount: children.count,
            isExpanded: isExpanded,
            isChild: session.parentID != nil && !session.parentID!.isEmpty
        ) {
            selectSession(session)
        } onToggleExpand: {
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

    private func selectSession(_ session: Session) {
        state.selectSession(session)
        dismiss()
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

struct SessionRowView: View {
    let session: Session
    let status: SessionStatus?
    let isSelected: Bool
    let isDeleting: Bool
    var childCount: Int = 0
    var isExpanded: Bool = false
    var isChild: Bool = false
    let onSelect: () -> Void
    var onToggleExpand: (() -> Void)? = nil
    
    private var isBusy: Bool {
        guard let status else { return false }
        return status.type == "busy" || status.type == "retry"
    }

    var body: some View {
        Button(action: onSelect) {
            HStack {
                if isChild {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .frame(width: 12)
                }

                if isChild {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(session.title.isEmpty ? L10n.t(.sessionsUntitled) : session.title)
                            .font(.caption)
                            .lineLimit(1)
                            .foregroundStyle(isBusy ? .blue : .primary)

                        Text(formattedDate(session.time.updated))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(session.title.isEmpty ? L10n.t(.sessionsUntitled) : session.title)
                                .font(.headline)
                                .foregroundStyle(isBusy ? .blue : .primary)

                            if childCount > 0 {
                                Text("\(childCount)")
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(Color.secondary.opacity(0.5)))
                            }
                        }

                        HStack(spacing: 8) {
                            Text(formattedDate(session.time.updated))
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            if let status {
                                Text(statusLabel(status))
                                    .font(.caption)
                                    .foregroundStyle(statusColor(status))
                            }
                        }
                    }
                }

                Spacer()

                if isDeleting {
                    ProgressView()
                        .controlSize(.small)
                } else if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.secondary)
                }

                if childCount > 0 {
                    Button {
                        onToggleExpand?()
                    } label: {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, isChild ? 0 : 4)
        }
        .disabled(isDeleting)
        .buttonStyle(.plain)
        .listRowBackground(isSelected ? Color.blue.opacity(0.08) : Color.clear)
    }

    private func formattedDate(_ timestamp: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.locale = Locale.current
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func statusLabel(_ status: SessionStatus) -> String {
        switch status.type {
        case "busy": return L10n.t(.sessionsStatusBusy)
        case "retry": return L10n.t(.sessionsStatusRetry)
        default: return L10n.t(.sessionsStatusIdle)
        }
    }

    private func statusColor(_ status: SessionStatus) -> Color {
        switch status.type {
        case "busy", "retry": return .blue
        default: return .secondary
        }
    }
}
