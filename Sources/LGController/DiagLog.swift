//  DiagLog.swift
//  诊断日志：追加写入 ~/Library/Logs/LGController/diag.log（带毫秒时间戳与线程）。
//  用于排查 DDC 时序问题——菜单栏 App 经 `open` 启动时 NSLog 不一定进入统一日志，文件日志最可靠。
//  只记录离散事件（输入源切换、弹窗触发的回读），不记录 60Hz 的亮度 ramp 写入。

import Foundation

enum DiagLog {
    private static let queue = DispatchQueue(label: "lgcontroller.diaglog")
    static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/LGController", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("diag.log")
    }()

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func write(_ message: String) {
        let stamp = formatter.string(from: Date())
        let thread = Thread.isMainThread ? "main" : (String(cString: __dispatch_queue_get_label(nil)))
        let line = "\(stamp) [\(thread)] \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            // 超过 1MB 轮转一次（保留上一份为 diag.log.1），避免长期运行无限增长
            if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 1_000_000 {
                let old = url.appendingPathExtension("1")
                try? FileManager.default.removeItem(at: old)
                try? FileManager.default.moveItem(at: url, to: old)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}
