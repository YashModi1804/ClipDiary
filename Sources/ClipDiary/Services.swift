import AppKit
import Carbon
import ClipDiaryCore
import ImageIO
import CryptoKit
import Darwin

/// Observes only the current user's explicitly enabled local capture sources.
@MainActor
final class CaptureService {
    private let store: ClipStore
    private let onChange: () -> Void
    private var timer: Timer?
    private var running = false
    private var lastChange = 0
    enum SuspensionReason: Hashable { case sleep, inactiveSession, screenLock }
    private var suspensions: Set<SuspensionReason> = []
    private var locked: Bool { !suspensions.isEmpty }
    private var observers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var folderTicks = 0
    private var folderWatcher: DispatchSourceFileSystemObject?
    private var folderFollowup: DispatchWorkItem?
    private var scopedFolder: URL?
    private var ledger: Set<String> = []
    struct DirectoryIdentity: Equatable { let device: UInt64; let inode: UInt64 }
    private var watchedDirectory: DirectoryIdentity?
    private var pending: [String: String] = [:]
    private var failures: [String: Int] = [:]
    private var rejected: [String: String] = [:]
    private struct RetryState { let signature: String; let attempts: Int; let nextAttempt: Date }
    private var retries: [String: RetryState] = [:]
    private var itemIssues: [String: String] = [:]
    private var folderIssue: String?
    private struct ImageArrival {
        let digest: Data
        let folder: Bool
        let observedAt: Date
        let recordID: String
    }
    private var imageArrivals: [ImageArrival] = []
    private let imageQueue = DispatchQueue(label: "ClipDiary.imagePreparation", qos: .userInitiated, autoreleaseFrequency: .workItem)
    private var activePreparations = 0
    private(set) var imagePreparationCount = 0
    var queuedImagePreparations: Int { activePreparations }
    var isPreparingImages: Bool { activePreparations > 0 }
    private var generation: UInt64 = 0
    private var inFlightFiles: Set<String> = []
    private var tagPending: Set<String> = []
    private let metadataQueue = DispatchQueue(label: "ClipDiary.screenshotMetadata", qos: .userInitiated, autoreleaseFrequency: .workItem)
    private var metadataInProgress = false
    private var metadataRequested = false
    struct ScreenshotFile {
        let url: URL
        let identity: String
        let created: Date
        let modified: Date
        let size: Int
        let screenshot: Bool
        let device: UInt64
        let inode: UInt64
        let directory: DirectoryIdentity
    }
    private let autoDetectScreenshots: Bool
    private let automaticScreenshotDestination: URL?
    private var automaticMode = false
    private let automaticModeKey = "capture.screenshotAutomaticMode"
    private let automaticDisabledKey = "capture.screenshotAutomaticDisabled"
    private let defaults: UserDefaults
    private let pasteboard: NSPasteboard
    private let bookmarkKey = "capture.screenshotBookmark"
    private let bookmarkScopedKey = "capture.screenshotBookmarkScoped"
    private let ledgerKey = "capture.screenshotLedger"
    private let baselineKey = "capture.screenshotBaseline"
    private var folderBaseline = Date()
    private(set) var screenshotFolder: URL?
    private(set) var screenshotStatus = "Screenshot folder is off"
    private(set) var status = "Starting capture"
    var excludedBundleIDs: Set<String> = [] {
        didSet { if oldValue != excludedBundleIDs { advanceGeneration() } }
    }
    var paused = false {
        didSet {
            guard paused != oldValue else { return }
            advanceGeneration()
            lastChange = pasteboard.changeCount
            baselineWhilePaused()
            status = paused ? "Capture paused" : "Capture active"
            onChange()
        }
    }

    init(store: ClipStore, onChange: @escaping () -> Void, pasteboard: NSPasteboard = .general, defaults: UserDefaults = .standard, autoDetectScreenshots: Bool = false, automaticScreenshotDestination: URL? = nil) {
        self.store = store
        self.onChange = onChange
        self.pasteboard = pasteboard
        self.defaults = defaults
        self.autoDetectScreenshots = autoDetectScreenshots
        self.automaticScreenshotDestination = automaticScreenshotDestination
    }

