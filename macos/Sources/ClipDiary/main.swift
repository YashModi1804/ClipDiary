import AppKit
import SwiftUI
import ServiceManagement
import Carbon
import ClipDiaryCore

// Disambiguate the stable property wrapper from the SDK 27 State macro.
typealias ViewState<Value> = SwiftUI.State<Value>

@MainActor
final class DiaryModel: ObservableObject {
    @Published var records: [ClipRecord] = []
    @Published var selectedID: String?
    @Published var query = "" { didSet { if query != oldValue { refresh() } } }
    @Published var snippets = false {
        didSet {
            if snippets != oldValue {
                if query.isEmpty { refresh() } else { query = "" }
                selectedID = records.last?.id
            }
        }
    }
    @Published var filter = 0 { didSet { if filter != oldValue { refresh() } } }
    @Published var message: String?
    @Published var captureStatus = "Starting…"
    @Published var screenshotStatus = "Not configured"
    @Published var screenshotFolder = ""
    @Published var paused = false { didSet { capture?.paused = paused; preferences.set(paused, forKey: "capturePaused") } }
    @Published var loginEnabled = false
    @Published var loginStatus = ""
    @Published var shortcutLabel = "⌘D"
    @Published var shortcutError: String?
    @Published var excludedApps: String = "" {
        didSet {
            preferences.set(excludedApps, forKey: "excludedApps")
            capture?.excludedBundleIDs = Self.parseExclusions(excludedApps)
        }
    }
    @Published var counts = ""
    let store: ClipStore?
    let preferences: UserDefaults
    var capture: CaptureService?
    var hotkey: HotKeyService?
    var onCopy: (() -> Void)?
    var onEdit: ((EditorDraft) -> Void)?
    var onParameters: ((ClipRecord, [String]) -> Void)?
    private var statusTimer: Timer?
    private var refreshScheduled = false
    private(set) var listIsVisible = false
    let testMode: Bool
    private let clipboardOverride: NSPasteboard?

    init() {
        let env = ProcessInfo.processInfo.environment
        testMode = env["CLIPDIARY_TEST_MODE"] == "1"
        clipboardOverride = nil
        preferences = env["CLIPDIARY_TEST_MODE"] == "1" ? UserDefaults(suiteName: (Bundle.main.bundleIdentifier ?? "com.local.ClipDiary") + ".Preview")! : .standard
        let directory = env["CLIPDIARY_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ClipDiary", isDirectory: true)
        do { store = try ClipStore(directory: directory) }
        catch { store = nil; message = "Storage could not be opened. Your saved data has not been reset. \(error.localizedDescription)" }
        paused = preferences.bool(forKey: "capturePaused")
        excludedApps = preferences.string(forKey: "excludedApps") ?? "com.1password.1password\ncom.bitwarden.desktop\ncom.apple.Passwords"
        refreshLoginStatus()
        refresh()
    }

    /// Isolated model dependencies for native integration checks; never touches the general clipboard.
    init(store: ClipStore, preferences: UserDefaults, pasteboard: NSPasteboard) {
        self.store = store
        self.preferences = preferences
        self.clipboardOverride = pasteboard
        self.testMode = true
        self.listIsVisible = true
        self.paused = preferences.bool(forKey: "capturePaused")
        self.excludedApps = preferences.string(forKey: "excludedApps") ?? ""
        refresh()
    }

