//  InputSource.swift
//  LG 显示器输入源切换（合并自 SourceShift / InputShifter 项目）：
//  - 4 个输入源 Type C / DP / HDMI1 / HDMI2，走 LG 私有 VCP 0xF4（数据地址 0x50）。该寄存器只写不可读，无法回读校验。
//  - 全局快捷键 ⌘⇧1~4：Carbon RegisterEventHotKey，无需辅助功能权限；显示器正在显示别的输入源时也能「盲按」切回。
//  - 目标选择：鼠标所在的可 DDC 外接屏 → 第一台可 DDC 外接屏 → 兜底（全部 External 端点 → 系统默认服务）。
//    兜底用于「显示器切走后从 CGDisplay 列表消失」的拉回场景，与 SourceShift 的盲写策略一致。
//  注意：macOS 26+ 在显示器切走后可能拆除整条显示链路，此时 I²C 端点也随之消失、拉回会失败（系统行为）。

import AppKit
import Carbon

enum InputSource: Int, CaseIterable, Identifiable {
    case typeC = 1
    case displayPort = 2
    case hdmi1 = 3
    case hdmi2 = 4

    /// LG 私有输入源 VCP 码。
    static let lgVCP: UInt8 = 0xF4

    var id: Int { rawValue }

    /// 写入 0xF4 的值（与 SourceShift 完全一致）。
    var lgCode: UInt16 {
        switch self {
        case .typeC: return 0xD1
        case .displayPort: return 0xD0
        case .hdmi1: return 0x90
        case .hdmi2: return 0x91
        }
    }

    var title: String {
        switch self {
        case .typeC: return "Type C"
        case .displayPort: return "DP"
        case .hdmi1: return "HDMI1"
        case .hdmi2: return "HDMI2"
        }
    }

    var symbol: String {
        switch self {
        case .typeC: return "cable.connector"
        case .displayPort: return "display"
        case .hdmi1, .hdmi2: return "tv"
        }
    }

    /// Carbon 虚拟键码 kVK_ANSI_1 ~ kVK_ANSI_4。
    var keyCode: UInt32 {
        switch self {
        case .typeC: return UInt32(kVK_ANSI_1)
        case .displayPort: return UInt32(kVK_ANSI_2)
        case .hdmi1: return UInt32(kVK_ANSI_3)
        case .hdmi2: return UInt32(kVK_ANSI_4)
        }
    }

    var shortcutLabel: String { "⌘⇧\(rawValue)" }
}

// MARK: - 切换执行端

/// 所有方法在主线程调用。
final class InputSwitcher {
    /// 一次切换请求会落到的通道（自检用来断言目标选择，不实际写入）。
    enum Route: Equatable {
        case display(CGDirectDisplayID, name: String) // 匹配到的 DDC 外接屏
        case allExternal(count: Int)                  // 兜底：全部 External 端点
        case systemDefault                            // 最后兜底：系统默认 AVService
        case none
    }

    private let displayManager: DisplayManager
    /// 每台屏自己的请求计数（仅主线程）：同一台屏上有更新的请求、或其后发生了盲发时，旧请求的重试不再发，
    /// 免得覆盖用户最后的选择；换一台屏切换不影响另一台上旧请求的重试与提示。
    private var displayGeneration: [CGDirectDisplayID: Int] = [:]
    private let fallbackQueue = DispatchQueue(label: "lgcontroller.input.fallback", qos: .userInitiated)

    init(displayManager: DisplayManager) {
        self.displayManager = displayManager
    }

    /// 目标显示器：鼠标所在的可 DDC 外接屏；否则第一台可 DDC 的外接屏。
    func targetDisplay() -> DDCDisplay? {
        if let underMouse = displayManager.displayUnderMouse() as? DDCDisplay, underMouse.ddc != nil {
            return underMouse
        }
        return displayManager.displays.lazy.compactMap { $0 as? DDCDisplay }.first { $0.ddc != nil }
    }

    /// 本次请求会走哪条通道（只查询，不写入）。
    func plannedRoute() -> Route {
        if let display = targetDisplay() { return .display(display.id, name: display.name) }
        let count = DDCServiceMatcher.allExternalServices().count
        if count > 0 { return .allExternal(count: count) }
        return DDCServiceMatcher.defaultService() != nil ? .systemDefault : .none
    }

