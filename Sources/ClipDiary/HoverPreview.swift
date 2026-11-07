import AppKit
import SwiftUI
import ClipDiaryCore

/// A single preview belongs to the panel, never to an individual reusable row.
struct InstantHoverPreview: NSViewRepresentable {
    let item: ClipRecord
    static func dismiss() { HoverPreviewController.shared.dismiss() }
    func makeNSView(context: Context) -> HoverAnchor { HoverAnchor(item: item) }
    func updateNSView(_ view: HoverAnchor, context: Context) {
        let changed = view.item.text != item.text || view.item.title != item.title || view.item.thumbnailPath != item.thumbnailPath || view.item.source != item.source || view.item.capturedAt != item.capturedAt || view.item.byteCount != item.byteCount
        view.item = item
        if changed { HoverPreviewController.shared.contentChanged(view) }
    }
    static func dismantleNSView(_ view: HoverAnchor, coordinator: ()) { HoverPreviewController.shared.remove(view) }

    final class HoverAnchor: NSView {
        var item: ClipRecord
        private var tracking: NSTrackingArea?
        init(item: ClipRecord) {
            self.item = item
            super.init(frame: .zero)
            HoverPreviewController.shared.add(self)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
            addTrackingArea(area); tracking = area
        }
        override func mouseEntered(with event: NSEvent) { HoverPreviewController.shared.pointerMoved() }
        override func mouseExited(with event: NSEvent) { HoverPreviewController.shared.pointerMoved() }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { HoverPreviewController.shared.remove(self) }
            else { HoverPreviewController.shared.add(self) }
        }
    }
}

@MainActor
private final class HoverPreviewController {
    static let shared = HoverPreviewController()
    private let anchors = NSHashTable<InstantHoverPreview.HoverAnchor>.weakObjects()
    private let popover = NSPopover()
    private let content = NSViewController()
    private weak var current: InstantHoverPreview.HoverAnchor?
    private var currentID: String?
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var updateScheduled = false
    private var suppressed = false
    private var dismissedAt = NSPoint.zero
    private var scrollSettling = false
    private var scrollUpdate: DispatchWorkItem?
    private var menuTracking = false

