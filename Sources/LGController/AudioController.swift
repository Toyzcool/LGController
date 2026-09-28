//  AudioController.swift
//  CoreAudio 输出设备的查询、音量/静音读写、输出源切换与变化监听（内建扬声器、耳机、AirPods 等）。
//  DisplayPort/HDMI 音频设备通常没有可设音量，此时由 DDC 通道接管（见 VolumeControl）。

import CoreAudio
import Foundation

enum AudioController {
    private static let kVirtualMainVolume: AudioObjectPropertySelector = 0x766D_7663 // 'vmvc'

    fileprivate static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func defaultOutputDevice() -> AudioDeviceID? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device)
        return status == noErr && device != 0 ? device : nil
    }

    static func allOutputDevices() -> [AudioDeviceID] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devices) == noErr else { return [] }
        return devices.filter { hasOutputStreams($0) }
    }

    private static func hasOutputStreams(_ device: AudioDeviceID) -> Bool {
        var addr = address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size)
        return size > 0
    }

    static func name(of device: AudioDeviceID) -> String {
        var addr = address(kAudioObjectPropertyName)
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(device, &addr, 0, nil, &size, $0)
        }
        return status == noErr ? (value as String) : ""
    }

    /// 设备持久 UID（跨重启/重插稳定，用作音量状态的键）。
    static func deviceUID(_ device: AudioDeviceID) -> String? {
        var addr = address(kAudioDevicePropertyDeviceUID)
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(device, &addr, 0, nil, &size, $0)
        }
        return status == noErr ? (value as String) : nil
    }

    static func transportType(of device: AudioDeviceID) -> UInt32 {
        var addr = address(kAudioDevicePropertyTransportType)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value)
        return value
    }

    static func hasSettableVolume(_ device: AudioDeviceID) -> Bool {
        var addr = address(kVirtualMainVolume, kAudioObjectPropertyScopeOutput)
        guard AudioObjectHasProperty(device, &addr) else { return false }
        var settable = DarwinBoolean(false)
        AudioObjectIsPropertySettable(device, &addr, &settable)
        return settable.boolValue
    }

    static func volume(of device: AudioDeviceID) -> Float? {
        var addr = address(kVirtualMainVolume, kAudioObjectPropertyScopeOutput)
        guard AudioObjectHasProperty(device, &addr) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    @discardableResult
    static func setVolume(_ device: AudioDeviceID, _ value: Float) -> Bool {
        var addr = address(kVirtualMainVolume, kAudioObjectPropertyScopeOutput)
        var clamped = Float32(min(max(value, 0), 1))
        return AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &clamped) == noErr
    }

    static func isMuted(_ device: AudioDeviceID) -> Bool {
        var addr = address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput)
        guard AudioObjectHasProperty(device, &addr) else { return false }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value)
        return value == 1
    }

    @discardableResult
    static func setMuted(_ device: AudioDeviceID, _ muted: Bool) -> Bool {
        var addr = address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput)
        guard AudioObjectHasProperty(device, &addr) else { return false }
        var settable = DarwinBoolean(false)
        AudioObjectIsPropertySettable(device, &addr, &settable)
        guard settable.boolValue else { return false }
        var value: UInt32 = muted ? 1 : 0
        return AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }

    /// 是否为显示器自带音频（DisplayPort / HDMI）。
    static func isDisplayAudio(_ device: AudioDeviceID) -> Bool {
        let t = transportType(of: device)
        return t == kAudioDeviceTransportTypeDisplayPort || t == kAudioDeviceTransportTypeHDMI
    }

    /// 内建扬声器（transport = 'bltn'）。
    static func builtInSpeakers() -> AudioDeviceID? {
        allOutputDevices().first { transportType(of: $0) == kAudioDeviceTransportTypeBuiltIn }
    }

    // MARK: 输出源选择（音量模块用）

    /// 一个可选的输出设备（与「系统设置 → 声音 → 输出」列出的一致：有输出流、未隐藏）。
    struct OutputDevice: Identifiable, Equatable {
        let id: AudioDeviceID
        let uid: String
        let name: String
        let transport: UInt32

        /// 菜单里的图标：耳机 / 蓝牙 / 显示器 / USB / 扬声器
        var symbol: String {
            let lower = name.lowercased()
            switch transport {
            case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
                return lower.contains("airpods") ? "airpods" : "headphones"
            case kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeHDMI:
                return "display"
            case kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeThunderbolt:
                return "hifispeaker"
            case kAudioDeviceTransportTypeAirPlay:
                return "airplayaudio"
            case kAudioDeviceTransportTypeBuiltIn:
                return (lower.contains("headphone") || lower.contains("耳机")) ? "headphones" : "laptopcomputer"
            default:
                return "speaker.wave.2"
            }
        }
    }

    private static func isHidden(_ device: AudioDeviceID) -> Bool {
        var addr = address(kAudioDevicePropertyIsHidden)
        guard AudioObjectHasProperty(device, &addr) else { return false }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value)
        return value != 0
    }

    /// 能否被选为默认输出（会议/录屏软件的辅助虚拟设备常为否，系统设置里也不列出）。读不到按「能」处理。
    private static func canBeDefaultOutput(_ device: AudioDeviceID) -> Bool {
        var addr = address(kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeOutput)
        guard AudioObjectHasProperty(device, &addr) else { return true }
        var value: UInt32 = 1
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr else { return true }
        return value != 0
    }

    /// 当前所有可选的输出设备（系统枚举顺序）。
    static func outputDevices() -> [OutputDevice] {
        allOutputDevices().filter { !isHidden($0) && canBeDefaultOutput($0) }.map { device in
            OutputDevice(id: device,
                         uid: deviceUID(device) ?? "dev-\(device)",
                         name: name(of: device),
                         transport: transportType(of: device))
        }
    }

    /// 切换系统默认输出设备（声音输出）。只改默认输出，不动「播放声音效果的设备」：
    /// 公开 API 无法区分它是「跟随输出」还是用户特意指定的，猜错会覆盖用户设置，故与 SwitchAudioSource 一样不碰。
    @discardableResult
    static func setDefaultOutputDevice(_ device: AudioDeviceID) -> Bool {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var value = device
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                                          UInt32(MemoryLayout<AudioDeviceID>.size), &value) == noErr
    }

    /// 监听音频设备变化，在主线程回调，分两路：
    /// - onDevicesChange(defaultChanged)：默认输出变化 / 设备增减（需要重新枚举设备）；
    /// - onLevelChange：当前输出的音量或静音变化（含本 App 自己的写入，拖滑杆时每帧都会来，须保持轻量）。
    /// 当前默认设备变化时自动把音量/静音监听挪到新设备上。
    final class OutputObserver {
        private let onDevicesChange: (_ defaultChanged: Bool) -> Void
        private let onLevelChange: () -> Void
        private var watchedDevice: AudioDeviceID = 0
        private var systemBlock: AudioObjectPropertyListenerBlock?
        private var deviceBlock: AudioObjectPropertyListenerBlock?

        private static let systemSelectors = [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDevices]
        private static let deviceSelectors: [(AudioObjectPropertySelector, AudioObjectPropertyScope)] = [
            (0x766D_7663, kAudioObjectPropertyScopeOutput), // 'vmvc' 虚拟主音量
            (kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput),
        ]

        init(onDevicesChange: @escaping (_ defaultChanged: Bool) -> Void, onLevelChange: @escaping () -> Void) {
            self.onDevicesChange = onDevicesChange
            self.onLevelChange = onLevelChange
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self else { return }
                let changed = self.rewatchDefaultDevice()
                self.onDevicesChange(changed)
            }
            systemBlock = block
            for selector in Self.systemSelectors {
                var addr = AudioController.address(selector)
                AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, block)
            }
            rewatchDefaultDevice()
        }

        deinit {
            if let block = systemBlock {
                for selector in Self.systemSelectors {
                    var addr = AudioController.address(selector)
                    AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, block)
                }
            }
            unwatchDevice()
        }

        /// 默认输出设备换了就把音量/静音监听挪过去；返回是否发生了变化。
        @discardableResult
        private func rewatchDefaultDevice() -> Bool {
            let current = AudioController.defaultOutputDevice() ?? 0
            guard current != watchedDevice else { return false }
            unwatchDevice()
            guard current != 0 else { return true }
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.onLevelChange() }
            for (selector, scope) in Self.deviceSelectors {
                var addr = AudioController.address(selector, scope)
                if AudioObjectHasProperty(current, &addr) {
                    AudioObjectAddPropertyListenerBlock(current, &addr, .main, block)
                }
            }
            deviceBlock = block
            watchedDevice = current
            return true
        }

        private func unwatchDevice() {
            guard watchedDevice != 0, let block = deviceBlock else { return }
            for (selector, scope) in Self.deviceSelectors {
                var addr = AudioController.address(selector, scope)
                AudioObjectRemovePropertyListenerBlock(watchedDevice, &addr, .main, block)
            }
            deviceBlock = nil
            watchedDevice = 0
        }
    }
}
