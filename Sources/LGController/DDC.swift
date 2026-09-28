//  DDC.swift
//  Apple Silicon 的 DDC/CI 实现：通过 IOAVService 对外接显示器做 I2C 读写（协议移植自 MonitorControl 的 Arm64DDC，MIT 许可，见 THIRD_PARTY_NOTICES.md）。
//  以及 AVService ↔ CGDirectDisplayID 的匹配（EDID UUID / 位置路径打分）。

import CoreGraphics
import Foundation
import IOKit

enum VCP: UInt8 {
    case brightness = 0x10
    case volume = 0x62
    case mute = 0x8D
}

// MARK: - 单显示器的 DDC 通道

final class DDCService {
    private let service: CFTypeRef
    /// 最近一次 I²C 事务结束的单调时钟（ns）。只在该显示器的串行队列上读写。
    private(set) var lastActivityNS: UInt64 = 0

    init(service: CFTypeRef) {
        self.service = service
    }

    private func touch() { lastActivityNS = DispatchTime.now().uptimeNanoseconds }

    /// 距上一次 I²C 事务已过去的毫秒数（从未通信过 = 很大）。
    var idleMS: Double {
        lastActivityNS == 0 ? .infinity : Double(DispatchTime.now().uptimeNanoseconds - lastActivityNS) / 1_000_000
    }

    private static func checksum(seed: UInt8, data: [UInt8], from: Int, to: Int) -> UInt8 {
        var chk = seed
        for i in from ... to { chk ^= data[i] }
        return chk
    }

    /// 读取 VCP 值（阻塞 ~60ms，含重试可达数百 ms；只在初始化/重配置时调用，且须在后台队列）。
    func read(_ vcp: VCP) -> (current: UInt16, max: UInt16)? {
        guard let write = PrivateAPI.ioAVServiceWriteI2C,
              let read = PrivateAPI.ioAVServiceReadI2C else { return nil }
        var packet: [UInt8] = [0x82, 0x01, vcp.rawValue, 0]
        packet[3] = Self.checksum(seed: 0x37 << 1, data: packet, from: 0, to: 2)
        let packetCount = UInt32(packet.count)
        var reply = [UInt8](repeating: 0, count: 11)
        let replyCount = UInt32(reply.count)
        defer { touch() }
        for attempt in 0 ..< 4 {
            usleep(10000)
            let wrote = packet.withUnsafeMutableBytes {
                write(service, 0x37, 0x51, $0.baseAddress!, packetCount)
            } == 0
            if wrote {
                usleep(40000)
                let readOK = reply.withUnsafeMutableBytes {
                    read(service, 0x37, 0, $0.baseAddress!, replyCount)
                } == 0
                // 除 checksum 外，校验应答类型/结果码/VCP 回显，防串包（沉降不足时把音量应答当亮度采纳会导致大跳变）
                if readOK,
                   Self.checksum(seed: 0x50, data: reply, from: 0, to: reply.count - 2) == reply[reply.count - 1],
                   reply[2] == 0x02,          // VCP Feature Reply 操作码
                   reply[3] == 0x00,          // result code：无错误
                   reply[4] == vcp.rawValue { // VCP 码回显
                    let maxValue = UInt16(reply[6]) * 256 + UInt16(reply[7])
                    let current = UInt16(reply[8]) * 256 + UInt16(reply[9])
                    return (current, maxValue > 0 ? maxValue : 100)
                }
            }
            if attempt < 3 { usleep(20000) }
        }
        return nil
    }

    /// 标准 DDC/CI 数据地址（亮度、音量、静音等 MCCS VCP 都走它）。
    static let standardDataAddress: UInt8 = 0x51
    /// LG 私有输入源命令（VCP 0xF4）使用的数据地址——移植自 SourceShift，实测 LG 27UP / UltraFine 系列。
    static let lgInputDataAddress: UInt8 = 0x50

    /// DDC/CI 写包：`[0x84, 0x03, 码, 值高, 值低, 校验]`，校验 = (0x37<<1) ^ 数据地址 ^ 前 5 字节。
    /// 纯函数，自检用它与 SourceShift 实际发出的字节逐字节比对。
    static func writePacket(code: UInt8, value: UInt16, dataAddress: UInt8) -> [UInt8] {
        var packet: [UInt8] = [0x84, 0x03, code, UInt8(value >> 8), UInt8(value & 0xFF), 0]
        packet[5] = checksum(seed: (0x37 << 1) ^ dataAddress, data: packet, from: 0, to: 4)
        return packet
    }

    /// 写入 VCP 值（阻塞 ~5-15ms）。须在该显示器的串行队列上调用。
    @discardableResult
    func write(_ vcp: VCP, _ value: UInt16) -> Bool {
        writeRaw(code: vcp.rawValue, value: value, dataAddress: Self.standardDataAddress)
    }

