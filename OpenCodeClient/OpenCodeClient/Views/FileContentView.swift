//
//  FileContentView.swift
//  OpenCodeClient
//

import SwiftUI
import MarkdownUI

struct FileContentView: View {
    @Bindable var state: AppState
    let filePath: String
    @Environment(\.dismiss) private var dismiss
    @State private var content: String?
    @State private var imageData: Data?
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var showPreview = true
    @State private var loadTask: Task<Void, Never>?

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "tif", "heic", "heif", "ico"]
    private static let imageLoadTimeout: UInt64 = 15_000_000_000 // 15s

    private var isImage: Bool {
        let ext = filePath.lowercased().split(separator: ".").last.map(String.init) ?? ""
        return Self.imageExtensions.contains(ext)
    }

    private var isMarkdown: Bool {
        filePath.lowercased().hasSuffix(".md") || filePath.lowercased().hasSuffix(".markdown")
    }

    private var fileName: String {
        filePath.split(separator: "/").last.map(String.init) ?? filePath
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if let content {
            ToolbarItem(placement: .primaryAction) {
                ShareLink(item: content, subject: Text(fileName)) {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
        if let imageData, let uiImage = UIImage(data: imageData) {
            ToolbarItem(placement: .primaryAction) {
                ShareLink(
                    item: Image(uiImage: uiImage),
                    preview: SharePreview(fileName, image: Image(uiImage: uiImage))
                ) {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
        if isMarkdown {
            ToolbarItem(placement: .primaryAction) {
                Button(showPreview ? "Markdown" : "Preview") {
                    showPreview.toggle()
                }
            }
        }
    }

    var body: some View {
        Group {
            if isLoading {
                VStack(spacing: 20) {
                    ProgressView("Loading...")
                    Button(role: .cancel) {
                        loadTask?.cancel()
                        dismiss()
                    } label: {
                        Text("Cancel")
                            .font(.body)
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let err = loadError {
                ContentUnavailableView("Error", systemImage: "exclamationmark.triangle", description: Text(err))
            } else if let data = imageData, let uiImage = UIImage(data: data) {
                ImageView(uiImage: uiImage)
            } else if let text = content {
                contentView(text: text)
            } else {
                ContentUnavailableView("No content", systemImage: "doc.text")
            }
        }
        .navigationTitle(fileName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .onAppear {
            loadContent()
        }
        .onDisappear {
            loadTask?.cancel()
        }
        .refreshable {
            loadContent()
        }
    }

    @ViewBuilder
    private func contentView(text: String) -> some View {
        if isMarkdown {
            if showPreview {
                MarkdownPreviewView(text: text)
            } else {
                RawTextView(text: text, monospaced: true)
            }
        } else {
            CodeView(text: text, path: filePath)
        }
    }

    private func loadContent() {
        loadTask?.cancel()
        isLoading = true
        loadError = nil
        imageData = nil
        content = nil

        let path = filePath
        let wantImage = isImage

        loadTask = Task {
            do {
                if wantImage {
                    try await loadImage(path: path)
                } else {
                    try await loadText(path: path)
                }
            } catch is CancellationError {
                // View disappeared or reload triggered
            } catch let urlError as URLError where urlError.code == .timedOut {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    loadError = "Loading timed out — the image may be too large"
                    isLoading = false
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    loadError = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }

    /// Fast path for images: uses optimized APIClient.imageData() which keeps all
    /// base64/JSON processing on the APIClient actor. Only decoded bytes reach here.
    private func loadImage(path: String) async throws {
        let data: Data = try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                try await state.loadImageData(path: path)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: Self.imageLoadTimeout)
                throw URLError(.timedOut)
            }
            guard let result = try await group.next() else {
                throw URLError(.timedOut)
            }
            group.cancelAll()
            return result
        }

        try Task.checkCancellation()

        await MainActor.run {
            imageData = data
            isLoading = false
        }
    }

    /// Standard path for text/markdown/code files.
    private func loadText(path: String) async throws {
        let fc = try await state.loadFileContent(path: path)

        try Task.checkCancellation()

        if let text = fc.text {
            await MainActor.run {
                content = text
                isLoading = false
            }
        } else if fc.type == "binary" {
            await MainActor.run {
                loadError = "Binary file"
                isLoading = false
            }
        } else {
            await MainActor.run {
                isLoading = false
            }
        }
    }
}

/// Simple code view with line numbers
struct CodeView: View {
    let text: String
    let path: String

    private var lines: [String] {
        text.components(separatedBy: .newlines)
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(i + 1)")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 36, alignment: .trailing)
                            Text(line)
                                .font(.system(.body, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 2)
                    }
                }
                .padding(.vertical, 8)
                .frame(minWidth: 400, alignment: .leading)
            }
        }
    }
}

/// Markdown preview using MarkdownUI library for full GFM rendering.
struct MarkdownPreviewView: View {
    let text: String

    var body: some View {
        ScrollView {
            Markdown(text)
                .textSelection(.enabled)
                .padding()
        }
    }
}

/// Raw text view for Markdown source (wraps to fill available width).
struct RawTextView: View {
    let text: String
    var monospaced: Bool = false

    var body: some View {
        ScrollView {
            Text(text)
                .font(monospaced ? .system(.body, design: .monospaced) : .body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
    }
}

/// Image view with zoom support
struct ImageView: View {
    let uiImage: UIImage
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geometry in
            ScrollView([.horizontal, .vertical]) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(
                        SimultaneousGesture(
                            MagnificationGesture()
                                .onChanged { value in
                                    let newScale = lastScale * value
                                    scale = min(max(newScale, 0.5), 5.0)
                                }
                                .onEnded { _ in
                                    lastScale = scale
                                },
                            DragGesture()
                                .onChanged { value in
                                    offset = CGSize(
                                        width: lastOffset.width + value.translation.width,
                                        height: lastOffset.height + value.translation.height
                                    )
                                }
                                .onEnded { _ in
                                    lastOffset = offset
                                }
                        )
                    )
                    .frame(
                        width: max(uiImage.size.width * scale, geometry.size.width),
                        height: max(uiImage.size.height * scale, geometry.size.height)
                    )
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    withAnimation { scale = 1.0; lastScale = 1.0; offset = .zero; lastOffset = .zero }
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
            }
        }
    }
}
