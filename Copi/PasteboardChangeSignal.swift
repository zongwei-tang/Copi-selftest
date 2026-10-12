//
//  PasteboardChangeSignal.swift
//  Copi
//
//  别的进程一写系统剪贴板，剪贴板服务就让本进程作废它缓存的剪贴板内容：CoreFoundation 内部的 _CFPasteboardCache 的
//  setChangeCount: 在 CFPasteboard 自己的后台队列上被调用。Chromium（139 版起）就靠拦下这个方法代替轮询剪贴板。
//  Copi 照做，只把它当作"该去看一眼了"的信号：拦下的方法里先调用原来的实现，再记个时间、合并之后 async 到主线程，绝不在后台碰
//  NSPasteboard（Chromium 第一版在后台线程上直接通知，出过 use-after-free）。主线程上照常检查一次（会读 changeCount，
//  让缓存重新"变脏"——剪贴板服务只在缓存是脏的时候才通知，下一次别的进程写入时才会再来）。
//  信号在主线程很忙的时候也会到：Accessibility 查询的间隙里（PasteboardQuarantine.checkpoint）据此不等节流、马上去看。
//  私有接口：类、方法不存在、类型编码不是 "v20@0:8i16"（返回 void、一个 int 参数）时什么都不改，Copi 照旧轮询、照旧用占位项。
//  它是"立即发现剪贴板变化"的首选方式：装上并且一直有信号时，不用再在剪贴板上放占位项（占位项别的 App 看得见）
//

import Foundation
import AppKit
import ObjectiveC

enum PasteboardChangeSignal {
    // 以下在 lock 里读写（拦下的方法在后台队列上调用）
    private static let lock = NSLock()
    // "立即发现剪贴板变化"开着（装上之后不卸载，关掉开关时只是不再理会信号）
    private static var enabled = false
    private static var mainCheckScheduled = false
    // 每来一次信号加一
    private static var signalSerial: UInt64 = 0
    private static var signalSinceCheckpoint = false

    // 以下只在主线程上用
    private(set) static var isInstalled = false
    private static var installAttempted = false
    // 主线程上一次检查剪贴板时的信号序号
    private static var serialAtLastCheck: UInt64 = 0
    // 连续几次：轮询发现了别的程序的写入，而从上一次检查以来却没来过信号。到 3 次就当作这个信号在这个系统上不可靠（改用占位项）
    private static var missedSignals = 0

    // 主线程：开着、装上了，并且没发现漏掉信号
    static var isHealthy: Bool {
        isInstalled && missedSignals < 3 && isEnabled
    }

    // 主线程：装一次（以后不卸载，关掉开关时只是不再用它）。装不上返回 false，什么都没改
    @discardableResult
    static func install() -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !installAttempted else {
            return isInstalled
        }
        installAttempted = true
        guard let cacheClass = NSClassFromString("_CFPasteboardCache") else {
            return false
        }
        let selector = NSSelectorFromString("setChangeCount:")
        // 只认这个类自己的方法（继承来的话改了会影响别的类）
        var count: UInt32 = 0
        guard let methods = class_copyMethodList(cacheClass, &count) else {
            return false
        }
        defer { free(methods) }
        var found: Method?
        for index in 0..<Int(count) where method_getName(methods[index]) == selector {
            found = methods[index]
        }
        guard let method = found, let encoding = method_getTypeEncoding(method), String(cString: encoding) == "v20@0:8i16" else {
            return false
        }
        typealias SetChangeCount = @convention(c) (AnyObject, Selector, Int32) -> Void
        let originalIMP = method_getImplementation(method)
        let original = unsafeBitCast(originalIMP, to: SetChangeCount.self)
        let replacement: @convention(block) (AnyObject, Int32) -> Void = { cache, changeCount in
            // 先记下信号再让缓存失效：轮询读到新的计数之前，序号一定已经变了
            let notify = noteSignal()
            original(cache, selector, changeCount)
            if notify {
                scheduleMainCheck()
            }
        }
        let previous = method_setImplementation(method, imp_implementationWithBlock(replacement))
        // 别人同时也改了这个方法：放回去，不用
        guard previous == originalIMP else {
            method_setImplementation(method, previous)
            return false
        }
        isInstalled = true
        // 读一次，让缓存"变脏"，下一次写入时剪贴板服务才会通知
        _ = NSPasteboard.general.changeCount
        return true
    }

    // 主线程：跟着"立即发现剪贴板变化"开关
    static func setEnabled(_ on: Bool) {
        if on {
            install()
            // 重新打开时重新判断可不可靠
            missedSignals = 0
        }
        lock.lock()
        enabled = on
        serialAtLastCheck = signalSerial
        lock.unlock()
    }

    // 任意线程
    static var isEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return enabled
    }

    // CFPasteboard 的后台队列上：只记录。返回 true 表示要安排一次主线程检查（合并：已经安排了就不再安排）
    private static func noteSignal() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard enabled else {
            return false
        }
        signalSerial &+= 1
        signalSinceCheckpoint = true
        let schedule = !mainCheckScheduled
        mainCheckScheduled = true
        return schedule
    }

    private static func scheduleMainCheck() {
        DispatchQueue.main.async {
            lock.lock()
            mainCheckScheduled = false
            lock.unlock()
            // 写入的一方往往先清空、再分几次写进内容和标记：稍等 5 毫秒再看，之后半秒加密检查（和占位项的通知一样）
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.005) {
                let pasteboard = NSPasteboard.general
                pasteboard.checkForChangesInPasteboard()
                if GlobalMode.shared.isProtecting {
                    pasteboard.checkFrequently(for: 0.5)
                }
            }
        }
    }

    // 主线程（PasteboardQuarantine.checkpoint）：上次看过之后有没有新的信号（读完清掉）
    static func consumeSignal() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let signaled = signalSinceCheckpoint
        signalSinceCheckpoint = false
        return signaled
    }

    // 主线程：每次检查系统剪贴板（以及 Copi 自己写完剪贴板）时调用。foreignChange：这次检查发现了一次不是 Copi 自己造成的变化。
    // 从上一次检查到现在一次信号都没来过，就是漏掉了（不管主线程这次晚了多久才来看）；来过就清零。
    // 判定不可靠之后，下一次 Copi 清空剪贴板时会放上占位项（这里不去抢：别的 App 可能刚清空、还没写完）
    static func noteCheck(foreignChange: Bool) {
        lock.lock()
        let serial = signalSerial
        lock.unlock()
        defer { serialAtLastCheck = serial }
        guard foreignChange, isHealthy, GlobalMode.shared.isProtecting else {
            return
        }
        missedSignals = serial == serialAtLastCheck ? missedSignals + 1 : 0
    }
}