    /// LG 输入源命令，时序逐一照搬 SourceShift v1.0.2（在 LG 显示器上实测可切换的版本，
    /// 与 m1ddc 相同）：两遍「等 10ms → 写」，两份相隔约 12ms；某一遍未被确认即停止。
    /// 返回每遍的 IOReturn（0 = I²C 事务被确认，不代表显示器执行了）。须在该显示器的串行队列上调用。
    func writeInputSourceLikeSourceShift(_ code: UInt16) -> [IOReturn] {
        guard let writeFn = PrivateAPI.ioAVServiceWriteI2C else { return [kIOReturnUnsupported] }
        let dataAddress = Self.lgInputDataAddress
        var packet = Self.writePacket(code: InputSource.lgVCP, value: code, dataAddress: dataAddress)
        let packetCount = UInt32(packet.count)
        var results: [IOReturn] = []
        defer { touch() }
        for _ in 0 ..< 2 {
            usleep(10000)
            let ret = packet.withUnsafeMutableBytes {
                writeFn(service, 0x37, UInt32(dataAddress), $0.baseAddress!, packetCount)
            }
            results.append(ret)
            if ret != 0 { break }
        }
        return results
    }

    /// 写任意 VCP 码到指定数据地址。失败会重试一次。
    @discardableResult
    func writeRaw(code: UInt8, value: UInt16, dataAddress: UInt8) -> Bool {
        guard let writeFn = PrivateAPI.ioAVServiceWriteI2C else { return false }
        var packet = Self.writePacket(code: code, value: value, dataAddress: dataAddress)
        let packetCount = UInt32(packet.count)
        defer { touch() }
        for attempt in 0 ..< 2 {
            usleep(4000)
            let ok = packet.withUnsafeMutableBytes {
                writeFn(service, 0x37, UInt32(dataAddress), $0.baseAddress!, packetCount)
            } == 0
            if ok { return true }
            if attempt == 0 { usleep(10000) }
        }
        return false
    }
}

// MARK: - AVService 匹配（移植并精简自 MonitorControl Arm64DDC）

enum DDCServiceMatcher {
    struct IOregCandidate {
        var edidUUID = ""
        var productName = ""
        var serialNumber: Int64 = 0
        var ioDisplayLocation = ""
        var service: CFTypeRef?
        var serviceLocation = 0
    }

