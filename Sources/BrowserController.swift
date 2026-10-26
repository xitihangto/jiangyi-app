import AppKit
import WebKit

/// 允许把窗口挪到屏幕外而不被系统拉回来
final class ParkableWindow: NSWindow {
    var allowOffscreen = true

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        allowOffscreen ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }
}

/// 内置浏览器：一个常驻的 WKWebView + 一个可挪到屏幕外的窗口
final class BrowserController: NSObject, WKNavigationDelegate, NSWindowDelegate {

    private(set) var webView: WKWebView
    private var window: ParkableWindow?
    private(set) var isPageLoaded = false
    private(set) var lastNavigationError: String?

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()          // cookie 持久化在 App 容器里
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 1180, height: 820),
            configuration: config
        )
        super.init()
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
    }

    // MARK: - 窗口

    private func makeWindowIfNeeded() {
        guard window == nil else { return }
        let w = ParkableWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 820),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        w.title = "DeepSeek 登录"
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.collectionBehavior = [.moveToActiveSpace]
        w.contentView = webView
        w.alphaValue = 0                 // 建出来就是隐形的，绝不会有"闪一下"
        w.ignoresMouseEvents = true
        placeCentered(w)
        window = w
    }

    private func placeCentered(_ w: ParkableWindow) {
        w.allowOffscreen = false
        let size = NSSize(width: 1180, height: 820)
        if let screen = NSScreen.main {
            let v = screen.visibleFrame
            let w0 = min(size.width, v.width - 40)
            let h0 = min(size.height, v.height - 40)
            w.setFrame(NSRect(x: v.midX - w0 / 2, y: v.midY - h0 / 2, width: w0, height: h0),
                       display: true)
        }
    }

    /// 完全隐形：alpha = 0 + 鼠标穿透。
    ///
    /// 为什么不挪到屏幕外：那样页面会被判定 hidden，`setInterval` 被节流（实测 200ms 的
    /// 定时器 4 秒只跑 5 次），而且双屏时还会漏到副屏上。
    /// `alphaValue = 0` 时页面**依然认为自己是 visible**，零节流，注入的真实鼠标事件
    /// 也照常命中 —— 这是 2026-10-25 六组实验测出来的最优解。
    func hideCompletely() {
        makeWindowIfNeeded()
        guard let w = window else { return }
        w.alphaValue = 0
        w.ignoresMouseEvents = true
        // 必须在窗口服务器里"存在"，否则 hitTest 找不到视图，注入的事件会被丢弃
        w.orderFrontRegardless()
    }

    /// 内置网页大叉只隐藏，不触发主界面退出确认框，更不退出 App。
    /// 主界面大叉走 ExitConfirmWindowDelegate，那是另一个代理，不要混。
    /// 点主界面“登录 DeepSeek”会走 openDeepSeek -> showForUser 重新显现。
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hideCompletely()
        return false
    }

    /// 只有登录时才把窗口真正显示出来
    func showForUser() {
        makeWindowIfNeeded()
        guard let w = window else { return }
        placeCentered(w)
        w.alphaValue = 1
        w.ignoresMouseEvents = false
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    // MARK: - 状态查询（给自检和调试用）

    var windowAlpha: CGFloat { window?.alphaValue ?? -1 }
    var isWindowOnScreen: Bool { window?.isVisible ?? false }
    var clickThrough: Bool { window?.ignoresMouseEvents ?? false }

    // MARK: - 加载

    func loadDeepSeek(force: Bool = false) {
        makeWindowIfNeeded()
        hideCompletely()
        guard force || !isPageLoaded else { return }
        guard let url = URL(string: "https://chat.deepseek.com/") else { return }
        isPageLoaded = false
        webView.load(URLRequest(url: url))
    }

    func reload() {
        isPageLoaded = false
        webView.reload()
    }

    var currentURL: String {
        webView.url?.absoluteString ?? ""
    }

    /// 退出登录：清掉 DeepSeek 的 cookie / localStorage / IndexedDB，然后重新加载页面。
    ///
    /// 只删 cookie 不够 —— DeepSeek 把会话 token 也放进了 localStorage，
    /// 光清 cookie 页面刷新后照样是登录态。所以走 `WKWebsiteDataStore` 整站清理。
    /// 内存里已加载的 cookie 还要再删一遍，否则当前页面在导航前仍是旧会话。
    func clearWebsiteData(completion: @escaping () -> Void) {
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        store.removeData(ofTypes: types, modifiedSince: .distantPast) { [weak self] in
            DispatchQueue.main.async {
                guard let self = self else { completion(); return }
                let cookieStore = self.webView.configuration.websiteDataStore.httpCookieStore
                cookieStore.getAllCookies { cookies in
                    for cookie in cookies { cookieStore.delete(cookie) }
                    self.isPageLoaded = false
                    self.loadDeepSeek(force: true)
                    completion()
                }
            }
        }
    }

    /// 截一张当前页面，给失败诊断包用。必须在主线程调用。
    ///
    /// 窗口 alpha = 0 也能截到 —— WKWebView 的 takeSnapshot 走的是渲染树，
    /// 不是屏幕抓取，所以不需要为了截图把窗口露出来。
    func snapshotPNG(completion: @escaping (Data?) -> Void) {
        let work = { [weak self] in
            guard let self = self, self.webView.bounds.width > 1 else {
                completion(nil)
                return
            }
            let config = WKSnapshotConfiguration()
            config.rect = self.webView.bounds
            self.webView.takeSnapshot(with: config) { image, _ in
                guard let image = image,
                      let tiff = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:])
                else { completion(nil); return }
                completion(png)
            }
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    // MARK: - 执行 JS

    /// 注意：必须在非主线程调用，否则会死锁
    func evaluateSync(_ js: String) throws -> String {
        if Thread.isMainThread {
            throw BridgeError.failed("内部错误：evaluateSync 不能在主线程调用")
        }
        var outcome: Result<String, Error>?
        let semaphore = DispatchSemaphore(value: 0)

        DispatchQueue.main.async { [weak self] in
            guard let self = self else {
                outcome = .failure(BridgeError.failed("浏览器已释放"))
                semaphore.signal()
                return
            }
            self.webView.evaluateJavaScript(js) { result, error in
                if let error = error {
                    outcome = .failure(BridgeError.failed("JS 执行失败：\(error.localizedDescription)"))
                } else if let text = result as? String {
                    outcome = .success(text)
                } else if let number = result as? NSNumber {
                    outcome = .success(number.stringValue)
                } else if result == nil {
                    outcome = .success("")
                } else {
                    outcome = .success("\(result!)")
                }
                semaphore.signal()
            }
        }

        semaphore.wait()
        guard let outcome = outcome else {
            throw BridgeError.failed("JS 没有返回结果")
        }
        return try outcome.get()
    }

    // MARK: - 真实鼠标事件

    /// 在视口坐标（左上原点、CSS 像素）处派发一次真实的鼠标点击。
    ///
    /// 为什么不直接用 JS 的 `element.click()` / `dispatchEvent`：
    /// 那样造出来的事件 `isTrusted = false`，页面上若有自动化检测就会拒收
    /// （DeepSeek 的「继续生成」实测就是这样——元素、坐标、pointer-events 全正常，
    /// 事件也派出去了，但页面毫无反应）。走 `NSWindow.sendEvent` 注入的
    /// NSEvent 是真实事件，`isTrusted = true`，同时也会产生 user activation。
    ///
    /// 必须在主线程调用。
    @discardableResult
    func clickAtViewportPoint(x: CGFloat, y: CGFloat) -> Bool {
        guard let w = window else { return false }
        let height = webView.bounds.height
        guard height > 1 else { return false }

        // 视口坐标（左上原点）→ NSView 本地坐标（要考虑 isFlipped）
        let localY = webView.isFlipped ? y : (height - y)
        let local = NSPoint(x: x, y: localY)
        let inWindow = webView.convert(local, to: nil)

        let now = ProcessInfo.processInfo.systemUptime
        guard let down = NSEvent.mouseEvent(
                with: .leftMouseDown, location: inWindow, modifierFlags: [],
                timestamp: now, windowNumber: w.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1.0),
              let up = NSEvent.mouseEvent(
                with: .leftMouseUp, location: inWindow, modifierFlags: [],
                timestamp: now + 0.06, windowNumber: w.windowNumber, context: nil,
                eventNumber: 1, clickCount: 1, pressure: 0.0)
        else { return false }

        // 窗口必须是「在窗口服务器里存在」的状态，hitTest 才找得到视图。
        // 不需要显示出来 —— alpha = 0 的窗口一样能收事件（实测）。
        let previousKey = NSApp.keyWindow
        if !w.isVisible { w.orderFrontRegardless() }
        w.makeKeyAndOrderFront(nil)
        w.displayIfNeeded()

        w.sendEvent(down)
        Thread.sleep(forTimeInterval: 0.06)
        w.sendEvent(up)

        // 把 key 还给主窗口，否则主窗口标题栏会一直显示成"非活动"的灰色
        if let previousKey = previousKey, previousKey !== w, previousKey.isVisible {
            previousKey.makeKeyAndOrderFront(nil)
        }
        return true
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isPageLoaded = true
        lastNavigationError = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        lastNavigationError = error.localizedDescription
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        lastNavigationError = error.localizedDescription
    }
}
