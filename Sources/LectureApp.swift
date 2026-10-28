import SwiftUI
import AppKit

// MARK: - 品牌色

/// 试用版 Liquid Glass（本地试用，不升版、不推 GitHub，用户 2026-10-26 特别交代先本地跑看效果）。
/// 只给上传卡用：macOS 26+ 走玻璃，旧系统自动回退到现有的实色卡片 + 阴影。
extension View {
    @ViewBuilder func trialGlassCard(cornerRadius: CGFloat, shadowOpacity: Double, shadowRadius: CGFloat) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self.background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(shadowOpacity), radius: shadowRadius, y: 4)
            )
        }
    }
    /// 带 tint 的玻璃按钮：26+ 走玻璃 + tint，旧系统走原来的填充 + 阴影。
    @ViewBuilder func trialGlassTinted(cornerRadius: CGFloat, tint: Color, fallback: AnyShapeStyle, shadowColor: Color, shadowRadius: CGFloat, shadowY: CGFloat) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular.tint(tint), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self.background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(fallback)
                    .shadow(color: shadowColor, radius: shadowRadius, y: shadowY)
            )
        }
    }
    /// 玻璃小药丸：26+ 走玻璃胶囊，旧系统走原来的胶囊填充。
    @ViewBuilder func trialGlassCapsule(fallbackFill: Color) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: Capsule())
        } else {
            self.background(Capsule().fill(fallbackFill))
        }
    }
    /// 退出确认框的按钮样式：26+ 走系统玻璃按钮，旧系统走原来的 bordered。
    /// 两个按钮用同一个样式，系统 hover 才完全一样；不要再在上面叠自定义
    /// onHover + 放大 + 提亮 + 手型光标，那是取消按钮闪黑闪白、边缘手/箭头
    /// 来回跳的根源（玻璃材质重算 + 双重 hover 处理）。
    @ViewBuilder func dialogGlassButtonStyle() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
    }
    /// 主操作按钮：26+ 走系统玻璃 prominent，旧系统走 borderedProminent。
    /// 取消保持上面的 .glass。方案 2 的自定义 plain + tint 玻璃已删：
    /// 它和取消的系统玻璃是两个世界的产物，用户 2026-10-26 否决。
    /// 主按钮 hover 只叠黑 0.06 变深，和取消的系统 hover 逻辑统一，按下状态不动。
    @ViewBuilder func dialogGlassProminentButtonStyle() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }
}

extension Color {
    static let brandBlue = Color(red: 0.16, green: 0.45, blue: 0.94)
    static let brandPurple = Color(red: 0.55, green: 0.32, blue: 0.93)
    static let brandPink = Color(red: 0.94, green: 0.33, blue: 0.58)
    static let brandRed = Color(red: 0.91, green: 0.30, blue: 0.38)
}

@main
struct LectureApp: App {
    @StateObject private var state = AppState()

