import AppKit
import CoreGraphics
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
    var contextMenuProvider: (() -> NSMenu?)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard interactiveRect.contains(point) else { return nil }
        // SwiftUI's internal views do not reliably surface right-clicks in a nonactivating panel.
        // Claim that event at the AppKit hosting boundary and open the native menu directly.
        if NSApp.currentEvent?.type == .rightMouseDown { return self }
        return super.hitTest(point)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = contextMenuProvider?() else {
            super.rightMouseDown(with: event)
            return
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    /// Deliver the first click even though the app is never active (the panel never becomes
    /// key), so tapping the island works without a focus-shifting "activation click" first.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Owns the panel + hosting view and keeps the island positioned on the correct screen.
@MainActor
final class NotchWindowController: NSObject {
    private let model: IslandModel
    private var panel: NotchPanel?
    private var hosting: PassthroughHostingView<IslandRootView>?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var mouseTimer: Timer?
    private var lastPointerInside: Bool?
    private var hoverIntent: DispatchWorkItem?

    init(model: IslandModel) {
        self.model = model
        super.init()
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
        hosting.contextMenuProvider = { [weak self] in
            guard let self else { return nil }
            NSLog("Pookify Copilot: opening context menu from hosting view.")
            return self.contextMenu()
        }
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
        let showsLever = model.style == .slotMachine && model.isTall
        let leverSpace = showsLever ? Theme.leverWidth * 2 : 0
        let zoneWidth = Theme.wing + model.notchWidth + Theme.wing + leverSpace
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
        updateHover(pointerInside: pointerInside, viewPoint: viewPoint)
    }

    /// Hover is derived from the pointer position here rather than SwiftUI's `onHover`. The panel
    /// only starts accepting mouse events once the pointer is already inside the island, so AppKit
    /// tracking areas frequently never report an "entered" event and the island would not expand.
    private func updateHover(pointerInside: Bool, viewPoint: CGPoint) {
        if pointerInside {
            if !model.hovering, !model.suppressHoverUntilExit, hoverIntent == nil {
                // A short intent delay so a pointer merely passing the menu bar doesn't pop it open.
                let work = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.hoverIntent = nil
                        guard self.lastPointerInside == true,
                              !self.model.suppressHoverUntilExit else { return }
                        self.model.hovering = true
                        self.updateInteractiveZone()
                    }
                }
                hoverIntent = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
            }
        } else {
            hoverIntent?.cancel()
            hoverIntent = nil
            if model.suppressHoverUntilExit { model.suppressHoverUntilExit = false }
            if model.hovering { model.hovering = false }
        }

        let hoveredID = pointerInside ? sessionIndex(atViewPoint: viewPoint).map { model.sessions[$0].id } : nil
        if model.hoveredSessionID != hoveredID { model.hoveredSessionID = hoveredID }
    }

    /// The session row at a point in hosting-view coordinates, or nil for the top bar, gutters,
    /// padding, or a collapsed island. A single session's whole drop-down counts as its row.
    private func sessionIndex(atViewPoint viewPoint: CGPoint) -> Int? {
        guard model.isVisible, model.isTall, let hosting else { return nil }
        let rect = hosting.interactiveRect
        guard rect.contains(viewPoint) else { return nil }
        if model.style == .slotMachine,
           viewPoint.x >= rect.maxX - Theme.leverWidth || viewPoint.x <= rect.minX + Theme.leverWidth {
            return nil
        }
        let yFromTop = hosting.isFlipped ? viewPoint.y : hosting.bounds.height - viewPoint.y
        guard yFromTop > model.topInset else { return nil }
        guard model.isMulti else { return model.sessions.isEmpty ? nil : 0 }

        let rowY = yFromTop - model.topInset + sessionScrollOffset() - 7 // stack's top padding
        guard rowY >= 0 else { return nil }
        let stride = Theme.sessionRowHeight + Theme.sessionRowSpacing
        let index = Int(rowY / stride)
        let withinRow = rowY - CGFloat(index) * stride
        guard withinRow <= Theme.sessionRowHeight, model.sessions.indices.contains(index) else {
            return nil
        }
        return index
    }

    /// Call when visibility or expansion changes so the window-level mouse routing follows the
    /// exact current pill footprint.
    func refreshInteractivity() { updateInteractiveZone() }

    /// Window-level `ignoresMouseEvents` is the only reliable way to pass clicks through to
    /// another application's fullscreen window. Global and local monitors cover movement both
    /// outside and inside this app. They also dispatch left clicks directly from the known pill
    /// geometry because SwiftUI controls inside a nonactivating panel do not reliably receive
    /// their action. The timer handles a stationary pointer when the island appears or changes.
    private func installMouseRouting() {
        let mask: NSEvent.EventTypeMask = [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .leftMouseDown,
            .rightMouseDown,
        ]
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.updateInteractiveZone()
                    if event.type == .leftMouseDown {
                        _ = self.routeLeftClick(atScreenPoint: NSEvent.mouseLocation)
                    } else if event.type == .rightMouseDown {
                        _ = self.routeContextMenu(atScreenPoint: NSEvent.mouseLocation)
                    }
                }
            }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self else { return false }
                self.updateInteractiveZone()
                guard event.window === self.panel else { return false }
                switch event.type {
                case .leftMouseDown:
                    return self.routeLeftClick(atWindowPoint: event.locationInWindow)
                case .rightMouseDown:
                    return self.routeContextMenu(atWindowPoint: event.locationInWindow)
                default:
                    return false
                }
            }
            if handled { return nil }
            return event
        }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateInteractiveZone() }
        }
        RunLoop.main.add(timer, forMode: .common)
        mouseTimer = timer
    }

    private func routeLeftClick(atScreenPoint point: NSPoint) -> Bool {
        guard let panel else { return false }
        return routeLeftClick(atWindowPoint: panel.convertPoint(fromScreen: point))
    }

    private func routeContextMenu(atScreenPoint point: NSPoint) -> Bool {
        guard let panel else { return false }
        return routeContextMenu(atWindowPoint: panel.convertPoint(fromScreen: point))
    }

    private func routeContextMenu(atWindowPoint point: NSPoint) -> Bool {
        guard model.isVisible, let hosting else { return false }
        let viewPoint = hosting.convert(point, from: nil)
        guard hosting.interactiveRect.contains(viewPoint) else { return false }

        NSLog("Pookify Copilot: opening context menu.")
        contextMenu().popUp(positioning: nil, at: viewPoint, in: hosting)
        return true
    }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        if NSScreen.screens.count > 1 {
            let displayItem = NSMenuItem(title: "Display", action: nil, keyEquivalent: "")
            let displayMenu = NSMenu(title: "Display")
            displayMenu.autoenablesItems = false

            let automatic = NSMenuItem(
                title: "Automatic",
                action: #selector(selectDisplay(_:)),
                keyEquivalent: ""
            )
            automatic.target = self
            automatic.representedObject = NSNumber(value: 0)
            automatic.state = NSScreen.preferredDisplayConnected ? .off : .on
            automatic.isEnabled = true
            displayMenu.addItem(automatic)
            displayMenu.addItem(.separator())

            for screen in NSScreen.screens {
                guard let displayID = screen.displayID else { continue }
                let item = NSMenuItem(
                    title: screenLabel(screen),
                    action: #selector(selectDisplay(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = NSNumber(value: displayID)
                item.state = NSScreen.preferredDisplayID == displayID ? .on : .off
                item.isEnabled = true
                displayMenu.addItem(item)
            }
            displayItem.submenu = displayMenu
            displayItem.isEnabled = true
            menu.addItem(displayItem)
        }

        let styleItem = NSMenuItem(title: "Style", action: nil, keyEquivalent: "")
        let styleMenu = NSMenu(title: "Style")
        styleMenu.autoenablesItems = false
        for style in IslandStyle.allCases {
            let item = NSMenuItem(
                title: style.title,
                action: #selector(selectStyle(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = style.rawValue
            item.state = model.style == style ? .on : .off
            item.isEnabled = true
            styleMenu.addItem(item)
        }
        styleItem.submenu = styleMenu
        styleItem.isEnabled = true
        menu.addItem(styleItem)

        menu.addItem(.separator())
        let quit = NSMenuItem(
            title: "Quit Pookify Copilot",
            action: #selector(quitFromMenu(_:)),
            keyEquivalent: ""
        )
        quit.target = self
        quit.isEnabled = true
        menu.addItem(quit)
        return menu
    }

    private func screenLabel(_ screen: NSScreen) -> String {
        var name = screen.localizedName
        if screen.hasNotch {
            name += " (built-in)"
        } else if screen == NSScreen.screens.first {
            name += " (main)"
        }
        return name
    }

    @objc private func selectDisplay(_ sender: NSMenuItem) {
        let rawValue = (sender.representedObject as? NSNumber)?.uint32Value ?? 0
        model.hovering = false
        model.onChooseDisplay(rawValue == 0 ? nil : CGDirectDisplayID(rawValue))
    }

    @objc private func selectStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let style = IslandStyle(rawValue: raw) else { return }
        IslandStyle.saved = style
        model.style = style
    }

    @objc private func quitFromMenu(_ sender: NSMenuItem) {
        model.onQuit()
    }

    /// Handle only the visible top bar and visible session content. Transparent panel space never
    /// reaches this method because it lies outside `interactiveRect`.
    private func routeLeftClick(atWindowPoint point: NSPoint) -> Bool {
        guard model.isVisible, let hosting else { return false }
        let viewPoint = hosting.convert(point, from: nil)
        guard hosting.interactiveRect.contains(viewPoint) else { return false }

        // Slot machine: the right gutter holds the lever, the left one only mirrors it.
        if model.style == .slotMachine, model.isTall {
            let rect = hosting.interactiveRect
            if viewPoint.x >= rect.maxX - Theme.leverWidth {
                NSLog("Pookify Copilot: lever pulled.")
                model.spinCount += 1
                return true
            }
            if viewPoint.x <= rect.minX + Theme.leverWidth { return true }
        }

        let yFromTop = hosting.isFlipped ? viewPoint.y : hosting.bounds.height - viewPoint.y
        if yFromTop <= model.topInset {
            activateTopBar()
            return true
        }

        guard model.isTall else { return false }
        if !model.isMulti {
            activateOnlySession()
            return true
        }

        guard let index = sessionIndex(atViewPoint: viewPoint) else { return false }
        let session = model.sessions[index]
        NSLog("Pookify Copilot: routed click to session row \(index), \(session.id).")
        model.onSelectSession(session.id)
        return true
    }

    private func activateTopBar() {
        if model.sessions.count == 1 {
            activateOnlySession()
        } else {
            model.onActivate?()
        }
    }

    private func activateOnlySession() {
        guard let session = model.sessions.first else { return }
        model.suppressHoverUntilExit = true
        model.hovering = false
        model.userExpanded = false
        model.onSelectSession(session.id)
        updateInteractiveZone()
    }

    /// Account for rows beyond the tenth after the user scrolls the stack.
    private func sessionScrollOffset() -> CGFloat {
        guard let hosting, let scrollView = firstScrollView(in: hosting) else { return 0 }
        return max(0, scrollView.contentView.bounds.minY)
    }

    private func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView { return scrollView }
        for child in view.subviews {
            if let match = firstScrollView(in: child) { return match }
        }
        return nil
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
