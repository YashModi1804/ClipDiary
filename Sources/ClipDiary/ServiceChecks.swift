import AppKit
import ClipDiaryCore
import ImageIO
import Darwin
import SQLite3

/// Opt-in integration checks. Never reads or changes the user's general clipboard.
@MainActor
func runServiceChecks() async -> Int32 {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ClipDiary-ServiceChecks-\(UUID().uuidString)")
    let suite = "ClipDiary.ServiceChecks.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let board = NSPasteboard.withUniqueName()
    var service: CaptureService?
    defer {
        service?.stop()
        board.releaseGlobally()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
    var passed = 0
    func check(_ condition: Bool, _ label: String) throws {
        guard condition else { throw CheckFailure(message: label) }
        passed += 1
        print("PASS: \(label)")
    }
    func waitForImages(_ capture: CaptureService) async throws {
        let deadline = Date().addingTimeInterval(5)
        while capture.isPreparingImages && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard !capture.isPreparingImages else { throw CheckFailure(message: "Image preparation timed out") }
    }
    func writeText(_ text: String) {
        board.clearContents()
        board.setString(text, forType: .string)
    }
    do {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try ClipStore(directory: root.appendingPathComponent("Store"))
        writeText("Synthetic startup clipboard")
        let capture = CaptureService(store: store, onChange: {}, pasteboard: board, defaults: defaults)
        service = capture
        capture.start()
        capture.importNow()
        try check(try store.records().isEmpty, "Startup does not ingest existing clipboard")
        try await runCaptureLifecycleChecks(root: root, suite: suite, check: check)
        try await runScreenshotReliabilityChecks(root: root, suite: suite, check: check)

        writeText("Synthetic Unicode 😀\nsecond line")
        capture.importNow()
        try check(try store.records().first?.text == "Synthetic Unicode 😀\nsecond line", "Changed text preserves Unicode and line breaks")
        writeText("Synthetic own write")
        capture.markOwnWrite()
        capture.importNow()
        try check(try store.records().count == 1, "Own clipboard write is suppressed")

        capture.paused = true
        writeText("Synthetic paused secret")
        capture.importNow()
        capture.paused = false
        capture.importNow()
        try check(try store.records().count == 1, "Pause and resume rebaseline without capturing paused content")

        writeText("Synthetic sensitive content")
        board.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        capture.importNow()
        try check(try store.records().count == 1, "Concealed clipboard marker is excluded")

        let image = try fixturePNG(red: 200)
        board.clearContents()
        board.setData(image, forType: .png)
        capture.importNow()
        try await waitForImages(capture)
        try check(try store.records(kind: .image).count == 1, "Synthetic clipboard image is persisted")

        let folder = root.appendingPathComponent("Screenshots")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let old = folder.appendingPathComponent("existing.png")
        try image.write(to: old)
        try capture.configureScreenshotFolder(folder)
        capture.importNow()
        try check(try store.records(kind: .image).count == 1, "Initial folder selection skips existing images")

        try await Task.sleep(nanoseconds: 100_000_000)
        let newFile = folder.appendingPathComponent("new.png")
        try fixturePNG(red: 40).write(to: newFile)
        // Measure from the completed write, excluding macOS's floating-thumbnail delay.
        let fileCompletedAt = ProcessInfo.processInfo.systemUptime
        let importDeadline = fileCompletedAt + 2
        while try store.records(kind: .image).count < 2, ProcessInfo.processInfo.systemUptime < importDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let importLatency = ProcessInfo.processInfo.systemUptime - fileCompletedAt
        print(String(format: "MEASURE: completed screenshot file to stored item %.3f seconds", importLatency))
        let imported = try store.records(kind: .image)
        try check(imported.count == 2 && importLatency <= 1, "Directory watcher imports screenshot within one second without clipboard copy")
        let screenshotData = try Data(contentsOf: newFile)
        guard let screenshotTIFF = NSImage(data: screenshotData)?.tiffRepresentation else { throw CheckFailure(message: "TIFF fixture representation") }
        board.clearContents()
        board.setData(screenshotTIFF, forType: .tiff)
        capture.importNow()
        try await waitForImages(capture)
        try check(try store.records(kind: .image).count == 2, "Same screenshot arriving as TIFF clipboard and PNG file is paired once")
        guard let saved = imported.first(where: { $0.source == "Screenshot folder" }) else { throw CheckFailure(message: "Screenshot source label") }
        try store.saveSnippet(saved.id)
        try store.purge(now: Date().addingTimeInterval(ClipStore.retention + 10))
        try check(try store.records().isEmpty, "96-hour expiry purges history")
        try check(try store.records(snippets: true).count == 1, "Image snippet survives history expiry")
        try check(FileManager.default.fileExists(atPath: newFile.path), "Retention preserves the user's original screenshot")
        capture.importNow()
        try await Task.sleep(nanoseconds: 700_000_000)
        capture.importNow()
        try check(try store.records().isEmpty, "Consumed screenshot is not reimported after purge")

        capture.stop()
        let restored = CaptureService(store: store, onChange: {}, pasteboard: board, defaults: defaults)
        service = restored
        restored.start()
        restored.importNow()
        try await Task.sleep(nanoseconds: 700_000_000)
        restored.importNow()
        try check(try store.records().isEmpty, "Durable screenshot ledger prevents reimport after restart")

        restored.stop()
        let downtime = folder.appendingPathComponent("downtime.png")
        try fixturePNG(red: 150).write(to: downtime)
        let recovered = CaptureService(store: store, onChange: {}, pasteboard: board, defaults: defaults)
        service = recovered
        recovered.paused = false // Mirrors the application model's startup assignment.
        recovered.start()
        try await Task.sleep(nanoseconds: 950_000_000)
        try check(try store.records().count == 1, "Restart reconciles new eligible screenshots created while the app was stopped")
        try store.clearHistory()

        recovered.paused = true
        let pausedFile = folder.appendingPathComponent("paused.png")
        try fixturePNG(red: 90).write(to: pausedFile)
        recovered.paused = false
        recovered.importNow()
        try await Task.sleep(nanoseconds: 700_000_000)
        recovered.importNow()
        try check(try store.records().isEmpty, "Screenshot created while paused is not imported on resume")
        board.clearContents()
        board.setData(try fixturePNG(red: 77), forType: .png)
        recovered.importNow()
        recovered.paused = true
        try await waitForImages(recovered)
        try check(try store.records().isEmpty, "Pause invalidates an image already queued for preparation")
        recovered.paused = false

        board.clearContents()
        board.setData(try fixturePNG(red: 78), forType: .png)
        recovered.importNow()
        recovered.invalidatePendingImports()
        try store.clearHistory()
        try await waitForImages(recovered)
        try check(try store.records().isEmpty, "Clear history invalidates queued image writes")

        board.clearContents()
        board.setData(try fixturePNG(red: 79), forType: .png)
        recovered.importNow()
        recovered.stop()
        try await waitForImages(recovered)
        try check(try store.records().isEmpty, "Stop invalidates queued image writes")
        recovered.start()
        board.clearContents()
        board.setData(try largeFixturePNG(), forType: .png)
        recovered.importNow()
        try check(recovered.isPreparingImages, "Large image preparation is scheduled asynchronously")
        try await waitForImages(recovered)
        try check(try store.records(kind: .image).count == 1, "12-megapixel image completes capture through the bounded worker")
        let autoFolder = root.appendingPathComponent("AutoScreenshots")
        try FileManager.default.createDirectory(at: autoFolder, withIntermediateDirectories: true)
        let recentAuto = autoFolder.appendingPathComponent("existing-screen-capture.png")
        try fixturePNG(red: 31).write(to: recentAuto)
        try markScreenshot(recentAuto)
        let unrelated = autoFolder.appendingPathComponent("Screenshot 2026-10-18 at 12.00.00.png")
        try fixturePNG(red: 32).write(to: unrelated)
        let expiredAuto = autoFolder.appendingPathComponent("expired-screen-capture.png")
        try fixturePNG(red: 34).write(to: expiredAuto)
        try markScreenshot(expiredAuto)
        try FileManager.default.setAttributes([.creationDate: Date().addingTimeInterval(-ClipStore.retention - 60)], ofItemAtPath: expiredAuto.path)
        let autoSuite = suite + ".Auto"
        let autoDefaults = UserDefaults(suiteName: autoSuite)!
        defer { autoDefaults.removePersistentDomain(forName: autoSuite) }
        let autoStore = try ClipStore(directory: root.appendingPathComponent("AutoStore"))
        let auto = CaptureService(store: autoStore, onChange: {}, pasteboard: board, defaults: autoDefaults, autoDetectScreenshots: true, automaticScreenshotDestination: autoFolder)
        defer { auto.stop() }
        auto.start()
        try await Task.sleep(nanoseconds: 800_000_000)
        try await waitForImages(auto)
        try check(auto.screenshotFolder == autoFolder, "Automatic mode uses injected screenshot destination without Desktop access")
        try check(try autoStore.records().map(\.title) == [recentAuto.lastPathComponent], "Automatic backfill imports only tagged screenshots within96hours")
        let delayed = autoFolder.appendingPathComponent("delayed-tag.png")
        try fixturePNG(red: 35).write(to: delayed)
        try await Task.sleep(nanoseconds: 100_000_000)
        try markScreenshot(delayed)
        try await Task.sleep(nanoseconds: 800_000_000)
        try await waitForImages(auto)
        try check(try autoStore.records().count == 2, "Automatic mode retries delayed screen-capture metadata")
        let partial = autoFolder.appendingPathComponent("partial-write.png")
        let partialData = try fixturePNG(red: 36)
        try partialData.prefix(8).write(to: partial)
        try markScreenshot(partial)
        try await Task.sleep(nanoseconds: 300_000_000)
        try check(try autoStore.records().count == 2, "Partial screenshot bytes are not admitted to history")
        try partialData.write(to: partial)
        try markScreenshot(partial)
        let completedPartial = ProcessInfo.processInfo.systemUptime
        while try autoStore.records().count < 3, ProcessInfo.processInfo.systemUptime - completedPartial < 2 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try check(try autoStore.records().count == 3, "Screenshot import retries successfully after a partial write completes")
        let largeScreenshot = autoFolder.appendingPathComponent("large-screen-capture.png")
        let largeScreenshotData = try largeFixturePNG()
        try largeScreenshotData.write(to: largeScreenshot)
        let largeFileCompletedAt = ProcessInfo.processInfo.systemUptime
        try markScreenshot(largeScreenshot)
        while try autoStore.records().count < 4, ProcessInfo.processInfo.systemUptime - largeFileCompletedAt < 2 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let largeFileLatency = ProcessInfo.processInfo.systemUptime - largeFileCompletedAt
        print(String(format: "MEASURE: completed12MP screenshot file to stored item %.3f seconds", largeFileLatency))
        try check(try autoStore.records().count == 4 && largeFileLatency <= 1, "12-megapixel screenshot imports within one second after completed save")
        auto.invalidatePendingImports()
        try autoStore.clearHistory()
        auto.stop()
        let restartedAuto = CaptureService(store: autoStore, onChange: {}, pasteboard: board, defaults: autoDefaults, autoDetectScreenshots: true, automaticScreenshotDestination: autoFolder)
        defer { restartedAuto.stop() }
        restartedAuto.start()
        try await Task.sleep(nanoseconds: 800_000_000)
        try await waitForImages(restartedAuto)
        try check(try autoStore.records().isEmpty, "Automatic mode and consumed ledger survive restart without reimport")
        try check(FileManager.default.fileExists(atPath: recentAuto.path) && FileManager.default.fileExists(atPath: unrelated.path), "Automatic ingestion leaves screenshot and unrelated originals untouched")
        let inaccessibleSuite = suite + ".Unavailable"
        let inaccessibleDefaults = UserDefaults(suiteName: inaccessibleSuite)!
        defer { inaccessibleDefaults.removePersistentDomain(forName: inaccessibleSuite) }
        let inaccessible = CaptureService(store: autoStore, onChange: {}, pasteboard: board, defaults: inaccessibleDefaults, autoDetectScreenshots: true, automaticScreenshotDestination: root.appendingPathComponent("DoesNotExist"))
        defer { inaccessible.stop() }
        inaccessible.start()
        try check(inaccessible.screenshotFolder == nil && inaccessible.screenshotStatus.contains("Allow folder access"), "Unavailable automatic destination provides actionable access status")
        try await runRecopyModelChecks(root: root, suite: suite, check: check)
        try runParameterModelChecks(root: root, suite: suite, check: check)
        try check(runNativeEditorChecks(), "Native snippet editor supports undo/redo and standard Edit menu commands")
        print("Service checks passed: \(passed)")
        return 0
    } catch {
        print("Service checks failed after \(passed) passes: \(error.localizedDescription)")
        return 1
    }
}

private struct CheckFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private func fixturePNG(red: UInt8) throws -> Data {
    let pixels: [UInt8] = [red, 20, 80, 255, red, 60, 80, 255, red, 90, 80, 255, red, 120, 80, 255]
    let bytes = Data(pixels)
    guard let provider = CGDataProvider(data: bytes as CFData),
          let image = CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw CheckFailure(message: "Image fixture creation") }
    let output = NSMutableData()
    guard let target = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else { throw CheckFailure(message: "Image fixture encoding") }
    CGImageDestinationAddImage(target, image, nil)
    guard CGImageDestinationFinalize(target) else { throw CheckFailure(message: "Image fixture encoding") }
    return output as Data
}