    static func parseExclusions(_ value: String) -> Set<String> {
        Set(value.split(whereSeparator: { $0 == "\n" || $0 == "," }).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
    }

    func start(onInvoke: @escaping () -> Void) {
        if let store, !testMode {
            capture = CaptureService(store: store, onChange: { [weak self] in self?.scheduleRefresh() }, autoDetectScreenshots: true)
            capture?.paused = paused
            capture?.excludedBundleIDs = Self.parseExclusions(excludedApps)
            capture?.start()
        }
        hotkey = HotKeyService(onInvoke: onInvoke)
        let key = UInt32(preferences.integer(forKey: "hotkeyCode"))
        let modifiers = UInt32(preferences.integer(forKey: "hotkeyModifiers"))
        registerShortcut(code: modifiers == 0 ? UInt32(kVK_ANSI_D) : key, modifiers: modifiers == 0 ? UInt32(cmdKey) : modifiers, label: preferences.string(forKey: "hotkeyLabel") ?? "⌘D")
        if !testMode {
            let currentPath = Bundle.main.bundleURL.path
            let moved = preferences.string(forKey: "loginBundlePath") != currentPath
            let wanted = preferences.object(forKey: "wantsLogin") as? Bool ?? true
            if wanted && (!preferences.bool(forKey: "loginSetupAttempted") || moved) {
                // Rebind after moving a development build into its installed location.
                if moved && SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.unregister() }
                preferences.set(true, forKey: "loginSetupAttempted")
                setLogin(true)
            }
            preferences.set(currentPath, forKey: "loginBundlePath")
        }
        updateStatus()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateStatus() }
        }
    }

    func updateStatus() {
        let status = testMode ? "Preview mode · recording off" : (capture?.status ?? "Capture unavailable")
        let screenshot = capture?.screenshotStatus ?? "Choose a screenshot folder in Settings"
        let folder = capture?.screenshotFolder?.path ?? ""
        if captureStatus != status { captureStatus = status }
        if screenshotStatus != screenshot { screenshotStatus = screenshot }
        if screenshotFolder != folder { screenshotFolder = folder }
    }

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refresh()
            self.updateStatus()
        }
    }

    var selected: ClipRecord? { records.first { $0.id == selectedID } }
    func setListVisible(_ visible: Bool) {
        listIsVisible = visible
        if visible { refresh() }
        else {
            // A background clipboard collector does not need to retain a rendered list.
            if !records.isEmpty { records.removeAll() }
            if selectedID != nil { selectedID = nil }
        }
    }
    func moveSelection(_ delta: Int) {
        guard !records.isEmpty else { return }
        let index = selectedID.flatMap { id in records.firstIndex(where: { $0.id == id }) } ?? (records.count - 1)
        selectedID = records[min(max(index + delta, 0), records.count - 1)].id
    }
    @discardableResult
    func refresh() -> Bool {
        guard let store else { return false }
        do {
            try store.purge()
            if listIsVisible {
                let followLatest = selectedID == nil || selectedID == records.last?.id
                let updated = Array(try store.records(query: query, snippets: snippets, kind: filter == 1 ? .text : filter == 2 ? .image : nil, textPreviewLimit: 4_096).reversed())
                if records != updated { records = updated }
                if followLatest || !records.contains(where: { $0.id == selectedID }), selectedID != records.last?.id { selectedID = records.last?.id }
            }
            let stats = try store.stats()
            let summary = "\(stats.historyCount) history · \(stats.snippetCount) snippets · \(ByteCountFormatter.string(fromByteCount: Int64(stats.bytes), countStyle: .file))"
            if counts != summary { counts = summary }
            return true
        } catch { message = "Could not read saved items. \(error.localizedDescription)"; return false }
    }
    func perform(_ action: (ClipStore) throws -> Void) {
        guard let store else { return }
        do { try action(store); refresh() } catch { message = error.localizedDescription }
    }
    func editSnippet(id: String) {
        do {
            guard let item = try store?.record(id: id), item.isSnippet else { throw ClipStoreError.missingRecord }
            onEdit?(EditorDraft(id: item.id, title: item.title, text: item.text ?? "", image: item.kind == .image, parameterized: item.isParameterized))
        } catch { message = error.localizedDescription }
    }
    @discardableResult
    func copySelected(parameterValues: [String: String]? = nil) -> Bool {
        // Resolve the exact selected item again so expiry never copies a replacement.
        guard let store, let requestedID = selectedID else { return false }
        let item: ClipRecord
        do {
            guard let saved = try store.record(id: requestedID) else {
                refresh(); message = "That item has expired or was removed."; return false
            }
            item = saved
        } catch { message = error.localizedDescription; return false }
        let parameterNames = item.isSnippet && item.isParameterized && item.kind == .text ? SnippetParameters.names(in: item.text ?? "") : []
        if !parameterNames.isEmpty, parameterValues == nil {
            onParameters?(item, parameterNames)
            return false
        }
        let copiedText: String
        do { copiedText = item.isSnippet && item.isParameterized ? try SnippetParameters.render(item.text ?? "", values: parameterValues ?? [:]) : (item.text ?? "") }
        catch { message = error.localizedDescription; return false }
        guard copiedText.utf8.count <= ClipStore.maximumTextBytes else { message = "Text exceeds the 1 MB item limit."; return false }
        let board = clipboardOverride ?? (testMode ? NSPasteboard(name: NSPasteboard.Name((Bundle.main.bundleIdentifier ?? "com.local.ClipDiary") + ".Preview")) : NSPasteboard.general)
        if item.kind == .image {
            guard let path = item.assetPath, let image = NSImage(contentsOfFile: path) else { message = "The saved image could not be read."; return false }
            board.clearContents()
            guard board.writeObjects([image]) else { message = "macOS could not copy this image."; return false }
        } else {
            board.clearContents()
            guard board.setString(copiedText, forType: .string) else { message = "macOS could not copy this text."; return false }
        }
        capture?.markOwnWrite()
        do {
            let latest = try store.recopy(id: item.id, parameterValues: parameterValues ?? [:])
            guard refresh() else {
                message = "Copied successfully and saved its new time, but the history list could not refresh. You can still paste this item."
                return false
            }
            if records.contains(where: { $0.id == latest.id }) { selectedID = latest.id }
        } catch {
            message = "Copied successfully, but the history update could not be saved. You can still paste this item. \(error.localizedDescription)"
            return false
        }
        message = nil
        onCopy?()
        return true
    }
    func chooseFolder() {
        let chooser = NSOpenPanel()
        chooser.title = "Choose your screenshot folder"
        chooser.message = "Choose the local folder used by macOS Screenshot. Only new images are imported. Existing files stay untouched."
        chooser.canChooseDirectories = true; chooser.canChooseFiles = false
        chooser.canCreateDirectories = true; chooser.allowsMultipleSelection = false
        if chooser.runModal() == .OK, let url = chooser.url {
            do { try capture?.configureScreenshotFolder(url); updateStatus() }
            catch { message = "Could not watch that folder. \(error.localizedDescription)" }
        }
    }
    func stopFolder() {
        do { try capture?.configureScreenshotFolder(nil); updateStatus() }
        catch { message = error.localizedDescription }
    }
    func setLogin(_ enabled: Bool) {
        preferences.set(enabled, forKey: "wantsLogin")
        if testMode {
            loginEnabled = enabled
            loginStatus = "Preview preference only; login startup is unchanged."
            return
        }
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch { message = "Login startup could not be changed. \(error.localizedDescription)" }
        refreshLoginStatus()
    }
    func refreshLoginStatus() {
        switch SMAppService.mainApp.status {
        case .enabled: loginEnabled = true; loginStatus = "Starts automatically after you sign in."
        case .requiresApproval: loginEnabled = true; loginStatus = "Approve ClipDiary in System Settings → General → Login Items."
        case .notRegistered: loginEnabled = false; loginStatus = "Start at login is off."
        case .notFound: loginEnabled = false; loginStatus = "Install the app in Applications before enabling login startup."
        @unknown default: loginEnabled = false; loginStatus = "Login status unavailable."
        }
    }
    func registerShortcut(code: UInt32, modifiers: UInt32, label: String) {
        do {
            try hotkey?.register(keyCode: code, modifiers: modifiers)
            shortcutLabel = label; shortcutError = nil
            preferences.set(Int(code), forKey: "hotkeyCode")
            preferences.set(Int(modifiers), forKey: "hotkeyModifiers")
            preferences.set(label, forKey: "hotkeyLabel")
        } catch { shortcutError = "That shortcut is unavailable. \(error.localizedDescription)" }
    }
    func shutDown() { capture?.stop(); hotkey?.stop(); statusTimer?.invalidate() }
}

