//  DDC.swift
//  DDC/CI 实现，两种硬件通道：
//  - Apple Silicon：通过 IOAVService 对外接显示器做 I²C 读写（协议移植自 MonitorControl 的 Arm64DDC）；
//  - Intel：通过 IOFramebuffer 的 I²C 总线（IOI2CInterface）收发（移植自 MonitorControl 的 IntelDDC）。
//  两者均为 MIT 许可，见 THIRD_PARTY_NOTICES.md。另含 AVService / IOFramebuffer ↔ CGDirectDisplayID 的匹配。

import CoreGraphics
import Foundation
import IOKit
import IOKit.graphics
import IOKit.i2c

enum VCP: UInt8 {
    case brightness = 0x10
    case volume = 0x62
    case mute = 0x8D
}

// MARK: - 单显示器的 DDC 通道

final class DDCService {
    /// 硬件通道。
    private enum Transport {
        case avService(CFTypeRef)      // Apple Silicon：DCPAVServiceProxy 上的 IOAVService
        case framebuffer(io_service_t) // Intel：IOFramebuffer（持有一份端口引用，释放时归还）
    }

    private let transport: Transport
    /// 最近一次 I²C 事务结束的单调时钟（ns）。只在该显示器的串行队列上读写。
    private(set) var lastActivityNS: UInt64 = 0

    init(service: CFTypeRef) {
        transport = .avService(service)
    }

    /// Intel：接管调用方已持有的 framebuffer 端口引用，本对象释放时 IOObjectRelease。
    init(framebuffer: io_service_t) {
        transport = .framebuffer(framebuffer)
    }

    deinit {
        if case .framebuffer(let framebuffer) = transport { IOObjectRelease(framebuffer) }
    }

    /// 诊断日志用：通道类型。
    var transportName: String {
        switch transport {
        case .avService: return "IOAVService"
        case .framebuffer: return "IOFramebuffer I²C"
        }
    }

