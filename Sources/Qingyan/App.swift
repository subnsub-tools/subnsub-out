import AppKit
import SwiftUI
import Combine
import QingyanCore

@main
enum QingyanApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

/// What the panel's window holds: glass over all of it, the column, and the side drawer (History or Settings).
final class PanelContainer: NSView {
    let glass = NSVisualEffectView()
    let column: NSView
    let drawer: NSView

    init(column: NSView, drawer: NSView) {
        self.column = column; self.drawer = drawer
        super.init(frame: NSRect(x: 0, y: 0, width: Metrics.width, height: Metrics.defaultHeight))
        wantsLayer = true
        layer?.masksToBounds = true
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.frame = bounds
        glass.autoresizingMask = [.width, .height]
        addSubview(glass)
        addSubview(drawer)
        addSubview(column)
        pin(drawerLeft: false)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func pin(drawerLeft: Bool) {
        let height = bounds.height
        if drawerLeft {
            column.frame = NSRect(x: bounds.width - Metrics.width, y: 0, width: Metrics.width, height: height)
            drawer.frame = NSRect(x: bounds.width - Metrics.width - Metrics.drawer, y: 0, width: Metrics.drawer, height: height)
            column.autoresizingMask = [.minXMargin, .height]; drawer.autoresizingMask = [.minXMargin, .height]
        } else {
            column.frame = NSRect(x: 0, y: 0, width: Metrics.width, height: height)
            drawer.frame = NSRect(x: Metrics.width, y: 0, width: Metrics.drawer, height: height)
            column.autoresizingMask = [.maxXMargin, .height]; drawer.autoresizingMask = [.maxXMargin, .height]
        }
    }
}

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private var settings: SettingsStore!
    private var controller: DictationController!
    private var window: NSWindow?
    private var overlay: NSPanel?
    private var overlayHost: NSHostingView<VoiceBar>?
    /// The capsule's size as SwiftUI last laid it out.
    private var overlayReportedSize: CGSize?
    private var overlayCorner: OverlayPlacement.AnchorCorner = .topCenter
    private var overlayScreenFrame: CGRect?
    private var overlayAnchorOrigin: CGPoint?
    private var overlayDraggedByUser = false
    private var statusItem: NSStatusItem?
    private var timer: Timer?
    private var observations: [NSObjectProtocol] = []
    private var languageSubscription: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if let index = CommandLine.arguments.firstIndex(of: "--render-previews"), CommandLine.arguments.count > index + 1 {
            Task { @MainActor in
                do { try await renderPreviews(to: CommandLine.arguments[index + 1]); NSApp.terminate(nil) }
                catch { fputs("Preview failed: \(error)\n", stderr); exit(1) }
            }
            return
        }
        #endif
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: "local.hopo.qingyan")
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if let existing = others.first { existing.activate(); NSApp.terminate(nil); return }
        // A copy still at the name from before the rename moves to put.app and starts again there.
        if Relocation.moveIfNeeded() { return }
        let loginItemRenewed = Relocation.renewLoginItem()
        settings = SettingsStore()
        if !loginItemRenewed { settings.loginMessage = tr("Open at login could not be set up again after the app moved to put.app. Turn it on again here.") }
        controller = DictationController(settings: settings)
        settings.openPanel = { [weak self] in self?.showWindow() }
        installMainMenu()
        // The menu bar's words and the status item's tooltip are set once; a change of language
        // sets them again.
        languageSubscription = settings.$preferences.map(\.language).removeDuplicates().dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.installMainMenu(); self?.labelStatusItem() } }
        controller.openSettings = { [weak self] in self?.showWindow() }
        controller.presentOverlay = { [weak self] in self?.showOverlay() }
        controller.dismissOverlay = { [weak self] in self?.hideOverlay() }
        installStatusItem()
        controller.refresh()
        let scheduled = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.controller.refresh()
                KnockProbe.poll(settings: self.settings, identity: self.controller.identity, name: self.controller.deviceName, busy: self.controller.busy)
                self.controller.shelf.probe()
            }
        }
        scheduled.tolerance = 0.6
        timer = scheduled
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observations.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.controller.suspend() }
            })
        }
        observations.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.relocateOverlayIfObstructed() }
        })
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "panelOpenBeforeUpdate")
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        let renewed = defaults.string(forKey: "panelShownForBuild") != build
        defaults.set(build, forKey: "panelShownForBuild")
        if renewed { showWindow(activating: false, inFront: true) }
        else if defaults.object(forKey: "panelOpen") as? Bool != false { showWindow(activating: false) }
        controller.updater.start()
        if CommandLine.arguments.contains("--setup-permissions") {
            settings.section = nil
            Task { @MainActor in
                await settings.requestSetupPermissions()
                controller.refresh()
            }
        } else if CommandLine.arguments.contains("--take-over-fn") {
            settings.reveal(.keyboard)
            controller.takeOverFn()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        settings?.flushPersistence()
        controller?.suspend(); controller?.shortcut.stop()
        PasteboardLease.general.restore()
        observations.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }

    private func installStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // The word alone, and any click opens the menu (its Show Main Panel opens the panel).
        if let button = statusItem?.button {
            button.title = "put"
            button.image = nil
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem?.menu = menu
        labelStatusItem()
    }

    /// The status item's tooltip and spoken name, in the chosen language.
    private func labelStatusItem() {
        guard let button = statusItem?.button else { return }
        button.toolTip = tr("put · Click for the menu")
        button.setAccessibilityLabel(tr("put, opens its menu"))
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        item(menu, controller.phase == .recording ? tr("put · Recording") : tr("put · %@ to Start or Stop", settings.shortcutLabel), nil)?.isEnabled = false
        menu.addItem(.separator())
        if controller.phase == .recording { item(menu, tr("Stop Recording"), #selector(stopRecording)) }
        if !controller.busy { item(menu, tr("Start Recording"), #selector(startRecording)) }
        if controller.busy { item(menu, tr("Cancel Recording"), #selector(cancelRecording)) }
        if !controller.busy { item(menu, tr("Type the Clipboard (⌃⌥V)"), #selector(typeClipboard)) }
        item(menu, tr("Show Main Panel"), #selector(openMain))
        item(menu, tr("Settings…"), #selector(openSettings))
        if !controller.result.isEmpty { item(menu, tr("Copy Last Result"), #selector(copyResult)) }
        menu.addItem(.separator())
        item(menu, tr("Quit put"), #selector(quit))
    }

    @discardableResult private func item(_ menu: NSMenu, _ title: String, _ action: Selector?) -> NSMenuItem? {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self; menu.addItem(item); return item
    }
    @objc private func openMain() { showWindow() }
    @objc private func openSettings() { settings.reveal(.general) }
    @objc private func startRecording() { controller.toggle() }
    @objc private func typeClipboard() { controller.typeClipboard(from: .menu) }
    @objc private func stopRecording() { controller.finish() }
    @objc private func cancelRecording() { controller.cancel() }
    @objc private func copyResult() { controller.copyResult() }
    @objc private func quit() { NSApp.terminate(nil) }

    private func installMainMenu() {
        let main = NSMenu()
        let application = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = application
        main.addItem(appItem)
        let preferences = NSMenuItem(title: tr("Settings…"), action: #selector(openSettings), keyEquivalent: ",")
        preferences.target = self
        application.addItem(preferences)
        application.addItem(.separator())
        let hide = NSMenuItem(title: tr("Hide put"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        hide.target = NSApp
        application.addItem(hide)
        let quit = NSMenuItem(title: tr("Quit put"), action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        application.addItem(quit)
        let edit = NSMenu(title: tr("Edit"))
        let editItem = NSMenuItem(title: tr("Edit"), action: nil, keyEquivalent: "")
        editItem.submenu = edit
        main.addItem(editItem)
        for (title, action, key) in [(tr("Undo"), "undo:", "z"), (tr("Redo"), "redo:", "Z"),
                                      (tr("Cut"), "cut:", "x"), (tr("Copy"), "copy:", "c"),
                                      (tr("Paste"), "paste:", "v"), (tr("Select All"), "selectAll:", "a")] {
            edit.addItem(NSMenuItem(title: title, action: Selector(action), keyEquivalent: key))
        }
        NSApp.mainMenu = main
    }

    private func showWindow(activating: Bool = true, inFront: Bool = false) {
        guard settings != nil else { return }
        if window == nil {
            let window = makePanel(settings: settings, controller: controller)
            let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            let height = min(wishedHeight, Metrics.defaultHeight, (visible?.height ?? 900) - 16)
            let defaults = UserDefaults.standard
            if defaults.object(forKey: "panelLeft") != nil {
                window.setFrame(NSRect(x: defaults.double(forKey: "panelLeft"), y: defaults.double(forKey: "panelTop") - height,
                                       width: Metrics.width, height: height), display: false)
            } else if window.setFrameUsingName("input.panel") {
                let frame = window.frame
                window.setFrame(NSRect(x: frame.minX, y: frame.maxY - height, width: Metrics.width, height: height), display: false)
            } else if let visible {
                window.setContentSize(NSSize(width: Metrics.width, height: height))
                window.setFrameTopLeftPoint(NSPoint(x: visible.maxX - Metrics.width - 12, y: visible.maxY - 8))
            }
            window.delegate = self
            self.window = window
            followDrawer(of: window)
        }
        UserDefaults.standard.set(true, forKey: "panelOpen")
        defer { relocateOverlayIfObstructed() }
        guard activating else {
            if inFront { window?.orderFrontRegardless() } else { window?.orderFront(nil) }
            return
        }
        NSApp.unhide(nil)
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let window = self?.window, window.isVisible, !window.isMiniaturized, !window.isOnActiveSpace else { return }
            window.collectionBehavior.insert(.moveToActiveSpace)
            window.makeKeyAndOrderFront(nil)
            DispatchQueue.main.async { window.collectionBehavior.remove(.moveToActiveSpace) }
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        UserDefaults.standard.set(false, forKey: "panelOpen")
    }

    private func followDrawer(of window: NSWindow) {
        settings.drawerGoesLeft = { [weak self, weak window] in
            guard let self, let window else { return false }
            if window.frame.width > Metrics.width + 0.5 { return self.settings.drawerLeft }
            let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? window.frame
            let roomRight = visible.maxX - window.frame.maxX, roomLeft = window.frame.minX - visible.minX
            return roomRight < Metrics.drawer && roomLeft > roomRight
        }
        if settings.drawerOpen {
            settings.drawerLeft = settings.drawerGoesLeft?() ?? false
        }
        drawerSubscription = Publishers.CombineLatest(settings.$historyOpen, settings.$page)
            .map { history, page in history || page == .settings }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self, weak window] _ in
                DispatchQueue.main.async { if let self, let window { self.arrange(window, gliding: true) } }
            }
        let opened = Publishers.Merge3(
            settings.$section.removeDuplicates().dropFirst().map { $0 != nil },
            settings.$preferences.map(\.foldedBlocks.count).removeDuplicates()
                .scan((0, 0)) { ($0.1, $1) }.dropFirst().map { $0.1 < $0.0 },
            settings.detailOpened.map { _ in true })
        openSubscription = opened.filter { $0 }.sink { [weak self, weak window] _ in
            self?.wishedHeight = Self.unlimited
            DispatchQueue.main.async { if let self, let window { self.arrange(window, gliding: false) } }
        }
    }

    private func makePanel(settings: SettingsStore, controller: DictationController) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Metrics.width, height: Metrics.defaultHeight),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "put"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.managed, .fullScreenNone]
        window.contentMinSize = NSSize(width: Metrics.width, height: Metrics.minHeight)
        window.contentMaxSize = NSSize(width: Metrics.width, height: 10_000)
        let column = NSHostingView(rootView: MainView(settings: settings, controller: controller, shelf: controller.shelf,
                                                      onFit: { [weak self, weak window] height, live in
            self?.scheduleFit(window, content: height, live: live)
        }))
        let drawer = NSHostingView(rootView: SideDrawer(settings: settings, controller: controller))
        column.sizingOptions = []; drawer.sizingOptions = []
        if #unavailable(macOS 26.0) { column.safeAreaRegions = [] }
        window.contentView = PanelContainer(column: column, drawer: drawer)
        return window
    }

    private var wishedHeight: CGFloat {
        get { let saved = UserDefaults.standard.double(forKey: "panelWishedHeight"); return saved > 0 ? saved : Self.unlimited }
        set {
            if newValue >= Self.unlimited { UserDefaults.standard.removeObject(forKey: "panelWishedHeight") }
            else { UserDefaults.standard.set(Double(newValue), forKey: "panelWishedHeight") }
        }
    }
    private static let unlimited: CGFloat = 100_000
    private var contentHeight: CGFloat = 0
    private var pendingFit: (height: CGFloat, live: Bool)?
    /// The window has followed a moving block and has not been settled since.
    private var followed = false

    /// Coalesces multiple height preference updates within a single runloop tick into one window resize.
    /// `live`: a block of the panel is moving and this is the column's height on this frame — the
    /// last word of the tick decides, so a settled report after the last frame settles it.
    private func scheduleFit(_ window: NSWindow?, content: CGFloat, live: Bool) {
        guard let window, content > Metrics.titlebar else { return }
        let wasIdle = pendingFit == nil
        pendingFit = (content, live)
        guard wasIdle else { return }
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, let next = self.pendingFit else { return }
            self.pendingFit = nil
            self.contentHeight = next.height
            self.arrange(window, live: next.live)
        }
    }

    /// `gliding` animates the frame on a clock of its own — the drawer sliding out. `live` is one
    /// frame of a moving block: the window takes the height at once, so its lower edge stays with
    /// the content on every frame (operator 2026-11-18: opening and closing a block was not
    /// smoothly animated), and the place is remembered and the capsule moved only when the
    /// movement has settled.
    private func arrange(_ window: NSWindow, gliding glide: Bool = false, live: Bool = false) {
        guard contentHeight > Metrics.titlebar else { return }
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? window.frame
        let open = settings.drawerOpen, left = settings.drawerLeft
        (window.contentView as? PanelContainer)?.pin(drawerLeft: left)
        let width = Metrics.width + (open ? Metrics.drawer : 0)
        // Whole pixels, not whole points: a block moving a fraction of a point a frame would
        // otherwise drag the window's edge along in visible steps behind it.
        let scale = max(1, window.backingScaleFactor)
        let most = max(120, min((contentHeight * scale).rounded(.up) / scale, visible.height - 16))
        window.contentMinSize = NSSize(width: width, height: min(Metrics.minHeight, most))
        window.contentMaxSize = NSSize(width: width, height: most)
        guard !window.inLiveResize else { return }
        let target = min(wishedHeight, most)
        let frame = window.frame
        let column = left ? frame.maxX - Metrics.width : frame.minX
        var top = frame.maxY
        if top - target < visible.minY + 8 { top = min(visible.maxY, visible.minY + 8 + target) }
        let goal = NSRect(x: column - (open && left ? Metrics.drawer : 0), y: top - target, width: width, height: target)
        if live, fitted, gliding == nil, window.isVisible, !Motion.reduced {
            followed = true
            guard abs(frame.height - goal.height) * scale >= 0.5 || abs(frame.minY - goal.minY) * scale >= 0.5
                    || abs(frame.minX - goal.minX) > 0.5 || abs(frame.width - goal.width) > 0.5 else { return }
            window.setFrame(goal, display: true)
            return
        }
        if followed, !live {
            followed = false
            if !Self.same(frame, goal) { window.setFrame(goal, display: true) }
            rememberPlace(window)
            relocateOverlayIfObstructed()
            return
        }
        if let gliding, Self.same(gliding, goal) { return }
        guard !Self.same(frame, goal) else { return }
        guard glide, fitted, window.isVisible, !Motion.reduced else {
            fitted = true; gliding = nil; window.setFrame(goal, display: true); rememberPlace(window)
            relocateOverlayIfObstructed()
            return
        }
        gliding = goal
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Motion.duration
            context.timingFunction = CAMediaTimingFunction(controlPoints: Float(Motion.curve.0), Float(Motion.curve.1), Float(Motion.curve.2), Float(Motion.curve.3))
            window.animator().setFrame(goal, display: true)
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let gliding = self.gliding, Self.same(gliding, goal) else { return }
                self.gliding = nil
                self.rememberPlace(window)
                self.arrange(window)
                self.relocateOverlayIfObstructed()
            }
        })
    }

    private static func same(_ a: NSRect, _ b: NSRect) -> Bool {
        abs(a.minX - b.minX) <= 0.5 && abs(a.minY - b.minY) <= 0.5 && abs(a.width - b.width) <= 0.5 && abs(a.height - b.height) <= 0.5
    }

    private var fitted = false
    private var gliding: NSRect?
    private var drawerSubscription: AnyCancellable?
    private var openSubscription: AnyCancellable?

    private func rememberPlace(_ window: NSWindow) {
        guard gliding == nil, window.isVisible else { return }
        let frame = window.frame
        UserDefaults.standard.set(Double(settings.drawerLeft ? frame.maxX - Metrics.width : frame.minX), forKey: "panelLeft")
        UserDefaults.standard.set(Double(frame.maxY), forKey: "panelTop")
    }

    func windowDidMove(_ notification: Notification) {
        if let moved = notification.object as? NSWindow, moved === overlay {
            overlayDraggedByUser = true
            overlayAnchorOrigin = moved.frame.origin
            return
        }
        guard let window = notification.object as? NSWindow, window === self.window else { return }
        // Following a moving block moves the window's origin on every frame; that is remembered
        // and acted on once, when the movement settles (arrange).
        guard !followed else { return }
        rememberPlace(window)
        relocateOverlayIfObstructed()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === self.window else { return }
        let height = window.frame.height
        let most = window.contentMaxSize.height
        wishedHeight = height >= most - 1 ? Self.unlimited : height
        rememberPlace(window)
    }

    // MARK: - Miniature Floating Status Capsule

    private func measuredOverlaySize() -> CGSize {
        guard let host = overlayHost else { return OverlayPlacement.defaultSize }
        // The capsule's own view keeps no size of its own (sizingOptions = [], so that it never
        // resizes the panel by itself), and so its fittingSize is zero: every capsule used to open
        // at the smallest size, cut off at both ends. A throwaway view of the same content is measured.
        let probe = NSHostingView(rootView: host.rootView)
        probe.sizingOptions = .intrinsicContentSize
        let fitting = probe.fittingSize
        let width = min(max(ceil(fitting.width), 96), 248)
        let height = min(max(ceil(fitting.height), 38), 58)
        return CGSize(width: width, height: height)
    }

    private func showOverlay() {
        if overlay == nil {
            let panel = FloatingPanel(
                contentRect: NSRect(origin: .zero, size: OverlayPlacement.defaultSize),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.hidesOnDeactivate = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.isMovableByWindowBackground = true
            panel.delegate = self
            let host = NSHostingView(rootView: VoiceBar(
                controller: controller,
                meter: controller.meter,
                settings: settings,
                onSize: { [weak self] size in
                    DispatchQueue.main.async { self?.resizeOverlay(to: size) }
                }
            ))
            host.sizingOptions = []
            panel.contentView = host
            overlay = panel
            overlayHost = host
        }
        guard let overlay else { return }
        let wasHidden = !overlay.isVisible || overlay.alphaValue < 0.05
        if wasHidden { overlayDraggedByUser = false }
        overlayLeaving = false

        let size = measuredOverlaySize()
        let rest: CGPoint
        if overlayDraggedByUser, let visible = overlayScreenFrame ?? NSScreen.main?.visibleFrame {
            rest = OverlayPlacement.reanchor(frame: overlay.frame, newSize: size, corner: overlayCorner, in: visible).origin
        } else if let captured = SightSensor.capture(excludingPanel: window, previousOrigin: wasHidden ? nil : overlayAnchorOrigin) {
            let placement = OverlayPlacement.choose(size: size, in: captured.scene)
            overlayCorner = placement.corner
            overlayScreenFrame = captured.scene.visibleFrame
            overlayAnchorOrigin = placement.origin
            rest = placement.origin
        } else {
            let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            overlayScreenFrame = visible
            overlayCorner = .topCenter
            rest = CGPoint(x: round(visible.midX - size.width / 2), y: visible.maxY - size.height - 2)
            overlayAnchorOrigin = rest
        }

        let targetFrame = NSRect(origin: rest, size: size)
        guard !Motion.reduced else {
            overlay.alphaValue = 1
            overlay.setFrame(targetFrame, display: true)
            overlay.orderFrontRegardless()
            return
        }
        if wasHidden {
            let dy: CGFloat = (overlayCorner == .topCenter || overlayCorner == .topTrailing || overlayCorner == .topLeading) ? 6 : -6
            overlay.alphaValue = 0
            overlay.setFrame(NSRect(x: targetFrame.minX, y: targetFrame.minY + dy, width: size.width, height: size.height), display: true)
            overlay.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.85, 0.25, 1)
                overlay.animator().alphaValue = 1
                overlay.animator().setFrame(targetFrame, display: true)
            }, completionHandler: { [weak self] in
                // A size SwiftUI reported while the frame was still gliding was undone by it.
                MainActor.assumeIsolated { if let size = self?.overlayReportedSize { self?.resizeOverlay(to: size) } }
            })
        } else {
            overlay.orderFrontRegardless()
            overlay.alphaValue = 1
            if !Self.same(overlay.frame, targetFrame) {
                overlay.setFrame(targetFrame, display: true)
            }
        }
    }

    private func resizeOverlay(to rawSize: CGSize) {
        overlayReportedSize = rawSize
        guard let overlay, overlay.isVisible, !overlayLeaving else { return }
        let size = CGSize(
            width: min(max(ceil(rawSize.width), 96), 248),
            height: min(max(ceil(rawSize.height), 38), 58)
        )
        let visible = overlayScreenFrame ?? (overlay.screen ?? NSScreen.main)?.visibleFrame ?? overlay.frame
        let next = OverlayPlacement.reanchor(frame: overlay.frame, newSize: size, corner: overlayCorner, in: visible)
        guard !Self.same(overlay.frame, next) else { return }
        overlay.setFrame(next, display: true)
        if !overlayDraggedByUser { overlayAnchorOrigin = next.origin }
    }

    /// Re-checks whether a newly activated window, focused input field, or moved input panel now
    /// collides with the capsule, and glides it to an unobstructed spot if needed.
    private func relocateOverlayIfObstructed() {
        guard let overlay, overlay.isVisible, !overlayLeaving, !overlayDraggedByUser else { return }
        let pointer = NSEvent.mouseLocation
        // Never move the capsule out from under the user's hand when they are hovering it to click Stop or Cancel.
        guard !overlay.frame.insetBy(dx: -20, dy: -20).contains(pointer) else { return }
        guard let captured = SightSensor.capture(excludingPanel: window, previousOrigin: overlayAnchorOrigin) else { return }
        let sameScreen = captured.screen.frame.intersects(overlay.frame)
        guard !sameScreen || OverlayPlacement.isObstructed(overlay.frame, in: captured.scene) else { return }
        let size = overlay.frame.size
        let placement = OverlayPlacement.choose(size: size, in: captured.scene)
        overlayCorner = placement.corner
        overlayScreenFrame = captured.scene.visibleFrame
        overlayAnchorOrigin = placement.origin
        let goal = NSRect(origin: placement.origin, size: size)
        guard hypot(goal.minX - overlay.frame.minX, goal.minY - overlay.frame.minY) > 12 else { return }
        if Motion.reduced {
            overlay.setFrame(goal, display: true)
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1)
                overlay.animator().setFrame(goal, display: true)
            }
        }
    }

    private var overlayLeaving = false

    private func hideOverlay() {
        guard let overlay, overlay.isVisible else { return }
        guard !Motion.reduced else { overlay.orderOut(nil); return }
        overlayLeaving = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            overlay.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.overlayLeaving else { return }
                self.overlayLeaving = false
                overlay.orderOut(nil)
            }
        })
    }

    #if DEBUG
    private func renderPreviews(to directory: String) async throws {
        let settings = SettingsStore(preview: true)
        let controller = DictationController(settings: settings)
        self.settings = settings; self.controller = controller
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        var count = 0
        func panel(_ name: String, _ section: PanelSection? = nil, dark: Bool = false, drawer: Bool = false) async throws {
            if let section, [.connection, .keyboard, .dictionary, .general].contains(section) {
                settings.historyOpen = false
                settings.page = .settings
                try await capture(MainView(settings: settings, controller: controller, shelf: controller.shelf, windowed: false), dark: dark,
                                  width: Metrics.width + Metrics.drawer, path: "\(directory)/settings-\(name).png")
                settings.closeDrawer()
                count += 1
                return
            }
            settings.reveal(section)
            settings.historyOpen = drawer
            try await capture(MainView(settings: settings, controller: controller, shelf: controller.shelf, windowed: false), dark: dark,
                              width: Metrics.width + (drawer ? Metrics.drawer : 0), path: "\(directory)/\(name).png")
            settings.historyOpen = false
            count += 1
        }
        func bar(_ name: String) async throws {
            let host = NSHostingView(rootView: VoiceBar(controller: controller, meter: controller.meter, settings: settings, glass: false))
            host.layoutSubtreeIfNeeded()
            let fit = host.fittingSize
            let size = NSSize(width: ceil(max(88, fit.width)), height: ceil(max(32, fit.height)))
            guard size.width * size.height <= OverlayPlacement.maxAllowedArea else {
                throw VoiceError("The status capsule is larger than its limit, a quarter of the earlier capsule: \(Int(size.width))×\(Int(size.height))")
            }
            try await capture(VoiceBar(controller: controller, meter: controller.meter, settings: settings, glass: false),
                              size: size, path: "\(directory)/\(name).png")
            count += 1
        }
        try await panel("panel-setup")
        try await panel("connection-empty", .connection)
        settings.hasKey = true; settings.microphoneAllowed = true; settings.accessibilityAllowed = true
        controller.hotkeyInstalled = true
        controller.shortcutStatus = tr("Fn is taken over · A single press no longer switches the input source or opens emoji or dictation.")
        try await panel("panel-ready")
        controller.recordShortcut()
        try await panel("panel-shortcut-recording")
        controller.endShortcutRecording()
        controller.phase = .done
        controller.result = "Preview: Discuss the new plan at 3 p.m. tomorrow."; controller.message = tr("Written to Notes · Saved to history"); controller.latency = 1.42
        try await panel("panel-result")
        controller.shelf.previewFill()
        try await panel("panel-shelf")
        try await panel("panel-shelf-dark", dark: true)
        controller.shelf.targeted = true
        try await panel("panel-shelf-drop")
        controller.shelf.targeted = false
        controller.shelf.items = []; controller.shelf.linked = 0
        controller.phase = .idle; controller.result = ""; controller.message = ""; controller.latency = nil
        try await panel("history-empty", drawer: true)
        try await panel("dictionary-empty", .dictionary)
        try await panel("keyboard-fn-ready", .keyboard)
        controller.hotkeyInstalled = false
        controller.shortcutStatus = tr("The macOS action for Fn is still on. Click “Take over Fn”, or set it to “Do Nothing” in Keyboard settings.")
        try await panel("keyboard-fn-conflict", .keyboard)
        controller.hotkeyInstalled = true
        settings.preferences.shortcut = "control-option-space"
        controller.shortcutStatus = tr("The key combination is on, and Fn is back with macOS.")
        try await panel("keyboard-shortcut", .keyboard)
        settings.preferences.shortcut = "fn"
        controller.shortcutStatus = tr("Fn is taken over · A single press no longer switches the input source or opens emoji or dictation.")
        try await panel("remote-off", .remote)
        settings.preferences.linkEnabled = true
        try await panel("remote-empty", .remote)
        let first = TrustedDevice(key: "preview-key-1", name: "Study Mac mini", host: "100.64.0.2", port: 18765)
        var second = TrustedDevice(key: "preview-key-2", name: "Office MacBook", host: "", port: 18765)
        second.canRead = false
        settings.preferences.devices = [first, second]
        controller.peerStatus = [first.key: "Preview: Ready to receive."]
        controller.peerReachable = [first.key: true]
        controller.remoteListening = true; controller.remoteStatus = tr("Listening on port 18765 · Ready")
        try await panel("panel-sender")
        try await panel("panel-sender-dark", dark: true)
        controller.found = [RemoteSender.Found(key: "preview-key-3", name: "Living room iMac", host: "100.64.0.9", port: 18765),
                            RemoteSender.Found(key: "preview-key-4", name: "Old MacBook Air", host: "100.64.0.12", port: 18765)]
        controller.pairing = ["100.64.0.12": tr("Waiting for the other Mac to confirm · code %@", "482 913")]
        try await panel("remote-setup", .remote)
        controller.pairRequests = [RemoteReceiver.PairRequest(device: TrustedDevice(key: "preview-key-5", name: "Workstation MacBook", host: "100.64.0.20", port: 18765),
                                                              code: "305 771", answer: { _ in })]
        try await panel("remote-request")
        try await panel("remote-request-dark", dark: true)
        controller.pairRequests = []; controller.found = []; controller.pairing = [:]
        settings.hasKey = false; settings.microphoneAllowed = false
        try await panel("panel-receiver-only")
        if let far = settings.preferences.devices.last {
            let (reached, linked) = (controller.peerReachable, controller.shelf.linkedKeys)
            controller.peerReachable[far.key] = false; controller.shelf.linkedKeys = [far.key]
            try await panel("panel-one-way")
            controller.peerReachable = reached; controller.shelf.linkedKeys = linked
        }
        settings.hasKey = true; settings.microphoneAllowed = true
        settings.preferences.linkEnabled = false; settings.preferences.devices = []
        controller.peerStatus = [:]; controller.peerReachable = [:]; controller.remoteListening = false; controller.remoteStatus = ""
        try await panel("connection", .connection)
        settings.choose(Platform.groq.id, speech: true); settings.choose(Platform.custom.id, speech: false)
        settings.preferences.customBase = "http://100.64.0.7:11434/v1"; settings.preferences.textModel = "qwen3:14b"
        settings.keyMessages[Platform.groq.id] = tr("The API key is valid, and the chosen models are available.")
        try await panel("connection-mixed", .connection)
        settings.choose(Platform.siliconFlow.id, speech: true); settings.choose(Platform.siliconFlow.id, speech: false)
        settings.savedKeys = []; settings.keyMessages = [:]
        try await panel("connection-other-empty", .connection)
        settings.choose(Platform.openAI.id, speech: true); settings.choose(Platform.openAI.id, speech: false)
        settings.preferences.customBase = ""; settings.hasKey = true
        try await panel("general", .general)
        settings.preferences.dictionary = ["OpenAI", "Tailscale", "SwiftUI", "Mixed-language input", "Jump Desktop", "Thursday stand-up", "An exceptionally long proper noun that checks how an entry is cut off in the narrow panel"]
        try await panel("dictionary-filled", .dictionary)
        settings.history = [HistoryEntry(text: "Preview: Move Wednesday's meeting to Thursday at 3 p.m.; nothing else changes.", mode: .dictate, seconds: 12),
                            HistoryEntry(text: "Preview: This is a longer dictation, to check the layout and the folding in the narrow panel. Click any text to copy all of it.", mode: .dictate, seconds: 41),
                            HistoryEntry(text: "Preview: move the review to Thursday at three.", mode: .translate, seconds: 9)]
        try await panel("panel-history")
        try await panel("panel-history-dark", dark: true)
        try await panel("history-filled", drawer: true)
        let request = SavedDictation(mode: .dictate, polish: true, targetLanguage: "English", speechModel: "fixture",
                                     textModel: "fixture", dictionary: [], selection: "")
        settings.history.insert(HistoryEntry(text: "", mode: .dictate, seconds: 23, status: .pending,
            request: request, problem: "Preview: The network connection dropped. The recording is kept and is transcribed once online."), at: 0)
        controller.networkAvailable = false
        try await panel("history-offline", drawer: true)
        controller.networkAvailable = true
        settings.history[0].status = .failed
        settings.history[0].text = "Preview: Next week, the plan is to finish…"
        settings.history[0].problem = "Preview: The OpenAI API key is not valid or has expired. Update it in Settings."
        try await panel("history-retry", drawer: true)
        settings.history[0].status = .processing; settings.history[0].problem = nil
        controller.retryingID = settings.history[0].id
        try await panel("history-processing", drawer: true)
        controller.retryingID = nil
        for phase in [DictationPhase.recording, .processing, .done, .error] {
            controller.phase = phase; controller.level = 0.8; controller.elapsed = 17; controller.connected = true
            controller.partial = phase == .recording ? "Preview: Discuss the new plan at 3 p.m. tomorrow." : ""
            controller.result = "Preview: Discuss the new plan at 3 p.m. tomorrow."
            controller.message = phase == .error ? tr("No text field is focused, saved to history") : phase == .done ? tr("Written to Notes · Saved to history") : tr("Polishing text…")
            try await bar("bar-\(phase)")
            if phase == .recording || phase == .error { try await panel("panel-\(phase)") }
        }
        controller.phase = .done; controller.result = "Preview: Discuss the new plan at 3 p.m. tomorrow."
        controller.capsuleResult = .notWritten(DictationController.missTitle(.noField, peer: "Study"), DictationController.missLine(.noField, clipboard: .there))
        try await bar("bar-not-typed")
        controller.capsuleResult = .notWritten(DictationController.missTitle(.unreachable, peer: "Office"), DictationController.missLine(.unreachable, clipboard: .thisMac))
        try await bar("bar-not-reached")
        controller.capsuleResult = .inserted
        controller.phase = .recording; controller.connected = false; controller.partial = ""
        try await bar("bar-offline")
        controller.phase = .idle; controller.message = ""; controller.result = ""; settings.section = nil
        let live = makePanel(settings: settings, controller: controller)
        live.setFrameTopLeftPoint(NSPoint(x: -3000, y: 900))
        live.alphaValue = 0
        live.ignoresMouseEvents = true
        live.orderFrontRegardless()
        followDrawer(of: live)
        func shot(_ name: String) async throws {
            try await Task.sleep(nanoseconds: 400_000_000)
            guard let frame = live.contentView?.superview, let bitmap = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { throw VoiceError("Could not capture the window.") }
            frame.cacheDisplay(in: frame.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(directory)/\(name).png"))
            print("Rendered \(name).png · window \(Int(live.frame.width))×\(Int(live.frame.height))")
            count += 1
        }
        try await shot("window-default")
        func press(_ x: CGFloat, fromTop y: CGFloat) async throws {
            let point = NSPoint(x: x, y: live.frame.height - y)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: live.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else { continue }
                NSApp.sendEvent(event)
                try await Task.sleep(nanoseconds: 60_000_000)
            }
            try await Task.sleep(nanoseconds: 350_000_000)
        }
        func expect(_ ok: Bool, _ what: String) throws { if !ok { throw VoiceError("A click did not reach \(what).") } }
        try await press(258, fromTop: 15)
        try expect(settings.page == .settings, "the settings button in the title row")
        try await shot("window-settings")
        try await press(258, fromTop: 15)
        try expect(settings.page == .main, "the settings button that returns from Settings to the main page")
        try await press(225, fromTop: 15)
        try expect(settings.historyOpen, "the history button in the title row")
        settings.historyOpen = false
        try await Task.sleep(nanoseconds: 500_000_000)
        try await press(35, fromTop: 62)
        try expect(controller.recordingShortcut, "the shortcut badge")
        try await press(35, fromTop: 62)
        try expect(!controller.recordingShortcut, "the shortcut badge, clicked again to keep the shortcut")
        try await press(206, fromTop: 121)
        try expect(!settings.preferences.polish, "Polish “Off”")
        try await press(248, fromTop: 121)
        try expect(settings.preferences.polish, "Polish “On”")
        print("Clicks reach the settings and history buttons, the shortcut badge and the tidying choice.")
        live.close()
        for key in ["panelWishedHeight", "panelLeft", "panelTop"] { UserDefaults.standard.removeObject(forKey: key) }
        print("Rendered \(count) native UI states without recording, API calls, or permission changes.")
    }

    private func capture<V: View>(_ view: V, size: NSSize? = nil, dark: Bool = false, width: CGFloat = Metrics.width, path: String) async throws {
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let window = FloatingPanel(contentRect: NSRect(origin: NSPoint(x: -3000, y: 0), size: size ?? NSSize(width: width, height: 1400)),
                                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        try await Task.sleep(nanoseconds: 250_000_000)
        if size == nil {
            host.layoutSubtreeIfNeeded()
            window.setContentSize(NSSize(width: width, height: ceil(host.fittingSize.height)))
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw VoiceError("Could not capture the view.") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw VoiceError("Could not encode the view's image.") }
        try data.write(to: URL(fileURLWithPath: path))
        window.close()
        print("Rendered \(URL(fileURLWithPath: path).lastPathComponent)")
    }
    #endif
}
