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
                    footer
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
            }
        }
        .sheet(isPresented: $state.showOutputPanel) {
            OutputSheet().environmentObject(state)
        }
        .onReceive(NotificationCenter.default.publisher(for: .lectureAppConfirmExit)) { _ in
            showExitConfirm = true
        }
        .overlay {
            if showExitConfirm {
                exitConfirmOverlay
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
                    Button {
                        NSApplication.shared.terminate(nil)
                    } label: {
                        Text("退出")
                            .font(.system(size: 13.5, weight: .semibold))
                            .padding(.horizontal, 20)
                            .padding(.vertical, 6)
                    }
                    .dialogGlassButtonStyle()
                    .tint(Color.brandRed)
                    .foregroundStyle(.white)
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
                    if !state.modesReady && !state.modesChecking {
                        Button("重新检查") { state.retryDeepSeekModes() }
                            .font(.system(size: 11, weight: .medium))
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.brandBlue)
                            .handCursor()
                    }
                }
            }

            Spacer(minLength: 6)

            if state.loginCountdown > 0 {
                Text("\(state.loginCountdown) 秒后自动收起")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.brandBlue)
                    .lineLimit(1)
            } else if state.loginSettled && !state.login.isLoggedIn {
                Button { state.openDeepSeek() } label: {
                    Text("登录 DeepSeek")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .trialGlassCapsule(fallbackFill: Color.brandBlue.opacity(0.13))
                        .foregroundStyle(Color.brandBlue)
                }
                .buttonStyle(.plain)
                .handCursor()
                .help("只在登录时会弹出窗口，登录成功后自动收起")
            }
        }
        .padding(.horizontal, 4)
        .frame(height: 30)
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
        }
        .buttonStyle(.plain)
        .handCursor()
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

    // MARK: 页脚

    private var footer: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(state.pythonReady ? Color.green : Color.red)
                .frame(width: 6, height: 6)
            Text(state.pythonReady ? "运行环境已就绪" : "运行环境缺失，无法生成讲义")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Spacer()
            Menu {
                Button("退出 DeepSeek 账号…") { state.confirmLogout() }
                    .disabled(!state.login.isLoggedIn)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 20)
            .handCursor()
            .disabled(state.isRunning)
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }
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
        .animation(.easeOut(duration: 0.18), value: active)
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
                Text("\(fileSize) KB · 点框里任何地方可以换一个")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text("＊必选，点框里任何地方选择文件")
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
                .strokeBorder(Color.secondary.opacity(active ? 0 : 0.30), lineWidth: 1.2)
        )
        .overlay(
            RotatingGradientBorder(radius: 16, active: active)
                .opacity(active ? 1 : 0)
        )
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

    private var active: Bool { state.docx.isReady }

    private var isFailed: Bool {
        if case .failed = state.docx { return true }
        return false
    }

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
            return "这次没成功：\(why)。诊断日志已自动留在本机，需要发给开发者时点下面的按钮。"
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
                    Text("可下载")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .trialGlassCapsule(fallbackFill: Color.green.opacity(0.16))
                        .foregroundStyle(.green)
                }
            }

            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(state.docx.isReady ? Color.secondary : Color.secondary.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 10) {
                if isFailed {
                    // 失败时主按钮换成「导出诊断报告」——
                    // 用户不需要看懂 Python，只要把这个文件夹发给开发者就行
                    Button {
                        state.exportDiagnostics()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 12))
                            Text("导出诊断报告")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .trialGlassTinted(cornerRadius: 10,
                                          tint: Color.brandPink,
                                          fallback: AnyShapeStyle(LinearGradient(colors: [.brandPink, .brandPurple],
                                                                                   startPoint: .leading, endPoint: .trailing)),
                                          shadowColor: .clear, shadowRadius: 0, shadowY: 0)
                    }
                    .buttonStyle(.plain)
                    .handCursor()

                    Button {
                        state.showOutputPanel = true
                    } label: {
                        Text("查看详情")
                            .font(.system(size: 13))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .trialGlassTinted(cornerRadius: 10,
                                              tint: Color.secondary,
                                              fallback: AnyShapeStyle(Color.secondary.opacity(0.12)),
                                              shadowColor: .clear, shadowRadius: 0, shadowY: 0)
                    }
                    .buttonStyle(.plain)
                    .handCursor()
                } else {
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
                    }
                    .buttonStyle(.plain)
                    .handCursor()
                    .disabled(!active)

                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .trialGlassCard(cornerRadius: 16, shadowOpacity: active ? 0.08 : 0.02, shadowRadius: active ? 12 : 5)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.secondary.opacity(active ? 0 : 0.28), lineWidth: 1.2)
        )
        .overlay(
            RotatingGradientBorder(radius: 16, active: active)
                .opacity(active ? 1 : 0)
        )
        .animation(.easeOut(duration: 0.2), value: active)
    }
}

// MARK: - 运行输出面板（只在出错时自动弹出）

struct OutputSheet: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("出错的详细信息")
                .font(.system(size: 16, weight: .semibold))
            Text("这一段是给开发排查用的。你可以直接关掉，也可以复制下来发给开发者。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            ScrollView {
                Text(state.scriptOutput.isEmpty ? "（没有输出）" : state.scriptOutput)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            )

            HStack {
                Button("复制全部") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(state.scriptOutput, forType: .string)
                }
                .controlSize(.small)

                Button("导出诊断报告到桌面") { state.exportDiagnostics() }
                    .controlSize(.small)

                Spacer()

                Button("知道了") { state.showOutputPanel = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 660, height: 460)
    }
}