    init() {
        // 自检模式：不启动界面，只验证包内资源与类型白名单
        if CommandLine.arguments.contains("--selftest") {
            print("bundle   = \(Bundle.main.bundlePath)")
            print("rule     = \(AppState.bundledRule?.path ?? "❌ 未找到")")
            print("template = \(AppState.bundledTemplate?.path ?? "❌ 未找到")")
            print("docTypes = \(AppState.docTypes.map { $0.identifier }.joined(separator: ", "))")
            let rule = AppState.bundledRule.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            print("ruleHead = \(rule?.prefix(40).replacingOccurrences(of: "\n", with: " ") ?? "❌ 读不出")")
            print("python   = \(PythonRunner.executable?.path ?? "❌ 未找到")")
            print("pySize   = \(PythonRunner.sizeDescription)")
            exit(0)
        }

        // 自检：两框之间的查重（--dupetest，用户 2026-10-29 第 11 轮）
        // 要验证四件事：
        //   ① 同一份文件换个名字，指纹一样（按内容判，不按文件名）
        //   ② 不同内容指纹不一样
        //   ③ 考卷框放过的文件，再往答案框放 —— **必须被拒**，而且提示落在答案框上
        //   ④ 不重复的文件照常收下
        if CommandLine.arguments.contains("--dupetest") {
            let dir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("dupe-test-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }

            func write(_ body: String, to name: String) -> URL {
                let url = dir.appendingPathComponent(name)
                try? Data(body.utf8).write(to: url)
                return url
            }

            let a = write("考卷正文……", to: "考卷.docx")
            let b = write("考卷正文……", to: "考卷-副本.docx")     // 同内容、不同名
            let c = write("答案正文……", to: "答案.docx")          // 不同内容
            let bad = write("考卷正文……", to: "考卷.pdf")         // 类型不在白名单

            let app = AppState()
            let r1 = app.accept(a, for: .exam)            // 应 true
            let r2 = app.accept(b, for: .answer)          // 应 false（和考卷框里那份同内容）
            let dupToast = app.toast
            let dupSlot = app.toastSlot
            let answerEmpty = app.answerURL == nil        // 被拒之后答案框必须还是空的
            let r3 = app.accept(c, for: .answer)          // 应 true
            let r4 = app.accept(bad, for: .exam)          // 应 false（类型不对）
            let typeToast = app.toast

            var lines: [String] = []
            lines.append("指纹 a == b（内容同、名字不同）：\(AppState.sameFile(a, b))")
            lines.append("指纹 a != c（内容不同）：        \(!AppState.sameFile(a, c))")
            lines.append("考卷框放 a       → \(r1)（应 true）")
            lines.append("答案框放 b(重复) → \(r2)（应 false）")
            lines.append("    提示：\(dupToast ?? "无")")
            lines.append("    落在：\(dupSlot.map { $0 == .exam ? "考卷框" : "答案框" } ?? "无")（应为答案框）")
            lines.append("    答案框还是空的：\(answerEmpty)")
            lines.append("答案框放 c       → \(r3)（应 true）")
            lines.append("考卷框放 .pdf    → \(r4)（应 false）")
            lines.append("    提示：\(typeToast ?? "无")")
            FileHandle.standardError.write(Data((lines.joined(separator: "\n") + "\n").utf8))

            let ok = AppState.sameFile(a, b)
                && !AppState.sameFile(a, c)
                && r1 && !r2 && answerEmpty && r3 && !r4
                && dupSlot == .answer
                && (dupToast ?? "").contains("放反")
            exit(ok ? 0 : 1)
        }

        // 脚本执行自检：--runpython /path/to/script.py
        if let idx = CommandLine.arguments.firstIndex(of: "--runpython"),
           idx + 1 < CommandLine.arguments.count {
            let path = CommandLine.arguments[idx + 1]
            print("python = \(PythonRunner.executable?.path ?? "❌ 未找到")")
            print("size   = \(PythonRunner.sizeDescription)")
            let code = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            guard !code.isEmpty else {
                print("❌ 读不到脚本：\(path)")
                exit(2)
            }
            do {
                let r = try PythonRunner.run(script: code, timeout: 90)
                print("exit   = \(r.exitCode)  timeout=\(r.timedOut)")
                print("work   = \(r.workDir.path)")
                print("files  = \(r.producedFiles.map { $0.lastPathComponent })")
                print("--- output ---")
                print(r.output)
                if let doc = r.producedFiles.first(where: { $0.pathExtension == "docx" }) {
                    let attrs = try? FileManager.default.attributesOfItem(atPath: doc.path)
                    let size = (attrs?[.size] as? Int) ?? 0
                    print("--- docx \(size) bytes ---")
                }
                exit(r.ok ? 0 : 1)
            } catch {
                print("❌ \(error.localizedDescription)")
                exit(3)
            }
        }
    }

    var body: some Scene {
        WindowGroup("讲义生成") {
            ContentView().environmentObject(state)
        }
        .windowResizability(.contentSize)
    }
}

// MARK: - 左上角关闭按钮 = 退出确认

/// 系统红灯（左上角关闭按钮）默认只关窗口，App 本身还留在后台。
/// 这里把它改成“退出 App”：窗口代理先拦住关闭（返回 false），
/// 发通知让 ContentView 在窗口绝对中心弹确认框；用户点“退出”才真正 terminate，
/// 点“取消”窗口原样保留。Cmd+Q 走系统退出，不经过这条路，不受影响。
/// 注意：代理只实现 windowShouldClose，其它窗口行为不受影响。
extension Notification.Name {
    static let lectureAppConfirmExit = Notification.Name("LectureAppConfirmExit")
}

final class ExitConfirmWindowDelegate: NSObject, NSWindowDelegate {
    static let shared = ExitConfirmWindowDelegate()
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NotificationCenter.default.post(name: .lectureAppConfirmExit, object: nil)
        return false
    }
}

/// 把窗口代理挂到主窗口上：NSViewRepresentable 的 view 一拿到 window 就设代理，
/// update 时再设一次，防止 SwiftUI 后续重建时代理被换掉。
struct WindowCloseAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                window.delegate = ExitConfirmWindowDelegate.shared
                // 标题栏只留红绿灯，不显示“讲义生成”几个字（和界面内大标题重复）。
                // 只隐藏标题栏文字，不改窗口本身的标题，Dock 菜单里的窗口名还在。
                window.titleVisibility = .hidden
            }
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                window.delegate = ExitConfirmWindowDelegate.shared
                window.titleVisibility = .hidden
            }
        }
    }
}

// MARK: - 手型光标

/// 可按的元素统一换成"手"光标。
/// 用 `onContinuousHover` + `NSCursor.set()` 而不是 push/pop：
/// push/pop 必须严格配对，视图在悬停中被移除（比如上传框选中后重绘）就会漏 pop，
/// 光标会永久卡成手型。`set()` 无栈，退出时再设回箭头即可。
struct HandCursor: ViewModifier {
    func body(content: Content) -> some View {
        content.onContinuousHover { phase in
            switch phase {
            case .active: NSCursor.pointingHand.set()
            case .ended: NSCursor.arrow.set()
            }
        }
    }
}

extension View {
    /// 给可按的元素加手型光标。**状态展示区不要加**。
    func handCursor() -> some View { modifier(HandCursor()) }
}

// MARK: - 旋转渐变描边

/// 激活状态元素的边框：一圈随时间旋转的渐变色。
/// 用 TimelineView 逐帧算角度，因为 AngularGradient 的 angle 不是可动画属性，
/// 用 withAnimation 推不动它。
struct RotatingGradientBorder: View {
    var radius: CGFloat = 16
    var lineWidth: CGFloat = 1.8
    var active: Bool = true
    var period: Double = 3.2

    private let colors: [Color] = [.brandBlue, .brandPurple, .brandPink, .brandBlue]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !active)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let angle = Angle.degrees((t.truncatingRemainder(dividingBy: period) / period) * 360)
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(
                    AngularGradient(gradient: Gradient(colors: colors),
                                    center: .center, angle: angle),
                    lineWidth: lineWidth
                )
        }
        .allowsHitTesting(false)
    }
}