private func largeFixturePNG() throws -> Data {
    guard let context = CGContext(data: nil, width: 4_000, height: 3_000, bitsPerComponent: 8, bytesPerRow: 16_000, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CheckFailure(message: "Large image fixture allocation") }
    context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 4_000, height: 3_000))
    guard let image = context.makeImage() else { throw CheckFailure(message: "Large image fixture creation") }
    let data = NSMutableData()
    guard let target = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { throw CheckFailure(message: "Large image fixture encoding") }
    CGImageDestinationAddImage(target, image, nil)
    guard CGImageDestinationFinalize(target) else { throw CheckFailure(message: "Large image fixture encoding") }
    return data as Data
}

private func markScreenshot(_ url: URL) throws {
    let data = try PropertyListSerialization.data(fromPropertyList: true, format: .binary, options: 0)
    let result = data.withUnsafeBytes { bytes in
        setxattr(url.path, "com.apple.metadata:kMDItemIsScreenCapture", bytes.baseAddress, data.count, 0, 0)
    }
    if result != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}

/// Exercises the exact model method shared by row Copy and the panel's Cmd+C action.
@MainActor
private func runRecopyModelChecks(root: URL, suite: String, check: (Bool, String) throws -> Void) async throws {
    let modelSuite = suite + ".RecopyModel"
    let preferences = UserDefaults(suiteName: modelSuite)!
    let board = NSPasteboard.withUniqueName()
    let directory = root.appendingPathComponent("RecopyModelStore")
    let store = try ClipStore(directory: directory)
    let model = DiaryModel(store: store, preferences: preferences, pasteboard: board)
    let capture = CaptureService(store: store, onChange: {}, pasteboard: board, defaults: preferences)
    model.capture = capture
    capture.start()
    defer {
        capture.stop()
        board.releaseGlobally()
        preferences.removePersistentDomain(forName: modelSuite)
    }
    var copied = 0
    var refreshedBeforeClose = false
    model.onCopy = { [weak model] in
        copied += 1
        refreshedBeforeClose = model?.records.last?.id == model?.selectedID
    }
    let old = Date().addingTimeInterval(-3_600)
    guard let text = try store.addText("Synthetic original text 😀", source: "com.synthetic.OriginalEditor", now: old),
          let newer = try store.addText("Synthetic newer text", source: "com.synthetic.SecondEditor", now: old.addingTimeInterval(60)) else { throw CheckFailure(message: "Recopy text fixtures") }
    model.refresh()
    model.selectedID = text.id
    let copiedAt = Date()
    model.copySelected()
    guard let promotedText = try store.record(id: text.id) else { throw CheckFailure(message: "Promoted text record missing") }
    try check(board.string(forType: .string) == text.text && copied == 1 && refreshedBeforeClose, "Shared Copy action writes text and refreshes newest row before closing")
    try check(promotedText.id == text.id && promotedText.source == text.source && promotedText.title == text.title && promotedText.text == text.text && promotedText.byteCount == text.byteCount, "Text recopy preserves identity, original source, title and contents")
    try check(promotedText.capturedAt >= copiedAt && promotedText.expiresAt.map { abs($0.timeIntervalSince(promotedText.capturedAt) - ClipStore.retention) <= 0.000001 } == true && model.records.last?.id == text.id && model.records.first?.id == newer.id, "Text recopy renews96hours and becomes the bottom/latest row")
    capture.importNow()
    try await Task.sleep(nanoseconds: 600_000_000)
    try check(try store.records().count == 2, "Polling after model text copy creates no duplicate history row")

    guard let image = try store.addImage(data: fixturePNG(red: 91), title: "Original screenshot", source: "com.synthetic.ScreenCapture", now: old.addingTimeInterval(120)) else { throw CheckFailure(message: "Recopy image fixture") }
    model.refresh()
    model.selectedID = image.id
    model.copySelected()
    guard let promotedImage = try store.record(id: image.id) else { throw CheckFailure(message: "Promoted image record missing") }
    try check(board.canReadObject(forClasses: [NSImage.self], options: nil) && promotedImage.source == image.source && promotedImage.title == image.title, "Shared Copy action writes image and preserves its original source")
    try check(promotedImage.assetPath == image.assetPath && promotedImage.thumbnailPath == image.thumbnailPath && promotedImage.byteCount == image.byteCount && promotedImage.capturedAt > image.capturedAt && model.records.last?.id == image.id, "Image recopy reuses its assets and moves the existing row to latest")
    capture.importNow()
    try await Task.sleep(nanoseconds: 600_000_000)
    try check(try store.records().count == 3, "Polling after model image copy creates no duplicate history row")
    let reopenedStore = try ClipStore(directory: directory)
    let reopened = DiaryModel(store: reopenedStore, preferences: preferences, pasteboard: board)
    try check(reopened.records.last?.id == image.id && reopened.records.last?.source == image.source, "Recopy order and original source persist when the model reloads local storage")

    model.paused = true
    capture.excludedBundleIDs.insert(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "")
    model.selectedID = text.id
    model.copySelected()
    try check(board.string(forType: .string) == text.text && model.records.last?.id == text.id && capture.paused && copied == 3, "Explicit Copy remains active while background capture is paused and excluded")
    model.paused = false
    capture.excludedBundleIDs = []

    try store.saveSnippet(text.id, title: "Permanent text")
    guard let textSnippet = try store.records(snippets: true).first(where: { $0.kind == .text }) else { throw CheckFailure(message: "Text snippet fixture") }
    let historyBeforeSnippet = try store.records().count
    model.snippets = true
    model.selectedID = textSnippet.id
    model.copySelected()
    guard let snippetAfter = try store.record(id: textSnippet.id), let snippetHistory = try store.records().first else { throw CheckFailure(message: "Text snippet recopy results") }
    try check(snippetHistory.id != textSnippet.id && !snippetHistory.isSnippet && snippetHistory.source == textSnippet.source && snippetHistory.text == textSnippet.text && snippetHistory.title == textSnippet.title && (try store.records().count) == historyBeforeSnippet + 1, "Copying a text snippet creates one fresh history item with original source")
    try check(snippetAfter.isSnippet && snippetAfter.expiresAt == nil && snippetAfter.capturedAt == textSnippet.capturedAt && snippetAfter.text == textSnippet.text, "Text snippet remains permanent and unchanged after Copy")
    model.snippets = false
    try check(model.records.last?.id == snippetHistory.id, "Copied snippet appears at the bottom/latest of ordinary history")

    try store.saveSnippet(image.id, title: "Permanent image")
    guard let imageSnippet = try store.records(snippets: true).first(where: { $0.kind == .image }) else { throw CheckFailure(message: "Image snippet fixture") }
    model.snippets = true
    model.selectedID = imageSnippet.id
    model.copySelected()
    guard let imageHistory = try store.records().first,
          let snippetAsset = imageSnippet.assetPath,
          let historyAsset = imageHistory.assetPath,
          let imageSnippetAfter = try store.record(id: imageSnippet.id) else { throw CheckFailure(message: "Image snippet recopy results") }
    try check(imageHistory.id != imageSnippet.id && historyAsset != snippetAsset && imageHistory.source == imageSnippet.source && (try Data(contentsOf: URL(fileURLWithPath: historyAsset))) == (try Data(contentsOf: URL(fileURLWithPath: snippetAsset))), "Copied image snippet gets independent image assets and preserved source")
    try check(imageSnippetAfter.capturedAt == imageSnippet.capturedAt && imageSnippetAfter.expiresAt == nil && imageSnippetAfter.assetPath == snippetAsset, "Image snippet timestamp and permanent asset remain unchanged")
    let beforePoll = try store.records().count
    capture.importNow()
    try await Task.sleep(nanoseconds: 600_000_000)
    try check(try store.records().count == beforePoll, "Polling after copying a snippet does not add a second history item")
    try store.delete(id: imageHistory.id)
    try check(FileManager.default.fileExists(atPath: snippetAsset) && !FileManager.default.fileExists(atPath: historyAsset), "Deleting copied image history leaves the permanent snippet intact")

    model.snippets = false
    model.selectedID = text.id
    guard let beforeFailure = try store.record(id: text.id) else { throw CheckFailure(message: "Failure-path text fixture") }
    try executeFixtureSQL("CREATE TRIGGER synthetic_recopy_failure BEFORE UPDATE OF captured ON clips BEGIN SELECT RAISE(ABORT, 'synthetic recopy failure'); END", directory: directory)
    defer { try? executeFixtureSQL("DROP TRIGGER IF EXISTS synthetic_recopy_failure", directory: directory) }
    let successfulBeforeFailure = copied
    model.message = nil
    model.copySelected()
    try check(board.string(forType: .string) == text.text && copied == successfulBeforeFailure && model.message?.contains("Copied successfully") == true && model.message?.contains("history update") == true, "Database failure after clipboard success reports partial success and keeps the panel open")
    try check(try store.record(id: text.id)?.capturedAt == beforeFailure.capturedAt, "Failed history promotion leaves the previous timestamp intact")
    try executeFixtureSQL("DROP TRIGGER synthetic_recopy_failure", directory: directory)

    model.selectedID = newer.id
    try store.delete(id: newer.id)
    let boardBeforeMissing = board.changeCount
    model.copySelected()
    try check(board.changeCount == boardBeforeMissing && copied == successfulBeforeFailure && model.message?.contains("expired or was removed") == true, "Removed selection is not copied, replaced or resurrected")
    guard let expired = try store.addText("Synthetic expired selection", source: "com.synthetic.Expired", now: Date().addingTimeInterval(-ClipStore.retention - 60)) else { throw CheckFailure(message: "Expired recopy fixture") }
    model.selectedID = expired.id
    let boardBeforeExpiry = board.changeCount
    model.copySelected()
    try check(board.changeCount == boardBeforeExpiry && (try store.record(id: expired.id)) == nil, "Expired selection is not copied or resurrected")
    capture.invalidatePendingImports()
    try store.purge(now: Date().addingTimeInterval(ClipStore.retention + 10))
    try check(try store.records().isEmpty && store.records(snippets: true).count == 2 && FileManager.default.fileExists(atPath: snippetAsset), "Recopied history expiry leaves both permanent snippets intact")
}

