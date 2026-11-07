import AppKit

/// Preserve native field editing while keeping the panel's established row shortcuts.
enum PanelKeyAction: Equatable {
    case copy, move(Int), dismiss, passThrough

    @MainActor
    static func action(for event: NSEvent, editor: NSTextView?) -> PanelKeyAction {
        // Input-method candidate navigation and confirmation belong to the text system.
        if editor?.hasMarkedText() == true { return .passThrough }
        if event.modifierFlags.contains(.command),
           event.modifierFlags.intersection([.control, .option, .shift]).isEmpty,
           event.charactersIgnoringModifiers?.lowercased() == "c" {
            return (editor?.selectedRange().length ?? 0) > 0 ? .passThrough : .copy
        }
        if event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
           [125, 126].contains(event.keyCode) {
            return .move(event.keyCode == 125 ? 1 : -1)
        }
        if event.keyCode == 53 { return .dismiss }
        return .passThrough
    }
}

@MainActor
func runKeyboardRoutingChecks() -> Bool {
    func event(_ key: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: key)!
    }
    let editor = NSTextView()
    editor.string = "selected search text"
    editor.setSelectedRange(NSRange(location: 0, length: 8))
    guard PanelKeyAction.action(for: event(8, "c", .command), editor: editor) == .passThrough,
          PanelKeyAction.action(for: event(126, "", .shift), editor: editor) == .passThrough,
          PanelKeyAction.action(for: event(125, "", .shift), editor: editor) == .passThrough else { return false }
    editor.setSelectedRange(NSRange(location: 0, length: 0))
    guard PanelKeyAction.action(for: event(8, "c", .command), editor: editor) == .copy,
          PanelKeyAction.action(for: event(125, ""), editor: editor) == .move(1),
          PanelKeyAction.action(for: event(126, ""), editor: editor) == .move(-1) else { return false }
    editor.setMarkedText("候補", selectedRange: NSRange(location: 0, length: 1), replacementRange: NSRange(location: NSNotFound, length: 0))
    guard PanelKeyAction.action(for: event(125, ""), editor: editor) == .passThrough,
          PanelKeyAction.action(for: event(53, ""), editor: editor) == .passThrough else { return false }
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
    let recorder = ShortcutRecorder.RecorderView()
    window.contentView = recorder
    window.makeFirstResponder(recorder)
    var recorded: UInt32?
    recorder.received = { key, _, _ in recorded = key }
    guard window.performKeyEquivalent(with: event(12, "q", .command)), recorded == 12 else { return false }
    recorded = nil
    window.makeFirstResponder(nil)
    guard !recorder.performKeyEquivalent(with: event(12, "q", .command)), recorded == nil else { return false }
    print("PASS: search selection, Shift arrows and IME retain native editing; row keys work; shortcut recorder consumes Command-Q only while focused")
    return true
}
