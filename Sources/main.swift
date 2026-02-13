import Cocoa
import WebKit
import UserNotifications

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var webView: WKWebView!
    private var titleObservation: NSKeyValueObservation?
    private var cookieTimer: Timer?

    private static let cookieFileURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("MessengerDesktop", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("cookies.dat")
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Request native notification permission
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        UNUserNotificationCenter.current().delegate = self

        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []

        config.websiteDataStore = WKWebsiteDataStore.default()

        // Enable developer extras for debugging (right-click -> Inspect Element)
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")

        // Inject JS to bridge web notifications to native
        let contentController = WKUserContentController()
        contentController.add(self, name: "nativeNotification")
        let script = WKUserScript(source: Self.notificationBridgeJS, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        contentController.addUserScript(script)
        config.userContentController = contentController

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true

        // Use a Safari user agent so Facebook serves the full site
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

        // Observe title changes to update dock badge with unread count
        titleObservation = webView.observe(\.title, options: [.new]) { [weak self] _, change in
            guard let self = self, let title = change.newValue ?? nil else { return }
            self.window?.title = title.isEmpty ? "Messenger" : title
            self.updateBadge(from: title)
        }

        // Create centered window
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let width: CGFloat = min(1200, screen.width * 0.8)
        let height: CGFloat = min(860, screen.height * 0.85)
        let x = screen.origin.x + (screen.width - width) / 2
        let y = screen.origin.y + (screen.height - height) / 2

        window = NSWindow(
            contentRect: NSRect(x: x, y: y, width: width, height: height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Messenger"
        window.minSize = NSSize(width: 480, height: 400)
        window.contentView = webView
        window.setFrameAutosaveName("MessengerMainWindow")
        window.titlebarAppearsTransparent = true
        window.makeKeyAndOrderFront(nil)

        setupMenu()

        // Restore cookies from previous session, then load
        restoreCookies {
            let url = URL(string: "https://www.messenger.com")!
            self.webView.load(URLRequest(url: url))
        }

        // Periodically save cookies while the app is running (every 30s)
        cookieTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.saveCookies()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { window.makeKeyAndOrderFront(nil) }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        cookieTimer?.invalidate()
        // Save cookies with a short timeout so the app doesn't hang on quit
        let semaphore = DispatchSemaphore(value: 0)
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
            Self.writeCookiesToDisk(cookies)
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 2)
    }

    // MARK: - Cookie Persistence

    private func saveCookies() {
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
            Self.writeCookiesToDisk(cookies)
        }
    }

    private static func writeCookiesToDisk(_ cookies: [HTTPCookie]) {
        // Serialize each cookie as its properties dictionary
        let props = cookies.compactMap { $0.properties as NSDictionary? }
        let data = try? NSKeyedArchiver.archivedData(withRootObject: props, requiringSecureCoding: false)
        try? data?.write(to: cookieFileURL, options: .atomic)
    }

    private func restoreCookies(completion: @escaping () -> Void) {
        guard let fileData = try? Data(contentsOf: Self.cookieFileURL),
              let propsList = try? NSKeyedUnarchiver.unarchivedObject(
                  ofClasses: [NSArray.self, NSDictionary.self, NSString.self, NSNumber.self, NSDate.self, NSURL.self],
                  from: fileData
              ) as? [[HTTPCookiePropertyKey: Any]] else {
            completion()
            return
        }

        let cookies = propsList.compactMap { HTTPCookie(properties: $0) }
        guard !cookies.isEmpty else { completion(); return }

        let store = webView.configuration.websiteDataStore.httpCookieStore
        let group = DispatchGroup()
        for cookie in cookies {
            group.enter()
            store.setCookie(cookie) { group.leave() }
        }
        group.notify(queue: .main) { completion() }
    }

    // MARK: - Badge

    private func updateBadge(from title: String) {
        // Messenger may use various title formats:
        //   "(3) Messenger"  or  "Messenger (3)"  or  "(3) Chat name"
        // Look for any number inside parentheses anywhere in the title
        if let range = title.range(of: #"\((\d+)\)"#, options: .regularExpression),
           let digits = Int(title[range].dropFirst().dropLast()) {
            NSApplication.shared.dockTile.badgeLabel = "\(digits)"
        } else {
            NSApplication.shared.dockTile.badgeLabel = nil
        }
    }

    // MARK: - Menu

    private func setupMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Messenger", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Messenger", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Messenger", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Edit menu (copy/paste support is critical for a messaging app)
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // View menu
        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        let reload = NSMenuItem(title: "Reload", action: #selector(reloadPage), keyEquivalent: "r")
        reload.target = self
        viewMenu.addItem(reload)
        let actualSize = NSMenuItem(title: "Actual Size", action: #selector(resetZoom), keyEquivalent: "0")
        actualSize.target = self
        viewMenu.addItem(actualSize)
        let zoomIn = NSMenuItem(title: "Zoom In", action: #selector(zoomIn), keyEquivalent: "+")
        zoomIn.target = self
        viewMenu.addItem(zoomIn)
        let zoomOut = NSMenuItem(title: "Zoom Out", action: #selector(zoomOut), keyEquivalent: "-")
        zoomOut.target = self
        viewMenu.addItem(zoomOut)
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        // Window menu
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApplication.shared.mainMenu = mainMenu
        NSApplication.shared.windowsMenu = windowMenu
    }

    @objc private func reloadPage() { webView.reload() }
    @objc private func resetZoom() { webView.pageZoom = 1.0 }
    @objc private func zoomIn() { webView.pageZoom += 0.1 }
    @objc private func zoomOut() { webView.pageZoom = max(0.5, webView.pageZoom - 0.1) }

    // MARK: - Notification Bridge JS

    static let notificationBridgeJS = """
    (function() {
        // Override the Notification API to bridge to native macOS notifications
        const NativeNotification = window.Notification;

        class BridgedNotification {
            constructor(title, options = {}) {
                this.title = title;
                this.body = options.body || '';
                this.icon = options.icon || '';
                this.tag = options.tag || '';
                this.onclick = null;
                this._closed = false;

                // Send to native side
                window.webkit.messageHandlers.nativeNotification.postMessage({
                    type: 'show',
                    title: this.title,
                    body: this.body,
                    tag: this.tag,
                    icon: this.icon
                });
            }

            close() { this._closed = true; }

            static get permission() { return 'granted'; }

            static requestPermission(callback) {
                const result = 'granted';
                if (callback) callback(result);
                return Promise.resolve(result);
            }
        }

        // Preserve static properties
        BridgedNotification.maxActions = NativeNotification ? NativeNotification.maxActions : 2;

        window.Notification = BridgedNotification;
    })();
    """;
}

// MARK: - WKScriptMessageHandler (notification bridge)

extension AppDelegate: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "nativeNotification",
              let body = message.body as? [String: Any],
              let type = body["type"] as? String,
              type == "show" else { return }

        let title = body["title"] as? String ?? "Messenger"
        let text = body["body"] as? String ?? ""
        let tag = body["tag"] as? String ?? UUID().uuidString

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = text
        content.sound = .default

        let request = UNNotificationRequest(identifier: tag, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension AppDelegate: UNUserNotificationCenterDelegate {
    // Show notifications even when the app is in the foreground (but window is not focused)
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        if NSApplication.shared.isActive && window.isKeyWindow {
            // App is focused — don't show a banner
            completionHandler([])
        } else {
            completionHandler([.banner, .sound])
        }
    }

    // Clicking a notification brings the app to the foreground
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        completionHandler()
    }
}

// MARK: - WKNavigationDelegate

extension AppDelegate: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        let host = url.host ?? ""
        let allowed = ["messenger.com", "facebook.com", "fbcdn.net", "fbsbx.com", "facebook.net", "accountkit.com"]

        if allowed.contains(where: { host.hasSuffix($0) }) {
            decisionHandler(.allow)
        } else if navigationAction.navigationType == .linkActivated || !host.isEmpty {
            // External link — open in default browser
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }
}

// MARK: - WKUIDelegate

extension AppDelegate: WKUIDelegate {
    // Handle target="_blank" links
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            let host = url.host ?? ""
            if host.hasSuffix("messenger.com") || host.hasSuffix("facebook.com") {
                webView.load(navigationAction.request)
            } else {
                NSWorkspace.shared.open(url)
            }
        }
        return nil
    }

    // Camera & mic permission prompts (for video/audio calls)
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        // Grant permission for messenger.com — macOS will still show its own system prompt
        if origin.host.hasSuffix("messenger.com") {
            decisionHandler(.grant)
        } else {
            decisionHandler(.deny)
        }
    }
}

// MARK: - Main

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.activate(ignoringOtherApps: true)
app.run()
