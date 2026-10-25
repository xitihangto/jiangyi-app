import Foundation

/// 从 AI 回复的纯文本里抽出 Python 代码块
enum ScriptExtractor {

    /// 从一段完整回复里挑出「最像生成讲义」的那段代码
    static func extract(from text: String) -> String? {
        let blocks = codeBlocks(in: text)
        guard !blocks.isEmpty else {
            // 没有任何围栏，但整段看起来就是脚本
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if looksLikeScript(trimmed) { return normalize(trimmed) }
            return nil
        }
        // 优先含 docx / Document 的
        let scored = blocks.map { block -> (String, Int) in
            var score = 0
            let lower = block.lowercased()
            if lower.contains("docx") { score += 5 }
            if lower.contains("document(") || lower.contains("document()") { score += 4 }
            if lower.contains("add_heading") { score += 3 }
            if lower.contains("add_paragraph") { score += 3 }
            if lower.contains("add_table") { score += 2 }
            if lower.contains("save(") { score += 2 }
            if lower.contains("import ") { score += 1 }
            return (block, score * 1000 + block.count)
        }
        guard let best = scored.max(by: { $0.1 < $1.1 })?.0,
              looksLikeScript(best) else { return nil }
        return normalize(best)
    }

    /// 抓所有围栏代码块
    static func codeBlocks(in text: String) -> [String] {
        let pattern = "```[ \\t]*([A-Za-z0-9_+-]*)[ \\t]*\\r?\\n([\\s\\S]*?)```"
        guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let ns = text as NSString
        let matches = re.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
        var out: [String] = []
        for m in matches {
            guard m.numberOfRanges >= 3 else { continue }
            let lang = ns.substring(with: m.range(at: 1)).lowercased()
            let body = ns.substring(with: m.range(at: 2))
            // 明确标了非 Python 的跳过
            if !lang.isEmpty && !["python", "py", "python3"].contains(lang) { continue }
            out.append(body)
        }
        return out
    }

    /// 清洗：去掉残留围栏、统一换行、保证结尾有换行
    static func normalize(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: "\r\n", with: "\n")
        // 去掉首尾可能残留的围栏
        let lines = s.components(separatedBy: "\n")
        var kept = lines
        while let first = kept.first,
              first.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
            kept.removeFirst()
        }
        while let last = kept.last,
              last.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
            kept.removeLast()
        }
        s = kept.joined(separator: "\n")
        s = s.trimmingCharacters(in: CharacterSet.newlines)
        // 去掉每行统一的缩进（AI 偶尔会整体缩进）
        let bodyLines = s.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if let minIndent = bodyLines.map({ line -> Int in
            line.prefix(while: { $0 == " " }).count
        }).min(), minIndent > 0 {
            s = s.components(separatedBy: "\n").map { line in
                line.count >= minIndent ? String(line.dropFirst(minIndent)) : line
            }.joined(separator: "\n")
        }
        if !s.hasSuffix("\n") { s += "\n" }
        return s
    }

    /// 粗略判断一段文本是不是 Python 脚本
    static func looksLikeScript(_ text: String) -> Bool {
        let lower = text.lowercased()
        guard text.count > 80 else { return false }
        let signals = ["import ", "def ", "docx", "document", "save(", "from "]
        let hits = signals.filter { lower.contains($0) }.count
        return hits >= 3
    }
}
