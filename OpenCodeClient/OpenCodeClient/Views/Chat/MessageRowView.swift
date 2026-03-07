//
//  MessageRowView.swift
//  OpenCodeClient
//

import SwiftUI
import MarkdownUI

struct MessageRowView: View {
    let message: MessageWithParts
    let sessionTodos: [TodoItem]
    let workspaceDirectory: String?
    let showTechnicalDetails: Bool
    let onOpenResolvedPath: (String) -> Void
    let onOpenFilesTab: () -> Void
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var textForSelection: String?

    private var cardGridColumnCount: Int { sizeClass == .regular ? 3 : 2 }
    private var cardGridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 10), count: cardGridColumnCount)
    }

    private enum AssistantBlock: Identifiable {
        case text(Part)
        case cards([Part])

        var id: String {
            switch self {
            case .text(let p):
                return "text-\(p.id)"
            case .cards(let parts):
                let first = parts.first?.id ?? "nil"
                let last = parts.last?.id ?? "nil"
                return "cards-\(first)-\(last)"
            }
        }
    }

    struct CompactToolGroup: Identifiable {
        let parts: [Part]

        var id: String {
            let first = parts.first?.id ?? "nil"
            let last = parts.last?.id ?? "nil"
            return "compact-\(first)-\(last)"
        }

        var primaryStatus: String? {
            parts.compactMap { ActivityTracker.formatStatusFromPart($0) }.first
        }

        var runningCount: Int {
            parts.filter { $0.stateDisplay?.lowercased() == "running" }.count
        }
    }

    private var assistantBlocks: [AssistantBlock] {
        var blocks: [AssistantBlock] = []
        var buffer: [Part] = []

        func flushBuffer() {
            guard !buffer.isEmpty else { return }
            blocks.append(.cards(buffer))
            buffer.removeAll(keepingCapacity: true)
        }

        for part in message.parts {
            if part.isReasoning { continue }
            if part.isTool || part.isPatch {
                buffer.append(part)
                continue
            }
            if part.isStepStart || part.isStepFinish { continue }
            if part.isText {
                flushBuffer()
                blocks.append(.text(part))
            } else {
                flushBuffer()
            }
        }

        flushBuffer()
        return blocks
    }

    private func compactToolGroups(from parts: [Part]) -> [CompactToolGroup] {
        guard !showTechnicalDetails else { return [] }
        var groups: [CompactToolGroup] = []
        var buffer: [Part] = []

        func flush() {
            guard !buffer.isEmpty else { return }
            groups.append(CompactToolGroup(parts: buffer))
            buffer.removeAll(keepingCapacity: true)
        }

        for part in parts where part.isTool || part.isPatch {
            if part.shouldShowInCompactProgress {
                flush()
            } else {
                buffer.append(part)
            }
        }

        flush()
        return groups
    }

    private func visibleParts(from parts: [Part]) -> [Part] {
        guard !showTechnicalDetails else { return parts }
        return parts.filter { !$0.isPatch && $0.shouldShowInCompactProgress }
    }

    @ViewBuilder
    private func markdownText(_ text: String) -> some View {
        if shouldRenderMarkdown(text) {
            Markdown(text)
                .textSelection(.enabled)
                .contextMenu {
                    Button {
                        UIPasteboard.general.string = text
                    } label: {
                        Label(L10n.t(.chatCopyText), systemImage: "doc.on.doc")
                    }
                    Button {
                        textForSelection = text
                    } label: {
                        Label(L10n.t(.chatSelectText), systemImage: "text.cursor")
                    }
                }
        } else {
            Text(text)
                .textSelection(.enabled)
                .contextMenu {
                    Button {
                        UIPasteboard.general.string = text
                    } label: {
                        Label(L10n.t(.chatCopyText), systemImage: "doc.on.doc")
                    }
                    Button {
                        textForSelection = text
                    } label: {
                        Label(L10n.t(.chatSelectText), systemImage: "text.cursor")
                    }
                }
        }
    }

    private func shouldRenderMarkdown(_ text: String) -> Bool {
        Self.hasMarkdownSyntax(text)
    }

    static func hasMarkdownSyntax(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let markdownSignals = [
            "```", "`", "**", "__", "#", "- ", "* ", "+ ", "1. ",
            "[", "](", "> ", "|", "~~"
        ]
        if markdownSignals.contains(where: { trimmed.contains($0) }) {
            return true
        }

        return trimmed.contains("\n\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if message.info.isUser {
                Divider()
                    .padding(.vertical, 4)
                userMessageView
            } else {
                assistantMessageView
            }
        }
        .sheet(item: Binding(
            get: { textForSelection.map { TextWrapper(text: $0) } },
            set: { textForSelection = $0?.text }
        )) { wrapper in
            SelectableTextSheet(text: wrapper.text)
        }
    }

    private var userMessageView: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(message.parts.filter { $0.isText }, id: \.id) { part in
                markdownText(part.text ?? "")
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.07))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.accentColor.opacity(0.14), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14))

            if let model = message.info.resolvedModel {
                Text("\(model.providerID)/\(model.modelID)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 4)
            }
        }
    }

    private var assistantMessageView: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(assistantBlocks) { block in
                switch block {
                case .text(let part):
                    markdownText(part.text ?? "")
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .cards(let parts):
                    LazyVGrid(
                        columns: cardGridColumns,
                        alignment: .leading,
                        spacing: 10
                    ) {
                        ForEach(visibleParts(from: parts), id: \.id) { part in
                            cardView(part)
                        }
                        ForEach(compactToolGroups(from: parts)) { group in
                            CompactProgressSummaryCard(group: group)
                        }
                    }
                }
            }
            if let err = message.info.errorMessageForDisplay {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.red.opacity(0.25), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private func cardView(_ part: Part) -> some View {
        if part.isTool {
            ToolPartView(
                part: part,
                sessionTodos: sessionTodos,
                workspaceDirectory: workspaceDirectory,
                showTechnicalDetails: showTechnicalDetails,
                onOpenResolvedPath: onOpenResolvedPath
            )
        } else if part.isPatch {
            PatchPartView(
                part: part,
                workspaceDirectory: workspaceDirectory,
                onOpenResolvedPath: onOpenResolvedPath,
                onOpenFilesTab: onOpenFilesTab
            )
        } else {
            EmptyView()
        }
    }
}

private struct CompactProgressSummaryCard: View {
    let group: MessageRowView.CompactToolGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "ellipsis.rectangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(L10n.t(.chatBackgroundActivity))
                    .font(.caption)
                    .fontWeight(.semibold)
                Spacer()
                if group.runningCount > 0 {
                    ProgressView()
                        .scaleEffect(0.5)
                }
            }

            Text(L10n.t(.chatBackgroundActivitySummary, group.parts.count))
                .font(.caption2)
                .foregroundStyle(.secondary)

            if let primaryStatus = group.primaryStatus {
                Text(primaryStatus)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.secondary.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

private struct TextWrapper: Identifiable {
    let text: String
    var id: String { text }
}

// MARK: - Selectable Text (UITextView wrapper)

private struct SelectableTextView: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.font = .preferredFont(forTextStyle: .body)
        tv.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
        tv.backgroundColor = .clear
        tv.dataDetectorTypes = [.link]
        return tv
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        uiView.text = text
    }
}

struct SelectableTextSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SelectableTextView(text: text)
                .navigationTitle(L10n.t(.chatSelectText))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.t(.appClose)) { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            UIPasteboard.general.string = text
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                    }
                }
        }
    }
}
