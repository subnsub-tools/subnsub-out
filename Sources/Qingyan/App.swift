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
    /// Told when the user starts dragging it by its background (WindowDragArea).
    var onDragBegan: (() -> Void)?
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The bar's content view: says where on the screen the pointer was when it left the bar, whichever
/// app is active (SwiftUI's hover follows only while out is), so the bar can step aside from it.
final class PointerExitView: NSView {
    var onExit: ((NSPoint) -> Void)?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) {}
    override func mouseExited(with event: NSEvent) {
        guard let window else { return }
        onExit?(window.convertPoint(toScreen: event.locationInWindow))
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private var settings: SettingsStore!
    private var controller: DictationController!
    private var historyKeys: Any?
    private var window: NSWindow?
    private var overlay: NSPanel?
    /// The compact floating bar, shown in place of the panel when it is chosen (CompactBar).
    private var compactPanel: NSPanel?
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
    private var menuObservations: [NSObjectProtocol] = []
    private var languageSubscription: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if let index = CommandLine.arguments.firstIndex(of: "--screen-selftest"), CommandLine.arguments.count > index + 2 {
            let arguments = CommandLine.arguments
            Task { @MainActor in
                do { exit(try await ScreenShareSelfTest.run(account: arguments[index + 1], report: arguments[index + 2]) ? 0 : 1) }
                catch { fputs("Screen self-test failed: \(error)\n", stderr); exit(1) }
            }
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--screen-window-preview"), CommandLine.arguments.count > index + 1 {
            let settings = SettingsStore(preview: true)
            let controller = DictationController(settings: settings)
            self.settings = settings; self.controller = controller
            Task { @MainActor in
                do { try await ScreenViewer.preview(to: CommandLine.arguments[index + 1], controller: controller); exit(0) }
                catch { fputs("Screen window preview failed: \(error)\n", stderr); exit(1) }
            }
            return
        }
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
        // A copy still at a name from before a rename moves to out.app and starts again there.
        if Relocation.moveIfNeeded() { return }
        let loginItemRenewed = Relocation.renewLoginItem()
        settings = SettingsStore()
        if !loginItemRenewed { settings.loginMessage = tr("Open at login could not be set up again after the app moved to out.app. Turn it on again here.") }
        controller = DictationController(settings: settings)
        settings.openPanel = { [weak self] in self?.showWindow() }
        settings.setCompact = { [weak self] on in self?.setCompact(on) }
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
        // The pointer leaving the bar for a menu of out's (a Shelf item's) is no reason to step aside.
        menuObservations.append(NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.menuOpen = true }
        })
        menuObservations.append(NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.menuOpen = false; self?.menuClosedAt = ProcessInfo.processInfo.systemUptime }
        })
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "panelOpenBeforeUpdate")
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        let renewed = defaults.string(forKey: "panelShownForBuild") != build
        defaults.set(build, forKey: "panelShownForBuild")
        // Where the compact bar was left, before it and the capsule became one window with one place.
        for key in ["compactLeft", "compactTop"] { defaults.removeObject(forKey: key) }
        if defaults.bool(forKey: "panelCompact") { showCompact() }
        else if renewed { showWindow(activating: false, inFront: true) }
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
        controller?.suspend(); controller?.shortcut.stop(); controller?.screen.stop()
        PasteboardLease.general.restore()
        observations.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        menuObservations.forEach { NotificationCenter.default.removeObserver($0) }
        compactReturn?.invalidate()
    }

    private func installStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // The name alone, and any click opens the menu and shows the panel with it (menuWillOpen), so
        // the menu has no Show Main Panel (user 2026-11-23). A capital O and an exclamation mark,
        // semibold, not the plain word (user 2026-11-23).
        if let button = statusItem?.button {
            button.attributedTitle = NSAttributedString(string: "Out!", attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .semibold)
            ])
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
        button.toolTip = tr("out · Click for the menu")
        button.setAccessibilityLabel(tr("out, opens its menu"))
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let recording = controller.phase == .recording
        // Every item has a sign before its name (user 2026-11-23).
        item(menu, recording ? tr("out · Recording") : tr("out · %@ to Start or Stop", settings.shortcutLabel), nil, recording ? "record.circle" : "command")?.isEnabled = false
        menu.addItem(.separator())
        if controller.phase == .recording { item(menu, tr("Stop Recording"), #selector(stopRecording), "stop.circle") }
        if !controller.busy { item(menu, tr("Start Recording"), #selector(startRecording), "mic") }
        if controller.busy { item(menu, tr("Cancel Recording"), #selector(cancelRecording), "xmark.circle") }
        if !controller.busy { item(menu, tr("Type the Clipboard (⌃⌥V)"), #selector(typeClipboard), "keyboard") }
        item(menu, tr("Clipboard History (⌃⌥C)"), #selector(openClipboard), "list.clipboard")
        if settings.preferences.clipHistory {
            item(menu, tr("Pause Clipboard History"), #selector(pauseClipboard), "pause.circle")?.state = controller.clipboard.paused ? .on : .off
        }
        if controller.screenState == .viewing { item(menu, tr("Stop Showing the Screen"), #selector(stopScreen), "eye.slash") }
        item(menu, tr("Keep on Top"), #selector(togglePinned), "pin")?.state = pinned ? .on : .off
        item(menu, tr("Settings…"), #selector(openSettings), "gearshape")
        if !controller.result.isEmpty { item(menu, tr("Copy Last Result"), #selector(copyResult), "doc.on.doc") }
        menu.addItem(.separator())
        item(menu, tr("Quit out"), #selector(quit), "power")
    }

    /// A click on Out! shows the panel along with the menu (user 2026-11-23). Kept on top, the bar is
    /// the panel and comes in front. Otherwise the panel comes in front on this desktop without the
    /// keyboard, so Start Recording from the menu still writes into the app in front; open on another
    /// desktop, it is shown as before, by switching to that desktop.
    func menuWillOpen(_ menu: NSMenu) {
        guard menu === statusItem?.menu, settings != nil else { return }
        if NSApp.isHidden { NSApp.unhideWithoutActivation() }
        if pinned {
            if compactPanel?.isVisible == true { compactPanel?.orderFrontRegardless() } else { showCompact() }
        } else if let window, window.isVisible, !window.isOnActiveSpace {
            showWindow()
        } else {
            if window?.isMiniaturized == true { window?.deminiaturize(nil) }
            showWindow(activating: false, inFront: true)
        }
    }

    @discardableResult private func item(_ menu: NSMenu, _ title: String, _ action: Selector?, _ symbol: String) -> NSMenuItem? {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        item.target = self; menu.addItem(item); return item
    }
    @objc private func stopScreen() { controller.screen.stopViewing() }
    // Unchecked, it only stops keeping on top, as the bar's own pin does; the panel stays as it is.
    @objc private func togglePinned() { if pinned { leaveCompact() } else { setCompact(true) } }
    @objc private func openSettings() { settings.reveal(.general) }
    @objc private func startRecording() { controller.toggle() }
    @objc private func typeClipboard() { controller.typeClipboard(from: .menu) }
    @objc private func openClipboard() { controller.picker.show() }
    @objc private func pauseClipboard() { controller.clipboard.paused.toggle() }
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
        let hide = NSMenuItem(title: tr("Hide out"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        hide.target = NSApp
        application.addItem(hide)
        let quit = NSMenuItem(title: tr("Quit out"), action: #selector(quit), keyEquivalent: "q")
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
        // Asking for the panel, from anywhere, brings it back in place of the compact bar.
        if UserDefaults.standard.bool(forKey: "panelCompact") || compactPanel?.isVisible == true { leaveCompact() }
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
            watchHistoryKeys()
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

    /// History's keys, while it shows in the panel and the panel has the keyboard. Text being
    /// composed in the search field (an input method's candidates) keeps its keys.
    private func watchHistoryKeys() {
        guard historyKeys == nil else { return }
        historyKeys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window, event.window === window, self.settings.historyOpen,
                  self.settings.page != .settings else { return event }
            if let editor = window.firstResponder as? NSTextView {
                // The search field's own: not another field, not text being composed.
                guard !editor.hasMarkedText(), self.controller.historyPage.searchFocused else { return event }
            } else if NSApp.isFullKeyboardAccessEnabled {
                // A control may have the keyboard: its Return and arrows stay its own.
                return event
            }
            return self.controller.historyKey(event) ? nil : event
        }
    }

    private func makePanel(settings: SettingsStore, controller: DictationController) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Metrics.width, height: Metrics.defaultHeight),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Out"
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
        TitleRowLights.center(window)
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

    /// Sent when the user starts dragging a window, never when out moves it (checked on macOS 15).
    func windowWillMove(_ notification: Notification) {
        guard let moving = notification.object as? NSWindow, moving === overlay || moving === compactPanel else { return }
        userMoving = moving
    }

    func windowDidMove(_ notification: Notification) {
        if let moved = notification.object as? NSWindow, moved === compactPanel || moved === overlay {
            // out's own moves (placing, gliding, fitting a new size) move it too: only this window's
            // drag, while the button is still down, is the user's place.
            guard userMoving === moved, NSEvent.pressedMouseButtons & 1 == 1 else { return }
            if moved === overlay {
                overlayDraggedByUser = true
                overlayAnchorOrigin = moved.frame.origin
                // Its new screen, and its top center, are what later sizes keep.
                overlayCorner = .topCenter
                overlayScreenFrame = (moved.screen ?? NSScreen.main)?.visibleFrame
                savedPlace = NSPoint(x: moved.frame.midX, y: moved.frame.maxY - Self.capsuleMargin)
            } else {
                savedPlace = NSPoint(x: moved.frame.midX, y: moved.frame.maxY)
                // Dragged while standing aside: where it is dropped is its place.
                settleCompact()
            }
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

    // MARK: - Kept on top: the capsule and the bar as one window

    /// Kept on top (the bar), or not (the capsule, only while something happens). The choice is kept across starts.
    private var pinned: Bool { UserDefaults.standard.bool(forKey: "panelCompact") }

    /// The capsule's window reaches this far above the capsule (VoiceBar's outer padding).
    private static let capsuleMargin: CGFloat = 9

    /// The one place of the capsule and the bar: the top center of what is drawn, in screen
    /// coordinates, where the user last dragged either. None until then: the capsule finds its own
    /// spot below the menu bar, and the bar goes to the top center of the main screen.
    private var savedPlace: NSPoint? {
        get {
            let defaults = UserDefaults.standard
            guard defaults.object(forKey: "barCenterX") != nil else { return nil }
            let point = NSPoint(x: defaults.double(forKey: "barCenterX"), y: defaults.double(forKey: "barTop"))
            // A screen that is no longer there forgets it.
            return NSScreen.screens.contains(where: { $0.frame.insetBy(dx: -2, dy: -2).contains(point) }) ? point : nil
        }
        set {
            let defaults = UserDefaults.standard
            if let newValue {
                defaults.set(Double(newValue.x), forKey: "barCenterX"); defaults.set(Double(newValue.y), forKey: "barTop")
            } else {
                defaults.removeObject(forKey: "barCenterX"); defaults.removeObject(forKey: "barTop")
            }
        }
    }
    /// The window the user is dragging (from windowWillMove), so that its moves are the user's place.
    private var userMoving: NSWindow?

    /// The frame for something of this size with its top center at `place`, kept inside that screen.
    private static func frame(_ size: CGSize, topCenter place: NSPoint, above margin: CGFloat = 0) -> NSRect {
        let screen = NSScreen.screens.first(where: { $0.frame.contains(place) }) ?? NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: place.x - 720, y: place.y - 900, width: 1440, height: 900)
        var origin = NSPoint(x: round(place.x - size.width / 2), y: round(place.y + margin - size.height))
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        return NSRect(origin: origin, size: size)
    }

    /// Kept on top (on: the bar, in place of the panel and of the capsule) or not (off: the panel
    /// back, and the capsule for whatever happens).
    private func setCompact(_ on: Bool) {
        guard on else { leaveCompact(); showWindow(); return }
        // Kept on top where the capsule is, when it is showing; that is the user's place only once dragged.
        var here: NSPoint?
        if let overlay, overlay.isVisible, !overlayLeaving {
            here = NSPoint(x: overlay.frame.midX, y: overlay.frame.maxY - Self.capsuleMargin)
        }
        UserDefaults.standard.set(true, forKey: "panelCompact")
        overlayLeaving = false
        overlay?.orderOut(nil)
        showCompact(at: here)
        // Out of sight, not closed: the panel comes back as it was.
        window?.orderOut(nil)
    }

    /// No longer kept on top: the bar goes, and what it was showing goes on in the capsule (at the
    /// user's place, or where the capsule finds its own).
    private func leaveCompact() {
        UserDefaults.standard.set(false, forKey: "panelCompact")
        compactPanel?.orderOut(nil)
        settleCompact()
        // The panel that keeping on top put out of sight stays so after a restart (showWindow, when it
        // is the way out, opens it again).
        if window?.isVisible != true { UserDefaults.standard.set(false, forKey: "panelOpen") }
        if controller.capsuleShown { showOverlay() }
    }

    /// `here`: where the capsule was, for want of the user's place.
    private func showCompact(at here: NSPoint? = nil) {
        guard settings != nil else { return }
        if compactPanel == nil {
            let panel = makeCompact(onExpand: { [weak self] in self?.setCompact(false) },
                                    onUnpin: { [weak self] in self?.leaveCompact() })
            panel.onDragBegan = { [weak self, weak panel] in self?.userMoving = panel }
            compactPanel = panel
        }
        guard let panel = compactPanel else { return }
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        userMoving = nil
        settleCompact()
        // At the height its content has now, whatever height it was left at.
        panel.setFrame(Self.frame(Self.compactSize, topCenter: savedPlace ?? here ?? NSPoint(x: visible.midX, y: visible.maxY - 8)), display: true)
        panel.orderFrontRegardless()
    }

    /// The bar's size as its content is: with the Shelf or without.
    private static var compactSize: NSSize {
        NSSize(width: CompactBar.width, height: CompactBar.height(shelfFolded: UserDefaults.standard.bool(forKey: CompactBar.foldedKey)))
    }

    /// The Shelf hidden or shown: the bar keeps its top and its center.
    private func resizeCompact(to size: CGSize) {
        guard let panel = compactPanel else { return }
        let size = CGSize(width: ceil(size.width), height: ceil(size.height))
        guard abs(panel.frame.height - size.height) > 0.5 || abs(panel.frame.width - size.width) > 0.5 else { return }
        let visible = (panel.screen ?? NSScreen.main)?.visibleFrame
        // Standing aside, it stays where it is and the place it goes back to takes the new size too.
        if let home = compactHome { compactHome = Self.resized(home, to: size, in: visible) }
        panel.setFrame(Self.resized(panel.frame, to: size, in: visible), display: true)
    }

    /// `frame` at a new size, with the same top and center; too near the bottom of its screen for
    /// the Shelf, it moves up rather than off it.
    private static func resized(_ frame: NSRect, to size: CGSize, in visible: NSRect?) -> NSRect {
        var next = NSRect(x: round(frame.midX - size.width / 2), y: frame.maxY - size.height, width: size.width, height: size.height)
        if let visible, next.minY < visible.minY {
            next.origin.y = min(visible.minY, visible.maxY - size.height)
        }
        return next
    }

    // MARK: - The bar steps aside

    /// Where the bar stands while it has stepped aside, to go back to; nil while it has not.
    private var compactHome: NSRect?
    /// How far it stands aside from there on each axis: half its height either way, or nothing.
    private var compactAside = CGVector.zero
    /// While it stands aside: brings it back once the pointer has been away for a moment.
    private var compactReturn: Timer?
    private var compactAwaySince: TimeInterval?
    /// Where the bar is gliding to, while it does: what it moves from next is that, not a frame on the way.
    private var compactGlide: NSRect?
    private var menuOpen = false
    private var menuClosedAt: TimeInterval = 0

    /// The pointer left the bar at `point`: the bar moves half its height away from the side the
    /// pointer left by, to show what it covers there (user 2026-11-25: it often covers something;
    /// left above, it moves down a little; below, up; to its right, left; to its left, right; by half
    /// the whole window's height). Each axis is one step from where it stood at most, so it never
    /// wanders, and it stays inside its screen's visible part (at its edge, it does not move that way).
    private func compactPointerLeft(_ window: NSWindow?, at point: NSPoint) {
        // Not while a button is down (a drag into or out of the Shelf, a drag of the bar), nor for
        // one of out's menus.
        guard let panel = compactPanel, window === panel, panel.isVisible, NSEvent.pressedMouseButtons == 0,
              !menuOpen, ProcessInfo.processInfo.systemUptime - menuClosedAt > 0.4 else { return }
        let frame = panel.frame
        // How far past each side the pointer is: it left by the side it is furthest past (still
        // inside, it left for a window over the bar, and the bar stays).
        let sides: [(past: CGFloat, dx: CGFloat, dy: CGFloat)] = [
            (frame.minX - point.x, 1, 0),
            (point.x - frame.maxX, -1, 0),
            (frame.minY - point.y, 0, 1),
            (point.y - frame.maxY, 0, -1),
        ]
        guard let side = sides.max(by: { $0.past < $1.past }), side.past >= -1 else { return }
        // Gliding back when the pointer leaves again: from where it is going back to.
        let home = compactHome ?? compactGlide ?? frame
        let step = (home.height / 2).rounded()
        var aside = compactAside
        if side.dx != 0 { aside.dx = side.dx * step } else { aside.dy = side.dy * step }
        guard aside != compactAside else { return }
        compactHome = home
        compactAside = aside
        glideCompact(to: Self.steppedAside(home, by: aside))
        watchCompactReturn()
    }

    /// `home` moved by `aside`, as far as its screen's visible part lets it, and never back past home
    /// (a bar left partly outside that part does not move toward the pointer).
    private static func steppedAside(_ home: NSRect, by aside: CGVector) -> NSRect {
        let top = NSPoint(x: home.midX, y: home.maxY - 1)
        guard let visible = (NSScreen.screens.first(where: { $0.frame.contains(top) }) ?? NSScreen.main)?.visibleFrame else {
            return home.offsetBy(dx: aside.dx, dy: aside.dy)
        }
        func toward(_ start: CGFloat, _ delta: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
            if delta > 0 { return max(start, min(start + delta, high)) }
            if delta < 0 { return min(start, max(start + delta, low)) }
            return start
        }
        var frame = home
        frame.origin.x = toward(home.minX, aside.dx, visible.minX, visible.maxX - home.width)
        frame.origin.y = toward(home.minY, aside.dy, visible.minY, visible.maxY - home.height)
        return frame
    }

    /// Out of the way quickly (`back` false); back to its place slowly enough to be followed (user
    /// 2026-11-26: it snapped back; it should come back along the way, diagonally when it stood aside
    /// both ways). Both axes move together, so the way is the straight line between the two.
    private func glideCompact(to goal: NSRect, back: Bool = false) {
        guard let panel = compactPanel else { return }
        // out's own move, not the user's place (windowDidMove).
        if userMoving === panel { userMoving = nil }
        guard !Motion.reduced, panel.isVisible else { compactGlide = nil; panel.setFrame(goal, display: true); return }
        compactGlide = goal
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = back ? 0.45 : 0.18
            context.timingFunction = back ? CAMediaTimingFunction(name: .easeInEaseOut)
                : CAMediaTimingFunction(controlPoints: Float(Motion.curve.0), Float(Motion.curve.1), Float(Motion.curve.2), Float(Motion.curve.3))
            panel.animator().setFrame(goal, display: true)
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                if self?.compactGlide == goal { self?.compactGlide = nil }
            }
        })
    }

    private func watchCompactReturn() {
        compactAwaySince = nil
        guard compactReturn == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkCompactReturn() }
        }
        timer.tolerance = 0.05
        compactReturn = timer
    }

    /// Back where it stood once the pointer has been 0.6 s away from both where it stands and where
    /// it stood (by more than half its height); not while a button is down.
    private func checkCompactReturn() {
        guard let panel = compactPanel, panel.isVisible, let home = compactHome else { settleCompact(); return }
        let reach = max((home.height / 2).rounded(), 20)
        let near = home.union(compactGlide ?? panel.frame).insetBy(dx: -reach, dy: -reach).contains(NSEvent.mouseLocation)
        guard !near, NSEvent.pressedMouseButtons == 0 else { compactAwaySince = nil; return }
        let now = ProcessInfo.processInfo.systemUptime
        guard let since = compactAwaySince else { compactAwaySince = now; return }
        guard now - since >= 0.6 else { return }
        settleCompact()
        glideCompact(to: home, back: true)
    }

    /// No longer standing aside: where the bar is (or is going) is its place.
    private func settleCompact() {
        compactReturn?.invalidate()
        compactReturn = nil
        compactHome = nil
        compactAside = .zero
        compactAwaySince = nil
        compactGlide = nil
    }

    /// A glass bar above every window on every Space, full-screen apps included, that never takes
    /// the keyboard from the app in front and moves by any part that is not a control.
    private func makeCompact(onExpand: @escaping () -> Void, onUnpin: @escaping () -> Void = {}, glass: Bool = true) -> FloatingPanel {
        // At the top of its window, whatever the window's height: laid over a view that takes the
        // window's size, the bar is never centered in a window that is not yet as tall as it is
        // (which cut it off at its top and bottom).
        let host = NSHostingView(rootView: Color.clear.overlay(alignment: .top) {
            CompactBar(settings: settings, controller: controller, shelf: controller.shelf,
                       meter: controller.meter, glass: glass, onExpand: onExpand, onUnpin: onUnpin,
                       onSize: { [weak self] size in DispatchQueue.main.async { self?.resizeCompact(to: size) } })
        })
        host.sizingOptions = []
        let size = Self.compactSize
        let content = PointerExitView(frame: NSRect(origin: .zero, size: size))
        host.frame = content.bounds
        host.autoresizingMask = [.width, .height]
        content.addSubview(host)
        let panel = FloatingPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
        content.onExit = { [weak self, weak panel] point in self?.compactPointerLeft(panel, at: point) }
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.contentView = content
        panel.delegate = self
        return panel
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
        let width = min(max(ceil(fitting.width), 96), OverlayPlacement.maxSize.width)
        let height = min(max(ceil(fitting.height), 38), OverlayPlacement.maxSize.height)
        return CGSize(width: width, height: height)
    }

    private func showOverlay() {
        controller.capsuleShown = true
        // Kept on top, the bar's first row shows it: the two never show at once.
        guard !pinned else { return }
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
                },
                onPin: { [weak self] in self?.setCompact(true) }
            ))
            host.sizingOptions = []
            panel.contentView = host
            panel.onDragBegan = { [weak self, weak panel] in self?.userMoving = panel }
            overlay = panel
            overlayHost = host
        }
        guard let overlay else { return }
        let wasHidden = !overlay.isVisible || overlay.alphaValue < 0.05
        overlayLeaving = false
        userMoving = nil

        let size = measuredOverlaySize()
        let rest: CGPoint
        // Not looked at while it stays where the user dragged it during this showing.
        let captured = wasHidden || !overlayDraggedByUser
            ? SightSensor.capture(excludingPanel: window, previousOrigin: wasHidden ? nil : overlayAnchorOrigin) : nil
        if wasHidden, let captured, let spot = OverlayPlacement.besideCaret(size: size, in: captured.scene, margin: Self.capsuleMargin) {
            // With the caret, when the field in front says where it is, before the place it was
            // last dragged to (user 2026-11-23: it goes with the cursor).
            overlayDraggedByUser = false
            overlayCorner = spot.corner
            overlayScreenFrame = captured.scene.visibleFrame
            overlayAnchorOrigin = spot.origin
            rest = spot.origin
        } else if wasHidden, let place = savedPlace {
            // Where the user last put the capsule or the bar.
            let frame = Self.frame(size, topCenter: place, above: Self.capsuleMargin)
            overlayDraggedByUser = true
            overlayCorner = .topCenter
            overlayScreenFrame = (NSScreen.screens.first(where: { $0.frame.contains(place) }) ?? NSScreen.main)?.visibleFrame
            overlayAnchorOrigin = frame.origin
            rest = frame.origin
        } else if !wasHidden, overlayDraggedByUser, let visible = overlayScreenFrame ?? NSScreen.main?.visibleFrame {
            rest = OverlayPlacement.reanchor(frame: overlay.frame, newSize: size, corner: overlayCorner, in: visible).origin
        } else if let captured {
            overlayDraggedByUser = false
            let placement = OverlayPlacement.choose(size: size, in: captured.scene, margin: Self.capsuleMargin)
            overlayCorner = placement.corner
            overlayScreenFrame = captured.scene.visibleFrame
            overlayAnchorOrigin = placement.origin
            rest = placement.origin
        } else {
            let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            overlayDraggedByUser = false
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
            width: min(max(ceil(rawSize.width), 96), OverlayPlacement.maxSize.width),
            height: min(max(ceil(rawSize.height), 38), OverlayPlacement.maxSize.height)
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
        // With a caret known it goes where the caret went; otherwise only out of the way.
        guard !sameScreen || captured.scene.caret != nil || OverlayPlacement.isObstructed(overlay.frame, in: captured.scene) else { return }
        let size = overlay.frame.size
        let placement = OverlayPlacement.choose(size: size, in: captured.scene, margin: Self.capsuleMargin)
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
        controller.capsuleShown = false
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
        func bar(_ name: String, pin: Bool = false) async throws {
            let make = { VoiceBar(controller: controller, meter: controller.meter, settings: settings, glass: false,
                                  onPin: pin ? {} : nil, pinShownForPreview: pin) }
            let host = NSHostingView(rootView: make())
            host.layoutSubtreeIfNeeded()
            let fit = host.fittingSize
            let size = NSSize(width: ceil(max(88, fit.width)), height: ceil(max(32, fit.height)))
            // The window never grows past maxSize; content larger than that is cut off on screen.
            guard size.width <= OverlayPlacement.maxSize.width, size.height <= OverlayPlacement.maxSize.height else {
                throw VoiceError("The status capsule is larger than its window: \(Int(size.width))×\(Int(size.height))")
            }
            // Glass like the panel, so light and dark both (the dark one is <name>-dark.png).
            for dark in [false, true] {
                try await capture(make(), size: size, dark: dark, path: "\(directory)/\(name)\(dark ? "-dark" : "").png")
                count += 1
            }
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
        // The picture that floats out of a Shelf tile: a wide image, and a piece of text.
        let wide = NSImage(size: NSSize(width: 1600, height: 1000), flipped: false) { rect in
            NSGradient(starting: NSColor(hue: 0.58, saturation: 0.5, brightness: 0.9, alpha: 1), ending: NSColor(hue: 0.68, saturation: 0.7, brightness: 0.6, alpha: 1))?.draw(in: rect, angle: 60)
            return true
        }
        let peeks = [("shelf-peek-image", ShelfPeekView(item: ShelfItem(kind: .image, name: "Screenshot 2026-11-22 at 10.41.03.png", size: 482_000, origin: "Study"),
                                                        image: wide, text: nil, icon: nil, size: ShelfModel.size(482_000))),
                     ("shelf-peek-text", ShelfPeekView(item: ShelfItem(kind: .text, name: "Text.txt", size: 120, origin: "Study"), image: nil,
                                                       text: "Plan review on Thursday at 3 p.m., third-floor meeting room. Bring the quote and last week's numbers.",
                                                       icon: nil, size: ShelfModel.size(120)))]
        for (name, peek) in peeks {
            let fitted = peek.fitted
            for dark in [false, true] {
                try await capture(peek, size: NSSize(width: fitted.width + 24, height: fitted.height + 24), dark: dark, path: "\(directory)/\(name)\(dark ? "-dark" : "").png")
                count += 1
            }
        }
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
        controller.helperState = .missing
        try await panel("remote-no-helper", .remote)
        controller.helperState = .ready
        try await panel("remote-empty", .remote)
        let first = TrustedDevice(key: HelperLink.id("previewStudy"), name: "Study", host: HelperLink.id("previewStudy"), port: RemoteWire.defaultPort)
        let second = TrustedDevice(key: HelperLink.id("previewOffice"), name: "Office", host: HelperLink.id("previewOffice"), port: RemoteWire.defaultPort)
        settings.preferences.devices = [first, second]
        controller.peerStatus = [first.key: "Preview: Ready to receive."]
        controller.peerReachable = [first.key: true]
        controller.remoteListening = true; controller.remoteStatus = tr("Ready to receive through the Monitor helper")
        try await panel("panel-sender")
        try await panel("panel-sender-dark", dark: true)
        try await panel("remote-macs", .remote)
        settings.hasKey = false; settings.microphoneAllowed = false
        try await panel("panel-receiver-only")
        if let far = settings.preferences.devices.last {
            let (reached, linked) = (controller.peerReachable, controller.shelf.linkedKeys)
            controller.peerReachable[far.key] = false; controller.shelf.linkedKeys = [far.key]
            try await panel("panel-one-way")
            controller.peerReachable = reached; controller.shelf.linkedKeys = linked
        }
        settings.hasKey = true; settings.microphoneAllowed = true
        // Text another Mac sent: its card, in place of the result card (receive leaves that to it).
        let shownMessage = controller.message
        controller.message = ""
        controller.lastReceived = .init(text: "Preview: Send the draft to Office before noon, and keep a copy in the shared folder.", from: "Study", date: Date(),
                                        written: false, status: [DictationController.missTitle(.noField, peer: nil), DictationController.missLine(.noField, clipboard: nil), tr("Copied to the clipboard")].joined(separator: " · "))
        try await panel("panel-received")
        try await panel("panel-received-dark", dark: true)
        controller.lastReceived = .init(text: "Preview: Send the draft to Office before noon.", from: "Study", date: Date(),
                                        written: true, status: [tr("Inserted into %@", "Notes"), tr("Copied to the clipboard")].joined(separator: " · "))
        try await panel("panel-received-typed")
        controller.lastReceived = nil
        controller.message = shownMessage
        settings.preferences.linkEnabled = false; settings.preferences.devices = []
        controller.peerStatus = [:]; controller.peerReachable = [:]; controller.remoteListening = false; controller.remoteStatus = ""
        try await panel("connection", .connection)
        settings.choose(Platform.groq.id, speech: true); settings.choose(Platform.custom.id, speech: false)
        settings.preferences.customBase = "http://100.64.0.7:11434/v1"; settings.preferences.textModel = "qwen3:14b"
        settings.keyMessages[Platform.groq.id] = tr("The API key is valid, and the chosen models are available.")
        // With Text polishing on, so the polishing rows and the second platform's key show.
        settings.preferences.style = "polish"
        try await panel("connection-mixed", .connection)
        settings.preferences.style = StyleChoice.standard
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
        controller.capsuleResult = .notWritten(DictationController.missTitle(.notAllowed, peer: "Kitchen Mac mini 2023"), DictationController.missLine(.notAllowed, clipboard: .thisMac))
        try await bar("bar-not-typed-long")
        // The pin that shows while the pointer is over the capsule, on the widest capsule there is.
        try await bar("bar-not-typed-long-pin", pin: true)
        controller.capsuleResult = .inserted
        // Text on its way between two Macs, with a long Mac name: the sending and the receiving capsule.
        controller.phase = .processing; controller.capsuleStep = .sending; controller.sendingTo = "Kitchen Mac mini 2023"
        try await bar("bar-sending")
        try await bar("bar-sending-pin", pin: true)
        controller.capsuleStep = .recognizing
        controller.phase = .receiving; controller.receivingFrom = "Kitchen Mac mini 2023"
        try await bar("bar-receiving")
        try await bar("bar-receiving-pin", pin: true)
        controller.phase = .done
        try await bar("bar-done-pin", pin: true)
        controller.phase = .recording; controller.connected = false; controller.partial = ""
        try await bar("bar-offline")
        // The compact floating bar, light and dark: Shelf items and a result; recording; empty.
        func compact(_ name: String) async throws {
            let make = { CompactBar(settings: settings, controller: controller, shelf: controller.shelf, meter: controller.meter, glass: false, onExpand: {}) }
            let host = NSHostingView(rootView: make())
            host.layoutSubtreeIfNeeded()
            let size = NSSize(width: CompactBar.width, height: ceil(host.fittingSize.height))
            for dark in [false, true] {
                try await capture(make(), size: size, dark: dark, path: "\(directory)/\(name)\(dark ? "-dark" : "").png")
                count += 1
            }
        }
        controller.phase = .done
        controller.shelf.previewFill()
        // The Shelf shown, whatever an earlier run left.
        UserDefaults.standard.removeObject(forKey: "compactShelfFolded")
        try await compact("compact-shelf")
        controller.shelf.targeted = true
        try await compact("compact-drop")
        controller.shelf.targeted = false
        controller.capsuleShown = true
        controller.phase = .recording; controller.elapsed = 7; controller.connected = true
        controller.partial = "Preview: Discuss the new plan at 3 p.m. tomorrow."
        try await compact("compact-recording")
        controller.partial = ""
        controller.phase = .processing; controller.capsuleStep = .sending; controller.sendingTo = "Kitchen Mac mini 2023"
        try await compact("compact-sending")
        controller.capsuleStep = .recognizing
        controller.phase = .receiving; controller.receivingFrom = "Kitchen Mac mini 2023"
        try await compact("compact-receiving")
        controller.phase = .done; controller.capsuleResult = .inserted
        try await compact("compact-done")
        controller.capsuleResult = .notWritten(DictationController.missTitle(.notAllowed, peer: "Kitchen Mac mini 2023"), DictationController.missLine(.notAllowed, clipboard: .thisMac))
        try await compact("compact-not-typed")
        controller.capsuleResult = .inserted
        controller.phase = .error; controller.message = tr("No text field is focused, saved to history")
        try await compact("compact-error")
        controller.capsuleShown = false
        controller.phase = .done
        UserDefaults.standard.set(true, forKey: "compactShelfFolded")
        try await compact("compact-folded")
        UserDefaults.standard.removeObject(forKey: "compactShelfFolded")
        controller.phase = .idle; controller.result = ""; controller.shelf.items = []; controller.shelf.linked = 0
        let kept = settings.history; settings.history = []
        try await compact("compact-empty")
        settings.history = kept
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
        func press(_ x: CGFloat, fromTop y: CGFloat, in target: NSWindow? = nil) async throws {
            let window = target ?? live
            let point = NSPoint(x: x, y: window.frame.height - y)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else { continue }
                NSApp.sendEvent(event)
                try await Task.sleep(nanoseconds: 60_000_000)
            }
            try await Task.sleep(nanoseconds: 350_000_000)
        }
        func expect(_ ok: Bool, _ what: String) throws { if !ok { throw VoiceError("A click did not reach \(what).") } }
        try await press(258, fromTop: 15)
        try expect(settings.page == .settings, "the settings button in the title row")
        try await shot("window-settings")
        // Text polishing's On and Off (the row under the recognition model; laid out on macOS 15).
        try await press(555, fromTop: 157)
        try expect(settings.preferences.style == "polish", "Text polishing's On in Settings")
        try await press(517, fromTop: 157)
        try expect(settings.preferences.style == StyleChoice.standard, "Text polishing's Off in Settings")
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
        // Keeping on top: its button in the title row, and the bar's own buttons at the end of its first row.
        var compactAsked: Bool?
        settings.setCompact = { compactAsked = $0 }
        try await press(159, fromTop: 15)
        try expect(compactAsked == true, "the Keep on Top button in the title row")
        var expanded = false, unpinned = false
        let bar = makeCompact(onExpand: { expanded = true }, onUnpin: { unpinned = true }, glass: false)
        bar.setFrameOrigin(NSPoint(x: live.frame.minX, y: live.frame.minY))
        bar.alphaValue = 0
        bar.ignoresMouseEvents = true
        bar.orderFrontRegardless()
        try await Task.sleep(nanoseconds: 400_000_000)
        try await press(CompactBar.width - 20, fromTop: 22, in: bar)
        try expect(expanded, "the bar's button back to the full panel")
        try await press(CompactBar.width - 53, fromTop: 22, in: bar)
        try expect(unpinned, "the bar's Stop Keeping on Top button")
        try await press(CompactBar.width - 86, fromTop: 22, in: bar)
        try expect(UserDefaults.standard.bool(forKey: "compactShelfFolded"), "the bar's Hide the Shelf button")
        try await press(CompactBar.width - 86, fromTop: 22, in: bar)
        try expect(!UserDefaults.standard.bool(forKey: "compactShelfFolded"), "the bar's Show the Shelf button")
        UserDefaults.standard.removeObject(forKey: "compactShelfFolded")
        bar.close()
        settings.setCompact = nil
        print("Clicks reach the settings and history buttons, Text polishing's switch, the shortcut badge, Keep on Top, and the bar's Shelf, pin and full panel buttons.")
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

/// The panel's close and minimize buttons in the middle of its title row, as the row's own buttons
/// are (user 2026-11-22: the buttons at the top sat too close to the window's top). A plain title
/// bar has them higher, and AppKit puts them back there whenever it lays the title bar out: each
/// time they move, they are moved again, before anything is drawn. (A toolbar would make the title
/// bar that tall, but it takes the clicks meant for the row's buttons.)
@MainActor
final class TitleRowLights {
    private static var kept: [ObjectIdentifier: TitleRowLights] = [:]
    private static let kinds: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
    private weak var window: NSWindow?
    private var observers: [NSObjectProtocol] = []

    static func center(_ window: NSWindow) {
        kept[ObjectIdentifier(window)] = TitleRowLights(window)
    }

    /// A window that closes for good (another Mac's screen) lets them go.
    static func forget(_ window: NSWindow) {
        guard let lights = kept.removeValue(forKey: ObjectIdentifier(window)) else { return }
        for observer in lights.observers { NotificationCenter.default.removeObserver(observer) }
        lights.observers = []
    }

    private init(_ window: NSWindow) {
        self.window = window
        let center = NotificationCenter.default
        var watched: [(Notification.Name, AnyObject)] = [(NSWindow.didResizeNotification, window), (NSWindow.didBecomeKeyNotification, window),
                                                         (NSWindow.didResignKeyNotification, window)]
        for kind in Self.kinds {
            guard let button = window.standardWindowButton(kind) else { continue }
            button.postsFrameChangedNotifications = true
            watched.append((NSView.frameDidChangeNotification, button))
        }
        for (name, object) in watched {
            observers.append(center.addObserver(forName: name, object: object, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.place() }
            })
        }
        place()
    }

    func place() {
        guard let window else { return }
        for kind in Self.kinds {
            guard let button = window.standardWindowButton(kind), let bar = button.superview else { continue }
            // How far below the window's top the bar starts, and so where in the bar the row's middle is.
            let below = window.frame.height - bar.convert(bar.bounds, to: nil).maxY
            let middle = Metrics.titlebar / 2 - below
            let y = (bar.isFlipped ? middle - button.frame.height / 2 : bar.bounds.height - middle - button.frame.height / 2).rounded()
            if abs(button.frame.minY - y) > 0.25 { button.setFrameOrigin(NSPoint(x: button.frame.minX, y: y)) }
        }
    }
}
