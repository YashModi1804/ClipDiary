import Foundation
import AppKit
import ClipDiaryCore
import SQLite3
import Darwin
setbuf(stdout, nil)
func require(_ condition: Bool, _ message: String = "Core verification assertion failed", line: Int = #line) { if !condition { fatalError("Line \(line): \(message)") } }
func verify() throws {
let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
defer { try? FileManager.default.removeItem(at: folder) }
let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
var store: ClipStore? = try ClipStore(directory: folder)
let original = try store!.addText("hello Unicode café", source: "Test", now: now)!
try store!.saveSnippet(original.id)
require(try store!.records().count == 1)
require(try store!.records(snippets: true).count == 1)
let snippet = try store!.records(snippets: true).first!
require(abs(snippet.capturedAt.timeIntervalSince(original.capturedAt)) < 0.001, "Saved snippet preserves original copy time")
try store!.updateSnippet(id: snippet.id, title: "Saved", text: "changed")
require(try store!.records().first!.text == "hello Unicode café")
require(try store!.records(now: now.addingTimeInterval(ClipStore.retention)).isEmpty)
require(try store!.record(id: original.id, now: now)?.text == "hello Unicode café")
require(try store!.record(id: original.id, now: now.addingTimeInterval(ClipStore.retention)) == nil)
require(try store!.record(id: snippet.id, now: now.addingTimeInterval(ClipStore.retention))?.isSnippet == true)
require(try store!.record(id: "missing") == nil)
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
let data = bitmap.representation(using: .png, properties: [:])!
let image = try store!.addImage(data: data, title: "shot", source: "Test", now: now)!
try store!.saveSnippet(image.id)
let imageSnippet = try store!.records(snippets: true).first { $0.kind == .image }!
require(imageSnippet.assetPath != image.assetPath)
try store!.purge(now: now.addingTimeInterval(ClipStore.retention))
require(!FileManager.default.fileExists(atPath: image.assetPath!))
require(FileManager.default.fileExists(atPath: imageSnippet.assetPath!))
store = nil
store = try ClipStore(directory: folder)
require(try store!.records().isEmpty)
require(try store!.records(snippets: true).count == 2)
do { _ = try store!.addImage(data: Data([1,2,3]), title: "bad", source: "Test"); fatalError("Accepted invalid image") } catch ClipStoreError.invalidImage { }
try store!.deleteAll()
require(try store!.stats().bytes == 0)
require(!FileManager.default.fileExists(atPath: imageSnippet.assetPath!))
let exact = "  leading\ntrailing  "
let textRecord = try store!.addText(exact, source: "Test")!
require(textRecord.text == exact, "Whitespace must remain exact")
let shot1 = try store!.addImage(data: data, title: "shot 1", source: "Screenshot folder", now: now, deduplicate: false)!
let shot2 = try store!.addImage(data: data, title: "shot 2", source: "Screenshot folder", now: now, deduplicate: false)!
require(shot1.id != shot2.id, "Intentional separate screenshots must remain distinct")
try store!.deleteAll()
let orphan = folder.appendingPathComponent("Assets/orphan.png")
try Data([1,2,3]).write(to: orphan)
store = nil
store = try ClipStore(directory: folder)
require(!FileManager.default.fileExists(atPath: orphan.path), "Orphan file reconciliation")
store = nil
var raw: OpaquePointer?
require(sqlite3_open(folder.appendingPathComponent("history.sqlite3").path, &raw) == SQLITE_OK)
require(sqlite3_exec(raw, "PRAGMA user_version=99", nil, nil, nil) == SQLITE_OK)
sqlite3_close(raw)
do { _ = try ClipStore(directory: folder); fatalError("Opened unsupported schema") } catch ClipStoreError.database { }
require(sqlite3_open(folder.appendingPathComponent("history.sqlite3").path, &raw) == SQLITE_OK)
var stmt: OpaquePointer?
require(sqlite3_prepare_v2(raw, "PRAGMA user_version", -1, &stmt, nil) == SQLITE_OK)
require(sqlite3_step(stmt) == SQLITE_ROW)
require(sqlite3_column_int(stmt, 0) == 99, "Newer schema must not be overwritten")
sqlite3_finalize(stmt); sqlite3_close(raw)
print("PASS: independent text/image snippets, immutable history, exact96h filtering and asset purge, durable restart, invalid-image rejection, delete-all byte accounting")
}

func withRawDatabase(_ folder: URL, _ action: (OpaquePointer) throws -> Void) throws {
    var raw: OpaquePointer?
    require(sqlite3_open(folder.appendingPathComponent("history.sqlite3").path, &raw) == SQLITE_OK)
    guard let raw else { fatalError("Cannot open fixture database") }
    defer { sqlite3_close(raw) }
    try action(raw)
}
func executeFixture(_ raw: OpaquePointer, _ sql: String) {
    let result = sqlite3_exec(raw, sql, nil, nil, nil)
    require(result == SQLITE_OK, "Fixture SQL failed: \(String(cString: sqlite3_errmsg(raw)))")
}
func verifyStorageLimits() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    var store: ClipStore? = try ClipStore(directory: folder)
    try store!.createSnippet(title: "Protected", text: "Keep me")
    let protectedID = try store!.records(snippets: true).first!.id
    let existing = try store!.addText("existing", source: "Original app")!
    store = nil
    // Inject accounting metadata only: exercises the capacity guard without allocating 512 MiB.
    try withRawDatabase(folder) { raw in
        executeFixture(raw, "UPDATE clips SET bytes=\(ClipStore.maximumStorageBytes - existing.byteCount) WHERE snippet=1")
    }
    store = try ClipStore(directory: folder)
    do { _ = try store!.addText("rejected", source: "Capacity check"); fatalError("Storage budget was not enforced") }
    catch ClipStoreError.limit { }
    require(try store!.records(snippets: true).first?.id == protectedID)
    require(try store!.stats().historyCount == 1)
    require(try store!.stats().bytes == ClipStore.maximumStorageBytes)
    let promoted = try store!.recopy(id: existing.id)
    require(promoted.id == existing.id && promoted.source == "Original app")
    require(try store!.stats().bytes == ClipStore.maximumStorageBytes)
    do { _ = try store!.recopy(id: protectedID); fatalError("Snippet recopy exceeded storage budget") } catch ClipStoreError.limit { }
    require(try store!.records(snippets: true).first?.id == protectedID)
    do { _ = try store!.addText(String(repeating: "x", count: ClipStore.maximumTextBytes + 1), source: "Item limit"); fatalError("Text item limit was not enforced") }
    catch ClipStoreError.limit { }
    do { _ = try store!.addImage(data: Data(repeating: 0, count: ClipStore.maximumImageBytes + 1), title: "Oversize", source: "Item limit"); fatalError("Image item limit was not enforced") }
    catch ClipStoreError.limit { }
    require(try store!.stats().snippetCount == 1)
    print("PASS: 512 MiB accounting cap and text/image item limits reject new items; protected snippet unchanged (budget fixture uses synthetic byte metadata)")
}
func verifyRecordCapacityAndMeasureSearch() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    var started = ProcessInfo.processInfo.systemUptime
    var store: ClipStore? = try ClipStore(directory: folder)
    let openMS = (ProcessInfo.processInfo.systemUptime - started) * 1000
    started = ProcessInfo.processInfo.systemUptime
    _ = try store!.addText("Initial insertion", source: "Timing")
    let insertMS = (ProcessInfo.processInfo.systemUptime - started) * 1000
    try store!.deleteAll()
    store = nil
    let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)).timeIntervalSince1970
    try withRawDatabase(folder) { raw in
        executeFixture(raw, "BEGIN IMMEDIATE")
        executeFixture(raw, "WITH RECURSIVE sequence(n) AS (VALUES(1) UNION ALL SELECT n+1 FROM sequence WHERE n<10000) INSERT INTO clips(id,kind,text,title,captured,expires,source,snippet,asset,thumbnail,bytes,digest) SELECT 'fixture-'||n,'text','Searchable fixture value '||n,'Fixture '||n,\(now),CASE WHEN n=1 THEN NULL ELSE \(now + ClipStore.retention) END,'Fixture',CASE WHEN n=1 THEN 1 ELSE 0 END,NULL,NULL,32,NULL FROM sequence")
        executeFixture(raw, "COMMIT")
    }
    store = try ClipStore(directory: folder)
    require(try store!.stats().historyCount == 9999)
    require(try store!.stats().snippetCount == 1)
    do { _ = try store!.addText("Record overflow", source: "Limit test"); fatalError("Record capacity was not enforced") }
    catch ClipStoreError.limit { }
    require(try store!.stats().historyCount == 9999)
    require(try store!.records(snippets: true).first?.id == "fixture-1")
    let promoted = try store!.recopy(id: "fixture-9999")
    require(promoted.id == "fixture-9999" && promoted.source == "Fixture")
    do { _ = try store!.recopy(id: "fixture-1"); fatalError("Snippet recopy exceeded row capacity") } catch ClipStoreError.limit { }
    require(try store!.stats().historyCount == 9999)
    var fullTimes: [Double] = []
    var searchTimes: [Double] = []
    for _ in 0..<5 {
        started = ProcessInfo.processInfo.systemUptime
        let all = try store!.records()
        fullTimes.append((ProcessInfo.processInfo.systemUptime - started) * 1000)
        require(all.count == 9999)
        started = ProcessInfo.processInfo.systemUptime
        let found = try store!.records(query: "fixture value 9999")
        searchTimes.append((ProcessInfo.processInfo.systemUptime - started) * 1000)
        require(found.count == 1 && found.first?.id == "fixture-9999")
    }
    started = ProcessInfo.processInfo.systemUptime
    for _ in 0..<100 { require(try store!.record(id: "fixture-9999")?.id == "fixture-9999") }
    let lookupMS = (ProcessInfo.processInfo.systemUptime - started) * 1000 / 100
    print(String(format: "PASS: single-record lookup average %.3f ms across 100 reads of 10,000-record fixture", lookupMS))
    print(String(format: "PASS: 10,000-record combined cap preserves snippet; empty-store open %.2f ms; first durable text insertion %.2f ms; 9,999-row materialization median %.2f ms; selective search median %.2f ms (5 runs, synthetic small text rows)", openMS, insertMS, fullTimes.sorted()[2], searchTimes.sorted()[2]))
}
func verifyDeletionAndBackupPolicy() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = try ClipStore(directory: folder)
    var checkedURL = URL(fileURLWithPath: store.directory.path, isDirectory: true)
    checkedURL.removeAllCachedResourceValues()
    let resource = try checkedURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
    // Verify the persisted exclusion metadata directly: the SDK's URL resource query can
    // report false for temporary directories even when the exclusion xattr is present.
    let attribute = "com.apple.metadata:com_apple_backup_excludeItem"
    let length = getxattr(store.directory.path, attribute, nil, 0, 0, 0)
    require(length > 0, "Persisted backup exclusion metadata missing")
    var attributeData = Data(count: length)
    let read = attributeData.withUnsafeMutableBytes { getxattr(store.directory.path, attribute, $0.baseAddress, length, 0, 0) }
    require(read == length)
    let excludedBy = try PropertyListSerialization.propertyList(from: attributeData, format: nil) as? String
    require(excludedBy == "com.apple.backupd", "Backup exclusion marker has unexpected payload")

    let sentinel = "CLIPDIARY_DELETION_SENTINEL_" + UUID().uuidString + "_END"
    let bytes = Data(sentinel.utf8)
    let record = try store.addText(sentinel, source: "Deletion check")!
    let database = store.directory.appendingPathComponent("history.sqlite3")
    require(try Data(contentsOf: database).range(of: bytes) != nil, "Sentinel must actually reach the database before deletion")
    try store.delete(id: record.id)
    let files = try FileManager.default.contentsOfDirectory(at: store.directory, includingPropertiesForKeys: [.isRegularFileKey])
    var checked = 0
    for file in files where try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
        require(try Data(contentsOf: file).range(of: bytes) == nil, "Deleted sentinel remains in active store/journal bytes")
        checked += 1
    }
    require(!FileManager.default.fileExists(atPath: database.path + "-wal"))
    require(!FileManager.default.fileExists(atPath: database.path + "-journal"))
    print("PASS: persisted backup exclusion xattr valid (Foundation resource flag \(String(describing: resource.isExcludedFromBackup))); deleted sentinel absent in \(checked) active store files; no surviving WAL or rollback journal (does not test snapshots/SSD recovery)")
}
func verifySymlinkCanonicalPersistence() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let real = root.appendingPathComponent("Real")
    let link = root.appendingPathComponent("Alias")
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    var store: ClipStore? = try ClipStore(directory: link)
    require(store!.directory == real.standardizedFileURL.resolvingSymlinksInPath())
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let data = bitmap.representation(using: .png, properties: [:])!
    let image = try store!.addImage(data: data, title: "Symlink fixture", source: "Test")!
    try store!.saveSnippet(image.id)
    let snippet = try store!.records(snippets: true).first!
    require(abs(snippet.capturedAt.timeIntervalSince(image.capturedAt)) < 0.001, "Image snippet preserves original copy time")
    require(snippet.assetPath!.hasPrefix(store!.directory.path + "/"))
    store = nil
    store = try ClipStore(directory: real)
    require(try store!.records(snippets: true).first?.id == snippet.id)
    require(try Data(contentsOf: URL(fileURLWithPath: snippet.assetPath!)) == data)
    store = nil
    store = try ClipStore(directory: link)
    require(try store!.records(snippets: true).first?.id == snippet.id)
    require(FileManager.default.fileExists(atPath: snippet.thumbnailPath!))
    print("PASS: symbolic-link and real-directory reopen preserve independent image snippet original and thumbnail")
}
func verifyExplicitRecopy() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
    var store: ClipStore? = try ClipStore(directory: folder)
    let first = try store!.addText("  exact text\n", source: "com.example.Original", now: now)!
    _ = try store!.addText("newer", source: "Other app", now: now.addingTimeInterval(1))
    let initialStats = try store!.stats()
    let promoted = try store!.recopy(id: first.id, now: now.addingTimeInterval(2))
    require(promoted.id == first.id && promoted.source == first.source && promoted.text == first.text)
    require(promoted.capturedAt == now.addingTimeInterval(2))
    require(promoted.expiresAt == now.addingTimeInterval(2 + ClipStore.retention))
    require(try store!.records(now: now.addingTimeInterval(2)).first?.id == first.id)
    require(try store!.stats().bytes == initialStats.bytes && store!.stats().historyCount == initialStats.historyCount)
    require(try store!.record(id: first.id, now: now.addingTimeInterval(ClipStore.retention)) != nil)
    let tiedAt = now.addingTimeInterval(2)
    let olderTie = try store!.addText("Older equal-time item", source: "Equal-time original", now: tiedAt)!
    _ = try store!.addText("Newer equal-time item", source: "Other", now: tiedAt)
    let tieStats = try store!.stats()
    let tiePromoted = try store!.recopy(id: olderTie.id, now: tiedAt)
    require(tiePromoted.id == olderTie.id && tiePromoted.capturedAt == tiedAt && tiePromoted.source == olderTie.source)
    require(try store!.records(now: tiedAt).first?.id == olderTie.id, "Explicit recopy must become latest even at equal timestamps")
    require(try store!.stats().historyCount == tieStats.historyCount && store!.stats().bytes == tieStats.bytes)
    try store!.saveSnippet(first.id)
    let snippet = try store!.records(snippets: true).first!
    let copied = try store!.recopy(id: snippet.id, now: now.addingTimeInterval(3))
    require(copied.id != snippet.id && !copied.isSnippet && copied.source == snippet.source)
    require(copied.text == snippet.text && copied.title == snippet.title)
    let repeated = try store!.recopy(id: snippet.id, now: now.addingTimeInterval(3))
    require(repeated.id != copied.id, "Explicit recopy must bypass passive duplicate suppression")
    let untouched = try store!.record(id: snippet.id)!
    require(untouched.capturedAt == snippet.capturedAt && untouched.source == snippet.source && untouched.expiresAt == nil)
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let data = bitmap.representation(using: .png, properties: [:])!
    let image = try store!.addImage(data: data, title: "Original screenshot", source: "Screenshot folder", now: now.addingTimeInterval(10), deduplicate: false)!
    let imageStats = try store!.stats()
    let promotedImage = try store!.recopy(id: image.id, now: now.addingTimeInterval(11))
    require(promotedImage.id == image.id && promotedImage.assetPath == image.assetPath && promotedImage.thumbnailPath == image.thumbnailPath)
    require(try promotedImage.source == image.source && store!.stats().bytes == imageStats.bytes)
    try store!.saveSnippet(image.id)
    let imageSnippet = try store!.records(snippets: true).first { $0.kind == .image }!
    let imageHistory = try store!.recopy(id: imageSnippet.id, now: now.addingTimeInterval(12))
    require(imageHistory.assetPath != imageSnippet.assetPath && imageHistory.thumbnailPath != imageSnippet.thumbnailPath)
    require(imageHistory.source == imageSnippet.source && imageHistory.capturedAt == now.addingTimeInterval(12))
    require(try Data(contentsOf: URL(fileURLWithPath: imageHistory.assetPath!)) == data)
    try store!.delete(id: imageHistory.id)
    require(try Data(contentsOf: URL(fileURLWithPath: imageSnippet.assetPath!)) == data)
    store = nil
    store = try ClipStore(directory: folder)
    require(try store!.record(id: promoted.id)?.capturedAt == promoted.capturedAt)
    require(try store!.record(id: promotedImage.id)?.source == image.source)
    require(try store!.record(id: imageSnippet.id)?.capturedAt == imageSnippet.capturedAt)
    do { _ = try store!.recopy(id: first.id, now: promoted.expiresAt!); fatalError("Expired history was resurrected") } catch ClipStoreError.missingRecord { }
    do { _ = try store!.recopy(id: "missing"); fatalError("Missing item accepted") } catch ClipStoreError.missingRecord { }
    try store!.purge(now: now.addingTimeInterval(12 + ClipStore.retention))
    require(try store!.records(snippets: true).count == 2)
    require(FileManager.default.fileExists(atPath: imageSnippet.assetPath!))
    print("PASS: explicit recopy promotes same history ID/assets without byte growth, renews 96h and ordering, preserves provenance through restart; snippets remain unchanged with independent history assets; cap rejection and expired/missing protection")
}
func verifyEmbeddedNullPersistence() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    var store: ClipStore? = try ClipStore(directory: folder)
    let text = "before\0after 🧪"
    let source = "source\0suffix"
    let item = try store!.addText(text, source: source)!
    let loaded = try store!.record(id: item.id)!
    require(loaded.text == text, "Embedded U+0000 must not truncate clipboard text in SQLite")
    require(loaded.source == source && loaded.byteCount == text.utf8.count)
    try store!.saveSnippet(item.id, title: "title\0suffix")
    let snippet = try store!.records(snippets: true).first!
    require(snippet.title == "title\0suffix" && snippet.text == text)
    try store!.updateSnippet(id: snippet.id, title: "edited\0title", text: "<value>\0tail", parameterized: true)
    let rendered = try store!.recopy(id: snippet.id, parameterValues: ["value": "literal\0replacement"])
    require(rendered.text == "literal\0replacement\0tail")
    store = nil
    store = try ClipStore(directory: folder)
    require(try store!.record(id: item.id)?.text == text)
    require(try store!.record(id: snippet.id)?.title == "edited\0title")
    require(try store!.record(id: rendered.id)?.text == rendered.text)
    print("PASS: embedded U+0000 preserves complete UTF-8 clipboard text, source, titles, edited snippets and rendered parameters through restart")
}