    func start() {
        guard !running else { return }
        running = true
        lastChange = pasteboard.changeCount
        restoreFolder()
        configureAutomaticDestinationIfNeeded()
        startFolderWatcher()
        scheduleFolderScan()
        let center = NSWorkspace.shared.notificationCenter
        let workspaceEvents: [(Notification.Name, Bool, SuspensionReason)] = [
            (NSWorkspace.willSleepNotification, true, .sleep),
            (NSWorkspace.didWakeNotification, false, .sleep),
            (NSWorkspace.sessionDidResignActiveNotification, true, .inactiveSession),
            (NSWorkspace.sessionDidBecomeActiveNotification, false, .inactiveSession)
        ]
        for (name, value, reason) in workspaceEvents {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setSuspended(value, reason: reason) }
            })
        }
        let distributed = DistributedNotificationCenter.default()
        for (name, value) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            distributedObservers.append(distributed.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setSuspended(value, reason: .screenLock) }
            })
        }
        status = paused ? "Capture paused" : "Capture active"
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        onChange()
    }

    func stop() {
        running = false
        advanceGeneration()
        timer?.invalidate()
        timer = nil
        stopFolderWatcher()
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        distributedObservers.forEach(DistributedNotificationCenter.default().removeObserver)
        observers.removeAll()
        distributedObservers.removeAll()
        scopedFolder?.stopAccessingSecurityScopedResource()
        scopedFolder = nil
    }

    func markOwnWrite() { lastChange = pasteboard.changeCount }

    /// Call before clearing history so queued work cannot restore cleared items.
    func invalidatePendingImports() {
        advanceGeneration()
        lastChange = pasteboard.changeCount
        baselineWhilePaused()
    }

    private func advanceGeneration() {
        generation &+= 1
        metadataRequested = false
        inFlightFiles.removeAll()
        imageArrivals.removeAll()
    }

    func importNow() {
        guard running, !paused, !locked else { return }
        captureClipboard()
        scanFolder()
    }

    // Independent reasons prevent wake/session events from releasing a screen lock.
    func setSuspended(_ value: Bool, reason: SuspensionReason) {
        guard running, suspensions.contains(reason) != value else { return }
        if value { suspensions.insert(reason) } else { suspensions.remove(reason) }
        advanceGeneration()
        lastChange = pasteboard.changeCount
        baselineWhilePaused()
        if !locked { scheduleFolderScan() }
    }

    private func tick() {
        guard running else { return }
        if paused || locked {
            lastChange = pasteboard.changeCount
        } else {
            captureClipboard()
        }
        folderTicks += 1
        let now = Date()
        let pendingDue = pending.keys.contains { !inFlightFiles.contains($0) && (retries[$0]?.nextAttempt ?? .distantPast) <= now }
        if folderTicks >= 60 || pendingDue || !tagPending.isEmpty {
            if folderTicks >= 60 { folderTicks = 0 }
            if paused || locked { baselineWhilePaused() } else { scanFolder() }
        }
    }

    private func stopFolderWatcher() {
        folderFollowup?.cancel()
        folderFollowup = nil
        folderWatcher?.cancel()
        folderWatcher = nil
    }

    private func startFolderWatcher() {
        stopFolderWatcher()
        guard running, let folder = screenshotFolder else { return }
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return } // Timer provides a 30-second fallback.
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .extend, .attrib, .rename, .delete, .revoke], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.paused || self.locked { self.baselineWhilePaused() }
                else { self.scheduleFolderScan() }
            }
        }
        source.setCancelHandler { close(descriptor) }
        folderWatcher = source
        source.resume()
    }

    private func scheduleFolderScan() {
        guard running, !paused, !locked, screenshotFolder != nil else { return }
        scanFolder()
        folderFollowup?.cancel()
        let followup = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.paused, !self.locked else { return }
                self.scanFolder()
            }
        }
        folderFollowup = followup
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: followup)
    }

    private func captureClipboard() {
        let board = pasteboard
        let change = board.changeCount
        guard change != lastChange else { return }
        lastChange = change
        if #available(macOS 15.4, *), board.accessBehavior == .alwaysDeny {
            status = "Clipboard access denied in System Settings"
            onChange()
            return
        }
        let appID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard !excludedBundleIDs.contains(appID ?? "") else { return }
        let blocked = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType", "com.agilebits.onepassword"]
        guard !blocked.contains(where: { board.types?.contains(NSPasteboard.PasteboardType($0)) == true }) else { return }
        do {
            if let data = board.data(forType: .png) ?? board.data(forType: .tiff) {
                guard let png = Self.validatedPNG(data) else { status = "Image skipped: unsupported or too large"; onChange(); return }
                if !enqueueImage(png, date: Date(), source: appID) {
                    status = "Image capture busy; copy the image again"
                    onChange()
                }
                return
            } else if let text = board.string(forType: .string), !text.isEmpty {
                guard text.utf8.count <= ClipStore.maximumTextBytes else { status = "Text skipped: larger than 1 MB"; onChange(); return }
                try insertText(text, source: appID)
            } else { return }
            status = "Capture active"
        } catch { status = "Could not save clipboard item: \(error.localizedDescription)" }
        onChange()
    }

    nonisolated private static func validatedPNG(_ data: Data) -> Data? {
        // ImageIO can decode a truncated PNG without reporting an incomplete source.
        // A PNG is not finished until its zero-length IEND chunk has been written.
        let pngSignature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
        let pngEnd: [UInt8] = [0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130]
        if data.starts(with: pngSignature), !data.suffix(pngEnd.count).elementsEqual(pngEnd) { return nil }
        guard data.count <= ClipStore.maximumImageBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.int64Value > 0, height.int64Value > 0,
              width.int64Value <= Int64(ClipStore.maximumPixels) / height.int64Value else { return nil }
        // Keep original bytes; core validates decoding and makes a bounded thumbnail.
        return data
    }

    func configureScreenshotFolder(_ url: URL?) throws {
        try configureFolder(url, automatic: false)
    }

    private func configureAutomaticDestinationIfNeeded() {
        guard autoDetectScreenshots, !defaults.bool(forKey: automaticDisabledKey),
              defaults.data(forKey: bookmarkKey) == nil || automaticMode,
              screenshotFolder == nil || automaticMode else { return }
        let configured = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location")
        let discovered = configured.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
            ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        guard let folder = automaticScreenshotDestination ?? discovered else { return }
        if automaticMode, screenshotFolder?.standardizedFileURL == folder.standardizedFileURL { return }
        do { try configureFolder(folder, automatic: true) }
        catch { screenshotStatus = "Screenshot folder access unavailable. Allow folder access in System Settings → Privacy & Security, or choose a screenshot folder. \(error.localizedDescription)" }
    }

    private func configureFolder(_ url: URL?, automatic: Bool) throws {
        guard let url else {
            advanceGeneration()
            stopFolderWatcher()
            scopedFolder?.stopAccessingSecurityScopedResource()
            scopedFolder = nil
            screenshotFolder = nil
            watchedDirectory = nil
            automaticMode = false
            defaults.set(true, forKey: automaticDisabledKey)
            defaults.removeObject(forKey: automaticModeKey)
            defaults.removeObject(forKey: bookmarkKey)
            defaults.removeObject(forKey: bookmarkScopedKey)
            defaults.removeObject(forKey: ledgerKey)
            defaults.removeObject(forKey: baselineKey)
            ledger.removeAll()
            resetScreenshotWork()
            screenshotStatus = "Screenshot folder is off"
            onChange()
            return
        }
        let access = url.startAccessingSecurityScopedResource()
        do {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else { throw CocoaError(.fileReadUnsupportedScheme) }
            let directory = try Self.directoryIdentity(url)
            let files = try listFiles(url)
            let bookmark = try makeBookmark(for: url)
            guard try Self.directoryIdentity(url) == directory else { throw ScreenshotReadError.directoryChanged }
            advanceGeneration()
            scopedFolder?.stopAccessingSecurityScopedResource()
            scopedFolder = access ? url : nil
            screenshotFolder = url
            watchedDirectory = directory
            automaticMode = automatic
            defaults.set(automatic, forKey: automaticModeKey)
            defaults.set(false, forKey: automaticDisabledKey)
            folderBaseline = automatic ? Date().addingTimeInterval(-ClipStore.retention) : Date()
            if !automatic { ledger = Set(files.compactMap { Self.fileSnapshot($0, automatic: false, directory: directory)?.identity }) }
            resetScreenshotWork()
            defaults.set(bookmark.data, forKey: bookmarkKey)
            defaults.set(bookmark.scoped, forKey: bookmarkScopedKey)
            defaults.set(folderBaseline, forKey: baselineKey)
            saveLedger()
            screenshotStatus = automatic ? "Automatically watching screenshots in \(url.lastPathComponent)" : "Watching \(url.lastPathComponent); existing files skipped"
            startFolderWatcher()
            onChange()
        } catch {
            if access { url.stopAccessingSecurityScopedResource() }
            throw error
        }
    }

    private func restoreFolder() {
        automaticMode = defaults.bool(forKey: automaticModeKey)
        guard let bookmark = defaults.data(forKey: bookmarkKey) else { return }
        do {
            var stale = false
            let scoped = defaults.object(forKey: bookmarkScopedKey) as? Bool ?? true
            let url: URL
            do {
                url = try URL(resolvingBookmarkData: bookmark, options: scoped ? [.withSecurityScope, .withoutUI] : [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
            } catch {
                // An ordinary resolution carries no permission grant. Subsequent reads
                // still have to satisfy the current process's filesystem permissions.
                url = try URL(resolvingBookmarkData: bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
            }
            if scoped, url.startAccessingSecurityScopedResource() { scopedFolder = url }
            let directory = try Self.directoryIdentity(url)
            screenshotFolder = url
            watchedDirectory = directory
            resetScreenshotWork()
            folderBaseline = defaults.object(forKey: baselineKey) as? Date ?? Date()
            ledger = Set(defaults.stringArray(forKey: ledgerKey) ?? [])
            if stale {
                let refreshed = try makeBookmark(for: url)
                defaults.set(refreshed.data, forKey: bookmarkKey)
                defaults.set(refreshed.scoped, forKey: bookmarkScopedKey)
            }
            screenshotStatus = "Watching \(url.lastPathComponent)"
        } catch {
            scopedFolder?.stopAccessingSecurityScopedResource()
            scopedFolder = nil
            screenshotFolder = nil
            watchedDirectory = nil
            screenshotStatus = "Screenshot folder unavailable; choose it again"
        }
    }

    private func makeBookmark(for url: URL) throws -> (data: Data, scoped: Bool) {
        do {
            return (try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil), true)
        } catch {
            // The local build has no App Sandbox entitlement. If scope creation is
            // unavailable, an ordinary bookmark only remembers an already-readable
            // folder; it neither grants access nor bypasses OS privacy checks.
            return (try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil), false)
        }
    }

    nonisolated private static let fileKeys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey, .isSymbolicLinkKey]
    private func listFiles(_ folder: URL) throws -> [URL] {
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(Self.fileKeys), options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
        guard files.count <= 10_000 else { throw CocoaError(.fileReadTooLarge) }
        return files.filter { ["png", "jpg", "jpeg", "tiff", "tif", "heic", "heif"].contains($0.pathExtension.lowercased()) }
    }

    nonisolated static func fileSnapshot(_ url: URL, automatic: Bool, directory: DirectoryIdentity? = nil) -> ScreenshotFile? {
        guard let directory = directory ?? (try? directoryIdentity(url.deletingLastPathComponent())),
              let value = try? url.resourceValues(forKeys: fileKeys), value.isRegularFile == true, value.isSymbolicLink != true,
              let created = value.creationDate, let modified = value.contentModificationDate,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let inode = attributes[.systemFileNumber] as? NSNumber,
              let volume = attributes[.systemNumber] as? NSNumber else { return nil }
        let key = "\(volume)|\(inode)|\(created.timeIntervalSince1970)"
        let identity = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return ScreenshotFile(url: url, identity: identity, created: created, modified: modified, size: value.fileSize ?? 0, screenshot: !automatic || isScreenshot(url), device: volume.uint64Value, inode: inode.uint64Value, directory: directory)
    }

    nonisolated private static func screenshotFiles(_ folder: URL, automatic: Bool, expectedDirectory: DirectoryIdentity) throws -> [ScreenshotFile] {
        let descriptor = try openScreenshotDirectory(folder, expected: expectedDirectory)
        defer { close(descriptor) }
        let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(fileKeys), options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
        guard urls.count <= 10_000 else { throw CocoaError(.fileReadTooLarge) }
        let extensions: Set<String> = ["png", "jpg", "jpeg", "tiff", "tif", "heic", "heif"]
        let files = urls.filter { extensions.contains($0.pathExtension.lowercased()) }.compactMap { fileSnapshot($0, automatic: automatic, directory: expectedDirectory) }
        guard try directoryIdentity(folder) == expectedDirectory else { throw ScreenshotReadError.directoryChanged }
        return files
    }

    private func baselineWhilePaused() {
        guard screenshotFolder != nil else { return }
        // Reject files created during a pause even if they finish writing after resume.
        folderBaseline = Date()
        defaults.set(folderBaseline, forKey: baselineKey)
        pending.removeAll()
    }

    private func saveLedger() {
        defaults.set(Array(ledger), forKey: ledgerKey)
        defaults.synchronize()
    }

    private func scanFolder() {
        guard running, !paused, !locked, let folder = screenshotFolder, let directory = watchedDirectory else { return }
        if metadataInProgress { metadataRequested = true; return }
        metadataInProgress = true
        let token = generation
        let automatic = automaticMode
        metadataQueue.async { [weak self] in
            let result = Result { try Self.screenshotFiles(folder, automatic: automatic, expectedDirectory: directory) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.metadataInProgress = false
                    let requested = self.metadataRequested
                    self.metadataRequested = false
                    if self.running, token == self.generation, !self.paused, !self.locked, folder == self.screenshotFolder {
                        switch result {
                        case .success(let files): self.applyScreenshotFiles(files, folder: folder)
                        case .failure(let error):
                            self.folderIssue = "Screenshot import: \(error.localizedDescription)"
                            self.updateScreenshotStatus()
                        }
                    }
                    if requested { self.scanFolder() }
                }
            }
        }
    }

    private func resetScreenshotWork() {
        pending.removeAll()
        failures.removeAll()
        rejected.removeAll()
        retries.removeAll()
        itemIssues.removeAll()
        folderIssue = nil
        tagPending.removeAll()
    }

    private func updateScreenshotStatus() {
        if let issue = folderIssue { screenshotStatus = issue }
        else if let key = itemIssues.keys.min(), let issue = itemIssues[key] { screenshotStatus = issue }
        else if let folder = screenshotFolder { screenshotStatus = "Watching \(folder.lastPathComponent)" }
    }

    private func deferScreenshot(_ identity: String, signature: String, empty: Bool = false) {
        let attempts = retries[identity].map { $0.signature == signature ? $0.attempts + 1 : 1 } ?? 1
        let delay = min(empty ? 5.0 : 30.0, (empty ? 0.5 : 1.0) * pow(2, Double(min(attempts - 1, 5))))
        retries[identity] = RetryState(signature: signature, attempts: attempts, nextAttempt: Date().addingTimeInterval(delay))
    }

    private func applyScreenshotFiles(_ files: [ScreenshotFile], folder: URL) {
        let identities = Set(files.map(\.identity))
        pending = pending.filter { identities.contains($0.key) }
        tagPending = tagPending.intersection(identities)
        failures = failures.filter { identities.contains($0.key) }
        rejected = rejected.filter { identities.contains($0.key) }
        retries = retries.filter { identities.contains($0.key) }
        itemIssues = itemIssues.filter { identities.contains($0.key) }
        folderIssue = nil
        guard ledger.count < 100_000 else {
            folderIssue = "Screenshot ledger full; choose a new folder"
            updateScreenshotStatus()
            return
        }
        var processed = 0
        var changed = false
        for entry in files {
            let identity = entry.identity
            guard !ledger.contains(identity), !inFlightFiles.contains(identity) else { continue }
            let age = Date().timeIntervalSince(entry.created)
            if automaticMode && !entry.screenshot {
                if age >= 0, age < 10, tagPending.count < 128 { tagPending.insert(identity) }
                else { tagPending.remove(identity) }
                continue
            }
            tagPending.remove(identity)
            guard entry.created > folderBaseline, age >= 0, age < ClipStore.retention else {
                ledger.insert(identity)
                pending.removeValue(forKey: identity)
                retries.removeValue(forKey: identity)
                itemIssues.removeValue(forKey: identity)
                changed = true
                continue
            }
            guard processed < 3 else { continue }
            let signature = "\(entry.size)|\(entry.modified.timeIntervalSince1970)"
            guard rejected[identity] != signature else { continue }
            guard pending[identity] == signature else {
                pending[identity] = signature
                failures[identity] = 0
                retries.removeValue(forKey: identity)
                itemIssues.removeValue(forKey: identity)
                continue
            }
            guard Date().timeIntervalSince(entry.modified) >= 0.15,
                  (retries[identity]?.nextAttempt ?? .distantPast) <= Date() else { continue }
            processed += 1
            if entry.size == 0 {
                itemIssues[identity] = "Waiting for screenshot file to finish writing"
                deferScreenshot(identity, signature: signature, empty: true)
                continue
            }
            guard entry.size <= ClipStore.maximumImageBytes else {
                rejected[identity] = signature
                pending.removeValue(forKey: identity)
                retries.removeValue(forKey: identity)
                itemIssues[identity] = "Screenshot skipped: image exceeds the 25 MB item limit"
                continue
            }
            inFlightFiles.insert(identity)
            let accepted = enqueueImage(file: entry.url, expectedFile: entry, date: entry.created, source: "Screenshot folder", title: entry.url.lastPathComponent, deduplicate: false) { [weak self] result in
                guard let self else { return }
                self.inFlightFiles.remove(identity)
                switch result {
                case .success:
                    self.ledger.insert(identity)
                    self.saveLedger()
                    self.pending.removeValue(forKey: identity)
                    self.retries.removeValue(forKey: identity)
                    self.itemIssues.removeValue(forKey: identity)
                case .failure(let error):
                    if case ClipStoreError.invalidImage = error { self.recordFailure(identity, signature: signature) }
                    else if case ScreenshotReadError.changed = error { /* Rescan changed metadata promptly. */ }
                    else { self.deferScreenshot(identity, signature: signature) }
                    self.itemIssues[identity] = "Screenshot import: \(error.localizedDescription)"
                }
                self.updateScreenshotStatus()
            }
            if !accepted { inFlightFiles.remove(identity) }
        }
        if changed { saveLedger() }
        updateScreenshotStatus()
    }

    nonisolated private static func isScreenshot(_ url: URL) -> Bool {
        let key = "com.apple.metadata:kMDItemIsScreenCapture"
        let size = getxattr(url.path, key, nil, 0, 0, 0)
        guard size > 0, size <= 4_096 else { return false }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { bytes in getxattr(url.path, key, bytes.baseAddress, size, 0, 0) }
        guard read == size,
              let value = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else { return false }
        return (value as? NSNumber)?.boolValue == true
    }

    private func recordFailure(_ identity: String, signature: String) {
        failures[identity, default: 0] += 1
        if failures[identity, default: 0] >= 3 {
            rejected[identity] = signature
            pending.removeValue(forKey: identity)
        }
        // A subsequent size/mtime change makes this file eligible for fresh retries.
    }

    // Isolated adapters keep the capture boundary separate from storage policy.
    private func insertText(_ text: String, source: String?) throws {
        try store.addText(text, source: source ?? "Unknown application")
    }
    @discardableResult
    private func enqueueImage(_ bytes: Data? = nil, file: URL? = nil, expectedFile: ScreenshotFile? = nil, date: Date, source: String?, title: String = "Image", deduplicate: Bool = true, completion: @escaping (Result<Void, Error>) -> Void = { _ in }) -> Bool {
        guard activePreparations < 3 else { return false }
        let observedAt = Date()
        let folder = source == "Screenshot folder"
        let token = generation
        activePreparations += 1
        imagePreparationCount += 1
        imageQueue.async { [weak self] in
            // File reads, validation, full pixel rendering and hashing stay off the UI actor.
            let prepared = Result { () throws -> (Data, Data?) in
                let data: Data
                if let bytes { data = bytes }
                else if let file, let expectedFile {
                    data = try Self.readScreenshotData(file, expected: expectedFile)
                } else { throw ClipStoreError.invalidImage }
                guard Self.validatedPNG(data) != nil else { throw ClipStoreError.invalidImage }
                return (data, Self.normalizedImageDigest(data))
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.activePreparations -= 1
                    guard self.running, token == self.generation, !self.paused, !self.locked else { return }
                    do {
                        let (data, digest) = try prepared.get()
                        self.imageArrivals.removeAll { observedAt.timeIntervalSince($0.observedAt) > 3 }
                        if let digest, let paired = try self.imageArrivals.firstIndex(where: { arrival in
                            guard arrival.folder != folder, arrival.digest == digest else { return false }
                            return try self.store.record(id: arrival.recordID) != nil
                        }) {
                            self.imageArrivals.remove(at: paired)
                            completion(.success(()))
                            return
                        }
                        let saved = try self.store.addImage(data: data, title: title, source: source ?? "Unknown application", now: date, deduplicate: deduplicate)
                        if let digest, let saved {
                            self.imageArrivals.append(ImageArrival(digest: digest, folder: folder, observedAt: observedAt, recordID: saved.id))
                            if self.imageArrivals.count > 16 { self.imageArrivals.removeFirst(self.imageArrivals.count - 16) }
                        }
                        if !folder { self.status = "Capture active" }
                        completion(.success(()))
                    } catch {
                        if !folder { self.status = "Could not save image: \(error.localizedDescription)" }
                        completion(.failure(error))
                    }
                    self.onChange()
                }
            }
        }
        return true
    }

    enum ScreenshotReadError: LocalizedError {
        case changed, directoryChanged
        var errorDescription: String? {
            switch self {
            case .changed: return "Screenshot changed while being read; retrying."
            case .directoryChanged: return "Screenshot folder was moved or replaced; choose it again."
            }
        }
    }

    nonisolated private static func openScreenshotDirectory(_ url: URL, expected: DirectoryIdentity? = nil) throws -> Int32 {
        // Resolve an authorized folder alias, then anchor all image opens to its descriptor.
        let descriptor = open(url.resolvingSymlinksInPath().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFDIR else {
            close(descriptor)
            throw ScreenshotReadError.directoryChanged
        }
        let identity = DirectoryIdentity(device: UInt64(truncatingIfNeeded: attributes.st_dev), inode: UInt64(attributes.st_ino))
        guard expected == nil || expected == identity else {
            close(descriptor)
            throw ScreenshotReadError.directoryChanged
        }
        return descriptor
    }

    nonisolated private static func directoryIdentity(_ url: URL) throws -> DirectoryIdentity {
        let descriptor = try openScreenshotDirectory(url)
        defer { close(descriptor) }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0 else { throw ScreenshotReadError.directoryChanged }
        return DirectoryIdentity(device: UInt64(truncatingIfNeeded: attributes.st_dev), inode: UInt64(attributes.st_ino))
    }

    /// Validate the opened file, rather than trusting a path checked in an earlier scan.
    nonisolated static func readScreenshotData(_ url: URL, expected: ScreenshotFile) throws -> Data {
        let parent = try openScreenshotDirectory(url.deletingLastPathComponent(), expected: expected.directory)
        defer { close(parent) }
        let descriptor = openat(parent, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        func matches(_ value: stat) -> Bool {
            let modified = Double(value.st_mtimespec.tv_sec) + Double(value.st_mtimespec.tv_nsec) / 1_000_000_000
            let created = Double(value.st_birthtimespec.tv_sec) + Double(value.st_birthtimespec.tv_nsec) / 1_000_000_000
            return value.st_mode & S_IFMT == S_IFREG && value.st_nlink > 0 &&
                UInt64(truncatingIfNeeded: value.st_dev) == expected.device && UInt64(value.st_ino) == expected.inode &&
                value.st_size == expected.size && expected.size > 0 && expected.size <= ClipStore.maximumImageBytes &&
                abs(modified - expected.modified.timeIntervalSince1970) < 0.000001 &&
                abs(created - expected.created.timeIntervalSince1970) < 0.000001
        }
        var before = stat()
        guard fstat(descriptor, &before) == 0, matches(before) else { throw ScreenshotReadError.changed }
        let data = try handle.read(upToCount: ClipStore.maximumImageBytes + 1) ?? Data()
        var after = stat()
        guard data.count == expected.size, fstat(descriptor, &after) == 0, matches(after) else { throw ScreenshotReadError.changed }
        return data
    }

    nonisolated private static func normalizedImageDigest(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width > 0, image.height > 0,
              image.width <= ClipStore.maximumPixels / image.height,
              let color = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: color, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              let pixels = context.data else { return nil }
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        var hash = SHA256()
        hash.update(data: Data("\(image.width)x\(image.height)".utf8))
        hash.update(data: Data(bytesNoCopy: pixels, count: context.bytesPerRow * image.height, deallocator: .none))
        return Data(hash.finalize())
    }
}

enum HotKeyError: LocalizedError {
    case registration(OSStatus)
    var errorDescription: String? { "Shortcut unavailable. Choose another combination in Settings." }
}

@MainActor
final class HotKeyService {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var currentKey: UInt32?
    private var currentModifiers: UInt32?
    private let onInvoke: () -> Void
    init(onInvoke: @escaping () -> Void) { self.onInvoke = onInvoke }

    func register(keyCode: UInt32 = UInt32(kVK_ANSI_D), modifiers: UInt32 = UInt32(cmdKey)) throws {
        if reference != nil, currentKey == keyCode, currentModifiers == modifiers { return }
        if handler == nil {
            var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let context = Unmanaged.passUnretained(self).toOpaque()
            let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, pointer in
                guard let pointer, let event else { return OSStatus(eventNotHandledErr) }
                var identifier = EventHotKeyID()
                let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
                guard result == noErr, identifier.signature == 0x434C4950, identifier.id == 1 else { return OSStatus(eventNotHandledErr) }
                let service = Unmanaged<HotKeyService>.fromOpaque(pointer).takeUnretainedValue()
                MainActor.assumeIsolated { service.onInvoke() }
                return noErr
            }, 1, &event, context, &handler)
            guard installed == noErr else { throw HotKeyError.registration(installed) }
        }
        var candidate: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: 0x434C4950, id: 1)
        let registered = RegisterEventHotKey(keyCode, modifiers, identifier, GetApplicationEventTarget(), 0, &candidate)
        guard registered == noErr else { throw HotKeyError.registration(registered) }
        // Preserve the previous working shortcut until replacement succeeds.
        if let reference { UnregisterEventHotKey(reference) }
        reference = candidate
        currentKey = keyCode
        currentModifiers = modifiers
    }

    func stop() {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
        reference = nil
        handler = nil
        currentKey = nil
        currentModifiers = nil
    }
}
