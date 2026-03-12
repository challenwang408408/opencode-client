//
//  FileContentView.swift
//  OpenCodeClient
//

import SwiftUI
import MarkdownUI
import WebKit
#if canImport(UIKit)
import UIKit
#endif

struct FileContentView: View {
    @Bindable var state: AppState
    let filePath: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var content: String?
    @State private var imageData: Data?
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var showPreview = true
    @State private var loadTask: Task<Void, Never>?
    @State private var htmlPreviewPackage: HTMLPreviewMaterializer.Package?
    private static let imageLoadTimeout: UInt64 = 15_000_000_000 // 15s

    private var previewType: FilePreviewType {
        FilePreviewType.detect(path: filePath)
    }

    private var isImage: Bool {
        previewType == .image
    }

    private var isMarkdown: Bool {
        previewType == .markdown
    }

    private var isHTML: Bool {
        previewType == .html
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
        if isMarkdown || isHTML {
            ToolbarItem(placement: .primaryAction) {
                Button(showPreview ? L10n.t(.fileSource) : L10n.t(.filePreview)) {
                    showPreview.toggle()
                }
            }
        }
        if isHTML, let externalURL = htmlPreviewPackage?.fileURL {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    openURL(externalURL)
                } label: {
                    Image(systemName: "safari")
                }
                .help(L10n.t(.fileOpenExternal))
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
        } else if isHTML {
            if showPreview {
                HTMLPreviewContainerView(
                    state: state,
                    filePath: filePath,
                    html: text,
                    previewPackage: $htmlPreviewPackage
                )
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

struct HTMLPreviewContainerView: View {
    @Bindable var state: AppState
    let filePath: String
    let html: String
    @Binding fileprivate var previewPackage: HTMLPreviewMaterializer.Package?
    @State private var isPreparing = true
    @State private var renderError: String?

    var body: some View {
        ZStack {
            if let previewPackage {
                HTMLWebView(
                    fileURL: previewPackage.fileURL,
                    readAccessURL: previewPackage.readAccessURL,
                    renderError: $renderError
                )
            }

            if let renderError {
                ContentUnavailableView(
                    L10n.t(.fileError),
                    systemImage: "globe.badge.chevron.backward",
                    description: Text(renderError)
                )
                .padding()
            } else if isPreparing || previewPackage == nil {
                ProgressView(L10n.t(.fileRendering))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .task(id: filePath + "|" + html) {
            await preparePreviewFiles()
        }
    }

    @MainActor
    private func preparePreviewFiles() async {
        isPreparing = true
        renderError = nil
        self.previewPackage = nil

        do {
            self.previewPackage = try await HTMLPreviewMaterializer.materialize(
                html: html,
                filePath: filePath,
                state: state
            )
        } catch {
            renderError = error.localizedDescription
        }

        isPreparing = false
    }
}

private enum HTMLPreviewMaterializer {
    struct Package {
        let fileURL: URL
        let readAccessURL: URL
    }

    private static let textExtensions: Set<String> = [
        "css", "htm", "html", "js", "json", "map", "svg", "txt", "xml"
    ]

    static func materialize(html: String, filePath: String, state: AppState) async throws -> Package {
        let fm = FileManager.default
        let rootURL = fm.temporaryDirectory
            .appendingPathComponent("OpenCodeHTMLPreview", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let normalizedDocumentPath = normalizedRelativePath(filePath)
        let htmlURL = rootURL.appendingPathComponent(normalizedDocumentPath)
        try fm.createDirectory(at: htmlURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try html.write(to: htmlURL, atomically: true, encoding: .utf8)

        var visited: Set<String> = [normalizedDocumentPath]
        var pendingTextFiles: [(path: String, content: String)] = [(normalizedDocumentPath, html)]

        while let current = pendingTextFiles.first {
            pendingTextFiles.removeFirst()
            let references = HTMLPreviewResourcePlanner.referencedRelativePaths(in: current.content)

            for reference in references {
                guard let resolvedPath = HTMLPreviewResourcePlanner.resolvedRelativePath(reference: reference, from: current.path),
                      visited.insert(resolvedPath).inserted else {
                    continue
                }

                let destinationURL = rootURL.appendingPathComponent(resolvedPath)
                try fm.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)

                let ext = destinationURL.pathExtension.lowercased()
                if textExtensions.contains(ext) {
                    let content = try await loadTextAsset(path: resolvedPath, state: state)
                    try content.write(to: destinationURL, atomically: true, encoding: .utf8)
                    if ext == "html" || ext == "htm" || ext == "css" {
                        pendingTextFiles.append((resolvedPath, content))
                    }
                } else {
                    let data = try await state.loadBinaryFileData(path: resolvedPath)
                    try data.write(to: destinationURL)
                }
            }
        }

        return Package(fileURL: htmlURL, readAccessURL: rootURL)
    }

    private static func loadTextAsset(path: String, state: AppState) async throws -> String {
        let content = try await state.loadFileContent(path: path)
        if let text = content.text {
            return text
        }
        throw NSError(
            domain: "HTMLPreview",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: L10n.errorMessage(.fileUnsupportedAsset, path)]
        )
    }

    private static func normalizedRelativePath(_ filePath: String) -> String {
        let normalized = PathNormalizer.normalize(filePath)
        return normalized.isEmpty ? "index.html" : normalized
    }
}

private struct HTMLWebView: UIViewRepresentable {
    let fileURL: URL
    let readAccessURL: URL
    @Binding var renderError: String?

    func makeCoordinator() -> Coordinator {
        Coordinator(readAccessURL: readAccessURL, renderError: $renderError)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        context.coordinator.load(fileURL: fileURL, in: webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.load(fileURL: fileURL, in: webView)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let readAccessURL: URL
        @Binding private var renderError: String?
        private var lastFileURL: URL?

        init(readAccessURL: URL, renderError: Binding<String?>) {
            self.readAccessURL = readAccessURL
            _renderError = renderError
        }

        func load(fileURL: URL, in webView: WKWebView) {
            guard lastFileURL != fileURL else { return }
            lastFileURL = fileURL
            renderError = nil
            webView.loadFileURL(fileURL, allowingReadAccessTo: readAccessURL)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            renderError = nil
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            renderError = error.localizedDescription
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            renderError = error.localizedDescription
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
