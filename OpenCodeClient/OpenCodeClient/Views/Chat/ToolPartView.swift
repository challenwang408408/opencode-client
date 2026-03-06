import SwiftUI

struct ToolPartView: View {
    let part: Part
    let sessionTodos: [TodoItem]
    let workspaceDirectory: String?
    let showTechnicalDetails: Bool
    let onOpenResolvedPath: (String) -> Void
    @State private var isExpanded: Bool
    @State private var showOpenFileSheet = false

    init(
        part: Part,
        sessionTodos: [TodoItem],
        workspaceDirectory: String?,
        showTechnicalDetails: Bool,
        onOpenResolvedPath: @escaping (String) -> Void
    ) {
        self.part = part
        self.sessionTodos = sessionTodos
        self.workspaceDirectory = workspaceDirectory
        self.showTechnicalDetails = showTechnicalDetails
        self.onOpenResolvedPath = onOpenResolvedPath
        self._isExpanded = State(initialValue: showTechnicalDetails && part.stateDisplay?.lowercased() == "running")
    }

    private var toolDisplayName: String {
        let raw = part.tool ?? "tool"
        if raw == "apply_patch" { return "patch" }
        return raw
    }

    private var toolAccentColor: Color {
        if part.isPlanningTool { return .green }
        if part.isSkillOrMCPTool { return .orange }
        return .accentColor
    }

    private var toolBackgroundColor: Color {
        toolAccentColor.opacity(0.07)
    }

    private var isCompactProgressCard: Bool {
        !showTechnicalDetails && part.shouldShowInCompactProgress
    }

    private var compactSubtitle: String? {
        let text = part.toolReason ?? part.metadata?.title ?? part.stateDisplay
        return text?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Group {
            if isCompactProgressCard {
                compactProgressBody
            } else {
                DisclosureGroup(isExpanded: $isExpanded) {
                    expandedContent
                } label: {
                    headerRow(showReason: true)
                }
                .onChange(of: part.stateDisplay) { _, newValue in
                    if newValue?.lowercased() == "completed" {
                        isExpanded = false
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(toolBackgroundColor)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(toolAccentColor.opacity(0.14), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .contextMenu {
            if !part.filePathsForNavigation.isEmpty {
                ForEach(part.filePathsForNavigation, id: \.self) { path in
                    Button(L10n.toolOpenFileLabel(path: path)) {
                        openFile(path)
                    }
                }
            }
        }
        .confirmationDialog(L10n.t(.toolOpenFile), isPresented: $showOpenFileSheet) {
            ForEach(part.filePathsForNavigation, id: \.self) { path in
                Button(L10n.toolOpenFileLabel(path: path)) {
                    openFile(path)
                }
            }
            Button(L10n.t(.commonCancel), role: .cancel) {}
        } message: {
            Text(L10n.t(.toolSelectFile))
        }
    }

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let reason = part.toolReason ?? part.metadata?.title, !reason.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.t(.toolReason))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(reason)
                        .font(.caption2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if part.isPlanningTool {
                let todos = part.toolTodos.isEmpty ? sessionTodos : part.toolTodos
                if !todos.isEmpty {
                    TodoListInlineView(todos: todos)
                }
            }
            if !part.isPlanningTool,
               let input = part.toolInputSummary ?? part.metadata?.input,
               !input.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.t(.toolCommandInput))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(input)
                        .font(.system(.caption2, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let path = part.metadata?.path {
                LabeledContent(L10n.t(.toolPath), value: path)
            }
            if !part.isPlanningTool,
               let output = part.toolOutput,
               !output.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.t(.toolOutput))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(output)
                        .font(.system(.caption2, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            fileButtons
        }
        .font(.caption2)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var compactProgressBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            headerRow(showReason: false)
            if let subtitle = compactSubtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(3)
            }
            if part.isPlanningTool {
                let todos = part.toolTodos.isEmpty ? sessionTodos : part.toolTodos
                if !todos.isEmpty {
                    TodoListInlineView(todos: todos)
                }
            }
        }
    }

    @ViewBuilder
    private var fileButtons: some View {
        if !part.filePathsForNavigation.isEmpty {
            ForEach(part.filePathsForNavigation, id: \.self) { path in
                Button {
                    openFile(path)
                } label: {
                    Label(L10n.toolOpenFileLabel(path: path), systemImage: "folder.badge.plus")
                        .font(.caption2)
                }
            }
        }
    }

    private func headerRow(showReason: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: iconName)
                .foregroundStyle(toolAccentColor)
                .font(.caption)
            Text(toolDisplayName)
                .fontWeight(.medium)
                .foregroundStyle(toolAccentColor)
            if showReason, let reason = part.toolReason ?? part.metadata?.title, !reason.isEmpty {
                Text("·")
                    .foregroundStyle(.secondary)
                Text(reason)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
            } else if let status = part.stateDisplay, !status.isEmpty {
                Text(status)
                    .foregroundStyle(.secondary)
            }
            if part.stateDisplay?.lowercased() == "running" {
                ProgressView()
                    .scaleEffect(0.5)
            }
            Spacer()
            if !part.filePathsForNavigation.isEmpty {
                Button {
                    if part.filePathsForNavigation.count == 1 {
                        openFile(part.filePathsForNavigation[0])
                    } else {
                        showOpenFileSheet = true
                    }
                } label: {
                    Image(systemName: "folder.badge.plus")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
            }
        }
        .font(.caption2)
    }

    private var iconName: String {
        if part.isPlanningTool { return "checklist" }
        if part.isSkillOrMCPTool { return "sparkles.rectangle.stack.fill" }
        return "wrench.and.screwdriver.fill"
    }

    private func openFile(_ path: String) {
        let raw = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = PathNormalizer.resolveWorkspaceRelativePath(raw, workspaceDirectory: workspaceDirectory)
        guard !p.isEmpty else { return }
        onOpenResolvedPath(p)
    }
}
