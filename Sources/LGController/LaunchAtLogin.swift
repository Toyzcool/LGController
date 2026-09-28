//  LaunchAtLogin.swift
//  开机自启动：macOS 13+ 用 SMAppService（与「系统设置 → 通用 → 登录项」一致）；
//  macOS 12 没有 SMAppService，退回用 AppleScript 让「系统事件」增删登录项（同 SourceShift 的做法）。
//  macOS 12 上第一次开启时，系统会询问是否允许 LGController 控制「系统事件」，需点「好」。
//  所有方法在主线程调用（NSAppleScript 只能在主线程用）。

import AppKit
import ServiceManagement

enum LaunchAtLogin {
    enum Status {
        case enabled
        case notRegistered
        case requiresApproval // 仅 macOS 13+：需在「登录项」里批准
        case notFound         // 不是从 App 包内运行，系统找不到对应的 App
        case unknown
    }

    static var status: Status {
        if #available(macOS 13.0, *) {
            switch SMAppService.mainApp.status {
            case .enabled: return .enabled
            case .notRegistered: return .notRegistered
            case .requiresApproval: return .requiresApproval
            case .notFound: return .notFound
            @unknown default: return .unknown
            }
        }
        guard LegacyLoginItem.runningFromAppBundle else { return .notFound }
        return LegacyLoginItem.isEnabled ? .enabled : .notRegistered
    }

    static var isEnabled: Bool { status == .enabled }

    /// 开启或关闭。失败时抛出错误（macOS 12 上最常见的原因是没有允许控制「系统事件」）。
    static func setEnabled(_ enabled: Bool) throws {
        if #available(macOS 13.0, *) {
            let service = SMAppService.mainApp
            if enabled {
                if service.status != .enabled { try service.register() }
            } else if service.status == .enabled {
                try service.unregister()
            }
            return
        }
        try LegacyLoginItem.setEnabled(enabled)
    }
}

/// macOS 12：通过「系统事件」管理传统登录项，按 App 路径识别本 App。
private enum LegacyLoginItem {
    struct ScriptError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// 上次查询/设置的结果。每次调用 AppleScript 都要跟「系统事件」往返一次，
    /// 弹窗每次打开都查会卡顿，所以只在首次需要和每次改动后才真正去问系统。
    private static var cached: Bool?

    static var runningFromAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    private static var appPath: String { Bundle.main.bundlePath }

    private static var appName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "LGController"
    }

    static var isEnabled: Bool {
        if let cached = cached { return cached }
        let found = (try? run("""
            tell application "System Events"
                repeat with anItem in login items
                    if (path of anItem as text) is "\(escaped(appPath))" then return "1"
                end repeat
                return "0"
            end tell
            """)) == "1"
        cached = found
        return found
    }

    static func setEnabled(_ enabled: Bool) throws {
        guard runningFromAppBundle else {
            throw ScriptError(message: "须从 /Applications/\(appName).app 内运行")
        }
        let path = escaped(appPath)
        if enabled {
            _ = try run("""
                tell application "System Events"
                    repeat with anItem in login items
                        if (path of anItem as text) is "\(path)" then return "1"
                    end repeat
                    make login item at end with properties {path:"\(path)", hidden:false, name:"\(escaped(appName))"}
                    return "1"
                end tell
                """)
        } else {
            _ = try run("""
                tell application "System Events"
                    delete (every login item whose path is "\(path)")
                    return "0"
                end tell
                """)
        }
        cached = enabled
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func run(_ source: String) throws -> String? {
        guard let script = NSAppleScript(source: source) else {
            throw ScriptError(message: "AppleScript 编译失败")
        }
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo = errorInfo {
            let message = (errorInfo[NSAppleScript.errorMessage] as? String) ?? "\(errorInfo)"
            throw ScriptError(message: message)
        }
        return result.stringValue
    }
}
