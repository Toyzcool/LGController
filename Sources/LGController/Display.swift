//  Display.swift
//  显示器模型：
//  - AppleProtocolDisplay：内建屏 / 苹果协议屏（雷雳 UltraFine、Studio Display），亮度走 DisplayServices。
//  - DDCDisplay：普通外接屏（如 DP 连接的 LG），亮度/音量走 DDC/CI。
//  目标值状态一律主线程维护；硬件写入在各自串行队列上完成（亮度经 SmoothRamp 滑动，音量合并直写）。
//
//  亮度步进规则与系统内建屏一致（规则相同，并非数值同步）：
//  按一下 = 移到相邻的 1/16 网格线（⌥⇧ = 1/64），向上取严格更高的下一条、向下取严格更低的上一条，
//  因此从任意值（含硬件校准来的非网格值）按数下必然精确落到 0 或 1。

import AppKit
import Foundation

/// 最小线程安全包装：max 值在主线程写、显示器串行队列（ramp 闭包）读，用锁消除数据竞争。
private final class Atomic<Value> {
    private var storage: Value
    private let lock = NSLock()
    init(_ value: Value) { storage = value }
    var value: Value {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}

/// 待写入硬件的音量/静音目标：主线程放入最新值，串行队列取走并写入。
/// 后到的值覆盖先到的，因此滑杆连续拖动只会写「最新状态」，不会堆积过时的写入。
private final class PendingVolume {
    private var pending: (volume: Float, muted: Bool)?
    private let lock = NSLock()
    func put(_ value: (volume: Float, muted: Bool)) { lock.withLock { pending = value } }
    func take() -> (volume: Float, muted: Bool)? {
        lock.withLock { let v = pending; pending = nil; return v }
    }
}

class Display {
    let id: CGDirectDisplayID
    let name: String
    let uuid: String
    let isBuiltin: Bool

    /// UI/按键所依据的亮度目标值（0...1）。
    private(set) var brightness: Float = 0.5
    var canBrightness: Bool { false }
    var canVolume: Bool { false }

    fileprivate var lastBrightnessTouch = Date.distantPast

    init(id: CGDirectDisplayID, name: String) {
        self.id = id
        self.name = name
        self.isBuiltin = CGDisplayIsBuiltin(id) != 0
        if let cfUUID = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
           let str = CFUUIDCreateString(kCFAllocatorDefault, cfUUID) {
            self.uuid = str as String
        } else {
            self.uuid = "display-\(id)"
        }
    }

    /// 系统内建屏的步进规则：向上到「严格高于当前值」的下一条网格线，向下到「严格低于」的上一条。
    /// 已在网格线上时正好移动一整档；在网格线之间时先对齐到相邻线。结果精确落在 n*step 上，可达 0 和 1。
    static func gridStep(_ value: Float, step: Float, up: Bool) -> Float {
        let idx = value / step
        let epsilon: Float = 0.001 // 容忍浮点/硬件量化误差，避免在线上原地打转
        let newIdx = up ? floor(idx + epsilon) + 1 : ceil(idx - epsilon) - 1
        return min(max(newIdx * step, 0), 1)
    }

    // MARK: 亮度（子类实现写入）

    fileprivate func applyBrightnessTarget(_ value: Float) {}

    /// 步进前对齐硬件当前值——仅当能「同步且廉价」地读取时才有意义（AppleProtocolDisplay 走
    /// DisplayServices 同步读）。DDC 读阻塞 ~60ms 不能放主线程，故不在此路径读，改由菜单打开/空闲异步重同步。
    func alignBrightnessBeforeStep() {}

    /// 供 UI 显示前刷新（子类可从硬件同步）。
    func refreshBrightnessForUI() {}

    func setBrightness(_ value: Float) {
        let clamped = min(max(value, 0), 1)
        brightness = clamped
        lastBrightnessTouch = Date()
        UserDefaults.standard.set(clamped, forKey: "brightness-\(uuid)")
        applyBrightnessTarget(clamped)
        NotificationCenter.default.post(name: .lgControllerStateDidChange, object: nil)
    }

    /// 按一档步进（1/16；fine = 1/64），返回新目标值用于 OSD。
    @discardableResult
    func stepBrightness(up: Bool, fine: Bool) -> Float {
        alignBrightnessBeforeStep()
        let step: Float = fine ? 1 / 64 : 1 / 16
        setBrightness(Self.gridStep(brightness, step: step, up: up))
        return brightness
    }

