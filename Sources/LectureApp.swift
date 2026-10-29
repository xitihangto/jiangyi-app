import SwiftUI
import AppKit
import Quartz          // QLPreviewView：点文件卡直接预览 docx 内容

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
                // 系统的分割线在这套「隐藏标题 + 透明标题栏」的窗口上压不住（只 hover 才出现），
                // 所以界面里自己画了一条常驻的（见 ContentView 的 .overlay(alignment: .top)）。
                // 这里把系统的关掉，免得上下一共两条线。做法照抄试卷识别版。
                window.titlebarSeparatorStyle = .none
            }
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                window.delegate = ExitConfirmWindowDelegate.shared
                window.titleVisibility = .hidden
                window.titlebarSeparatorStyle = .none
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
    /// ⌘V 监听 + 「点框外退出等待粘贴」两个本地监听器（用户 2026-10-29 第 17 轮加粘贴）
    @State private var pasteMonitor: Any?
    @State private var clickMonitor: Any?

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
        // 标题栏（红绿灯那条）下面的分割线 —— **自己画一条，常驻**（照抄试卷识别版）。
        //
        // 为什么不用系统的 `titlebarSeparatorStyle = .line`：那个属性在本窗口上不生效。
        // 窗口为了只留红绿灯，把 `titleVisibility` 设成了 `.hidden`，
        // 这种「标题栏透明、内容顶到窗口顶部」的形态下，系统只在滚动/鼠标悬停时才画那条线
        // （`.automatic` 的表现），`.line` 也压不住。与其跟系统猜，不如自己画一条 1px 的，
        // 位置正好在内容区最顶端 = 标题栏底边，颜色用系统的 `.separatorColor`，明暗自适应。
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 1)
                .allowsHitTesting(false)
        }
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
        .onAppear { installPasteMonitor() }
        .onDisappear {
            if let monitor = pasteMonitor { NSEvent.removeMonitor(monitor) }
            pasteMonitor = nil
            if let monitor = clickMonitor { NSEvent.removeMonitor(monitor) }
            clickMonitor = nil
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
            // 文件预览：放在两个确认框**之前**（overlay 后加的在上层，所以这样确认框会盖住它）
            if let url = state.previewURL {
                FilePreviewPanel(url: url) { state.closePreview() }
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

    // MARK: 粘贴监听（⌘V + 点框外取消）

    /// ⌘V 监听 + 「点框外退出等待粘贴」。
    ///
    /// 粘贴：只有某个上传框处于「等待粘贴」状态时才接管，其余情况原样放行 ——
    /// 不能把别处的正常粘贴吃掉。Esc 顺手退出等待粘贴态（不吞事件，免得影响别的弹窗取消）。
    ///
    /// 取消：**框内再点不取消，只有点框外（必须在 app 范围内）才取消**。
    /// 这里不判断坐标 —— 判断坐标要处理 SwiftUI global 空间和 NSEvent 窗口空间的 y 轴翻转，
    /// 平台行为一变就会「点框内反而取消」。改成**票据制**：框内任何点击都会留一张票
    /// （`state.insideClickTicket`），mouseUp 之后异步看一眼 —— 有票作废票据、没票才取消。
    /// 用 local monitor 而不是 SwiftUI 手势：只有发给本 App 的事件才进来，
    /// 「点别的 app 不取消」这条天然满足。
    private func installPasteMonitor() {
        guard pasteMonitor == nil else { return }
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Esc：先关日志，再关预览，最后退等待粘贴（都不吞事件，免得影响别的弹窗取消）
            if event.keyCode == 53 {
                if state.showLog {
                    state.closeLog()
                } else if state.previewURL != nil {
                    state.closePreview()
                } else if state.pasteArmed != nil {
                    state.pasteArmed = nil
                    state.closePasteMenu()
                }
                return event
            }
            guard let slot = state.pasteArmed,
                  event.modifierFlags.contains(.command),
                  event.charactersIgnoringModifiers?.lowercased() == "v"
            else { return event }
            state.pasteFromClipboard(into: slot)
            return nil
        }

        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp]) { event in
            guard state.pasteArmed != nil else { return event }
            // 顺序很关键：local monitor 在事件派发给视图**之前**跑，框自己的 onTapGesture 在**之后**跑。
            // 所以不能在派发前就判（那时票还没发），要推到下一轮 runloop —— 那时框内点击已经留过票了。
            DispatchQueue.main.async {
                if state.insideClickTicket {
                    state.insideClickTicket = false     // 这一下点在框内，留着
                } else if state.pasteArmed != nil {
                    state.pasteArmed = nil              // 点在框外，取消
                    state.closePasteMenu()              // 右键小菜单跟着一起收
                }
            }
            return event
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

/// 一个框只放一个文件，所以不用文章版那套「三等分占位」：
/// 有文件时直接给一张**铺满加号右侧全部宽度**的文件卡（用户 2026-10-29 第 17 轮：「预览卡可以大到边框」）。
///
/// 排版和交互都照文章批改 app（用户同日贴截图要求「参照它的位置」）：
///   第 1 行  标题 + ＊必选（激活时中间冒出蓝色提示）
///   第 2 行  副标题：支持哪些格式
///   第 3 行  [加号] + 右侧内容（空框是居中提示，有文件是铺满的文件卡）
/// - 点框内 → 进入「等待粘贴」态（蓝边 + 浅蓝底 + 标题行中间冒出蓝色提示）
/// - 左下角加号 → 开文件面板；⌘V → 粘贴；右键 → 「粘贴 / 取消」小菜单
/// - 点框外 / Esc → 取消激活
struct UploadCard: View {
    @EnvironmentObject var state: AppState
    let slot: AppState.Slot
    let title: String
    let subtitle: String

    /// 叉按钮悬停时整体向右上挪 1pt，阴影同步放大，看着像"浮起来"了一下
    @State private var isCloseHover = false
    /// 加号 hover：只改底色和描边，不动布局
    @State private var plusHover = false
    /// 整张上传卡的 hover：只在卡片上叠一层浅蓝提亮，不动玻璃本身
    @State private var cardHover = false
    /// 文件卡 hover：提示「这张卡能点开预览」
    @State private var fileHover = false
    /// 有文件正被拖到这张卡上方（用户 2026-10-29 第 11 轮加拖放）
    @State private var dropTargeted = false

    private var url: URL? {
        slot == .exam ? state.examURL : state.answerURL
    }

    private var active: Bool { url != nil }
    private var armed: Bool { state.pasteArmed == slot }

    private var fileSize: Int {
        guard let url = url else { return 0 }
        return ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0) / 1024
    }

    var body: some View {
        // 排版照文章批改 app（用户 2026-10-29 贴截图要求「参照它的位置」），
        // 但压成**两行**（同日第二次要求：三行太占地方）：
        //   第 1 行  标题 + ＊必选，副标题绝对居中叠在这一行
        //   第 2 行  [加号] + 右侧内容（空框是居中大字提示，有文件是铺满的文件卡）
        // 加号在**左下角**，不是标题行右侧 —— 那是文章版的固定位置。
        VStack(alignment: .leading, spacing: 9) {
            header
            actionRow
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        // 点框内一律「激活等待粘贴」，不再直接开面板（用户 2026-10-29 第 17 轮：
        // 框内逻辑照文章批改 app）。开面板走左下角那个加号。
        .onTapGesture {
            guard !state.isRunning else { return }
            state.armPaste(slot)
            state.closePasteMenu()      // 右键小菜单还开着的话，这一下把它收了
        }
        .trialGlassCard(cornerRadius: 16,
                        shadowOpacity: active || armed ? 0.09 : 0.03,
                        shadowRadius: active || armed ? 14 : 6)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.brandBlue.opacity(armed || dropTargeted ? 0.06
                                                   : (cardHover ? 0.04 : 0)))
                .allowsHitTesting(false)
        )
        .overlay(
            // 有文件时靠旋转渐变边，没有时靠这条实线；拖着文件 / 等待粘贴时变成加粗蓝色。
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(armed || dropTargeted ? Color.brandBlue.opacity(0.75)
                                                    : Color.secondary.opacity(active ? 0 : 0.30),
                              lineWidth: armed || dropTargeted ? 1.6 : 1.2)
                .allowsHitTesting(false)
        )
        .overlay(
            RotatingGradientBorder(radius: 16, active: active)
                .opacity(active ? 1 : 0)
        )
        // 拖放（用户 2026-10-29 第 11 轮）：一个框只放一个文件，只取第一个。
        // 和粘贴 / 点加号选文件走**同一个** `accept` —— 白名单、跨框查重都在那里。
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard !state.isRunning, !providers.isEmpty else { return false }
            AppState.resolveFileURLs(from: providers) { urls in
                state.acceptDropped(urls, for: slot)
            }
            return true
        }
        .overlay {
            // 右键：激活本框 + 在鼠标位置冒出「粘贴 / 取消」小菜单。
            // 窗口失焦时的第一次左键也在这里接（否则会被 AppKit 吞掉），转成「激活」。
            // 平时左键完全穿透（见 RightClickCatcher）。
            RightClickCatcher(
                onRightClick: { point in
                    guard !state.isRunning else { return }
                    state.openPasteMenu(slot, at: point)
                },
                onFirstLeftClick: {
                    guard !state.isRunning else { return }
                    state.armPaste(slot)
                }
            )
        }
        .overlay {
            // 小菜单。位置夹在框内，免得贴边时半个菜单露到卡片外面去。
            if state.pasteMenuSlot == slot {
                GeometryReader { geo in
                    PasteBubble(
                        onPaste: {
                            // 留着激活态：和 ⌘V 粘贴完一样，框还是蓝的
                            state.keepPasteArmed(slot)
                            state.closePasteMenu()
                            state.pasteFromClipboard(into: slot)
                        },
                        onCancel: {
                            state.closePasteMenu()
                            state.pasteArmed = nil
                        }
                    )
                    .position(
                        x: min(max(state.pasteMenuPoint.x, 62), max(geo.size.width - 62, 62)),
                        y: min(max(state.pasteMenuPoint.y, 44), max(geo.size.height - 44, 44))
                    )
                }
            }
        }
        .onHover { cardHover = $0 && !state.isRunning }
        .animation(.easeOut(duration: 0.15), value: cardHover)
        .animation(.easeOut(duration: 0.15), value: dropTargeted)
        .animation(.easeOut(duration: 0.18), value: active)
        .animation(.easeOut(duration: 0.18), value: armed)
        // 提示落在**本框的下沿**（用户 2026-10-29：注意冒泡位置）：
        // 只有 toastSlot 是自己的框才显示，两个框不会同时弹；
        // 贴底部是为了不盖住标题和文件名。
        .overlay(alignment: .bottom) {
            if state.toastSlot == slot, let text = state.toast {
                ToastBar(text: text) { state.dismissToast() }
                    .padding(.bottom, 6)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
    }

    // MARK: 标题行（副标题绝对居中叠在同一行）

    private var header: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 14.5, weight: .semibold))
            if active {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.green.opacity(0.9))
            } else {
                Text("＊必选")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.brandPink)
            }
            Spacer(minLength: 8)
        }
        // 用户 2026-10-29：原来「标题 / 副标题 / 加号」三行太占地方，压成两行 ——
        // 副标题**绝对居中**叠在标题这一行上，相对整卡宽度居中，不看左边已经有几个字。
        // HStack 撑满整卡，所以 overlay 的 center 就是整卡中心。
        .overlay(alignment: .center) {
            Text(subtitle)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .allowsHitTesting(false)
        }
        // 激活态的蓝色提示已经删掉（用户 2026-10-29：和下面那行大字重复了）。
        // 现在激活只靠蓝边 + 浅蓝底 + 大字提示变色来体现。
    }

    // MARK: 加号 + 内容（照文章版：加号在左下角）

    private var actionRow: some View {
        HStack(spacing: 9) {
            plusButton
            if let url = url {
                fileCard(url)
            } else {
                // 空着也要撑满：否则 HStack 的宽度只等于加号，overlay 的「中心」会跑到左边去
                Color.clear.frame(maxWidth: .infinity)
            }
        }
        // 大字提示**相对整卡绝对居中**（用户 2026-10-29 第 19 轮：不是相对「加号右边那块」居中）。
        // overlay 的宽度等于整个 actionRow（含加号），center 天然就是整卡中心。
        .overlay(alignment: .center) {
            if url == nil {
                emptyHint
            }
        }
    }

    private var plusButton: some View {
        Button {
            // 加号也算「框内点击」，不退出等待粘贴（只有点框外才取消）
            state.keepPasteArmed(slot)
            state.chooseFile(for: slot)
        } label: {
            // 用户 2026-10-29 第 19 轮：边长宽都加大 30%（46 → 60），图标跟着 17 → 22，
            // 圆角同比例 11 → 14。框因此变高、主页跟着往下推，用户说都接受。
            Image(systemName: "plus")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Color.brandBlue.opacity(plusHover ? 1 : 0.8))
                .frame(width: 60, height: 60)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.brandBlue.opacity(plusHover ? 0.13 : 0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.brandBlue.opacity(plusHover ? 0.6 : 0.32),
                                      lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .handCursor()
        .onHover { plusHover = $0 }
        .animation(.easeOut(duration: 0.07), value: plusHover)
        .disabled(state.isRunning)
        .help("选择文件")
    }

    // MARK: 空框提示

    private var emptyHint: some View {
        // 用户 2026-10-29：把「点击此处可粘贴，或将文件拖入」改写成把三种入口都写全 ——
        // ⌘V 用 ⌘ 符号（不是 "cmd"），右键也是粘贴入口，最后才是拖入。
        Text("点击此处可 ⌘V 或右键粘贴，也可拖入文件")
            .font(.system(size: 14))
            .foregroundStyle(armed ? Color.brandBlue : Color.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .allowsHitTesting(false)
            .transition(.opacity)
    }

    // MARK: 文件卡（铺满右侧可用宽度）

    /// 只有一个文件，所以不用三等分：整张卡铺满加号右边的全部宽度，
    /// 左边文档图标、中间文件名 + 大小、右边一个叉。用户 2026-10-29 第 17 轮：
    /// 「预览卡可以大到边框」。高度跟加号一起改成 60（第 19 轮加号 +30%），
    /// 两个框高度不会因为有没有文件而跳。
    private func fileCard(_ url: URL) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.brandBlue.opacity(0.10))
                    .frame(width: 42, height: 42)
                Image(systemName: "doc.text.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.brandBlue)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(fileSize) KB · 点框粘贴替换，或拖入新文件")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button {
                state.clearFile(for: slot)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
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
            .handCursor()
            .onHover { isCloseHover = $0 }
            .help("移除这个文件")
        }
        .padding(.horizontal, 12)
        .frame(height: 60)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(fileHover ? 0.085 : 0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.brandBlue.opacity(fileHover ? 0.45 : 0),
                              lineWidth: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.14), lineWidth: 1)
                .opacity(fileHover ? 0 : 1)
        )
        // 用户 2026-10-29 第 18 轮：卡片要有预览。点卡片 = 放大看 docx 内容，
        // 点叉 = 移除，两者不冲突（Button 会先吃掉点击）。
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture { state.openPreview(url) }
        .onHover { fileHover = $0 && !state.isRunning }
        .animation(.easeOut(duration: 0.12), value: fileHover)
        .help("点击预览这个文件")
    }
}

