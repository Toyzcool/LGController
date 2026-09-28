//  KeyRouter.swift
//  按键路由核心：
//  - 亮度：按「鼠标所在屏幕」路由（目标屏支持则调它，DisplayServices 或 DDC）。
//  - 音量：只跟随「当前输出源」，目标解析与操作统一在 VolumeControl 模块（弹窗音量卡片共用同一份规则）。

import AppKit
import AVFoundation
import Foundation

final class KeyRouter {
    private let displayManager: DisplayManager
    let volumeControl: VolumeControl
    private var audioPlayer: AVAudioPlayer?
    var suspended = false // 睡眠/重配置期间暂停

    init(displayManager: DisplayManager, volumeControl: VolumeControl? = nil) {
        self.displayManager = displayManager
        self.volumeControl = volumeControl ?? VolumeControl(displayManager: displayManager)
    }

    /// MediaKeyTap 回调入口（主线程）。返回 true = 吞掉事件。
    func handle(key: MediaKey, pressed: Bool, isRepeat: Bool, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard !suspended else { return false }

        // ⌘/⌃/单独⌥ 等组合键一律放行（保留系统行为，如 ⌥+亮度键打开设置）
        let relevant = modifiers.intersection([.command, .control, .option, .shift])
        let fine = relevant == [.option, .shift]
        guard relevant.isEmpty || relevant == [.shift] || fine else { return false }

        guard let display = displayManager.displayUnderMouse() else { return false }

        switch key {
        case .brightnessUp, .brightnessDown:
            guard display.canBrightness else { return false } // 控不了就还给系统
            guard pressed else { return true } // keyUp 也要吞，避免系统重复响应
            let value = display.stepBrightness(up: key == .brightnessUp, fine: fine)
            OSD.showBrightness(value, on: display.id)
            return true

        case .volumeUp, .volumeDown:
            let target = volumeTarget(for: display)
            switch target {
            case .none:
                guard pressed else { return true }
                OSD.showSimple(.volumeDisabled, on: display.id)
                return true
            case .ddc(let ddcDisplay):
                if pressed {
                    let value = ddcDisplay.stepVolume(up: key == .volumeUp, fine: fine)
                    OSD.showVolume(value, muted: ddcDisplay.muted, on: display.id)
                } else if !isRepeat, !ddcDisplay.muted, ddcDisplay.volume > 0 {
                    playVolumeFeedback() // 静音/音量为 0 时不放反馈音，与 CoreAudio 分支一致
                }
                return true
            case .coreAudio(let device):
                if pressed {
                    let value = AudioVolume.shared.step(device, up: key == .volumeUp, fine: fine)
                    OSD.showVolume(value, muted: value <= 0, on: display.id)
                    NotificationCenter.default.post(name: .lgControllerStateDidChange, object: nil)
                } else if !isRepeat, AudioVolume.shared.displayVolume(device) > 0 {
                    playVolumeFeedback()
                }
                return true
            }

        case .mute:
            guard pressed, !isRepeat else { return true } // 吞掉 keyUp/重复，仅响应首次按下
            let target = volumeTarget(for: display)
            switch target {
            case .none:
                OSD.showSimple(.muteDisabled, on: display.id)
            case .ddc(let ddcDisplay):
                let muted = ddcDisplay.toggleMute()
                OSD.showVolume(muted ? 0 : ddcDisplay.volume, muted: muted, on: display.id)
                if !muted { playVolumeFeedback() }
            case .coreAudio(let device):
                let muted = AudioVolume.shared.toggleMute(device)
                OSD.showVolume(AudioVolume.shared.displayVolume(device), muted: muted, on: display.id)
                if !muted { playVolumeFeedback() }
            }
            NotificationCenter.default.post(name: .lgControllerStateDidChange, object: nil)
            return true
        }
    }

    // MARK: 音量目标解析（委托给 VolumeControl）

    typealias VolumeTarget = VolumeControl.Target

    /// 音量路由：只认「当前输出源」，与鼠标位置无关。`display` 仅用于 OSD 位置与兜底判断。
    func volumeTarget(for display: Display) -> VolumeTarget {
        volumeControl.target(fallbackDisplay: display)
    }

    // MARK: 音量调节提示音（遵循系统「更改音量时播放反馈」设置）

    private func playVolumeFeedback() {
        let pref = CFPreferencesCopyValue("com.apple.sound.beep.feedback" as CFString,
                                          kCFPreferencesAnyApplication,
                                          kCFPreferencesCurrentUser,
                                          kCFPreferencesAnyHost)
        if let enabled = pref as? Int, enabled == 0 { return }
        let path = "/System/Library/LoginPlugins/BezelServices.loginPlugin/Contents/Resources/volume.aiff"
        guard FileManager.default.fileExists(atPath: path) else { return }
        audioPlayer = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
        audioPlayer?.volume = 1
        audioPlayer?.play()
    }
}
