import Foundation
import AppKit

private struct UploadItem {
    var url: URL
    var name: String
    var mime: String
}

extension AppState {

    static let promptText = """
    我传给你了 4 个文件，分别是《标准模式讲义.docx》、《讲义制作规则.md》、【考卷】、和【答案】。请先自行读懂这 4 个附件的内容：【考卷】和【答案】的文件命名可能不太规范，按内容和角色判断即可，不要只看文件名。

    读懂之后，按《讲义制作规则.md》执行，版式照《标准模式讲义.docx》；规则没写到的地方，从样本里参照模仿。

    因为现在是网页版，无法直接输出文件，请你给出完整的 Python 脚本，用户会自己执行。

    补充说明（用户的环境）：Python 3.12，已装好 python-docx，没有其他第三方库；脚本要能一次跑完，不要用 input() 等待键盘输入；最后用 save() 把成品存成 .docx，文件名用中文、能看出是哪份讲义。

    【格式要求，非常重要】代码的最后一行必须原样写上这一行注释：
    # ===LECTURE-END===
    这一行必须是代码框里的最后一行，它之后不能再有任何代码。这是用户用来判断代码是否输出完整的标记，请务必保留、不要改动、不要省略。

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
        lastLogAt = nil          // 新一轮从零计时，别把上一轮的间隔带过来
        docx = .idle
        // 测试期：开跑就把日志摊开，跑的过程中能一直看着（正式行为是 false）
        if Self.autoOpenLogWhileTesting { openLog() }

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

        // 0. 开新对话。内置浏览器走三档，从最省事往下退：
        //
        //   ① 页面已经停在根地址 → 什么都不做。App 第一次打开、刚登录、上一轮没发出去，
        //      都落在这里 —— 本来就是空对话，按 ⌘J 或重载都是多余的。
        //   ② 停在会话页（/a/chat/s/<id>）→ 按 ⌘J。它只切 SPA 里的会话，不重载页面，
        //      比 reload 快 2~4 秒。走真实 NSEvent 注入，和「继续生成」是同一条路
        //      （见 BrowserController.sendCommandKey）。
        //   ③ ⌘J 按了没反应 / 页面没加载完 → 重载根地址。
        //
        // 以前这里是每次无条件重载根地址，因为「点页面上的『开启新对话』按钮」从
        // 作文版 v0.12 到 v0.20 一次都没点中过（每轮日志都是 NOT_FOUND）。
        // 重载那条路留着当兜底：绝不能在旧对话里继续提问，否则上一轮上下文会串味。
        say("正在准备新对话…", detail: "重置页面中，稍等几秒", running: true)
        if engine == .webview {
            switch browser.newChatByShortcut() {
            case .alreadyFresh:
                // App 刚启动、刚登录、上一轮没发出去 —— 页面就停在根地址，本来就是空对话。
                log("页面已在根地址，本来就是新对话，跳过重置")
            case .shortcut(let seconds):
                log("⌘J 开新对话：\(String(format: "%.1f", seconds)) 秒")
                // 地址栏变了不代表 DOM 已经换完（SPA 切会话是异步渲染）。
                // 稍等一下再往里塞附件，免得塞进上一轮那个还没拆掉的输入框。
                Thread.sleep(forTimeInterval: 1.2)
            case .failed:
                log("⌘J 没换掉会话，回退重载根地址")
                // loadDeepSeek 里有 NSWindow 操作，必须回主线程。但它是异步的，
                // 等它跑起来再轮询标志的话，读到的是上一轮的 true —— 循环立刻退出，
                // 日志里就是「用时 0.0 秒」，等于没等。所以先把标志同步打回 false 再派发。
                browser.markReloading()
                DispatchQueue.main.async { [weak self] in self?.browser.loadDeepSeek(force: true) }
                var waited = 0.0
                while !browser.isPageLoaded && waited < 25 {
                    try checkStop()
                    Thread.sleep(forTimeInterval: 0.25)
                    waited += 0.25
                }
                log("页面重载：\(String(format: "%.1f", waited)) 秒")
                if !browser.isPageLoaded {
                    log("⚠️ 25 秒内没等到页面加载完成，继续尝试（后面探针会暴露真实状态）")
                }
            }
        } else {
            // Safari 模式没法从 App 里注入键盘事件（跨进程），只能让它重新打开一次根地址
            SafariBridge.openDeepSeek()
            Thread.sleep(forTimeInterval: 3.0)
            log("已在 Safari 里重新打开根地址")
        }

        // didFinish 只说明文档到了，SPA 还没渲染完。以前是固定睡 1.5 秒赌一把，
        // 现在直接等输入框真的出现 —— 快的时候几百毫秒就过，慢的时候也不会白等。
        var ready = 0.0
        while ready < 10 {
            try checkStop()
            let p = (try? self.js(Scripts.probeComposer)) ?? ""
            if p.contains("\"textarea\":true") { break }
            Thread.sleep(forTimeInterval: 0.4)
            ready += 0.4
        }
        if ready > 0 { log("等输入框出现：\(String(format: "%.1f", ready)) 秒") }

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

        // 5. 先清空输入框，再填提示词。
        // 网页版收到附件后会把文件名当文字塞进输入框（HANDOVER §6.9，作文版实测截图），
        // 不清的话提示词前面会挂着「IMG_3435.jpeg 未标题-1.png」这一串。
        // 顺序必须是「先等附件就位 → 再清 → 再填」：清早了网页还会补回来。
        _ = try fillPrompt(prompt)

        // 6. 发送
        if auto {
            try checkStop()
            for second in stride(from: 4, through: 1, by: -1) {
                say("马上开始生成…", detail: "\(second) 秒后自动发送，不用你操作",
                    fraction: 0.75, running: true)
                Thread.sleep(forTimeInterval: 1.0)
            }
            // 发送前再确认一次：万一这几秒里网页又把文件名补进输入框，重填一遍。
            // 只做回读比对，一致就不动输入框（无谓地清空重填反而多一次竞态）。
            if try self.js(Scripts.readText).trimmingCharacters(in: .whitespacesAndNewlines)
                != prompt.trimmingCharacters(in: .whitespacesAndNewlines) {
                log("发送前回读不一致，重填提示词")
                _ = try fillPrompt(prompt)
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

    /// 清空输入框 → 填入提示词 → 回读校验。对不上就再来一次（最多两次）。
    /// 回读这一步是关键：网页插入文件名是异步的，只靠「填完就当成功」会漏。
    /// 返回 true 表示回读与提示词完全一致。
    @discardableResult
    private func fillPrompt(_ prompt: String) throws -> Bool {
        for attempt in 1...2 {
            _ = try self.js(Scripts.clearText)
            // 清完稍等一下，让网页那边的 React 状态落定，否则它可能把我们填的又盖掉
            Thread.sleep(forTimeInterval: attempt == 1 ? 0.35 : 0.8)

            let filled = try self.js(Scripts.fillText(textJSON: jsonString(prompt)))
            guard filled.hasPrefix("OK") else {
                throw BridgeError.failed("文字填不进去：\(filled)")
            }

            let back = try self.js(Scripts.readText)
            if sameText(back, prompt) {
                log("提示词已填入并回读一致（\(prompt.count) 字）")
                return true
            }
            log("第 \(attempt) 次填入后回读不一致：输入框 \(back.count) 字 / 应为 \(prompt.count) 字，清空重填")
        }
        // 两次都对不上就不再硬失败 —— 内容已经在框里，多出来的无非是文件名，AI 自己能认出来
        log("⚠️ 提示词回读仍不一致，按当前内容发送")
        say("提示词已填入", detail: "输入框内容和预期略有出入，仍按此发送", fraction: 0.7, running: true)
        return false
    }

    /// 回读比对用的相等判断。只忽略首尾空白 —— 输入框偶尔会多一个尾随换行，
    /// 那不是问题，不该为它触发一次重填。
    private func sameText(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespacesAndNewlines)
            == b.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 等回复 / 抓代码

    /// 等 AI 写完的总上限（秒）。**全 App 只有这一处定义**，改时长只改这里。
    /// 用户 2026-10-26 定：这个规模 10 分钟就是上限，一到就判失败，不再顺延。
    /// 上一版把总上限放到 30 分钟，结果一次成功跑了 15 分钟，太长了。
    private static let replyDeadline: TimeInterval = 600

    /// 轮询回复区，直到内容不再变化；期间自动点「继续」
    /// 注意：点了不算数，必须验证页面内容真的涨了，否则记一次无效
    private func waitForReply() throws -> String? {
        // 以前签名上挂了个 `timeout: TimeInterval = 240` 的参数，但函数体压根不读它
        // （直接写死 600），谁想改时长都会白改。2026-10-27 删掉，只留 replyDeadline。
        let deadline = Date().addingTimeInterval(Self.replyDeadline)
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

            // —— 统一播报（用户要求）：内部每轮判断增长，但状态框每轮只报下面这一句，持续不断。
            // 不再有“正在写 / 正在读 / 快写完了”几套文案，也不再另起多套节奏。
            // 字数涨没涨，一看这句里的数字就知道；分段提示在下面点“继续”时会立刻报一次，
            // 下一轮播报再接上这句，不会立刻盖掉分段提示。
            // 还没出现真的代码框、字数还是 0 时，别报“代码目前 0 字”，看着着急。
            // 先报思考中，直到代码框出现且字数大于 0，才恢复原来的代码字数播报。
            if blocks > 0 && codeLen > 0 {
                say("AI 正在思考…", detail: "代码目前 \(codeLen) 字，正在等它继续输出", running: true)
            } else {
                say("DeepSeek 正在认真思考", detail: "代码即将呈现", running: true)
            }
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

                // ⚠️ 2026-10-29 实测踩到的坑（试卷识别 app 同步过来）：文字还在长，
                // 说明其实正在生成，但「继续生成」按钮可能仍挂在 DOM 上
                // （停止按钮是纯图标，generating 认不出来），这时点下去会落到
                // 同一位置的「停止」上，把刚恢复的生成掐死。
                // 日志证据：点完继续 1.6 秒后又点了一次 → 之后 24 秒一个字没涨 → 失败。
                // 所以：最近 4 秒内还在涨字，就绝不点，老老实实等它写完。
                if Date().timeIntervalSince(lastChangeAt) < 4.0 {
                    lastTextLen = textLen
                    lastCodeLen = codeLen
                    Thread.sleep(forTimeInterval: 1.0)
                    continue
                }

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

                    // 【2026-10-29】判据换了：不看「12 秒内有没有涨字」，看「按钮有没有消失」。
                    //
                    // 用户实测：手点下去按钮**瞬间消失**，绝不会变成「停止」。
                    // 而 AI 点完「继续」要先重新想十几秒才出字，用「涨字」当判据
                    // 会把有效点击误判成无效、多点一次，把生成掐死。
                    //
                    // probeY：只认刚点的那个位置，别把历史消息残留的旧按钮算进来。
                    let probeY = self.clickedY(from: r)
                    var buttonGone = false
                    for _ in 0..<3 {
                        Thread.sleep(forTimeInterval: 0.2)
                        if let gone = try? self.continueButtonGone(nearY: probeY), gone {
                            buttonGone = true
                            break
                        }
                    }

                    if buttonGone {
                        log("按钮已消失，点击被页面接受")
                        // 点击成功后就安心等它出字。实测最长 12 秒以上，这里给 24 秒。
                        // 6 秒后开始顺带盯按钮：AI 有时只写两三百字又截断，
                        // 按钮几秒内会重新出现，死等 24 秒纯属白耗。
                        var grew = false
                        for attempt in 0..<12 {
                            Thread.sleep(forTimeInterval: 2.0)
                            if let now = try? self.textLength(), now > before {
                                grew = true
                                log("继续生效（约 \(2 * (attempt + 1)) 秒后开始出字，涨了 \(now - before) 字）")
                                break
                            }
                            if attempt >= 2, let back = try? self.continueButtonGone(nearY: probeY), !back {
                                log("按钮又出现了（等了 \(2 * (attempt + 1)) 秒没出字），AI 又停住了，交给下一轮再催")
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
                            // 按钮消失了却没出字：点击是有效的，只是 AI 还在想。
                            // 绝不能重复点击（会掐死生成），交给外层循环和总超时兜底。
                            log("按钮已消失但 24 秒未见新内容，继续等，不重复点击")
                        }
                    } else {
                        // 按钮还在 = 这次点击被吞了（窗口刚激活 / 页面没有 hover 状态）。
                        // 立刻补一次，不用干等 12 秒。
                        clicksIneffective += 1
                        log("点了 0.6 秒按钮仍在，这次点击被吞了（无效 \(clicksIneffective)/2）")
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
            //
            // 2026-10-27 用户定：**不必等 60 秒**。理由是到目前为止结束标志从未失手，
            // 60 秒纯属白等。改成「一轮没长 + 有收尾标志」就收工（循环 3 秒一轮，即约 3 秒）。
            // 仍保留两条底线：① 没有收尾标志时绝不执行，继续等；② 总上限 10 分钟不变。
            if blocks > 0 {
                if textLen == lastTextLen && codeLen == lastCodeLen {
                    stableRounds += 1
                    if looksComplete && stableRounds >= 1 {
                        log("内容 3 秒未变且有收尾标志，按完成处理")
                        say("脚本看起来写完了", detail: "正在把它取回来…", running: true)
                        return try grabScript()
                    }
                    // 没有收尾标志：攒够 60 秒（20 轮 × 3 秒）提示一次，然后继续等
                    if stableRounds >= 20 {
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

            // 思考提示已统一移到循环顶部，每轮报一次，这里不再另起一套节奏。
            lastTextLen = textLen
            lastCodeLen = codeLen
            // 3 秒一轮（原来是 5 秒）：兜底判定要「一轮没长」≈3 秒就收工，
            // 轮间隔必须跟着缩，否则「3 秒」实际是 5 秒。轮数阈值也按 3 秒重算过。
            Thread.sleep(forTimeInterval: 3.0)
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
    ///
    /// 2026-10-29 加了两道保险（用户实测：手点 0.1–0.2 秒就继续、按钮瞬间消失）：
    /// ① 坐标只在按钮**已经在视口内**时才取，需要滚动就先返回 SCROLLING 等滚完再取；
    /// ② 点之前做 `elementFromPoint` 命中测试，命中元素不是按钮就绝不下手。
    private func clickContinueButton() throws -> String {
        var lastRaw = "NOT_TRIED"

        for attempt in 0..<4 {
            let raw = try self.js(Scripts.locateContinue)
            lastRaw = raw

            // 页面刚滚动过，坐标还不作数 —— 等它停稳再取一次
            if raw == "SCROLLING" {
                log("「继续」按钮不在视口内，滚动后重新取坐标（\(attempt + 1)/4）")
                Thread.sleep(forTimeInterval: 0.45)
                continue
            }

            // 按钮被别的东西盖住 / 正在淡出 —— 等一下再看，不算一次失败
            if raw.hasPrefix("NOT_HIT") {
                log("「继续」按钮命中测试未通过（\(raw)），\(attempt < 3 ? "稍后重试" : "放弃")")
                if attempt < 3 { Thread.sleep(forTimeInterval: 0.5) }
                continue
            }

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

        return "LOCATE_UNSTABLE:\(lastRaw.prefix(60))"
    }

    /// 「继续」按钮还在不在（只探测，不滚动、不点击、无副作用）
    ///
    /// `nearY` 是刚才点击时的视口 y。只检查这个位置附近的按钮，
    /// 避免历史消息里残留的旧「继续生成」被当成「按钮还在」。
    private func continueButtonGone(nearY: Double?) throws -> Bool {
        let raw = try self.js(Scripts.probeContinue(nearY: nearY))
        return raw.trimmingCharacters(in: .whitespacesAndNewlines) == "NO"
    }

    /// 从 `REAL_MOUSE(123,456)` 里取出点击时的 y 坐标
    private func clickedY(from result: String) -> Double? {
        let prefix = "REAL_MOUSE("
        guard result.hasPrefix(prefix) else { return nil }
        guard let close = result.firstIndex(of: ")") else { return nil }
        let inner = result[result.index(result.startIndex, offsetBy: prefix.count)..<close]
        let parts = inner.split(separator: ",")
        guard parts.count == 2, let y = Double(parts[1].trimmingCharacters(in: .whitespaces)) else {
            return nil
        }
        return y
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