func verifyFailedAssetDeletionRetry() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.appendingPathComponent("Assets").path); try? FileManager.default.removeItem(at: folder) }
    let store = try ClipStore(directory: folder)
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let data = bitmap.representation(using: .png, properties: [:])!
    let image = try store.addImage(data: data, title: "Delete retry", source: "Test")!
    let assetDirectory = URL(fileURLWithPath: image.assetPath!).deletingLastPathComponent()
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: assetDirectory.path)
    var blocked = false
    do { try store.delete(id: image.id) } catch { blocked = true }
    require(blocked, "Fixture must really prevent asset deletion")
    require(try store.record(id: image.id) == nil)
    require(FileManager.default.fileExists(atPath: image.assetPath!))
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: assetDirectory.path)
    try store.purge()
    require(!FileManager.default.fileExists(atPath: image.assetPath!), "Periodic purge must retry previously failed asset deletion without app restart")
    require(!FileManager.default.fileExists(atPath: image.thumbnailPath!))
    print("PASS: failed asset removal is reported and retried by periodic purge after permissions recover, without reopening the store")
}
func verifyLinkedStorageSafety() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    for name in ["Assets", "Thumbnails"] {
        let storage = root.appendingPathComponent("Store-" + name)
        let unrelated = root.appendingPathComponent("Unrelated-" + name)
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        let sentinel = unrelated.appendingPathComponent("keep.txt")
        let content = Data("unrelated files must remain untouched".utf8)
        try content.write(to: sentinel)
        try FileManager.default.createSymbolicLink(at: storage.appendingPathComponent(name), withDestinationURL: unrelated)
        var rejected = false
        do { _ = try ClipStore(directory: storage) } catch { rejected = true }
        require(rejected, "Linked asset directories must be rejected before reconciliation")
        require(try Data(contentsOf: sentinel) == content)
    }
    let storage = root.appendingPathComponent("Store-Database")
    let unrelated = root.appendingPathComponent("Unrelated-Database")
    try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
    try withRawDatabase(unrelated) { raw in executeFixture(raw, "CREATE TABLE unrelated(value TEXT); INSERT INTO unrelated VALUES ('keep')") }
    try FileManager.default.createSymbolicLink(at: storage.appendingPathComponent("history.sqlite3"), withDestinationURL: unrelated.appendingPathComponent("history.sqlite3"))
    var rejected = false
    do { _ = try ClipStore(directory: storage) } catch ClipStoreError.database { rejected = true }
    require(rejected, "A linked database must not migrate an unrelated database")
    try withRawDatabase(unrelated) { raw in
        var stmt: OpaquePointer?
        require(sqlite3_prepare_v2(raw, "PRAGMA user_version", -1, &stmt, nil) == SQLITE_OK)
        require(sqlite3_step(stmt) == SQLITE_ROW && sqlite3_column_int(stmt, 0) == 0)
        sqlite3_finalize(stmt)
        require(sqlite3_prepare_v2(raw, "SELECT value FROM unrelated", -1, &stmt, nil) == SQLITE_OK)
        require(sqlite3_step(stmt) == SQLITE_ROW)
        require(String(cString: sqlite3_column_text(stmt, 0)) == "keep")
        sqlite3_finalize(stmt)
    }
    print("PASS: linked database rejected without migrating unrelated data; linked asset directories rejected without deleting external sentinels; root-directory aliases remain covered by durability check")
}

