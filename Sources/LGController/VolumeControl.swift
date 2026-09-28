//  VolumeControl.swift
//  音量模块：音量只跟随「当前输出源」（系统默认输出设备），与鼠标位置无关。
//  按键（KeyRouter）与弹窗「音量」卡片共用这里的目标解析和操作，规则只有一份：
//  - 输出源可由 CoreAudio 调节（耳机/AirPods/内建扬声器/USB 音频）→ 走 AudioVolume；
//  - 输出源是显示器自带音频（DP/HDMI，CoreAudio 调不了）→ 用 DDC 控制那台显示器的扬声器；
//  - 兜底（仅按键）：鼠标所在屏可 DDC 控制音量则用它；否则输出源是显示器音频（认不出哪台）时不可调，
//    其余情况用内建扬声器。
//    弹窗卡片不走兜底（见 outputTarget），当前输出源调不了就如实显示不可调。
//  另负责输出源切换（setDefaultOutputDevice）。所有方法在主线程调用。

import CoreAudio
import Foundation

final class VolumeControl {
    enum Target {
        case ddc(DDCDisplay)
        case coreAudio(AudioDeviceID)
        case none
    }

    /// 弹窗展示用的当前音量状态。
    struct Level: Equatable {
        var volume: Float      // 0...1，静音时为 0
        var muted: Bool
        var controllable: Bool // 当前输出源能否调节音量
        var viaDDC: Bool       // 是否经 DDC 控制显示器扬声器
    }

    private let displayManager: DisplayManager

    init(displayManager: DisplayManager) {
        self.displayManager = displayManager
    }

    // MARK: 目标解析

    /// `fallbackDisplay` 仅在拿不到可用输出源时用于兜底（通常传鼠标所在屏）。
    func target(fallbackDisplay: Display? = nil) -> Target {
        var outputIsDisplayAudio = false
        if let device = AudioController.defaultOutputDevice() {
            if AudioController.hasSettableVolume(device) {
                return .coreAudio(device)
            }
            if let ddc = displayManager.ddcDisplay(forAudioDevice: device) {
                return .ddc(ddc)
            }
            outputIsDisplayAudio = AudioController.isDisplayAudio(device)
        }
        if let ddcDisplay = fallbackDisplay as? DDCDisplay, ddcDisplay.canVolume {
            return .ddc(ddcDisplay)
        }
        // 声音从显示器出（只是认不出是哪台）时，调内建扬声器毫无反应，宁可提示不可调
        if outputIsDisplayAudio { return .none }
        if let speakers = AudioController.builtInSpeakers(), AudioController.hasSettableVolume(speakers) {
            return .coreAudio(speakers)
        }
        return .none
    }

    /// 弹窗音量卡片用：只控制「当前输出源」本身，不做按键的兜底。
    /// 输出源既不能 CoreAudio 调节、又对不上 DDC 屏（多输出设备、无硬件音量的 USB 声卡等）时返回 .none，
    /// 卡片显示「不支持调节」，避免标着输出源的名字、实际却在调没在出声的内建扬声器。
    /// 没有默认输出设备时才退回按键同一套规则。
    func outputTarget() -> Target {
        guard let device = AudioController.defaultOutputDevice() else { return target() }
        if AudioController.hasSettableVolume(device) { return .coreAudio(device) }
        if let ddc = displayManager.ddcDisplay(forAudioDevice: device) { return .ddc(ddc) }
        return .none
    }

    // MARK: 状态与操作（弹窗卡片，均作用于 outputTarget）

    func level() -> Level {
        switch outputTarget() {
        case .coreAudio(let device):
            return Level(volume: AudioVolume.shared.displayVolume(device),
                         muted: AudioVolume.shared.isMuted(device), controllable: true, viaDDC: false)
        case .ddc(let display):
            return Level(volume: display.volume, muted: display.muted, controllable: true, viaDDC: true)
        case .none:
            return Level(volume: 0, muted: false, controllable: false, viaDDC: false)
        }
    }

    /// 弹窗打开或外部改动后调用：CoreAudio 与硬件对账（即时可靠）；
    /// includeDDC 时输出源是 DDC 显示器才去回读它（慢、占该屏 I²C 队列，只在打开弹窗/切换输出源时做）。
    func syncFromHardware(includeDDC: Bool = true) {
        switch outputTarget() {
        case .coreAudio(let device): AudioVolume.shared.syncFromHardware(device)
        case .ddc(let display): if includeDDC { display.refreshVolumeForUI() }
        case .none: break
        }
    }

    func setVolume(_ value: Float) {
        switch outputTarget() {
        case .coreAudio(let device): AudioVolume.shared.setVolume(device, value)
        case .ddc(let display): display.setVolume(value)
        case .none: return
        }
        NotificationCenter.default.post(name: .lgControllerStateDidChange, object: nil)
    }

    /// 返回切换后的静音状态；不可控时返回 nil。
    @discardableResult
    func toggleMute() -> Bool? {
        let muted: Bool
        switch outputTarget() {
        case .coreAudio(let device): muted = AudioVolume.shared.toggleMute(device)
        case .ddc(let display): muted = display.toggleMute()
        case .none: return nil
        }
        NotificationCenter.default.post(name: .lgControllerStateDidChange, object: nil)
        return muted
    }

    // MARK: 输出源

    func outputDevices() -> [AudioController.OutputDevice] {
        AudioController.outputDevices()
    }

    var currentOutputID: AudioDeviceID? {
        AudioController.defaultOutputDevice()
    }

    @discardableResult
    func selectOutput(_ device: AudioDeviceID) -> Bool {
        let ok = AudioController.setDefaultOutputDevice(device)
        NSLog("LGController: 输出源 → \(AudioController.name(of: device))：\(ok ? "成功" : "失败")")
        NotificationCenter.default.post(name: .lgControllerStateDidChange, object: nil)
        return ok
    }
}