// MARK: - 主界面

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @State private var showExitConfirm = false
    @State private var showLogoutConfirm = false
    // 主页面 hover：只做玻璃上的一层浅色提亮，不叠放大、提亮、brightness，
    // 退出/取消按钮那次闪黑闪白就是叠了那些才出的，这里不再重蹈覆辙。
    @State private var generateHover = false
    @State private var exitPrimaryHover = false
    @State private var logoutPrimaryHover = false
    @State private var loginHover = false
    @State private var loginBreathing = false
    @State private var recheckHover = false
    @State private var logoutHover = false

    var body: some View {
        ZStack {
            Backdrop()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 15) {
                    titleCard
                    UploadCard(slot: .exam,
                               title: "上传考卷",
                               subtitle: "支持 .doc / .docx，含题目与原文")
                    UploadCard(slot: .answer,
                               title: "上传答案",
                               subtitle: "支持 .doc / .docx，含参考答案 / 解析 / 范文")
                    loginLine
                    generateButton
                    ProgressCard()
                    WordCard()
                }
                .padding(.horizontal, 22)
                .padding(.top, 18)
                .padding(.bottom, 22)
            }
        }
        .frame(width: 620, height: 720)
        .background(WindowCloseAccessor())
        .onAppear {
            state.startPolling()
            // 兜底：界面出现时也直接给已存在的窗口挂上关闭代理，
            // 防止 background 的 NSView 在窗口挂接时序上没赶上。
            DispatchQueue.main.async {
                for window in NSApplication.shared.windows {
                    // 内置网页窗口跳过：它有自己的大叉逻辑（只隐藏），
                    // 要是也挂上退出确认代理，点它的大叉就会弹主界面退出框。
                    if window is ParkableWindow { continue }
                    window.delegate = ExitConfirmWindowDelegate.shared
                }
            }
            // 开发用：--uidemo / --uidemo2 只改界面状态，方便截图检查视觉
            if CommandLine.arguments.contains("--uidemo") {
                state.applyUIDemo(step: 1)
            } else if CommandLine.arguments.contains("--uidemo2") {
                state.applyUIDemo(step: 2)
            } else if CommandLine.arguments.contains("--uidemo3") {
                state.applyUIDemo(step: 3)
            } else if CommandLine.arguments.contains("--uidemo4") {
                state.applyUIDemo(step: 4)
            } else if CommandLine.arguments.contains("--uidemo5") {
                state.applyUIDemo(step: 5)
            } else if CommandLine.arguments.contains("--uidemo6") {
                state.applyUIDemo(step: 6)
            } else if CommandLine.arguments.contains("--logintest") {
                state.runLoginSelfTest()
            } else if CommandLine.arguments.contains("--modeprobe") {
                state.runModeProbe()
            } else if CommandLine.arguments.contains("--logdemo") {
                // 演示「跑完一轮 + 日志面板打开」，只为截图看版式
                state.applyLogDemo(openPanel: true)
            } else if CommandLine.arguments.contains("--logdemo-closed") {
                // 同上，但面板关着，用来看 Word 卡自己的样子
                state.applyLogDemo(openPanel: false)
            } else if CommandLine.arguments.contains("--faildemo") {
                // 失败态：验证「失败只改一行字、按钮不换」
                state.applyLogDemo(openPanel: false, failed: true)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .lectureAppConfirmExit)) { _ in
            showExitConfirm = true
        }
        .overlay(alignment: .top) {
            // 运行日志：只压暗上半屏，底部 Word 卡（含「详情」按钮）留出来。
            // 面板绝不能盖住自己的开关 —— 盖住了用户就没法再点一次收起来。
            if state.showLog {
                LogPanel(onClose: { state.closeLog() })
                    .transition(.opacity.combined(with: .scale(scale: 0.985, anchor: .top)))
            }
        }
        .overlay {
            if showExitConfirm {
                exitConfirmOverlay
            }
        }
        .overlay {
            if showLogoutConfirm {
                logoutConfirmOverlay
            }
        }
    }

    // MARK: 退出确认弹窗（窗口绝对中心）

    /// overlay 铺满整个 620×720 窗口，卡片在 ZStack 正中，
    /// 不是贴在某个角落，也不是系统 sheet。
    private var exitConfirmOverlay: some View {
        ZStack {
            Color.black.opacity(0.35)
            VStack(spacing: 14) {
                Text("确认退出吗？")
                    .font(.system(size: 16, weight: .semibold))
                Text("退出后 App 将完全关闭。")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                HStack(spacing: 13) {
                    // 方案 1：主按钮保持系统玻璃 prominent，只在上面叠一层黑 0.06 hover 变深，
                    // 和取消按钮的系统 hover 逻辑统一（hover 变深、按下不弹起变浅是系统
                    // 自带的按下状态，这里只改 hover，不动按下）。不叠放大、不提亮、
                    // 不加手型光标。主窗口失焦时带颜色按钮变灰是系统行为，用户表示不介意，
                    // 不用自定义样式去绕它。
                    Button {
                        NSApplication.shared.terminate(nil)
                    } label: {
                        Text("退出")
                            .font(.system(size: 13.5, weight: .semibold))
                            .padding(.horizontal, 20)
                            .padding(.vertical, 6)
                    }
                    .dialogGlassProminentButtonStyle()
                    .tint(Color.brandRed)
                    .foregroundStyle(.white)
                    // 叠层本身不接点击：不加这一句，叠层盖在系统玻璃按钮上面，
                    // 即使填充透明也会挡住鼠标，退出按钮点不下去（2026-10-26 用户报）。
                    // 加在叠层内容上，不是加在整个按钮上，否则按钮自己也被禁点了。
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.black.opacity(exitPrimaryHover ? 0.06 : 0))
                        .allowsHitTesting(false))
                    .onHover { exitPrimaryHover = $0 }
                    .animation(.easeOut(duration: 0.15), value: exitPrimaryHover)
                    .keyboardShortcut(.defaultAction)
                    Button {
                        showExitConfirm = false
                    } label: {
                        Text("取消")
                            .font(.system(size: 13.5, weight: .medium))
                            .padding(.horizontal, 20)
                            .padding(.vertical, 6)
                    }
                    .dialogGlassButtonStyle()
                    .keyboardShortcut(.cancelAction)
                }
                .padding(.top, 4)
            }
            .padding(24)
            .trialGlassCard(cornerRadius: 16, shadowOpacity: 0.18, shadowRadius: 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 退出 DeepSeek 确认弹窗（和退出 App 确认框同一个做法）

    /// 以前是 NSAlert 系统弹窗，位置是屏幕居中，不是主界面绝对居中，
    /// 框和按钮也不是玻璃。现在改成和退出确认框一样的 overlay：
    /// 铺满整个 620×720 主界面，卡片在正中；整框玻璃，按钮也是系统玻璃，
    /// 按钮 hover 就靠系统玻璃本身，不再叠自定义放大、提亮、brightness。
    /// 文案原样保留 NSAlert 那两句，按钮位置和快捷键也和退出确认框一样：
    /// 主操作在左、取消在右，回车主操作、Esc 取消。
    private var logoutConfirmOverlay: some View {
        ZStack {
            Color.black.opacity(0.35)
            VStack(spacing: 14) {
                Text("登出 DeepSeek 账号？")
                    .font(.system(size: 16, weight: .semibold))
                Text("会清掉本机保存的登录信息，然后重新打开登录页。之后需要重新扫码或输入账号密码登录。")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                // 按钮上下排、等宽对齐，中间留 10 空隙，和原来 NSAlert 的排布相似；
                // 主操作不再用红，用蓝，退出 App 那个确认框的红按钮不动。
                VStack(spacing: 10) {
                    Button {
                        showLogoutConfirm = false
                        state.logoutDeepSeek()
                    } label: {
                        Text("登出并重新登录")
                            .font(.system(size: 13.5, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .dialogGlassProminentButtonStyle()
                    .tint(Color.brandBlue)
                    .foregroundStyle(.white)
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.black.opacity(logoutPrimaryHover ? 0.06 : 0))
                        .allowsHitTesting(false))
                    .onHover { logoutPrimaryHover = $0 }
                    .animation(.easeOut(duration: 0.15), value: logoutPrimaryHover)
                    .keyboardShortcut(.defaultAction)
                    .disabled(state.isRunning)
                    Button {
                        showLogoutConfirm = false
                    } label: {
                        Text("取消")
                            .font(.system(size: 13.5, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .dialogGlassButtonStyle()
                    .keyboardShortcut(.cancelAction)
                }
                .padding(.top, 4)
            }
            .padding(24)
            // 卡片定宽 360：小字一行约 24 个字，整段正好两行，不再被长句撑到满屏宽。
            .frame(width: 360)
            .trialGlassCard(cornerRadius: 16, shadowOpacity: 0.18, shadowRadius: 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 标题

    /// 标题直接裸在背景上，不套圆角矩形 —— 之前那圈描边跟下面的卡片抢视觉重点。
    private var titleCard: some View {
        VStack(spacing: 9) {
            Text("高三英语「备课讲义」生成器")
                .font(.system(size: 21, weight: .bold))
                .foregroundStyle(
                    LinearGradient(colors: [.brandBlue, .brandPurple],
                                   startPoint: .leading, endPoint: .trailing)
                )

            Text("上传考卷与答案两份 Word 文档，自动合成红答案 / 紫干扰 / 绿解析的备课讲义。生成约需 1–3 分钟。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: 登录

    private var loginLine: some View {
        // 两行合并为一行：启动时只有登录状态，检测出已登录后第二行再出现，
        // 原来会让窗口高度突然变大、看着突兀。现在整行高度固定为 30，
        // 第二行内容只在同一行里横向出现，窗口高度从启动到登录完成都不变。
        HStack(spacing: 8) {
            if state.loginSettled {
                Circle()
                    .fill(state.login.dotColor)
                    .frame(width: 8, height: 8)
                Text(state.login.label)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                // 还没问出来之前只说"在检测"，不吓唬用户说没登录
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 12, height: 12)
                Text("正在检测登录状态…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if let mode = state.modeStatusText {
                Text("·")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                HStack(spacing: 5) {
                    Image(systemName: state.modesChecking ? "arrow.triangle.2.circlepath" :
                          (state.modesReady ? "checkmark.circle.fill" : "exclamationmark.circle"))
                        .font(.system(size: 11))
                        .foregroundStyle(state.modesReady ? Color.green : Color.secondary)
                    Text(mode)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    // “重新检查”只在绿灯亮起 5 秒后仍未激活时出现，
                    // 5 秒内即使检测失败也不出现，见 AppState.modesRetryAllowed。
                    if !state.modesReady && !state.modesChecking && state.modesRetryAllowed {
                        Button {
                            state.retryDeepSeekModes()
                        } label: {
                            Text("重新检查")
                                .underline(recheckHover)
                        }
                        .font(.system(size: 11, weight: .medium))
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.brandBlue)
                        .handCursor()
                        .onHover { recheckHover = $0 }
                        .animation(.easeOut(duration: 0.15), value: recheckHover)
                    }
                }
            }

            Spacer(minLength: 6)

            // 未登录时，在登录按钮左边显示提示 + 纯文字箭头指向按钮。
            // 箭头就是文字“→”，不是带边框的图标，蓝、粗、明显；
            // 已登录、还在检测时都不显示，只有登录按钮出现时才出现。
            if state.loginSettled && !state.login.isLoggedIn {
                HStack(spacing: 4) {
                    Text("请登录后使用本软件")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.brandRed)
                        .lineLimit(1)
                    Text("→")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color.brandBlue)
                }
            }

            // 登录行永远不显示倒计时：登录成功后 5 秒收窗口的倒计时，
            // 只在内置网页的徽标里显示（AppState.pushBadge），主界面这里不显示。
            // 未登录就直接显示登录按钮；退出后按钮要等探针确认已退出才出现，
            // 见 AppState.logoutDeepSeek / refreshLogin 的等待确认逻辑。
            if state.loginSettled && !state.login.isLoggedIn {
                Button { state.openDeepSeek() } label: {
                    Text("登录 DeepSeek")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .trialGlassCapsule(fallbackFill: Color.brandBlue.opacity(0.13))
                        .overlay(Capsule().fill(Color.brandBlue.opacity(loginHover ? 0.10 : 0)))
                        .foregroundStyle(Color.brandBlue)
                }
                .buttonStyle(.plain)
                .handCursor()
                .onHover { loginHover = $0 }
                .animation(.easeOut(duration: 0.15), value: loginHover)
                // 呼吸灯：外部光晕减弱，蓝光阴影在 0.10～0.28 透明度、4～8 半径之间 1.6 秒来回，
                // 内部玻璃和悬停效果、时长都不变；登录后按钮消失，呼吸也停。
                .shadow(color: Color.brandBlue.opacity(loginBreathing ? 0.28 : 0.10),
                        radius: loginBreathing ? 8 : 4)
                .onAppear {
                    withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                        loginBreathing = true
                    }
                }
                .onDisappear { loginBreathing = false }
                .help("只在登录时会弹出窗口，登录成功后自动收起")
            }

            // 双绿灯（已登录 + 模式已激活）之后 0.5 秒出现：登出 DeepSeek。
            // 它接的是原来右下角「⋯」菜单里的「退出账号」，那个菜单连同底部状态行
            // 一起删掉了（用户 2026-10-27 要求），所以这是现在唯一的登出入口。
            // 点它只弹确认框，真正清登录态在确认之后。
            if state.logoutReady {
                Button { showLogoutConfirm = true } label: {
                    Text("登出 DeepSeek")
                        // 不加粗：用户 2026-10-27 明确要求
                        .font(.system(size: 12))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .trialGlassCapsule(fallbackFill: Color.brandBlue.opacity(0.13))
                        .overlay(Capsule().fill(Color.brandBlue.opacity(logoutHover ? 0.10 : 0)))
                        .foregroundStyle(Color.brandBlue)
                }
                .buttonStyle(.plain)
                .handCursor()
                .onHover { logoutHover = $0 }
                .animation(.easeOut(duration: 0.15), value: logoutHover)
                // 生成中禁点：登出会清掉整个网页数据，正在跑的这一轮直接废掉
                .disabled(state.isRunning)
                .help("登出 DeepSeek 账号，会清掉本机保存的登录信息")
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 4)
        .frame(height: 30)
        // 「登出 DeepSeek」按钮出现 / 消失用 0.5 秒淡入淡出。
        // 只绑 logoutReady，别给它挂别的动画。
        .animation(.easeOut(duration: 0.5), value: state.logoutReady)
    }

    // MARK: 主按钮

    private var generateButton: some View {
        Button {
            if state.isRunning { state.requestStop() } else { state.generate() }
        } label: {
            HStack(spacing: 7) {
                if state.isRunning {
                    Image(systemName: "stop.fill").font(.system(size: 11))
                }
                Text(state.isRunning ? "中止" : "生成备课讲义")
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(state.canGenerate || state.isRunning
                             ? Color.white
                             : Color(nsColor: .secondaryLabelColor))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .trialGlassTinted(cornerRadius: 14,
                              tint: state.isRunning ? Color.brandRed : (state.canGenerate ? Color.brandBlue : Color.secondary),
                              fallback: buttonStyle,
                              shadowColor: shadowColor, shadowRadius: 16, shadowY: 7)
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(generateHover ? 0.06 : 0)))
        }
        .buttonStyle(.plain)
        .handCursor()
        .onHover { generateHover = $0 }
        .animation(.easeOut(duration: 0.15), value: generateHover)
        .disabled(!state.isRunning && !state.canGenerate)
    }

    private var shadowColor: Color {
        if state.isRunning { return Color.brandRed.opacity(0.34) }
        if state.canGenerate { return Color.brandBlue.opacity(0.32) }
        return .clear
    }

    private var buttonStyle: AnyShapeStyle {
        if state.isRunning {
            // 中止：珊瑚红 → 洋红，两个色差拉开一点，一眼看出是渐变
            return AnyShapeStyle(LinearGradient(
                colors: [Color(red: 0.98, green: 0.40, blue: 0.36),
                         Color(red: 0.86, green: 0.18, blue: 0.56)],
                startPoint: .leading, endPoint: .trailing))
        }
        if state.canGenerate {
            return AnyShapeStyle(LinearGradient(
                colors: [.brandBlue, .brandPurple],
                startPoint: .leading, endPoint: .trailing))
        }
        return AnyShapeStyle(Color.secondary.opacity(0.16))
    }

    // 页脚整条删了（用户 2026-10-27 要求）。
    //
    // 原来左边是「绿点 + 运行环境已就绪」，右边是「⋯」菜单（里面只有一项「退出 DeepSeek 账号…」）。
    // 删的理由：绿灯从来没红过 —— 运行环境是打进 App 包里的，缺了根本打不开，
    // 这条告警一次都没起过作用；「⋯」菜单则是因为登出改成了标题行里那个独立按钮。
    // 所以连带 `pythonReady` 在界面上也没有引用了（属性还在 AppState 里，留着不碍事）。
    // 别把绿灯加回来。
}

// MARK: - 背景

struct Backdrop: View {
    var body: some View {
        // 用户 2026-10-26 反馈：主背景不要玻璃，背景复杂就看不清。
        // 主背景恢复原来的实色 + 蓝紫晕，玻璃只留给按钮和圆角框。
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            RadialGradient(colors: [Color.brandBlue.opacity(0.16), .clear],
                           center: .topLeading, startRadius: 20, endRadius: 620)
            RadialGradient(colors: [Color.brandPurple.opacity(0.14), .clear],
                           center: .bottomTrailing, startRadius: 20, endRadius: 620)
        }
        .ignoresSafeArea()
    }
}

// MARK: - 上传卡片

/// 整块可点：点框里任何地方都会打开选文件面板。
/// 选中后右上角浮一个圆形叉，点它移除（它在 ZStack 上层，所以不会被下面的大按钮吃掉）。
struct UploadCard: View {
    @EnvironmentObject var state: AppState
    let slot: AppState.Slot
    let title: String
    let subtitle: String

    /// 叉按钮悬停时整体向右上挪 1pt，阴影同步放大，看着像"浮起来"了一下
    @State private var isCloseHover = false
    /// 整张上传卡的 hover：只在卡片上叠一层浅蓝提亮，不动玻璃本身，不放大不提亮，
    /// 避免退出/取消按钮那次的闪黑闪白；生成进行中卡片被禁用时不响应 hover。
    @State private var cardHover = false
    /// 有文件正被拖到这张卡上方（用户 2026-10-29 第 11 轮加拖放）
    @State private var dropTargeted = false

    private var url: URL? {
        slot == .exam ? state.examURL : state.answerURL
    }

    private var active: Bool { url != nil }

    private var fileSize: Int {
        guard let url = url else { return 0 }
        return ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0) / 1024
    }

    /// 用 `mutating get` 绕开 struct 里 closure 写 self 的限制
    private mutating func setCloseHover(_ value: Bool) { isCloseHover = value }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button {
                state.chooseFile(for: slot)
            } label: {
                content
            }
            .buttonStyle(.plain)
            .handCursor()
            .disabled(state.isRunning)

            if active {
                Button {
                    state.clearFile(for: slot)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.brandPink))
                        .shadow(color: Color.brandPink.opacity(isCloseHover ? 0.4 : 0.3),
                                radius: isCloseHover ? 4 : 3,
                                y: isCloseHover ? 2 : 1)
                        .offset(x: isCloseHover ? 1 : 0, y: isCloseHover ? -1 : 0)
                        .animation(.easeOut(duration: 0.12), value: isCloseHover)
                }
                .buttonStyle(.plain)
                .padding(11)
                .handCursor()
                .onHover { [self] inside in
                    var copy = self
                    copy.setCloseHover(inside)
                }
                .help("移除这个文件")
                .transition(.scale.combined(with: .opacity))
            }
        }
        // 拖放（用户 2026-10-29 第 11 轮）：一个框只放一个文件，只取第一个。
        // 和点框选文件走**同一个** `accept` —— 白名单、跨框查重都在那里。
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard !state.isRunning, !providers.isEmpty else { return false }
            AppState.resolveFileURLs(from: providers) { urls in
                state.acceptDropped(urls, for: slot)
            }
            return true
        }
        .onHover { cardHover = $0 && !state.isRunning }
        .animation(.easeOut(duration: 0.15), value: cardHover)
        .animation(.easeOut(duration: 0.15), value: dropTargeted)
        .animation(.easeOut(duration: 0.18), value: active)
        // 提示落在**本框的下沿**（用户 2026-10-29：注意冒泡位置）：
        // 只有 toastSlot 是自己的框才显示，两个框不会同时弹；
        // 贴底部是为了不盖住标题和文件名 —— 卡片只有 ~95pt 高，居中会把标题压掉。
        .overlay(alignment: .bottom) {
            if state.toastSlot == slot, let text = state.toast {
                ToastBar(text: text) { state.dismissToast() }
                    .padding(.bottom, 6)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
    }

    private var content: some View {
        VStack(spacing: 6) {
            HStack(spacing: 9) {
                Image(systemName: active ? "doc.fill" : "doc.badge.plus")
                    .font(.system(size: 19))
                    .foregroundStyle(active ? Color.brandBlue : Color.secondary)
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
            }

            if let url = url {
                Text(url.lastPathComponent)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 26)
                Text("\(fileSize) KB · 点框更换，或拖入新文件")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text("＊必选，点框选择，或把文件拖进来")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.brandPink)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 19)
        .padding(.horizontal, 16)
        .contentShape(Rectangle())
        .trialGlassCard(cornerRadius: 16, shadowOpacity: active ? 0.09 : 0.03, shadowRadius: active ? 14 : 6)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.brandBlue.opacity(dropTargeted ? 0.07 : (cardHover ? 0.04 : 0)))
        )
        .overlay(
            // 有文件时靠上面那条旋转渐变边，没有时靠这条实线；
            // 拖着文件悬停时这条线变成加粗的蓝色 —— 和「等待放置」的观感对上。
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(dropTargeted ? Color.brandBlue.opacity(0.75)
                                           : Color.secondary.opacity(active ? 0 : 0.30),
                              lineWidth: dropTargeted ? 1.6 : 1.2)
        )
        .overlay(
            RotatingGradientBorder(radius: 16, active: active)
                .opacity(active ? 1 : 0)
        )
    }
}

