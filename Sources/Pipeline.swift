import Foundation
import AppKit

private struct UploadItem {
    var url: URL
    var name: String
    var mime: String
}

extension AppState {

    static let promptText = """
    执行《讲义制作规则.md》所规定的内容，但是因为现在是网页版无法输出文件，请你给出 Python 脚本文件我自己去执行，其他规则不变。

    补充说明（我的运行环境）：Python 3.12，已装好 python-docx，没有其他第三方库，请不要 import pandas、matplotlib、openpyxl 之类；脚本要能一次跑完，不要用 input() 等待键盘输入；最后请用 doc.save('文件名.docx') 保存。

    【格式要求，非常重要】代码的最后一个行必须原样写上这一行注释：
    # ===LECTURE-END===
    这一行必须是代码框里的最后一行，它之后不能再有任何代码。这是我用来判断代码是否输出完整的标记，请务必保留、不要改动、不要省略。

    【收尾说明，同样重要】代码块结束之后，请再写一段简短的中文说明，**至少 3 行、3 行或更多**，讲清楚：这份讲义生成了什么内容、哪部分是红答案 / 紫干扰 / 绿解析、使用时有什么注意事项。这段说明必须写在代码块外面，不要写进代码里。
    """

    /// AI 必须在代码末尾打上的结束标记
    static let endMarker = "# ===LECTURE-END==="

    private var docxMime: String {
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    }

