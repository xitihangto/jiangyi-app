import Foundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import CryptoKit

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
    /// 失败时只在「详情」里补一行日志，**不写文件、不截图、不改外观**（用户 2026-10-27 定）。
    /// 挂 didSet 而不是在每个失败分支里各写一次 —— 失败出口有六七个，漏一个就没日志。
    @Published var docx: DocxState = .idle {
        didSet {
            if case .failed(let why) = docx { log("✗ 生成失败：\(why)") }
        }
    }
    /// 用户点了「中止」
    @Published var stopRequested = false

    /// 登录倒计时（0 表示没在倒计时）
    @Published var loginCountdown = 0

    /// 第一次检测有结论之前不显示「登录」按钮 —— 否则一开 App 就闪一下"未登录"，很吓人
    @Published var loginSettled = false

    /// 双绿灯（已登录 + 深度思考/智能搜索已激活）之后 0.5 秒才放出「登出 DeepSeek」按钮。
    /// 延迟是为了不让「登录成功」和「冒出新按钮」发生在同一瞬间 —— 那样看着像闪了一下。
    @Published var logoutReady = false
    private var logoutWorkItem: DispatchWorkItem?
    /// 兜底：已登录但模式迟迟没激活（网页改版、检测一直失败）时，到点也把按钮放出来。
    /// 没有这个兜底，用户就没有任何登出入口 —— 底部那个「⋯」菜单已经删了。
    private var logoutFallbackItem: DispatchWorkItem?
    /// 双绿灯达成到按钮出现之间等多久（用户 2026-10-27 定的 0.5 秒）
    private static let logoutDelay: TimeInterval = 0.5
    /// 只有已登录、模式还没激活时，最多等这么久就把按钮放出来
    private static let logoutFallbackDelay: TimeInterval = 8
    /// 按钮淡入时长
    private static let logoutFade: TimeInterval = 0.5

    /// 深度思考 / 智能搜索 的激活状态（在登录流程里探测，供 idleStatus 显示）
    @Published var deepThinkOn = false
    @Published var smartSearchOn = false
    /// 把模式检查单独展示出来，不能把“登录成功”伪装成“两个模式已就绪”。
    @Published var modeCheckDetail = "正在等待 DeepSeek 输入区加载"

    /// 只有在两个开关都由页面复检为开启后才置 true。页面首次渲染较慢时，下一次
    /// 登录探针会自然重试，不能在“尚未找到按钮”时就永久放弃。
    private var modesChecked = false
    private var modesCheckInFlight = false
    /// “重新检查”蓝字按钮只在绿灯亮起 5 秒后仍未激活时才出现。
    /// 绿灯刚亮那几秒，模式检测即使失败也不出重试字样、不出按钮，
    /// 只在后台每轮探针自动重试，直到 5 秒定时器把这个开关打开。
    @Published var modesRetryAllowed = false
    private var modeRetryWorkItem: DispatchWorkItem?

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
    /// 退出后等待确认：退出时先把登录行打回“正在检测”，
    /// 探针第一次明确说已退出之前，登录按钮和提示字都不出现，
    /// 期间探针偶尔误判成已登录也直接忽略，不翻状态、不启动倒计时。
    /// 这样退出后按钮只出现一次，不会先出现、消失一秒、再出现。
    /// 登录行永远不显示倒计时，倒计时只在内置网页徽标里。
    private var awaitingLogoutConfirmation = false

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
            // 退出等待确认时不放行：按钮要等探针确认已退出才出现，
            // 这里只给正常启动检测兜底，不给退出检测兜底。
            guard let self = self, !self.awaitingLogoutConfirmation else { return }
            self.loginSettled = true
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
                // 退出等待确认期间：只有明确说已退出才放行、翻状态；
                // 其它结果（包括偶尔误判成已登录）一律忽略，登录行继续显示“正在检测”，
                // 不翻绿点、不出按钮、不启动倒计时，按钮只在确认后出现一次。
                if self.awaitingLogoutConfirmation {
                    if result.0.kind == .loggedOut {
                        self.awaitingLogoutConfirmation = false
                        self.login = result.0
                        self.diagnostics = result.1
                        self.loginSettled = true
                        self.reactToLoginState()
                    }
                    return
                }
                let wasLoggedIn = self.login.isLoggedIn
                self.login = result.0
                self.diagnostics = result.1
                if result.0.kind == .noPermission { self.pollingStopped = true }
                if AppState.isDefinite(result.0.kind) { self.loginSettled = true }
                // 先后顺序：绿灯先亮，模式检测后开始，不要和绿灯同一轮探针一起跑。
                // 第一轮刚变已登录时只亮绿灯、不跑模式检测，下一轮探针（已登录已稳定）
                // 才开始检测，这样刚登录那一两秒页面还没准备好时，不会立刻冒出重试。
                if result.0.kind == .loggedIn {
                    if !wasLoggedIn {
                        self.modeCheckDetail = "正在等待 DeepSeek 输入区加载"
                        self.scheduleModeRetryTimer()
                    } else if !self.modesChecked && !self.modesCheckInFlight {
                        print("[DEBUG] refreshLogin: 已登录已稳定，检查深度思考和智能搜索")
                        self.ensureDeepSeekModes()
                    }
                } else {
                    self.modesRetryAllowed = false
                    self.modeRetryWorkItem?.cancel()
                    self.modeRetryWorkItem = nil
                }
                self.reactToLoginState()
                // 每轮探针都顺手校准一次「登出 DeepSeek」按钮的放行状态：
                // 退出登录时它要立刻消失。幂等，不会重复计时。
                self.syncLogoutGate()
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
            // 模式检测不在这里启动：refreshLogin 已经按“绿灯先亮、下一轮再检测”
            // 的顺序管了，这里再调会绕过那个顺序，刚登录就和绿灯一起跑。
            // 退出等待确认期间的误判根本到不了这里（refreshLogin 已拦住），
            // 所以这里不用再连续数两次、三次：一次已登录就启动倒计时收窗口。
            // 倒计时只在内置网页徽标里显示，登录行永远不显示倒计时数字。
            startLoginCountdown()
        } else {
            if let timer = countdownTimer {
                timer.invalidate()
                countdownTimer = nil
                loginCountdown = 0
            }
            pushBadge("正在等待登录…  登录成功后本窗口会自动收起")
        }
    }

    /// 绿灯亮起后 5 秒，才允许出现“重新检查”。5 秒内即使模式没激活，
    /// 也只在后台自动重试，不出重试字样、不出按钮；5 秒后仍未激活，
    /// 定时器把 modesRetryAllowed 打开，按钮和重试文案才出现。
    private func scheduleModeRetryTimer() {
        modeRetryWorkItem?.cancel()
        modesRetryAllowed = false
        let item = DispatchWorkItem { [weak self] in
            guard let self = self, self.login.isLoggedIn, !self.modesChecked else { return }
            self.modesRetryAllowed = true
        }
        modeRetryWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: item)
    }

    // MARK: - 「登出 DeepSeek」按钮的放行

    /// 双绿灯（已登录 + 模式已激活）都亮，才允许出现登出按钮。
    private var logoutAllowed: Bool {
        loginSettled && login.isLoggedIn && modesChecked
    }

    /// 双绿灯一变，就重新安排「登出 DeepSeek」按钮的出现时机。**幂等**，每轮登录探针都能调：
    /// 已经在等那 0.5 秒的不会重新计时，已经亮了的不会重复亮。
    private func syncLogoutGate() {
        let loggedIn = loginSettled && login.isLoggedIn
        guard loggedIn else {
            logoutWorkItem?.cancel()
            logoutWorkItem = nil
            logoutFallbackItem?.cancel()
            logoutFallbackItem = nil
            if logoutReady {
                // 退出登录：按钮淡出
                withAnimation(.easeOut(duration: Self.logoutFade)) { logoutReady = false }
            }
            return
        }
        // 只要登录了就先把兜底计时器挂上 —— 万一模式一直检测不出来，
        // 到点仍然能给用户一个登出入口（底部那个「⋯」已经删了，没有别的路）。
        scheduleLogoutFallback()
        guard logoutAllowed else { return }
        guard !logoutReady, logoutWorkItem == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.logoutWorkItem = nil
            guard self.logoutAllowed else { return }
            // 渐显：按钮从无到有，0.5 秒淡入
            withAnimation(.easeOut(duration: Self.logoutFade)) { self.logoutReady = true }
        }
        logoutWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.logoutDelay, execute: item)
    }

    /// 已登录、但双绿灯迟迟不达成时的兜底。
    /// 只在本次登录会话里挂一次：按钮已经亮了就什么都不做。
    private func scheduleLogoutFallback() {
        guard !logoutReady, logoutFallbackItem == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.logoutFallbackItem = nil
            guard self.loginSettled, self.login.isLoggedIn, !self.logoutReady else { return }
            self.log("模式检测 \(Int(Self.logoutFallbackDelay)) 秒未完成，「登出」按钮按兜底放出")
            withAnimation(.easeOut(duration: Self.logoutFade)) { self.logoutReady = true }
        }
        logoutFallbackItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.logoutFallbackDelay, execute: item)
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
                    // 5 秒内不出“重试”字样，只说在等页面；5 秒后仍失败，才说重试。
                    self.modeCheckDetail = self.modesRetryAllowed ? "模式检查暂时失败，正在重试" : "正在等待页面加载"
                    print("[DEBUG] 开关检查将重试：\(errorDescription)")
                } else {
                    if !deepThinkFound || !smartSearchFound {
                        self.modeCheckDetail = "未识别到模式开关，正在等待页面加载"
                    } else {
                        self.modeCheckDetail = self.modesRetryAllowed ? "模式尚未确认开启，正在重试" : "模式尚未确认开启，正在等待页面加载"
                    }
                    print("[DEBUG] 开关尚未全部就绪，将在下一次登录探针时重试")
                }
                // 模式一就绪，双绿灯达成 —— 立刻校准「登出」按钮的放行（0.5 秒后淡入）
                self.syncLogoutGate()
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
        // 登录成功倒计时走完才到这里，正常情况仍收起窗口，逻辑不动。
        // 但如果倒计时还没走完用户就退出了（或退出后残留的旧倒计时走完），
        // 此时已经是未登录，登录窗口是留给用户重新登录用的，不能再收起它。
        let stillLoggedIn = login.isLoggedIn
        browserShownForLogin = false
        if stillLoggedIn { pushBadge("✓ 已登录") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            // 徽标不管怎样都要清掉，否则退出后网页上还残留“x 秒后自动收起”；
            // 窗口只在登录成功时收起，退出后留给重新登录用，不收。
            self.clearBadge()
            if stillLoggedIn {
                self.browser.hideCompletely()
            }
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

    /// 「登出 DeepSeek」按钮（标题行末尾那个胶囊）的确认框 —— 和退出 App 确认框一样：
    /// 主界面绝对居中、整框玻璃、按钮玻璃，不用 NSAlert 系统弹窗。
    /// 确认后走下面的 logoutDeepSeek；生成进行中时确认框里的登出按钮是禁用的。

    /// 真的清登录态。清完直接把登录窗口弹出来，用户不用再找按钮。
    func logoutDeepSeek() {
        say("正在登出 DeepSeek 账号…", detail: "清掉本机保存的登录信息", running: true)
        // 先停掉探针和倒计时，免得旧状态干扰新登录流程
        timer?.invalidate()
        timer = nil
        countdownTimer?.invalidate()
        countdownTimer = nil
        loginCountdown = 0
        awaitingLogoutConfirmation = true
        browserShownForLogin = false
        // 「登出 DeepSeek」按钮立刻收掉，等重新登录后再走 syncLogoutGate 淡入
        logoutWorkItem?.cancel()
        logoutWorkItem = nil
        logoutFallbackItem?.cancel()
        logoutFallbackItem = nil
        logoutReady = false
        modesChecked = false
        modesCheckInFlight = false
        modesRetryAllowed = false
        modeRetryWorkItem?.cancel()
        modeRetryWorkItem = nil
        deepThinkOn = false
        smartSearchOn = false
        modeCheckDetail = "正在等待 DeepSeek 输入区加载"

        // 把状态框重置回「等待检测」，否则退出后还显示"已登录"
        progress = ProgressInfo()

        browser.clearWebsiteData { [weak self] in
            guard let self = self else { return }
            // 不要在这里立刻把状态写成已退出：清数据回调时页面还是旧的，
            // 立刻写已退出会让登录按钮瞬间出现，下一轮探针误判已登录又把它藏起来，
            // 再下一轮才重新出现，就是用户报的“出现、消失一秒、再出现”。
            // 这里只打回“正在检测”，按钮和提示字等 refreshLogin 探针确认已退出才出现。
            self.login = LoginStatus(kind: .unknown)
            self.loginSettled = false
            self.pollingStopped = false
            self.say("已登出 DeepSeek 账号", detail: "请在打开的窗口里重新登录",
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

    // MARK: - 跨框查重（用户 2026-10-29 第 11 轮）

    /// 只收这几种。`NSOpenPanel` 那边有 `allowedContentTypes` 挡着，
    /// 但拖放绕得过，所以 `accept` 里还要自己挡一次。
    static let allowedExtensions: Set<String> = ["doc", "docx"]

    /// 内容指纹：字节数 + 头 128KB + 尾 128KB 的 SHA-256。
    ///
    /// 讲义的 doc/docx 都很小（几十 KB），本来整份读进内存也没多慢 ——
    /// 这里仍然只读头尾，是为了不让「把整个文件读进内存」变成习惯。
    /// 文件小于 256KB 时头尾重叠，等于读全文，反而更准。
    static func fingerprint(ofFileAt url: URL) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let chunk: UInt64 = 128 * 1024
        var sample = Data()
        try? fh.seek(toOffset: 0)
        sample.append((try? fh.read(upToCount: Int(chunk))) ?? Data())
        if size > chunk * 2 {
            try? fh.seek(toOffset: size - chunk)
            sample.append((try? fh.read(upToCount: Int(chunk))) ?? Data())
        }
        var hasher = SHA256()
        hasher.update(data: sample)
        hasher.update(data: Data("\(size)".utf8))
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return "\(size)-\(hex)"
    }

    /// 两个 URL 是不是同一份文件。
    /// 先比路径（同一个文件被选进两个框），再比内容（复制一份、改个名字再放进来）。
    /// 读不出内容时一律当作「不同」—— 宁可可放过去，也不要误杀。
    static func sameFile(_ a: URL, _ b: URL) -> Bool {
        if a.standardizedFileURL == b.standardizedFileURL { return true }
        guard let fa = fingerprint(ofFileAt: a), let fb = fingerprint(ofFileAt: b) else { return false }
        return fa == fb
    }

    // MARK: - 冒泡提示（落在被操作的那个框上）

    /// 一句话提示。**必须带上 slot** —— 提示要落在被操作的那个框里，
    /// 而不是窗口顶部、也不是另一个框（用户 2026-10-29 特别交代）。
    @Published var toast: String?
    @Published var toastSlot: Slot?
    private var toastItem: DispatchWorkItem?

    func showToast(_ text: String, on slot: Slot, seconds: TimeInterval = 2.7) {
        toastItem?.cancel()
        withAnimation(.easeOut(duration: 0.15)) {
            toast = text
            toastSlot = slot
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                self.toast = nil
                self.toastSlot = nil
            }
        }
        toastItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func dismissToast() {
        toastItem?.cancel()
        withAnimation(.easeOut(duration: 0.18)) {
            toast = nil
            toastSlot = nil
        }
    }

    // MARK: - 等待粘贴 / 右键小菜单（用户 2026-10-29 第 17 轮，逻辑照文章批改 app）

    /// 当前处于「等待粘贴」状态的框，同时只有一个：点另一个框会把它取消。
    @Published var pasteArmed: Slot?

    /// 框内点击的「票据」：框内任何点击都会置 true，全局鼠标监听在 mouseUp 之后看一眼 ——
    /// **有票就不取消，没票才取消**。
    ///
    /// 为什么不用时间戳：右键可以按住不放，按住的时长会把时间戳拖过阈值，
    /// 长按右键就会被误判成「点在外面」，框莫名其妙取消激活。票据跟按键时长完全无关。
    var insideClickTicket = false

    /// 框内被点击：激活等待粘贴，并留一张票
    func armPaste(_ slot: Slot) {
        pasteArmed = slot
        insideClickTicket = true
    }

    /// 框内某个控件（加号、预览卡、叉）被点了：本来就在等粘贴的话，别退出
    func keepPasteArmed(_ slot: Slot) {
        if pasteArmed == slot { insideClickTicket = true }
    }

    /// 右键弹出的小菜单：哪个框、弹在框内哪个位置（左上原点，单位 pt）。
    /// 右键**不直接粘贴**，只激活 + 冒出这个两选一的小菜单。
    @Published var pasteMenuSlot: Slot?
    @Published var pasteMenuPoint: CGPoint = .zero

    func openPasteMenu(_ slot: Slot, at point: CGPoint) {
        armPaste(slot)
        pasteMenuPoint = point
        pasteMenuSlot = slot
    }

    func closePasteMenu() { pasteMenuSlot = nil }

    /// ⌘V / 右键小菜单：从**系统剪贴板**往框里放一个文件。
    func pasteFromClipboard(into slot: Slot) {
        paste(from: .general, into: slot)
    }

    /// 真正干活的那一层。剪贴板作为参数传进来，自检就能用一块私有剪贴板。
    ///
    /// 讲义只收 Word，所以只处理「剪贴板里是文件」这一种；没有文件就直说，
    /// 不去猜「是不是想粘一张图」—— 讲义的两份输入都是 docx，粘图没有意义。
    ///
    /// ⚠️ 剪贴板里一旦有文件 URL，就走完这个分支直接 return，
    /// **绝不能落到 `NSImage(pasteboard:)`**：它会把文件 URL 当图片去解，
    /// 白名单不认的格式（tiff / heic / gif）就这样被塞进框里 ——
    /// 文章版踩过这个坑，症状是「提示了类型不支持，文件却还是进来了」。
    func paste(from pb: NSPasteboard, into slot: Slot) {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = (pb.readObjects(forClasses: [NSURL.self], options: options) as? [URL]) ?? []
        guard !urls.isEmpty else {
            showToast("剪贴板里没有文件，讲义只收 .doc / .docx", on: slot)
            return
        }
        // 复用拖放那条路：只取第一个，多出来的给一句提示；白名单、跨框查重都在 accept 里
        acceptDropped(urls, for: slot)
    }

    /// 把拖进来的 `NSItemProvider` 解析成文件 URL（保持拖进来的顺序）。
    /// 全部回来之后再回调，这样「拖了 3 个」只弹一条提示，而不是三条。
    static func resolveFileURLs(from providers: [NSItemProvider],
                               completion: @escaping ([URL]) -> Void) {
        guard !providers.isEmpty else { completion([]); return }
        var slots = [URL?](repeating: nil, count: providers.count)
        let group = DispatchGroup()
        for (i, provider) in providers.enumerated() {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                slots[i] = url
                group.leave()
            }
        }
        group.notify(queue: .main) {
            completion(slots.compactMap { $0 })
        }
    }

    // MARK: - 文件选择（带目录记忆）

    private static func dirKey(_ slot: Slot) -> String {
        slot == .exam ? "pickDir.exam" : "pickDir.answer"
    }

    /// 上次选文件的目录：优先本框自己的，其次另一个框的，最后下载目录
    ///
    /// 第 16 轮之后两个框的键恒等（选一次两边都写），所以「本框优先」实际上只是容错：
    /// 万一某个键指向的目录被删掉或挪走了，还能退到另一个键 / 共享键 / 下载目录。
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

    /// 记住这次选文件的目录，并**同步给另一个框**（用户 2026-10-29 第 16 轮）。
    ///
    /// 两个框的「上次目录」永远保持一致：框 1 换了目录，框 2 下次打开面板就直接落在同一个目录，
    /// 不用再导航一遍。写进 `UserDefaults`，所以关掉 App 重开也还记得；
    /// 直到用户又选了别的目录，再重新同步一次。
    private func rememberDirectory(_ url: URL, slot: Slot) {
        let dir = url.deletingLastPathComponent().path
        let ud = UserDefaults.standard
        ud.set(dir, forKey: AppState.dirKey(slot))
        // 另一个框立刻继承同一个目录 —— 这是本条需求的关键，不能只写本框的键
        ud.set(dir, forKey: AppState.dirKey(slot == .exam ? .answer : .exam))
        // 老版本留下的共享键，继续写，免得别处还读它时值不一致
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
            // 先记目录再收文件：哪怕这个文件因为类型不对被拒，用户「导航到了哪个目录」
            // 这个事实也该记住，并同步给另一个框（第 16 轮）。
            self.rememberDirectory(url, slot: slot)
            self.accept(url, for: slot)
        }

        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(panel.runModal())
        }
    }

    /// 把一个文件放进某个框。**被拒返回 false**，并冒泡说明原因。
    ///
    /// 两个入口共用：点框选文件、把文件拖进来。所以白名单必须在这里挡一次 ——
    /// `NSOpenPanel` 有 `allowedContentTypes`，拖放可绕不过去。
    @discardableResult
    func accept(_ url: URL, for slot: Slot) -> Bool {
        // ① 类型：只收 Word
        guard Self.allowedExtensions.contains(url.pathExtension.lowercased()) else {
            showToast("只收 Word 文档（.doc / .docx）", on: slot)
            return false
        }
        // ② 跨框查重（用户 2026-10-29 第 11 轮）：
        //    两个框放同一份文件，生成出来的讲义一定是错的 —— 最常见的错法
        //    就是把答案当考卷传、或者反过来。宁可在这一步拦下来。
        if let other = (slot == .exam ? answerURL : examURL), Self.sameFile(url, other) {
            showToast(slot == .exam
                      ? "这份和「上传答案」里的是同一个文件，检查一下是不是放反了"
                      : "这份和「上传考卷」里的是同一个文件，检查一下是不是放反了",
                      on: slot)
            return false
        }

        switch slot {
        case .exam: examURL = url
        case .answer: answerURL = url
        }
        rememberDirectory(url, slot: slot)
        // 不在这里改状态框文案 —— 状态框由 idleStatus 统一按「两个文件 + 登录」推算，
        // 之前那种"已选择 xxx.docx"只反映最后一次操作，看起来像另一个文件丢了。
        // 上一次成功提示也顺便清掉，让状态框回到"还差哪一步"。
        if !isRunning && progress.tone == .ok { progress = ProgressInfo() }
        return true
    }

    /// 拖进来的一批文件（用户 2026-10-29 第 11 轮）。
    /// **一个框只放一个文件**，所以只取第一个；多出来的忽略，并说一句用了哪个。
    func acceptDropped(_ urls: [URL], for slot: Slot) {
        guard let first = urls.first else { return }
        let took = accept(first, for: slot)
        if took && urls.count > 1 {
            showToast("一个框只放一个文件，只用了 \(first.lastPathComponent)", on: slot)
        }
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
        // 框都空了，还挂着「等待粘贴」的蓝边就很怪；小菜单也一起收掉
        pasteArmed = nil
        closePasteMenu()
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

    /// 运行日志面板（成功、失败都从这里看，见 `LogPanel`）。
    /// 2026-10-27 用户定：失败时**不换按钮、不弹面板、不导 md/截图**，
    /// 一律只在这个面板里看 —— 所以 `progressLines` 是唯一的日志出口。
    @Published var showLog = false

    func openLog() {
        guard !showLog else { return }
        withAnimation(.easeOut(duration: 0.18)) { showLog = true }
    }

    func closeLog() {
        guard showLog else { return }
        withAnimation(.easeOut(duration: 0.18)) { showLog = false }
    }

    func toggleLog() {
        if showLog { closeLog() } else { openLog() }
    }

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
                    self.docx = .failed(failure)
                    self.scriptOutput = failure
                    self.restoreHeldFiles()
                    self.say("生成失败了", detail: "点 Word 卡右上角「详情」可以看这次运行的日志，或再试一次",
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
                    self.docx = .failed("执行超时（4 分钟）")
                    self.restoreHeldFiles()
                    self.say("生成超时了", detail: "脚本跑了 4 分钟还没结束，已强制停下",
                             running: false, tone: .error)
                    return
                }
                if result.exitCode != 0 {
                    let msg = "脚本报错（退出码 \(result.exitCode)）"
                    self.docx = .failed(msg)
                    self.restoreHeldFiles()
                    self.say("生成失败了", detail: "点 Word 卡右上角「详情」可以看这次运行的日志，或再试一次",
                             running: false, tone: .error)
                    return
                }
                let docs = result.producedFiles.filter { $0.pathExtension.lowercased() == "docx" }
                guard !docs.isEmpty else {
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

    // MARK: - 失败诊断：已删除（2026-10-27）
    //
    // 这里原来有 `timeStamp` / `diagnosticMarkdown` / `saveDiagnosticLog` / `pruneLogs` /
    // `exportDiagnostics` 五块，外加 BrowserController 里的 `snapshotPNG`，一共约 150 行。
    // 作用是「失败时写一份 md + 一张页面截图，用户手动发给我」。
    //
    // 用户 2026-10-27 定：**失败不要改变任何外观，日志一律看「详情」**。
    // 于是这条链路整个撤掉：失败只做两件事 ——
    //   1. `docx = .failed(原因)`，Word 卡那一行说明改字，别的什么都不动；
    //   2. `docx` 的 didSet 往 `progressLines` 补一行 `✗ 生成失败：…`，进「详情」面板。
    // 别再把它加回来：截图要等主线程、写文件要挑目录、还要定期清理，
    // 换来的只是一份没人看的 md，而「详情」里日志本来就有。

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
                detail: "点 Word 卡右上角「详情」可以看这次运行的日志，或再试一次",
                fraction: 0, running: false, tone: .error)
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

    /// 开发用：`--logdemo` / `--logdemo-closed` / `--faildemo`。
    /// 造一份**像真的跑完一轮**的状态：成品已出、日志有内容、可下载。
    /// 不用真跑三分钟，就能看「详情」面板的版式，以及它有没有压住 Word 卡上的按钮。
    /// 只为截图检查视觉，不碰网络、不跑脚本，正式使用不会触发。
    func applyLogDemo(openPanel: Bool, failed: Bool = false) {
        // 关键顺序：先把轮询停掉，否则 `startPolling()` 已经派出去的那一次探针
        // 会在我们设完状态之后落地，把 login 改成「未登录」—— 界面上就会出现
        // 「登录」和「登出」两个按钮并排的怪画面。停掉之后再补一次延时重设，兜住那一次。
        pollingStopped = true
        let apply: () -> Void = { [weak self] in
            guard let self = self else { return }
            self.login = LoginStatus(kind: .loggedIn)
            self.loginSettled = true
            self.logoutReady = true
            self.isRunning = false
            if failed {
                // 失败态：**只改这一行字**，按钮还是同一个、只是禁用（2026-10-27 用户要求）
                self.progress = ProgressInfo(
                    title: "生成失败了",
                    detail: "点 Word 卡右上角「详情」可以看这次运行的日志，或再试一次",
                    fraction: 0, running: false, tone: .error)
                self.docx = .failed("脚本报错（退出码 1）")
                self.scriptOutput = "Traceback (most recent call last):\n  File \"生成讲义.py\", line 42\nKeyError: 'style'"
            } else {
                self.progress = ProgressInfo(
                    title: "讲义生成好了 ✓",
                    detail: "在下面点「下载 Word 讲义」保存到电脑里",
                    fraction: 1, running: false, tone: .ok)
                // 拿包内模板当「刚生成的成品」，KB 数是真文件大小，卡片上的文案不会露馅
                self.docx = .ready(AppState.bundledTemplate ?? URL(fileURLWithPath: "/tmp/讲义.docx"))
                self.scriptOutput = ""
            }
        }
        apply()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: apply)

        // 照抄一次真实运行的日志形态（根地址重载 → 探针 → 上传 → 发送 → 分段 → 收尾 → 抓脚本）
        progressLines = [
            "页面重载：2.4 秒",
            "等输入框出现：0.4 秒",
            "页面：{\"textarea\":true,\"fileInputs\":1,\"sendLabel\":\"\",\"deepThink\":true,\"smartSearch\":true}",
            "载入 讲义制作规则.md（21 KB）",
            "载入 标准模式讲义.docx（32 KB）",
            "载入 2026届高三英语上学期期中试卷.docx（48 KB）",
            "载入 2026届高三英语上学期期中试卷-参考答案.docx（36 KB）",
            "注入：INPUT:4/0",
            "4 个附件已就位",
            "提示词已填入并回读一致（1043 字）",
            "发送结果：ENTER",
            "代码出现收尾标志：末尾有 .save( 调用",
            "第 1 段写完了，正在请 AI 接着写第 2 段…",
            "继续生效（约 4 秒后开始出字，涨了 2310 字）",
            "内容 3 秒未变且有收尾标志，按完成处理",
            "抓到 1 个代码块，原文总长 14218 字符",
            "脚本 14219 字符，直接执行",
        ]
        showLog = openPanel
    }
}
