//  main.swift — LGController 入口（菜单栏应用，无 Dock 图标）

import AppKit

/// `--login-item on|off|status`：命令行开关开机自启动（与弹窗里的开关同一套实现，见 LaunchAtLogin）。
/// 须从 /Applications/LGController.app 包内的可执行文件运行，系统按 App 包识别登录项。
func runLoginItemCommand(_ action: String) -> Never {
    do {
        switch action {
        case "on": try LaunchAtLogin.setEnabled(true)
        case "off": try LaunchAtLogin.setEnabled(false)
        default: break
        }
    } catch {
        print("开机自启动 \(action) 失败：\(error.localizedDescription)")
        exit(1)
    }
    let status = LaunchAtLogin.status
    let state: String
    switch status {
    case .enabled: state = "已开启"
    case .notRegistered: state = "未开启"
    case .requiresApproval: state = "待批准（系统设置 → 通用 → 登录项 里打开 LGController）"
    case .notFound: state = "找不到 App（须从 /Applications/LGController.app 内运行）"
    case .unknown: state = "未知"
    }
    print("开机自启动：\(state)")
    exit(action == "on" && status != .enabled ? 1 : 0)
}

if let i = CommandLine.arguments.firstIndex(of: "--login-item") {
    let args = CommandLine.arguments
    runLoginItemCommand(i + 1 < args.count ? args[i + 1] : "status")
}
if CommandLine.arguments.contains("--selftest") {
    runSelfTest() // 见 SelfTest.swift，验证枚举/DDC/平滑管线后退出
}
if CommandLine.arguments.contains("--osdtest") {
    runOSDTest() // 每个屏幕演示 HUD 浮层样式后退出
}
if CommandLine.arguments.contains("--uipreview") {
    runUIPreview() // 离屏渲染弹窗 UI 到 /tmp 后退出
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