struct DiaryView: View {
    @ObservedObject var model: DiaryModel
    let settings: () -> Void
    @FocusState private var searchFocused: Bool
    @ViewState(initialValue: false) private var confirmClear: Bool
    @ViewState(initialValue: false) private var confirmDelete: Bool
    @ViewState(initialValue: nil) private var deleteTargetID: String?
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "square.on.square").font(.system(size: 18, weight: .semibold)).foregroundStyle(.teal)
                Text("ClipDiary").font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(model.shortcutLabel).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                Button { model.paused.toggle() } label: { Image(systemName: model.paused ? "play.fill" : "pause") }
                    .help(model.paused ? "Resume automatic capture" : "Pause automatic capture")
                Button(action: settings) { Image(systemName: "slider.horizontal.3") }.help("Settings")
            }.buttonStyle(.borderless).padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 15)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search your clipboard…", text: $model.query)
                    .textFieldStyle(.plain).focused($searchFocused)
                if !model.query.isEmpty {
                    Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain)
                }
            }.font(.system(size: 13)).padding(11)
                .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10)).padding(.horizontal, 16)
            HStack(spacing: 10) {
                Picker("Collection", selection: $model.snippets) {
                    Text("History").tag(false); Text("Snippets").tag(true)
                }.pickerStyle(.segmented).labelsHidden()
                Picker("Content type", selection: $model.filter) {
                    Text("All").tag(0); Text("Text").tag(1); Text("Images").tag(2)
                }.labelsHidden().frame(width: 85)
                if model.snippets {
                    Button { model.onEdit?(EditorDraft(id: nil, title: "", text: "", image: false)) } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless).help("New text snippet")
                }
            }.padding(.horizontal, 16).padding(.vertical, 13)
            Divider().opacity(0.5)
            if model.records.isEmpty {
                Text(model.query.isEmpty ? "No items" : "No matches")
                    .font(.system(size: 12)).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(model.records) { item in
                                Button {
                                    model.selectedID = item.id
                                    model.copySelected()
                                } label: {
                                    ClipRow(item: item, selected: model.selectedID == item.id)
                                }.buttonStyle(.plain).focusable(false)
                                    .id(item.id)
                                    .accessibilityAddTraits(model.selectedID == item.id ? .isSelected : [])
                                    .background(InstantHoverPreview(item: item))
                                    .accessibilityHint(metadata(item))
                                    .accessibilityLabel(item.kind == .image ? "Image: \(item.title)" : (item.text ?? item.title))
                                    .contextMenu {
                                        if !item.isSnippet { Button("Save as Snippet") { save(item) } }
                                        else {
                                            Button("Edit Snippet") { edit(item) }
                                            if item.kind == .text {
                                                Button(item.isParameterized ? "Disable Parameters" : "Make Parameterized") {
                                                    model.perform { try $0.setParameterized(id: item.id, enabled: !item.isParameterized) }
                                                }
                                            }
                                        }
                                        Divider()
                                        Button("Delete", role: .destructive) { deleteTargetID = item.id; confirmDelete = true }
                                        if !model.snippets {
                                            Divider()
                                            Button("Clear History…", role: .destructive) { confirmClear = true }
                                        }
                                    }
                            }
                        }.padding(10)
                    }
                    .onChange(of: model.selectedID) { _, id in
                        if let id { proxy.scrollTo(id, anchor: .bottom) }
                    }
                    .onChange(of: model.snippets) { _, _ in
                        model.selectedID = model.records.last?.id
                        DispatchQueue.main.async { if let id = model.records.last?.id { proxy.scrollTo(id, anchor: .bottom) } }
                    }
                    .onAppear { DispatchQueue.main.async { if let id = model.records.last?.id { proxy.scrollTo(id, anchor: .bottom) } } }
                    .onReceive(NotificationCenter.default.publisher(for: .diaryPanelOpened)) { _ in
                        model.selectedID = model.records.last?.id
                        DispatchQueue.main.async { if let id = model.records.last?.id { proxy.scrollTo(id, anchor: .bottom) } }
                    }
                }.id(model.snippets)
            }
            Divider().opacity(0.5)
            HStack(spacing: 6) {
                Circle().fill(model.paused ? Color.orange : Color.teal).frame(width: 5, height: 5)
                Text(model.paused ? "Paused" : model.captureStatus).lineLimit(1)
                Spacer(minLength: 8)
            }.font(.system(size: 10)).padding(.horizontal, 17).padding(.vertical, 11)
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 15))
        .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(.primary.opacity(0.09), lineWidth: 0.5))
        .frame(minWidth: 360, minHeight: 520)
        .onChange(of: model.query) { _, _ in InstantHoverPreview.dismiss() }
        .onChange(of: model.filter) { _, _ in InstantHoverPreview.dismiss() }
        .onChange(of: model.snippets) { _, _ in InstantHoverPreview.dismiss() }
        .onChange(of: model.selectedID) { _, _ in InstantHoverPreview.dismiss() }
        .onAppear { searchFocused = true }
        .onReceive(NotificationCenter.default.publisher(for: .diaryPanelOpened)) { _ in searchFocused = true }
        .alert("Clear clipboard history?", isPresented: $confirmClear) {
            Button("Cancel", role: .cancel) {}
            Button("Clear History", role: .destructive) { model.capture?.invalidatePendingImports(); model.perform { try $0.clearHistory() } }
        } message: { Text("Removes text and image history from ClipDiary. Your snippets and original screenshot files are kept.") }
        .alert("Delete this item?", isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { if let id = deleteTargetID { model.perform { try $0.delete(id: id) } } }
        }
        .alert("ClipDiary", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("OK") { model.message = nil }
        } message: { Text(model.message ?? "") }
        .background {
            Group {
                Button("") { model.snippets = false }.keyboardShortcut("1", modifiers: .command)
                Button("") { model.snippets = true }.keyboardShortcut("2", modifiers: .command)
                Button("") { searchFocused = true }.keyboardShortcut("f", modifiers: .command)
                Button("") { if let item = model.selected, !item.isSnippet { save(item) } }.keyboardShortcut("s", modifiers: .command)
            }.hidden()
        }
    }
    func metadata(_ item: ClipRecord) -> String {
        let details = "Source: \(item.source)\nCopied: \(item.capturedAt.formatted(date: .abbreviated, time: .shortened))\nSize: \(ByteCountFormatter.string(fromByteCount: Int64(item.byteCount), countStyle: .file))"
        guard item.kind == .text, let text = item.text else { return details }
        let bounded = String(text.prefix(601))
        let lines = bounded.split(separator: "\n", omittingEmptySubsequences: false)
        let preview = String(lines.prefix(12).joined(separator: "\n").prefix(600))
        let truncated = bounded.count > 600 || lines.count > 12
        return preview + (truncated ? "\n…" : "") + "\n\n" + details
    }
    func save(_ item: ClipRecord) { model.perform { try $0.saveSnippet(item.id, title: nil) } }
    func edit(_ item: ClipRecord) { model.editSnippet(id: item.id) }
}

