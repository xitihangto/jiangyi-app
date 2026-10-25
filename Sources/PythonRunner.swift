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

    static func run(script: String, timeout: TimeInterval = 240) throws -> RunResult {
        guard let py = executable else {
            throw BridgeError.failed("App 内没有找到 Python 运行时")
        }

        let fm = FileManager.default
        let stamp = Int(Date().timeIntervalSince1970)
        let workDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("讲义生成-run-\(stamp)")
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)

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
