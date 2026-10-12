//
//  KeystrokeObservers.swift
//  Copi
//
//  现在有哪些程序能看到键盘输入：系统里所有 event tap 的清单（CGGetEventTapList）。Copi 用模拟键入粘贴时（终端、网页里的
//  一些地方），这些程序都看得到打出来的文字。清单里没有直接读键盘硬件的程序（系统设置里"输入监控"那一类用的是 IOHID）、
//  也没有驱动和系统内核层面的，所以只能作参考：系统设置 › 隐私与安全性 › 输入监控、辅助功能 里列着所有被允许的 App。
//

import Foundation
import AppKit

struct KeystrokeObserver: Identifiable, Equatable {
    let pid: pid_t
    let name: String
    let bundleIdentifier: String?
    // 能拦下、改写按键（主动过滤的 tap），而不只是看
    let canModify: Bool
    // 只看某几个 App 的按键（空：所有 App）
    let targets: [String]
    // tap 现在是否启用（停用的看不到按键，但随时可以重新启用）
    let enabled: Bool

    var id: pid_t { pid }
}

enum KeystrokeObservers {
    // 看得到按键的 tap：关心按下或松开（只关心修饰键变化的看不到打了什么字）
    private static let keyEventMask = (CGEventMask(1) << CGEventMask(CGEventType.keyDown.rawValue))
        | (CGEventMask(1) << CGEventMask(CGEventType.keyUp.rawValue))

    // 任意线程。按进程合并，Copi 自己的不算
    static func current() -> [KeystrokeObserver] {
        var count: UInt32 = 0
        guard CGGetEventTapList(0, nil, &count) == .success, count > 0 else {
            return []
        }
        // 两次调用之间可能又多了几个
        var taps = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count) + 8)
        guard CGGetEventTapList(UInt32(taps.count), &taps, &count) == .success else {
            return []
        }
        let ownPID = getpid()
        var byPID: [pid_t: (canModify: Bool, enabled: Bool, targets: Set<pid_t>, global: Bool)] = [:]
        for tap in taps.prefix(Int(min(count, UInt32(taps.count)))) {
            guard tap.eventsOfInterest & keyEventMask != 0, tap.tappingProcess != ownPID, tap.tappingProcess > 0 else {
                continue
            }
            var entry = byPID[tap.tappingProcess] ?? (false, false, [], false)
            entry.canModify = entry.canModify || tap.options == .defaultTap
            entry.enabled = entry.enabled || tap.enabled
            if tap.processBeingTapped > 0 {
                entry.targets.insert(tap.processBeingTapped)
            } else {
                entry.global = true
            }
            byPID[tap.tappingProcess] = entry
        }
        return byPID.map { pid, entry in
            let (name, bundleID) = describe(pid)
            let targets = entry.global ? [] : entry.targets.map { describe($0).name }.sorted()
            return KeystrokeObserver(pid: pid, name: name, bundleIdentifier: bundleID, canModify: entry.canModify,
                                     targets: targets, enabled: entry.enabled)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // 任意线程（"Don't Type When Keystrokes Are Watched" 用）：Copi 往 targetPID 模拟键入、事件发在 location 时，能看到这些按键的
    // 非系统程序的名字。事件从 HID 层流到会话层、再到"已标注"层，发在哪一层，就只经过那一层和之后的 tap（之前的看不到）；
    // 只看某个 App 的 tap 只有看的正是目标 App 时才算；目标 App 自己的 tap（虚拟机、远程桌面客户端）不算。
    // tap 清单默认缓存 1 秒
    // directToTarget：事件直接发给目标 App（CGEventPostToPid），全系统的 tap 都看不到，只算专门盯着它的。
    // 停用的 tap 也算：它的主人随时可以重新启用
    // maxAge：tap 清单的缓存最多用多久以前的
    static func thirdPartyWatchers(postedAt location: CGEventTapLocation, targetPID: pid_t, directToTarget: Bool = false,
                                   maxAge: TimeInterval = 1) -> [String] {
        cacheLock.lock()
        let taps: [KeyTap]
        if let cached, Date().timeIntervalSince(cached.at) < maxAge {
            taps = cached.taps
            cacheLock.unlock()
        } else {
            cacheLock.unlock()
            taps = keyTaps().filter { !isSystemProcess($0.pid) }
            cacheLock.lock()
            cached = (Date(), taps)
            cacheLock.unlock()
        }
        let watching = taps.filter { tap in
            guard tap.pid != targetPID else {
                return false
            }
            if tap.target > 0 {
                return tap.target == targetPID
            }
            return !directToTarget && tap.point.rawValue >= location.rawValue
        }
        var names: [String] = []
        for pid in Set(watching.map(\.pid)) {
            names.append(describe(pid).name)
        }
        return names.sorted()
    }

    // 一个看得到按键的 tap
    private struct KeyTap {
        let pid: pid_t
        let point: CGEventTapLocation
        // 只看这个进程（0：所有进程）
        let target: pid_t
        let enabled: Bool
    }

    private static let cacheLock = NSLock()
    private static var cached: (at: Date, taps: [KeyTap])?

    private static func keyTaps() -> [KeyTap] {
        var count: UInt32 = 0
        guard CGGetEventTapList(0, nil, &count) == .success, count > 0 else {
            return []
        }
        var taps = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count) + 8)
        guard CGGetEventTapList(UInt32(taps.count), &taps, &count) == .success else {
            return []
        }
        let ownPID = getpid()
        return taps.prefix(Int(min(count, UInt32(taps.count)))).compactMap { tap in
            guard tap.eventsOfInterest & keyEventMask != 0, tap.tappingProcess != ownPID, tap.tappingProcess > 0 else {
                return nil
            }
            return KeyTap(pid: tap.tappingProcess, point: tap.tapPoint, target: tap.processBeingTapped, enabled: tap.enabled)
        }
    }

    // 系统自带的后台组件：在 SIP 保护的系统目录里（第三方程序放不进去）。/usr/bin 里的 osascript、ruby 这类解释器能运行任何人写的脚本，
    // /System/Applications 里的"脚本编辑器"也一样，不算
    static func isSystemProcess(_ pid: pid_t) -> Bool {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else {
            return false
        }
        let path = String(cString: buffer)
        return ["/System/Library/", "/usr/libexec/", "/usr/sbin/", "/sbin/"].contains { path.hasPrefix($0) }
    }

    // 进程的显示名称：App 用它的名字，其他进程用可执行文件名
    private static func describe(_ pid: pid_t) -> (name: String, bundleIdentifier: String?) {
        if let app = NSRunningApplication(processIdentifier: pid) {
            return (app.localizedName ?? app.bundleIdentifier ?? "pid \(pid)", app.bundleIdentifier)
        }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 {
            let path = String(cString: buffer)
            return ((path as NSString).lastPathComponent, nil)
        }
        return ("pid \(pid)", nil)
    }
}
