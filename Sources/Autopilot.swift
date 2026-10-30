import Foundation
import AppKit

/// 无人值守跑一轮，供回归测试用（省得每次手动选文件、点按钮）。
///
/// 三种触发方式，**首选第 1 种**：
///
///     1) 直接执行包内二进制 —— 参数一定传得到，退出码还能同步拿到：
///        "讲义生成.app/Contents/MacOS/LectureGen" --autopilot 考卷.docx 答案.docx [--out 目录]
///
///     2) defaults write com.workbuddy.lecturegen autopilotExam   -string "/abs/考卷.docx"
///        defaults write com.workbuddy.lecturegen autopilotAnswer -string "/abs/答案.docx"
///        defaults write com.workbuddy.lecturegen autopilotOut    -string "/abs/输出目录"
///        open -a "讲义生成"
///
///     3) open -a "讲义生成" --args --autopilot 考卷.docx 答案.docx [--out 目录]
///        —— **不推荐**：`open --args` 不保证能传进 `CommandLine.arguments`
///        （`--logdemo` 2026-10-30 踩过；同日给作文批改 App 加替跑时又踩了一次，
///        同一套参数 `open --args` 起来连 `_trace.txt` 都不生成，换成跑二进制立刻就对了）。
///
/// 第 1 种要求 App 没在运行（`open -a` 会复用旧实例，改完代码必须 `killall LectureGen`）。
/// 第 2 种是兜底，也是唯一能「双击图标就替跑」的方式。
///
/// 跑完把成品和日志复制到输出目录，然后按结果退出：
/// 0 = 成功、1 = 生成失败、2 = 超时、3 = 文件放不进上传框 / 文件不存在、4 = 双绿灯未确认。
/// 用完记得 `defaults delete` 清掉，否则下次启动还会自动跑。
enum Autopilot {

    struct Config {
        var exam: URL
        var answer: URL
        var outDir: URL
    }

    /// 整轮最长等多久（正常 2~4 分钟，留足余量）
    private static let deadline: TimeInterval = 480

    /// 等「深度思考 + 联网搜索」两个绿灯最多多久（页面慢时实测要 8~10 秒）
    private static let modeWait: TimeInterval = 60

    static func configFromLaunch() -> Config? {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--autopilot"), i + 2 < args.count {
            let exam = URL(fileURLWithPath: args[i + 1])
            let answer = URL(fileURLWithPath: args[i + 2])
            var out = exam.deletingLastPathComponent()
            if let j = args.firstIndex(of: "--out"), j + 1 < args.count {
                out = URL(fileURLWithPath: args[j + 1])
            }
            return Config(exam: exam, answer: answer, outDir: out)
        }