private func executeFixtureSQL(_ sql: String, directory: URL) throws {
    var database: OpaquePointer?
    let result = sqlite3_open(directory.appendingPathComponent("history.sqlite3").path, &database)
    guard result == SQLITE_OK, let database else { throw CheckFailure(message: "Synthetic database connection") }
    defer { sqlite3_close(database) }
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw CheckFailure(message: "Synthetic database fault setup") }
}

@MainActor
private func runParameterModelChecks(root: URL, suite: String, check: (Bool, String) throws -> Void) throws {
    let preferences = UserDefaults(suiteName: suite + ".Parameters")!
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally(); preferences.removePersistentDomain(forName: suite + ".Parameters") }
    let store = try ClipStore(directory: root.appendingPathComponent("ParameterStore"))
    let model = DiaryModel(store: store, preferences: preferences, pasteboard: board)
    try store.createSnippet(title: "Command", text: "connect <instance> / <region> / <instance>")
    let snippet = try store.records(snippets: true).first!
    model.snippets = true
    model.selectedID = snippet.id
    var prompts: [[String]] = [], copies = 0
    model.onParameters = { _, names in prompts.append(names) }
    model.onCopy = { copies += 1 }
    model.copySelected()
    try check(prompts.isEmpty && board.string(forType: .string) == snippet.text, "Plain snippets with angle brackets copy literally until opted in")
    try store.setParameterized(id: snippet.id, enabled: true)
    model.selectedID = snippet.id
    let boardBeforePrompt = board.changeCount, historyBeforePrompt = try store.records().count
    model.copySelected()
    try check(prompts == [["instance", "region"]] && board.changeCount == boardBeforePrompt && (try store.records().count) == historyBeforePrompt && copies == 1, "Parameterized copy prompts once per unique name without copying before confirmation")
    // Cancel simply closes the prompt: no copySelected(values:) call, so no history or clipboard change.
    try check(board.changeCount == boardBeforePrompt && (try store.records().count) == historyBeforePrompt, "Cancelling the parameter prompt leaves clipboard and history unchanged")
    model.copySelected(parameterValues: ["instance": "PROD", "region": ""])
    let latest = try store.records().first!
    try check(board.string(forType: .string) == "connect PROD / <region> / PROD" && latest.text == board.string(forType: .string) && latest.source == snippet.source && !latest.isParameterized && copies == 2, "Confirmed parameter values replace repeated tokens and history captures exact copied result")
    let preserved = try store.record(id: snippet.id)!
    try check(preserved.text == snippet.text && preserved.isParameterized && preserved.expiresAt == nil, "Parameterized copy leaves the permanent template unchanged")
    model.copySelected(parameterValues: [:])
    try check(board.string(forType: .string) == snippet.text && copies == 3, "Confirming empty values copies original placeholders")
    let beforeOversize = board.changeCount
    model.copySelected(parameterValues: ["instance": String(repeating: "x", count: ClipStore.maximumTextBytes)])
    try check(board.changeCount == beforeOversize && copies == 3 && model.message != nil, "Oversized parameter expansion fails before altering the clipboard")
    model.message = nil
    _ = try store.addText("Old history", source: "First", now: Date().addingTimeInterval(-60))
    model.snippets = false
    let expected = try store.records().first!.id
    try check(model.selectedID == expected && model.records.last?.id == expected, "Switching from Snippets to History selects the latest bottom item")
    model.selectedID = model.records.first?.id
    model.snippets = true
    model.snippets = false
    try check(model.selectedID == expected, "Repeated collection switches reset History to latest rather than the oldest row")
    model.selectedID = latest.id
    let promptCount = prompts.count
    model.copySelected()
    try check(prompts.count == promptCount && board.string(forType: .string) == latest.text, "Rendered history is ordinary text and never prompts for unresolved placeholders")
}