func verifyExpiredHistoryCannotBecomeSnippet() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = try ClipStore(directory: folder)
    let expired = try store.addText("Already expired", source: "Test", now: Date().addingTimeInterval(-ClipStore.retention - 10))!
    do { try store.saveSnippet(expired.id); fatalError("Expired history was resurrected permanently") } catch ClipStoreError.missingRecord { }
    require(try store.records(snippets: true).isEmpty)
    try store.purge()
    require(try store.stats().bytes == 0)
    print("PASS: stale save-as-snippet action rejects expired history rather than resurrecting it permanently")
}
func verifyMovedStoreDurability() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let old = root.appendingPathComponent("Original"), moved = root.appendingPathComponent("Moved")
    var store: ClipStore? = try ClipStore(directory: old)
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let bytes = bitmap.representation(using: .png, properties: [:])!
    let image = try store!.addImage(data: bytes, title: "Moved screenshot", source: "Original source")!
    try store!.saveSnippet(image.id)
    let snippet = try store!.records(snippets: true).first!
    store = nil
    try FileManager.default.moveItem(at: old, to: moved)
    store = try ClipStore(directory: moved)
    let relocated = try store!.record(id: snippet.id)!
    require(relocated.assetPath != snippet.assetPath && relocated.assetPath!.hasPrefix(store!.directory.path))
    require(try Data(contentsOf: URL(fileURLWithPath: relocated.assetPath!)) == bytes)
    require(FileManager.default.fileExists(atPath: relocated.thumbnailPath!))
    require(try store!.record(id: image.id)?.source == image.source)
    try store!.clearHistory()
    require(try Data(contentsOf: URL(fileURLWithPath: relocated.assetPath!)) == bytes)
    store = nil
    store = try ClipStore(directory: moved)
    require(try store!.record(id: snippet.id)?.assetPath == relocated.assetPath)
    print("PASS: moving the whole data directory preserves UUID-owned history/snippet originals and thumbnails without exposing arbitrary external paths")
}

