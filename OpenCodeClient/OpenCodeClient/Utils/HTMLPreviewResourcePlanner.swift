import Foundation

enum HTMLPreviewResourcePlanner {
    private static let attributePattern = #"(?:src|href)\s*=\s*["']([^"']+)["']"#
    private static let cssURLPattern = #"url\(\s*['\"]?([^)'\"]+)['\"]?\s*\)"#

    static func referencedRelativePaths(in text: String) -> [String] {
        var results: [String] = []
        var seen: Set<String> = []

        for raw in matches(in: text, pattern: attributePattern) + matches(in: text, pattern: cssURLPattern) {
            guard let normalized = normalizeReference(raw), seen.insert(normalized).inserted else { continue }
            results.append(normalized)
        }

        return results
    }

    static func resolvedRelativePath(reference: String, from documentPath: String) -> String? {
        let trimmedReference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedReference.isEmpty else { return nil }
        guard !trimmedReference.hasPrefix("/") else { return nil }

        var components = documentPath.split(separator: "/").map(String.init)
        if !components.isEmpty {
            components.removeLast()
        }

        for component in trimmedReference.split(separator: "/").map(String.init) {
            switch component {
            case "", ".":
                continue
            case "..":
                guard !components.isEmpty else { return nil }
                components.removeLast()
            default:
                components.append(component)
            }
        }

        let joined = components.joined(separator: "/")
        return joined.isEmpty ? nil : joined
    }

    private static func normalizeReference(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !trimmed.hasPrefix("#") else { return nil }
        guard !trimmed.hasPrefix("//") else { return nil }

        let lowercased = trimmed.lowercased()
        let blockedSchemes = ["http://", "https://", "data:", "javascript:", "mailto:", "tel:"]
        guard blockedSchemes.allSatisfy({ !lowercased.hasPrefix($0) }) else { return nil }

        let stripped = trimmed
            .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? trimmed
        let noQuery = stripped
            .split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? stripped
        let decoded = noQuery.removingPercentEncoding ?? noQuery
        let cleaned = decoded.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleaned.isEmpty else { return nil }
        return cleaned
    }

    private static func matches(in text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, options: [], range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let captureRange = Range(match.range(at: 1), in: text) else {
                return nil
            }
            return String(text[captureRange])
        }
    }
}