// MARK: - 框里的一句话提示

/// 被拒时冒个泡（用户 2026-10-29 第 11 轮）。
/// 位置由调用方决定：`UploadCard` 把它贴在自己下沿，所以提示一定落在**被操作的那个框**上，
/// 不会跑到窗口顶部、也不会串到另一个框。
/// 点一下能提前收掉；没人管的话 2.7 秒自己消失（定时器在 `AppState.showToast`）。
struct ToastBar: View {
    let text: String
    let onTap: () -> Void

    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.brandRed.opacity(0.93))
            )
            .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
            .padding(.horizontal, 14)
            .onTapGesture { onTap() }
    }
}

// MARK: - 进度卡片

struct ProgressCard: View {
    @EnvironmentObject var state: AppState

    /// 空闲（没在跑、也没出结果/出错）时，状态框讲的是「还差哪一步」，
    /// 而不是最后一次操作。跑起来、成功、出错时才切到流程进度。
    private var showingIdle: Bool {
        !state.isRunning && state.progress.tone == .idle
    }

    private var title: String {
        showingIdle ? state.idleStatus.title : state.progress.title
    }

    private var detail: String {
        showingIdle ? state.idleStatus.detail : state.progress.detail
    }

    private var fraction: Double {
        showingIdle ? state.idleStatus.fraction : state.progress.fraction
    }

