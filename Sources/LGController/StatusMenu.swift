//  StatusMenu.swift
//  菜单栏 UI：点击状态项弹出 NSPopover，内部用 SwiftUI 布局（macOS 26/27 玻璃拟态风格）。
//  改用 SwiftUI 而非 NSMenu 自定义视图，彻底避免 NSMenu 对自定义视图的固定内边距/裁剪
//  导致的滑块被遮挡问题；布局、材质、圆角、滑块均为系统原生。
//  弹窗打开期间收到 .lgControllerStateDidChange（键盘调节 / 硬件重同步）会实时联动。
//  卡片依次为：各显示器亮度 → 「音量」（独立模块：输出源选择 + 当前输出源的音量/静音）
//  → 「输入源」（合并自 SourceShift：Type C / DP / HDMI1 / HDMI2，对应 ⌘⇧1~4）。

import AppKit
import CoreAudio
import ServiceManagement
import SwiftUI

// MARK: - 视图模型

final class PopoverModel: ObservableObject {
    struct DisplayRow: Identifiable {
        let id: CGDirectDisplayID
        let name: String
        let canBrightness: Bool
        var brightness: Double
        /// 该屏卡片里是否显示 DDC 扬声器音量行：仅在有 ≥2 台可 DDC 调音量的屏、且「音量」卡片没在控制它时显示，
        /// 保证每台显示器的扬声器都有地方调（单台 LG 时布局不变）。
        var showVolume = false
        var volume: Double = 0
        var muted = false
    }

    struct OutputRow: Identifiable, Equatable {
        let id: AudioDeviceID
        let name: String
        let symbol: String
    }

    @Published var displays: [DisplayRow] = []
    @Published var accessibilityGranted = true
    @Published var launchAtLogin = false
    /// 输入源命令的目标显示器名；nil = 未识别到可 DDC 的外接屏（按钮仍可用，会走兜底盲发）。
    @Published var inputTargetName: String?
    /// 音量模块：可选输出源、当前输出源、当前输出源的音量状态。
    @Published var outputs: [OutputRow] = []
    @Published var selectedOutput: AudioDeviceID = 0
    @Published var level = VolumeControl.Level(volume: 0, muted: false, controllable: false, viaDDC: false)
    /// 当前输出源是显示器音频、且有 ≥2 台同名 DDC 屏认不出是哪台——卡片提示去各显示器卡片调。
    @Published var outputAmbiguousDisplay = false

    private let manager: DisplayManager?
    private let inputSwitcher: InputSwitcher?
    private let volumeControl: VolumeControl?
    private var outputObserver: AudioController.OutputObserver?

    init(displayManager: DisplayManager, inputSwitcher: InputSwitcher, volumeControl: VolumeControl) {
        self.manager = displayManager
        self.inputSwitcher = inputSwitcher
        self.volumeControl = volumeControl
        NotificationCenter.default.addObserver(self, selector: #selector(externalChange),
                                               name: .lgControllerStateDidChange, object: nil)
        // 插拔耳机、在控制中心切换输出、系统音量条改音量 → 弹窗里的输出源与音量实时同步。
        // 设备增减/默认输出变化才重新枚举设备；只有默认输出真的换了才去 DDC 回读（设备列表抖动不占 I²C）。
        // 音量/静音变化（含自己拖滑杆的每一帧）只做 CoreAudio 对账 + 刷新数值，不枚举、不读 DDC。
        outputObserver = AudioController.OutputObserver(
            onDevicesChange: { [weak self] defaultChanged in
                self?.volumeControl?.syncFromHardware(includeDDC: defaultChanged)
                self?.reload(includingOutputs: true)
            },
            onLevelChange: { [weak self] in
                self?.volumeControl?.syncFromHardware(includeDDC: false)
                self?.reload()
            })
    }