    /// 遍历 IORegistry，把 AppleCLCD2/IOMobileFramebufferShim（携带 EDID 信息）与随后的
    /// DCPAVServiceProxy(Location=External) 配对，得到候选服务列表。
    static func externalServiceCandidates() -> [IOregCandidate] {
        guard let create = PrivateAPI.ioAVServiceCreateWithService else { return [] }
        var candidates: [IOregCandidate] = []
        var current = IOregCandidate()
        var serviceLocation = 0

        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }
        var iterator = io_iterator_t()
        guard IORegistryEntryCreateIterator(root, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        let namePtr = UnsafeMutablePointer<CChar>.allocate(capacity: MemoryLayout<io_name_t>.size)
        defer { namePtr.deallocate() }

        while true {
            let entry = IOIteratorNext(iterator)
            guard entry != IO_OBJECT_NULL else { break }
            defer { IOObjectRelease(entry) }
            guard IORegistryEntryGetName(entry, namePtr) == KERN_SUCCESS else { continue }
            let name = String(cString: namePtr)

            if name.contains("AppleCLCD2") || name.contains("IOMobileFramebufferShim") {
                current = IOregCandidate()
                serviceLocation += 1
                current.serviceLocation = serviceLocation
                if let uuid = IORegistryEntryCreateCFProperty(entry, "EDID UUID" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String {
                    current.edidUUID = uuid
                }
                let pathPtr = UnsafeMutablePointer<CChar>.allocate(capacity: MemoryLayout<io_string_t>.size)
                defer { pathPtr.deallocate() }
                if IORegistryEntryGetPath(entry, kIOServicePlane, pathPtr) == KERN_SUCCESS {
                    current.ioDisplayLocation = String(cString: pathPtr)
                }
                if let attrs = IORegistryEntryCreateCFProperty(entry, "DisplayAttributes" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSDictionary,
                   let product = attrs["ProductAttributes"] as? NSDictionary {
                    current.productName = product["ProductName"] as? String ?? ""
                    current.serialNumber = (product["SerialNumber"] as? Int64) ?? 0
                }
            } else if name.contains("DCPAVServiceProxy") {
                if let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String,
                   location == "External" {
                    current.service = create(kCFAllocatorDefault, entry)?.takeRetainedValue()
                    if current.service != nil {
                        candidates.append(current)
                    }
                }
            }
        }
        return candidates
    }

    /// EDID UUID 与显示器信息字典的多特征打分（vendor/product/生产日期/物理尺寸/位置路径）。
    static func matchScore(displayID: CGDirectDisplayID, candidate: IOregCandidate) -> Int {
        var score = 0
        guard let info = PrivateAPI.displayInfoDictionary(displayID) else { return 0 }
        if let vendor = info["DisplayVendorID"] as? Int64,
           let product = info["DisplayProductID"] as? Int64,
           let week = info["DisplayWeekOfManufacture"] as? Int64,
           let year = info["DisplayYearOfManufacture"] as? Int64,
           let hSize = info["DisplayHorizontalImageSize"] as? Int64,
           let vSize = info["DisplayVerticalImageSize"] as? Int64 {
            let uuid = candidate.edidUUID
            let checks: [(key: String, loc: Int)] = [
                (String(format: "%04X", UInt16(clamping: vendor)), 0),
                (String(format: "%02X%02X", UInt8(UInt16(clamping: product) & 0xFF), UInt8(UInt16(clamping: product) >> 8)), 4),
                (String(format: "%02X%02X", UInt8(clamping: week), UInt8(clamping: max(0, year - 1990))), 19),
                (String(format: "%02X%02X", UInt8(clamping: hSize / 10), UInt8(clamping: vSize / 10)), 30),
            ]
            for check in checks where check.key != "0000" && uuid.count >= check.loc + 4 {
                if String(uuid.prefix(check.loc + 4).suffix(4)) == check.key {
                    score += 1
                }
            }
        }
        if !candidate.ioDisplayLocation.isEmpty,
           let location = info["IODisplayLocation"] as? String,
           location == candidate.ioDisplayLocation {
            score += 10
        }
        if !candidate.productName.isEmpty,
           let names = info["DisplayProductName"] as? [String: String],
           let name = names["en_US"] ?? names.first?.value,
           name.lowercased() == candidate.productName.lowercased() {
            score += 1
        }
        if candidate.serialNumber != 0,
           let serial = info["DisplaySerialNumber"] as? Int64,
           serial == candidate.serialNumber {
            score += 1
        }
        return score
    }

    /// 贪心分配：按分数从高到低把候选服务分配给外接显示器。
    static func match(displayIDs: [CGDirectDisplayID]) -> [CGDirectDisplayID: DDCService] {
        let candidates = externalServiceCandidates()
        guard !candidates.isEmpty else { return [:] }
        var scored: [(score: Int, displayID: CGDirectDisplayID, candidateIndex: Int)] = []
        for displayID in displayIDs {
            for (idx, candidate) in candidates.enumerated() {
                scored.append((matchScore(displayID: displayID, candidate: candidate), displayID, idx))
            }
        }
        var result: [CGDirectDisplayID: DDCService] = [:]
        var takenCandidates = Set<Int>()
        for entry in scored.sorted(by: { $0.score > $1.score }) {
            guard result[entry.displayID] == nil, !takenCandidates.contains(entry.candidateIndex) else { continue }
            if let service = candidates[entry.candidateIndex].service {
                result[entry.displayID] = DDCService(service: service)
                takenCandidates.insert(entry.candidateIndex)
            }
        }
        return result
    }

    /// 为单台显示器重新匹配端点（输入源重试用）。只接受「能确认是它」的候选：
    /// 分数 ≥3（EDID 多项特征 / 位置路径吻合）且明显高于次优；否则返回 nil——宁可不发，也不写到别的屏
    /// （同厂商的另一台 LG 仅厂商码吻合，只得 1 分）。
    static func freshService(for displayID: CGDirectDisplayID) -> DDCService? {
        let ranked = externalServiceCandidates()
            .map { (score: matchScore(displayID: displayID, candidate: $0), candidate: $0) }
            .sorted { $0.score > $1.score }
        guard let best = ranked.first, best.score >= 3,
              ranked.count < 2 || ranked[1].score < best.score,
              let service = best.candidate.service else { return nil }
        return DDCService(service: service)
    }

    /// 当前所有 External DCPAVServiceProxy 的通道（不做显示器匹配）。
    /// 用于输入源切换的兜底：显示器切到别的输入后可能从 CGDisplay 列表里消失，但 I²C 端点仍在。
    static func allExternalServices() -> [DDCService] {
        externalServiceCandidates().compactMap { $0.service.map(DDCService.init(service:)) }
    }

    /// 系统默认 AVService（最后兜底，SourceShift v1.0.2 的唯一路径）。
    static func defaultService() -> DDCService? {
        guard let service = PrivateAPI.ioAVServiceCreate?(kCFAllocatorDefault)?.takeRetainedValue() else { return nil }
        return DDCService(service: service)
    }
}