    private var spinning: Bool {
        showingIdle ? false : state.progress.running
    }

    private var isError: Bool {
        !showingIdle && state.progress.tone == .error
    }

    private var toneColor: Color {
        if showingIdle {
            return fraction >= 1 ? .green : Color.brandBlue.opacity(0.75)
        }
        switch state.progress.tone {
        case .ok: return .green
        case .error: return .brandRed
        case .idle: return state.progress.running ? Color.brandBlue : Color.secondary.opacity(0.5)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(toneColor).frame(width: 8, height: 8)
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isError ? Color.brandRed : Color.primary)
                Spacer(minLength: 6)
                if spinning {
                    Text("进行中")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            if !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            ProgressBar(fraction: fraction, running: spinning)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .trialGlassCard(cornerRadius: 16, shadowOpacity: 0.05, shadowRadius: 10)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.14), lineWidth: 1)
        )
        .overlay(
            RotatingGradientBorder(radius: 16, active: spinning)
                .opacity(spinning ? 1 : 0)
        )
        .animation(.easeInOut(duration: 0.3), value: fraction)
    }
}

struct ProgressBar: View {
    var fraction: Double
    var running: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.14))
                if fraction > 0.001 {
                    Capsule()
                        .fill(LinearGradient(colors: [.brandBlue, .brandPurple],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(6, geo.size.width * min(1, fraction)))
                        .animation(.easeInOut(duration: 0.45), value: fraction)
                } else if running {
                    // 进度未知时跑一条来回扫的光带
                    TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { ctx in
                        let t = ctx.date.timeIntervalSinceReferenceDate
                        let phase = t.truncatingRemainder(dividingBy: 1.5) / 1.5
                        let w = geo.size.width * 0.34
                        let x = -w + (geo.size.width + w) * phase
                        Capsule()
                            .fill(LinearGradient(
                                colors: [.clear, Color.brandBlue.opacity(0.9),
                                         Color.brandPurple.opacity(0.9), .clear],
                                startPoint: .leading, endPoint: .trailing))
                            .frame(width: w)
                            .offset(x: x)
                    }
                }
            }
        }
        .frame(height: 6)
        .clipShape(Capsule())
    }
}

