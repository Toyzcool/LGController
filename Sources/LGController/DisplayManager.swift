//  DisplayManager.swift
//  显示器枚举、分类（苹果协议 vs DDC）与「鼠标所在屏幕」定位。

import AppKit
import CoreAudio
import Foundation

final class DisplayManager {
    private(set) var displays: [Display] = []

    /// 重新枚举显示器并匹配 DDC 通道。在主线程调用。
    func rebuild() {
        displays.forEach { $0.invalidate() }
        var newDisplays: [Display] = []

        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        CGGetOnlineDisplayList(16, &ids, &count)
        let onlineIDs = Array(ids.prefix(Int(count))).filter {
            // 跳过镜像从属屏：控制主屏即可
            CGDisplayMirrorsDisplay($0) == 0
        }

        var ddcCandidateIDs: [CGDirectDisplayID] = []
        for id in onlineIDs {
            if Self.isAppleProtocol(id) {
                newDisplays.append(AppleProtocolDisplay(id: id, name: Self.displayName(id)))
            } else if !Self.isVirtual(id) {
                ddcCandidateIDs.append(id)
            } else {
                NSLog("LGController: 跳过虚拟显示器 \(id) (\(Self.displayName(id)))")
            }
        }

        let services = DDCServiceMatcher.match(displayIDs: ddcCandidateIDs)
        for id in ddcCandidateIDs {
            let name = Self.displayName(id)
            newDisplays.append(DDCDisplay(id: id, name: name, ddc: services[id]))
            if let service = services[id] {
                DiagLog.write("DDC 通道 \(name)[\(id)] → \(service.transportName)")
            } else {
                NSLog("LGController: 显示器 \(name) 未匹配到 DDC 通道")
                DiagLog.write("DDC 通道 \(name)[\(id)] → 未匹配（亮度/音量/输入源不可控）")
            }
        }

        displays = newDisplays.sorted { !$0.isBuiltin && $1.isBuiltin } // 外接屏排前面
        NotificationCenter.default.post(name: .lgControllerStateDidChange, object: nil)
    }

    /// 鼠标当前所在屏幕对应的显示器。
    func displayUnderMouse() -> Display? {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) else {
            return displays.first
        }
        guard let screenID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return displays.first
        }
        // 若鼠标在镜像从属屏上，归并到镜像主屏
        var effectiveID = screenID
        let mirrored = CGDisplayMirrorsDisplay(screenID)
        if mirrored != 0 { effectiveID = mirrored }
        return displays.first { $0.id == effectiveID } ?? displays.first
    }

    /// 某个音频设备（通常是显示器的 DP/HDMI 音频）对应的、可 DDC 控制音量的显示器。
    /// 用于「默认输出是显示器自带音频且不可由 CoreAudio 调节」时，回退到 DDC 控制该屏。
    func ddcDisplay(forAudioDevice device: AudioDeviceID) -> DDCDisplay? {
        let ddcDisplays = displays.compactMap { $0 as? DDCDisplay }.filter { $0.canVolume }
        guard !ddcDisplays.isEmpty else { return nil }
        // 多台都对得上（如两台同型号「LG HDR 4K (1)/(2)」对同名音频设备）无法判定是哪台 → 不猜，返回 nil，
        // 弹窗改用各屏卡片里的音量行，按键走鼠标所在屏兜底。
        let candidates = ddcCandidates(forAudioDevice: device)
        if candidates.count == 1 { return candidates[0] }
        if candidates.count > 1 { return nil }
        // 名称失配兜底：设备是显示器自带音频(DP/HDMI)且系统仅一台可 DDC 控制音量的外接屏 → 认定就是它，
        // 避免回退到内建扬声器（声音其实从显示器出，调内建扬声器毫无反应，非常反直觉）。
        if AudioController.isDisplayAudio(device), ddcDisplays.count == 1 {
            return ddcDisplays.first
        }
        return nil
    }

    /// 名称对得上该音频设备的可 DDC 调音量显示器：精确匹配（忽略大小写/空格）优先，没有再用包含关系。
    /// 返回 ≥2 台 = 同名歧义（弹窗据此提示去各屏卡片调）。
    func ddcCandidates(forAudioDevice device: AudioDeviceID) -> [DDCDisplay] {
        let ddcDisplays = displays.compactMap { $0 as? DDCDisplay }.filter { $0.canVolume }
        let normalize = { (s: String) in s.lowercased().replacingOccurrences(of: " ", with: "") }
        let audioName = normalize(AudioController.name(of: device))
        guard !audioName.isEmpty else { return [] }
        let exact = ddcDisplays.filter { normalize($0.name) == audioName }
        if !exact.isEmpty { return exact }
        return ddcDisplays.filter {
            let displayName = normalize($0.name)
            return !displayName.isEmpty && (displayName.contains(audioName) || audioName.contains(displayName))
        }
    }

    // MARK: 分类

    /// 与 MonitorControl 一致：DisplayServices 能读到亮度 → 苹果协议屏；内建屏恒为苹果协议。
    static func isAppleProtocol(_ id: CGDirectDisplayID) -> Bool {
        if CGDisplayIsBuiltin(id) != 0 { return true }
        guard let get = PrivateAPI.displayServicesGetBrightness else { return false }
        var value: Float = -1
        return get(id, &value) == 0 && value >= 0
    }

    static func isVirtual(_ id: CGDirectDisplayID) -> Bool {
        guard let info = PrivateAPI.displayInfoDictionary(id) else { return false }
        return (info["kCGDisplayIsVirtualDevice"] as? Bool) ?? false
    }

    static func displayName(_ id: CGDirectDisplayID) -> String {
        if let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == id
        }) {
            return screen.localizedName
        }
        if let info = PrivateAPI.displayInfoDictionary(id),
           let names = info["DisplayProductName"] as? [String: String],
           let name = names["zh_CN"] ?? names["en_US"] ?? names.first?.value {
            return name
        }
        return CGDisplayIsBuiltin(id) != 0 ? "内建显示器" : "显示器 \(id)"
    }
}