func verifyBoundedPreviewsAndUnicodeSearch() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = try ClipStore(directory: folder)
    let text = "ÉCOLE Привет Straße %_\\ \0tail 👩🏽‍💻 e\u{301}"
    let item = try store.addText(text, source: "Unicode source")!
    for query in ["école", "привет", "STRASSE", "%_\\", "\0tail"] {
        require(try store.records(query: query).map(\.id) == [item.id], "Literal Unicode case-insensitive search failed: \(query)")
    }
    require(try store.records(query: "%anything").isEmpty)
    require(try store.records(query: "_anything").isEmpty)
    for limit in [0, 1, 12, 35, 100, 4096] {
        let expected = String(String.UnicodeScalarView(text.unicodeScalars.prefix(limit)))
        let preview = try store.records(textPreviewLimit: limit).first!
        require(preview.text == expected, "Preview must preserve UTF8 scalar boundaries and embedded U+0000")
        require(preview.byteCount == item.byteCount && preview.id == item.id)
    }
    require(try store.record(id: item.id)?.text == text, "Full lookup must never inherit preview truncation")
    let blankLines = try store.addText("\n\nFirst useful line\nsecond", source: "Title check", now: Date().addingTimeInterval(3))!
    require(blankLines.title == "First useful line")
    let accent = try store.addText("e\u{301}", source: "ZZZ", now: Date().addingTimeInterval(6))!
    require(try !store.records(query: "e").contains(where: { $0.id == accent.id }), "ASCII optimization must not split a combining-character match")
    require(try store.records(query: "é").contains(where: { $0.id == accent.id }))
    let nulAccent = try store.addText("e\0é", source: "ZZZ", now: Date().addingTimeInterval(7))!
    require(try store.records(query: "e").contains(where: { $0.id == nulAccent.id }))
    require(try store.records(query: "é").contains(where: { $0.id == nulAccent.id }))
    let longTitle = String(repeating: "z", count: 8192) + "NEEDLE_SUFFIX"
    try store.createSnippet(title: longTitle, text: "Metadata preview")
    let titlePreview = try store.records(query: "needle_suffix", snippets: true, textPreviewLimit: 4096).first!
    require(titlePreview.title.utf8.count == 4096)
    require(try store.record(id: titlePreview.id)?.title == longTitle)
    let longSource = String(repeating: "a", count: 8192) + "SOURCE_SUFFIX"
    let sourceItem = try store.addText("Metadata source", source: longSource, now: Date().addingTimeInterval(5))!
    let sourcePreview = try store.records(query: "source_suffix", textPreviewLimit: 4096).first!
    require(sourcePreview.id == sourceItem.id && sourcePreview.source.utf8.count == 4096)
    require(try store.record(id: sourceItem.id)?.source == longSource)
    print("PASS: bounded scalar previews preserve NUL/Unicode, full lookups remain complete, and Unicode search treats percent/underscore/backslash literally")
}