    fileprivate func restoreSavedBrightness(fallback: Float) {
        let key = "brightness-\(uuid)"
        if UserDefaults.standard.object(forKey: key) != nil {
            brightness = min(max(UserDefaults.standard.float(forKey: key), 0), 1)
        } else {
            brightness = fallback
        }
    }

    fileprivate func setBrightnessState(_ value: Float) {
        brightness = min(max(value, 0), 1)
    }

    func invalidate() {}
}

// MARK: - 内建屏 / 苹果协议屏

final class AppleProtocolDisplay: Display {
    private let queue: DispatchQueue
    private var ramp: SmoothRamp?
    private let supported: Bool

    override var canBrightness: Bool { supported }

    override init(id: CGDirectDisplayID, name: String) {
        self.queue = DispatchQueue(label: "lgcontroller.apple.\(id)", qos: .userInteractive)
        var initial: Float = 0.5
        var ok = false
        if let get = PrivateAPI.displayServicesGetBrightness,
           PrivateAPI.displayServicesSetBrightness != nil {
            var value: Float = -1
            if get(id, &value) == 0, value >= 0 {
                initial = value
                ok = true
            }
        }
        self.supported = ok
        super.init(id: id, name: name)
        setBrightnessState(initial)
        if supported {
            let displayID = id
            self.ramp = SmoothRamp(queue: queue, initial: initial) { value in
                _ = PrivateAPI.displayServicesSetBrightness?(displayID, value)
            }
        }
    }

    override fileprivate func applyBrightnessTarget(_ value: Float) {
        ramp?.setTarget(value)
    }

    /// DisplayServices 读是同步且廉价的，步进前对齐即可吸收系统自动亮度/原生控制的漂移。
    override func alignBrightnessBeforeStep() {
        refreshBrightnessForUI()
    }

    /// 空闲 3 秒后从硬件重读，吸收系统自动亮度/原生控制造成的漂移。
    override func refreshBrightnessForUI() {
        guard supported, Date().timeIntervalSince(lastBrightnessTouch) > 3,
              let get = PrivateAPI.displayServicesGetBrightness else { return }
        var value: Float = -1
        if get(id, &value) == 0, value >= 0 {
            setBrightnessState(value)
            ramp?.syncCurrent(value)
        }
    }

    override func invalidate() {
        ramp?.cancel()
    }
}

// MARK: - DDC 外接屏

/// 音量语义（对齐系统行为，也是用户明确要求的规则）：
/// - 步长恒为 **1 个 DDC 单位**（满格 = 设备上报的 maxVolume，LG 通常为 100）；
/// - **静音 ⟺ 音量为 0**：静音后音量显示 0；音量降到 0 自动静音（真正无声）；
/// - 音量从 0 加上去只要 > 0 就自动解除静音，且仍是 +1（0 → 1）。
/// 硬件写入顺序关键——实测 LG：**音量为 0 时写 0x8D=2 会被忽略**，故解除静音必须
/// 「先写非零音量、再写 0x8D=2」；两者在同一串行队列上紧邻执行，不会被其他写入插队。
// 诊断日志用的小工具：把回读结果格式化成文字。单独成函数，免得长插值表达式拖慢旧版编译器（Swift 5.7）的类型检查。
private func readText(_ read: (current: UInt16, max: UInt16)?) -> String {
    guard let read = read else { return "失败" }
    return "\(read.current)/\(read.max)"
}

private func muteText(_ value: UInt16?) -> String {
    guard let value = value else { return "失败" }
    return String(value)
}

private func elapsedMS(since start: Date) -> Int {
    Int(Date().timeIntervalSince(start) * 1000)
}

final class DDCDisplay: Display {
    /// 连续 DDC 写入之间的最小间距（实测 LG 写得太密会丢包，尤其音量后紧跟静音）。
    private static let writeSpacingUS: UInt32 = 50_000
    /// 输入源命令前要求该屏 I²C 至少静默这么久（DDC/CI 规定消息间 ≥50ms，LG 读后常回 Null，留足余量）。
    private static let inputQuietMS: Double = 250

    private let queue: DispatchQueue
    let ddc: DDCService?
    private var brightnessRamp: SmoothRamp?

    private let maxBrightness = Atomic<Float>(100)
    private let maxVolume = Atomic<Float>(100)

    /// 音量目标值（0...1）；静音时恒为 0。preMuteVolume 用于静音键的恢复。
    private(set) var volume: Float = 0.25
    private(set) var muted = false
    private var preMuteVolume: Float = 0.25

