import AppKit
import SwiftUI

/// A borderless panel that floats over the notch on every Space, above the menu bar, without
/// stealing focus from the user's terminal. The controller toggles window-level mouse ignoring
/// so transparent areas never intercept fullscreen applications.
final class NotchPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isFloatingPanel = true
        // Sit just above the menu bar / ordinary status items so the island is always visible.
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovableByWindowBackground = false
        isMovable = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        ignoresMouseEvents = true
        acceptsMouseMovedEvents = true
        // Don't show in the window cycle / screenshots of windows.
        isExcludedFromWindowsMenu = true
    }

    // SwiftUI buttons require a key-capable window to receive their first click reliably. The
    // nonactivatingPanel style keeps the app itself from activating, and becomesKeyOnlyIfNeeded
    // limits key status to controls that need it; selecting a row immediately reactivates the
    // corresponding terminal.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Hosting view that additionally limits AppKit hit testing to the visible pill. Cross-application
/// pass-through is handled by `NotchPanel.ignoresMouseEvents`; returning nil here is only a second
/// guard while the window is interactive.
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    var interactiveRect: CGRect = .zero

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard interactiveRect.contains(point) else { return nil }
        return super.hitTest(point)
    }

    /// Deliver the first click even though the app is never active (the panel never becomes
    /// key), so tapping the island works without a focus-shifting "activation click" first.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Owns the panel + hosting view and keeps the island positioned on the correct screen.
@MainActor
final class NotchWindowController {
    private let model: IslandModel
    private var panel: NotchPanel?
    private var hosting: PassthroughHostingView<IslandRootView>?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var mouseTimer: Timer?
    private var lastPointerInside: Bool?

    init(model: IslandModel) {
        self.model = model
        // Register once, up front — independent of whether the first install() finds a screen — so a
        // display connecting later (e.g. app launched before screens settled) still builds the panel.
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    func install() {
        guard panel == nil, let screen = NSScreen.islandScreen else { return }
        applyScreen(screen)
        let frame = panelFrame(for: screen)

        let root = IslandRootView(model: model)
        let hosting = PassthroughHostingView(rootView: root)
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.frame = NSRect(origin: .zero, size: frame.size)
        hosting.layer?.isOpaque = false

        let panel = NotchPanel(contentRect: frame)
        panel.contentView = hosting
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()

        self.panel = panel
        self.hosting = hosting
        installMouseRouting()
        updateInteractiveZone()
    }

    /// Feed the screen's notch geometry to the model so content can flank the camera correctly.
    /// On displays without a physical notch, the island draws a synthetic one with real-notch
    /// proportions, so it looks exactly the same everywhere.
    /// Dev: ISLAND_FORCE_NO_NOTCH=1 exercises the synthetic path on a notched Mac.
    private func applyScreen(_ screen: NSScreen) {
        let forceNoNotch = ProcessInfo.processInfo.environment["ISLAND_FORCE_NO_NOTCH"] == "1"
        if screen.hasNotch && !forceNoNotch {
            model.topInset = screen.islandTopInset
            model.notchWidth = screen.notchSize?.width ?? NSScreen.syntheticNotchWidth
            model.hasNotch = true
        } else {
            model.topInset = screen.syntheticNotchHeight
            model.notchWidth = NSScreen.syntheticNotchWidth
            model.hasNotch = false
        }
    }

    /// Panel covers the top strip of the screen, anchored to the very top so SwiftUI's top edge
    /// aligns with the screen top (and thus the notch).
    private func panelFrame(for screen: NSScreen) -> NSRect {
        let w = screen.frame.width
        // Reserve enough transparent host space for ten full rows plus the partial overflow row.
        // Hit testing still only claims the pill itself, so the larger panel does not block apps.
        let expandedStack = Theme.stackDropHeight(Theme.sessionRowsVisible + 1)
        let h = min(screen.frame.height, max(240, ceil(model.topInset + expandedStack + 40)))
        return NSRect(x: screen.frame.minX,
                      y: screen.frame.maxY - h,
                      width: w,
                      height: h)
    }

    private func updateInteractiveZone() {
        guard let panel, let hosting else { return }
        let h = hosting.bounds.height
        let w = hosting.bounds.width
        let zoneWidth = Theme.wing + model.notchWidth + Theme.wing
        let zoneHeight = model.topInset + (model.isTall ? model.dropHeight : 0)
        let rect = CGRect(
            x: (w - zoneWidth) / 2,
            y: hosting.isFlipped ? 0 : h - zoneHeight,
            width: zoneWidth,
            height: zoneHeight
        )
        hosting.interactiveRect = model.isVisible ? rect : .zero

        let windowPoint = panel.convertPoint(fromScreen: NSEvent.mouseLocation)
        let viewPoint = hosting.convert(windowPoint, from: nil)
        let pointerInside = model.isVisible && rect.contains(viewPoint)
        if ProcessInfo.processInfo.environment["ISLAND_DEBUG"] == "1",
           lastPointerInside != pointerInside {
            NSLog(
                "Pookify Copilot: mouse routing screen=\(NSEvent.mouseLocation) "
                + "view=\(viewPoint) rect=\(rect) inside=\(pointerInside)"
            )
        }
        lastPointerInside = pointerInside
        let shouldIgnoreMouse = !pointerInside
        if panel.ignoresMouseEvents != shouldIgnoreMouse {
            panel.ignoresMouseEvents = shouldIgnoreMouse
        }
        if !pointerInside, model.hovering {
            model.hovering = false
        }
    }

    /// Call when visibility or expansion changes so the window-level mouse routing follows the
    /// exact current pill footprint.
    func refreshInteractivity() { updateInteractiveZone() }

    /// Window-level `ignoresMouseEvents` is the only reliable way to pass clicks through to
    /// another application's fullscreen window. Global and local monitors cover movement both
    /// outside and inside this app; the timer also handles a stationary pointer when the island
    /// appears or changes size.
    private func installMouseRouting() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.updateInteractiveZone() }
            }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.updateInteractiveZone() }
            return event
        }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateInteractiveZone() }
        }
        RunLoop.main.add(timer, forMode: .common)
        mouseTimer = timer
    }

    @objc private func screensChanged() { relocate() }

    /// Move the island onto the currently-elected screen (`NSScreen.islandScreen`), building the
    /// panel first if it doesn't exist yet. Called on display changes and when the user picks a
    /// screen from the context menu.
    func relocate() {
        // A screen appeared after a deferred launch (none available at install time) → build now.
        if panel == nil { install(); return }
        guard let panel, let screen = NSScreen.islandScreen else { return }
        applyScreen(screen)
        let frame = panelFrame(for: screen)
        panel.setFrame(frame, display: true)
        hosting?.frame = NSRect(origin: .zero, size: frame.size)
        updateInteractiveZone()
    }

    func tearDown() {
        NotificationCenter.default.removeObserver(self)
        if let monitor = globalMouseMonitor {
            NSEvent.removeMonitor(monitor)
            globalMouseMonitor = nil
        }
        if let monitor = localMouseMonitor {
            NSEvent.removeMonitor(monitor)
            localMouseMonitor = nil
        }
        mouseTimer?.invalidate()
        mouseTimer = nil
        panel?.orderOut(nil)
        panel = nil
        hosting = nil
    }
}