// MARK: - Word 讲义卡片

/// 一直占着位置，只是没生成时是「未激活」的样子 —— 用户知道成品会出现在这里。
struct WordCard: View {
    @EnvironmentObject var state: AppState

    /// 卡片和里面按钮的 hover，做法和上传卡、生成按钮一样：
    /// 只在玻璃上叠一层浅色提亮，不动玻璃、不放大、不提亮。
    @State private var cardHover = false
    @State private var downloadHover = false
    @State private var logHover = false

    private var active: Bool { state.docx.isReady }

    private var message: String {
        switch state.docx {
        case .idle:
            return "讲义还没有开始生成，等上面的进度走完再回到这里。"
        case .building:
            return "正在生成，稍等一下…"
        case .ready(let url):
            let kb = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0) / 1024
            return "已经生成好了（\(kb) KB），点下面的按钮保存到电脑里。"
        case .failed(let why):
            // 失败只改这一行字，卡片其他部分一点不变（用户 2026-10-27：
            // 不要换按钮、不要弹面板、不要导 md/截图，日志一律看「详情」）。
            return "这次没成功：\(why)。点右上角「详情」可以看到这次运行的完整日志。"
        }
    }

    private var buttonTitle: String {
        switch state.docx {
        case .idle: return "下载 Word 讲义（尚未生成）"
        case .building: return "正在生成…"
        case .ready: return "下载 Word 讲义"
        case .failed: return "下载 Word 讲义（未生成）"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                Image(systemName: "doc.richtext")
                    .font(.system(size: 15))
                    .foregroundStyle(active ? Color.brandBlue : Color.secondary)
                Text("Word 讲义")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                if active {
                    // 纯绿字，不加药丸底（用户 2026-10-27：带边框看着像个能点的按钮）
                    Text("可下载")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.green)
                }
                // 运行日志入口。跑过一次之后才出现（没跑过没什么可看的）。
                // 放在标题行而不是按钮行：不挤「下载」的宽度，也不改变卡片高度。
                if !state.progressLines.isEmpty {
                    Button { state.toggleLog() } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "text.alignleft")
                                .font(.system(size: 9, weight: .semibold))
                            Text(state.showLog ? "收起" : "详情")
                                .font(.system(size: 11))
                        }
                        .foregroundStyle(Color.brandBlue)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .trialGlassCapsule(fallbackFill: Color.brandBlue.opacity(logHover ? 0.16 : 0.09))
                        .overlay(Capsule().fill(Color.brandBlue.opacity(logHover ? 0.10 : 0)))
                    }
                    .buttonStyle(.plain)
                    .handCursor()
                    .onHover { logHover = $0 }
                    .animation(.easeOut(duration: 0.15), value: logHover)
                    .help("看这次运行的详细日志")
                }
            }

            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(state.docx.isReady ? Color.secondary : Color.secondary.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 10) {
                // 成功失败都是这一个按钮（用户 2026-10-27：失败时不要换按钮、
                // 不要弹面板、不要导 md/截图）。没生成好就是禁用态，日志去「详情」看。
                Button {
                    state.downloadDocx()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: active ? "arrow.down.circle.fill" : "arrow.down.circle")
                            .font(.system(size: 12))
                        Text(buttonTitle)
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(active ? Color.white : Color(nsColor: .secondaryLabelColor))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .trialGlassTinted(cornerRadius: 10,
                                      tint: active ? Color.brandBlue : Color.secondary,
                                      fallback: active
                                        ? AnyShapeStyle(LinearGradient(colors: [.brandBlue, .brandPurple],
                                                                       startPoint: .leading, endPoint: .trailing))
                                        : AnyShapeStyle(Color.secondary.opacity(0.14)),
                                      shadowColor: .clear, shadowRadius: 0, shadowY: 0)
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(downloadHover ? 0.06 : 0)))
                }
                .buttonStyle(.plain)
                .handCursor()
                .onHover { downloadHover = $0 }
                .animation(.easeOut(duration: 0.15), value: downloadHover)
                .disabled(!active)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .trialGlassCard(cornerRadius: 16, shadowOpacity: active ? 0.08 : 0.02, shadowRadius: active ? 12 : 5)
        // 卡片 hover 叠层盖在整个卡片上面，包括里面的下载按钮和标题行「详情」按钮。
        // 不加 allowsHitTesting(false)，即使填充透明也会挡住鼠标，和 2026-10-26 退出按钮
        // 那个 bug 同一个根源（见 AGENTS.md 按钮教训）。加在叠层内容上，不是整个卡片上，
        // 否则卡片里的按钮全被禁点；hover 还是靠卡片自己的 onHover，不受影响。
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.brandBlue.opacity(cardHover ? 0.04 : 0))
                .allowsHitTesting(false)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.secondary.opacity(active ? 0 : 0.28), lineWidth: 1.2)
        )
        .overlay(
            RotatingGradientBorder(radius: 16, active: active)
                .opacity(active ? 1 : 0)
        )
        .onHover { cardHover = $0 && active }
        .animation(.easeOut(duration: 0.15), value: cardHover)
        .animation(.easeOut(duration: 0.2), value: active)
    }
}