    /// 预览用（不接真实 DisplayManager）。
    init(previewRows: [DisplayRow], accessibility: Bool, launch: Bool, inputTarget: String?,
         outputs: [OutputRow], selectedOutput: AudioDeviceID, level: VolumeControl.Level) {
        self.manager = nil
        self.inputSwitcher = nil
        self.volumeControl = nil
        self.displays = previewRows
        self.accessibilityGranted = accessibility
        self.launchAtLogin = launch
        self.inputTargetName = inputTarget
        self.outputs = outputs
        self.selectedOutput = selectedOutput
        self.level = level
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func externalChange() {
        DispatchQueue.main.async { [weak self] in self?.reload() }
    }

    /// 弹窗打开时调用：拉取硬件最新值并刷新全部状态。
    func refresh() {
        guard let manager else { return }
        for display in manager.displays {
            display.refreshBrightnessForUI()
            // 所有 DDC 屏都回读音量：按键在兜底路径下可能调任意一台，步进要从真实值出发（已有 5s/在途去重）
            (display as? DDCDisplay)?.refreshVolumeForUI()
        }
        volumeControl?.syncFromHardware()
        accessibilityGranted = AXIsProcessTrusted()
        launchAtLogin = SMAppService.mainApp.status == .enabled
        reload(includingOutputs: true)
    }

    /// includingOutputs：是否重新枚举音频设备——只在弹窗打开、切换输出源、CoreAudio 通知变化时需要；
    /// 其余状态变化（如拖动亮度滑杆每一帧）只刷新数值，避免无谓的设备枚举。
    private func reload(includingOutputs: Bool = false) {
        guard let manager else { return }
        let volumeDisplays = Set(manager.displays.compactMap { ($0 as? DDCDisplay)?.canVolume == true ? $0.id : nil })
        var cardTargetID: CGDirectDisplayID?
        if case .ddc(let d) = volumeControl?.outputTarget() { cardTargetID = d.id }
        displays = manager.displays.map { display in
            var row = DisplayRow(id: display.id, name: display.name,
                                 canBrightness: display.canBrightness, brightness: Double(display.brightness))
            if let ddc = display as? DDCDisplay, volumeDisplays.count >= 2,
               volumeDisplays.contains(display.id), display.id != cardTargetID {
                row.showVolume = true
                row.volume = Double(ddc.muted ? 0 : ddc.volume)
                row.muted = ddc.muted
            }
            return row
        }
        inputTargetName = inputSwitcher?.targetDisplay()?.name
        if let volumeControl {
            if includingOutputs || outputs.isEmpty {
                outputs = Self.outputRows(volumeControl.outputDevices())
                selectedOutput = volumeControl.currentOutputID ?? 0
            }
            outputAmbiguousDisplay = volumeControl.currentOutputID.map {
                AudioController.isDisplayAudio($0) && manager.ddcCandidates(forAudioDevice: $0).count >= 2
            } ?? false
            level = volumeControl.level()
        }
    }

    /// 同名设备（两台同型号显示器的 DP 音频）加序号区分，否则两个按钮一模一样。
    private static func outputRows(_ devices: [AudioController.OutputDevice]) -> [OutputRow] {
        var total: [String: Int] = [:]
        for d in devices { total[d.name, default: 0] += 1 }
        var seen: [String: Int] = [:]
        return devices.map { d in
            guard total[d.name, default: 0] > 1 else { return OutputRow(id: d.id, name: d.name, symbol: d.symbol) }
            seen[d.name, default: 0] += 1
            // 不用「(1)/(2)」：那看起来像系统给显示器的编号，但两者顺序无关，容易对错屏
            return OutputRow(id: d.id, name: "\(d.name) · 音频\(seen[d.name]!)", symbol: d.symbol)
        }
    }

    // MARK: 控制

    func setBrightness(_ id: CGDirectDisplayID, _ value: Double) {
        guard let display = manager?.displays.first(where: { $0.id == id }) else { return }
        display.setBrightness(Float(value))
        if let i = displays.firstIndex(where: { $0.id == id }) { displays[i].brightness = value }
    }

    /// 显示器卡片里的 DDC 扬声器音量行（多台 DDC 屏时，音量卡片没在控制的那些）。
    func setDisplayVolume(_ id: CGDirectDisplayID, _ value: Double) {
        guard let display = manager?.displays.first(where: { $0.id == id }) as? DDCDisplay else { return }
        display.setVolume(Float(value))
        if let i = displays.firstIndex(where: { $0.id == id }) {
            displays[i].volume = value
            displays[i].muted = value <= 0
        }
    }

    func toggleDisplayMute(_ id: CGDirectDisplayID) {
        guard let display = manager?.displays.first(where: { $0.id == id }) as? DDCDisplay else { return }
        let muted = display.toggleMute()
        if let i = displays.firstIndex(where: { $0.id == id }) {
            displays[i].muted = muted
            displays[i].volume = muted ? 0 : Double(display.volume)
        }
    }

    // MARK: 音量模块

    func setOutputVolume(_ value: Double) {
        guard let volumeControl else { return }
        volumeControl.setVolume(Float(value))
        level = volumeControl.level()
    }

    func toggleOutputMute() {
        guard let volumeControl else { return }
        volumeControl.toggleMute()
        level = volumeControl.level()
    }

    func selectOutput(_ device: AudioDeviceID) {
        guard let volumeControl, device != selectedOutput else { return }
        volumeControl.selectOutput(device)
        volumeControl.syncFromHardware()
        reload(includingOutputs: true)
    }

    var volumeSymbol: String { Self.speakerSymbol(volume: Double(level.volume), muted: level.muted) }

    static func speakerSymbol(volume: Double, muted: Bool) -> String {
        if muted || volume <= 0 { return "speaker.slash.fill" }
        if volume < 1.0 / 3 { return "speaker.wave.1.fill" }
        if volume < 2.0 / 3 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("LGController: 切换开机自启动失败: \(error.localizedDescription)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func openAccessibilitySettings() {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as NSString
        _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func switchInput(_ source: InputSource) {
        inputSwitcher?.switchTo(source)
    }


}

// MARK: - SwiftUI 界面

struct MenuView: View {
    @ObservedObject var model: PopoverModel
    @Environment(\.previewSliders) private var previewSliders

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "slider.horizontal.3")
                    .foregroundStyle(.secondary)
                Text("LGController")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
            }

            if model.displays.isEmpty {
                Text("未检测到显示器")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                ForEach(model.displays) { row in
                    DisplayCard(model: model, row: row)
                }
            }

            VolumeCard(model: model)

            InputSourceCard(model: model)

            Divider().padding(.vertical, 2)

            if !model.accessibilityGranted {
                Button(action: model.openAccessibilitySettings) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("启用键盘快捷键需授予辅助功能权限…")
                            .font(.callout)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            if previewSliders {
                // 离屏预览：原生 Toggle 无法被 ImageRenderer 快照，画一个同样式的开关
                HStack {
                    Label("开机自启动", systemImage: "power")
                        .font(.callout)
                    Spacer()
                    Capsule()
                        .fill(model.launchAtLogin ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 32, height: 18)
                        .overlay(Circle().fill(.white).padding(2),
                                 alignment: model.launchAtLogin ? .trailing : .leading)
                }
            } else {
                Toggle(isOn: Binding(get: { model.launchAtLogin },
                                     set: { _ in model.toggleLaunchAtLogin() })) {
                    Label("开机自启动", systemImage: "power")
                        .font(.callout)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            Button(action: { NSApp.terminate(nil) }) {
                HStack(spacing: 8) {
                    Image(systemName: "xmark.circle")
                    Text("退出 LGController")
                    Spacer(minLength: 0)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .frame(width: 300)
    }
}

/// 音量卡片（独立模块）：当前输出源的音量滑杆（点喇叭图标静音）+ 输出源按钮，一点即切换。
/// 按钮与「输入源」卡片共用 TileButtonStyle，风格一致；当前输出源用强调色高亮。
/// 与音量键同一套规则（VolumeControl）：输出源是显示器 DP/HDMI 音频时经 DDC 调节它的扬声器。
private struct VolumeCard: View {
    @ObservedObject var model: PopoverModel

    private var currentName: String {
        model.outputs.first { $0.id == model.selectedOutput }?.name ?? "无输出设备"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("音量")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(model.level.viaDDC ? "\(currentName) · DDC" : currentName)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            if model.level.controllable {
                ControlRow(systemImage: model.volumeSymbol,
                           iconAction: { model.toggleOutputMute() },
                           value: Binding(get: { Double(model.level.volume) },
                                          set: { model.setOutputVolume($0) }))
            } else {
                Text(model.outputAmbiguousDisplay && model.displays.contains { $0.showVolume }
                     ? "请在上方显示器卡片中调节扬声器音量" : "该输出设备不支持调节音量")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            if !model.outputs.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 8)], spacing: 8) {
                    ForEach(model.outputs) { output in
                        let selected = output.id == model.selectedOutput
                        Button(action: { model.selectOutput(output.id) }) {
                            VStack(spacing: 4) {
                                Image(systemName: output.symbol)
                                    .font(.system(size: 15, weight: .medium))
                                    .frame(height: 18)
                                Text(output.name)
                                    .font(.system(size: 10, weight: .semibold))
                                    .multilineTextAlignment(.center)
                                    .lineLimit(2)
                                    .minimumScaleFactor(0.85)
                            }
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(TileButtonStyle(selected: selected))
                        .help(selected ? "当前输出源：\(output.name)" : "切换声音输出到 \(output.name)")
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// 输入源卡片：4 个切换按钮一行排开，标注对应快捷键。
/// 按下态用 ButtonStyle 的 isPressed 实现，不用 @State——只装 Command Line Tools 时 SwiftUI 宏插件缺失，@State 会编译失败。
private struct InputSourceCard: View {
    @ObservedObject var model: PopoverModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("输入源")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(model.inputTargetName ?? "未识别外接屏")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            HStack(spacing: 8) {
                ForEach(InputSource.allCases) { source in
                    Button(action: { model.switchInput(source) }) {
                        VStack(spacing: 3) {
                            Image(systemName: source.symbol)
                                .font(.system(size: 15, weight: .medium))
                                .frame(height: 18)
                            Text(source.title)
                                .font(.system(size: 11, weight: .semibold))
                                .lineLimit(1)
                            Text(source.shortcutLabel)
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(TileButtonStyle())
                    .help("切换到 \(source.title)（\(source.shortcutLabel)）")
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// 卡片内圆角按钮的共用样式（输入源、输出源）：按下态用 isPressed，不用 @State
/// （只装 Command Line Tools 时 SwiftUI 宏插件缺失，@State 会编译失败）。selected = 当前项，强调色高亮。
private struct TileButtonStyle: ButtonStyle {
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return configuration.label
            .foregroundStyle(selected ? Color.accentColor : Color.primary)
            .background(selected ? Color.accentColor.opacity(configuration.isPressed ? 0.26 : 0.16)
                                 : Color.primary.opacity(configuration.isPressed ? 0.16 : 0.06),
                        in: shape)
            .overlay(shape.strokeBorder(selected ? Color.accentColor.opacity(0.55) : Color.clear, lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct DisplayCard: View {
    @ObservedObject var model: PopoverModel
    let row: PopoverModel.DisplayRow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(row.name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if row.canBrightness {
                ControlRow(systemImage: "sun.max.fill",
                           value: Binding(get: { row.brightness },
                                          set: { model.setBrightness(row.id, $0) }))
            }

            if row.showVolume {
                ControlRow(systemImage: PopoverModel.speakerSymbol(volume: row.volume, muted: row.muted),
                           iconAction: { model.toggleDisplayMute(row.id) },
                           value: Binding(get: { row.volume },
                                          set: { model.setDisplayVolume(row.id, $0) }))
            }

            if !row.canBrightness, !row.showVolume {
                Text("亮度不可控")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct ControlRow: View {
    let systemImage: String
    var iconAction: (() -> Void)? = nil
    @Binding var value: Double
    @Environment(\.previewSliders) private var previewSliders

    var body: some View {
        HStack(spacing: 12) {
            if let iconAction {
                Button(action: iconAction) { icon }
                    .buttonStyle(.plain)
            } else {
                icon
            }
            if previewSliders {
                PreviewSlider(value: value) // 仅离屏预览用（ImageRenderer 无法快照原生 Slider）
            } else {
                Slider(value: $value, in: 0 ... 1)
            }
        }
    }

    private var icon: some View {
        Image(systemName: systemImage)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 20, height: 18)
            .contentShape(Rectangle())
    }
}

/// 预览专用：模拟原生滑块外观（真实 App 用系统 Slider）。
private struct PreviewSlider: View {
    let value: Double
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let x = max(8, min(w - 8, w * value))
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary).frame(height: 4)
                Capsule().fill(Color.accentColor).frame(width: x, height: 4)
                Circle().fill(.white).frame(width: 16, height: 16)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                    .offset(x: x - 8)
            }
            .frame(height: geo.size.height, alignment: .center)
        }
        .frame(height: 18)
    }
}

// 环境开关：预览时用自绘滑块条，真实运行用原生 Slider。
private struct PreviewSlidersKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var previewSliders: Bool {
        get { self[PreviewSlidersKey.self] }
        set { self[PreviewSlidersKey.self] = newValue }
    }
}

// MARK: - 状态栏控制器

final class StatusMenuController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let model: PopoverModel
    private let popover = NSPopover()

    init(displayManager: DisplayManager, inputSwitcher: InputSwitcher, volumeControl: VolumeControl) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.model = PopoverModel(displayManager: displayManager, inputSwitcher: inputSwitcher,
                                  volumeControl: volumeControl)
        super.init()

        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "sun.max", accessibilityDescription: "LGController")
            image?.isTemplate = true
            button.image = image
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        popover.behavior = .transient
        popover.animates = true
        // 初始 contentSize 与 MenuView 宽度一致，避免首帧内容比弹窗宽而被横向裁剪；
        // sizingOptions 会据 SwiftUI 内容自适应高度（宽度保持 300）。
        popover.contentSize = NSSize(width: 300, height: 520)
        let hosting = NSHostingController(rootView: MenuView(model: model))
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        popover.delegate = self
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        model.refresh()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // 让弹窗窗口成为 key，滑块等控件才能接收拖动事件（accessory 应用尤其需要）
        popover.contentViewController?.view.window?.makeKey()
    }
}