    private func mimeFor(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "docx": return docxMime
        case "doc": return "application/msword"
        case "md": return "text/markdown"
        default: return "application/octet-stream"
        }
    }

    // MARK: - 入口

    func runPipeline() {
        guard !isRunning else { return }
        isRunning = true
        stopRequested = false
        progressLines = []
        docx = .idle

        // 先把两个文件拷到局部变量，再把上传框清空 —— 顺序反了就拿不到文件了。
        let exam = examURL
        let answer = answerURL
        let auto = autoSend
        submitAndClearUploads()

        say("正在生成备课讲义…",
            detail: "两份文档已提交给 DeepSeek，上传框已清空以免重复生成。请稍候，约 1–3 分钟。",
            running: true)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            // 浏览器隐形时系统会做 App Nap 节流，压住它保证流式输出不卡
            let token = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled],
                reason: "等待 DeepSeek 生成讲义")
            defer { ProcessInfo.processInfo.endActivity(token) }

            var script: String?
            var failure: String?
            do {
                script = try self.pipeline(exam: exam, answer: answer, auto: auto)
            } catch {
                failure = error.localizedDescription
                self.log("✗ \(failure ?? "")")
            }
            DispatchQueue.main.async {
                self.isRunning = false
                if let failure = failure {
                    let aborted = failure.contains("已中止")
                    let friendly = aborted ? "已中止" : "生成失败了"
                    // 上传框是提交时清空的，失败/中止就把文件放回去，省得重新选
                    self.restoreHeldFiles()
                    self.say(friendly,
                             detail: aborted
                                ? "讲义没有生成，两份文档已放回上传框，可直接重试"
                                : failure,
                             running: false,
                             tone: aborted ? .idle : .error)
                    if !aborted {
                        self.lastFailure = failure
                        self.docx = .failed(failure)
                    }
                    return
                }
                if let script = script, !script.isEmpty {
                    self.offerScript(script)
                } else if auto {
                    self.restoreHeldFiles()
                    self.say("AI 回答完了，但没找到脚本",
                             detail: "两份文档已放回上传框，可以再试一次",
                             running: false, tone: .error)
                }
            }
        }
    }

    // MARK: - 主流程

    @discardableResult
    private func pipeline(exam: URL?, answer: URL?, auto: Bool) throws -> String? {
        guard let exam = exam, let answer = answer else {
            throw BridgeError.failed("文件没选齐")
        }
        guard let ruleURL = AppState.bundledRule,
              let tplURL = AppState.bundledTemplate else {
            throw BridgeError.failed("App 内置的规则文件丢了，请重新安装 App")
        }

        var uploads = [
            UploadItem(url: ruleURL, name: "讲义制作规则.md", mime: "text/markdown"),
            UploadItem(url: tplURL, name: "标准模式讲义.docx", mime: docxMime),
            UploadItem(url: exam, name: exam.lastPathComponent, mime: mimeFor(exam)),
            UploadItem(url: answer, name: answer.lastPathComponent, mime: mimeFor(answer))
        ]
        var prompt = AppState.promptText

        // 0. 先开一个新对话，避免上一轮的附件和上下文残留
        let newChat = try self.js(Scripts.newChat)
        log("新对话：\(newChat)")
        Thread.sleep(forTimeInterval: 1.5)

        // 1. 探针：确认输入框和文件框的结构
        // 注：深度思考+智能搜索已在登录成功时由 ensureDeepSeekModes() 处理，
        // 这里只探结构，不再重复检测开关状态。
        let probe = try self.js(Scripts.probeComposer)
        log("页面：\(probe)")

        // 2. 清空分片缓冲
        _ = try self.js(Scripts.resetBuffer)

        // 3. 把字节灌进页面
        for (index, item) in uploads.enumerated() {
            try checkStop()
            let data = try Data(contentsOf: item.url)
            try feed(index: index, data: data)
            log("载入 \(item.name)（\(data.count / 1024) KB）")
            say("正在上传文件…",
                detail: "\(item.name)（第 \(index + 1)/\(uploads.count) 个）",
                fraction: Double(index + 1) / Double(uploads.count + 2),
                running: true)
        }

        // 4. 组装成 File 并交给页面
        let defs = uploads.enumerated().map { index, item -> [String: Any] in
            ["idx": index, "name": item.name, "type": item.mime]
        }
        let injected = try self.js(Scripts.commitFiles(defsJSON: jsonString(defs)))
        log("注入：\(injected)")
        say("正在把文件交给 AI…", detail: "一共 4 个文件：规则、模板、考卷、答案",
            fraction: 0.55, running: true)

        // 4. 等附件条渲染出来
        var missing = try waitFor(names: uploads.map { $0.name }, timeout: 25)
        log(missing.isEmpty ? "4 个附件已就位" : "还没出现：\(missing.joined(separator: "、"))")

        // 4.1 .md 被拒收就改 .txt 重试，并同步替换提示词里的文件名
        if missing.contains("讲义制作规则.md") {
            log("DeepSeek 不收 .md，改用 .txt 重试")
            say("正在换一种格式重传规则文件…", fraction: 0.6, running: true)
            uploads[0].name = "讲义制作规则.txt"
            uploads[0].mime = "text/plain"
            prompt = prompt.replacingOccurrences(
                of: "《讲义制作规则.md》", with: "《讲义制作规则.txt》")

            let retry: [[String: Any]] = [
                ["idx": 0, "name": uploads[0].name, "type": uploads[0].mime]
            ]
            _ = try self.js(Scripts.commitFiles(defsJSON: jsonString(retry)))
            let still = try waitFor(names: [uploads[0].name], timeout: 20)
            if !still.isEmpty {
                throw BridgeError.failed("规则文件传不上去，DeepSeek 可能既不收 .md 也不收 .txt")
            }
            missing.removeAll { $0 == "讲义制作规则.md" }
        }

        if !missing.isEmpty {
            throw BridgeError.failed("这些文件没能放进对话框：\(missing.joined(separator: "、"))")
        }
        say("文件都传上去了", detail: "正在把题目和要求发给 AI", fraction: 0.68, running: true)

        // 5. 填提示词
        let filled = try self.js(Scripts.fillText(textJSON: jsonString(prompt)))
        guard filled.hasPrefix("OK") else {
            throw BridgeError.failed("文字填不进去：\(filled)")
        }
        log("提示词已填入（\(filled.dropFirst(3)) 字）")

        // 6. 发送
        if auto {
            try checkStop()
            for second in stride(from: 4, through: 1, by: -1) {
                say("马上开始生成…", detail: "\(second) 秒后自动发送，不用你操作",
                    fraction: 0.75, running: true)
                Thread.sleep(forTimeInterval: 1.0)
            }
            let sent = try self.js(Scripts.sendNow)
            log("发送结果：\(sent)")
            if sent == "NO_TARGET" {
                throw BridgeError.failed("找不到发送按钮")
            }
            say("已经发给 AI 了", detail: "AI 正在读题目，通常要 1–3 分钟，请勿关闭", running: true)
            // 7. 等它写完，中途需要就点「继续」
            return try waitForReply()
        } else {
            say("已经填好了，请在窗口里按回车发送", running: false)
            return nil
        }
    }

    // MARK: - 等回复 / 抓代码

    /// 轮询回复区，直到内容不再变化；期间自动点「继续」
    /// 注意：点了不算数，必须验证页面内容真的涨了，否则记一次无效
    private func waitForReply(timeout: TimeInterval = 240) throws -> String? {
        // 用户要求：这个规模 10 分钟就是上限，10 分钟一到直接判失败，不再顺延。
        // 上一版把总上限放到 30 分钟，结果一次成功跑了 15 分钟，太长了。
        let hardDeadline = Date().addingTimeInterval(600)
        var deadline = hardDeadline
        // 发送后先给页面一点时间开始动
        Thread.sleep(forTimeInterval: 3.0)

        var lastTextLen = -1
        var lastCodeLen = -1
        var stableRounds = 0
        var clicksTried = 0
        var clicksIneffective = 0
        var lastStageKey = ""
        var loggedMain = false
        var endMarkRounds = 0
        var lastChangeAt = Date()

        func announce(_ key: String, _ title: String, _ detail: String = "") {
            guard key != lastStageKey else { return }
            lastStageKey = key
            say(title, detail: detail, running: true)
        }

        while Date() < deadline {
            if stopRequested {
                throw BridgeError.failed("已中止")
            }

            let raw = try self.js(Scripts.replyState)
            guard let data = raw.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                Thread.sleep(forTimeInterval: 2.0)
                continue
            }
            let generating = obj["generating"] as? Bool ?? false
            let hasContinue = obj["hasContinue"] as? Bool ?? false
            let blocks = obj["blocks"] as? Int ?? 0
            let pres = obj["pres"] as? Int ?? 0
            let codes = obj["codes"] as? Int ?? 0
            let codeLen = obj["codeLen"] as? Int ?? 0
            let textLen = obj["textLen"] as? Int ?? 0
            let hasSaveTail = obj["hasSaveTail"] as? Bool ?? false
            let hasEndMark = obj["hasEndMark"] as? Bool ?? false
            let looksComplete = obj["looksComplete"] as? Bool ?? false
            let afterLines = obj["afterLines"] as? Int ?? 0

            if textLen != lastTextLen || codeLen != lastCodeLen {
                lastChangeAt = Date()
                // 总上限就是 10 分钟：增长只影响“正在输出”的判断，不再延长总时间。
            }

            // 结束标记随时判定：即使 generating 还报 true（停止按钮残留 / 纯图标没认出来），
            // 只要标记连续两轮都在，就说明代码本身写完了，不用等到“没在生成”才认。
            // 下面的旧结束标记分支已删掉，避免一轮里重复计数、两轮变一轮。
            if hasEndMark {
                endMarkRounds += 1
                if endMarkRounds >= 2 {
                    log("看到结束标记 # ===LECTURE-END===，判定写完")
                    say("脚本写完了", detail: "正在把它取回来…", running: true)
                    return try grabScript()
                }
            } else {
                endMarkRounds = 0
            }

            // —— 统一播报（用户要求）：内部每轮判断增长，但状态框每 5 秒只报下面这一句，持续不断。
            // 不再有“正在写 / 正在读 / 快写完了”几套文案，也不再另起多套节奏。
            // 字数涨没涨，一看这句里的数字就知道；分段提示在下面点“继续”时会立刻报一次，
            // 下一轮播报（5 秒后）再接上这句，不会立刻盖掉分段提示。
            say("AI 正在思考…", detail: "代码目前 \(codeLen) 字，正在等它继续输出", running: true)
            if hasContinue {
                announce("continue-\(clicksTried)",
                         clicksTried == 0
                            ? "第 1 段写完了，正在请 AI 接着写第 2 段…"
                            : "第 \(clicksTried + 1) 段写完了，正在请 AI 接着往下写…",
                         "脚本比较长，AI 会分段写完，这是正常的")
            }

            if looksComplete && !loggedMain {
                loggedMain = true
                let which = hasSaveTail ? "末尾有 .save( 调用" : "末尾有 main() 收尾"
                log("代码出现收尾标志：\(which)")
            }

            // 还在流式输出 → 继续等，轮询步长统一为 5 秒（状态框播报也按这个步长来）
            if generating {
                stableRounds = 0
                clicksIneffective = 0
                lastTextLen = textLen
                lastCodeLen = codeLen
                Thread.sleep(forTimeInterval: 5.0)
                continue
            }

            // 被截断了 → 点继续，然后验证
            if hasContinue {
                stableRounds = 0

                if clicksIneffective >= 2 {
                    throw BridgeError.failed(
                        "AI 停下来之后没有继续写。可能到了长度上限，请再试一次。")
                }
                if clicksTried >= 5 {
                    throw BridgeError.failed("已经连续催了 5 次，AI 还是没有继续写，请再试一次。")
                }

                let before = textLen
                let r = try self.clickContinueButton()
                clicksTried += 1

                if r.hasPrefix("REAL_MOUSE") || r.hasPrefix("CLICKED:") {
                    log("点「继续」第 \(clicksTried) 次 → \(r)")
                    // DeepSeek 点完「继续」要先「想」一会儿才开始吐字，实测远超 3 秒。
                    // 等太短会把有效点击误判成无效，两次就直接抛错了。
                    var grew = false
                    for attempt in 0..<6 {
                        Thread.sleep(forTimeInterval: 2.0)
                        if let now = try? self.textLength(), now > before {
                            grew = true
                            log("继续生效（约 \(2 * (attempt + 1)) 秒后开始出字，涨了 \(now - before) 字）")
                            break
                        }
                    }
                    if grew {
                        clicksIneffective = 0
                        lastChangeAt = Date()
                        // 分段开始必须在状态框里留一句：第 1 段是原生的，第 1 次点“继续”就是第 2 段开始。
                        // 自动点“继续”本身不动（用户要求），一般最多 3 段、点两次，5 次上限只是兜底，不改。
                        // 点完后下一轮就是 5 秒播报重新开始，直到结束。
                        say("第 \(clicksTried + 1) 段开始生成", detail: "代码目前 \(codeLen) 字，正在等它继续输出",
                            running: true)
                    } else {
                        clicksIneffective += 1
                        log("点了 12 秒仍无新内容（无效 \(clicksIneffective)/2）")
                    }
                } else {
                    clicksIneffective += 1
                    log("点「继续」失败：\(r)")
                }

                lastTextLen = textLen
                lastCodeLen = codeLen
                Thread.sleep(forTimeInterval: 1.5)
                continue
            }

            // 【主判定】语义信号：脚本出现收尾标志，且代码块后面还有说明文字
            // （结束标记的判定已移到循环顶部，随时都做，这里不再重复计数。）
            if blocks > 0 && looksComplete && afterLines >= 3 {
                log("脚本收尾 + \(afterLines) 行说明，判定写完")
                say("脚本写完了", detail: "正在把它取回来…", running: true)
                return try grabScript()
            }

            // 【兜底判定】2026-10-25 的教训：旧代码“稳定 10 秒就按完成处理”，
            // 深度思考的思考间隙很容易超过 10 秒，结果抓到写了一半、字符串都没闭合的
            // 截断脚本（16216 字，第 368 行 SyntaxError），然后 Python 报错收场。
            // 新规则：稳定满 60 秒（5 秒一轮，共 12 轮），且必须同时有收尾标志（.save / main），才按完成处理；
            // 稳定满 60 秒但没有收尾标志，说明 AI 可能还在思考、也可能停了，
            // 但绝不擅自执行一段没收尾的代码，继续等到总上限，宁可报“没等到完整回答”，
            // 也不把截断脚本拿去执行。
            if blocks > 0 {
                if textLen == lastTextLen && codeLen == lastCodeLen {
                    stableRounds += 1
                    if stableRounds >= 12 {
                        if looksComplete {
                            log("内容稳定 60 秒且有收尾标志，按完成处理")
                            say("脚本看起来写完了", detail: "正在把它取回来…", running: true)
                            return try grabScript()
                        }
                        log("内容稳定 60 秒但未见收尾标志，继续等，不擅自执行截断脚本")
                        stableRounds = 0
                    }
                } else {
                    stableRounds = 0
                }
            } else {
                // 没有代码块：深度思考先想后写，75 秒太短，放到 180 秒再判“没给脚本”
                let idle = Date().timeIntervalSince(lastChangeAt)
                if idle > 180 {
                    throw BridgeError.failed(
                        "页面停住了，但没找到脚本（pre=\(pres) code=\(codes) 字数=\(textLen)）。"
                        + "可能是 AI 没有输出脚本。")
                }
                stableRounds = 0
            }

            // 思考提示已统一移到循环顶部，每 5 秒报一次，这里不再另起一套节奏。
            lastTextLen = textLen
            lastCodeLen = codeLen
            Thread.sleep(forTimeInterval: 5.0)
        }

        throw BridgeError.failed("等了 10 分钟仍未等到完整回答（没有结束标记、也没有收尾标志），没有擅自执行截断的脚本，请再试一次。")
    }

    /// 单独读一次正文长度，用于验证「继续」是否真的生效
    /// 必须用 textContent —— innerText 依赖布局，页面被判隐藏时会失真
    private func textLength() throws -> Int {
        let raw = try self.js("(document.body.textContent||'').length")
        return Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// 点「继续生成」
    /// 内置浏览器走真实 NSEvent 注入（isTrusted = true），Safari 只能走 JS。
    private func clickContinueButton() throws -> String {
        let raw = try self.js(Scripts.locateContinue)

        if raw == "NOT_FOUND" { return "NOT_FOUND" }
        if raw == "ZERO_SIZE" { return "ZERO_SIZE" }

        guard let data = raw.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let x = obj["x"] as? Double,
              let y = obj["y"] as? Double else {
            return "BAD_LOCATE:\(raw.prefix(60))"
        }

        if engine == .webview {
            var ok = false
            DispatchQueue.main.sync {
                ok = self.browser.clickAtViewportPoint(x: CGFloat(x), y: CGFloat(y))
            }
            if ok {
                return String(format: "REAL_MOUSE(%.0f,%.0f)", x, y)
            }
            let js = try self.js(Scripts.clickContinue)
            return "FALLBACK_JS:\(js.prefix(80))"
        }

        let js = try self.js(Scripts.clickContinue)
        return "SAFARI_JS:\(js.prefix(120))"
    }

    /// 把页面上的代码块取回来，挑出最像「生成讲义」的那段
    func grabScript() throws -> String? {
        let lenRaw = try self.js(Scripts.grabBlocksBuild)
        guard let total = Int(lenRaw.trimmingCharacters(in: .whitespacesAndNewlines)),
              total > 0 else {
            log("页面上没有找到代码块")
            return nil
        }

        var encoded = ""
        encoded.reserveCapacity(total)
        let step = 40000
        var index = 0
        while index < total {
            let end = min(index + step, total)
            encoded += try self.js(Scripts.grabBlocksChunk(from: index, to: end))
            index = end
        }

        guard let json = encoded.removingPercentEncoding,
              let data = json.data(using: .utf8),
              let blocks = (try? JSONSerialization.jsonObject(with: data)) as? [String],
              !blocks.isEmpty else {
            log("代码块解码失败")
            return nil
        }
        log("抓到 \(blocks.count) 个代码块，总长 \(blocks.reduce(0) { $0 + $1.count }) 字符")

        let joined = blocks.map { "```python\n\($0)\n```" }.joined(separator: "\n\n")
        return ScriptExtractor.extract(from: joined)
    }

    // MARK: - 工具

    /// 用户点了「中止」就在下一个检查点退出
    private func checkStop() throws {
        if stopRequested { throw BridgeError.failed("已中止") }
    }

    private func feed(index: Int, data: Data) throws {
        let base64 = data.base64EncodedString()
        let step = 96000
        var cursor = base64.startIndex
        while cursor < base64.endIndex {
            let end = base64.index(cursor, offsetBy: step, limitedBy: base64.endIndex)
                ?? base64.endIndex
            let chunk = String(base64[cursor..<end])
            _ = try self.js(Scripts.appendChunk(index: index, chunk: chunk))
            cursor = end
        }
    }

    private func waitFor(names: [String], timeout: TimeInterval) throws -> [String] {
        let deadline = Date().addingTimeInterval(timeout)
        var missing = names
        while Date() < deadline {
            if stopRequested { throw BridgeError.failed("已中止") }
            let raw = try self.js(Scripts.checkNames(namesJSON: jsonString(names)))
            if let data = raw.data(using: .utf8),
               let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let list = obj["missing"] as? [String] {
                missing = list
                if list.isEmpty { return [] }
            }
            Thread.sleep(forTimeInterval: 1.0)
        }
        return missing
    }

    private func jsonString(_ obj: Any) -> String {
        // fragmentsAllowed 才能序列化顶层的字符串，否则传 String 会抛异常把 App 打死
        guard let data = try? JSONSerialization.data(
                withJSONObject: obj, options: .fragmentsAllowed),
              let text = String(data: data, encoding: .utf8) else {
            return "null"
        }
        return text
    }
}