    private var isFramebuffer: Bool {
        if case .framebuffer = transport { return true }
        return false
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

    /// 把一个写包（writePacket 的结果，不含数据地址字节）发往数据地址 dataAddress。
    /// 返回 IOReturn（0 = I²C 事务被确认，不代表显示器执行了）。
    private func send(_ packet: [UInt8], dataAddress: UInt8) -> IOReturn {
        switch transport {
        case .avService(let service):
            guard let writeFn = PrivateAPI.ioAVServiceWriteI2C else { return kIOReturnUnsupported }
            var bytes = packet
            let count = UInt32(bytes.count)
            return bytes.withUnsafeMutableBytes {
                writeFn(service, 0x37, UInt32(dataAddress), $0.baseAddress!, count)
            }
        case .framebuffer(let framebuffer):
            return IntelI2C.write(Self.framebufferPacket(packet, dataAddress: dataAddress), to: framebuffer)
        }
    }

    /// Intel 的 I²C 请求没有单独的「数据地址」参数：它就是包的首字节（源地址）。
    /// writePacket 的校验和已把数据地址算进去，所以直接拼在前面即可（与 SourceShift / MonitorControl 的 Intel 包逐字节相同）。
    static func framebufferPacket(_ packet: [UInt8], dataAddress: UInt8) -> [UInt8] {
        [dataAddress] + packet
    }

    /// 读取 VCP 值（阻塞 ~60ms，含重试可达数百 ms；只在初始化/重配置时调用，且须在后台队列）。
    func read(_ vcp: VCP) -> (current: UInt16, max: UInt16)? {
        defer { touch() }
        switch transport {
        case .avService(let service): return Self.readViaAVService(service, vcp)
        case .framebuffer(let framebuffer): return Self.readViaFramebuffer(framebuffer, vcp)
        }
    }

    private static func readViaAVService(_ service: CFTypeRef, _ vcp: VCP) -> (current: UInt16, max: UInt16)? {
        guard let write = PrivateAPI.ioAVServiceWriteI2C,
              let read = PrivateAPI.ioAVServiceReadI2C else { return nil }
        var packet: [UInt8] = [0x82, 0x01, vcp.rawValue, 0]
        packet[3] = checksum(seed: 0x37 << 1, data: packet, from: 0, to: 2)
        let packetCount = UInt32(packet.count)
        var reply = [UInt8](repeating: 0, count: 11)
        let replyCount = UInt32(reply.count)
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
                if readOK, let value = parseReply(reply, vcp: vcp) {
                    return value
                }
            }
            if attempt < 3 { usleep(20000) }
        }
        return nil
    }

    private static func readViaFramebuffer(_ framebuffer: io_service_t, _ vcp: VCP) -> (current: UInt16, max: UInt16)? {
        // 读请求 [源地址 0x51, 0x82, 0x01, VCP, 校验]，校验 = 0x6E ^ 前 4 字节（与 MonitorControl IntelDDC 相同）
        var request: [UInt8] = [0x51, 0x82, 0x01, vcp.rawValue, 0]
        request[4] = checksum(seed: 0x6E, data: request, from: 0, to: 3)
        for attempt in 0 ..< 3 {
            usleep(10000)
            if let reply = IntelI2C.read(request, replyCount: 11, from: framebuffer),
               let value = parseReply(reply, vcp: vcp) {
                return value
            }
            if attempt < 2 { usleep(20000) }
        }
        return nil
    }

    /// 校验 VCP Feature Reply：checksum、应答类型、结果码、VCP 回显都要对（防串包：沉降不足时
    /// 把音量应答当亮度采纳会导致大跳变）。两种通道的应答布局相同。
    private static func parseReply(_ reply: [UInt8], vcp: VCP) -> (current: UInt16, max: UInt16)? {
        guard reply.count == 11,
              checksum(seed: 0x50, data: reply, from: 0, to: reply.count - 2) == reply[reply.count - 1],
              reply[2] == 0x02,          // VCP Feature Reply 操作码
              reply[3] == 0x00,          // result code：无错误
              reply[4] == vcp.rawValue   // VCP 码回显
        else { return nil }
        let maxValue = UInt16(reply[6]) * 256 + UInt16(reply[7])
        let current = UInt16(reply[8]) * 256 + UInt16(reply[9])
        return (current, maxValue > 0 ? maxValue : 100)
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

    /// LG 输入源命令，时序照搬 SourceShift：
    /// - Apple Silicon（v1.0.2，与 m1ddc 相同）：两遍「等 10ms → 写」，两份相隔约 12ms；某一遍未被确认即停止；
    /// - Intel：只写一遍，写完等 20ms（SourceShift 的 Intel 路径就是这样）。
    /// 返回每遍的 IOReturn（0 = I²C 事务被确认，不代表显示器执行了）。须在该显示器的串行队列上调用。
    func writeInputSourceLikeSourceShift(_ code: UInt16) -> [IOReturn] {
        let dataAddress = Self.lgInputDataAddress
        let packet = Self.writePacket(code: InputSource.lgVCP, value: code, dataAddress: dataAddress)
        let copies = isFramebuffer ? 1 : 2
        var results: [IOReturn] = []
        defer { touch() }
        for _ in 0 ..< copies {
            usleep(10000)
            let ret = send(packet, dataAddress: dataAddress)
            results.append(ret)
            if ret != 0 { break }
        }
        if isFramebuffer { usleep(20000) }
        return results
    }

    /// 写任意 VCP 码到指定数据地址。失败会重试一次。
    @discardableResult
    func writeRaw(code: UInt8, value: UInt16, dataAddress: UInt8) -> Bool {
        let packet = Self.writePacket(code: code, value: value, dataAddress: dataAddress)
        defer { touch() }
        for attempt in 0 ..< 2 {
            usleep(4000)
            if send(packet, dataAddress: dataAddress) == 0 { return true }
            if attempt == 0 { usleep(10000) }
        }
        return false
    }
}

// MARK: - Intel：IOFramebuffer 的 I²C 通道（移植并精简自 MonitorControl 的 IntelDDC，MIT）

enum IntelI2C {
    /// 显卡支持的应答事务类型（进程内只探测一次）：优先 DDC/CI 专用应答，其次简单事务。
    static let replyTransactionType: IOOptionBits? = {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceNameMatching("IOFramebufferI2CInterface"),
                                           &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var fallback: IOOptionBits?
        while true {
            let service = IOIteratorNext(iterator)
            guard service != IO_OBJECT_NULL else { break }
            defer { IOObjectRelease(service) }
            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = properties?.takeRetainedValue() as NSDictionary?,
                  let types = (dict[kIOI2CTransactionTypesKey] as? NSNumber)?.uint64Value else { continue }
            if types & (UInt64(1) << UInt64(kIOI2CDDCciReplyTransactionType)) != 0 {
                return IOOptionBits(kIOI2CDDCciReplyTransactionType)
            }
            if types & (UInt64(1) << UInt64(kIOI2CSimpleTransactionType)) != 0 {
                fallback = IOOptionBits(kIOI2CSimpleTransactionType)
            }
        }
        return fallback
    }()

