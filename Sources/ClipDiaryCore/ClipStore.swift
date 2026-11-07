import Foundation
import SQLite3
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
import Darwin

public enum ClipKind: String, Codable, CaseIterable { case text, image }
public struct ClipRecord: Identifiable, Codable, Equatable {
    public let id: String
    public let kind: ClipKind
    public let text: String?
    public let title: String
    public let capturedAt: Date
    public let expiresAt: Date?
    public let source: String
    public let isSnippet: Bool
    public let assetPath: String?
    public let thumbnailPath: String?
    public let byteCount: Int
    public let isParameterized: Bool
}
public enum ClipStoreError: Error, LocalizedError {
    case database(String), invalidImage, limit(String), missingRecord, invalidSnippet
    public var errorDescription: String? {
        switch self {
        case .database(let message): return "Local storage: \(message)"
        case .invalidImage: return "This image is damaged or unsupported."
        case .limit(let message): return message
        case .missingRecord: return "This item is no longer available."
        case .invalidSnippet: return "A snippet needs a title and content."
        }
    }
}

/// Use from one thread. Stores all data locally; no network operations.
public final class ClipStore {
    public static let retention: TimeInterval = 96 * 3600
    public static let maximumImageBytes = 25 * 1024 * 1024
    public static let maximumPixels = 50_000_000
    public static let maximumTextBytes = 1024 * 1024
    public static let maximumStorageBytes = 512 * 1024 * 1024
    private var db: OpaquePointer?
    public let directory: URL
    private let assets: URL
    private let thumbnails: URL
    private let fm = FileManager.default
    private var pendingAssetRemovals = Set<String>()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(directory: URL) throws {
        let canonical = directory.standardizedFileURL.resolvingSymlinksInPath()
        self.directory = canonical
        assets = canonical.appendingPathComponent("Assets", isDirectory: true)
        thumbnails = canonical.appendingPathComponent("Thumbnails", isDirectory: true)
        for url in [canonical, assets, thumbnails] {
            try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let file = canonical.appendingPathComponent("history.sqlite3")
        // Refuse a linked database file: migration/cleanup must never mutate an unrelated store.
        // SQLite NOFOLLOW also rejects aliased parent paths; resolve the owned directory
        // physically first while retaining protection against a linked database leaf.
        guard let physicalRoot = realpath(canonical.path, nil) else { throw ClipStoreError.database("Cannot resolve local storage directory") }
        let physicalFile = String(cString: physicalRoot) + "/history.sqlite3"
        free(physicalRoot)
        let opened = sqlite3_open_v2(physicalFile, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOFOLLOW, nil)
        guard opened == SQLITE_OK else {
            let message = error()
            sqlite3_close(db); db = nil
            throw message
        }
        do {
            sqlite3_busy_timeout(db, 3000)
            try registerTextFunctions()
            let versionStatement = try statement("PRAGMA user_version", [])
            let versionStep = sqlite3_step(versionStatement)
            let version = sqlite3_column_int(versionStatement, 0)
            sqlite3_finalize(versionStatement)
            guard versionStep == SQLITE_ROW, version <= 2 else { throw ClipStoreError.database("This history was created by a newer version of ClipDiary.") }
            var root = canonical
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try root.setResourceValues(values)
            try execute("PRAGMA journal_mode=DELETE")
            try execute("PRAGMA synchronous=FULL")
            try execute("PRAGMA secure_delete=ON")
            try execute("CREATE TABLE IF NOT EXISTS clips (id TEXT PRIMARY KEY, kind TEXT NOT NULL, text TEXT, title TEXT NOT NULL, captured REAL NOT NULL, expires REAL, source TEXT NOT NULL, snippet INTEGER NOT NULL DEFAULT 0, asset TEXT, thumbnail TEXT, bytes INTEGER NOT NULL, digest TEXT)")
            try execute("CREATE INDEX IF NOT EXISTS clips_expiry ON clips(expires)")
            try execute("CREATE INDEX IF NOT EXISTS clips_collection_capture ON clips(snippet,captured)")
            if version < 2 {
                try execute("BEGIN IMMEDIATE")
                do {
                    try execute("ALTER TABLE clips ADD COLUMN parameterized INTEGER NOT NULL DEFAULT 0")
                    try execute("PRAGMA user_version=2")
                    try execute("COMMIT")
                } catch { try? execute("ROLLBACK"); throw error }
            }
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            try purge()
            try reconcileAssets()
        } catch {
            sqlite3_close(db); db = nil; throw error
        }
    }
    deinit { sqlite3_close(db) }

    public func records(query: String = "", snippets: Bool = false, kind: ClipKind? = nil, now: Date = Date(), textPreviewLimit: Int? = nil) throws -> [ClipRecord] {
        // Expired items never appear, even when cleanup has not run yet.
        let projectedText = textPreviewLimit == nil ? "text" : "clip_preview(text,?)"
        let projectedTitle = textPreviewLimit == nil ? "title" : "clip_preview(title,?)"
        let projectedSource = textPreviewLimit == nil ? "source" : "clip_preview(source,?)"
        var sql = "SELECT id,kind,\(projectedText),\(projectedTitle),captured,expires,\(projectedSource),snippet,asset,thumbnail,bytes,parameterized FROM clips WHERE snippet=? AND (expires IS NULL OR expires>?)"
        var args: [Any?] = textPreviewLimit.map { [max(0, $0), max(0, $0), max(0, $0)] } ?? []
        args += [snippets ? 1 : 0, now.timeIntervalSince1970]
        if let kind { sql += " AND kind=?"; args.append(kind.rawValue) }
        if !query.isEmpty {
            sql += " AND (clip_contains(title,?) OR clip_contains(text,?) OR clip_contains(source,?))"
            args += [query, query, query]
        }
        sql += " ORDER BY captured DESC, rowid DESC"
        return try fetch(sql, args)
    }

    /// Resolves one current item without materializing the complete collection.
    public func record(id: String, now: Date = Date()) throws -> ClipRecord? {
        try fetch("SELECT id,kind,text,title,captured,expires,source,snippet,asset,thumbnail,bytes,parameterized FROM clips WHERE id=? AND (expires IS NULL OR expires>?)", [id, now.timeIntervalSince1970]).first
    }

    @discardableResult public func addText(_ text: String, source: String, now: Date = Date()) throws -> ClipRecord? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        try purge(now: now)
        let count = text.utf8.count
        guard count <= Self.maximumTextBytes else { throw ClipStoreError.limit("Text exceeds the 1 MB item limit.") }
        let digest = hash(Data(text.utf8))
        if let recent = try duplicate(digest: digest, kind: .text, now: now) { return recent }
        let title = firstLineTitle(text)
        try validateMetadata(title: title, source: source)
        try capacity(count + metadataBytes(title: title, source: source))
        let record = ClipRecord(id: UUID().uuidString, kind: .text, text: text, title: title, capturedAt: now, expiresAt: now.addingTimeInterval(Self.retention), source: source, isSnippet: false, assetPath: nil, thumbnailPath: nil, byteCount: count, isParameterized: false)
        try insert(record, digest: digest)
        return record
    }

