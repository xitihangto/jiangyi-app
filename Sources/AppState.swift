import Foundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct LoginStatus {
    enum Kind {
        case unknown, loggedIn, loggedOut, noSafari, noWindow, noPage, wrongPage, noPermission, jsDisabled
    }

    var kind: Kind = .unknown
    var detail: String = ""

    var isLoggedIn: Bool { kind == .loggedIn }

    var needsJSHelp: Bool { kind == .jsDisabled }

    var dotColor: Color {
        switch kind {
        case .loggedIn: return .green
        case .loggedOut, .wrongPage: return .orange
        case .noPermission, .jsDisabled: return .red
        default: return Color(nsColor: .tertiaryLabelColor)
        }
    }

    var label: String {
        switch kind {
        case .loggedIn: return "已登录 DeepSeek"
        case .loggedOut: return "还没登录 DeepSeek"
        case .noSafari: return "Safari 未运行"
        case .noWindow: return "Safari 没有打开窗口"
        case .wrongPage: return "当前标签页不是 DeepSeek"
        case .noPermission: return "缺少控制 Safari 的权限"
        case .jsDisabled: return "Safari 未开启「允许来自 Apple 事件的 JavaScript」"
        case .noPage: return "正在连接 DeepSeek…"
        case .unknown: return "正在检查登录状态…"
        }
    }
}

/// 给不懂编程的人看的进度，只保留「在干什么 / 到哪一步了 / 成没成」
struct ProgressInfo: Equatable {
    enum Tone { case idle, ok, error }

    var title: String = "等待上传文档"
    var detail: String = "请上传考卷与答案两份 Word 文档，两份齐备后即可开始生成备课讲义。"
    /// 0 表示进度不确定（用滚动条动画），0~1 之间才是确定的百分比
    var fraction: Double = 0
    var running: Bool = false
    var tone: Tone = .idle
}

/// 空闲时状态框显示什么 —— 按「考卷 / 答案 / 登录」的组合给书面文案
struct IdleStatus {
    var title: String
    var detail: String
    /// 0~1，用来画"准备到哪一步了"的进度条
    var fraction: Double
}

/// 讲义成品的状态机 —— 界面那张「Word 讲义」卡片直接照着它渲染
enum DocxState: Equatable {
    case idle                 // 还没开始，卡片显示为未激活的占位
    case building             // 正在生成
    case ready(URL)           // 好了，可以下载
    case failed(String)

    var isReady: Bool { if case .ready = self { return true }; return false }
    var isBuilding: Bool { if case .building = self { return true }; return false }
    var url: URL? { if case .ready(let u) = self { return u }; return nil }
}

final class AppState: ObservableObject {
    enum Slot { case exam, answer }

    @Published var examURL: URL?
    @Published var answerURL: URL?
    @Published var login = LoginStatus()
    @Published var isRunning = false
    @Published var progress = ProgressInfo()
    @Published var diagnostics = ""
    @Published var autoSend = true
    @Published var progressLines: [String] = []
    /// 一进失败态就自动留一份日志（写 App 支持目录，不打扰用户）。
    /// 挂 didSet 而不是在每个失败分支里各写一次 —— 失败出口有六七个，漏一个就没日志。
    @Published var docx: DocxState = .idle {
        didSet {
            if case .failed = docx { saveDiagnosticLog() }
        }
    }
    /// 用户点了「中止」
    @Published var stopRequested = false

    /// 登录倒计时（0 表示没在倒计时）
    @Published var loginCountdown = 0

    /// 第一次检测有结论之前不显示「登录」按钮 —— 否则一开 App 就闪一下"未登录"，很吓人
    @Published var loginSettled = false

    /// 最近一次失败原因
    @Published var lastFailure = ""

    /// 深度思考 / 智能搜索 的激活状态（在登录流程里探测，供 idleStatus 显示）
    @Published var deepThinkOn = false
    @Published var smartSearchOn = false
    /// 把模式检查单独展示出来，不能把“登录成功”伪装成“两个模式已就绪”。
    @Published var modeCheckDetail = "正在等待 DeepSeek 输入区加载"

    /// 只有在两个开关都由页面复检为开启后才置 true。页面首次渲染较慢时，下一次
    /// 登录探针会自然重试，不能在“尚未找到按钮”时就永久放弃。
    private var modesChecked = false
    private var modesCheckInFlight = false

    enum Engine: String, CaseIterable, Identifiable {
        case webview = "内置浏览器"
        case safari = "Safari"
        var id: String { rawValue }
    }

    /// Safari 通道保留着（万一以后内置浏览器出问题可以切回去），界面上不再暴露
    @Published var engine: Engine = .webview
    let browser = BrowserController()

    /// 浏览器当前是不是为了登录而露出来的
    private var browserShownForLogin = false
    private var countdownTimer: Timer?

    /// 统一的 JS 执行入口：内置浏览器 / Safari 两条通道
    func js(_ code: String) throws -> String {
        switch engine {
        case .webview:
            if browser.currentURL.isEmpty { return "__NO_PAGE__" }
            if !browser.currentURL.contains("deepseek") {
                return "__WRONG_PAGE__" + browser.currentURL
            }
            return try browser.evaluateSync(code)
        case .safari:
            return try SafariBridge.doJS(code)
        }
    }