    private let pendingVolume = PendingVolume()
    /// 上一次写入硬件的静音态（仅在 queue 上访问）：nil = 未知，用于避免每次音量变更都重复写 0x8D。
    private var lastWrittenMute: Bool?

    private var lastVolumeTouch = Date.distantPast
    private var brightnessRefreshInFlight = false
    private var volumeRefreshInFlight = false

    override var canBrightness: Bool { ddc != nil }
    override var canVolume: Bool { ddc != nil }

    /// 一个 DDC 音量单位（LG 通常为 1/100）。
    private var volumeStepUnit: Float {
        let mv = maxVolume.value
        return mv > 0 ? 1 / mv : 0.01
    }

    init(id: CGDirectDisplayID, name: String, ddc: DDCService?) {
        self.queue = DispatchQueue(label: "lgcontroller.ddc.\(id)", qos: .userInteractive)
        self.ddc = ddc
        super.init(id: id, name: name)

        restoreSavedBrightness(fallback: 0.5)
        let volumeKey = "volume-\(uuid)"
        if UserDefaults.standard.object(forKey: volumeKey) != nil {
            volume = min(max(UserDefaults.standard.float(forKey: volumeKey), 0), 1)
        }
        muted = UserDefaults.standard.bool(forKey: "muted-\(uuid)")
        if muted { volume = 0 }
        preMuteVolume = max(UserDefaults.standard.float(forKey: "premute-\(uuid)"), 0.01)

        guard let ddc = ddc else { return }
        brightnessRamp = SmoothRamp(queue: queue, initial: brightness) { [weak self] value in
            guard let self = self else { return }
            ddc.write(.brightness, UInt16((value * self.maxBrightness.value).rounded()))
        }

        // 后台读取真实硬件状态校准：状态一律以硬件为准（刻度才会准），仅当用户已抢先操作时放弃。
        // 静音同样以硬件 0x8D 为准——这样既能反映用户在显示器自身按键设的静音，
        // 也不会用陈旧的持久化状态去覆盖硬件（不再需要启动时强写 0x8D）。
        queue.async { [weak self] in
            let t0 = Date()
            let brightnessRead = ddc.read(.brightness)
            let volumeRead = ddc.read(.volume)
            let muteRead = ddc.read(.mute)?.current
            DiagLog.write("回读(启动校准) 亮度 → \(readText(brightnessRead)) 音量 → \(readText(volumeRead)) 静音 → \(muteText(muteRead)) 用时\(elapsedMS(since: t0))ms")
            guard let self = self else { return }
            if let m = muteRead { self.lastWrittenMute = (m == 1) } // 记录硬件现状，供后续判断是否需要写 0x8D
            DispatchQueue.main.async {
                if let (current, maxValue) = brightnessRead, maxValue > 0 {
                    self.maxBrightness.value = Float(maxValue)
                    self.adoptHardwareBrightness(Float(current) / Float(maxValue))
                }
                if let (current, maxValue) = volumeRead, maxValue > 0 {
                    self.maxVolume.value = Float(maxValue)
                    self.adoptHardwareVolume(Float(current) / Float(maxValue),
                                             hardwareMuted: muteRead.map { $0 == 1 })
                }
                NotificationCenter.default.post(name: .lgControllerStateDidChange, object: nil)
            }
        }
    }

    /// 以硬件读数为准更新亮度状态（用户 2 秒内操作过则不覆盖用户意图）。
    private func adoptHardwareBrightness(_ raw: Float) {
        guard Date().timeIntervalSince(lastBrightnessTouch) > 2 else { return }
        let value = min(max(raw, 0), 1)
        setBrightnessState(value)
        UserDefaults.standard.set(value, forKey: "brightness-\(uuid)")
        brightnessRamp?.syncCurrent(value)
    }

    /// 以硬件读数为准更新音量/静音状态（只改内部状态，不回写硬件）。
    private func adoptHardwareVolume(_ raw: Float, hardwareMuted: Bool? = nil) {
        guard Date().timeIntervalSince(lastVolumeTouch) > 2 else { return }
        let value = min(max(raw, 0), 1)
        if value > 0 { preMuteVolume = value } // 记住可恢复的音量
        muted = (hardwareMuted ?? false) || value <= 0
        volume = muted ? 0 : value
        persistVolume()
    }

    override fileprivate func applyBrightnessTarget(_ value: Float) {
        brightnessRamp?.setTarget(value)
    }