// MARK: - 文件预览（照搬文章批改 app 的 PreviewPanel）

/// 系统 QuickLook 的 SwiftUI 包装（和文章版 `QuickLookPreview` 是同一个东西）。
/// 讲义只有 docx，交给系统渲染比自己做省事得多 —— 和访达里按空格看到的是同一套效果，
/// 由系统自带的 Office.qlgenerator 出图，不需要装 Office。
struct QuickLookView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> NSView {
        // 这个初始化器签名是可失败的，真拿不到就给个空视图兜住，别让整个界面炸掉
        guard let view = QLPreviewView(frame: NSRect(x: 0, y: 0, width: 529, height: 552),
                                       style: .normal) else { return NSView() }
        view.autostarts = true
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? QLPreviewView else { return }
        guard (view.previewItem as? URL) != url else { return }
        view.previewItem = url as NSURL
        view.refreshPreviewItem()
    }
}

/// 点文件卡弹出的放大预览（用户 2026-10-29 第 19 轮：「预览逻辑先照搬 article 的 app」）。
///
/// 结构和文章版一模一样：顶部信息栏（图标 + 文件名 + 类型·大小 + 右上角叉）→ Divider →
/// QuickLook 真渲染的正文 → 底部文件名胶囊 + 一句关闭提示。
/// 尺寸按用户要求整体放大 15%：460×480 → **529×552**，信息栏 34 → 39，圆角 14 → 16。
///
/// 交互也照搬：
/// - 点面板外面 / 点信息栏 / 点右上角的 ✕ / 按 Esc → 关闭
/// - **正文区域本身不接「点一下关闭」**，否则翻页和滚动会被吃掉
struct FilePreviewPanel: View {
    let url: URL
    let close: () -> Void

