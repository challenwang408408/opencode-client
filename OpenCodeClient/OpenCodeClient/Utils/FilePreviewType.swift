import Foundation

enum FilePreviewType: Equatable {
    case image
    case markdown
    case html
    case text

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "tif", "heic", "heif", "ico"
    ]

    static func detect(path: String) -> FilePreviewType {
        let ext = path.lowercased().split(separator: ".").last.map(String.init) ?? ""
        if imageExtensions.contains(ext) {
            return .image
        }
        if ext == "md" || ext == "markdown" {
            return .markdown
        }
        if ext == "html" || ext == "htm" {
            return .html
        }
        return .text
    }

    var isPreviewable: Bool {
        switch self {
        case .image, .markdown, .html:
            return true
        case .text:
            return false
        }
    }
}
