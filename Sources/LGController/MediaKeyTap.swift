//  MediaKeyTap.swift
//  CGEventTap 拦截系统媒体键（NX_SYSDEFINED，subtype 8）：亮度±、音量±、静音。
//  需要「辅助功能」权限；未授权时 tapCreate 返回 nil，由 AppDelegate 定时重试。

import AppKit
import Foundation

enum MediaKey {
    case volumeUp, volumeDown, brightnessUp, brightnessDown, mute

    init?(nxKeyType: Int32) {
        switch nxKeyType {
        case 0: self = .volumeUp // NX_KEYTYPE_SOUND_UP
        case 1: self = .volumeDown // NX_KEYTYPE_SOUND_DOWN
        case 2: self = .brightnessUp // NX_KEYTYPE_BRIGHTNESS_UP
        case 3: self = .brightnessDown // NX_KEYTYPE_BRIGHTNESS_DOWN
        case 7: self = .mute // NX_KEYTYPE_MUTE
        default: return nil
        }
    }
}

final class MediaKeyTap {
    /// 返回 true 表示吞掉该事件（由我们处理），false 则放行给系统。
    var handler: ((MediaKey, _ pressed: Bool, _ isRepeat: Bool, _ modifiers: NSEvent.ModifierFlags) -> Bool)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// 诊断：本次启动已记下的「收到但不处理」的系统按键事件条数（只在主线程访问）。
    private var unhandledLogged = 0

    @discardableResult
    func start() -> Bool {
        guard eventTap == nil else { return true }
        let mask = CGEventMask(1 << 14) // NX_SYSDEFINED
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
            let tap = Unmanaged<MediaKeyTap>.fromOpaque(refcon).takeUnretainedValue()
            return tap.handle(type: type, event: event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .defaultTap,
                                          eventsOfInterest: mask,
                                          callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            return false
        }
        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        NSLog("LGController: 媒体键监听已启动")
        return true
    }

    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        runLoopSource = nil
        eventTap = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // 系统在回调过慢/用户干预时会禁用 tap，这里自动恢复
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            DiagLog.write("媒体键监听被系统暂停（\(type == .tapDisabledByTimeout ? "回调超时" : "用户操作")），已重新启用")
            return Unmanaged.passUnretained(event)
        }
        guard type.rawValue == 14, // NX_SYSDEFINED
              let nsEvent = NSEvent(cgEvent: event) else {
            return Unmanaged.passUnretained(event)
        }
        let subtype = nsEvent.subtype.rawValue
        guard subtype == 8 else { // NX_SUBTYPE_AUX_CONTROL_BUTTONS
            // subtype 7 是鼠标按键（每次点击都有），不记；其余记下来，排查「按键没到 App」用
            if subtype != 7 { logUnhandled("系统事件 subtype=\(subtype)（不是媒体键，放行）") }
            return Unmanaged.passUnretained(event)
        }

        let data1 = nsEvent.data1
        let keyCode = Int32((data1 & 0xFFFF_0000) >> 16)
        let keyFlags = data1 & 0x0000_FFFF
        let pressed = ((keyFlags & 0xFF00) >> 8) == 0x0A
        let isRepeat = (keyFlags & 0x1) == 1

        guard let key = MediaKey(nxKeyType: keyCode) else {
            if pressed { logUnhandled("系统按键 类型码=\(keyCode)（不是亮度/音量/静音，放行）") }
            return Unmanaged.passUnretained(event)
        }
        let consumed = handler?(key, pressed, isRepeat, nsEvent.modifierFlags) ?? false
        return consumed ? nil : Unmanaged.passUnretained(event)
    }

    /// 诊断日志：收到但不处理的系统按键事件（每次启动最多记 50 条，避免刷屏）。
    private func logUnhandled(_ message: String) {
        guard unhandledLogged < 50 else { return }
        unhandledLogged += 1
        DiagLog.write(message)
    }
}