func verifyUnicodeSearchSemantics() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = try ClipStore(directory: folder)
    let samples = ["ÉCOLE", "e\u{301}", "q\u{301}", "Straße", "SS", "K", "K", "ſ", "s", "ﬃ", "ffi", "İ", "i", "I", "ı", "👩🏽‍💻", "👩", "abc\0é", "e\0é", "abc\0DEF"]
    var entries: [ClipRecord] = []
    for (index, sample) in samples.enumerated() {
        entries.append(try store.addText(sample, source: "ZZZ", now: Date().addingTimeInterval(Double(index * 3)))!)
    }
    let queries = ["é", "E\u{301}", "e", "q", "STRASSE", "ß", "s", "ss", "K", "k", "ſ", "ﬃ", "ffi", "İ", "i", "I", "ı", "👩", "👩🏽‍💻", "\0", "c\0d", "不存在", "%", "_", "\u{301}", "🏽", "💻"]
    for query in queries {
        let matcher = try NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: query.precomposedStringWithCanonicalMapping), options: .caseInsensitive)
        func matches(_ value: String) -> Bool {
            let canonical = value.precomposedStringWithCanonicalMapping
            return matcher.firstMatch(in: canonical, range: NSRange(canonical.startIndex..., in: canonical)) != nil
        }
        let expected = Set(entries.filter { matches($0.text ?? "") || matches($0.title) || matches($0.source) }.map(\.id))
        require(try Set(store.records(query: query).map(\.id)) == expected, "ASCII fast path differs from canonical Unicode substring policy for \(query.debugDescription)")
    }
        let qAccent = entries.first { $0.text == "q\u{301}" }!
    let emoji = entries.first { $0.text == "👩🏽‍💻" }!
    require(try store.records(query: "q").contains(where: { $0.id == qAccent.id }))
    require(try store.records(query: "👩").contains(where: { $0.id == emoji.id }))
    print("PASS: canonical Unicode literal-substring search covers accents, Turkish I, case folds, partial emoji/scalars, NUL and escaped regex/wildcard characters")
}

