import Foundation

/// 内置 Python 运行时的执行结果
struct RunResult {
    var exitCode: Int32
    var output: String          // stdout + stderr 合并
    var producedFiles: [URL]    // 本次运行真正写出的文件（按 mtime 过滤）
    var workDir: URL
    var scriptURL: URL
    var timedOut: Bool
    var cancelled: Bool = false

    var ok: Bool { exitCode == 0 && !timedOut && !cancelled }
}

/// 用 App 内自带的 CPython 执行 AI 生成的脚本，产出 docx。
/// 设计要点：
/// 1. 完全不碰用户脚本内容（不注入、不改 shebang），靠 launcher + runpy 执行
/// 2. 用猴补丁拦截 Document.save，精确记录生成的文件
/// 3. 工作目录是临时沙盒，脚本里写相对路径也不会污染别处
/// 4. 支持从外部叫停（用户点「中止」）
enum PythonRunner {

    /// 当前正在跑的进程，供「中止」按钮直接掐掉
    private static let lock = NSLock()
    private static var currentTask: Process?
    private static var cancelRequested = false

    static func cancelCurrent() {
        lock.lock()
        cancelRequested = true
        let task = currentTask
        lock.unlock()
        guard let task = task, task.isRunning else { return }
        task.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if task.isRunning { kill(task.processIdentifier, SIGKILL) }
        }
    }


    /// bundle 内的解释器
    static var executable: URL? {
        guard let res = Bundle.main.resourceURL else { return nil }
        let url = res.appendingPathComponent("python/bin/python3.12")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    static var isAvailable: Bool { executable != nil }

    /// 运行时体积，用于界面展示
    static var sizeDescription: String {
        guard let exe = executable else { return "未内置" }
        let root = exe.deletingLastPathComponent().deletingLastPathComponent()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        task.arguments = ["-sh", root.path]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        try? task.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        return text.split(separator: "\t").first.map(String.init) ?? "—"
    }

    // MARK: - 执行

    /// - Parameter assets: 从考卷/答案里抽出来的图片，会写进工作目录的 `assets/`，
    ///   供成品回填阶段使用。脚本本身看不到它们（不注入任何提示），互不干扰。
    static func run(script: String, assets: [DocxImage] = [], timeout: TimeInterval = 240) throws -> RunResult {
        guard let py = executable else {
            throw BridgeError.failed("App 内没有找到 Python 运行时")
        }

        let fm = FileManager.default
        let stamp = Int(Date().timeIntervalSince1970)
        let workDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("讲义生成-run-\(stamp)")
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)

        // 图片放在工作目录的 assets/ 下，回填脚本按相对路径取，跟用户脚本的 cwd 一致
        if !assets.isEmpty {
            let assetDir = workDir.appendingPathComponent("assets")
            try? fm.createDirectory(at: assetDir, withIntermediateDirectories: true)
            for image in assets {
                try? image.data.write(to: assetDir.appendingPathComponent(image.fileName))
            }
        }

        // 用户脚本
        let scriptURL = workDir.appendingPathComponent("生成讲义.py")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        // 前置补丁：拦截保存动作
        let prelude = workDir.appendingPathComponent("_wb_prelude.py")
        try preludeText.write(to: prelude, atomically: true, encoding: .utf8)

        // 启动器
        let launcher = workDir.appendingPathComponent("_wb_launch.py")
        try launcherText.write(to: launcher, atomically: true, encoding: .utf8)

        let manifest = workDir.appendingPathComponent("_wb_manifest.txt")
        fm.createFile(atPath: manifest.path, contents: nil)

        let logURL = workDir.appendingPathComponent("_wb_output.txt")
        fm.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: logURL)

        let startedAt = Date()

        let task = Process()
        task.executableURL = py
        task.arguments = [launcher.path]
        task.currentDirectoryURL = workDir

        var env = ProcessInfo.processInfo.environment
        env["PYTHONNOUSERSITE"] = "1"        // 不读用户的 ~/.local 包
        env["PYTHONIOENCODING"] = "utf-8"
        env["PYTHONDONTWRITEBYTECODE"] = "1" // 不留 __pycache__
        env["PYTHONUNBUFFERED"] = "1"
        env["WB_MANIFEST"] = manifest.path
        env["PATH"] = py.deletingLastPathComponent().path + ":/usr/bin:/bin:/usr/sbin:/sbin"
        // 清掉可能干扰的外部 Python 变量
        env.removeValue(forKey: "PYTHONHOME")
        env.removeValue(forKey: "PYTHONPATH")
        env.removeValue(forKey: "VIRTUAL_ENV")
        task.environment = env

        task.standardOutput = logHandle
        task.standardError = logHandle
        task.standardInput = FileHandle.nullDevice

        lock.lock()
        cancelRequested = false
        currentTask = task
        lock.unlock()
        defer {
            lock.lock()
            currentTask = nil
            lock.unlock()
        }

        try task.run()

        // 带超时 + 可叫停的等待
        var timedOut = false
        let deadline = Date().addingTimeInterval(timeout)
        while task.isRunning {
            if Date() > deadline {
                timedOut = true
                task.terminate()                    // SIGTERM
                Thread.sleep(forTimeInterval: 2)
                if task.isRunning { kill(task.processIdentifier, SIGKILL) }
                break
            }
            lock.lock()
            let cancelled = cancelRequested
            lock.unlock()
            if cancelled {
                task.terminate()
                Thread.sleep(forTimeInterval: 2)
                if task.isRunning { kill(task.processIdentifier, SIGKILL) }
                break
            }
            Thread.sleep(forTimeInterval: 0.15)
        }
        task.waitUntilExit()
        try? logHandle.close()

        lock.lock()
        let wasCancelled = cancelRequested
        lock.unlock()

        let output = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""

        // 收集产物：先看 manifest，再用 mtime 兜底
        var seen = Set<String>()
        var produced: [URL] = []
        let allowed: Set<String> = ["docx", "doc", "md", "txt", "pdf", "py"]

        func consider(_ url: URL) {
            let path = url.standardizedFileURL.path
            guard !seen.contains(path), fm.fileExists(atPath: path) else { return }
            guard path.hasPrefix(workDir.path) else { return }
            let name = url.lastPathComponent
            guard !name.hasPrefix("_wb_") else { return }
            guard allowed.contains(url.pathExtension.lowercased()) else { return }
            // 只认本次运行期间写出的文件
            if let attrs = try? fm.attributesOfItem(atPath: path),
               let mtime = attrs[.modificationDate] as? Date,
               mtime >= startedAt.addingTimeInterval(-2) {
                seen.insert(path)
                produced.append(url)
            }
        }

        if let list = try? String(contentsOf: manifest, encoding: .utf8) {
            for line in list.split(separator: "\n") {
                let p = line.trimmingCharacters(in: .whitespaces)
                if !p.isEmpty { consider(URL(fileURLWithPath: p)) }
            }
        }
        if let en = fm.enumerator(at: workDir, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for case let url as URL in en { consider(url) }
        }
        produced.sort { $0.lastPathComponent < $1.lastPathComponent }

        return RunResult(exitCode: task.terminationStatus,
                         output: output,
                         producedFiles: produced,
                         workDir: workDir,
                         scriptURL: scriptURL,
                         timedOut: timedOut,
                         cancelled: wasCancelled)
    }

    /// 在已经跑完的工作目录里再执行一段辅助脚本（成品回填图片）。
    /// 不收集产物、不碰 manifest —— 主脚本的结果已经拿到了，这里只补图。
    @discardableResult
    static func runAux(script: String,
                       in workDir: URL,
                       timeout: TimeInterval = 120) throws -> (code: Int32, output: String) {
        guard let py = executable else {
            throw BridgeError.failed("App 内没有找到 Python 运行时")
        }
        let fm = FileManager.default
        let scriptURL = workDir.appendingPathComponent("_wb_backfill.py")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        let logURL = workDir.appendingPathComponent("_wb_backfill.log")
        fm.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: logURL)
        defer { try? logHandle.close() }

        let task = Process()
        task.executableURL = py
        task.arguments = [scriptURL.path]
        task.currentDirectoryURL = workDir

        var env = ProcessInfo.processInfo.environment
        env["PYTHONNOUSERSITE"] = "1"
        env["PYTHONIOENCODING"] = "utf-8"
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        env["PYTHONUNBUFFERED"] = "1"
        env["PATH"] = py.deletingLastPathComponent().path + ":/usr/bin:/bin:/usr/sbin:/sbin"
        env.removeValue(forKey: "PYTHONHOME")
        env.removeValue(forKey: "PYTHONPATH")
        env.removeValue(forKey: "VIRTUAL_ENV")
        task.environment = env
        task.standardOutput = logHandle
        task.standardError = logHandle
        task.standardInput = FileHandle.nullDevice

        try task.run()

        let deadline = Date().addingTimeInterval(timeout)
        while task.isRunning {
            if Date() > deadline {
                task.terminate()
                Thread.sleep(forTimeInterval: 2)
                if task.isRunning { kill(task.processIdentifier, SIGKILL) }
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        task.waitUntilExit()

        let output = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        return (task.terminationStatus, output)
    }

    /// 成品回填脚本：把模型写的「[图片缺失]」之类标记换成真图。
    /// 实测模型标的位置是准的（三处全对，含表格里那张），这里只负责按顺序填。
    static func backfillScript(docxName: String) -> String {
        backfillTemplate.replacingOccurrences(of: "%%DOCX%%", with: docxName)
    }

    private static let backfillTemplate = #"""
    # -*- coding: utf-8 -*-
    # 讲义生成 App 注入的回填脚本：把 [图片缺失] 之类的占位标记换成 assets/ 里的真图
    import glob, os, re
    from docx import Document
    from docx.shared import Emu
    from docx.enum.text import WD_ALIGN_PARAGRAPH
    from docx.image.image import Image
    from docx.oxml.ns import qn
    from docx.table import Table
    from docx.text.paragraph import Paragraph

    TARGET = "%%DOCX%%"
    ASSET_DIR = "assets"
    DPI = 96.0

    # 模型输出的标记格式不稳定，实测见过两种：
    #   [图片缺失]
    #   [图1：阅览室拟议布局图（原文配有草图）]
    # 所以认两类：整段被方括号包住的「图」标记，或整段就是一句缺失说明。
    # 只认整段，不做子串匹配 —— 正文里提到「图」的句子不能被误删。
    BRACKETED = re.compile(r'^\s*[\[【（(]\s*(?:图\s*\d+|图片|插图|图像)[^\n]{0,120}?[\]】）)]\s*$', re.I)
    PLAIN = re.compile(
        r'^\s*[\[【（(]?\s*(?:图片缺失|图片无法显示|图片未显示|图片略|此处略|'
        r'image\s*missing|missing\s*image|no\s*image)\s*[\]】）)]?\s*$', re.I)


    def is_mark(text):
        return bool(BRACKETED.match(text) or PLAIN.match(text))


    def numbered(paths):
        def key(p):
            m = re.search(r'图\s*(\d+)', os.path.basename(p))
            return (int(m.group(1)) if m else 10 ** 6, p)
        return sorted(paths, key=key)


    def iter_paras(doc):
        # 必须按文档流真实顺序走：先 doc.paragraphs 再表格，会把「正文-表格-正文」
        # 重排成「正文-正文-表格」，图片顺序跟着错。这里按 body 子元素递归。
        seen = set()

        def walk(parent, elm):
            for child in elm.iterchildren():
                if child.tag == qn('w:p'):
                    yield Paragraph(child, parent)
                elif child.tag == qn('w:tbl'):
                    tbl = Table(child, parent)
                    for row in tbl.rows:
                        for cell in row.cells:
                            key = id(cell._tc)
                            if key in seen:      # 合并单元格会重复返回同一个 tc
                                continue
                            seen.add(key)
                            for p in walk(cell, cell._tc):
                                yield p

        for p in walk(doc, doc.element.body):
            yield p


    def clear(p):
        for r in list(p.runs):
            r._element.getparent().remove(r._element)


    def main():
        if not os.path.exists(TARGET):
            print("[回填] 找不到成品：%s" % TARGET)
            return
        files = numbered(glob.glob(os.path.join(ASSET_DIR, "图*.*")))
        if not files:
            print("[回填] 没有图片可填，跳过")
            return

        doc = Document(TARGET)
        sec = doc.sections[0]
        avail = Emu(int(sec.page_width - sec.left_margin - sec.right_margin))

        used = dropped = 0
        for p in iter_paras(doc):
            text = p.text.strip()
            if not text or not is_mark(text):
                continue
            if used >= len(files):
                clear(p)
                dropped += 1
                continue
            path = files[used]
            try:
                info = Image.from_file(path)
                natural = Emu(int(info.width * 72.0 / DPI))
            except Exception as exc:
                print("[回填] 读不了 %s（%s），跳过" % (os.path.basename(path), exc))
                clear(p)
                dropped += 1
                continue
            clear(p)
            p.alignment = WD_ALIGN_PARAGRAPH.CENTER
            p.paragraph_format.first_line_indent = Emu(0)
            try:
                p.add_run().add_picture(path, width=min(natural, avail))
                used += 1
                print("[回填] %s → 第 %d 处" % (os.path.basename(path), used))
            except Exception as exc:
                print("[回填] 插入失败 %s（%s）" % (os.path.basename(path), exc))
                dropped += 1
        try:
            doc.save(TARGET)
            print("[回填] 完成：插入 %d 张，清理 %d 处多余标记" % (used, dropped))
        except Exception as exc:
            print("[回填] 保存失败（文件可能正被 Word 打开）：%s" % exc)


    main()
    """#

    // MARK: - 脚本片段

    /// 运行在用户脚本之前：拦截所有「保存文件」的动作，写进 manifest
    private static let preludeText = #"""
    # -*- coding: utf-8 -*-
    # 讲义生成 App 注入的前置补丁：记录脚本写出的文件，不改动脚本本身
    import os, sys, atexit

    _MANIFEST = os.environ.get("WB_MANIFEST")

    def _record(path):
        try:
            p = os.path.abspath(os.fspath(path))
        except Exception:
            return path
        if _MANIFEST:
            try:
                with open(_MANIFEST, "a", encoding="utf-8") as f:
                    f.write(p + "\n")
            except Exception:
                pass
        return p

    # 1) python-docx：Document.save
    try:
        import docx.document as _dd
        _orig_save = _dd.Document.save
        def _save(self, path, *a, **kw):
            return _orig_save(self, _record(path), *a, **kw)
        _dd.Document.save = _save
    except Exception as _e:
        sys.stderr.write("[内置运行器] 未能挂接 python-docx：%r\n" % (_e,))

    # 2) 兜底：退出时扫描工作目录
    def _sweep():
        root = os.getcwd()
        for dirpath, _dirs, files in os.walk(root):
            for fn in files:
                if fn.lower().endswith((".docx", ".doc", ".pdf")):
                    _record(os.path.join(dirpath, fn))
    atexit.register(_sweep)
    """#

    private static let launcherText = #"""
    # -*- coding: utf-8 -*-
    import os, sys, runpy
    _here = os.path.dirname(os.path.abspath(__file__))
    sys.path.insert(0, _here)

    # 先执行前置补丁
    _prelude = os.path.join(_here, "_wb_prelude.py")
    if os.path.exists(_prelude):
        with open(_prelude, "r", encoding="utf-8") as f:
            exec(compile(f.read(), _prelude, "exec"), {"__name__": "__wb_prelude__"})

    _script = os.path.join(_here, "生成讲义.py")
    sys.argv = [_script]
    runpy.run_path(_script, run_name="__main__")
    """#
}