    private init() {
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.contentViewController = content
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .scrollWheel]) { [weak self] event in
            MainActor.assumeIsolated {
                if event.type == .scrollWheel { self?.scrolling() }
                else { self?.pointerMoved() }
            }
            return event
        }
        let center = NotificationCenter.default
        for name in [Notification.Name.diaryPanelClosed, NSApplication.didResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss() }
            })
        }
        observers.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.menuTracking = true; self?.hide() }
        })
        observers.append(center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.menuTracking = false }
        })
        observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard notification.object is NSClipView else { return }
                guard let self, !self.suppressed else { return }
                self.scrolling()
            }
        })
    }
    func add(_ anchor: InstantHoverPreview.HoverAnchor) {
        anchors.add(anchor)
        anchor.enclosingScrollView?.contentView.postsBoundsChangedNotifications = true
    }
    func remove(_ anchor: InstantHoverPreview.HoverAnchor) {
        if current === anchor { hide() }
        anchors.remove(anchor)
    }
    func contentChanged(_ anchor: InstantHoverPreview.HoverAnchor) {
        if current === anchor { hide(); scheduleUpdate() }
    }
    func dismiss() {
        suppressed = true
        dismissedAt = NSEvent.mouseLocation
        scrollUpdate?.cancel(); scrollUpdate = nil; scrollSettling = false
        hide()
    }
    func pointerMoved() {
        if suppressed && NSEvent.mouseLocation == dismissedAt { return }
        suppressed = false
        if !scrollSettling { update() }
    }
    private func scrolling() {
        suppressed = false
        scrollSettling = true
        hide()
        scrollUpdate?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.scrollSettling = false
            self.update()
        }
        scrollUpdate = work
        // Avoid building previews for rows that pass under a stationary cursor during momentum.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }
    private func scheduleUpdate() {
        guard !updateScheduled else { return }
        updateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updateScheduled = false
            self.update()
        }
    }
    func hide() {
        popover.close()
        current = nil; currentID = nil
    }
    func update() {
        guard NSApp.isActive, !menuTracking, !suppressed, !scrollSettling else { hide(); return }
        let mouse = NSEvent.mouseLocation
        let topWindow = NSWindow.windowNumber(at: mouse, belowWindowWithWindowNumber: 0)
        let hovered = anchors.allObjects.first { anchor in
            guard let window = anchor.window, window.isVisible, window.windowNumber == topWindow, !anchor.isHiddenOrHasHiddenAncestor else { return false }
            let local = anchor.convert(window.convertPoint(fromScreen: mouse), from: nil)
            return anchor.bounds.contains(local) && anchor.visibleRect.contains(local)
        }
        guard let anchor = hovered else { hide(); return }
        guard current !== anchor || currentID != anchor.item.id || !popover.isShown else { return }
        hide()
        current = anchor; currentID = anchor.item.id
        let size = configureContent(anchor.item)
        popover.contentSize = size
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxX)
    }
    func checkNativeLayouts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ClipDiary-HoverChecks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ClipStore(directory: root)
        var items: [ClipRecord] = []
        for value in ["Short preview", String(repeating: "Wrapped text ", count: 80), String(repeating: "LongLine", count: 100), (1...20).map { "Line \($0)" }.joined(separator: "\n")] {
            if let item = try store.addText(value, source: "Layout fixture") { items.append(item) }
        }
        for dimensions in [(32, 96), (96, 32)] {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: dimensions.0, pixelsHigh: dimensions.1, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            memset(bitmap.bitmapData!, 255, bitmap.bytesPerRow * bitmap.pixelsHigh)
            let data = bitmap.representation(using: .png, properties: [:])!
            if let item = try store.addImage(data: data, title: "Image fixture", source: "Layout fixture", deduplicate: false) { items.append(item) }
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 330, height: 420), styleMask: [.borderless], backing: .buffered, defer: false)
        var samples: [Double] = []
        for item in items {
            let start = CFAbsoluteTimeGetCurrent()
            let size = configureContent(item)
            window.contentView = content.view
            content.view.setFrameSize(size)
            content.view.layoutSubtreeIfNeeded()
            samples.append((CFAbsoluteTimeGetCurrent() - start) * 1_000)
            guard size.width == 330, size.height.isFinite, (80...420).contains(size.height),
                  let stack = content.view.subviews.first as? NSStackView,
                  !content.view.hasAmbiguousLayout, !stack.hasAmbiguousLayout,
                  stack.arrangedSubviews.allSatisfy({ $0.frame.height > 0 }),
                  stack.frame.maxY <= size.height + 1 else {
                throw NSError(domain: "HoverLayout", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid preview layout for \(item.title)"])
            }
        }
        window.contentView = nil
        print("PASS: six native hover layouts (wrapped/long text, portrait/landscape); maximum build \(String(format: "%.2f", samples.max() ?? 0)) ms")
    }
    private func configureContent(_ item: ClipRecord) -> NSSize {
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 9
        func label(_ value: String, size: CGFloat, secondary: Bool = false) -> NSTextField {
            let field = NSTextField(wrappingLabelWithString: value)
            field.font = .systemFont(ofSize: size)
            field.textColor = secondary ? .secondaryLabelColor : .labelColor
            field.isSelectable = false
            field.preferredMaxLayoutWidth = 304
            field.widthAnchor.constraint(equalToConstant: 304).isActive = true
            return field
        }
        if item.kind == .text {
            let bounded = String((item.text ?? "").prefix(601))
            let lines = bounded.split(separator: "\n", omittingEmptySubsequences: false)
            let clipped = String(lines.prefix(12).joined(separator: "\n").prefix(600))
            let text = label(clipped + (bounded.count > 600 || lines.count > 12 ? "…" : ""), size: 12)
            text.maximumNumberOfLines = 12
            text.lineBreakMode = .byTruncatingTail
            stack.addArrangedSubview(text)
        } else if let path = item.thumbnailPath {
            if let image = ThumbnailCache.shared.image(at: path) {
                let view = NSImageView(image: image)
                view.imageScaling = .scaleProportionallyUpOrDown
                let ratio = image.size.width > 0 ? image.size.height / image.size.width : 1
                view.widthAnchor.constraint(equalToConstant: 304).isActive = true
                view.heightAnchor.constraint(equalToConstant: min(210, 304 * ratio)).isActive = true
                stack.addArrangedSubview(view)
            }
        }
        let divider = NSBox(); divider.boxType = .separator
        divider.widthAnchor.constraint(equalToConstant: 304).isActive = true
        stack.addArrangedSubview(divider)
        stack.addArrangedSubview(label("\(item.source)\n\(item.capturedAt.formatted(date: .abbreviated, time: .shortened))\n\(ByteCountFormatter.string(fromByteCount: Int64(item.byteCount), countStyle: .file))", size: 10, secondary: true))
        let container = NSView()
        container.addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 13),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -13),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 13),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -13)
        ])
        content.view = container
        container.layoutSubtreeIfNeeded()
        return NSSize(width: 330, height: max(80, min(420, stack.fittingSize.height + 26)))
    }
}

/// Reuse decoded thumbnails across row redraws and hover previews; bound memory use.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let images = NSCache<NSString, NSImage>()
    private init() {
        images.countLimit = 64
        images.totalCostLimit = 24 * 1_024 * 1_024
    }
    func image(at path: String) -> NSImage? {
        if let image = images.object(forKey: path as NSString) { return image }
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        let pixels = image.representations.reduce(0) { $0 + $1.pixelsWide * $1.pixelsHigh * 4 }
        images.setObject(image, forKey: path as NSString, cost: max(pixels, 1))
        return image
    }
}

@MainActor
func runHoverPreviewLayoutChecks() -> Bool {
    do { try HoverPreviewController.shared.checkNativeLayouts(); return true }
    catch { print("FAIL: hover preview layout: \(error.localizedDescription)"); return false }
}
