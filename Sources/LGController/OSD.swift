//  OSD.swift
//  自绘的调节浮层（HUD），样式对齐 macOS 26 系统原生 OSD：
//  目标屏幕右上角的玻璃胶囊，左侧 SF Symbol 图标 + 右侧连续填充条（或文字），淡入停留淡出。
//  不依赖私有 OSD.framework（其 OSDUIHelper 只会画旧版居中方块条）。
//  所有调用须在主线程（按键回调与菜单动作均在主线程）。

import AppKit

enum OSD {
    static func showBrightness(_ value: Float, on displayID: CGDirectDisplayID) {
        HUD.shared.show(symbol: "sun.max.fill", value: value, on: displayID)
    }

    static func showVolume(_ value: Float, muted: Bool, on displayID: CGDirectDisplayID) {
        let v = min(max(value, 0), 1)
        let symbol: String
        if muted || v <= 0 {
            symbol = "speaker.slash.fill"
        } else if v < 1.0 / 3 {
            symbol = "speaker.wave.1.fill"
        } else if v < 2.0 / 3 {
            symbol = "speaker.wave.2.fill"
        } else {
            symbol = "speaker.wave.3.fill"
        }
        HUD.shared.show(symbol: symbol, value: muted ? 0 : v, on: displayID)
    }

    enum Glyph {
        case volumeDisabled
        case muteDisabled
    }

    /// 「不可调」提示：斜杠图标 + 空进度条。
    static func showSimple(_ glyph: Glyph, on displayID: CGDirectDisplayID) {
        let symbol = glyph == .volumeDisabled ? "speaker.slash.circle" : "speaker.slash.circle.fill"
        HUD.shared.show(symbol: symbol, value: 0, on: displayID)
    }

    /// 输入源命令已送达显示器：图标 + 文字（无进度条）。0xF4 只写不可读，无法确认显示器是否真的执行，故写「已发送」。
    static func showInputSource(_ source: InputSource, on displayID: CGDirectDisplayID) {
        HUD.shared.show(symbol: source.symbol, text: "已发送切换 → \(source.title)", on: displayID)
    }

    /// 输入源命令未能送达显示器（DDC 通道不可用）。
    static func showInputSourceFailed(_ source: InputSource, on displayID: CGDirectDisplayID) {
        HUD.shared.show(symbol: "exclamationmark.triangle.fill", text: "\(source.title) 未送达显示器", on: displayID)
    }
}

// MARK: - HUD 面板

private final class HUD {
    static let shared = HUD()

    private let panelSize = NSSize(width: 230, height: 40)
    private let cornerRadius: CGFloat = 14
    private let panel: NSPanel
    private let iconView = NSImageView()
    private let trackView = TrackView()
    private let label = NSTextField(labelWithString: "")
    private var hideWork: DispatchWorkItem?

    private init() {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: panelSize),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .screenSaver
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.animationBehavior = .none

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: panelSize))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        // 圆角：「透出窗口背后」的磨砂只认 maskImage——旧系统（如 macOS 12）上图层圆角裁不到磨砂，
        // 会露出方形的磨砂底和方形阴影；新系统两种都认。两者都设，各版本外观一致。
        effect.maskImage = Self.roundedMask(radius: cornerRadius)
        effect.wantsLayer = true
        effect.layer?.cornerRadius = cornerRadius
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        panel.contentView = effect

        iconView.frame = NSRect(x: 14, y: (panelSize.height - 20) / 2, width: 20, height: 20)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.contentTintColor = .secondaryLabelColor
        effect.addSubview(iconView)

        trackView.frame = NSRect(x: 46, y: (panelSize.height - 8) / 2,
                                 width: panelSize.width - 46 - 16, height: 8)
        effect.addSubview(trackView)

        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: 46, y: (panelSize.height - 18) / 2, width: panelSize.width - 46 - 16, height: 18)
        label.isHidden = true
        effect.addSubview(label)
    }

    /// 进度条模式（亮度/音量）。
    func show(symbol: String, value: Float, on displayID: CGDirectDisplayID) {
        trackView.value = CGFloat(min(max(value, 0), 1))
        trackView.isHidden = false
        label.isHidden = true
        present(symbol: symbol, on: displayID)
    }

    /// 文字模式（输入源切换等离散事件）。
    func show(symbol: String, text: String, on displayID: CGDirectDisplayID) {
        label.stringValue = text
        label.isHidden = false
        trackView.isHidden = true
        present(symbol: symbol, on: displayID)
    }

    private func present(symbol: String, on displayID: CGDirectDisplayID) {
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID
        } ?? NSScreen.main
        guard let screen = screen else { return }

        // 目标屏右上角（visibleFrame 已避开菜单栏/刘海）
        let frame = screen.visibleFrame
        let origin = NSPoint(x: frame.maxX - panelSize.width - 16,
                             y: frame.maxY - panelSize.height - 12)
        panel.setFrame(NSRect(origin: origin, size: panelSize), display: false)

        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)

        hideWork?.cancel()
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            panel.invalidateShadow() // 阴影按圆角遮罩后的形状重算（否则旧系统上是方形阴影）
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 1
        }

        // 停留 1.5s 后淡出（DispatchWorkItem 在菜单跟踪期间也能触发）
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.35
                self.panel.animator().alphaValue = 0
            }, completionHandler: {
                if self.panel.alphaValue == 0 { self.panel.orderOut(nil) }
            })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }
}

extension HUD {
    /// 可拉伸的圆角遮罩（四角固定、中间拉伸），用作 NSVisualEffectView.maskImage。
    static func roundedMask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// 连续填充的圆角进度条（无刻度分段，与系统 26 风格一致；数值本身仍按 1/16 网格步进）。
private final class TrackView: NSView {
    var value: CGFloat = 0 {
        didSet { needsDisplay = true }
    }

    private let trackColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.25)
            : NSColor.black.withAlphaComponent(0.12)
    }

    private let fillColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.95)
            : NSColor.black.withAlphaComponent(0.7)
    }

    override func draw(_: NSRect) {
        let radius = bounds.height / 2
        trackColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()

        guard value > 0 else { return }
        let width = max(bounds.width * value, bounds.height) // 低值时保持圆头可见
        fillColor.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: width, height: bounds.height),
                     xRadius: radius, yRadius: radius).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