    /// 空闲 5 秒后异步从硬件重读（吸收显示器物理按键造成的漂移）。
    /// 与状态差异在量化噪声内（±0.02）时不采纳，保持网格值干净。
    override func refreshBrightnessForUI() {
        guard let ddc = ddc, !brightnessRefreshInFlight,
              Date().timeIntervalSince(lastBrightnessTouch) > 5 else { return }
        brightnessRefreshInFlight = true
        let name = self.name
        DiagLog.write("回读(弹窗) 亮度 入队 \(name)")
        queue.async { [weak self] in
            let t0 = Date()
            let result = ddc.read(.brightness)
            DiagLog.write("回读(弹窗) 亮度 \(name) → \(readText(result)) 用时\(elapsedMS(since: t0))ms")
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.brightnessRefreshInFlight = false
                guard let (current, maxValue) = result, maxValue > 0 else { return }
                self.maxBrightness.value = Float(maxValue)
                let hw = Float(current) / Float(maxValue)
                if abs(hw - self.brightness) > 0.02 {
                    self.adoptHardwareBrightness(hw)
                    NotificationCenter.default.post(name: .lgControllerStateDidChange, object: nil)
                }
            }
        }
    }

    /// 同上，音量版（菜单打开时调用）：音量与静音一起重读，外部改动才能如实反映。
    func refreshVolumeForUI() {
        guard let ddc = ddc, !volumeRefreshInFlight,
              Date().timeIntervalSince(lastVolumeTouch) > 5 else { return }
        volumeRefreshInFlight = true
        let name = self.name
        DiagLog.write("回读(弹窗) 音量+静音 入队 \(name)")
        queue.async { [weak self] in
            let t0 = Date()
            let result = ddc.read(.volume)
            let muteRead = ddc.read(.mute)?.current
            DiagLog.write("回读(弹窗) 音量 \(name) → \(readText(result)) 静音 → \(muteText(muteRead)) 用时\(elapsedMS(since: t0))ms")
            guard let self = self else { return }
            if let m = muteRead { self.lastWrittenMute = (m == 1) }
            DispatchQueue.main.async {
                self.volumeRefreshInFlight = false
                guard let (current, maxValue) = result, maxValue > 0 else { return }
                self.maxVolume.value = Float(maxValue)
                let hw = Float(current) / Float(maxValue)
                let hwMuted = muteRead.map { $0 == 1 } ?? false
                if abs(hw - self.volume) > 0.02 || hwMuted != self.muted {
                    self.adoptHardwareVolume(hw, hardwareMuted: hwMuted)
                    NotificationCenter.default.post(name: .lgControllerStateDidChange, object: nil)
                }
            }
        }
    }

    // MARK: 音量

    /// 把当前音量/静音状态落到硬件：在串行队列上合并写入（取最新值，过时的写入自动作废）。
    /// 顺序：静音 → 先写音量 0 再写 0x8D=1；解除 → 先写非零音量再写 0x8D=2（LG 要求音量非零才认解除）。
    private func applyVolumeToHardware() {
        guard let ddc = ddc else { return }
        pendingVolume.put((volume, muted))
        queue.async { [weak self] in
            guard let self = self, let target = self.pendingVolume.take() else { return }
            let mv = self.maxVolume.value
            let raw = UInt16((min(max(target.volume, 0), 1) * (mv > 0 ? mv : 100)).rounded())
            // 实测 LG：连续 DDC 写入间隔太近（几毫秒）会被丢弃，故写前留间距、两条写之间再留一段。
            // 音量键最快也就几十毫秒一次，这点延迟不影响手感（且过时的写入已被 take() 合并掉）。
            usleep(Self.writeSpacingUS)
            if target.muted || raw == 0 {
                ddc.write(.volume, 0)
                if self.lastWrittenMute != true {
                    usleep(Self.writeSpacingUS)
                    ddc.write(.mute, 1)
                    self.lastWrittenMute = true
                }
            } else {
                ddc.write(.volume, raw)          // 先写非零音量
                if self.lastWrittenMute != false {
                    usleep(Self.writeSpacingUS)
                    ddc.write(.mute, 2)          // 再解除静音，此时才会生效
                    self.lastWrittenMute = false
                }
            }
        }
    }

    private func persistVolume() {
        UserDefaults.standard.set(volume, forKey: "volume-\(uuid)")
        UserDefaults.standard.set(muted, forKey: "muted-\(uuid)")
        UserDefaults.standard.set(preMuteVolume, forKey: "premute-\(uuid)")
        NotificationCenter.default.post(name: .lgControllerStateDidChange, object: nil)
    }

