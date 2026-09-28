//  AudioVolume.swift
//  CoreAudio 输出设备的有状态音量控制，逻辑对齐 macOS：
//  - 步进从「内部意图值」出发（不读回被设备量化后的值），因此可精确落到每一档、精确归零；
//  - 到 0 即真正静音（scalar 0 + 硬件 mute 双保险），与 Mac 一致；
//  - 静音是独立状态（记住恢复音量），静音键切换、任意方向音量键都解除静音；
//  - 外部（其他 App / 菜单栏滑块）改过音量时，下一次步进前先采纳硬件真实值，避免跳变。
//  意图值始终以硬件当前值初始化（CoreAudio 可即时可靠读取，设备本身也会记住音量），
//  因此不做持久化——避免陈旧状态覆盖真实硬件值。所有方法须在主线程调用。

import CoreAudio
import Foundation

final class AudioVolume {
    static let shared = AudioVolume()

    private struct State {
        var volume: Float   // 意图音量（0...1），与静音无关
        var muted: Bool
        var preMute: Float  // 静音前音量，用于恢复
    }

    private var states: [String: State] = [:]

    private func uid(_ device: AudioDeviceID) -> String {
        AudioController.deviceUID(device) ?? "dev-\(device)"
    }

    private func state(_ device: AudioDeviceID) -> State {
        let key = uid(device)
        if let existing = states[key] { return existing }
        let hw = min(max(AudioController.volume(of: device) ?? 0.25, 0), 1)
        let s = State(volume: hw,
                      muted: AudioController.isMuted(device),
                      preMute: max(hw, 1.0 / 16))
        states[key] = s
        return s
    }

    private func save(_ device: AudioDeviceID, _ s: State) {
        states[uid(device)] = s
    }

    /// 写入硬件：静音或音量 0 → scalar 0 + 硬件 mute；否则取消 mute 并写 scalar。
    private func apply(_ device: AudioDeviceID, _ s: State) {
        if s.muted || s.volume <= 0 {
            AudioController.setVolume(device, 0)
            _ = AudioController.setMuted(device, true)
        } else {
            if AudioController.isMuted(device) {
                _ = AudioController.setMuted(device, false)
            }
            AudioController.setVolume(device, s.volume)
        }
    }

    // MARK: 查询

    /// 与硬件对账（系统音量条、控制中心等外部改动后调用），不写硬件。
    func syncFromHardware(_ device: AudioDeviceID) {
        var s = state(device)
        reconcileExternal(device, &s)
        if !s.muted, AudioController.isMuted(device) { s.muted = true } // 外部静音也要反映出来
        save(device, s)
    }

    /// 显示用音量（静音时为 0）。
    func displayVolume(_ device: AudioDeviceID) -> Float {
        let s = state(device)
        return s.muted ? 0 : s.volume
    }

    func isMuted(_ device: AudioDeviceID) -> Bool {
        state(device).muted
    }

    // MARK: 变更

    /// 采纳外部改动（其他 App / 系统菜单栏音量条），避免下一次步进/切换基于陈旧值突跳。
    private func reconcileExternal(_ device: AudioDeviceID, _ s: inout State) {
        // 内部认为静音、但硬件已被外部解除且音量非零 → 采纳该音量并清除静音标记
        if s.muted, !AudioController.isMuted(device), let hw = AudioController.volume(of: device), hw > 0 {
            s.muted = false
            s.volume = min(max(hw, 0), 1)
            return
        }
        // 未静音时，硬件音量与意图值偏差超过量化噪声 → 采纳硬件值
        guard !s.muted, let hw = AudioController.volume(of: device), abs(hw - s.volume) > 0.02 else { return }
        s.volume = min(max(hw, 0), 1)
    }

    /// 键盘步进（1/16；fine=1/64），从内部意图值出发，可精确归零。返回新音量。
    @discardableResult
    func step(_ device: AudioDeviceID, up: Bool, fine: Bool) -> Float {
        let stepSize: Float = fine ? 1.0 / 64 : 1.0 / 16
        var s = state(device)
        reconcileExternal(device, &s)
        s.muted = false // 任意方向音量键都解除静音（Mac 行为）
        s.volume = Display.gridStep(s.volume, step: stepSize, up: up)
        if s.volume <= 0 {
            s.muted = true
        } else {
            s.preMute = s.volume
        }
        save(device, s)
        apply(device, s)
        return s.volume
    }

    /// 直接设定（供菜单滑块等）。
    func setVolume(_ device: AudioDeviceID, _ value: Float) {
        var s = state(device)
        s.volume = min(max(value, 0), 1)
        s.muted = s.volume <= 0
        if s.volume > 0 { s.preMute = s.volume }
        save(device, s)
        apply(device, s)
    }

    /// 静音键切换。返回切换后的静音状态。
    @discardableResult
    func toggleMute(_ device: AudioDeviceID) -> Bool {
        var s = state(device)
        reconcileExternal(device, &s) // 先采纳外部改动，避免基于陈旧值切换
        if s.muted {
            s.muted = false
            if s.volume <= 0 { s.volume = max(s.preMute, 1.0 / 16) }
        } else {
            s.preMute = max(s.volume, 1.0 / 16)
            s.muted = true
        }
        save(device, s)
        apply(device, s)
        return s.muted
    }
}