    /// 写：data 是完整 DDC/CI 包，首字节为源地址（0x51 标准 / 0x50 LG 输入源）。返回 IOReturn。
    static func write(_ data: [UInt8], to framebuffer: io_service_t) -> IOReturn {
        var bytes = data
        let ok = bytes.withUnsafeMutableBufferPointer { buffer -> Bool in
            var request = IOI2CRequest()
            request.commFlags = 0
            request.sendAddress = 0x6E
            request.sendTransactionType = IOOptionBits(kIOI2CSimpleTransactionType)
            request.sendBuffer = vm_address_t(bitPattern: buffer.baseAddress)
            request.sendBytes = UInt32(buffer.count)
            request.replyTransactionType = IOOptionBits(kIOI2CNoTransactionType)
            request.replyBytes = 0
            return send(&request, to: framebuffer)
        }
        return ok ? kIOReturnSuccess : kIOReturnError
    }

    /// 读：发送读请求包（首字节为源地址 0x51），取 replyCount 字节应答；失败返回 nil。
    static func read(_ data: [UInt8], replyCount: Int, from framebuffer: io_service_t) -> [UInt8]? {
        guard let replyType = replyTransactionType else { return nil }
        var sendBytes = data
        var reply = [UInt8](repeating: 0, count: replyCount)
        let ok = sendBytes.withUnsafeMutableBufferPointer { sendBuffer -> Bool in
            reply.withUnsafeMutableBufferPointer { replyBuffer -> Bool in
                var request = IOI2CRequest()
                request.commFlags = 0
                request.sendAddress = 0x6E
                request.sendTransactionType = IOOptionBits(kIOI2CSimpleTransactionType)
                request.sendBuffer = vm_address_t(bitPattern: sendBuffer.baseAddress)
                request.sendBytes = UInt32(sendBuffer.count)
                request.minReplyDelay = 10
                request.replyAddress = 0x6F
                request.replySubAddress = 0x51
                request.replyTransactionType = replyType
                request.replyBuffer = vm_address_t(bitPattern: replyBuffer.baseAddress)
                request.replyBytes = UInt32(replyBuffer.count)
                return send(&request, to: framebuffer)
            }
        }
        return ok ? reply : nil
    }

    /// 逐条 I²C 总线尝试发送一个请求，直到有一条成功。
    private static func send(_ request: inout IOI2CRequest, to framebuffer: io_service_t) -> Bool {
        var busCount: IOItemCount = 0
        guard IOFBGetI2CInterfaceCount(framebuffer, &busCount) == KERN_SUCCESS else { return false }
        for bus in 0 ..< busCount {
            var interface: io_service_t = 0
            guard IOFBCopyI2CInterfaceForBus(framebuffer, bus, &interface) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(interface) }
            var connect: IOI2CConnectRef?
            guard IOI2CInterfaceOpen(interface, 0, &connect) == KERN_SUCCESS, let connection = connect else { continue }
            defer { IOI2CInterfaceClose(connection, 0) }
            if IOI2CSendRequest(connection, 0, &request) == KERN_SUCCESS, request.result == KERN_SUCCESS {
                return true
            }
        }
        return false
    }

    /// CGDirectDisplayID → IOFramebuffer 端口（返回的端口由调用方持有，用完须 IOObjectRelease；交给 DDCService 即可）。
    /// 先用 CGSServiceForDisplayNumber，拿不到再按 EDID 厂商/型号/序列号（及单元号）逐个比对（与 MonitorControl 相同）。
    static func framebuffer(for displayID: CGDirectDisplayID) -> io_service_t? {
        guard CGDisplayIsBuiltin(displayID) == 0 else { return nil }
        if let lookup = PrivateAPI.cgsServiceForDisplayNumber {
            var port: io_service_t = 0
            lookup(displayID, &port)
            if port != 0 {
                if hasI2CBus(port) {
                    DiagLog.write("Intel 帧缓冲 显示器\(displayID) → CGSServiceForDisplayNumber")
                    return port
                }
                IOObjectRelease(port)
            }
        }
        if let port = framebufferMatchingProperties(of: displayID) {
            DiagLog.write("Intel 帧缓冲 显示器\(displayID) → EDID 属性匹配")
            return port
        }
        DiagLog.write("Intel 帧缓冲 显示器\(displayID) → 未找到带 I²C 总线的 IOFramebuffer")
        return nil
    }

    private static func hasI2CBus(_ framebuffer: io_service_t) -> Bool {
        var busCount: IOItemCount = 0
        return IOFBGetI2CInterfaceCount(framebuffer, &busCount) == KERN_SUCCESS && busCount > 0
    }

    private static func framebufferMatchingProperties(of displayID: CGDirectDisplayID) -> io_service_t? {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOFramebuffer"),
                                           &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        while true {
            let port = IOIteratorNext(iterator)
            guard port != IO_OBJECT_NULL else { return nil }
            if framebuffer(port, matches: displayID), hasI2CBus(port) { return port }
            IOObjectRelease(port)
        }
    }

    private static func framebuffer(_ port: io_service_t, matches displayID: CGDirectDisplayID) -> Bool {
        guard let info = IODisplayCreateInfoDictionary(port, IOOptionBits(kIODisplayOnlyPreferredName))?
                .takeRetainedValue() as NSDictionary? else { return false }
        func number(_ key: String) -> UInt32 {
            (info[key] as? NSNumber)?.uint32Value ?? 0
        }
        guard number(kDisplayVendorID) == CGDisplayVendorNumber(displayID),
              number(kDisplayProductID) == CGDisplayModelNumber(displayID),
              number(kDisplaySerialNumber) == CGDisplaySerialNumber(displayID) else { return false }
        // 位置路径最后一个「@」后面的数字是单元号，用来区分两台同型号、同序列号（常为 0）的显示器
        if let location = info[kIODisplayLocationKey] as? String, let unit = unitNumber(inLocation: location) {
            return unit == CGDisplayUnitNumber(displayID)
        }
        return true
    }

    static func unitNumber(inLocation location: String) -> UInt32? {
        guard let at = location.range(of: "@", options: .backwards) else { return nil }
        let digits = location[at.upperBound...].prefix(while: { $0.isASCII && $0.isNumber })
        return UInt32(digits)
    }
}