struct ClipRow: View {
    let item: ClipRecord
    let selected: Bool
    @ViewState(initialValue: false) private var hovered: Bool
    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            if item.kind == .image, let thumb = item.thumbnailPath, let image = ThumbnailCache.shared.image(at: thumb) {
                Image(nsImage: image).resizable().scaledToFit().frame(width: 84, height: 68)
                    .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7)).clipShape(RoundedRectangle(cornerRadius: 7))
            } else {
                Image(systemName: item.kind == .image ? "photo" : "text.alignleft")
                    .font(.system(size: 13)).foregroundStyle(.teal.opacity(0.8)).frame(width: 23, height: 23)
            }
            Group {
                if item.kind == .text {
                    Text(item.isSnippet && !item.title.isEmpty ? item.title : String((item.text ?? item.title).prefix(240)).replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " "))
                        .font(.system(size: 13, weight: item.isSnippet ? .medium : .regular))
                        .lineLimit(1).truncationMode(.tail)
                } else {
                    Text(item.isSnippet && !item.title.isEmpty ? item.title : "Image")
                        .font(.system(size: 12, weight: .medium)).lineLimit(1)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if item.isParameterized { Image(systemName: "curlybraces").font(.system(size: 10)).foregroundStyle(.teal).help("Parameterized snippet") }
            if item.isSnippet { Image(systemName: "bookmark.fill").font(.system(size: 9)).foregroundStyle(.teal.opacity(0.7)) }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Color.teal.opacity(0.13) : hovered ? Color.primary.opacity(0.045) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Color.teal.opacity(0.3) : Color.clear, lineWidth: 0.6))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onHover { hovered = $0 }
    }
}