    /// 技术日志：只进内存，不再往界面上贴
    func log(_ line: String) {
        if Thread.isMainThread {
            progressLines.append(line)
            if progressLines.count > 400 { progressLines.removeFirst(200) }
        } else {
            DispatchQueue.main.async { self.log(line) }
        }
    }

    /// 面向用户的进度播报（线程安全）
    func say(_ title: String,
             detail: String = "",
             fraction: Double = 0,
             running: Bool = false,
             tone: ProgressInfo.Tone = .idle) {
        let apply: () -> Void = { [weak self] in
            self?.progress = ProgressInfo(title: title, detail: detail,
                                          fraction: fraction, running: running, tone: tone)
        }
        if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
    }

    private var timer: Timer?
    private var pollBusy = false
    private var pollingStopped = false

    static let docTypes: [UTType] = {
        var types: [UTType] = []
        if let t = UTType(filenameExtension: "docx") { types.append(t) }
        if let t = UTType(filenameExtension: "doc") { types.append(t) }
        return types.isEmpty ? [.data] : types
    }()

    deinit {
        timer?.invalidate()
        countdownTimer?.invalidate()
    }

    var canGenerate: Bool {
        examURL != nil && answerURL != nil && loginSettled && login.isLoggedIn && !isRunning
    }

    var hintText: String {
        if login.kind == .jsDisabled {
            return "Safari 少一个开关：设置 → 开发 → 允许来自 Apple 事件的 JavaScript"
        }
        if examURL == nil || answerURL == nil { return "把考卷和答案两个文件都放进来" }
        if !loginSettled { return "" }
        if !login.isLoggedIn { return "先点「登录 DeepSeek」，登录一次以后就不用再登" }
        return ""
    }

    var modeStatusText: String? {
        guard login.isLoggedIn else { return nil }
        if modesChecked { return "深度思考、联网搜索已激活" }
        if modesCheckInFlight { return "正在检查深度思考、联网搜索…" }
        return modeCheckDetail
    }

    var modesReady: Bool { modesChecked }
    var modesChecking: Bool { modesCheckInFlight }

    /// 空闲时状态框的文案。四种组合，用书面语说清楚下一步该干什么。
    var idleStatus: IdleStatus {
        switch (examURL != nil, answerURL != nil) {
        case (false, false):
            return IdleStatus(
                title: "等待上传文档",
                detail: "请上传考卷与答案两份 Word 文档，两份齐备后即可开始生成备课讲义。",
                fraction: 0)
        case (true, false):
            return IdleStatus(
                title: "考卷已就绪",
                detail: "请继续上传答案文档，其中应包含参考答案、解析或范文。",
                fraction: 0.34)
        case (false, true):
            return IdleStatus(
                title: "答案已就绪",
                detail: "请继续上传考卷文档，其中应包含题目与原文。",
                fraction: 0.34)
        case (true, true):
            if !loginSettled {
                return IdleStatus(
                    title: "文档已就绪",
                    detail: "正在确认登录状态，请稍候。",
                    fraction: 0.72)
            }
            if !login.isLoggedIn {
                return IdleStatus(
                    title: "文档已就绪",
                    detail: "请先登录 DeepSeek 账号，登录成功后即可开始生成备课讲义。",
                    fraction: 0.72)
            }
            // 登录后把深度思考/智能搜索状态拼进标题
            var title = "准备就绪"
            var modes: [String] = []
            if deepThinkOn { modes.append("深度思考") }
            if smartSearchOn { modes.append("智能搜索") }
            if !modes.isEmpty {
                title += "（\(modes.joined(separator: "、")) 已激活）"
            }
            return IdleStatus(
                title: title,
                detail: "考卷与答案均已就绪，点击上方「生成备课讲义」即可开始。",
                fraction: 1)
        }
    }

    // MARK: - 登录

