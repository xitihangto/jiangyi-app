// make_icon — 生成 1024×1024 的 app 图标底图
import AppKit
import Foundation

let S: CGFloat = 1024
guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
) else { exit(1) }
rep.size = NSSize(width: S, height: S)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// 圆角方块（Big Sur 风格：四周留白，圆角约 22.5%）
let inset: CGFloat = 92
let rect = CGRect(x: inset, y: inset, width: S - inset * 2, height: S - inset * 2)
let radius: CGFloat = (S - inset * 2) * 0.225
let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

// 底色渐变
ctx.saveGState()
ctx.addPath(path)
ctx.clip()
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let grad = CGGradient(colorsSpace: space, colors: [
    NSColor(srgbRed: 0.30, green: 0.42, blue: 0.98, alpha: 1).cgColor,
    NSColor(srgbRed: 0.46, green: 0.29, blue: 0.90, alpha: 1).cgColor
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(grad,
                       start: CGPoint(x: rect.minX, y: rect.maxY),
                       end: CGPoint(x: rect.maxX, y: rect.minY),
                       options: [])

// 左上柔光
let glow = CGGradient(colorsSpace: space, colors: [
    NSColor.white.withAlphaComponent(0.30).cgColor,
    NSColor.white.withAlphaComponent(0).cgColor
] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow,
                       startCenter: CGPoint(x: rect.minX + rect.width * 0.28,
                                            y: rect.maxY - rect.height * 0.18),
                       startRadius: 0,
                       endCenter: CGPoint(x: rect.minX + rect.width * 0.28,
                                          y: rect.maxY - rect.height * 0.18),
                       endRadius: rect.width * 0.85,
                       options: [])
ctx.restoreGState()

// 顶部高光边
ctx.saveGState()
ctx.addPath(path)
ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.28).cgColor)
ctx.setLineWidth(4)
ctx.strokePath()
ctx.restoreGState()

// 文字
let font = NSFont(name: "PingFangSC-Semibold", size: 470)
    ?? NSFont.systemFont(ofSize: 470, weight: .semibold)
let text = NSAttributedString(string: "讲", attributes: [
    .font: font,
    .foregroundColor: NSColor.white
])
let size = text.size()
text.draw(at: NSPoint(x: (S - size.width) / 2, y: (S - size.height) / 2 + 12))

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
try? png.write(to: URL(fileURLWithPath: out))
print(out)