    func switchTo(_ source: InputSource) {
        DiagLog.write("输入源 请求 \(source.title)（0x\(String(source.lgCode, radix: 16, uppercase: true))） 路线=\(targetDisplay().map { "DDC屏「\($0.name)」" } ?? "兜底")")
        // OSD 显示在鼠标所在屏：被切换的那块屏此刻可能正在切走/黑屏，看不到提示
        let feedbackDisplay = displayManager.displayUnderMouse()?.id ?? CGMainDisplayID()
        let finish: (Bool) -> Void = { delivered in
            if delivered {
                OSD.showInputSource(source, on: feedbackDisplay)
            } else {
                NSSound.beep() // 与 SourceShift 一致：命令没能送达显示器时给出提示音
                OSD.showInputSourceFailed(source, on: feedbackDisplay)
            }
            NSLog("LGController: 输入源 → \(source.title)：\(delivered ? "已送达" : "未送达")")
            DiagLog.write("输入源 完成 \(source.title)：\(delivered ? "已送达（I²C 确认）→ 显示 OSD" : "未送达 → 提示音")")
        }

        guard let display = targetDisplay() else {
            // 盲发会写到所有端点：之前各屏还在重试的旧请求一律作废，免得旧重试落在这次之后把选择改回去
            for id in displayGeneration.keys { displayGeneration[id, default: 0] += 1 }
            sendViaFallback(source, completion: finish)
            return
        }
        displayGeneration[display.id, default: 0] += 1
        let displayGen = displayGeneration[display.id]!
        // 同一台屏上（或其后的盲发）有更新的请求 → 静默放弃（新请求会自己给出提示）
        let superseded: () -> Bool = { [weak self] in
            guard let self, self.displayGeneration[display.id] == displayGen else {
                DiagLog.write("输入源 \(source.title) 已被更新的请求取代，不再重试")
                return true
            }
            return false
        }
        display.sendInputSource(source.lgCode) { [weak self] delivered in
            if delivered { finish(true); return }
            guard !superseded() else { return }
            // 未被确认：先在该屏自己的队列上重试一次（同样等总线静默、同样时序）
            display.sendInputSource(source.lgCode) { retried in
                if retried { finish(true); return }
                guard let self, !superseded() else { return }
                // 仍失败：缓存的通道可能已失效（链路重协商），为这台屏重新匹配端点再发一次。
                // 只认能确认是这台屏的端点——绝不广播，免得切走用户没选的另一台显示器。
                self.sendViaRematchedService(source, to: display.id, completion: finish)
            }
        }
    }

    /// 重试兜底：为目标屏重新匹配 I²C 端点（匹配不上就放弃，不写到别的屏）。
    private func sendViaRematchedService(_ source: InputSource, to displayID: CGDirectDisplayID,
                                         completion: @escaping (Bool) -> Void) {
        fallbackQueue.async {
            guard let service = DDCServiceMatcher.freshService(for: displayID) else {
                DiagLog.write("输入源 重新匹配：找不到能确认属于该屏的端点，放弃")
                DispatchQueue.main.async { completion(false) }
                return
            }
            let rets = service.writeInputSourceLikeSourceShift(source.lgCode)
            DiagLog.write("输入源 重新匹配端点 IOReturn=\(rets.map { String(format: "0x%08X", $0) })")
            DispatchQueue.main.async { completion(rets.first == 0) }
        }
    }

    /// 兜底：写到所有 External 端点（显示器可能已从 CGDisplay 列表消失，但 I²C 端点仍在）；
    /// 一个都没有时再试系统默认服务。
    private func sendViaFallback(_ source: InputSource, completion: @escaping (Bool) -> Void) {
        fallbackQueue.async {
            var services = DDCServiceMatcher.allExternalServices()
            if services.isEmpty, let fallback = DDCServiceMatcher.defaultService() {
                services = [fallback]
            }
            DiagLog.write("输入源 兜底：External 端点 \(services.count) 个")
            var delivered = false
            for (i, service) in services.enumerated() {
                let rets = service.writeInputSourceLikeSourceShift(source.lgCode)
                DiagLog.write("输入源 兜底 端点\(i) IOReturn=\(rets.map { String(format: "0x%08X", $0) })")
                if rets.first == 0 { delivered = true }
            }
            DispatchQueue.main.async { completion(delivered) }
        }
    }
}

// MARK: - 全局快捷键 ⌘⇧1~4

final class InputHotKeys {
    static let signature: OSType = 0x4C47_4354 // 'LGCT'
    static let modifiers = UInt32(cmdKey | shiftKey)

    private let onInput: (InputSource) -> Void
    private var handlerRef: EventHandlerRef?
    private var hotKeyRefs: [EventHotKeyRef] = []
    /// 每个组合键的注册结果：noErr 为成功；被本进程重复注册时为 eventHotKeyExistsErr。
    private(set) var status: [InputSource: OSStatus] = [:]

    init(onInput: @escaping (InputSource) -> Void) {
        self.onInput = onInput
    }

    deinit {
        unregister()
    }

    func register() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), inputHotKeyHandler, 1, &spec,
                            Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
        for source in InputSource.allCases {
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: Self.signature, id: UInt32(source.rawValue))
            let err = RegisterEventHotKey(source.keyCode, Self.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
            status[source] = err
            if err == noErr, let ref = ref {
                hotKeyRefs.append(ref)
            } else {
                NSLog("LGController: 快捷键 \(source.shortcutLabel) 注册失败（\(err)）")
            }
        }
    }

    func unregister() {
        hotKeyRefs.forEach { UnregisterEventHotKey($0) }
        hotKeyRefs.removeAll()
        if let handlerRef = handlerRef { RemoveEventHandler(handlerRef) }
        handlerRef = nil
        status.removeAll()
    }

    fileprivate func dispatch(id: UInt32) {
        guard let source = InputSource(rawValue: Int(id)) else { return }
        onInput(source)
    }
}

/// Carbon 回调：取出 EventHotKeyID，按签名过滤后分发到对应输入源。
private func inputHotKeyHandler(_: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event = event, let userData = userData else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let err = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
    guard err == noErr, hotKeyID.signature == InputHotKeys.signature else { return OSStatus(eventNotHandledErr) }
    Unmanaged<InputHotKeys>.fromOpaque(userData).takeUnretainedValue().dispatch(id: hotKeyID.id)
    return noErr
}
