import AppKit
import ClipDiaryCore
import Combine

/// Runs only on explicit --integration-test, using disposable storage and a private pasteboard.
@MainActor
func runModelRefreshChecks() -> Bool {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ClipDiary-ModelChecks-\(UUID().uuidString)")
    let suite = "ClipDiary.ModelChecks.\(UUID().uuidString)"
    let preferences = UserDefaults(suiteName: suite)!
    let board = NSPasteboard.withUniqueName()
    defer {
        board.releaseGlobally()
        preferences.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
    struct Failure: LocalizedError {
        let errorDescription: String?
    }
    var checks = 0
    func check(_ condition: Bool, _ label: String) throws {
        guard condition else { throw Failure(errorDescription: label) }
        checks += 1
    }
    do {
        let store = try ClipStore(directory: root)
        let fullText = "Start\0" + String(repeating: "large text 🧑🏽‍💻\n", count: 6_000) + "<instance> END"
        try store.createSnippet(title: "Complete template", text: fullText)
        let item = try store.records(snippets: true).first!
        try store.setParameterized(id: item.id, enabled: true)
        let model = DiaryModel(store: store, preferences: preferences, pasteboard: board)
        model.snippets = true
        try check(model.records.first?.text != fullText && (model.records.first?.text?.utf8.count ?? 0) < 20_000, "List must retain only a bounded preview")
        try check(model.records.first?.text?.hasPrefix("Start\0") == true, "List preview must preserve embedded nulls")
        var publications = 0
        let subscription = model.$records.sink { _ in publications += 1 }
        let beforeRefresh = publications
        for _ in 0..<20 { try check(model.refresh(), "Repeated refresh succeeds") }
        try check(publications == beforeRefresh, "Unchanged rows must not be republished")
        withExtendedLifetime(subscription) {}
        model.query = "END"
        try check(model.records.first?.id == item.id, "Search includes content beyond the preview boundary")
        var draft: EditorDraft?
        model.onEdit = { draft = $0 }
        model.editSnippet(id: item.id)
        try check(draft?.text == fullText && draft?.parameterized == true, "Editor receives the full stored template")
        var parameterNames: [String] = []
        model.onParameters = { _, names in parameterNames = names }
        model.selectedID = item.id
        let beforePrompt = board.changeCount
        try check(!model.copySelected() && parameterNames == ["instance"] && board.changeCount == beforePrompt, "Parameter discovery includes the full template without copying")
        model.setListVisible(false)
        try check(model.records.isEmpty && model.selectedID == nil, "Hidden list releases its rows and selection")
        for number in 0..<20 { _ = try store.addText("Background capture \(number)", source: "Fixture") }
        try check(model.refresh() && model.records.isEmpty, "Background refresh keeps hidden rows unloaded")
        model.selectedID = item.id
        var copies = 0
        model.onCopy = { copies += 1 }
        let oversized = ["instance": String(repeating: "x", count: ClipStore.maximumTextBytes)]
        try check(!model.copySelected(parameterValues: oversized) && copies == 0 && board.changeCount == beforePrompt, "Invalid parameter copy returns failure without changing clipboard")
        model.message = "An earlier unrelated error"
        try check(model.copySelected(parameterValues: ["instance": "VALUE"]) && copies == 1 && model.message == nil, "Successful copy returns success and clears stale alert state")
        try check(board.string(forType: .string) == fullText.replacingOccurrences(of: "<instance>", with: "VALUE"), "Hidden parameter copy preserves full text and substitutes its value")
        try check(try store.record(id: item.id)?.text == fullText, "Full template remains unchanged")
        model.snippets = false
        model.query = ""
        model.setListVisible(true)
        try check(model.selectedID == model.records.last?.id && model.records.last?.text?.hasPrefix("Start\0") == true, "Reopening history selects latest copied item")
        let currentID = model.selectedID
        model.setListVisible(false)
        model.setListVisible(true)
        try check(model.selectedID == currentID, "Repeated reopening retains latest selection")

        let delegate = AppDelegate()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 450, height: 240), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSTextView()
        delegate.parameterWindow = window
        delegate.closeAuxiliary(window, returnToPanel: false)
        try check(delegate.parameterWindow == nil && window.contentView == nil, "Completed parameter window releases its hosted values")
        print("PASS: \(checks) model checks: bounded previews, unchanged publication suppression, full search/edit/copy, hidden refresh, retry results, latest selection and released forms")
        return true
    } catch {
        print("FAIL: model refresh/workflow after \(checks) checks: \(error.localizedDescription)")
        return false
    }
}