    private var sizeText: String {
        let bytes = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.16)
                .transition(.opacity)
            VStack(spacing: 8) {
                documentPreview
                Text("\(url.lastPathComponent) · \(sizeText)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.black.opacity(0.42)))
                Text("点右上角的 ✕ 或面板外面关闭")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.7))
            }
            // 592 的面板 + 底部两行说明在 720 高的窗口里本来就快满了，
            // 所以外边距用 14 而不是文章版的 18，别让底部提示被裁掉。
            .padding(14)
            .transition(.scale(scale: 0.62).combined(with: .opacity))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { close() }
    }

    private var documentPreview: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.brandBlue)
                Text(url.lastPathComponent)
                    .font(.system(size: 13.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text("Word 文档 · \(sizeText)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.leading, 14)
            // 右边多留 41：给内层右上角那个大叉让位，别让类型文字钻到叉底下
            .padding(.trailing, 41)
            .frame(height: 39)
            .contentShape(Rectangle())
            .onTapGesture { close() }

            Divider()

            QuickLookView(url: url)
                .frame(width: 529, height: 552)
        }
        .frame(width: 529)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 1)
        )
        .overlay(alignment: .topTrailing) { closeButton.padding(9) }
        .shadow(color: .black.opacity(0.24), radius: 25, y: 9)
    }

    /// 内层右上角的大叉：**白底 + 深色叉**，描一圈淡灰边，压在浅色文档上也看得见。
    private var closeButton: some View {
        Button {
            close()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.black.opacity(0.72))
                .frame(width: 25, height: 25)
                .background(Circle().fill(Color.white))
                .overlay(Circle().strokeBorder(Color.black.opacity(0.14), lineWidth: 0.8))
                .shadow(color: .black.opacity(0.20), radius: 3, y: 1)
        }
        .buttonStyle(.plain)
        .handCursor()
        .help("关闭预览")
    }
}