    /// 直接设定音量（菜单滑杆）。拖到 0 即静音。
    func setVolume(_ value: Float) {
        let clamped = min(max(value, 0), 1)
        volume = clamped
        muted = clamped <= 0
        if !muted { preMuteVolume = clamped }
        lastVolumeTouch = Date()
        persistVolume()
        applyVolumeToHardware()
    }

    /// 音量键步进：恒为 ±1 个 DDC 单位。静音时状态音量为 0，故 +1 得 1 并自动解除静音；
    /// 降到 0 则自动静音（LG 上音量 0 未必真无声，需配合 0x8D）。fine 对 DDC 无意义（最小粒度即 1）。
    @discardableResult
    func stepVolume(up: Bool, fine _: Bool) -> Float {
        volume = Self.gridStep(volume, step: volumeStepUnit, up: up)
        muted = volume <= 0
        if !muted { preMuteVolume = volume }
        lastVolumeTouch = Date()
        persistVolume()
        applyVolumeToHardware()
        return volume
    }

    /// 静音键：静音时音量归 0；再次按下恢复到静音前音量（至少 1 格）。返回切换后的静音状态。
    @discardableResult
    func toggleMute() -> Bool {
        if muted {
            muted = false
            volume = max(preMuteVolume, volumeStepUnit)
        } else {
            preMuteVolume = max(volume, volumeStepUnit)
            muted = true
            volume = 0
        }
        lastVolumeTouch = Date()
        persistVolume()
        applyVolumeToHardware()
        return muted
    }

    // MARK: 输入源（移植自 SourceShift）

    /// 在该显示器的串行队列上发送 LG 输入源切换命令（VCP 0xF4 / 数据地址 0x50）。
    /// 该寄存器只写不可读，无法回读校验。发送前等该屏 I²C 静默 ≥ inputQuietMS，
    /// 然后按 SourceShift v1.0.2 的时序连发 2 遍。completion 在主线程回调「首遍写入是否被确认」。
    func sendInputSource(_ code: UInt16, completion: @escaping (Bool) -> Void) {
        guard let ddc = ddc else {
            completion(false)
            return
        }
        let enqueued = Date()
        let name = self.name
        DiagLog.write("输入源 入队 → \(name) code=0x\(String(code, radix: 16, uppercase: true))")
        queue.async {
            let waited = Date().timeIntervalSince(enqueued) * 1000
            // 总线静默保护：紧跟在回读/亮度写之后发（如刚打开弹窗就点）时，先让显示器的 DDC 引擎歇够
            let idle = ddc.idleMS
            if idle < Self.inputQuietMS {
                usleep(UInt32((Self.inputQuietMS - idle) * 1000))
            }
            DiagLog.write("输入源 开始写 \(name)（队列等待 \(Int(waited))ms，总线已静默 \(idle.isFinite ? "\(Int(idle))ms" : "∞")）")
            let rets = ddc.writeInputSourceLikeSourceShift(code)
            let delivered = rets.first == 0
            DiagLog.write("输入源 IOReturn=\(rets.map { String(format: "0x%08X", $0) }) delivered=\(delivered)")
            DispatchQueue.main.async { completion(delivered) }
        }
    }

    /// 自检专用：在该显示器的串行队列上同步执行一段 DDC 操作——排在已排队的校准读、ramp 写之后，
    /// 与它们严格串行。测试若从主线程直接访问 DDC，会与队列上的读写抢同一条 I²C 总线，读到错乱值。
    /// 会阻塞调用线程，正常运行路径不要调用。
    func debugOnQueue<T>(_ body: (DDCService) -> T) -> T? {
        guard let ddc = ddc else { return nil }
        return queue.sync { body(ddc) }
    }

    /// 自检专用：在该显示器的串行队列上回读硬件音量/静音。
    /// 用 queue.sync 保证排在所有已排队的写入之后，避免测试从主线程直接读时与写入抢同一条 I2C 总线。
    /// 会阻塞调用线程数百毫秒，正常运行路径不要调用。
    func debugReadHardwareVolume() -> (volume: Int, mute: Int)? {
        guard let ddc = ddc else { return nil }
        return queue.sync {
            guard let v = ddc.read(.volume)?.current, let m = ddc.read(.mute)?.current else { return nil }
            return (Int(v), Int(m))
        }
    }

    override func invalidate() {
        brightnessRamp?.cancel()
    }
}

extension Notification.Name {
    static let lgControllerStateDidChange = Notification.Name("lgControllerStateDidChange")
}
