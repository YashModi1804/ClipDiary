import AppKit
import SwiftUI

/// AppKit's plain text editor retains the responder-chain editing commands and undo stack.
struct PlainTextEditor: NSViewRepresentable {
    @Binding var text: String
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = makePlainSnippetEditor(text: text)
        (scroll.documentView as? NSTextView)?.delegate = context.coordinator
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? NSTextView, editor.string != text else { return }
        editor.string = text
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PlainTextEditor
        init(_ parent: PlainTextEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
        }
    }
}

struct ParameterValuesView: View {
    let names: [String]
    let copy: ([String: String]) -> Void
    let cancel: () -> Void
    @ViewState(initialValue: [:]) private var values: [String: String]
    @FocusState private var focusedName: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Parameter values").font(.title3.weight(.semibold))
            Text("Leave a value blank to keep its <placeholder>.").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(names, id: \.self) { name in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("<\(name)>").font(.system(size: 12, design: .monospaced))
                            TextField("Value", text: Binding(get: { values[name] ?? "" }, set: { values[name] = $0 }))
                                .textFieldStyle(.roundedBorder).focused($focusedName, equals: name)
                                .accessibilityLabel("Value for \(name)")
                        }
                    }
                }.padding(2)
            }.frame(minHeight: 60, maxHeight: 350)
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Copy") { copy(values) }.keyboardShortcut(.defaultAction)
            }
        }.padding(22).frame(width: 406)
            .onAppear { focusedName = names.first }
    }
}

@MainActor
func installEditingMenu() {
    let bar = NSMenu()
    let application = NSMenuItem()
    let appMenu = NSMenu()
    appMenu.addItem(withTitle: "Quit ClipDiary", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    application.submenu = appMenu
    bar.addItem(application)
    let editing = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
    let menu = NSMenu(title: "Edit")
    for (title, selector, key, shift) in [
        ("Undo", "undo:", "z", false), ("Redo", "redo:", "z", true),
        ("Cut", "cut:", "x", false), ("Copy", "copy:", "c", false),
        ("Paste", "paste:", "v", false), ("Select All", "selectAll:", "a", false)
    ] {
        let item = NSMenuItem(title: title, action: Selector(selector), keyEquivalent: key)
        item.keyEquivalentModifierMask = shift ? [.command, .shift] : [.command]
        menu.addItem(item)
    }
    editing.submenu = menu
    bar.addItem(editing)
    NSApp.mainMenu = bar
}

@MainActor
func makePlainSnippetEditor(text: String) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        let editor = NSTextView(frame: scroll.contentView.bounds)
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.isEditable = true
        editor.isSelectable = true
        editor.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.textContainerInset = NSSize(width: 8, height: 8)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
        editor.string = text
        scroll.documentView = editor
        return scroll
}

@MainActor
func runNativeEditorChecks() -> Bool {
    installEditingMenu()
    let scroll = makePlainSnippetEditor(text: "original")
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 240), styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = scroll
    guard let editor = scroll.documentView as? NSTextView else { return false }
    window.makeFirstResponder(editor)
    editor.insertText(" changed", replacementRange: NSRange(location: editor.string.utf16.count, length: 0))
    editor.breakUndoCoalescing()
    guard editor.string == "original changed", editor.undoManager?.canUndo == true else { return false }
    editor.undoManager?.undo()
    guard editor.string == "original", editor.undoManager?.canRedo == true else { return false }
    editor.undoManager?.redo()
    let actions = Set(NSApp.mainMenu?.items.last?.submenu?.items.compactMap { $0.action.map(NSStringFromSelector) } ?? [])
    return editor.string == "original changed" && !editor.isRichText && actions.isSuperset(of: ["copy:", "paste:", "cut:", "undo:", "redo:", "selectAll:"])
}
