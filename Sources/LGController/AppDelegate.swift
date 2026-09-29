//  AppDelegate.swift
//  组装：显示器管理、按键路由、输入源切换（合并自 SourceShift）、菜单栏，以及显示器重配置/睡眠唤醒的守护逻辑。

import AppKit
import Foundation
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) weak var shared: AppDelegate?

    let displayManager = DisplayManager()
    private(set) lazy var volumeControl = VolumeControl(displayManager: displayManager)
    private(set) lazy var router = KeyRouter(displayManager: displayManager, volumeControl: volumeControl)
    private(set) lazy var inputSwitcher = InputSwitcher(displayManager: displayManager)
    private var inputHotKeys: InputHotKeys?
    private let mediaKeyTap = MediaKeyTap()
    private var statusMenu: StatusMenuController?
    private var tapRetryTimer: Timer?
    private var reconfigureDebounce: DispatchWorkItem?

    func applicationDidFinishLaunching(_: Notification) {
        Self.shared = self
        displayManager.rebuild()

        statusMenu = StatusMenuController(displayManager: displayManager, inputSwitcher: inputSwitcher,
                                          volumeControl: volumeControl)

        // ⌘⇧1~4 切换输入源。刻意不受 router.suspended 约束：「盲按拉回」恰恰发生在显示器切走后的重配置期间。
        let hotKeys = InputHotKeys { [weak self] source in self?.inputSwitcher.switchTo(source) }
        hotKeys.register()
        inputHotKeys = hotKeys

        enableLaunchAtLoginOnFirstLaunch()

        mediaKeyTap.handler = { [weak self] key, pressed, isRepeat, modifiers in
            self?.router.handle(key: key, pressed: pressed, isRepeat: isRepeat, modifiers: modifiers) ?? false
        }
        requestAccessibilityAndStartTap()

        // 显示器插拔/分辨率变化 → 防抖后重建
        CGDisplayRegisterReconfigurationCallback({ _, flags, _ in
            guard flags.contains(.addFlag) || flags.contains(.removeFlag)
                || flags.contains(.enabledFlag) || flags.contains(.disabledFlag)
                || flags.contains(.setMainFlag) || flags.contains(.setModeFlag) else { return }
            DispatchQueue.main.async {
                AppDelegate.shared?.scheduleRebuild()
            }
        }, nil)

        // 睡眠/唤醒：暂停按键处理，唤醒后重建（DDC 通道可能失效）
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        // 仅显示器休眠（系统未睡）：也要暂停，否则对休眠屏的 DDC 写会静默失败、状态与硬件分叉
        workspace.addObserver(self, selector: #selector(screensDidSleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(screensDidWake), name: NSWorkspace.screensDidWakeNotification, object: nil)

        NSLog("LGController: 启动完成，共 \(displayManager.displays.count) 台显示器")
    }

    /// 合并自 SourceShift：全新安装首次启动默认开启「开机自启动」，之后完全以用户在弹窗里的开关为准。
    /// 已经用过本 App 的用户（已有显示器状态记录）不自动开启，以免改掉他们原有的选择。
    private func enableLaunchAtLoginOnFirstLaunch() {
        let key = "LaunchAtLogin.firstLaunchHandled"
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: key) else { return }
        let isUpgrade = defaults.dictionaryRepresentation().keys.contains { $0.hasPrefix("brightness-") }
        defaults.set(true, forKey: key)
        guard !isUpgrade, !LaunchAtLogin.isEnabled else { return }
        do {
            try LaunchAtLogin.setEnabled(true)
        } catch {
            NSLog("LGController: 首次启动开启开机自启动失败: \(error.localizedDescription)")
        }
    }

    private func requestAccessibilityAndStartTap() {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as NSString
        let trusted = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
        if trusted, mediaKeyTap.start() {
            DiagLog.write("媒体键监听已启动（辅助功能已授权）")
            return
        }
        DiagLog.write(trusted ? "媒体键监听启动失败：已授权，但无法创建事件监听"
                              : "辅助功能未授权：亮度/音量/静音键交给 macOS 处理，每 3 秒重试")
        // 未授权：每 3 秒重试，授权一生效立即接管媒体键
        tapRetryTimer?.invalidate()
        tapRetryTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            if AXIsProcessTrusted(), self.mediaKeyTap.start() {
                timer.invalidate()
                self.tapRetryTimer = nil
                NSLog("LGController: 辅助功能权限已获得")
                DiagLog.write("辅助功能权限已获得，媒体键监听已启动")
            }
        }
    }

    private func scheduleRebuild() {
        router.suspended = true
        reconfigureDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.displayManager.rebuild()
            self.router.suspended = false
            NSLog("LGController: 显示器配置已更新（\(self.displayManager.displays.count) 台）")
        }
        reconfigureDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    @objc private func willSleep() {
        router.suspended = true
    }

    @objc private func didWake() {
        scheduleRebuild()
    }

    @objc private func screensDidSleep() {
        router.suspended = true
    }

    @objc private func screensDidWake() {
        scheduleRebuild()
    }

    func applicationWillTerminate(_: Notification) {
        mediaKeyTap.stop()
        inputHotKeys?.unregister()
    }
}