func verifyMetadataBudgetAndExpiredCapacity() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = try ClipStore(directory: folder)
    let oversized = String(repeating: "t", count: ClipStore.maximumTextBytes + 1)
    do { try store.createSnippet(title: oversized, text: "x"); fatalError("Oversized title accepted") } catch ClipStoreError.limit { }
    do { _ = try store.addText("x", source: oversized); fatalError("Oversized source accepted") } catch ClipStoreError.limit { }
    try store.createSnippet(title: "Seed", text: "seed")
    let seed = try store.records(snippets: true).first!
    let timestamp = Date().timeIntervalSince1970
    let fillerBytes = ClipStore.maximumStorageBytes - seed.byteCount - seed.title.utf8.count - seed.source.utf8.count - 2
    try withRawDatabase(folder) { raw in executeFixture(raw, "INSERT INTO clips VALUES('budget-filler','text','x','f',\(timestamp),\(timestamp+ClipStore.retention),'s',0,NULL,NULL,\(fillerBytes),NULL,0)") }
    do { try store.createSnippet(title: "x", text: "x"); fatalError("Metadata bypassed storage budget") } catch ClipStoreError.limit { }
    do { try store.updateSnippet(id: seed.id, title: "Longer title", text: "seed"); fatalError("Title growth bypassed storage budget") } catch ClipStoreError.limit { }
    require(try store.record(id: seed.id)?.title == seed.title)
    // Legacy over-budget stores must still permit a shrinking edit to recover.
    try store.updateSnippet(id: seed.id, title: "S", text: "s")
    try store.deleteAll()
    let now = Date().timeIntervalSince1970
    try withRawDatabase(folder) { raw in
        executeFixture(raw, "WITH RECURSIVE s(n) AS (VALUES(1) UNION ALL SELECT n+1 FROM s WHERE n<10000) INSERT INTO clips SELECT 'expired-'||n,'text','old','Old',\(now-ClipStore.retention-10),\(now-10),'Test',0,NULL,NULL,3,NULL,0 FROM s")
    }
    try store.createSnippet(title: "New", text: "New content")
    require(try store.stats().historyCount == 0 && store.stats().snippetCount == 1)
    print("PASS: title/source limits and metadata-aware storage capacity prevent bypass; shrinking edits recover legacy over-budget records and expired history frees snippet capacity")
}