struct EditorDraft: Identifiable {
    var id: String?
    var title: String
    var text: String
    var image: Bool
    var parameterized: Bool = false
}
struct SnippetEditor: View {
    let draft: EditorDraft
    let save: (String, String, Bool) -> String?
    let dismiss: () -> Void
    @ViewState(initialValue: nil) private var saveError: String?
    @ViewState(initialValue: "") private var title: String
    @ViewState(initialValue: "") private var text: String
    @ViewState(initialValue: false) private var parameterized: Bool
    init(draft: EditorDraft, save: @escaping (String, String, Bool) -> String?, dismiss: @escaping () -> Void) {
        self.draft = draft; self.save = save; self.dismiss = dismiss
        _title = State(initialValue: draft.title); _text = State(initialValue: draft.text)
        _parameterized = State(initialValue: draft.parameterized)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(draft.id == nil ? "New snippet" : "Edit snippet").font(.title2.weight(.semibold))
            TextField("Title (optional)", text: $title).textFieldStyle(.roundedBorder)
            if !draft.image {
                PlainTextEditor(text: $text).frame(minHeight: 180).border(.secondary.opacity(0.3))
                if draft.id != nil { Toggle("Parameterized — prompt for <parameter_name> values", isOn: $parameterized) }
            }
            if let saveError { Text(saveError).font(.caption).foregroundStyle(.red) }
            Text("Snippets remain until you delete them.").font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    if let error = save(title, text, parameterized) { saveError = error } else { dismiss() }
                }.keyboardShortcut(.defaultAction).disabled(!draft.image && text.isEmpty)
            }
        }.padding(24).frame(width: 480)
    }
}

