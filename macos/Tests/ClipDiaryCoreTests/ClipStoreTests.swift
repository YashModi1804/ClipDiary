import XCTest
import Foundation
import AppKit
import SQLite3
@testable import ClipDiaryCore

final class ClipStoreTests: XCTestCase {
    var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    func testExactRetentionBoundaryAndIndependentTextSnippet() throws {
        let store = try ClipStore(directory: directory)
        let now = Date()
        let item = try XCTUnwrap(store.addText("permanent example", source: "Test", now: now))
        try store.saveSnippet(item.id)
        XCTAssertEqual(try store.records(now: now.addingTimeInterval(ClipStore.retention - 0.1)).count, 1)
        XCTAssertTrue(try store.records(now: now.addingTimeInterval(ClipStore.retention)).isEmpty)
        try store.purge(now: now.addingTimeInterval(ClipStore.retention))
        XCTAssertEqual(try store.stats().historyCount, 0)
        let snippet = try XCTUnwrap(store.records(snippets: true).first)
        XCTAssertNotEqual(snippet.id, item.id)
        XCTAssertNil(snippet.expiresAt)
        XCTAssertEqual(snippet.text, item.text)
    }

    func testImageSnippetAssetsSurviveSourceExpiryAndRestart() throws {
        let now = Date()
        let data = try imageData()
        var store: ClipStore? = try ClipStore(directory: directory)
        let original = try XCTUnwrap(store!.addImage(data: data, title: "Shot", source: "Screenshot", now: now))
        try store!.saveSnippet(original.id)
        let snippet = try XCTUnwrap(store!.records(snippets: true).first)
        XCTAssertNotEqual(snippet.assetPath, original.assetPath)
        XCTAssertNotEqual(snippet.thumbnailPath, original.thumbnailPath)
        try store!.purge(now: now.addingTimeInterval(ClipStore.retention))
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.assetPath!))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: snippet.assetPath!)), data)
        store = nil
        store = try ClipStore(directory: directory)
        XCTAssertEqual(try store!.records(snippets: true).count, 1)
        try store!.deleteAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: snippet.assetPath!))
        XCTAssertFalse(FileManager.default.fileExists(atPath: snippet.thumbnailPath!))
    }

    func testDurableTextSearchDeletionAndLiteralQuery() throws {
        var store: ClipStore? = try ClipStore(directory: directory)
        _ = try store!.addText("HELLO Unicode café 100%", source: "Test")
        try store!.createSnippet(title: "Keep", text: "text")
        store = nil
        store = try ClipStore(directory: directory)
        XCTAssertEqual(try store!.records(query: "hello").count, 1)
        XCTAssertTrue(try store!.records(query: "' OR 1=1 --").isEmpty)
        XCTAssertEqual(try store!.records(query: "%").count, 1)
        try store!.clearHistory()
        XCTAssertTrue(try store!.records().isEmpty)
        XCTAssertEqual(try store!.records(snippets: true).count, 1)
        try store!.deleteAll()
        XCTAssertEqual(try store!.stats().bytes, 0)
    }

    func testDuplicateCaptureDoesNotRefreshExpiryAndLaterCopyIsNewEvent() throws {
        let store = try ClipStore(directory: directory)
        let now = Date()
        let first = try XCTUnwrap(store.addText("same", source: "A", now: now))
        let duplicate = try XCTUnwrap(store.addText("same", source: "A", now: now.addingTimeInterval(1)))
        XCTAssertEqual(first.id, duplicate.id)
        XCTAssertEqual(first.expiresAt, duplicate.expiresAt)
        let later = try XCTUnwrap(store.addText("same", source: "A", now: now.addingTimeInterval(3)))
        XCTAssertNotEqual(first.id, later.id)
    }

    func testInvalidImageAndTextLimitsDoNotWriteRows() throws {
        let store = try ClipStore(directory: directory)
        XCTAssertThrowsError(try store.addImage(data: Data("broken".utf8), title: "Bad", source: "Test"))
        XCTAssertThrowsError(try store.addText(String(repeating: "x", count: ClipStore.maximumTextBytes + 1), source: "Test"))
        XCTAssertEqual(try store.stats().historyCount, 0)
    }

    func testStartupRemovesOrphansWithoutReimport() throws {
        var store: ClipStore? = try ClipStore(directory: directory)
        let orphan = directory.appendingPathComponent("Assets/orphan.png")
        try Data([1,2,3]).write(to: orphan)
        store = nil
        store = try ClipStore(directory: directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertEqual(try store!.stats().historyCount, 0)
    }

    func testEditingSnippetDoesNotChangeHistory() throws {
        let store = try ClipStore(directory: directory)
        let original = try XCTUnwrap(store.addText("original", source: "Test"))
        try store.saveSnippet(original.id)
        let snippet = try XCTUnwrap(store.records(snippets: true).first)
        try store.updateSnippet(id: snippet.id, title: "Edited", text: "changed")
        XCTAssertEqual(try store.records().first?.text, "original")
        XCTAssertEqual(try store.records(snippets: true).first?.text, "changed")
        try store.delete(id: snippet.id)
        XCTAssertEqual(try store.records().count, 1)
    }

    func testMissingImageOriginalReconciledOnRestart() throws {
        var store: ClipStore? = try ClipStore(directory: directory)
        let item = try XCTUnwrap(store!.addImage(data: imageData(), title: "Shot", source: "Test"))
        try FileManager.default.removeItem(atPath: item.assetPath!)
        store = nil
        store = try ClipStore(directory: directory)
        XCTAssertTrue(try store!.records().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.thumbnailPath!))
    }

    func testWhitespaceAndSeparateScreenshotEvents() throws {
        let store = try ClipStore(directory: directory)
        let text = "  leading\ntrailing  "
        XCTAssertEqual(try store.addText(text, source: "Test")?.text, text)
        let data = try imageData()
        let first = try store.addImage(data: data, title: "One", source: "Screenshot folder", deduplicate: false)
        let second = try store.addImage(data: data, title: "Two", source: "Screenshot folder", deduplicate: false)
        XCTAssertNotEqual(first?.id, second?.id)
    }

    func testNewerSchemaRejectedWithoutRewritingVersion() throws {
        var store: ClipStore? = try ClipStore(directory: directory)
        store = nil
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("history.sqlite3").path, &raw), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(raw, "PRAGMA user_version=99", nil, nil, nil), SQLITE_OK)
        sqlite3_close(raw)
        XCTAssertThrowsError(try ClipStore(directory: directory))
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("history.sqlite3").path, &raw), SQLITE_OK)
        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(raw, "PRAGMA user_version", -1, &stmt, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(stmt, 0), 99)
        sqlite3_finalize(stmt); sqlite3_close(raw)
    }

    func testImageAssetsSurviveSymbolicLinkAndRealDirectoryReopens() throws {
        let real = directory.appendingPathComponent("Real")
        let link = directory.appendingPathComponent("Alias")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        var store: ClipStore? = try ClipStore(directory: link)
        let bytes = try imageData()
        let image = try XCTUnwrap(store!.addImage(data: bytes, title: "Shot", source: "Test"))
        try store!.saveSnippet(image.id)
        let snippet = try XCTUnwrap(store!.records(snippets: true).first)
        store = nil
        store = try ClipStore(directory: real)
        XCTAssertEqual(try store!.records(snippets: true).first?.id, snippet.id)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: snippet.assetPath!)), bytes)
        store = nil
        store = try ClipStore(directory: link)
        XCTAssertTrue(FileManager.default.fileExists(atPath: snippet.thumbnailPath!))
        try store!.clearHistory()
        XCTAssertTrue(FileManager.default.fileExists(atPath: snippet.assetPath!))
    }

    private func imageData() throws -> Data {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
}
