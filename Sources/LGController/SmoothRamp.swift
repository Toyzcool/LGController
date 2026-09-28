//  SmoothRamp.swift
//  平滑调节引擎：目标值可随时更新，当前值以指数趋近方式滑向目标（约 60Hz），
//  写入慢的通道（DDC）会自然降频——下一拍在上一次写入完成后才调度，天然合并背压。

import Foundation

final class SmoothRamp {
    private let queue: DispatchQueue
    private let tick: TimeInterval
    private let alpha: Float
    private let minStep: Float
    private let epsilon: Float
    private let apply: (Float) -> Void

    private var target: Float
    private var current: Float
    private var running = false
    private var cancelled = false

    /// - Parameters:
    ///   - queue: 串行队列；同一物理通道（如同一显示器的 I2C）的多个 ramp 应共享同一队列。
    ///   - apply: 在 queue 上回调，执行实际写入（可阻塞）。
    init(queue: DispatchQueue,
         initial: Float,
         tick: TimeInterval = 0.016,
         alpha: Float = 0.35,
         minStep: Float = 0.005,
         epsilon: Float = 0.002,
         apply: @escaping (Float) -> Void) {
        self.queue = queue
        self.tick = tick
        self.alpha = alpha
        self.minStep = minStep
        self.epsilon = epsilon
        self.apply = apply
        self.target = initial
        self.current = initial
    }

    /// 同步内部状态（初始化读取硬件值后、或系统重配置后调用），不触发写入。
    func syncCurrent(_ value: Float) {
        queue.async {
            self.current = value
            self.target = value
        }
    }

    /// 更新目标值并启动趋近循环。
    func setTarget(_ value: Float) {
        let clamped = min(max(value, 0), 1)
        queue.async {
            self.target = clamped
            self.pump()
        }
    }

    func cancel() {
        queue.async { self.cancelled = true }
    }

    private func pump() {
        guard !running, !cancelled else { return }
        running = true
        step()
    }

    private func step() {
        guard !cancelled else { running = false; return }
        let diff = target - current
        if abs(diff) <= epsilon {
            if current != target {
                current = target
                apply(current)
            }
            running = false
            return
        }
        var delta = diff * alpha
        if abs(delta) < minStep {
            delta = diff > 0 ? min(minStep, diff) : max(-minStep, diff)
        }
        current += delta
        apply(current)
        queue.asyncAfter(deadline: .now() + tick) { [weak self] in
            self?.step()
        }
    }
}