// MARK: - 显示器 ↔ DDC 通道匹配
//  Apple Silicon：AVService 匹配（移植并精简自 MonitorControl Arm64DDC）；
//  Intel（x86_64）：每台外接屏各自的 IOFramebuffer（见 IntelI2C.framebuffer）。

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

    /// 为这些外接显示器各自找到 DDC 通道（找不到的不在结果里）。
    static func match(displayIDs: [CGDirectDisplayID]) -> [CGDirectDisplayID: DDCService] {
        #if arch(x86_64)
        var result: [CGDirectDisplayID: DDCService] = [:]
        for displayID in displayIDs {
            if let framebuffer = IntelI2C.framebuffer(for: displayID) {
                result[displayID] = DDCService(framebuffer: framebuffer)
            }
        }
        return result
        #else
        return avServiceMatch(displayIDs: displayIDs)
        #endif
    }

    /// Apple Silicon 贪心分配：按分数从高到低把候选服务分配给外接显示器。
    private static func avServiceMatch(displayIDs: [CGDirectDisplayID]) -> [CGDirectDisplayID: DDCService] {
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
        #if arch(x86_64)
        // Intel：按显示器 ID 重新找它自己的 IOFramebuffer，同样只认这一台
        return IntelI2C.framebuffer(for: displayID).map { DDCService(framebuffer: $0) }
        #else
        let ranked = externalServiceCandidates()
            .map { (score: matchScore(displayID: displayID, candidate: $0), candidate: $0) }
            .sorted { $0.score > $1.score }
        guard let best = ranked.first, best.score >= 3,
              ranked.count < 2 || ranked[1].score < best.score,
              let service = best.candidate.service else { return nil }
        return DDCService(service: service)
        #endif
    }

    /// 当前所有 External DCPAVServiceProxy 的通道（不做显示器匹配）。
    /// 用于输入源切换的兜底：显示器切到别的输入后可能从 CGDisplay 列表里消失，但 I²C 端点仍在。
    static func allExternalServices() -> [DDCService] {
        #if arch(x86_64)
        // Intel：当前在线的各台外接屏各自的 IOFramebuffer（与 SourceShift 的 Intel 路径相同，只认系统列表里的屏）
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        guard CGGetOnlineDisplayList(16, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).compactMap { id in
            IntelI2C.framebuffer(for: id).map { DDCService(framebuffer: $0) }
        }
        #else
        return externalServiceCandidates().compactMap { $0.service.map(DDCService.init(service:)) }
        #endif
    }

    /// 系统默认 AVService（最后兜底，SourceShift v1.0.2 的唯一路径）。
    static func defaultService() -> DDCService? {
        #if arch(x86_64)
        return nil // Intel 没有 IOAVService
        #else
        guard let service = PrivateAPI.ioAVServiceCreate?(kCFAllocatorDefault)?.takeRetainedValue() else { return nil }
        return DDCService(service: service)
        #endif
    }
}