@MainActor
private func runCaptureLifecycleChecks(root: URL, suite: String, check: (Bool, String) throws -> Void) async throws {
    let serviceSuite = suite + ".Lifecycle"
    let preferences = UserDefaults(suiteName: serviceSuite)!
    let board = NSPasteboard.withUniqueName()
    let store = try ClipStore(directory: root.appendingPathComponent("LifecycleStore"))
    let capture = CaptureService(store: store, onChange: {}, pasteboard: board, defaults: preferences)
    capture.start()
    defer {
        capture.stop()
        board.releaseGlobally()
        preferences.removePersistentDomain(forName: serviceSuite)
    }
    board.clearContents()
    board.setData(try fixturePNG(red: 201), forType: .png)
    capture.importNow()
    do {
        try capture.configureScreenshotFolder(root.appendingPathComponent("UnavailableSelection"))
        throw CheckFailure(message: "Missing folder unexpectedly configured")
    } catch is CheckFailure { throw CheckFailure(message: "Missing folder unexpectedly configured") }
    catch { /* The pending copy must remain valid when selection fails. */ }
    let deadline = Date().addingTimeInterval(5)
    while capture.isPreparingImages && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
    try check(try store.records(kind: .image).count == 1, "Failed folder selection preserves an already-queued clipboard image")

    let incompletePNG = Data(try fixturePNG(red: 205).dropLast(12))
    board.clearContents()
    board.setData(incompletePNG, forType: .png)
    capture.importNow()
    let incompleteDeadline = Date().addingTimeInterval(5)
    while capture.isPreparingImages && Date() < incompleteDeadline { try await Task.sleep(nanoseconds: 10_000_000) }
    try check(try store.records().count == 1, "PNG data missing its terminal chunk is not persisted as a complete image")

    capture.setSuspended(true, reason: .screenLock)
    capture.setSuspended(true, reason: .sleep)
    capture.setSuspended(false, reason: .sleep)
    board.clearContents()
    board.setString("Synthetic still-locked copy", forType: .string)
    capture.importNow()
    try check(try store.records().count == 1, "Waking from sleep does not release an existing screen lock")
    capture.setSuspended(false, reason: .screenLock)
    capture.importNow()
    try check(try store.records().count == 1, "Unlock rebaselines content copied while the screen was locked")
    board.clearContents()
    board.setString("Synthetic unlocked copy", forType: .string)
    capture.importNow()
    try check(try store.records().count == 2, "Capture resumes after all suspension reasons clear")
    capture.setSuspended(true, reason: .inactiveSession)
    capture.setSuspended(true, reason: .sleep)
    capture.setSuspended(false, reason: .sleep)
    board.clearContents()
    board.setString("Synthetic other-session copy", forType: .string)
    capture.importNow()
    try check(try store.records().count == 2, "Wake cannot resume capture while the user session remains inactive")
    capture.setSuspended(false, reason: .inactiveSession)

    let folder = root.appendingPathComponent("LifecycleScreenshots")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try capture.configureScreenshotFolder(folder)
    let pairedBytes = try fixturePNG(red: 202)
    board.clearContents()
    board.setData(pairedBytes, forType: .png)
    capture.importNow()
    let pairedDeadline = Date().addingTimeInterval(5)
    while capture.isPreparingImages && Date() < pairedDeadline { try await Task.sleep(nanoseconds: 10_000_000) }
    guard let paired = try store.records().first(where: { $0.kind == .image && $0.source != "Screenshot folder" && $0.capturedAt > Date().addingTimeInterval(-1) }) else { throw CheckFailure(message: "Deleted pair fixture did not persist") }
    try store.delete(id: paired.id)
    let screenshot = folder.appendingPathComponent("after-deleted-clipboard.png")
    try pairedBytes.write(to: screenshot)
    let screenshotDeadline = Date().addingTimeInterval(3)
    while try !store.records().contains(where: { $0.title == screenshot.lastPathComponent }), Date() < screenshotDeadline {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    try check(try store.records().contains(where: { $0.title == screenshot.lastPathComponent }), "A deleted clipboard image cannot suppress a later screenshot as a duplicate")

    let original = root.appendingPathComponent("read-race.png")
    let sentinel = root.appendingPathComponent("unselected-image.png")
    let originalBytes = try fixturePNG(red: 203)
    let sentinelBytes = try fixturePNG(red: 204)
    try originalBytes.write(to: original)
    try sentinelBytes.write(to: sentinel)
    guard let snapshot = CaptureService.fileSnapshot(original, automatic: false) else { throw CheckFailure(message: "Read-race snapshot fixture") }
    try check(try CaptureService.readScreenshotData(original, expected: snapshot) == originalBytes, "A regular unchanged screenshot is read from its validated descriptor")
    try FileManager.default.removeItem(at: original)
    try FileManager.default.createSymbolicLink(at: original, withDestinationURL: sentinel)
    var symlinkRejected = false
    do { _ = try CaptureService.readScreenshotData(original, expected: snapshot) } catch { symlinkRejected = true }
    try check(symlinkRejected && (try Data(contentsOf: sentinel)) == sentinelBytes, "A file replaced by a symlink is rejected without reading or altering the target")
    try FileManager.default.removeItem(at: original)
    try sentinelBytes.write(to: original)
    var replacementRejected = false
    do { _ = try CaptureService.readScreenshotData(original, expected: snapshot) } catch { replacementRejected = true }
    try check(replacementRejected, "A different file substituted after the metadata scan is rejected")
    guard let modifiedSnapshot = CaptureService.fileSnapshot(original, automatic: false) else { throw CheckFailure(message: "Modified read-race fixture") }
    try originalBytes.write(to: original)
    var modifiedRejected = false
    do { _ = try CaptureService.readScreenshotData(original, expected: modifiedSnapshot) } catch { modifiedRejected = true }
    try check(modifiedRejected, "A screenshot changed after its stable metadata scan is retried")

    let corruptSuite = suite + ".CorruptBookmark"
    let corrupt = UserDefaults(suiteName: corruptSuite)!
    defer { corrupt.removePersistentDomain(forName: corruptSuite) }
    corrupt.set(Data([1, 2, 3]), forKey: "capture.screenshotBookmark")
    corrupt.set(false, forKey: "capture.screenshotAutomaticMode")
    let fallback = root.appendingPathComponent("UnrequestedAutomaticFolder")
    try FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
    let restored = CaptureService(store: store, onChange: {}, pasteboard: board, defaults: corrupt, autoDetectScreenshots: true, automaticScreenshotDestination: fallback)
    defer { restored.stop() }
    restored.start()
    try check(restored.screenshotFolder == nil && restored.screenshotStatus.contains("unavailable"), "Unreadable explicit bookmark does not enable automatic capture in another folder")
}

@MainActor
private func runScreenshotReliabilityChecks(root: URL, suite: String, check: (Bool, String) throws -> Void) async throws {
    let testSuite = suite + ".ScreenshotReliability"
    let preferences = UserDefaults(suiteName: testSuite)!
    let board = NSPasteboard.withUniqueName()
    let directory = root.appendingPathComponent("ScreenshotReliabilityStore")
    let store = try ClipStore(directory: directory)
    let capture = CaptureService(store: store, onChange: {}, pasteboard: board, defaults: preferences)
    capture.start()
    defer {
        capture.stop()
        board.releaseGlobally()
        preferences.removePersistentDomain(forName: testSuite)
    }
    func waitUntil(_ condition: () throws -> Bool, seconds: TimeInterval = 3) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while try !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
    }
    let selected = root.appendingPathComponent("AnchoredScreenshotFolder")
    let moved = root.appendingPathComponent("MovedAuthorizedFolder")
    try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
    let authorizedOriginal = selected.appendingPathComponent("original.png")
    let authorizedBytes = try fixturePNG(red: 211)
    try authorizedBytes.write(to: authorizedOriginal)
    try capture.configureScreenshotFolder(selected)
    try FileManager.default.moveItem(at: selected, to: moved)
    try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
    let replacement = selected.appendingPathComponent("unrequested.png")
    let replacementBytes = try fixturePNG(red: 212)
    try replacementBytes.write(to: replacement)
    capture.importNow()
    try await Task.sleep(nanoseconds: 500_000_000)
    capture.importNow()
    try await Task.sleep(nanoseconds: 100_000_000)
    try check(try store.records().isEmpty && capture.screenshotStatus.contains("replaced"), "Replacing the watched directory cannot redirect capture into an unselected folder")
    try check(try Data(contentsOf: moved.appendingPathComponent("original.png")) == authorizedBytes && Data(contentsOf: replacement) == replacementBytes, "Directory replacement rejection preserves both original and replacement files")
    try capture.configureScreenshotFolder(selected)
    let selectedNew = selected.appendingPathComponent("explicitly-selected.png")
    try fixturePNG(red: 213).write(to: selectedNew)
    try await waitUntil { try store.records().count == 1 }
    try check(try store.records().count == 1, "Explicitly selecting a replacement directory restores capture")
    let alias = root.appendingPathComponent("ScreenshotFolderAlias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: selected)
    try fixturePNG(red: 214).write(to: alias.appendingPathComponent("authorized-alias.png"))
    try await waitUntil { try store.records().count == 2 }
    try check(try store.records().count == 2, "Files created through a parent alias import only from the already-authorized target")

    let retryFolder = root.appendingPathComponent("RetryScreenshots")
    try FileManager.default.createDirectory(at: retryFolder, withIntermediateDirectories: true)
    try capture.configureScreenshotFolder(retryFolder)
    let retryFile = retryFolder.appendingPathComponent("retry-storage.png")
    let retryBytes = try fixturePNG(red: 215)
    try executeFixtureSQL("CREATE TRIGGER synthetic_screenshot_insert_failure BEFORE INSERT ON clips WHEN NEW.source='Screenshot folder' BEGIN SELECT RAISE(ABORT, 'synthetic screenshot storage failure'); END", directory: directory)
    defer { try? executeFixtureSQL("DROP TRIGGER IF EXISTS synthetic_screenshot_insert_failure", directory: directory) }
    try retryBytes.write(to: retryFile)
    try await waitUntil { capture.screenshotStatus.contains("synthetic screenshot storage failure") }
    let attemptsAfterFailure = capture.imagePreparationCount
    capture.importNow()
    try await Task.sleep(nanoseconds: 550_000_000)
    try check(capture.imagePreparationCount == attemptsAfterFailure && capture.screenshotStatus.contains("synthetic screenshot storage failure"), "Storage failures back off expensive screenshot preparation and remain visible across metadata scans")
    try executeFixtureSQL("DROP TRIGGER synthetic_screenshot_insert_failure", directory: directory)
    try await waitUntil({ try store.records().contains { $0.title == retryFile.lastPathComponent } }, seconds: 4)
    try check(try store.records().contains { $0.title == retryFile.lastPathComponent } && !capture.screenshotStatus.contains("synthetic screenshot storage failure"), "A deferred screenshot retries and clears its error after storage recovers")
    try check(try Data(contentsOf: retryFile) == retryBytes, "Storage retries never change the screenshot source file")

    let oversized = retryFolder.appendingPathComponent("oversized.png")
    FileManager.default.createFile(atPath: oversized.path, contents: nil)
    let handle = try FileHandle(forWritingTo: oversized)
    try handle.truncate(atOffset: UInt64(ClipStore.maximumImageBytes + 1))
    try handle.close()
    let beforeOversize = capture.imagePreparationCount
    try await waitUntil { capture.screenshotStatus.contains("25 MB") }
    try check(capture.screenshotStatus.contains("25 MB") && capture.imagePreparationCount == beforeOversize && FileManager.default.fileExists(atPath: oversized.path), "Oversized screenshots report their limit before decoding and preserve the original")
    try FileManager.default.removeItem(at: oversized)
    capture.importNow()
    try await waitUntil { !capture.screenshotStatus.contains("25 MB") }
    try check(!capture.screenshotStatus.contains("25 MB"), "Removing an oversized file clears its stale warning")
    let empty = retryFolder.appendingPathComponent("initially-empty.png")
    try Data().write(to: empty)
    let beforeEmpty = capture.imagePreparationCount
    try await waitUntil { capture.screenshotStatus.contains("finish writing") }
    try check(capture.screenshotStatus.contains("finish writing") && capture.imagePreparationCount == beforeEmpty, "An empty screenshot remains pending without unnecessary image decoding")
    let completedBytes = try fixturePNG(red: 216)
    try completedBytes.write(to: empty)
    capture.importNow()
    try await waitUntil { try store.records().contains { $0.title == empty.lastPathComponent } }
    try check(try store.records().contains { $0.title == empty.lastPathComponent }, "An initially empty screenshot imports after its write completes")

    let burst = try largeFixturePNG()
    let started = ProcessInfo.processInfo.systemUptime
    for index in 0..<12 { try burst.write(to: retryFolder.appendingPathComponent("burst-\(index).png")) }
    let burstDeadline = Date().addingTimeInterval(12)
    var peakQueue = 0
    while try store.records().filter({ $0.title.hasPrefix("burst-") }).count < 12, Date() < burstDeadline {
        peakQueue = max(peakQueue, capture.queuedImagePreparations)
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    let burstCount = try store.records().filter { $0.title.hasPrefix("burst-") }.count
    print(String(format: "MEASURE:12 x12MP screenshot burst %.3f seconds; peak preparation queue %d", ProcessInfo.processInfo.systemUptime - started, peakQueue))
    try check(burstCount == 12 && peakQueue <= 3, "A12-shot12-megapixel burst drains completely with at most three queued preparations")
}