func verifyLargePayloadStress() throws {
    alarm(30)
    defer { alarm(0) }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    var store: ClipStore? = try ClipStore(directory: folder)
    store = nil
    let prefix = "Searchable payload marker ", suffix = "END_OF_PAYLOAD_MARKER"
    let payload = prefix + String(repeating: "x", count: ClipStore.maximumTextBytes - prefix.utf8.count - suffix.utf8.count) + suffix
    require(payload.utf8.count <= ClipStore.maximumTextBytes)
    let count = 500
    let now = Date().timeIntervalSince1970
    let started = ProcessInfo.processInfo.systemUptime
    try withRawDatabase(folder) { raw in
        executeFixture(raw, "BEGIN IMMEDIATE")
        var stmt: OpaquePointer?
        require(sqlite3_prepare_v2(raw, "INSERT INTO clips VALUES('large-'||?,'text',?,'Stress payload',\(now),\(now+ClipStore.retention),'Stress',0,NULL,NULL,\(payload.utf8.count),NULL,0)", -1, &stmt, nil) == SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        require(sqlite3_bind_text64(stmt, 2, payload, UInt64(payload.utf8.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self), UInt8(SQLITE_UTF8)) == SQLITE_OK)
        for index in 0..<count {
            require(sqlite3_bind_int(stmt, 1, Int32(index)) == SQLITE_OK)
            require(sqlite3_step(stmt) == SQLITE_DONE)
            require(sqlite3_reset(stmt) == SQLITE_OK)
        }
        executeFixture(raw, "COMMIT")
    }
    let fixtureSeconds = ProcessInfo.processInfo.systemUptime - started
    var clock = ProcessInfo.processInfo.systemUptime
    store = try ClipStore(directory: folder)
    let openMS = (ProcessInfo.processInfo.systemUptime - clock) * 1000
    clock = ProcessInfo.processInfo.systemUptime
    var full: [ClipRecord]? = try store!.records()
    let fullMS = (ProcessInfo.processInfo.systemUptime - clock) * 1000
    let fullBytes = full!.reduce(0) { $0 + ($1.text?.utf8.count ?? 0) }
    require(full!.count == count && fullBytes == count * payload.utf8.count)
    full = nil
    clock = ProcessInfo.processInfo.systemUptime
    let preview = try store!.records(textPreviewLimit: 4096)
    let previewMS = (ProcessInfo.processInfo.systemUptime - clock) * 1000
    let previewBytes = preview.reduce(0) { $0 + ($1.text?.utf8.count ?? 0) }
    require(preview.count == count && previewBytes == 4096 * count)
    clock = ProcessInfo.processInfo.systemUptime
    let found = try store!.records(query: "SEARCHABLE PAYLOAD MARKER", textPreviewLimit: 4096)
    let searchMS = (ProcessInfo.processInfo.systemUptime - clock) * 1000
    require(found.count == count)
    require(try store!.record(id: "large-0")?.text == payload)
    clock = ProcessInfo.processInfo.systemUptime
    require(try store!.records(query: "missing-token-never-present", textPreviewLimit: 4096).isEmpty)
    let noMatchMS = (ProcessInfo.processInfo.systemUptime - clock) * 1000
    print(String(format: "STRESS phase: ASCII no-match %.1fms", noMatchMS))
    clock = ProcessInfo.processInfo.systemUptime
    require(try store!.records(query: "end_of_payload_marker", textPreviewLimit: 4096).count == count)
    let endMatchMS = (ProcessInfo.processInfo.systemUptime - clock) * 1000
    print(String(format: "STRESS phase: ASCII end hit %.1fms", endMatchMS))
    clock = ProcessInfo.processInfo.systemUptime
    require(try store!.records(query: "不存在", textPreviewLimit: 4096).isEmpty)
    let unicodeMissMS = (ProcessInfo.processInfo.systemUptime - clock) * 1000
    print(String(format: "STRESS PASS: real %.1f MiB text fixture (%d near-limit clips), fixture %.2fs, startup %.1fms, full list %.1fms/%.1fMiB, preview %.1fms/%.2fMiB, ASCII case-insensitive prefix hit %.1fms, no-match %.1fms, end hit %.1fms, Unicode no-match %.1fms", Double(fullBytes)/1048576,count,fixtureSeconds,openMS,fullMS,Double(fullBytes)/1048576,previewMS,Double(previewBytes)/1048576,searchMS,noMatchMS,endMatchMS,unicodeMissMS))
    let unicodePayload = String(repeating: "😀", count: ClipStore.maximumTextBytes / 4)
    try withRawDatabase(folder) { raw in
        var stmt: OpaquePointer?
        require(sqlite3_prepare_v2(raw, "UPDATE clips SET text=?", -1, &stmt, nil) == SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        require(sqlite3_bind_text64(stmt, 1, unicodePayload, UInt64(unicodePayload.utf8.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self), UInt8(SQLITE_UTF8)) == SQLITE_OK)
        require(sqlite3_step(stmt) == SQLITE_DONE)
    }
    clock = ProcessInfo.processInfo.systemUptime
    require(try store!.records(query: "ΩNO_MATCH", textPreviewLimit: 4096).isEmpty)
    let unicodeSourceMissMS = (ProcessInfo.processInfo.systemUptime - clock) * 1000
    print(String(format: "STRESS phase: real500MiB emoji source Unicode no-match %.1fms (bounded30s process alarm)", unicodeSourceMissMS))

}

try verifyMovedStoreDurability()
try verifyBoundedPreviewsAndUnicodeSearch()
try verifyUnicodeSearchSemantics()
try verifyMetadataBudgetAndExpiredCapacity()
try verifyEmbeddedNullPersistence()
try verifyFailedAssetDeletionRetry()
try verifyLinkedStorageSafety()
try verifyExpiredHistoryCannotBecomeSnippet()
try verify()
try verifyStorageLimits()
try verifyRecordCapacityAndMeasureSearch()
try verifyDeletionAndBackupPolicy()
try verifySymlinkCanonicalPersistence()
try verifyExplicitRecopy()

func verifySnippetParametersAndMigration() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var raw: OpaquePointer?
    require(sqlite3_open(folder.appendingPathComponent("history.sqlite3").path, &raw) == SQLITE_OK)
    let legacy = "CREATE TABLE clips (id TEXT PRIMARY KEY,kind TEXT NOT NULL,text TEXT,title TEXT NOT NULL,captured REAL NOT NULL,expires REAL,source TEXT NOT NULL,snippet INTEGER NOT NULL DEFAULT 0,asset TEXT,thumbnail TEXT,bytes INTEGER NOT NULL,digest TEXT); PRAGMA user_version=1; INSERT INTO clips VALUES ('legacy','text','run <instance> and <instance> / <region>','Legacy',1000,NULL,'Original app',1,NULL,NULL,40,NULL);"
    require(sqlite3_exec(raw, legacy, nil, nil, nil) == SQLITE_OK)
    sqlite3_close(raw)
    var store: ClipStore? = try ClipStore(directory: folder)
    let original = try store!.record(id: "legacy")!
    require(!original.isParameterized && original.source == "Original app" && original.text!.contains("<instance>"), "Legacy schema migrates without opting in or changing the template")
    require(SnippetParameters.names(in: "<instance> <instance> <region> <名> <> <not valid>") == ["instance", "region", "名"])
    let literal = try store!.recopy(id: original.id)
    require(literal.text == original.text && !literal.isParameterized)
    try store!.setParameterized(id: original.id, enabled: true)
    let rendered = try store!.recopy(id: original.id, parameterValues: ["instance": "PROD$1\\path <region>", "region": ""])
    require(rendered.text == "run PROD$1\\path <region> and PROD$1\\path <region> / <region>", "Replacement is literal, repeatable and nonrecursive; blank leaves placeholder")
    require(rendered.source == original.source && !rendered.isSnippet && !rendered.isParameterized)
    let unchanged = try store!.record(id: original.id)!
    require(unchanged.isParameterized && unchanged.text == original.text && unchanged.capturedAt == original.capturedAt && unchanged.expiresAt == nil)
    let blank = try store!.recopy(id: original.id, parameterValues: [:])
    require(blank.text == original.text)
    let before = try store!.stats().historyCount
    do {
        _ = try store!.recopy(id: original.id, parameterValues: ["instance": String(repeating: "x", count: ClipStore.maximumTextBytes)])
        fatalError("Oversized rendered template accepted")
    } catch ClipStoreError.limit { }
    require(try store!.stats().historyCount == before)
    store = nil
    store = try ClipStore(directory: folder)
    require(try store!.record(id: original.id)!.isParameterized, "Opt-in survives restart")
    try store!.setParameterized(id: original.id, enabled: false)
    require(try store!.recopy(id: original.id, parameterValues: ["instance": "IGNORED"]).text == original.text)
    do { try store!.setParameterized(id: rendered.id, enabled: true); fatalError("History made parameterized") } catch ClipStoreError.invalidSnippet { }
    print("PASS: v1 migration, persisted opt-in, Unicode/repeated parameters, literal single-pass replacement, blank defaults, size limits and unchanged original template")
}
try verifySnippetParametersAndMigration()

func verifyParserStress() throws {
    let repeated = String(repeating: "<x>", count: ClipStore.maximumTextBytes / 3)
    var clock = ProcessInfo.processInfo.systemUptime
    require(SnippetParameters.names(in: repeated) == ["x"])
    let repeatedNamesMS = (ProcessInfo.processInfo.systemUptime - clock) * 1000
    clock = ProcessInfo.processInfo.systemUptime
    do { _ = try SnippetParameters.render(repeated, values: ["x": "abcdefgh"]); fatalError("Repeated expansion exceeded its byte limit") } catch ClipStoreError.limit { }
    let rejectedMS = (ProcessInfo.processInfo.systemUptime - clock) * 1000
    var unique = "", expected = 0
    while true {
        let token = "<p\(expected)>"
        if unique.utf8.count + token.utf8.count > ClipStore.maximumTextBytes { break }
        unique += token
        expected += 1
    }
    clock = ProcessInfo.processInfo.systemUptime
    let names = SnippetParameters.names(in: unique)
    let uniqueNamesMS = (ProcessInfo.processInfo.systemUptime - clock) * 1000
    require(names.count == expected)
    clock = ProcessInfo.processInfo.systemUptime
    let rendered = try SnippetParameters.render(unique, values: [:])
    let renderMS = (ProcessInfo.processInfo.systemUptime - clock) * 1000
    require(rendered == unique && rendered.utf8.count <= ClipStore.maximumTextBytes)
    print(String(format: "PARSER STRESS PASS: near1MiB repeated names %.1fms, over-limit expansion rejected %.1fms; %d unique fields names %.1fms/render %.1fms (UI form creation not tested)", repeatedNamesMS,rejectedMS,expected,uniqueNamesMS,renderMS))
}

if CommandLine.arguments.contains("--stress") { try verifyLargePayloadStress(); try verifyParserStress() }
