import Foundation

/// 从 docx 里按正文出现顺序抽出的一张图片。
/// `index` 从 1 起，`fileName` 就是回填时用的 `图1.png`、`图2.png`……
struct DocxImage {
    let index: Int
    let ext: String
    let data: Data

    var fileName: String { "图\(index).\(ext)" }
}

/// 抽 docx 里的图片，供成品回填用。
///
/// 顺序以 `word/document.xml` 里出现的先后为准，**不是** `word/media/` 的文件名顺序——
/// Word 会复用同一张图（image3 完全可能出现在 image1 前面），按文件名排会错位。
/// 同一张图被引用多次只算一张：正文里第二处引用还是它，回填时按顺序自然复用不到，
/// 这种情况极少（考卷里基本不会出现），不做额外处理。
enum DocxImages {

    static func extract(from docx: URL) -> [DocxImage] {
        guard docx.pathExtension.lowercased() == "docx",
              let documentXML = readText("word/document.xml", from: docx),
              let relsXML = readText("word/_rels/document.xml.rels", from: docx) else { return [] }

        // 1) rId → media 相对路径（Target 可能是 media/image1.png，也可能带 ../）
        var target: [String: String] = [:]
        for tag in scan(#"<Relationship\b[^>]*>"#, in: relsXML) {
            guard let id = firstGroup(#"\bId="([^"]+)""#, in: tag.text),
                  let path = firstGroup(#"\bTarget="([^"]+)""#, in: tag.text) else { continue }
            target[id] = path
        }
        guard !target.isEmpty else { return [] }

        // 2) 正文里两种图片引用都要认：DrawingML 的 a:blip，老 VML 的 v:imagedata
        var refs = scan(#"<a:blip\b[^>]*\br:embed="([^"]+)""#, in: documentXML)
        refs += scan(#"<v:imagedata\b[^>]*\br:id="([^"]+)""#, in: documentXML)
        refs.sort { $0.location < $1.location }
        guard !refs.isEmpty else { return [] }

        // 3) 按出现顺序取字节，同一个 rId 只取一次
        var seen = Set<String>()
        var out: [DocxImage] = []
        for ref in refs {
            guard !seen.contains(ref.capture) else { continue }
            seen.insert(ref.capture)
            guard let rel = target[ref.capture] else { continue }

            let entry = "word/" + rel.replacingOccurrences(of: "../", with: "")
            let ext = (rel as NSString).pathExtension.lowercased()
            guard !ext.isEmpty,
                  let data = unzip(entry, from: docx), !data.isEmpty else { continue }

            out.append(DocxImage(index: out.count + 1, ext: ext, data: data))
        }
        return out
    }

    // MARK: - 解压

    /// `unzip -p` 直接把单个条目吐到 stdout，不用先解整包（docx 里常有几 MB 的图）
    private static func unzip(_ entry: String, from docx: URL) -> Data? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        task.arguments = ["-p", docx.path, entry]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        return data.isEmpty ? nil : data
    }

    private static func readText(_ entry: String, from docx: URL) -> String? {
        guard let data = unzip(entry, from: docx) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - 正则

    private struct Hit {
        let location: Int
        let capture: String
        let text: String
    }

    private static func scan(_ pattern: String, in text: String) -> [Hit] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
            let whole = ns.substring(with: m.range)
            // 没有捕获组时（比如整段 <Relationship .../>），capture 就是整段本身
            var capture = whole
            if m.numberOfRanges > 1 {
                let r = m.range(at: 1)
                if r.location != NSNotFound { capture = ns.substring(with: r) }
            }
            return Hit(location: m.range.location, capture: capture, text: whole)
        }
    }

    private static func firstGroup(_ pattern: String, in text: String) -> String? {
        scan(pattern, in: text).first?.capture
    }
}