struct SettingsView: View {
    @ObservedObject var model: DiaryModel
    @ViewState(initialValue: false) private var recordingShortcut: Bool
    @ViewState(initialValue: false) private var confirmAll: Bool
    var body: some View {
        Form {
            Section {
                HStack {
                    Image(systemName: "square.on.square.fill").font(.largeTitle).foregroundStyle(.teal)
                    VStack(alignment: .leading) {
                        Text("ClipDiary").font(.title2.weight(.semibold))
                        Text("Your clipboard, kept on this Mac.").foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 4)
                Text("Text and images stay for up to four days. Save anything important as a snippet to keep it.")
            }
            Section("Everyday access") {
                Toggle("Start automatically at login", isOn: Binding(get: { model.loginEnabled }, set: { model.setLogin($0) }))
                Text(model.loginStatus).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text("Open history")
                    Spacer()
                    Button(recordingShortcut ? "Press a shortcut…" : model.shortcutLabel) { recordingShortcut = true }
                        .font(.system(.body, design: .monospaced))
                    Button("Reset") { model.registerShortcut(code: UInt32(kVK_ANSI_D), modifiers: UInt32(cmdKey), label: "⌘D") }
                }
                Text("⌘D replaces that shortcut in other apps while ClipDiary is running. Choose a different combination if needed.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = model.shortcutError { Text(error).font(.caption).foregroundStyle(.red) }
                if recordingShortcut {
                    ShortcutRecorder { code, modifiers, label in
                        recordingShortcut = false
                        model.registerShortcut(code: code, modifiers: modifiers, label: label)
                    } cancelled: { recordingShortcut = false }.frame(height: 1)
                    Text("Use Command, Control or Option with a key. Escape cancels.").font(.caption).foregroundStyle(.teal)
                }
                Toggle("Pause automatic capture", isOn: $model.paused)
            }
            Section("Automatic screenshots") {
                HStack {
                    Button("Choose Screenshot Folder…", action: model.chooseFolder)
                    if !model.screenshotFolder.isEmpty { Button("Disconnect", action: model.stopFolder) }
                }
                if !model.screenshotFolder.isEmpty { Text(model.screenshotFolder).font(.caption).textSelection(.enabled) }
                Text(model.screenshotStatus).font(.caption).foregroundStyle(.secondary)
            }
            Section("Privacy") {
                Text("Excluded application bundle identifiers (one per line)").font(.subheadline)
                TextEditor(text: $model.excludedApps).font(.system(.caption, design: .monospaced)).frame(height: 76)
                Text("Sensitive clipboard markers are skipped when provided. Screenshots cannot reliably identify sensitive content or which apps appear inside them; pause screenshot import when needed.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Clipboard access is controlled by macOS. If capture is blocked, allow ClipDiary in System Settings → Privacy & Security. No Screen Recording permission is needed for saved-file import.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Open System Settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security")!) }
            }
            Section("Storage") {
                Text(model.counts.isEmpty ? "Local storage" : model.counts).font(.caption).foregroundStyle(.secondary)
                Text("History: rolling 96 hours. Snippets: kept until deletion. Large items and storage limits are reported. No accounts, cloud sync, analytics or remote services.")
                    .font(.caption)
                Button("Delete All Local Data…", role: .destructive) { confirmAll = true }
            }
            Section { Text("ClipDiary 1.0.6").font(.caption).foregroundStyle(.secondary) }
        }.formStyle(.grouped).frame(width: 580, height: 740)
            .onAppear { model.refreshLoginStatus(); model.updateStatus(); model.refresh() }
            .alert("Delete all ClipDiary data?", isPresented: $confirmAll) {
                Button("Cancel", role: .cancel) {}
                Button("Delete Everything", role: .destructive) { model.capture?.invalidatePendingImports(); model.perform { try $0.deleteAll() } }
            } message: { Text("This permanently removes your history AND saved snippets from ClipDiary. Original screenshot files are kept.") }
            .alert("ClipDiary", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
                Button("OK") { model.message = nil }
            } message: { Text(model.message ?? "") }
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    let received: (UInt32, UInt32, String) -> Void
    let cancelled: () -> Void
    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView(); view.received = received; view.cancelled = cancelled
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }
    func updateNSView(_ nsView: RecorderView, context: Context) {}
    final class RecorderView: NSView {
        var received: ((UInt32, UInt32, String) -> Void)?
        var cancelled: (() -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard window?.firstResponder === self, event.type == .keyDown else { return false }
            keyDown(with: event)
            return true
        }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { cancelled?(); return }
            let f = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard !f.intersection([.command, .control, .option]).isEmpty else { NSSound.beep(); return }
            var modifiers: UInt32 = 0
            var label = ""
            if f.contains(.control) { modifiers |= UInt32(controlKey); label += "⌃" }
            if f.contains(.option) { modifiers |= UInt32(optionKey); label += "⌥" }
            if f.contains(.shift) { modifiers |= UInt32(shiftKey); label += "⇧" }
            if f.contains(.command) { modifiers |= UInt32(cmdKey); label += "⌘" }
            let named: [UInt16:String] = [49:"Space",36:"Return",48:"Tab",123:"←",124:"→",125:"↓",126:"↑"]
            label += named[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)"
            received?(UInt32(event.keyCode), modifiers, label)
        }
    }
}