    func startPolling() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refreshLogin()
        }
        if engine == .webview { browser.loadDeepSeek() }
        refreshLogin()
        // 兜底：万一页面一直加载不出来，20 秒后也把「登录」按钮放出来，
        // 不然用户会一直卡在"正在检测"，没有出口
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            self?.loginSettled = true
        }
    }

    func refreshLogin() {
        guard !pollingStopped, !pollBusy, !isRunning else { return }
        pollBusy = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let result = self.probeLogin()
            DispatchQueue.main.async {
                self.pollBusy = false
                self.login = result.0
                self.diagnostics = result.1
                if result.0.kind == .noPermission { self.pollingStopped = true }
                if AppState.isDefinite(result.0.kind) { self.loginSettled = true }
                // 如果启动时就已经是登录态（浏览器有缓存），ensureDeepSeekModes 也要跑
                // 但只跑一次，modesChecked 会拦住重复调用
                if result.0.kind == .loggedIn && !self.modesChecked && !self.modesCheckInFlight {
                    print("[DEBUG] refreshLogin: 已登录，检查深度思考和智能搜索")
                    self.ensureDeepSeekModes()
                }
                self.reactToLoginState()
            }
        }
    }

    /// 这些状态是"问清楚了"的，可以据此决定要不要显示登录按钮。
    /// `.noPage` / `.unknown` 只是还没查出来，继续等。
    private static func isDefinite(_ kind: LoginStatus.Kind) -> Bool {
        switch kind {
        case .loggedIn, .loggedOut, .wrongPage, .noSafari, .noWindow, .noPermission, .jsDisabled:
            return true
        case .noPage, .unknown:
            return false
        }
    }

    /// 登录状态一变，决定要不要开始倒计时收窗口。
    /// 登录成功后顺便把「深度思考」和「智能搜索」都激活（这两个状态在对话间会传递，
    /// 只要开一次就行，所以趁登录时一并处理）。
    private func reactToLoginState() {
        guard browserShownForLogin else { return }
        if login.isLoggedIn {
            ensureDeepSeekModes()
            startLoginCountdown()
        } else {
            pushBadge("正在等待登录…  登录成功后本窗口会自动收起")
        }
    }

    /// 登录成功后，确保深度思考 + 智能搜索都已激活。
    /// 如果本来就是开的，状态栏提示「已激活」；如果 App 帮点了，提示「已开启」。
    private func ensureDeepSeekModes() {
        guard !modesChecked, !modesCheckInFlight else { return }
        modesCheckInFlight = true
        modeCheckDetail = "正在检查深度思考、联网搜索…"
        print("[DEBUG] ensureDeepSeekModes: 开始探测")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            var finalDeepThink = false
            var finalSmartSearch = false
            var deepThinkFound = false
            var smartSearchFound = false
            var errorDescription: String?
            do {
                let probe = try self.js(Scripts.probeComposer)
                print("[DEBUG] probeComposer 返回: \(probe)")
                guard let data = probe.data(using: .utf8),
                      let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                else { throw BridgeError.failed("无法解析输入区开关状态") }
                let dt = obj["deepThink"] as? Bool ?? false
                let ss = obj["smartSearch"] as? Bool ?? false
                deepThinkFound = obj["deepThinkFound"] as? Bool ?? false
                smartSearchFound = obj["smartSearchFound"] as? Bool ?? false
                print("[DEBUG] deepThink=\(dt), smartSearch=\(ss)")
                var requested: [String] = []

                if !dt, let (x, y) = Self.modeRect(obj["deepThinkRect"]) {
                    print("[DEBUG] 点击深度思考: (\(x), \(y))")
                    if self.clickBrowserMode(at: x, y: y) { requested.append("深度思考") }
                } else {
                    if !dt { print("[DEBUG] 深度思考未激活且找不到坐标") }
                }

                if !ss, let (x, y) = Self.modeRect(obj["smartSearchRect"]) {
                    print("[DEBUG] 点击智能搜索: (\(x), \(y))")
                    if self.clickBrowserMode(at: x, y: y) { requested.append("智能搜索") }
                } else {
                    if !ss { print("[DEBUG] 智能搜索未激活且找不到坐标") }
                }

                // 不能把“已发出点击”当作“已开启”：等页面处理事件后重新探测确认。
                if !requested.isEmpty { Thread.sleep(forTimeInterval: 0.9) }
                let verified = try self.js(Scripts.probeComposer)
                guard let verifiedData = verified.data(using: .utf8),
                      let verifiedObj = (try? JSONSerialization.jsonObject(with: verifiedData)) as? [String: Any]
                else { throw BridgeError.failed("无法复检输入区开关状态") }
                finalDeepThink = verifiedObj["deepThink"] as? Bool ?? false
                finalSmartSearch = verifiedObj["smartSearch"] as? Bool ?? false
                deepThinkFound = verifiedObj["deepThinkFound"] as? Bool ?? deepThinkFound
                smartSearchFound = verifiedObj["smartSearchFound"] as? Bool ?? smartSearchFound
                print("[DEBUG] 开关复检: deepThink=\(finalDeepThink), smartSearch=\(finalSmartSearch)")
            } catch {
                print("[DEBUG] ensureDeepSeekModes 异常: \(error)")
                errorDescription = error.localizedDescription
            }
            DispatchQueue.main.async {
                self.modesCheckInFlight = false
                self.deepThinkOn = finalDeepThink
                self.smartSearchOn = finalSmartSearch
                self.modesChecked = finalDeepThink && finalSmartSearch
                if self.modesChecked {
                    // 登录流程结束后进度卡会回到 idleStatus；由它统一显示“已激活”，
                    // 不留一条成功提示遮住空闲状态框。
                    print("[DEBUG] 深度思考、智能搜索均已激活")
                } else if let errorDescription {
                    self.modeCheckDetail = "模式检查暂时失败，正在重试"
                    print("[DEBUG] 开关检查将重试：\(errorDescription)")
                } else {
                    if !deepThinkFound || !smartSearchFound {
                        self.modeCheckDetail = "未识别到模式开关，正在等待页面加载"
                    } else {
                        self.modeCheckDetail = "模式尚未确认开启，正在重试"
                    }
                    print("[DEBUG] 开关尚未全部就绪，将在下一次登录探针时重试")
                }
            }
        }
    }

    /// JSONSerialization 会把坐标对象桥接成 `[String: Any]` / `NSNumber`，不能直接
    /// 转成 `[String: Double]`。这是 v0.17 找得到按钮却无法点击的根因。
    private static func modeRect(_ value: Any?) -> (CGFloat, CGFloat)? {
        guard let rect = value as? [String: Any],
              let x = (rect["x"] as? NSNumber)?.doubleValue,
              let y = (rect["y"] as? NSNumber)?.doubleValue,
              x.isFinite, y.isFinite else { return nil }
        return (CGFloat(x), CGFloat(y))
    }

    /// `clickAtViewportPoint` 会操作 NSWindow，必须在主线程做；模式探测本身则留在
    /// 后台，避免等待 WebKit 回调时卡住界面。
    private func clickBrowserMode(at x: CGFloat, y: CGFloat) -> Bool {
        if Thread.isMainThread { return browser.clickAtViewportPoint(x: x, y: y) }
        var clicked = false
        DispatchQueue.main.sync { [weak self] in
            clicked = self?.browser.clickAtViewportPoint(x: x, y: y) ?? false
        }
        return clicked
    }

    /// 让用户可以在网页改版、或网络导致首次页面晚到时主动重新跑一次检查。
    func retryDeepSeekModes() {
        guard login.isLoggedIn, !modesCheckInFlight else { return }
        modesChecked = false
        deepThinkOn = false
        smartSearchOn = false
        ensureDeepSeekModes()
    }

    private func startLoginCountdown() {
        guard countdownTimer == nil else { return }
        loginCountdown = 5
        pushBadge("✓ 登录成功，\(loginCountdown) 秒后自动收起本窗口")
        say("登录成功", detail: "窗口将在 \(loginCountdown) 秒后自动收起，不用管它",
            running: false, tone: .ok)

        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] t in
            guard let self = self else { t.invalidate(); return }
            self.loginCountdown -= 1
            if self.loginCountdown <= 0 {
                t.invalidate()
                self.countdownTimer = nil
                self.finishLogin()
            } else {
                self.pushBadge("✓ 登录成功，\(self.loginCountdown) 秒后自动收起本窗口")
            }
        }
    }

    private func finishLogin() {
        browserShownForLogin = false
        pushBadge("✓ 已登录")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            self.browser.hideCompletely()
            self.clearBadge()
        }
        // 回到空闲状态框，标题会根据 deepThinkOn / smartSearchOn 显示开关状态。
        progress = ProgressInfo()
    }

    private func pushBadge(_ text: String) {
        guard engine == .webview else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            _ = try? self?.js(Scripts.loginBadge(text: text))
        }
    }

    private func clearBadge() {
        guard engine == .webview else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            _ = try? self?.js(Scripts.loginBadgeClear)
        }
    }

    /// 打开浏览器让用户登录（这是全 App 唯一会露出窗口的地方）
    func openDeepSeek() {
        switch engine {
        case .webview:
            browser.loadDeepSeek(force: false)
            browser.showForUser()
            browserShownForLogin = true
            pushBadge("正在等待登录…  登录成功后本窗口会自动收起")
            say("请在打开的窗口里登录 DeepSeek",
                detail: "登录成功后窗口会自动收起，不用手动关", running: false)
        case .safari:
            SafariBridge.openDeepSeek()
            say("正在打开 chat.deepseek.com，请在 Safari 里完成登录", running: false)
        }
        pollingStopped = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.refreshLogin()
        }
    }

    /// 右下角「⋯」里的退出登录 —— 先问一句，别让人手滑把登录态清了
    func confirmLogout() {
        guard !isRunning else { return }
        let alert = NSAlert()
        alert.messageText = "退出 DeepSeek 账号？"
        alert.informativeText = """
        会清掉本机保存的登录信息，然后重新打开登录页。
        之后需要重新扫码或输入账号密码登录。
        """
        alert.addButton(withTitle: "退出并重新登录")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        logoutDeepSeek()
    }

    /// 真的清登录态。清完直接把登录窗口弹出来，用户不用再找按钮。
    func logoutDeepSeek() {
        say("正在退出 DeepSeek 账号…", detail: "清掉本机保存的登录信息", running: true)
        // 先停掉探针和倒计时，免得旧状态干扰新登录流程
        timer?.invalidate()
        timer = nil
        countdownTimer?.invalidate()
        countdownTimer = nil
        loginCountdown = 0
        browserShownForLogin = false
        modesChecked = false
        modesCheckInFlight = false
        deepThinkOn = false
        smartSearchOn = false
        modeCheckDetail = "正在等待 DeepSeek 输入区加载"

        // 把状态框重置回「等待检测」，否则退出后还显示"已登录"
        progress = ProgressInfo()

        browser.clearWebsiteData { [weak self] in
            guard let self = self else { return }
            self.login = LoginStatus(kind: .loggedOut)
            self.loginSettled = true
            self.pollingStopped = false
            self.say("已退出 DeepSeek 账号", detail: "请在打开的窗口里重新登录",
                    running: false, tone: .ok)
            self.openDeepSeek()
            // 清完数据后探针被停了，必须重新启动，否则登录成功没人发现
            self.startPolling()
        }
    }

    func showJSHelp() {
        let alert = NSAlert()
        alert.messageText = "需要在 Safari 里打开一个开关"
        alert.informativeText = """
        1. 打开 Safari，菜单栏点「Safari」→「设置…」（⌘,）
        2. 切到「高级」标签，勾选「显示网页开发者功能」
        3. 再切到「开发」标签，勾选「允许来自 Apple 事件的 JavaScript」

        打开后本 App 会在 3 秒内自动恢复，不用重启 App。
        """
        alert.addButton(withTitle: "打开 Safari")
        alert.addButton(withTitle: "知道了")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Safari.app"))
        }
    }

    func probeLogin() -> (LoginStatus, String) {
        do {
            let raw = try js(Scripts.loginProbe)
            if raw == "__NO_SAFARI__" { return (LoginStatus(kind: .noSafari), raw) }
            if raw == "__NO_WINDOW__" { return (LoginStatus(kind: .noWindow), raw) }
            if raw == "__NO_PAGE__" { return (LoginStatus(kind: .noPage), raw) }
            if raw.hasPrefix("__WRONG_PAGE__") {
                return (LoginStatus(kind: .wrongPage, detail: String(raw.dropFirst(15))), raw)
            }
            guard let data = raw.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else {
                return (LoginStatus(kind: .unknown, detail: raw), raw)
            }
            let hasChat = obj["hasChatInput"] as? Bool ?? false
            let hasLoginForm = obj["hasLoginForm"] as? Bool ?? false
            let hasLoginButton = obj["hasLoginButton"] as? Bool ?? false
            let bodyLen = obj["bodyLen"] as? Int ?? 0
            let keys = obj["keys"] as? [String] ?? []
            let fileInputs = obj["fileInputs"] as? Int ?? 0
            let diag = "localStorage: \(keys.prefix(8).joined(separator: ", "))\n"
                + "chatInput=\(hasChat)  loginForm=\(hasLoginForm)  loginBtn=\(hasLoginButton)"
                + "  fileInput=\(fileInputs)  bodyLen=\(bodyLen)"

            if hasChat && !hasLoginForm { return (LoginStatus(kind: .loggedIn), diag) }
            if hasLoginForm || hasLoginButton { return (LoginStatus(kind: .loggedOut), diag) }
            // 既没有输入框也没有登录入口 —— 多半是页面还没渲染完，别急着下结论。
            // 早期版本在这里直接返回 loggedOut，导致 App 一启动就闪一下"未登录"。
            if bodyLen < 80 { return (LoginStatus(kind: .noPage), diag) }
            return (LoginStatus(kind: .unknown, detail: "页面有内容但认不出登录状态"), diag)
        } catch let err {
            let msg = err.localizedDescription
            if msg.contains("Allow JavaScript from Apple Events") || msg.contains("do JavaScript") {
                return (LoginStatus(kind: .jsDisabled), msg)
            }
            if let be = err as? BridgeError, case .denied = be {
                return (LoginStatus(kind: .noPermission), msg)
            }
            return (LoginStatus(kind: .unknown, detail: msg), msg)
        }
    }

    // MARK: - 文件选择（带目录记忆）

    private static func dirKey(_ slot: Slot) -> String {
        slot == .exam ? "pickDir.exam" : "pickDir.answer"
    }

    /// 上次选文件的目录：优先本框自己的，其次另一个框的，最后下载目录
    private func startDirectory(for slot: Slot) -> URL? {
        let ud = UserDefaults.standard
        let otherKey = AppState.dirKey(slot == .exam ? .answer : .exam)
        let candidates = [AppState.dirKey(slot), otherKey, "pickDir.shared"]
        for key in candidates {
            if let path = ud.string(forKey: key) {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                    return URL(fileURLWithPath: path, isDirectory: true)
                }
            }
        }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    }

    private func rememberDirectory(_ url: URL, slot: Slot) {
        let dir = url.deletingLastPathComponent().path
        let ud = UserDefaults.standard
        ud.set(dir, forKey: AppState.dirKey(slot))
        ud.set(dir, forKey: "pickDir.shared")
    }

    func chooseFile(for slot: Slot) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = AppState.docTypes
        panel.message = "只接受 doc 或 docx 文件"
        panel.prompt = "选择"
        panel.title = slot == .exam ? "选择考卷" : "选择答案"
        panel.isExtensionHidden = false
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = startDirectory(for: slot)

        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self = self, response == .OK, let url = panel.url else { return }
            self.accept(url, for: slot)
        }

        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(panel.runModal())
        }
    }

    private func accept(_ url: URL, for slot: Slot) {
        switch slot {
        case .exam: examURL = url
        case .answer: answerURL = url
        }
        rememberDirectory(url, slot: slot)
        // 不在这里改状态框文案 —— 状态框由 idleStatus 统一按「两个文件 + 登录」推算，
        // 之前那种"已选择 xxx.docx"只反映最后一次操作，看起来像另一个文件丢了。
        // 上一次成功提示也顺便清掉，让状态框回到"还差哪一步"。
        if !isRunning && progress.tone == .ok { progress = ProgressInfo() }
    }

    func clearFile(for slot: Slot) {
        switch slot {
        case .exam: examURL = nil
        case .answer: answerURL = nil
        }
        if !isRunning && progress.tone == .ok { progress = ProgressInfo() }
    }

    // MARK: - 内置附件

    static var bundledRule: URL? {
        Bundle.main.url(forResource: "讲义制作规则", withExtension: "md")
    }

    static var bundledTemplate: URL? {
        Bundle.main.url(forResource: "标准模式讲义", withExtension: "docx")
    }

    /// 请求中止当前流程（用户点「中止」时）
    func requestStop() {
        stopRequested = true
        PythonRunner.cancelCurrent()      // Python 跑起来的时候也能立刻停
        say("正在中止…", running: true)
    }

    // MARK: - 生成

    /// 已经提交出去、但为了防重复生成而从上传框里清掉的两个文件。
    /// 失败或中止时放回去，用户不用重新选一遍。
    @Published var heldFiles: (exam: URL, answer: URL)?

    func generate() {
        guard canGenerate else { return }
        runPipeline()
    }

    /// 提交后立刻清空两个上传框：同一批文件不会被反复提交，也避免误点出第二份讲义。
    /// 调用前必须先把两个 URL 拷出来（runPipeline 里已拷到局部变量）。
    func submitAndClearUploads() {
        guard let exam = examURL, let answer = answerURL else { return }
        heldFiles = (exam, answer)
        examURL = nil
        answerURL = nil
    }

    /// 失败 / 中止时把文件放回上传框
    func restoreHeldFiles() {
        guard let held = heldFiles else { return }
        examURL = held.exam
        answerURL = held.answer
        heldFiles = nil
    }

    // MARK: - 内置 Python 执行

    @Published var scriptOutput = ""
    @Published var showOutputPanel = false

    var pythonReady: Bool { PythonRunner.isAvailable }

    /// 抓到脚本 → 直接跑，不再问用户
    func offerScript(_ code: String) {
        let cleaned = ScriptExtractor.normalize(code)
        guard cleaned.count > 40 else {
            log("没有抓到可用的 Python 脚本")
            say("没有拿到可用的脚本", detail: "可以重试一次", running: false, tone: .error)
            return
        }
        log("脚本 \(cleaned.count) 字符，直接执行")
        runScript(cleaned)
    }

    func runScript(_ code: String) {
        let cleaned = ScriptExtractor.normalize(code)
        guard cleaned.count > 40 else {
            say("脚本内容太短，像是没生成全", running: false, tone: .error)
            return
        }
        isRunning = true
        scriptOutput = ""
        lastFailure = ""
        docx = .building
        say("正在生成 Word 讲义…", detail: "大约需要几十秒，请稍等", running: true)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            var payload: RunResult?
            var failure: String?
            do {
                payload = try PythonRunner.run(script: cleaned)
            } catch {
                failure = error.localizedDescription
            }

            DispatchQueue.main.async {
                self.isRunning = false
                if let failure = failure {
                    self.lastFailure = failure
                    self.docx = .failed(failure)
                    self.scriptOutput = failure
                    self.restoreHeldFiles()
                    self.say("生成失败了", detail: "可以点下面「查看详情」看原因，或再试一次",
                             running: false, tone: .error)
                    return
                }
                guard let result = payload else { return }
                self.scriptOutput = result.output.isEmpty ? "（脚本没有任何输出）" : result.output

                if result.cancelled {
                    self.docx = .idle
                    self.restoreHeldFiles()
                    self.say("已中止", detail: "讲义没有生成，两份文档已放回上传框，可以重新来一次",
                             running: false)
                    return
                }
                if result.timedOut {
                    self.lastFailure = "执行超时（4 分钟）"
                    self.docx = .failed("执行超时（4 分钟）")
                    self.restoreHeldFiles()
                    self.say("生成超时了", detail: "脚本跑了 4 分钟还没结束，已强制停下",
                             running: false, tone: .error)
                    return
                }
                if result.exitCode != 0 {
                    let msg = "脚本报错（退出码 \(result.exitCode)）"
                    self.lastFailure = msg
                    self.docx = .failed(msg)
                    self.restoreHeldFiles()
                    self.say("生成失败了", detail: "可以点下面「查看详情」看原因，或再试一次",
                             running: false, tone: .error)
                    return
                }
                let docs = result.producedFiles.filter { $0.pathExtension.lowercased() == "docx" }
                guard !docs.isEmpty else {
                    self.lastFailure = "脚本跑完了，但没有产出 docx"
                    self.docx = .failed("没有产出 docx")
                    self.restoreHeldFiles()
                    self.say("生成失败了", detail: "脚本跑完了，但没有产出 Word 文件",
                             running: false, tone: .error)
                    return
                }
                if let stored = self.storeProduced(docs) {
                    self.docx = .ready(stored)
                    self.heldFiles = nil          // 成功了就不再需要"放回去"
                    self.say("讲义生成好了 ✓", detail: "在下面点「下载 Word 讲义」保存到电脑里",
                             running: false, tone: .ok)
                } else {
                    self.docx = .failed("无法保存产物")
                    self.restoreHeldFiles()
                    self.say("生成失败了", detail: "文件存不下来", running: false, tone: .error)
                }
            }
        }
    }

    /// 产物不再搬到 Application Support/成品目录：直接用 Python 临时目录里的原件。
    /// 下载成功后由 downloadDocx 删掉它；下载失败或取消面板时不删，还能再点一次下载。
    private func storeProduced(_ files: [URL]) -> URL? {
        return files.first
    }

    /// 点「下载 Word 讲义」：弹系统面板选位置
    func downloadDocx() {
        guard let src = docx.url else { return }
        let panel = NSSavePanel()
        panel.title = "保存讲义"
        panel.message = "选择讲义存到哪里"
        panel.nameFieldStringValue = defaultDocxName()
        if let t = UTType(filenameExtension: "docx") { panel.allowedContentTypes = [t] }
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        if let dir = startDirectory(for: .exam) { panel.directoryURL = dir }

        guard panel.runModal() == .OK, let dest = panel.url else { return }
        let fm = FileManager.default
        do {
            try? fm.removeItem(at: dest)
            try fm.copyItem(at: src, to: dest)
            // 只有真正下载成功才删临时原件：先删文件本身，再把同批的临时工作目录清掉
            // （目录名以“讲义生成-run-”开头、且确实在系统临时目录下才删，防止误删别处文件）。
            // 删完卡片回到未生成状态，同一个临时文件不会被重复下载第二次。
            try? fm.removeItem(at: src)
            let workDir = src.deletingLastPathComponent()
            if workDir.path.hasPrefix(NSTemporaryDirectory()),
               workDir.lastPathComponent.hasPrefix("讲义生成-run-") {
                try? fm.removeItem(at: workDir)
            }
            docx = .idle
            say("讲义已保存 ✓", detail: dest.path, running: false, tone: .ok)
            revealInFinder(dest)
        } catch {
            say("保存失败", detail: error.localizedDescription, running: false, tone: .error)
        }
    }

    /// 在 Finder 里「打开所在文件夹并选中这个文件」。
    ///
    /// 不用 `activateFileViewerSelecting` —— 那个 API 会先激活 Finder 再开窗口，
    /// 用户反馈保存完讲义后会额外弹一个"桌面"窗口（Finder 没有已开窗口时的默认行为）。
    /// `selectFile(_:inFileViewerRootedAtPath:)` 直接定位到目标文件夹，只开一个窗口。
    private func revealInFinder(_ file: URL) {
        let folder = file.deletingLastPathComponent().path
        NSWorkspace.shared.selectFile(file.path, inFileViewerRootedAtPath: folder)
    }

    private func defaultDocxName() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd-HHmm"
        return "讲义-\(df.string(from: Date())).docx"
    }

    // MARK: - 失败诊断（Markdown 报告 + 页面截图）

    private static func timeStamp() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd-HHmmss"
        return df.string(from: Date())
    }

    /// 报告正文。用 Markdown 而不是 json/txt：能放标题、表格、代码块，
    /// 还能直接 `![]()` 引一张截图，老师用「预览」打开就能看，发给开发也好读。
    private func diagnosticMarkdown(stamp: String, shotName: String?) -> String {
        var md: [String] = []
        md.append("# 讲义生成 · 失败诊断报告")
        md.append("")
        md.append("| 项目 | 内容 |")
        md.append("| --- | --- |")
        md.append("| 生成时间 | \(stamp) |")
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        md.append("| App 版本 | \(version) |")
        md.append("| 系统版本 | \(ProcessInfo.processInfo.operatingSystemVersionString) |")
        md.append("| 页面地址 | \(browser.currentURL.isEmpty ? "（无）" : browser.currentURL) |")
        md.append("")

        if let shot = shotName {
            md.append("## 失败时的页面")
            md.append("")
            md.append("![页面截图](\(shot))")
            md.append("")
        } else {
            md.append("> 页面截图没有取到（页面可能还没加载完，或者窗口还没建出来）。")
            md.append("")
        }

        md.append("## 失败原因")
        md.append("")
        md.append(lastFailure.isEmpty ? (progress.detail.isEmpty ? "（没有记录）" : progress.detail)
                                      : lastFailure)
        md.append("")
        md.append("## 界面最后一次提示")
        md.append("")
        md.append("\(progress.title) ｜ \(progress.detail)")
        md.append("")
        md.append("## Python 输出")
        md.append("")
        md.append("```text")
        md.append(scriptOutput.isEmpty ? "（没有输出）" : scriptOutput)
        md.append("```")
        md.append("")
        md.append("## 流程记录")
        md.append("")
        md.append("```text")
        md.append(progressLines.isEmpty ? "（无）" : progressLines.joined(separator: "\n"))
        md.append("```")
        md.append("")
        return md.joined(separator: "\n")
    }

    /// 失败时自动留档：静默写进 App 支持目录，桌面上不弹任何东西。
    /// 用户的原话是「失败就失败吧，只要存日志即可」——所以默认不打扰，
    /// 需要发给开发者时再点「导出诊断文件」。
    func saveDiagnosticLog() {
        let stamp = AppState.timeStamp()
        let finish: () -> Void = { [weak self] in
            guard let self = self else { return }
            self.browser.snapshotPNG { png in
                let fm = FileManager.default
                guard let base = fm.urls(for: .applicationSupportDirectory,
                                         in: .userDomainMask).first else { return }
                let dir = base.appendingPathComponent("讲义生成/日志", isDirectory: true)
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
                let shotName = "失败-\(stamp)-页面.png"
                if let png = png {
                    try? png.write(to: dir.appendingPathComponent(shotName))
                }
                let md = self.diagnosticMarkdown(stamp: stamp,
                                                 shotName: png != nil ? shotName : nil)
                let out = dir.appendingPathComponent("失败-\(stamp).md")
                try? md.write(to: out, atomically: true, encoding: .utf8)
                self.log("失败日志已存：\(out.path)")
                AppState.pruneLogs(in: dir, keep: 30)
            }
        }
        if Thread.isMainThread { finish() } else { DispatchQueue.main.async(execute: finish) }
    }

    /// 只留最近 N 份，免得日志目录无限长大
    private static func pruneLogs(in dir: URL, keep: Int) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return }
        let reports = files.filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        guard reports.count > keep else { return }
        for old in reports.dropFirst(keep) {
            let stem = old.deletingPathExtension().lastPathComponent
            try? fm.removeItem(at: old)
            let png = dir.appendingPathComponent("\(stem)-页面.png")
            try? fm.removeItem(at: png)
        }
    }

    /// 点「导出诊断文件」：在桌面生成一个文件夹，里面是 md 报告 + 截图，直接发人。
    func exportDiagnostics() {
        let stamp = AppState.timeStamp()
        browser.snapshotPNG { [weak self] png in
            guard let self = self else { return }
            let fm = FileManager.default
            guard let desktop = fm.urls(for: .desktopDirectory,
                                        in: .userDomainMask).first else {
                self.say("导出失败", detail: "找不到桌面目录", running: false, tone: .error)
                return
            }
            let dir = desktop.appendingPathComponent("讲义生成-失败诊断-\(stamp)",
                                                     isDirectory: true)
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                let shotName = "页面截图.png"
                if let png = png {
                    try png.write(to: dir.appendingPathComponent(shotName))
                }
                let md = self.diagnosticMarkdown(stamp: stamp,
                                                 shotName: png != nil ? shotName : nil)
                let out = dir.appendingPathComponent("诊断报告.md")
                try md.write(to: out, atomically: true, encoding: .utf8)
                self.say("诊断报告已导出到桌面 ✓", detail: out.lastPathComponent,
                         running: false, tone: .ok)
                self.revealInFinder(out)
            } catch {
                self.say("导出失败", detail: error.localizedDescription,
                         running: false, tone: .error)
            }
        }
    }

    // MARK: - 开发用：登录流程自检

    /// `--logintest` 启动：强制成「未登录」→ 打开登录窗口 → 等真实探针发现已登录
    /// → 倒计时 → 强制隐藏。全程每秒打一行状态，用来验证注入的提示条和自动收起。
    /// 会真的把浏览器窗口弹出来几秒，只在开发时用。
    func runLoginSelfTest() {
        print("== 登录流程自检开始，等页面加载 ==")
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { [weak self] in
            guard let self = self else { return }
            self.login = LoginStatus(kind: .loggedOut)
            self.loginSettled = true
            print("[t=0] 强制未登录，调用 openDeepSeek()")
            self.openDeepSeek()
            self.tickLoginTest(0)
        }
    }

    /// 开发用：读取当前 DeepSeek 输入区的模式探针结果，不改页面状态。
    /// `--modeprobe` 启动后等待页面加载，再把原始返回打印到标准输出并退出。
    func runModeProbe() {
        print("== 模式探针开始，等待页面加载 ==")
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) { [weak self] in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let self = self else { exit(1) }
                let result = (try? self.js(Scripts.probeComposer)) ?? "(读取失败)"
                print("MODE_PROBE: \(result)")
                exit(0)
            }
        }
    }

    private func tickLoginTest(_ n: Int) {
        guard n <= 22 else {
            print("== 自检结束 ==")
            exit(0)
        }
        // evaluateSync 不能在主线程调用，先扔到后台读页面上的提示条文字
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let badge = (try? self.js(
                "(document.getElementById('__wb_badge__')||{}).textContent||'(无提示条)'"))
                ?? "(读取失败)"
            let line = String(
                format: "[t=%2ds] 倒计时=%d  alpha=%.1f  窗口在屏=%d  点击穿透=%d  登录态=%@  提示条=%@",
                n, self.loginCountdown, self.browser.windowAlpha,
                self.browser.isWindowOnScreen ? 1 : 0,
                self.browser.clickThrough ? 1 : 0,
                "\(self.login.kind)", badge)
            DispatchQueue.main.async {
                print(line)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.tickLoginTest(n + 1)
                }
            }
        }
    }

    // MARK: - 开发用：界面状态演示

    /// `--uidemo` 1=生成中 / 2=已出成品 / 3=失败 / 4=只传考卷 / 5=只传答案 / 6=都传但未登录
    /// 只为截图检查视觉，不碰网络、不跑脚本。正式使用不会触发。
    func applyUIDemo(step: Int) {
        let exam = URL(fileURLWithPath: "/Users/Shared/2026届高三英语上学期期中试卷.docx")
        let answer = URL(fileURLWithPath: "/Users/Shared/2026届高三英语上学期期中试卷-参考答案.docx")
        login = LoginStatus(kind: .loggedIn)
        loginSettled = true
        progress = ProgressInfo()

        switch step {
        case 4:
            examURL = exam
            return
        case 5:
            answerURL = answer
            return
        case 6:
            examURL = exam
            answerURL = answer
            login = LoginStatus(kind: .loggedOut)
            pollingStopped = true      // 演示用：别让真实探针把状态改回去
            return
        default:
            break
        }

        examURL = exam
        answerURL = answer
        if step == 1 {
            isRunning = true
            progress = ProgressInfo(
                title: "第 1 段写完了，正在请 AI 接着写第 2 段…",
                detail: "脚本比较长，AI 会分段写完，这是正常的",
                fraction: 0, running: true)
            docx = .building
        } else if step == 3 {
            isRunning = false
            progress = ProgressInfo(
                title: "生成失败了",
                detail: "可以点下面「查看详情」看原因，或再试一次",
                fraction: 0, running: false, tone: .error)
            lastFailure = "脚本报错（退出码 1）"
            scriptOutput = "Traceback (most recent call last):\n  File \"生成讲义.py\", line 42\nKeyError: 'style'"
            docx = .failed("脚本报错（退出码 1）")
        } else {
            isRunning = false
            progress = ProgressInfo(
                title: "讲义生成好了 ✓",
                detail: "在下面点「下载 Word 讲义」保存到电脑里",
                fraction: 1, running: false, tone: .ok)
            docx = .ready(URL(fileURLWithPath: "/tmp/讲义.docx"))
        }
    }
}
