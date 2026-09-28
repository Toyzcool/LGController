//  PrivateAPI.swift
//  私有框架符号桥接：DisplayServices（内建屏/苹果协议屏亮度）、IOAVService（Apple Silicon DDC I2C）、
//  CGSServiceForDisplayNumber（Intel：显示器 → IOFramebuffer）、CoreDisplay（显示器信息字典）。
//  全部通过 dlsym 动态解析，避免链接私有 .tbd。

import CoreGraphics
import Darwin
import Foundation
import IOKit

enum PrivateAPI {
    private static let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)! // RTLD_DEFAULT

    private static func symbol(_ name: String, frameworks: [String] = []) -> UnsafeMutableRawPointer? {
        if let sym = dlsym(rtldDefault, name) { return sym }
        for path in frameworks {
            if let handle = dlopen(path, RTLD_NOW), let sym = dlsym(handle, name) {
                return sym
            }
        }
        return nil
    }

    // MARK: DisplayServices.framework

    typealias DSGetBrightnessFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    typealias DSSetBrightnessFn = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private static let displayServicesPath = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"

    static let displayServicesGetBrightness: DSGetBrightnessFn? =
        symbol("DisplayServicesGetBrightness", frameworks: [displayServicesPath])
            .map { unsafeBitCast($0, to: DSGetBrightnessFn.self) }

    static let displayServicesSetBrightness: DSSetBrightnessFn? =
        symbol("DisplayServicesSetBrightness", frameworks: [displayServicesPath])
            .map { unsafeBitCast($0, to: DSSetBrightnessFn.self) }

    // MARK: IOAVService（DDC/CI over I2C，Apple Silicon）

    typealias IOAVCreateWithServiceFn = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    typealias IOAVI2CFn = @convention(c) (CFTypeRef?, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

    private static let ioavFrameworks = [
        "/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay",
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
    ]

    static let ioAVServiceCreateWithService: IOAVCreateWithServiceFn? =
        symbol("IOAVServiceCreateWithService", frameworks: ioavFrameworks)
            .map { unsafeBitCast($0, to: IOAVCreateWithServiceFn.self) }

    /// 系统「默认」AVService（通常是主显示器）。仅作输入源切换的最后兜底——SourceShift v1.0.2 即用此路径。
    typealias IOAVCreateFn = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?

    static let ioAVServiceCreate: IOAVCreateFn? =
        symbol("IOAVServiceCreate", frameworks: ioavFrameworks)
            .map { unsafeBitCast($0, to: IOAVCreateFn.self) }

    static let ioAVServiceWriteI2C: IOAVI2CFn? =
        symbol("IOAVServiceWriteI2C", frameworks: ioavFrameworks)
            .map { unsafeBitCast($0, to: IOAVI2CFn.self) }

    static let ioAVServiceReadI2C: IOAVI2CFn? =
        symbol("IOAVServiceReadI2C", frameworks: ioavFrameworks)
            .map { unsafeBitCast($0, to: IOAVI2CFn.self) }

    // MARK: CoreGraphics 私有函数（Intel Mac：CGDirectDisplayID → IOFramebuffer）

    /// `void CGSServiceForDisplayNumber(CGDirectDisplayID, io_service_t *)`，返回的端口由调用方释放。
    typealias CGSServiceForDisplayNumberFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<io_service_t>) -> Void

    static let cgsServiceForDisplayNumber: CGSServiceForDisplayNumberFn? =
        symbol("CGSServiceForDisplayNumber",
               frameworks: ["/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics"])
            .map { unsafeBitCast($0, to: CGSServiceForDisplayNumberFn.self) }

    // MARK: CoreDisplay

    typealias DisplayCreateInfoDictionaryFn = @convention(c) (CGDirectDisplayID) -> Unmanaged<CFDictionary>?

    static let coreDisplayCreateInfoDictionary: DisplayCreateInfoDictionaryFn? =
        symbol("CoreDisplay_DisplayCreateInfoDictionary",
               frameworks: ["/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay"])
            .map { unsafeBitCast($0, to: DisplayCreateInfoDictionaryFn.self) }

    static func displayInfoDictionary(_ displayID: CGDirectDisplayID) -> NSDictionary? {
        coreDisplayCreateInfoDictionary?(displayID)?.takeRetainedValue() as NSDictionary?
    }
}
