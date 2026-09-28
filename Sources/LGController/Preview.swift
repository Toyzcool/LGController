//  Preview.swift
//  `LGController --uipreview`：用示例数据把弹窗界面离屏渲染成 PNG（/tmp/menu_preview.png），
//  用于快速核对 UI 样式，不进入菜单栏交互。

import AppKit
import SwiftUI

func runUIPreview() -> Never {
    guard #available(macOS 13.0, *) else {
        print("--uipreview 需要 macOS 13 或更高（用到 ImageRenderer）")
        exit(1)
    }
    // ImageRenderer 须在主 actor 上用。不用 MainActor.assumeIsolated（Swift 5.9 才有）：
    // 投递一个主 actor 任务，再用 dispatchMain() 让主线程开始处理主队列。
    Task { @MainActor in
        renderPreviews()
        exit(0)
    }
    dispatchMain()
}

@available(macOS 13.0, *)
@MainActor
private func renderPreviews() {
    do {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let rows: [PopoverModel.DisplayRow] = [
            .init(id: 1, name: "LG HDR 4K", canBrightness: true, brightness: 0.72),
            .init(id: 2, name: "Built-in Retina Display", canBrightness: true, brightness: 0.55),
        ]
        let outputs: [PopoverModel.OutputRow] = [
            .init(id: 10, name: "MacBook Pro扬声器", symbol: "laptopcomputer"),
            .init(id: 11, name: "外置耳机", symbol: "headphones"),
            .init(id: 12, name: "LG HDR 4K", symbol: "display"),
        ]
        let model = PopoverModel(previewRows: rows, accessibility: false, launch: true, inputTarget: "LG HDR 4K",
                                 outputs: outputs, selectedOutput: 11,
                                 level: .init(volume: 0.45, muted: false, controllable: true, viaDDC: false))

        // 加不透明窗口底色，便于在 PNG 里看清（真实弹窗底为系统玻璃材质）
        // previewSliders=true：用自绘滑块条，让 ImageRenderer 能画出滑块（原生 Slider 无法快照）
        let content = MenuView(model: model)
            .environment(\.previewSliders, true)
            .background(Color(nsColor: .windowBackgroundColor))

        for (label, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
            let renderer = ImageRenderer(content: content.environment(\.colorScheme, scheme))
            renderer.scale = 2
            if let image = renderer.nsImage,
               let tiff = image.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                let path = "/tmp/menu_preview_\(label).png"
                try? png.write(to: URL(fileURLWithPath: path))
                print("已渲染 \(label): \(path) (\(Int(image.size.width))×\(Int(image.size.height)))")
            } else {
                print("渲染失败 (\(label))")
            }
        }
    }
}