// MARK: - 右键 / 失焦首次左键

/// 垫在整张上传卡上的一层透明 NSView，只在**右键**（和窗口失焦时的第一次左键）时接事件。
///
/// 为什么不用 SwiftUI：`onTapGesture` 只认左键；`.contextMenu` 会弹系统菜单；
/// `.gesture` 也接不到右键。AppKit 这边 `rightMouseDown` 是现成的，
/// 所以垫一个透明 NSView，在 `hitTest` 里**只在右键事件时返回自己**，左键一律返回 nil ——
/// 事件继续往下一层找，框的 tap、加号的按钮都照常工作。
///
/// 用户 2026-10-29 第 17 轮要求（照文章批改 app）：框内右键 = 激活该框 +
/// 在鼠标位置冒出「粘贴 / 取消」小菜单。左键连续点框内保持激活，右键也一样。
///
/// **顺手补的 macOS 坑**：窗口失去焦点、但仍然肉眼可见时，左键点框没反应，右键却正常。
/// 原因是 AppKit 的「第一次点击」规则 —— 非 key 窗口上的左键只用来激活窗口，事件被吞掉，
/// 除非命中的视图 `acceptsFirstMouse` 返回 true。右键不受这条限制，所以只有左键坏。
/// 修法：窗口不是 key 时，这一层把左键也接过来（`hitTest` 返回自己），
/// `mouseDown` 里直接转成「激活粘贴框」。窗口变 key 之后照旧穿透，一切照常。
struct RightClickCatcher: NSViewRepresentable {
    /// 右键回调。参数是**框内坐标**（左上原点，y 向下），用来决定小菜单弹在哪
    let onRightClick: (CGPoint) -> Void
    /// 窗口没焦点时的第一次左键（本来会被 AppKit 吞掉）—— 转成「激活这个框」
    let onFirstLeftClick: () -> Void

