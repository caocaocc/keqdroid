import AppKit

public final class DesktopController: NSObject, NSWindowDelegate {
    private weak var window: NSWindow?
    private var statusItem: NSStatusItem?
    private var hotkeys: GlobalHotkeys?
    private var initialized = false
    private var quitHandlerReady = false
    private var minimizeToTray = true
    private var pendingLinks: [String] = []
    private var deliveredLinks: [String: Date] = [:]
    private var emit: (String, [String: Any]) -> Void
    public var terminationApproved = false
    public var linksForForwarding: [String] { pendingLinks }

    public init(window: NSWindow, emit: @escaping (String, [String: Any]) -> Void) {
        self.window = window
        self.emit = emit
        super.init()
    }

    public func enqueue(url: URL) {
        guard ["keqdroid", "keqdis"].contains(url.scheme?.lowercased() ?? "") else { return }
        let text = url.absoluteString
        guard text.utf8.count <= 262144 else { return }
        let now = Date()
        deliveredLinks = deliveredLinks.filter { now.timeIntervalSince($0.value) < 2 }
        guard deliveredLinks[text] == nil, !pendingLinks.contains(text) else { return }
        if pendingLinks.count < 32 { pendingLinks.append(text) }
        if initialized { emit("onDeepLink", [:]); showWindow() }
    }

    public func handle(method: String, arguments: Any?, completion: @escaping (Result<Any?, Error>) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        let args = arguments as? [String: Any] ?? [:]
        do {
            switch method {
            case "initializeDesktop":
                initialize(); completion(.success(nil))
            case "setQuitHandlerReady":
                quitHandlerReady = args["ready"] as? Bool ?? false
                completion(.success(nil))
            case "applyDesktopSettings":
                if let minimized = args["minimizeToTray"] as? Bool { minimizeToTray = minimized }
                if let login = args["launchAtStartup"] as? Bool { try LoginItem.setEnabled(login) }
                completion(.success(nil))
            case "getLoginStatus": completion(.success(LoginItem.status()))
            case "isAutostartLaunch": completion(.success(ProcessInfo.processInfo.arguments.contains("--login")))
            case "toggleWindow": toggleWindow(); completion(.success(nil))
            case "completeQuit":
                terminationApproved = true
                NSApp.reply(toApplicationShouldTerminate: true)
                completion(.success(nil))
            case "getPendingDeepLink":
                let link = pendingLinks.isEmpty ? nil : pendingLinks.removeFirst()
                if let link { deliveredLinks[link] = Date() }
                completion(.success(link))
                if !pendingLinks.isEmpty { DispatchQueue.main.async { self.emit("onDeepLink", [:]) } }
            case "cancelQuit":
                terminationApproved = false
                NSApp.reply(toApplicationShouldTerminate: false)
                showWindow()
                completion(.success(nil))
            case "setGlobalHotkeys":
                if hotkeys == nil { hotkeys = GlobalHotkeys() }
                hotkeys?.onPressed = { [weak self] action in self?.emit("onHotkeyPressed", ["action": action]) }
                completion(.success(hotkeys?.apply(arguments as? [[String: Any]] ?? []) ?? []))
            case "getInstalledApps":
                let includeSystem = args["includeSystem"] as? Bool ?? false
                DispatchQueue.global(qos: .userInitiated).async {
                    let result = ApplicationCatalog.list(includeSystem: includeSystem)
                    DispatchQueue.main.async { completion(.success(result)) }
                }
            case "getAppIcon": completion(.success(ApplicationCatalog.icon(path: args["path"] as? String ?? "")))
            default: throw DesktopError.message("Unsupported desktop operation: \(method)")
            }
        } catch { completion(.failure(error)) }
    }

    private func initialize() {
        guard !initialized else { return }
        initialized = true
        window?.delegate = self
        window?.minSize = NSSize(width: 800, height: 560)
        _ = window?.setFrameUsingName("KEQDISMainWindow")
        window?.setFrameAutosaveName("KEQDISMainWindow")
        keepWindowVisible()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "network", accessibilityDescription: "KEQDIS")
        item.button?.image?.isTemplate = true
        let menu = NSMenu()
        let show = NSMenuItem(title: "Show KEQDIS", action: #selector(showFromMenu), keyEquivalent: "")
        show.target = self
        menu.addItem(show)
        let connect = NSMenuItem(title: "Connect / Disconnect", action: #selector(toggleConnection), keyEquivalent: "")
        connect.target = self
        menu.addItem(connect)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit KEQDIS", action: #selector(quitFromMenu), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        if ProcessInfo.processInfo.arguments.contains("--login") { window?.orderOut(nil) }
    }

    public func requestQuit() {
        if !quitHandlerReady { terminationApproved = true; NSApp.reply(toApplicationShouldTerminate: true); return }
        emit("onQuitRequest", [:])
    }

    public func showWindow() {
        window?.deminiaturize(nil)
        keepWindowVisible()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        emit("onWindowVisibility", ["visible": true])
    }

    public func toggleWindow() {
        if window?.isVisible == true && window?.isMiniaturized == false {
            window?.orderOut(nil)
            emit("onWindowVisibility", ["visible": false])
        } else { showWindow() }
    }

    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        if minimizeToTray {
            sender.orderOut(nil)
            emit("onWindowVisibility", ["visible": false])
        } else { NSApp.terminate(nil) }
        return false
    }

    public func windowDidMiniaturize(_ notification: Notification) { emit("onWindowVisibility", ["visible": false]) }
    public func windowDidDeminiaturize(_ notification: Notification) { emit("onWindowVisibility", ["visible": true]) }
    @objc private func showFromMenu() { showWindow() }
    @objc private func toggleConnection() { emit("onHotkeyPressed", ["action": "toggleConnection"]) }
    @objc private func quitFromMenu() { NSApp.terminate(nil) }
    @objc private func screensChanged() { keepWindowVisible() }

    private func keepWindowVisible() {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        var frame = window.frame
        frame.size.width = min(frame.width, visible.width)
        frame.size.height = min(frame.height, visible.height)
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        window.setFrame(frame, display: true)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
    }
}