    @discardableResult public func addImage(data: Data, title: String, source: String, now: Date = Date(), deduplicate: Bool = true) throws -> ClipRecord? {
        try validateMetadata(title: title, source: source)
        try purge(now: now)
        guard data.count <= Self.maximumImageBytes else { throw ClipStoreError.limit("Image exceeds the 25 MB item limit.") }
        let digest = hash(data)
        if deduplicate, let recent = try duplicate(digest: digest, kind: .image, now: now) { return recent }
        guard let image = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(image) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.int64Value > 0, height.int64Value > 0,
              width.int64Value <= Int64(Self.maximumPixels) / height.int64Value else { throw ClipStoreError.invalidImage }
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(image, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 320, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { throw ClipStoreError.invalidImage }
        let thumbData = NSMutableData()
        guard let output = CGImageDestinationCreateWithData(thumbData, UTType.png.identifier as CFString, 1, nil) else { throw ClipStoreError.invalidImage }
        CGImageDestinationAddImage(output, thumbnail, nil)
        guard CGImageDestinationFinalize(output) else { throw ClipStoreError.invalidImage }
        let bytes = data.count + thumbData.length
        try capacity(bytes + metadataBytes(title: title, source: source))
        let id = UUID().uuidString
        let ext = (CGImageSourceGetType(image).flatMap { UTType($0 as String)?.preferredFilenameExtension }) ?? "image"
        let asset = assets.appendingPathComponent(id).appendingPathExtension(ext)
        let thumb = thumbnails.appendingPathComponent(id).appendingPathExtension("png")
        do {
            try writePrivate(data, to: asset)
            try writePrivate(thumbData as Data, to: thumb)
            let record = ClipRecord(id: id, kind: .image, text: nil, title: title, capturedAt: now, expiresAt: now.addingTimeInterval(Self.retention), source: source, isSnippet: false, assetPath: asset.path, thumbnailPath: thumb.path, byteCount: bytes, isParameterized: false)
            try insert(record, digest: digest)
            return record
        } catch {
            try? fm.removeItem(at: asset); try? fm.removeItem(at: thumb); throw error
        }
    }

    /// Explicitly copying history moves that same record to now without changing provenance.
    /// Copying a snippet creates an independent expiring history record.
    @discardableResult public func recopy(id: String, now: Date = Date(), parameterValues: [String: String] = [:]) throws -> ClipRecord {
        guard let item = try record(id: id, now: now) else { throw ClipStoreError.missingRecord }
        if item.isSnippet {
            try purge(now: now)
            if item.isParameterized, item.kind == .text {
                let text = try SnippetParameters.render(item.text ?? "", values: parameterValues)
                guard text.utf8.count <= Self.maximumTextBytes else { throw ClipStoreError.limit("Text exceeds the 1 MB item limit.") }
                try validateMetadata(title: item.title, source: item.source)
                try capacity(text.utf8.count + metadataBytes(title: item.title, source: item.source))
                let copy = ClipRecord(id: UUID().uuidString, kind: .text, text: text, title: item.title, capturedAt: now, expiresAt: now.addingTimeInterval(Self.retention), source: item.source, isSnippet: false, assetPath: nil, thumbnailPath: nil, byteCount: text.utf8.count, isParameterized: false)
                try insert(copy, digest: nil)
                return copy
            }
            return try independentCopy(item, title: item.title, capturedAt: now, snippet: false)
        }
        if item.kind == .image {
            guard let path = item.assetPath, fm.fileExists(atPath: path) else { throw ClipStoreError.missingRecord }
        }
        // Advance the internal sort tiebreaker too; the public ID and owned assets remain stable.
        try execute("UPDATE clips SET rowid=(SELECT COALESCE(MAX(rowid),0)+1 FROM clips),captured=?,expires=? WHERE id=?", [now.timeIntervalSince1970, now.addingTimeInterval(Self.retention).timeIntervalSince1970, id])
        guard let promoted = try record(id: id, now: now) else { throw ClipStoreError.missingRecord }
        return promoted
    }

    /// Saves an independent durable copy; the source history retains its original expiry.
    public func saveSnippet(_ id: String, title: String? = nil) throws {
        let now = Date()
        guard let item = try record(id: id, now: now) else { throw ClipStoreError.missingRecord }
        if item.isSnippet { return }
        try purge(now: now)
        _ = try independentCopy(item, title: snippetTitle(title ?? item.title, text: item.text), capturedAt: item.capturedAt, snippet: true)
    }

    private func independentCopy(_ item: ClipRecord, title: String, capturedAt: Date, snippet: Bool) throws -> ClipRecord {
        try validateMetadata(title: title, source: item.source)
        try capacity(item.byteCount + metadataBytes(title: title, source: item.source))
        let newID = UUID().uuidString
        var copied: [URL] = []
        do {
            func copy(_ path: String?, into folder: URL) throws -> String? {
                guard let path else { return nil }
                let original = URL(fileURLWithPath: path)
                let target = folder.appendingPathComponent(newID).appendingPathExtension(original.pathExtension)
                try fm.copyItem(at: original, to: target)
                copied.append(target)
                return target.path
            }
            let asset = try copy(item.assetPath, into: assets)
            let thumb = try copy(item.thumbnailPath, into: thumbnails)
            let duplicate = ClipRecord(id: newID, kind: item.kind, text: item.text, title: title, capturedAt: capturedAt, expiresAt: snippet ? nil : capturedAt.addingTimeInterval(Self.retention), source: item.source, isSnippet: snippet, assetPath: asset, thumbnailPath: thumb, byteCount: item.byteCount, isParameterized: snippet && item.isParameterized)
            try insert(duplicate, digest: nil)
            return duplicate
        } catch {
            for url in copied { try? fm.removeItem(at: url) }
            throw error
        }
    }
    public func setParameterized(id: String, enabled: Bool) throws {
        guard let item = try record(id: id), item.isSnippet, item.kind == .text else { throw ClipStoreError.invalidSnippet }
        try execute("UPDATE clips SET parameterized=? WHERE id=?", [enabled ? 1 : 0, id])
    }

    public func createSnippet(title: String, text: String) throws {
        let title = snippetTitle(title, text: text)
        try validateSnippet(title: title, text: text)
        try purge()
        try capacity(text.utf8.count + metadataBytes(title: title, source: "Snippet"))
        let item = ClipRecord(id: UUID().uuidString, kind: .text, text: text, title: title, capturedAt: Date(), expiresAt: nil, source: "Snippet", isSnippet: true, assetPath: nil, thumbnailPath: nil, byteCount: text.utf8.count, isParameterized: false)
        try insert(item, digest: nil)
    }
    public func updateSnippet(id: String, title: String, text: String?, parameterized: Bool? = nil) throws {
        guard let item = try fetch("SELECT id,kind,text,title,captured,expires,source,snippet,asset,thumbnail,bytes,parameterized FROM clips WHERE id=? AND snippet=1", [id]).first else { throw ClipStoreError.missingRecord }
        let title = snippetTitle(title, text: text ?? item.text)
        try validateMetadata(title: title, source: item.source)
        try purge()
        if item.kind == .text {
            let content = text ?? item.text ?? ""
            try validateSnippet(title: title, text: content)
            try capacity(content.utf8.count - item.byteCount + title.utf8.count - item.title.utf8.count, additionalRecords: 0)
            try execute("UPDATE clips SET title=?,text=?,bytes=?,digest=NULL,parameterized=? WHERE id=?", [title, content, content.utf8.count, (parameterized ?? item.isParameterized) ? 1 : 0, id])
        } else {
            guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ClipStoreError.invalidSnippet }
            try capacity(title.utf8.count - item.title.utf8.count, additionalRecords: 0)
            try execute("UPDATE clips SET title=? WHERE id=?", [title, id])
        }
    }
    public func delete(id: String) throws { try remove(where: "id=?", args: [id]) }
    public func clearHistory() throws { try remove(where: "snippet=0", args: []) }
    public func deleteAll() throws { try remove(where: "1=1", args: []) }
    public func purge(now: Date = Date()) throws {
        try remove(where: "snippet=0 AND expires<=?", args: [now.timeIntervalSince1970])
        try retryPendingAssetRemovals()
    }
    public func stats() throws -> (historyCount: Int, snippetCount: Int, bytes: Int) {
        let stmt = try statement("SELECT COALESCE(SUM(CASE WHEN snippet=0 THEN 1 ELSE 0 END),0), COALESCE(SUM(CASE WHEN snippet=1 THEN 1 ELSE 0 END),0), COALESCE(SUM(bytes),0) FROM clips", [])
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw error() }
        return (Int(sqlite3_column_int64(stmt, 0)), Int(sqlite3_column_int64(stmt, 1)), Int(sqlite3_column_int64(stmt, 2)))
    }

    private func snippetTitle(_ title: String, text: String?) -> String {
        if !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return title }
        return text.map(firstLineTitle) ?? "Image snippet"
    }
    private func validateSnippet(title: String, text: String) throws {
        try validateMetadata(title: title, source: "Snippet")
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ClipStoreError.invalidSnippet }
        guard text.utf8.count <= Self.maximumTextBytes else { throw ClipStoreError.limit("Text exceeds the 1 MB item limit.") }
    }
    private func firstLineTitle(_ text: String) -> String {
        // Stop after the display limit instead of splitting an entire megabyte-long clip.
        var output = "", count = 0
        for character in text {
            if character.isNewline {
                if count > 0 { break }
                continue
            }
            output.append(character)
            count += 1
            if count == 120 { break }
        }
        return output
    }
    private func metadataBytes(title: String, source: String) -> Int { title.utf8.count + source.utf8.count }
    private func validateMetadata(title: String, source: String) throws {
        guard title.utf8.count <= Self.maximumTextBytes, source.utf8.count <= Self.maximumTextBytes else {
            throw ClipStoreError.limit("Title or source exceeds the 1 MB item limit.")
        }
    }
    private func capacity(_ added: Int, additionalRecords: Int = 1) throws {
        // A shrinking edit must remain possible for a legacy store already above its budget.
        if additionalRecords == 0 && added <= 0 { return }
        let stmt = try statement("SELECT COUNT(*),COALESCE(SUM(bytes+length(CAST(title AS BLOB))+length(CAST(source AS BLOB))),0) FROM clips", [])
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw error() }
        guard Int(sqlite3_column_int64(stmt, 0)) + additionalRecords <= 10_000 else { throw ClipStoreError.limit("Local history has reached the 10,000 item limit. Delete items before adding more.") }
        guard Int(sqlite3_column_int64(stmt, 1)) + added <= Self.maximumStorageBytes else { throw ClipStoreError.limit("Local storage is full (512 MB). Delete items before adding more.") }
    }
    private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func duplicate(digest: String, kind: ClipKind, now: Date) throws -> ClipRecord? {
        // Short-window deduplication preserves later genuine copy events and never extends expiry.
        let latest = try fetch("SELECT id,kind,text,title,captured,expires,source,snippet,asset,thumbnail,bytes,parameterized FROM clips WHERE snippet=0 ORDER BY captured DESC,rowid DESC LIMIT 1", []).first
        guard let latest, latest.kind == kind, now.timeIntervalSince(latest.capturedAt) >= 0, now.timeIntervalSince(latest.capturedAt) <= 2, latest.expiresAt.map({ $0 > now }) ?? false else { return nil }
        let stmt = try statement("SELECT digest FROM clips WHERE id=?", [latest.id])
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, let raw = sqlite3_column_text(stmt, 0), String(cString: raw) == digest else { return nil }
        return latest
    }
    private func insert(_ r: ClipRecord, digest: String?) throws {
        try execute("INSERT INTO clips VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)", [r.id, r.kind.rawValue, r.text, r.title, r.capturedAt.timeIntervalSince1970, r.expiresAt?.timeIntervalSince1970, r.source, r.isSnippet ? 1 : 0, r.assetPath, r.thumbnailPath, r.byteCount, digest, r.isParameterized ? 1 : 0])
    }
    private func remove(where condition: String, args: [Any?]) throws {
        // Cleanup only needs asset references; do not load potentially large text bodies.
        let stmt = try statement("SELECT asset,thumbnail FROM clips WHERE \(condition)", args)
        var paths: [String] = []
        var rowCount = 0
        do {
            defer { sqlite3_finalize(stmt) }
            while true {
                let result = sqlite3_step(stmt)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW else { throw error() }
                rowCount += 1
                for column: Int32 in [0, 1] {
                    if let raw = sqlite3_column_text(stmt, column) { paths.append(String(cString: raw)) }
                }
            }
        }
        guard rowCount > 0 else { return }
        try execute("DELETE FROM clips WHERE \(condition)", args)
        // SQL deletion commits first; retain failures for the next cleanup tick.
        // Startup reconciliation also recovers these orphans after an interrupted process.
        pendingAssetRemovals.formUnion(paths)
        try retryPendingAssetRemovals()
    }
    private func retryPendingAssetRemovals() throws {
        var firstError: Error?
        for path in pendingAssetRemovals {
            do {
                try removeOwned(path)
                pendingAssetRemovals.remove(path)
            } catch { if firstError == nil { firstError = error } }
        }
        if let firstError { throw firstError }
    }
    private func writePrivate(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private func removeOwned(_ path: String) throws {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard [assets.path, thumbnails.path].contains(url.deletingLastPathComponent().resolvingSymlinksInPath().path) else { return }
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
    }
    private func reconcileAssets() throws {
        // Startup must not materialize every copied text body (up to the storage budget).
        let stmt = try statement("SELECT id,kind,snippet,asset,thumbnail FROM clips", [])
        var items: [(id: String, image: Bool, snippet: Bool, asset: String?, thumbnail: String?)] = []
        do {
            defer { sqlite3_finalize(stmt) }
            while true {
                let result = sqlite3_step(stmt)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW else { throw error() }
                func field(_ n: Int32) -> String? { sqlite3_column_text(stmt, n).map { String(cString: $0) } }
                guard let id = field(0) else { throw ClipStoreError.database("Invalid asset record") }
                items.append((id, field(1) == ClipKind.image.rawValue, sqlite3_column_int(stmt, 2) != 0, field(3), field(4)))
            }
        }
        func ownedPath(_ stored: String?, folder: URL, id: String) -> String? {
            guard let stored else { return nil }
            let old = URL(fileURLWithPath: stored)
            // Only files generated for this exact UUID record can be rebased after moving a store.
            guard UUID(uuidString: id) != nil, old.deletingPathExtension().lastPathComponent == id,
                  old.deletingLastPathComponent().lastPathComponent == folder.lastPathComponent else { return stored }
            let current = folder.appendingPathComponent(old.lastPathComponent)
            guard let attributes = try? fm.attributesOfItem(atPath: current.path), attributes[.type] as? FileAttributeType == .typeRegular else { return stored }
            return current.path
        }
        var referenced = Set<String>()
        for item in items {
            let asset = ownedPath(item.asset, folder: assets, id: item.id)
            let thumbnail = ownedPath(item.thumbnail, folder: thumbnails, id: item.id)
            if asset != item.asset || thumbnail != item.thumbnail {
                try execute("UPDATE clips SET asset=?,thumbnail=? WHERE id=?", [asset, thumbnail, item.id])
            }
            for path in [asset, thumbnail].compactMap({ $0 }) {
                referenced.insert(URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path)
            }
            if item.image && !item.snippet, asset.map({ !fm.fileExists(atPath: $0) }) ?? true { try delete(id: item.id) }
        }
        for folder in [assets, thumbnails] {
            for url in try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) where !referenced.contains(url.standardizedFileURL.resolvingSymlinksInPath().path) { try fm.removeItem(at: url) }
        }
    }

    private final class SearchNeedle {
        let asciiFold: String?
        let matcher: NSRegularExpression?
        init(_ text: String) {
            let folded = text.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            asciiFold = folded.fastestEncoding == .ascii ? folded : nil
            matcher = try? NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: text.precomposedStringWithCanonicalMapping), options: .caseInsensitive)
        }
    }
    private static let asciiCharacters = Array(UInt8(1)...UInt8(127)) + [0]
    private static let searchLocale = newlocale(LC_CTYPE_MASK, "C", nil)
    private static func asciiContains(_ value: OpaquePointer?, needle: SearchNeedle) -> Bool? {
        guard let source = sqlite3_value_text(value), let locale = searchLocale else { return nil }
        let sourceCount = Int(sqlite3_value_bytes(value))
        let sourceChars = UnsafeRawPointer(source).assumingMemoryBound(to: CChar.self)
        // Keep ASCII folding independent of the user locale without changing other threads.
        let previousLocale = uselocale(locale)
        defer { uselocale(previousLocale) }
        return asciiCharacters.withUnsafeBufferPointer { buffer -> Bool? in
            let accept = UnsafeRawPointer(buffer.baseAddress!).assumingMemoryBound(to: CChar.self)
            func search(_ queryChars: UnsafePointer<CChar>?) -> Bool? {
                var offset = 0
                while offset < sourceCount {
                    let segment = sourceChars.advanced(by: offset)
                    let length = strlen(segment)
                    // Non-ASCII segments use canonical Unicode substring matching.
                    if strspn(segment, accept) != length { return nil }
                    if let queryChars, strcasestr(segment, queryChars) != nil { return true }
                    offset += length + 1
                }
                return false
            }
            if let folded = needle.asciiFold {
                return folded.withCString { queryChars -> Bool? in
                    guard !folded.isEmpty, strspn(queryChars, accept) == folded.utf8.count else { return nil }
                    return search(queryChars)
                }
            }
            // A caseless query that still contains non-ASCII scalars cannot occur in a
            // verified ASCII source. Avoid an expensive ICU full scan of megabyte clips.
            return search(nil)
        }
    }
    private static func sqliteString(_ value: OpaquePointer?) -> String? {
        guard let bytes = sqlite3_value_text(value) else { return nil }
        return String(decoding: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_value_bytes(value))), as: UTF8.self)
    }
    private func registerTextFunctions() throws {
        let flags = SQLITE_UTF8 | SQLITE_DETERMINISTIC
        guard sqlite3_create_function_v2(db, "clip_contains", 2, flags, nil, { context, _, arguments in
            autoreleasepool {
                guard let arguments else { sqlite3_result_int(context, 0); return }
                let needle: SearchNeedle
                if let cached = sqlite3_get_auxdata(context, 1) {
                    needle = Unmanaged<SearchNeedle>.fromOpaque(cached).takeUnretainedValue()
                } else {
                    needle = SearchNeedle(ClipStore.sqliteString(arguments[1]) ?? "")
                    sqlite3_set_auxdata(context, 1, Unmanaged.passRetained(needle).toOpaque(), { raw in
                        if let raw { Unmanaged<SearchNeedle>.fromOpaque(raw).release() }
                    })
                }
                if let match = ClipStore.asciiContains(arguments[0], needle: needle) {
                    sqlite3_result_int(context, match ? 1 : 0)
                    return
                }
                let value = ClipStore.sqliteString(arguments[0]) ?? ""
                guard let matcher = needle.matcher else {
                    sqlite3_result_error(context, "Search text is too large for Unicode matching.", -1)
                    return
                }
                let canonical = value.precomposedStringWithCanonicalMapping
                sqlite3_result_int(context, matcher.firstMatch(in: canonical, range: NSRange(canonical.startIndex..., in: canonical)) == nil ? 0 : 1)
            }
        }, nil, nil, nil) == SQLITE_OK else { throw error() }
        guard sqlite3_create_function_v2(db, "clip_preview", 2, flags, nil, { context, _, arguments in
            guard let arguments, let bytes = sqlite3_value_text(arguments[0]) else { sqlite3_result_null(context); return }
            let count = Int(sqlite3_value_bytes(arguments[0]))
            var remaining = max(0, sqlite3_value_int64(arguments[1]))
            var offset = 0
            while offset < count && remaining > 0 {
                let first = bytes[offset]
                let length = first < 0x80 ? 1 : first < 0xE0 ? 2 : first < 0xF0 ? 3 : 4
                offset += min(length, count - offset)
                remaining -= 1
            }
            sqlite3_result_text64(context, UnsafeRawPointer(bytes).assumingMemoryBound(to: CChar.self), UInt64(offset), unsafeBitCast(-1, to: sqlite3_destructor_type.self), UInt8(SQLITE_UTF8))
        }, nil, nil, nil) == SQLITE_OK else { throw error() }
    }
    private func statement(_ sql: String, _ args: [Any?]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw error() }
        for (offset, value) in args.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case let s as String: result = sqlite3_bind_text64(stmt, index, s, UInt64(s.utf8.count), transient, UInt8(SQLITE_UTF8))
            case let n as Int: result = sqlite3_bind_int64(stmt, index, Int64(n))
            case let n as Double: result = sqlite3_bind_double(stmt, index, n)
            default: result = sqlite3_bind_null(stmt, index)
            }
            if result != SQLITE_OK { sqlite3_finalize(stmt); throw error() }
        }
        return stmt
    }
    private func execute(_ sql: String, _ args: [Any?] = []) throws {
        let stmt = try statement(sql, args); defer { sqlite3_finalize(stmt) }
        let result = sqlite3_step(stmt)
        guard result == SQLITE_DONE || result == SQLITE_ROW else { throw error() }
    }
    private func fetch(_ sql: String, _ args: [Any?]) throws -> [ClipRecord] {
        let stmt = try statement(sql, args); defer { sqlite3_finalize(stmt) }
        func string(_ index: Int32) -> String? {
            guard let bytes = sqlite3_column_text(stmt, index) else { return nil }
            return String(decoding: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(stmt, index))), as: UTF8.self)
        }
        var output: [ClipRecord] = []
        while true {
            let result = sqlite3_step(stmt)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw error() }
            guard let id = string(0), let kind = string(1).flatMap(ClipKind.init(rawValue:)), let title = string(3), let source = string(6) else { throw ClipStoreError.database("Invalid history record") }
            let expiry = sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5))
            output.append(ClipRecord(id: id, kind: kind, text: string(2), title: title, capturedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4)), expiresAt: expiry, source: source, isSnippet: sqlite3_column_int(stmt, 7) != 0, assetPath: string(8), thumbnailPath: string(9), byteCount: Int(sqlite3_column_int64(stmt, 10)), isParameterized: sqlite3_column_int(stmt, 11) != 0))
        }
        return output
    }
    private func error() -> ClipStoreError { .database(db.map { String(cString: sqlite3_errmsg($0)) } ?? "Database unavailable") }
}