        let d = UserDefaults.standard
        guard let e = d.string(forKey: "autopilotExam"), !e.isEmpty,
              let a = d.string(forKey: "autopilotAnswer"), !a.isEmpty else { return nil }
        let o = d.string(forKey: "autopilotOut") ?? (e as NSString).deletingLastPathComponent
        return Config(exam: URL(fileURLWithPath: e),
                      answer: URL(fileURLWithPath: a),
                      outDir: URL(fileURLWithPath: o))
    }

    static func start(state: AppState) {
        guard let cfg = configFromLaunch() else { return }
        try? FileManager.default.createDirectory(at: cfg.outDir, withIntermediateDirectories: true)
        mark(cfg, "进入 start，考卷=\(cfg.exam.lastPathComponent) 答案=\(cfg.answer.lastPathComponent)")
        NSLog("[autopilot] 考卷=%@ 答案=%@ 输出=%@",
              cfg.exam.lastPathComponent, cfg.answer.lastPathComponent, cfg.outDir.path)

        // 先查文件在不在。上传框**不查存在性**（它只按扩展名收卡片），
        // 不在这儿拦一道，就要等 pipeline 跑到一半才报「未能打开文件」，
        // 退出码还变成 1（生成失败），看不出其实是路径写错了。
        let missing = [cfg.exam, cfg.answer].filter { !FileManager.default.fileExists(atPath: $0.path) }
        if !missing.isEmpty {
            let names = missing.map(\.lastPathComponent).joined(separator: "、")
            finish(state: state, cfg: cfg, code: 3, note: "文件不存在：\(names)")
            return
        }

        // 给内置浏览器 3 秒把页面拉起来，先把两个文件塞进槽位（跟模式无关，可以先做）
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            mark(cfg, "3 秒到，开始填槽")
            guard state.accept(cfg.exam, for: .exam) else {
                finish(state: state, cfg: cfg, code: 3, note: "考卷放不进上传框")
                return
            }
            guard state.accept(cfg.answer, for: .answer) else {
                finish(state: state, cfg: cfg, code: 3, note: "答案放不进上传框")
                return
            }
            mark(cfg, "两个槽已就位，等深度思考 / 联网搜索两个绿灯")
            awaitModes(state: state, cfg: cfg, until: Date().addingTimeInterval(modeWait))
        }
    }

    /// 界面上的「生成」按钮不等双绿灯也能点（模式检测失败时按钮不该永久变灰），
    /// 但无人值守必须等 —— 模式没确认就开跑，生成出来的讲义可能没开深度思考。
    private static func awaitModes(state: AppState, cfg: Config, until limit: Date) {
        if state.modesReady {
            mark(cfg, "双绿灯已就绪，启动 pipeline")
            state.runPipeline()
            poll(state: state, cfg: cfg, until: Date().addingTimeInterval(deadline))
            return
        }
        if Date() > limit {
            finish(state: state, cfg: cfg, code: 4,
                   note: "深度思考 / 联网搜索 \(Int(modeWait)) 秒内未确认开启")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            awaitModes(state: state, cfg: cfg, until: limit)
        }
    }

    /// 命令行侧看不到 NSLog，把关键节点落成文件，方便判断卡在哪一步
    private static func mark(_ cfg: Config, _ note: String) {
        let url = cfg.outDir.appendingPathComponent("_trace.txt")
        let line = "\(Date())  \(note)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private static func poll(state: AppState, cfg: Config, until limit: Date) {
        switch state.docx {
        case .ready(let url):
            finish(state: state, cfg: cfg, code: 0, note: nil, produced: url)
        case .failed(let message):
            finish(state: state, cfg: cfg, code: 1, note: message)
        default:
            if Date() > limit {
                finish(state: state, cfg: cfg, code: 2, note: "超时")
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    poll(state: state, cfg: cfg, until: limit)
                }
            }
        }
    }

    private static func finish(state: AppState, cfg: Config, code: Int32,
                               note: String?, produced: URL? = nil) {
        let fm = FileManager.default
        try? fm.createDirectory(at: cfg.outDir, withIntermediateDirectories: true)

        if let src = produced {
            let dest = cfg.outDir.appendingPathComponent(src.lastPathComponent)
            try? fm.removeItem(at: dest)
            do {
                try fm.copyItem(at: src, to: dest)
                NSLog("[autopilot] 成品=%@", dest.path)
                mark(cfg, "成品已复制：\(dest.lastPathComponent)")
            } catch {
                NSLog("[autopilot] 复制成品失败：%@", error.localizedDescription)
                mark(cfg, "复制成品失败：\(error.localizedDescription)")
            }
        }

        let logURL = cfg.outDir.appendingPathComponent("autopilot-日志.txt")
        try? state.logText.write(to: logURL, atomically: true, encoding: .utf8)

        // 结束原因也要落盘：命令行侧只看得到 NSLog，`open -a` 起的那次连 NSLog 都捞不着，
        // 没有这一行就只能靠猜「到底为什么退出的」。
        if let note = note {
            NSLog("[autopilot] 结束：%@", note)
            mark(cfg, "结束（退出码 \(code)）：\(note)")
        } else {
            mark(cfg, "结束（退出码 0）：成功")
        }
        exit(code)
    }
}