    func makeNSView(context: Context) -> NSView {
        let v = CatcherView()
        v.onRightClick = onRightClick
        v.onFirstLeftClick = onFirstLeftClick
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let v = nsView as? CatcherView else { return }
        v.onRightClick = onRightClick
        v.onFirstLeftClick = onFirstLeftClick
    }

    final class CatcherView: NSView {
        var onRightClick: ((CGPoint) -> Void)?
        var onFirstLeftClick: (() -> Void)?

        /// 不返回 true 的话，窗口没焦点时这一层连事件都收不到
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? {
            // 判断「当前这个事件是不是右键」—— NSApp.currentEvent 在命中测试期间就是它。
            // 不是右键就返回 nil，等于这一层不存在（左键穿透）。
            guard let type = NSApp.currentEvent?.type else { return nil }
            switch type {
            case .rightMouseDown, .rightMouseUp, .rightMouseDragged:
                return super.hitTest(point)
            case .leftMouseDown:
                // 窗口不是 key：这一下左键本来会被 AppKit 吞掉（只拿去激活窗口），
                // 拦下来自己处理，让「点框 = 激活粘贴」在失焦状态下也成立。
                return window?.isKeyWindow == false ? super.hitTest(point) : nil
            default:
                return nil
            }
        }

        override func rightMouseDown(with event: NSEvent) {
            // NSView 默认坐标原点在左下，SwiftUI 的 overlay 是左上原点 —— 这里翻一下，
            // 否则小菜单会上下颠倒地弹出来。
            let p = convert(event.locationInWindow, from: nil)
            onRightClick?(CGPoint(x: p.x, y: bounds.height - p.y))
        }

