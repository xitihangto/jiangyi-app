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

    /// 只把「已加载」标志打回 false，不碰窗口、不碰 WebView。
    /// 给后台线程用：`loadDeepSeek(force:)` 里有 NSWindow 操作必须回主线程，
    /// 等它异步执行完再轮询，标志早就被读成上一轮的 true 了 —— 日志里那个
    /// 「页面重载完成，用时 0.0 秒」就是这么来的，等于根本没等。
    func markReloading() {
        isPageLoaded = false
    }

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

    // 这里原来有个 `snapshotPNG`（截当前页面给失败诊断 md 用），2026-10-27 跟着
    // 「失败不留诊断、日志只看详情」一起删了。真要再截图，用 WKWebView.takeSnapshot，
    // 注意窗口 alpha=0 也能截到（走渲染树，不是屏幕抓取）。

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

    // MARK: - 真实键盘事件

    /// 向页面注入一次真实的 ⌘+<键> 按键。
    ///
    /// 和 `clickAtViewportPoint` 同一个道理：JS 里 `dispatchEvent(new KeyboardEvent(...))`
    /// 造出来的是 `isTrusted = false`，页面的快捷键处理器可以直接不理。
    /// 走 `NSWindow.sendEvent` 的 NSEvent 是真实事件，`isTrusted = true`。
    ///
    /// 带 Command 的 keyDown 在 AppKit 里会先走 `performKeyEquivalent` 链，
    /// 而 WKWebView 覆写了它、把事件转给页面 —— 网页里 ⌘A / ⌘C 能用就是走的这条路。
    ///
    /// 必须在主线程调用。
    @discardableResult
    func sendCommandKey(_ char: String, keyCode: UInt16,
                        modifiers: NSEvent.ModifierFlags = .command) -> Bool {
        guard let w = window else { return false }

        let previousKey = NSApp.keyWindow
        if !w.isVisible { w.orderFrontRegardless() }
        // 只在真的不在前台时才激活：正常流程是用户刚点了「开始生成」，本来就在前台，
        // 这一步不会触发，也就不会把窗口从别的 App 手里抢过来。
        if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(webView)
        w.displayIfNeeded()

        let now = ProcessInfo.processInfo.systemUptime
        guard let down = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: now, windowNumber: w.windowNumber, context: nil,
                characters: char, charactersIgnoringModifiers: char,
                isARepeat: false, keyCode: keyCode),
              let up = NSEvent.keyEvent(
                with: .keyUp, location: .zero, modifierFlags: modifiers,
                timestamp: now + 0.05, windowNumber: w.windowNumber, context: nil,
                characters: char, charactersIgnoringModifiers: char,
                isARepeat: false, keyCode: keyCode)
        else { return false }

        w.sendEvent(down)
        Thread.sleep(forTimeInterval: 0.05)
        w.sendEvent(up)

        if let previousKey = previousKey, previousKey !== w, previousKey.isVisible {
            previousKey.makeKeyAndOrderFront(nil)
        }
        return true
    }

    /// 从后台线程安全地读当前 URL（`webView.url` 只能在主线程取）
    var currentURLSync: String {
        if Thread.isMainThread { return currentURL }
        var s = ""
        DispatchQueue.main.sync { s = self.currentURL }
        return s
    }

    /// `newChatByShortcut` 的三种结局
    enum NewChatOutcome {
        /// 页面本来就停在根地址 —— 已经是空白新对话，一个动作都不用做
        case alreadyFresh
        /// ⌘J 生效，URL 已经变了（附带耗时）
        case shortcut(seconds: Double)
        /// 停在旧会话里按了 ⌘J 没反应 —— 调用方必须回退重载
        case failed
    }

    /// 开新对话：该按 ⌘J 才按，本来就在根地址就什么都不做。**必须在后台线程调用**。
    ///
    /// 判断依据是地址栏：DeepSeek 的会话页是 `/a/chat/s/<id>`，新对话是根地址。
    ///
    /// - 停在根地址 → 直接 `alreadyFresh`。App 刚启动、刚登录、上一轮没发出去，都落在这里。
    ///   这种情况本来就是空对话，再按一次 ⌘J 纯属多余。
    /// - 停在会话页 → 按 ⌘J，URL 变回根地址就算成功；3 秒没变返回 `failed`。
    /// - 页面根本没加载完（`isPageLoaded == false`）→ 也返回 `failed`，交给调用方重载。
    ///   这一条是保险：URL 为空时不能当成「根地址」。
    func newChatByShortcut(timeout: Double = 3.0) -> NewChatOutcome {
        // 主线程调用会死在下面的 main.sync 上；Pipeline 永远在后台线程，这里只是保险。
        if Thread.isMainThread {
            _ = sendCommandKey("j", keyCode: 38)
            return .alreadyFresh
        }
        guard isPageLoaded else { return .failed }

        let before = currentURLSync
        // 不是会话页 = 已经是新对话。空字符串走不到这里（上面拦了）。
        guard before.contains("/a/chat/s/") else { return .alreadyFresh }

        DispatchQueue.main.sync { [self] in _ = sendCommandKey("j", keyCode: 38) }

        var t = 0.0
        while t < timeout {
            Thread.sleep(forTimeInterval: 0.2)
            t += 0.2
            if currentURLSync != before { return .shortcut(seconds: t) }
        }
        return .failed
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