extension Notification.Name { static let diaryPanelOpened = Notification.Name("diaryPanelOpened"); static let diaryPanelClosed = Notification.Name("diaryPanelClosed") }

final class DiaryPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var model: DiaryModel!
    var panel: NSPanel!
    var settingsWindow: NSWindow?
    var editorWindow: NSWindow?
    var parameterWindow: NSWindow?
    var statusItem: NSStatusItem!
    var previousApp: NSRunningApplication?
    var purgeTimer: Timer?
    var escapeMonitor: Any?
    var openObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let bundleID = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            DistributedNotificationCenter.default().postNotificationName(Notification.Name("com.local.ClipDiary.open"), object: nil, userInfo: nil, deliverImmediately: true)
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.accessory)
        installEditingMenu()
        model = DiaryModel()
        panel = DiaryPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 696), styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        panel.title = "ClipDiary"; panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false; panel.isFloatingPanel = true; panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 360, height: 520)
        panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hasShadow = true; panel.isMovableByWindowBackground = true
        panel.acceptsMouseMovedEvents = true
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: DiaryView(model: model, settings: { [weak self] in self?.showSettings() }))
        panel.center()
        model.onCopy = { [weak self] in self?.dismissPanel(restore: true) }
        model.onEdit = { [weak self] draft in self?.showEditor(draft) }
        model.onParameters = { [weak self] item, names in self?.showParameters(item, names: names) }
        model.start { [weak self] in self?.togglePanel() }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "square.on.square", accessibilityDescription: "ClipDiary")
            button.target = self; button.action = #selector(statusClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "ClipDiary · \(model.shortcutLabel)"
        }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard self.panel.isKeyWindow, self.panel.attachedSheet == nil else { return event }
            switch PanelKeyAction.action(for: event, editor: self.panel.firstResponder as? NSTextView) {
            case .copy: self.model.copySelected(); return nil
            case .move(let delta): self.model.moveSelection(delta); return nil
            case .dismiss: self.dismissPanel(restore: true); return nil
            case .passThrough: break
            }
            return event
        }
        purgeTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in Task { @MainActor in self?.model.refresh() } }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(woke), name: NSWorkspace.didWakeNotification, object: nil)
        openObserver = DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.local.ClipDiary.open"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.showPanel() }
        }
        if !model.preferences.bool(forKey: "hasSeenWelcome") || model.testMode || CommandLine.arguments.contains("--show") {
            model.preferences.set(true, forKey: "hasSeenWelcome")
            showPanel()
        }
    }
    @objc func woke() { model.refresh() }
    @objc func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp { showMenu() } else { togglePanel() }
    }
    func showMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open ClipDiary", action: #selector(openFromMenu), keyEquivalent: "")
        menu.addItem(withTitle: model.paused ? "Resume Automatic Capture" : "Pause Automatic Capture", action: #selector(pauseFromMenu), keyEquivalent: "")
        menu.addItem(withTitle: "Settings…", action: #selector(settingsFromMenu), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit ClipDiary", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        statusItem.menu = menu; statusItem.button?.performClick(nil); statusItem.menu = nil
    }
    @objc func openFromMenu() { showPanel() }
    @objc func pauseFromMenu() { model.paused.toggle() }
    @objc func settingsFromMenu() { showSettings() }
    @objc func quit() { NSApp.terminate(nil) }
    func togglePanel() { if panel.isVisible && panel.isKeyWindow { dismissPanel(restore: true) } else { showPanel() } }
    func showPanel() {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp = front }
        model.setListVisible(true)
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) {
            let frame = screen.visibleFrame
            let fitted = NSSize(width: min(panel.frame.width, max(360, frame.width - 24)), height: min(panel.frame.height, max(520, frame.height - 24)))
            panel.setContentSize(fitted)
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width/2, y: frame.midY - panel.frame.height/2))
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .diaryPanelOpened, object: nil)
    }
    func dismissPanel(restore: Bool) {
        NotificationCenter.default.post(name: .diaryPanelClosed, object: nil)
        panel.orderOut(nil)
        model.setListVisible(false)
        if restore { previousApp?.activate(options: []) }
    }
    func showEditor(_ draft: EditorDraft) {
        if let editorWindow, editorWindow.isVisible { editorWindow.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 528, height: draft.image ? 205 : 470), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = draft.id == nil ? "New Snippet" : "Edit Snippet"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.level = .floating
        window.contentView = NSHostingView(rootView: SnippetEditor(draft: draft, save: { [weak self] title, text, parameterized in
            guard let self, let store = self.model.store else { return "Local storage is unavailable." }
            do {
                if let id = draft.id {
                    try store.updateSnippet(id: id, title: title, text: draft.image ? nil : text, parameterized: draft.image ? nil : parameterized)
                }
                else { try store.createSnippet(title: title, text: text) }
                self.model.refresh()
                return nil
            } catch { return error.localizedDescription }
        }, dismiss: { [weak self, weak window] in
            self?.closeAuxiliary(window, returnToPanel: true)
        }))
        window.center()
        NotificationCenter.default.post(name: .diaryPanelClosed, object: nil)
        panel.orderOut(nil)
        model.setListVisible(false)
        editorWindow = window
        window.makeKeyAndOrderFront(nil)
    }
    func showParameters(_ item: ClipRecord, names: [String]) {
        if let parameterWindow, parameterWindow.isVisible { parameterWindow.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 450, height: min(540, 180 + names.count * 60)), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Snippet parameters"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.level = .floating
        window.contentView = NSHostingView(rootView: ParameterValuesView(names: names, copy: { [weak self, weak window] values in
            guard let self else { return }
            // Resolve the selected template again; deletion/editing during the prompt must not copy a replacement.
            do {
                guard let saved = try self.model.store?.record(id: item.id), saved.isSnippet,
                      saved.isParameterized == item.isParameterized, saved.text == item.text else {
                    self.closeAuxiliary(window, returnToPanel: true); self.model.message = "This snippet changed. Select it again to copy."; return
                }
            } catch { self.showParameterError(error.localizedDescription, in: window); return }
            self.model.selectedID = item.id
            if self.model.copySelected(parameterValues: values) {
                self.closeAuxiliary(window, returnToPanel: false)
            } else if let message = self.model.message {
                // Keep the existing form and values available for correction or retry.
                self.showParameterError(message, in: window)
            }
        }, cancel: { [weak self, weak window] in self?.closeAuxiliary(window, returnToPanel: true) }))
        window.center()
        NotificationCenter.default.post(name: .diaryPanelClosed, object: nil)
        panel.orderOut(nil)
        model.setListVisible(false)
        parameterWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    private func showParameterError(_ message: String, in window: NSWindow?) {
        guard let window else { model.message = message; return }
        model.message = nil
        let alert = NSAlert()
        alert.messageText = "ClipDiary"
        alert.informativeText = message
        alert.beginSheetModal(for: window)
    }

    func closeAuxiliary(_ window: NSWindow?, returnToPanel: Bool) {
        guard let window else { return }
        if window === editorWindow { editorWindow = nil }
        if window === parameterWindow { parameterWindow = nil }
        window.close()
        window.contentView = nil
        if returnToPanel { showPanel() }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === editorWindow || sender === parameterWindow {
            closeAuxiliary(sender, returnToPanel: true)
            return false
        }
        return true
    }

    func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 740), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "ClipDiary Settings"; window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(model: model))
            window.center(); settingsWindow = window
        }
        NotificationCenter.default.post(name: .diaryPanelClosed, object: nil)
        panel.orderOut(nil)
        model.setListVisible(false)
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return true
    }
    func applicationDidResignActive(_ notification: Notification) {
        if panel?.attachedSheet == nil { NotificationCenter.default.post(name: .diaryPanelClosed, object: nil); panel?.orderOut(nil); model?.setListVisible(false) }
    }
    func applicationWillTerminate(_ notification: Notification) {
        model?.shutDown(); purgeTimer?.invalidate()
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        if let openObserver { DistributedNotificationCenter.default().removeObserver(openObserver) }
    }
}

MainActor.assumeIsolated {
let application = NSApplication.shared
if CommandLine.arguments.contains("--integration-test") {
    Task { @MainActor in
        guard runHoverPreviewLayoutChecks(), runKeyboardRoutingChecks(), runModelRefreshChecks() else { exit(1) }
        let result = await runServiceChecks()
        exit(result)
    }
    application.run()
    exit(1)
}
let delegate = AppDelegate()
application.delegate = delegate
withExtendedLifetime(delegate) { application.run() }

}