        override func mouseDown(with event: NSEvent) {
            onFirstLeftClick?()
        }
    }
}

// MARK: - 右键小菜单

/// 右键弹出的两选一气泡（照文章批改 app）：圆角矩形、仿 glass、只有「粘贴 / 取消」。
/// 不用系统 `.contextMenu`：那个是系统样式的菜单，和这套玻璃卡片不搭，也没法定两个选项的样式。
struct PasteBubble: View {
    let onPaste: () -> Void
    let onCancel: () -> Void

    @State private var hover: Int?

    var body: some View {
        VStack(spacing: 0) {
            row(0, title: "粘贴", icon: "doc.on.clipboard", action: onPaste)
            Rectangle()
                .fill(Color.secondary.opacity(0.18))
                .frame(height: 1)
                .padding(.horizontal, 8)
            row(1, title: "取消", icon: "xmark", action: onCancel)
        }
        .padding(5)
        .frame(width: 112)
        .trialGlassCard(cornerRadius: 12, shadowOpacity: 0.22, shadowRadius: 14)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.16), lineWidth: 1)
                .allowsHitTesting(false)
        )
        .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .center)))
    }

    private func row(_ index: Int, title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 10.5))
                    .frame(width: 13)
                Text(title)
                    .font(.system(size: 12))
                Spacer(minLength: 0)
            }
            .foregroundStyle(hover == index ? Color.brandBlue : Color.primary.opacity(0.86))
            .padding(.horizontal, 7)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.brandBlue.opacity(hover == index ? 0.12 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { hover = index } else if hover == index { hover = nil }
        }
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

    /// 复制后 1.6 秒内按钮显示「已复制」，给个明确的反馈
    @State private var copied = false

    private var lines: [String] { state.progressLines }
    private var scriptOutput: String { state.scriptOutput }

    /// 压暗层高度 = 720 - 172。172 是底部留给 Word 卡（标题行 + 说明 + 按钮行）的高度，
    /// 少留一点就会压到「详情」按钮上。
    /// （2026-10-29 对齐试卷识别版：原来这里是 520，比试卷版矮一截，面板和压暗层都跟着改回来。）
    private let scrimHeight: CGFloat = 548

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
        .frame(width: 566, height: 516)
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

            // 一键拷全部（2026-10-29 对齐试卷识别版）。
            // 每行是独立 Text，SwiftUI 的跨行拖选会被打断，只能一行一行选 ——
            // 用户要截图两次以上才拿得全，所以给个按钮。
            Button(action: copyAll) {
                HStack(spacing: 4) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 9, weight: .bold))
                    Text(copied ? "已复制" : "复制全部")
                        .font(.system(size: 10.5, weight: .medium))
                }
                .foregroundStyle(Color.black.opacity(0.72))
                .padding(.horizontal, 9)
                .frame(height: 22)
                .background(Capsule().fill(Color.white))
                .overlay(Capsule().strokeBorder(Color.black.opacity(0.14), lineWidth: 0.8))
                .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
            }
            .buttonStyle(.plain)
            .handCursor()
            .disabled(lines.isEmpty && scriptOutput.isEmpty)
            .opacity(lines.isEmpty && scriptOutput.isEmpty ? 0.45 : 1)
            .help("把整份日志拷到剪贴板（含脚本输出）")

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

    /// 把面板里看到的东西原样拷进剪贴板：日志行 + 分隔线 + 脚本输出。
    /// 顺序和界面一致，贴到别处不用再拼。
    private func copyAll() {
        var parts = lines
        if !scriptOutput.isEmpty {
            if !parts.isEmpty { parts.append("") }
            parts.append("—— 脚本输出 ——")
            parts.append(scriptOutput)
        }
        guard !parts.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(parts.joined(separator: "\n"), forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
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
