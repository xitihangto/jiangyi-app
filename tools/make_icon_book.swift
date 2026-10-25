// make_icon_book v3 — 生成 1024x1024 的新 app 图标底图：翻开的厚书，蓝青绿渐变底
// v3（用户 2026-10-25 要求）：去掉圆角方形外圈的黑色描边；下沿（厚度一边）也做成 m 型，
// 弧度和上沿统一；删掉页内拱形文字线和书底页间横线，只留书的外轮廓和书脊，清爽一点。
// 用法：swift tools/make_icon_book.swift /tmp/icon-book-1024.png
// 设计（用户 2026-10-25 要求）：
//  - 背景不再是白底，改成截图那种蓝（上）→ 青 → 绿（下）的渐变；
//  - 书本不再填白色，书页和书底只描黑线、不填色，渐变直接透出来，书和背景融为一体，只有线条是黑的；
//  - 书要更厚：书底从原来约 26px 加到约 60px，里面多一道书页层线；
//  - 书顶不再太平直，改成压扁的 m 型：左右两页各一个小半圆拱，中间书脊处略低，拱起不要太弯。
// 坐标系：先把 CG 上下翻转一次，之后全部按“左上角为原点、y 向下”来画，书底在下、书页在上，不会画反。
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
ctx.translateBy(x: 0, y: S)
ctx.scaleBy(x: 1, y: -1)

let black = NSColor.black.cgColor

// 1. 背景：圆角方块里填蓝→青→绿渐变（截图色系：上蓝、下绿、中间青绿过渡）
let bg = CGPath(roundedRect: CGRect(x: 96, y: 96, width: 832, height: 832),
                cornerWidth: 192, cornerHeight: 192, transform: nil)
ctx.saveGState()
ctx.addPath(bg)
ctx.clip()
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let grad = CGGradient(colorsSpace: space, colors: [
    NSColor(srgbRed: 0.04, green: 0.42, blue: 0.92, alpha: 1).cgColor,
    NSColor(srgbRed: 0.00, green: 0.72, blue: 0.84, alpha: 1).cgColor,
    NSColor(srgbRed: 0.00, green: 0.82, blue: 0.62, alpha: 1).cgColor,
    NSColor(srgbRed: 0.08, green: 0.82, blue: 0.38, alpha: 1).cgColor
] as CFArray, locations: [0, 0.35, 0.68, 1.0])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 512, y: 96), end: CGPoint(x: 512, y: 928), options: [])
ctx.restoreGState()
// 外圈不再描边：只填渐变，圆角由上面的裁剪决定，边缘就是渐变本身。

// 2. 书底（加厚：书页底到书底约 60px，里面两道层线，书和背景一样是渐变，只描线）
let base = CGMutablePath()
base.move(to: CGPoint(x: 212, y: 640))
base.addLine(to: CGPoint(x: 212, y: 700))
// 下沿也做成 m 型：左右各一个拱、书脊处略低，起伏和上沿统一（外 700、拱约 674、脊 732）
base.addCurve(to: CGPoint(x: 512, y: 732), control1: CGPoint(x: 312, y: 660), control2: CGPoint(x: 412, y: 660))
base.addCurve(to: CGPoint(x: 812, y: 700), control1: CGPoint(x: 612, y: 660), control2: CGPoint(x: 712, y: 660))
base.addLine(to: CGPoint(x: 812, y: 640))
// 上沿（书页底）同样做成 m 型，和下沿保持约 60px 均匀厚度：外 640、拱约 614、脊 672
base.addCurve(to: CGPoint(x: 512, y: 672), control1: CGPoint(x: 712, y: 600), control2: CGPoint(x: 612, y: 600))
base.addCurve(to: CGPoint(x: 212, y: 640), control1: CGPoint(x: 412, y: 600), control2: CGPoint(x: 312, y: 600))
base.closeSubpath()
ctx.addPath(base)
ctx.setStrokeColor(black)
ctx.setLineWidth(14)
ctx.setLineJoin(.round)
ctx.strokePath()

// 页间横线已删（用户要求清爽）：书底里不再画层线，只留外轮廓。// 3. 翻开的书页：顶部是压扁的 m 型——左右各一个小半圆拱，书脊处略低，拱不要太弯。
//    左页拱顶约 345，右页拱顶约 345，书脊 400，两端 372，拱起约 55px，够看出 m 型又不夸张。
let pages = CGMutablePath()
pages.move(to: CGPoint(x: 212, y: 372))
pages.addLine(to: CGPoint(x: 212, y: 640))
// 书页底同样做成 m 型，和书底上沿完全重合，厚度均匀约 60px
pages.addCurve(to: CGPoint(x: 512, y: 672), control1: CGPoint(x: 312, y: 600), control2: CGPoint(x: 412, y: 600))
pages.addCurve(to: CGPoint(x: 812, y: 640), control1: CGPoint(x: 612, y: 600), control2: CGPoint(x: 712, y: 600))
pages.addLine(to: CGPoint(x: 812, y: 372))
pages.addCurve(to: CGPoint(x: 512, y: 400), control1: CGPoint(x: 712, y: 330), control2: CGPoint(x: 612, y: 330))
pages.addCurve(to: CGPoint(x: 212, y: 372), control1: CGPoint(x: 412, y: 330), control2: CGPoint(x: 312, y: 330))
pages.closeSubpath()
ctx.addPath(pages)
ctx.setStrokeColor(black)
ctx.setLineWidth(16)
ctx.setLineJoin(.round)
ctx.strokePath()

// 4. 页内拱形文字线已删（用户要求清爽）：书页里不再画横线，只留外轮廓和书脊。
// 5. 书脊：从书页顶部中央（m 型低点）一直划到厚底底部
ctx.beginPath()
ctx.move(to: CGPoint(x: 512, y: 400))
ctx.addLine(to: CGPoint(x: 512, y: 732))
ctx.setStrokeColor(black)
ctx.setLineWidth(12)
ctx.setLineCap(.round)
ctx.strokePath()

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-book-1024.png"
try? png.write(to: URL(fileURLWithPath: out))
print(out)
