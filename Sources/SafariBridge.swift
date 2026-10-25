import Foundation
import AppKit

enum BridgeError: LocalizedError {
    case denied
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .denied:
            return "未获得控制 Safari 的权限"
        case .failed(let m):
            return m
        }
    }
}

/// 通过 AppleScript 操作 Safari。
/// 注意：所有 JS 都以单行传入 AppleScript 字符串字面量，换行会被压成空格。
enum SafariBridge {

    // MARK: - 转义

    static func escapeForAppleScript(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count + 128)
        for ch in s {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n", "\r", "\t": out += " "
            default: out.append(ch)
            }
        }
        return out
    }

    // MARK: - 执行

    static func run(_ source: String) throws -> String {
        var info: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            throw BridgeError.failed("无法构造 AppleScript")
        }
        let desc = script.executeAndReturnError(&info)
        if let info = info {
            let num = (info[NSAppleScript.errorNumber] as? Int) ?? 0
            let msg = (info[NSAppleScript.errorMessage] as? String) ?? "未知错误"
            if num == -1743 || num == -10004 {
                throw BridgeError.denied
            }
            throw BridgeError.failed("AppleScript \(num)：\(msg)")
        }
        return desc.stringValue ?? ""
    }

    /// 在前台标签页里执行 JS。返回特殊标记表示前置条件不满足。
    static func doJS(_ js: String) throws -> String {
        let code = escapeForAppleScript(js)
        let src = """
        on run
            if application "Safari" is not running then return "__NO_SAFARI__"
            tell application "Safari"
                if (count of windows) is 0 then return "__NO_WINDOW__"
                set t to current tab of front window
                set u to (URL of t) as text
                if u does not contain "deepseek" then return "__WRONG_PAGE__" & u
                return (do JavaScript "\(code)" in t)
            end tell
        end run
        """
        return try run(src)
    }

    // MARK: - 打开

    static func openDeepSeek() {
        guard let url = URL(string: "https://chat.deepseek.com/") else { return }
        let safari = URL(fileURLWithPath: "/Applications/Safari.app")
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: safari, configuration: cfg) { _, _ in }
    }
}