// MARK: - 运行日志面板

/// 「详情」按钮打开的那块。成功跑完也能看 —— 以前日志只在失败诊断的 md 里出现，
/// 成功一次就什么都看不到，想确认「提示词回读一致」也没地方确认。
///
/// 两个约束（用户 2026-10-27 定）：
/// 1. **不许盖住自己的开关**。所以压暗层只铺上半屏（`scrimHeight`），底部给 Word 卡
///    留出一条不遮不挡的带子，「详情」按钮永远点得到。
/// 2. 显示/隐藏跟预览卡片一个节奏：`withAnimation(.easeOut(0.18))` + opacity 过渡。
///    窗口本来就是固定 620×720，所以这里直接写死尺寸，不追求自适应。
struct LogPanel: View {
    @EnvironmentObject var state: AppState
    let onClose: () -> Void

    private var lines: [String] { state.progressLines }
    private var scriptOutput: String { state.scriptOutput }

    /// 压暗层高度 = 520。面板本身到 20+500=520 为止，Word 卡顶边在 538 左右，
    /// 中间留 18pt 空隙 —— 少留一点压暗层就会压到 Word 卡上，那一小条会被当成「点面板外面」。
    private let scrimHeight: CGFloat = 520

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.14)
                .frame(maxWidth: .infinity)
                .frame(height: scrimHeight)
                .contentShape(Rectangle())
                .onTapGesture { onClose() }

            card.padding(.top, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var card: some View {
        VStack(spacing: 0) {
            header
            Divider()
            logList
        }
        .frame(width: 566, height: 500)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color(nsColor: .windowBackgroundColor)))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Color.secondary.opacity(0.22), lineWidth: 1))
        .shadow(color: .black.opacity(0.22), radius: 24, y: 10)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.alignleft")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.brandBlue)
            Text("运行日志")
                .font(.system(size: 13, weight: .semibold))
            Text("\(lines.count) 行")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer()
            // 叉按钮统一白底黑字（用户 2026-10-27 定的规矩，系统级的除外）
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.black.opacity(0.72))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.white))
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.14), lineWidth: 0.8))
                    .shadow(color: .black.opacity(0.20), radius: 3, y: 1)
            }
            .buttonStyle(.plain)
            .handCursor()
            .help("关闭（Esc）")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var logList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if lines.isEmpty && scriptOutput.isEmpty {
                        Text("这次还没有日志。跑一次生成就会有了。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(tint(for: line))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                    if !scriptOutput.isEmpty {
                        Divider().padding(.vertical, 6)
                        Text("—— 脚本输出 ——")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(scriptOutput)
                            .font(.system(size: 10.5, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // 滚到底用的锚点
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(12)
            }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            // 跟着日志增长自动滚到底。用 onReceive 而不是 onChange：
            // onChange 的单参数写法在 macOS 14 已废弃，而本工程部署目标是 13.0。
            .onReceive(state.$progressLines) { _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.55))
    }

    /// 出错的标红，警告标黄，其余保持正文色 —— 扫一眼就知道哪行有问题
    private func tint(for line: String) -> Color {
        if line.hasPrefix("✗") { return Color.brandRed }
        if line.contains("⚠️") || line.contains("还没出现") { return Color.orange }
        return Color.primary.opacity(0.85)
    }
}
