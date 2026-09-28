//  SelfTest.swift
//  `LGController --selftest`：不进入 GUI，验证显示器枚举、DDC 匹配、平滑亮度写入与回读，然后退出。
//  亮度会短暂下调一档再复原，属预期现象。

import AppKit
import Carbon
import CoreAudio
import Foundation

/// `LGController --osdtest`：在每个屏幕右上角依次演示 HUD 三种状态（亮度 / 音量 / 静音）后退出。
func runOSDTest() -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    var delay: TimeInterval = 0.3
    for screen in NSScreen.screens {
        guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { continue }
        print("HUD 演示 → \(screen.localizedName) [id=\(id)]")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { OSD.showBrightness(5.0 / 16, on: id) }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.9) { OSD.showVolume(0.5, muted: false, on: id) }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 1.8) { OSD.showVolume(0, muted: true, on: id) }
        delay += 2.7
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + delay + 1.7) { exit(0) }
    app.run()
    exit(0)
}

func runSelfTest() -> Never {
    print("=== LGController 自检 ===")
    // 从 .build/release 直接运行时没有 bundle id，UserDefaults 落在进程名域「LGController」而非 App 的
    // com.toyzcool.LGController：先把 App 保存的各屏状态拷过来，DDC 读不到时才能按 App 的真实状态还原。
    // 先清掉本进程域里历次自检留下的旧值（否则会被误当成 App 状态），再拷贝。只在非 bundle 模式做——
    // 从 App 包内运行时进程域就是 App 自己的域，清了会丢掉真实状态。
    let appDomain = "com.toyzcool.LGController"
    let statePrefixes = ["volume-", "muted-", "premute-", "brightness-"]
    if Bundle.main.bundleIdentifier != appDomain {
        for key in UserDefaults.standard.dictionaryRepresentation().keys where statePrefixes.contains(where: { key.hasPrefix($0) }) {
            UserDefaults.standard.removeObject(forKey: key)
        }
        for (key, value) in UserDefaults.standard.persistentDomain(forName: appDomain) ?? [:]
        where statePrefixes.contains(where: { key.hasPrefix($0) }) {
            UserDefaults.standard.set(value, forKey: key)
        }
    }
    let manager = DisplayManager()
    manager.rebuild()

    func pumpRunLoop(seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    var failures = 0

    // 步进规则（与系统内建屏一致）：非网格值先对齐相邻线；可精确归零/到顶
    let sixteenth: Float = 1 / 16
    let gridCases: [(from: Float, up: Bool, expect: Float, desc: String)] = [
        (0.21, false, 0.1875, "非网格值向下对齐到 3/16"),
        (0.21, true, 0.25, "非网格值向上对齐到 4/16"),
        (0.25, true, 0.3125, "网格值向上走一整档"),
        (0.25, false, 0.1875, "网格值向下走一整档"),
        (0.03, false, 0.0, "低于一档时归零"),
        (0.0, false, 0.0, "0 之下夹紧"),
        (1.0, true, 1.0, "1 之上夹紧"),
        (0.97, true, 1.0, "接近顶端时到满"),
        (0.0625, false, 0.0, "一档整降到 0"),
    ]
    for c in gridCases {
        let got = Display.gridStep(c.from, step: sixteenth, up: c.up)
        let ok = abs(got - c.expect) < 0.0001
        print("gridStep \(c.desc): \(c.from) → \(got) (期望 \(c.expect)) \(ok ? "✅" : "❌")")
        if !ok { failures += 1 }
    }
    // fine(1/64) 与常规档位混用后仍可归零
    var mixed: Float = 0.0625 + 1 / 64
    mixed = Display.gridStep(mixed, step: sixteenth, up: false) // → 0.0625
    mixed = Display.gridStep(mixed, step: sixteenth, up: false) // → 0
    if abs(mixed) > 0.0001 {
        print("gridStep fine 混用归零 ❌ (got \(mixed))")
        failures += 1
    } else {
        print("gridStep fine 混用归零 ✅")
    }

    // LG(DDC) 音量：1/100 步长 = 每次 ±1 单位（满格 100）
    let hundredth: Float = 1.0 / 100
    let volCases: [(from: Float, up: Bool, expect: Float, desc: String)] = [
        (0.50, true, 0.51, "50 → 51（+1）"),
        (0.50, false, 0.49, "50 → 49（−1）"),
        (0.01, false, 0.0, "1 → 0（归零）"),
        (0.99, true, 1.0, "99 → 100（满格）"),
        (1.0, true, 1.0, "100 封顶"),
        (0.0, false, 0.0, "0 夹紧"),
    ]
    for c in volCases {
        let got = Display.gridStep(c.from, step: hundredth, up: c.up)
        let ok = abs(got - c.expect) < 0.0001
        print("DDC音量步长 \(c.desc): \(Int((c.from*100).rounded())) → \(Int((got*100).rounded())) \(ok ? "✅" : "❌")")
        if !ok { failures += 1 }
    }
    // 从满格连按 100 次应恰好到 0
    var v: Float = 1.0
    for _ in 0 ..< 100 { v = Display.gridStep(v, step: hundredth, up: false) }
    let toZeroOK = abs(v) < 0.0001
    print("DDC音量 100→按100次→\(Int((v*100).rounded())) \(toZeroOK ? "✅" : "❌")")
    if !toZeroOK { failures += 1 }

    // 等待 DDC 后台校准读真正完成：排空各显示器串行队列，再转动主循环让 adopt 回调落地。
    // 之后所有硬件读写都走 debugOnQueue，避免与队列上的读写抢 I²C 总线。
    for display in manager.displays {
        _ = (display as? DDCDisplay)?.debugOnQueue { _ in () }
    }
    pumpRunLoop(seconds: 0.3)
    for display in manager.displays {
        let kind = display is DDCDisplay ? "DDC" : "Apple/内建"
        print("显示器: \(display.name) [id=\(display.id)] 类型=\(kind) 亮度可控=\(display.canBrightness) 音量可控=\(display.canVolume)")
    }

    for display in manager.displays where display.canBrightness {
        let original = display.brightness
        let target = max(original - 1.0 / 16, 0)
        print("→ \(display.name): 亮度 \(String(format: "%.3f", original)) 平滑调至 \(String(format: "%.3f", target)) …")
        display.setBrightness(target)
        pumpRunLoop(seconds: 1.0)

        if let ddcDisplay = display as? DDCDisplay {
            if let (current, maxValue) = ddcDisplay.debugOnQueue({ $0.read(.brightness) }) ?? nil {
                let hw = Float(current) / Float(maxValue)
                let ok = abs(hw - target) <= 0.02
                print("   DDC 回读: \(current)/\(maxValue) (=\(String(format: "%.3f", hw))) 期望 \(String(format: "%.3f", target)) → \(ok ? "✅" : "❌")")
                if !ok { failures += 1 }
            } else {
                print("   DDC 回读失败 ❌")
                failures += 1
            }
        } else if let get = PrivateAPI.displayServicesGetBrightness {
            var hw: Float = -1
            _ = get(display.id, &hw)
            let ok = abs(hw - target) <= 0.02
            print("   DisplayServices 回读: \(String(format: "%.3f", hw)) 期望 \(String(format: "%.3f", target)) → \(ok ? "✅" : "❌")")
            if !ok { failures += 1 }
        }

        display.setBrightness(original)
        pumpRunLoop(seconds: 1.0)
        print("   已恢复至 \(String(format: "%.3f", original))")
    }

    // DDC 硬件静音(0x8D) 读写验证：LG 有独立于音量的硬件静音，
    // 只写音量无法解除 → "静音后调高音量仍无声"。修复须能写/读 0x8D。
    for display in manager.displays {
        guard let dd = display as? DDCDisplay, dd.ddc != nil else { continue }
        // DDC 回读偶发失败：写后留沉降时间再读，并重试几次（全部在显示器队列上执行）
        func readMuteSettled() -> UInt16? {
            dd.debugOnQueue { ddc -> UInt16? in
                for _ in 0 ..< 4 {
                    usleep(200_000)
                    if let v = ddc.read(.mute)?.current { return v }
                }
                return nil
            } ?? nil
        }
        func write(_ vcp: VCP, _ value: UInt16) { _ = dd.debugOnQueue { $0.write(vcp, value) } }
        let orig = readMuteSettled()                                   // 记录测试前的 0x8D，收尾还原
        let origVol = dd.debugOnQueue({ $0.read(.volume)?.current }) ?? nil // 音量同样记录还原
        // 硬件读不到时退回 App 保存的状态；连保存状态都没有就不猜（不写回，只还原静音位）
        let hasSaved = UserDefaults.standard.object(forKey: "volume-\(dd.uuid)") != nil
        let savedVol: UInt16? = hasSaved ? UInt16((dd.volume * 100).rounded()) : nil
        write(.mute, 1); let m1 = readMuteSettled()
        // 实测(LG)：音量为 0 时写 0x8D=2 会被忽略——解除静音必须先有非零音量，
        // 这正是 applyVolumeToHardware 采用「先写音量、再解除静音」顺序的原因。
        write(.volume, max(origVol ?? 30, 1))
        write(.mute, 2); let m2 = readMuteSettled()
        // 音量读不到时按保存的状态写回（不能留在临时的 30）
        if let v = origVol ?? savedVol { write(.volume, v) }
        write(.mute, orig ?? (hasSaved && dd.muted ? 1 : 2))          // 还原（都读不到则默认未静音）
        let ok = m1 == 1 && m2 == 2
        print("DDC 硬件静音 0x8D[\(display.name)]: 写1读=\(m1.map(String.init) ?? "nil") 写2读=\(m2.map(String.init) ?? "nil") \(ok ? "✅" : "❌")")
        if !ok { failures += 1 }
    }

    // DDC 音量状态机端到端验证（驱动真实 DDCDisplay + 回读硬件）：
    // 需求① 点击静音后音量变为 0；需求② 音量 >0 即解除静音，步长恒为 ±1
    for display in manager.displays {
        guard let dd = display as? DDCDisplay, dd.ddc != nil else { continue }
        print("DDC 音量状态机[\(display.name)]:")
        let origVol = dd.debugOnQueue({ $0.read(.volume)?.current }) ?? nil
        let origMute = dd.debugOnQueue({ $0.read(.mute)?.current }) ?? nil
        // 硬件读不到时（LG HDR 4K 的 0x62/0x8D 读不应答）按 App 保存的状态还原，
        // 否则会把该屏扬声器留在测试末尾的 1%；没有保存状态（从未用过）就不猜
        let logicalVol = dd.volume, logicalMuted = dd.muted
        let hasSavedState = UserDefaults.standard.object(forKey: "volume-\(dd.uuid)") != nil
        let savedPremute = UserDefaults.standard.object(forKey: "premute-\(dd.uuid)") // 测试会改写「静音前音量」，收尾写回
        let unit = 1.0 / 100.0 as Float // LG 的 maxVolume 通常为 100

        /// 等异步写入落地后回读硬件（音量, 静音）。
        /// 必须走 debugReadHardwareVolume（显示器自己的串行队列），否则读会与队列上的写抢 I2C 总线、读到落后值。
        func hw() -> (vol: Int, mute: Int) {
            pumpRunLoop(seconds: 0.6) // 等写入落地 + 显示器沉降（LG 刚写完立刻读会报旧值）
            return dd.debugReadHardwareVolume() ?? (9999, 9999)
        }
        // 起点：音量 5、未静音。先判断该屏的音量能否回读：有的显示器（如 LG HDR 4K）对 0x62 读请求
        // 只回 DDC 空消息，此时无法做硬件回读验证——只校验状态机逻辑，并如实标注，而不是误报失败。
        dd.setVolume(5 * unit)
        var s = hw()
        let readBack = s.vol != 9999
        if !readBack {
            print("   ⚠️ 该屏音量 VCP(0x62) 不可回读（读请求只得到空消息）：以下只校验状态机逻辑，未做硬件回读验证")
        }
        /// logic：状态机本身的断言；hardware：硬件回读断言（不可回读时不参与判定）
        func check(_ label: String, logic: Bool, hardware: Bool) {
            let ok = logic && (!readBack || hardware)
            let note = readBack ? "" : "（仅逻辑）"
            print("   \(label) \(ok ? "✅" : "❌")\(note)")
            if !ok { failures += 1 }
        }
        check("起点 音量=5 未静音 (硬件 vol=\(s.vol) mute=\(s.mute))",
              logic: abs(dd.volume - 5 * unit) < 0.0001 && !dd.muted, hardware: s.vol == 5 && s.mute == 2)

        // 需求①：静音 → 状态音量归 0，硬件 0x8D=1
        let didMute = dd.toggleMute()
        s = hw()
        check("静音后 状态muted=\(didMute) 状态音量=\(Int((dd.volume * 100).rounded())) 硬件 vol=\(s.vol) mute=\(s.mute)",
              logic: didMute && dd.volume == 0, hardware: s.vol == 0 && s.mute == 1)

        // 需求②：静音态按 + → 解除静音且恰好为 1（不跳到 6/旧值）
        let after = dd.stepVolume(up: true, fine: false)
        s = hw()
        check("静音态 +1 → 状态音量=\(Int((after * 100).rounded())) muted=\(dd.muted) 硬件 vol=\(s.vol) mute=\(s.mute)",
              logic: abs(after - unit) < 0.0001 && !dd.muted, hardware: s.vol == 1 && s.mute == 2)

        // 步长恒为 1：连加 2 次 → 3
        dd.stepVolume(up: true, fine: false)
        let three = dd.stepVolume(up: true, fine: false)
        s = hw()
        check("再 +1 +1 → 状态音量=\(Int((three * 100).rounded())) 硬件 vol=\(s.vol)",
              logic: abs(three - 3 * unit) < 0.0001, hardware: s.vol == 3)

        // 逐级降到 0：3 → 2 → 1 → 0，最低必须能到 0（且自动静音）
        dd.stepVolume(up: false, fine: false)
        let two = dd.volume
        dd.stepVolume(up: false, fine: false)
        let one = dd.volume
        let zero = dd.stepVolume(up: false, fine: false)
        s = hw()
        check("逐级 -1: 2=\(Int((two * 100).rounded())) 1=\(Int((one * 100).rounded())) 0=\(Int((zero * 100).rounded())) muted=\(dd.muted) 硬件 vol=\(s.vol) mute=\(s.mute)",
              logic: abs(two - 2 * unit) < 0.0001 && abs(one - unit) < 0.0001 && zero == 0 && dd.muted,
              hardware: s.vol == 0 && s.mute == 1)

        // 从 0 再 +1 → 1 并解除静音
        let backUp = dd.stepVolume(up: true, fine: false)
        s = hw()
        check("0 再 +1 → 状态音量=\(Int((backUp * 100).rounded())) muted=\(dd.muted) 硬件 vol=\(s.vol) mute=\(s.mute)",
              logic: abs(backUp - unit) < 0.0001 && !dd.muted, hardware: s.vol == 1 && s.mute == 2)

        // 还原测试前状态
        if let v = origVol {
            dd.setVolume(Float(v) / 100.0)
            pumpRunLoop(seconds: 0.4)
            if origMute == 1 { _ = dd.debugOnQueue { $0.write(.mute, 1) } }
            print("   已还原 音量=\(v) 静音=\(origMute.map(String.init) ?? "?")")
        } else if hasSavedState {
            dd.setVolume(logicalMuted ? 0 : logicalVol) // 音量 0 即静音（静音 ⟺ 音量 0）
            if let p = savedPremute { UserDefaults.standard.set(p, forKey: "premute-\(dd.uuid)") }
            pumpRunLoop(seconds: 0.4)
            print("   硬件读不到，按 App 保存的状态还原：音量=\(Int((logicalVol * 100).rounded())) 静音=\(logicalMuted)")
        } else {
            print("   ⚠️ 硬件读不到、App 也无保存状态：无法还原该屏扬声器音量（停在测试末尾的 1%）")
        }
    }

    // 音量路由验证：只跟随当前输出源——无论鼠标在哪块屏，都应解析到同一个目标（= 声音实际播放处）
    let router = KeyRouter(displayManager: manager)
    let defaultDev = AudioController.defaultOutputDevice()
    let defaultSettable = defaultDev.map { AudioController.hasSettableVolume($0) } ?? false
    print("当前输出源：\(defaultDev.map { AudioController.name(of: $0) } ?? "无") CoreAudio可调=\(defaultSettable)")
    for display in manager.displays {
        let target = router.volumeTarget(for: display)
        var got = ""
        var ok = false
        switch target {
        case .ddc(let d): got = "DDC「\(d.name)」扬声器"
        case .coreAudio(let d): got = "CoreAudio「\(AudioController.name(of: d))」"
        case .none: got = "不可控"
        }
        if defaultSettable {
            // 输出源可由 CoreAudio 调节 → 任意屏都必须指向它，与鼠标所在屏无关
            if case .coreAudio(let d) = target, d == defaultDev { ok = true }
        } else if let dev = defaultDev, let expected = manager.ddcDisplay(forAudioDevice: dev) {
            // 输出源是某显示器 DP/HDMI 音频 → 任意屏都必须指向那台屏的 DDC
            if case .ddc(let d) = target, d === expected { ok = true }
        } else {
            ok = true // 无可调输出源，兜底行为不做强约束
        }
        print("音量路由[鼠标在 \(display.name)]: \(got) \(ok ? "✅" : "❌")")
        if !ok { failures += 1 }
    }

    // CoreAudio 音量可从（可能被设备量化过的）非零值精确降到 0（真静音），再还原
    if let defaultDev = defaultDev, AudioController.hasSettableVolume(defaultDev) {
        let originalVol = AudioController.volume(of: defaultDev) ?? 0.5
        let originalMuted = AudioController.isMuted(defaultDev)
        // 先在硬件上设一个非网格起点，模拟"设备把设定值量化成非整档"的真实场景
        _ = AudioController.setMuted(defaultDev, false)
        AudioController.setVolume(defaultDev, 0.34)
        pumpRunLoop(seconds: 0.15)
        var value = AudioVolume.shared.displayVolume(defaultDev) // 从硬件初始化意图值
        print("降到 0 起点：硬件≈\(String(format: "%.4f", AudioController.volume(of: defaultDev) ?? -1)) 意图=\(String(format: "%.4f", value))")
        var steps = 0
        while value > 0, steps < 40 {
            value = AudioVolume.shared.step(defaultDev, up: false, fine: false)
            steps += 1
        }
        let reachedZero = value == 0
        let hwZero = (AudioController.volume(of: defaultDev) ?? 1) <= 0.0001
        let hwMuted = AudioController.isMuted(defaultDev)
        print("降到 0：value=\(value) 步数=\(steps) 硬件音量≈\(String(format: "%.4f", AudioController.volume(of: defaultDev) ?? -1)) 硬件静音=\(hwMuted) → \((reachedZero && (hwZero || hwMuted)) ? "✅" : "❌")")
        if !(reachedZero && (hwZero || hwMuted)) { failures += 1 }
        // 从 0 升一档应解除静音
        let up = AudioVolume.shared.step(defaultDev, up: true, fine: false)
        let unmuted = !AudioController.isMuted(defaultDev) && up > 0
        print("从 0 升一档解除静音：value=\(String(format: "%.4f", up)) 未静音=\(unmuted) → \(unmuted ? "✅" : "❌")")
        if !unmuted { failures += 1 }
        // 还原
        AudioVolume.shared.setVolume(defaultDev, originalVol)
        _ = AudioController.setMuted(defaultDev, originalMuted)
        print("   已还原音量至 \(String(format: "%.3f", originalVol))\(originalMuted ? "（静音）" : "")")
    }

    // ===== 音量模块：输出源选择 + 与按键共用同一套路由 =====
    print("音量模块:")
    let volumeControl = VolumeControl(displayManager: manager)
    let outputs = volumeControl.outputDevices()
    let currentOut = volumeControl.currentOutputID
    print("   输出源列表: \(outputs.map { "\($0.name)[\($0.symbol)]" }.joined(separator: " / "))")
    let listOK = !outputs.isEmpty && outputs.contains { $0.id == currentOut }
    print("   当前输出源在列表中: \(currentOut.map { AudioController.name(of: $0) } ?? "无") \(listOK ? "✅" : "❌")")
    if !listOK { failures += 1 }
    // 选择「当前」输出源 = 空操作，验证切换接口可用但不改变用户的声音路由
    if let cur = currentOut {
        let setOK = AudioController.setDefaultOutputDevice(cur) && AudioController.defaultOutputDevice() == cur
        print("   切换输出源接口（设为当前，无副作用）\(setOK ? "✅" : "❌")")
        if !setOK { failures += 1 }
    }
    // 弹窗音量卡片与音量键必须解析到同一目标
    func describe(_ t: VolumeControl.Target) -> String {
        switch t {
        case .coreAudio(let d): return "CoreAudio#\(d)"
        case .ddc(let d): return "DDC#\(d.id)"
        case .none: return "none"
        }
    }
    // 当前输出源本身可调（CoreAudio 可设 / 对得上 DDC 屏）时，两边必须一致；
    // 调不了时弹窗如实显示不可调（.none），按键才走鼠标所在屏兜底——此时不比较。
    let uiTarget = describe(volumeControl.outputTarget())
    let lvl = volumeControl.level()
    if case .none = volumeControl.outputTarget() {
        let keys = manager.displays.map { describe(router.volumeTarget(for: $0)) }.joined(separator: " / ")
        print("   当前输出源不可调 → 弹窗显示不可调，按键兜底 [\(keys)] ✅")
    } else {
        var sameRule = true
        for display in manager.displays where describe(router.volumeTarget(for: display)) != uiTarget {
            sameRule = false
        }
        print("   弹窗与按键同一目标 \(uiTarget)，音量=\(String(format: "%.3f", lvl.volume)) 静音=\(lvl.muted) 可调=\(lvl.controllable) \(sameRule ? "✅" : "❌")")
        if !sameRule { failures += 1 }
    }

    // ===== 输入源切换（合并自 SourceShift）=====
    // 全部不向显示器发送真实切换命令：切走会让显示器黑屏，macOS 26+ 甚至可能拆链路、需重插线才能恢复。
    print("输入源切换:")

    // ① 组包逐字节对齐 SourceShift 实际发出的字节（基准取自编译 SourceShift 仓库 DDC/i2c.m 的 prepareDDCWrite 输出）
    let reference: [(InputSource, [UInt8])] = [
        (.typeC, [0x84, 0x03, 0xF4, 0x00, 0xD1, 0x9C]),
        (.displayPort, [0x84, 0x03, 0xF4, 0x00, 0xD0, 0x9D]),
        (.hdmi1, [0x84, 0x03, 0xF4, 0x00, 0x90, 0xDD]),
        (.hdmi2, [0x84, 0x03, 0xF4, 0x00, 0x91, 0xDC]),
    ]
    for (source, expected) in reference {
        let got = DDCService.writePacket(code: InputSource.lgVCP, value: source.lgCode,
                                         dataAddress: DDCService.lgInputDataAddress)
        let hex = got.map { String(format: "%02X", $0) }.joined(separator: " ")
        let ok = got == expected
        print("   组包 \(source.title)(\(source.shortcutLabel)) @0x50: \(hex) \(ok ? "✅" : "❌")")
        if !ok { failures += 1 }
    }
    // 同一组包函数下，既有标准路径（0x51）也必须与 SourceShift 算法一致：音量 30
    let vol30 = DDCService.writePacket(code: VCP.volume.rawValue, value: 30, dataAddress: DDCService.standardDataAddress)
    let vol30OK = vol30 == [0x84, 0x03, 0x62, 0x00, 0x1E, 0xC4]
    print("   组包 标准VCP 音量30 @0x51: \(vol30.map { String(format: "%02X", $0) }.joined(separator: " ")) \(vol30OK ? "✅" : "❌")")
    if !vol30OK { failures += 1 }

    // ② 快捷键：注册 ⌘⇧1~4，并把合成的 Carbon 热键事件投递给应用事件目标，验证分发到正确输入源
    var dispatched: [InputSource] = []
    let hotKeys = InputHotKeys { dispatched.append($0) }
    hotKeys.register()
    for source in InputSource.allCases {
        let status = hotKeys.status[source] ?? OSStatus(-1)
        print("   快捷键 \(source.shortcutLabel) 注册: \(status == noErr ? "成功" : "失败(\(status))") \(status == noErr ? "✅" : "❌")")
        if status != noErr { failures += 1 }
    }
    for source in InputSource.allCases {
        var event: EventRef?
        CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), GetCurrentEventTime(),
                    EventAttributes(kEventAttributeNone), &event)
        var hotKeyID = EventHotKeyID(signature: InputHotKeys.signature, id: UInt32(source.rawValue))
        SetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                          MemoryLayout<EventHotKeyID>.size, &hotKeyID)
        SendEventToEventTarget(event, GetApplicationEventTarget())
        ReleaseEvent(event)
    }
    // 其他签名的热键（例如别的模块/App 的）不应被误分发
    var foreign: EventRef?
    CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), GetCurrentEventTime(),
                EventAttributes(kEventAttributeNone), &foreign)
    var foreignID = EventHotKeyID(signature: 0x5858_5858, id: 1)
    SetEventParameter(foreign, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                      MemoryLayout<EventHotKeyID>.size, &foreignID)
    SendEventToEventTarget(foreign, GetApplicationEventTarget())
    ReleaseEvent(foreign)
    let dispatchOK = dispatched == InputSource.allCases
    print("   快捷键分发: \(dispatched.map(\.title)) \(dispatchOK ? "✅" : "❌（期望 \(InputSource.allCases.map(\.title))）")")
    if !dispatchOK { failures += 1 }
    hotKeys.unregister()

    // ③ 目标选择：有可 DDC 外接屏时必须落到它（而不是兜底盲发）
    let switcher = InputSwitcher(displayManager: manager)
    let route = switcher.plannedRoute()
    let hasDDCDisplay = manager.displays.contains { ($0 as? DDCDisplay)?.ddc != nil }
    var routeOK = true
    switch route {
    case .display(_, let name): print("   目标选择: DDC 外接屏「\(name)」")
    case .allExternal(let count): print("   目标选择: 兜底→全部 External 端点（\(count) 个）"); routeOK = !hasDDCDisplay
    case .systemDefault: print("   目标选择: 兜底→系统默认服务"); routeOK = !hasDDCDisplay
    case .none: print("   目标选择: 无可用通道"); routeOK = !hasDDCDisplay
    }
    print("   目标选择与显示器现状一致 \(routeOK ? "✅" : "❌")")
    if !routeOK { failures += 1 }

    print(failures == 0 ? "=== 自检通过 ✅ ===" : "=== 自检失败 \(failures) 项 ❌ ===")
    exit(failures == 0 ? 0 : 1)
}
