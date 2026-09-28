//  makeicon.swift — 用 Apple Color Emoji 生成 macOS App 图标（.icns）
//  用法：swift makeicon.swift "☀️" Resources/AppIcon.icns
//  在圆角渐变背景（夜空蓝）上居中渲染高清彩色 emoji，导出全套尺寸并用 iconutil 打包 icns。

import AppKit
import Foundation

let args = CommandLine.arguments
let emoji = args.count > 1 ? args[1] : "☀️"
let outPath = args.count > 2 ? args[2] : "Resources/AppIcon.icns"

// 背景渐变（自上而下的夜空蓝，让彩色 emoji 更跳）
let topColor = NSColor(srgbRed: 74 / 255, green: 96 / 255, blue: 148 / 255, alpha: 1)
let bottomColor = NSColor(srgbRed: 20 / 255, green: 24 / 255, blue: 38 / 255, alpha: 1)

func renderPNG(size px: Int) -> Data {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else {
        fatalError("无法创建位图")
    }
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let side = CGFloat(px)
    let canvas = NSRect(x: 0, y: 0, width: side, height: side)

    // 圆角背景（Apple squircle 近似半径）
    let radius = side * 0.2237
    let path = NSBezierPath(roundedRect: canvas, xRadius: radius, yRadius: radius)
    path.addClip()
    NSGradient(starting: topColor, ending: bottomColor)?.draw(in: canvas, angle: -90)

    // 居中绘制 emoji
    let fontSize = side * 0.60
    let font = NSFont(name: "Apple Color Emoji", size: fontSize) ?? NSFont.systemFont(ofSize: fontSize)
    let attrs: [NSAttributedString.Key: Any] = [.font: font]
    let str = NSAttributedString(string: emoji, attributes: attrs)
    let textSize = str.size()
    let origin = NSPoint(x: (side - textSize.width) / 2,
                         y: (side - textSize.height) / 2)
    str.draw(at: origin)

    NSGraphicsContext.restoreGraphicsState()
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("PNG 编码失败")
    }
    return data
}

// 组装 .iconset（Apple 命名规范）
let fm = FileManager.default
let tmp = NSTemporaryDirectory() + "LGController-\(ProcessInfo.processInfo.processIdentifier).iconset"
try? fm.removeItem(atPath: tmp)
try fm.createDirectory(atPath: tmp, withIntermediateDirectories: true)

let variants: [(name: String, px: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for v in variants {
    let data = renderPNG(size: v.px)
    try data.write(to: URL(fileURLWithPath: "\(tmp)/\(v.name).png"))
}

// 确保输出目录存在
let outURL = URL(fileURLWithPath: outPath)
try? fm.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)

// iconutil 打包
let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", "-o", outPath, tmp]
try proc.run()
proc.waitUntilExit()
try? fm.removeItem(atPath: tmp)

if proc.terminationStatus == 0 {
    print("✅ 已生成图标: \(outPath)（emoji: \(emoji)）")
} else {
    print("❌ iconutil 失败，退出码 \(proc.terminationStatus)")
    exit(1)
}
