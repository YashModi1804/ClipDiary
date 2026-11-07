import Foundation

/// Literal, single-pass substitution. Values are never interpreted as more template text.
public enum SnippetParameters {
    private static let pattern = try! NSRegularExpression(pattern: #"<([\p{L}\p{N}_-]+)>"#)
    public static func names(in text: String) -> [String] {
        let source = text as NSString
        var seen = Set<String>()
        return pattern.matches(in: text, range: NSRange(location: 0, length: source.length)).compactMap {
            let name = source.substring(with: $0.range(at: 1))
            return seen.insert(name).inserted ? name : nil
        }
    }
    public static func render(_ text: String, values: [String: String], maximumBytes: Int = ClipStore.maximumTextBytes) throws -> String {
        let source = text as NSString
        var output = "", position = 0, bytes = 0
        func append(_ value: String) throws {
            let count = value.utf8.count
            guard count <= maximumBytes - bytes else { throw ClipStoreError.limit("Expanded text exceeds the 1 MB item limit.") }
            bytes += count
            output += value
        }
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            try append(source.substring(with: NSRange(location: position, length: match.range.location - position)))
            let name = source.substring(with: match.range(at: 1))
            let value = values[name] ?? ""
            try append(value.isEmpty ? source.substring(with: match.range) : value)
            position = NSMaxRange(match.range)
        }
        try append(source.substring(from: position))
        return output
    }
}
