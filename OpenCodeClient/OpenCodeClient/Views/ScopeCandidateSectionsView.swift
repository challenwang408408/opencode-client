import SwiftUI

struct ScopeCandidateSectionsView: View {
    @Bindable var state: AppState
    let desktopCandidates: [AppState.ScopeSwitchCandidate]
    let aiTestCandidates: [AppState.ScopeSwitchCandidate]
    let obsidianCandidates: [AppState.ScopeSwitchCandidate]
    var showEmptyState: Bool = true

    private var hasCandidates: Bool {
        !desktopCandidates.isEmpty || !aiTestCandidates.isEmpty || !obsidianCandidates.isEmpty
    }

    var body: some View {
        Group {
            ScopeCandidateGroupView(
                title: L10n.t(.filesDesktopGroup),
                iconName: "desktopcomputer",
                iconColor: .blue,
                candidates: desktopCandidates,
                state: state
            )
            ScopeCandidateGroupView(
                title: L10n.t(.filesAITestGroup),
                iconName: "folder.fill.badge.gearshape",
                iconColor: .orange,
                candidates: aiTestCandidates,
                state: state
            )
            ScopeCandidateGroupView(
                title: L10n.t(.filesObsidianGroup),
                iconName: "book.closed.fill",
                iconColor: .purple,
                candidates: obsidianCandidates,
                state: state
            )

            if showEmptyState && !hasCandidates {
                Text(L10n.t(.filesNoCurrentTarget))
                    .foregroundStyle(.secondary)
                    .font(.footnote)
            }
        }
    }
}

private struct ScopeCandidateGroupView: View {
    let title: String
    let iconName: String
    let iconColor: Color
    let candidates: [AppState.ScopeSwitchCandidate]
    @Bindable var state: AppState

    var body: some View {
        if !candidates.isEmpty {
            DisclosureGroup {
                ForEach(candidates) { candidate in
                    ScopeCandidateActionRow(state: state, candidate: candidate)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: iconName)
                        .foregroundStyle(iconColor)
                    Text(title)
                        .font(.body.weight(.medium))
                }
            }
        }
    }
}

struct ScopeCandidateActionRow: View {
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
}
