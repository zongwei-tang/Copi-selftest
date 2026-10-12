//
//  GlobalMode.swift
//  SecureYourClipboard
//
//  Created by lixindong on 2024/4/19.
//

import Foundation
import AppKit
import Carbon
import Combine
import Defaults
import UserNotifications

// Override ⌘C/⌘V 模式
class GlobalMode {
    static let shared = GlobalMode()

    // 主线程迟迟不响应时，event tap 线程最多等这么久
    // event tap 线程最多等主线程这么久（系统会停用回调太慢的 tap，停用期间的按键绕过 Copi；留足余量）
    private let decisionTimeout: TimeInterval = 0.45
    // 一次 ⌘C/⌘V 处理里 Accessibility 查询的总时间预算（要明显小于上面的等待时间）
    private let axBudget: TimeInterval = 0.4

    private lazy var keyTap: KeyTap = KeyTap(events: [.keyDown, .flagsChanged]) { event in
        GlobalMode.shared.shouldSwallow(event)
    }
    private lazy var secureInputHotKeys: SecureInputHotKeys = SecureInputHotKeys(
        // 返回 true 表示松开时要补发一次 ⌘V / ⌘C，让 App 自己处理。keyTime：按键真正按下的时刻。
        // 热键排在主线程上处理：主线程卡住时它会晚到，这期间用户可能已经按了回车、Tab（焦点换到了别的输入框）。
        // 和 event tap 的路线一样，太晚（超过 1 秒）或者用户已经接着操作了就作废，不补发
        // shift、option：按的是 ⇧⌘V、⌥⇧⌘V
        // 别的程序合成的按键也会触发热键：键盘上那时刚按下过一个键才算用户亲手按的（见 hardwareInput）
        onPastePress: { keyTime, shift, option in
            if hardwareInput(.keyDown, at: keyTime) {
                PastePress.noteDeliberate(at: keyTime)
            }
            let isStale = { Date().timeIntervalSince(keyTime) > 1 || userActedSince(keyTime) }
            guard !isStale() else {
                notifyCopiNotice("Copi was busy and skipped a ⌘V to avoid pasting into the wrong place. Press ⌘V again.")
                return false
            }
            let chord: PasteChord = option ? .optionShiftCommand : (shift ? .shiftCommand : .command)
            return !GlobalMode.shared.handlePaste(chord: chord, isStale: isStale, keyTime: keyTime)
        },
        onCopyPress: { keyTime in
            if hardwareInput(.keyDown, at: keyTime) {
                CopyPress.noteDeliberate(at: keyTime)
            }
            guard Date().timeIntervalSince(keyTime) <= 1, !userActedSince(keyTime) else {
                GlobalMode.shared.refuseCopy(app: RefusedApp(target: nil), cut: false, reason: .busy)
                return false
            }
            return !GlobalMode.shared.handleCopy(cut: false, keyTime: keyTime)
        },
        onCutPress: { keyTime in
            if hardwareInput(.keyDown, at: keyTime) {
                CopyPress.noteDeliberate(at: keyTime)
            }
            guard Date().timeIntervalSince(keyTime) <= 1, !userActedSince(keyTime) else {
                GlobalMode.shared.refuseCopy(app: RefusedApp(target: nil), cut: true, reason: .busy)
                return false
            }
            return !GlobalMode.shared.handleCopy(cut: true, keyTime: keyTime)
        }
    )
    private var observation: Any? = nil
    private var fallbackObservation: Any? = nil
    private var normalClipboardAppsObservation: Any? = nil
    private var ownershipObservation: Any? = nil
    private var autoClearObservation: Any? = nil
    // 锁屏、显示器睡眠、切到别的用户：没人在用这台 Mac，"持续快速检查"暂停（主线程）
    fileprivate enum AwayReason {
        case locked, screensAsleep, sessionInactive
    }
    private var awayReasons = Set<AwayReason>()
    private var constantFastCheckObservation: Any? = nil
    private var knownNormalClipboardApps = Set(Defaults[.normalClipboardApps])
    // 为哪个放行的 App 把复制留在了系统剪贴板上（当时的剪贴板计数）
    private var leftForNormalClipboardApp: (bundleID: String, changeCount: Int)?
    // 最近一次在放行的 App 里放行的 ⌘C/⌘X、最近一次鼠标松开（点菜单、按钮里的"拷贝"）时拿着焦点的 App：
    // 据此判断系统剪贴板上的新内容是不是那个放行的 App 自己复制的
    // （changeCount：之后剪贴板上的第一版，只有它算这次 ⌘C 的结果）
    private var normalCopyPassedAt: (bundleID: String, at: Date, changeCount: Int?, boundAt: Date?)?
    private var lastMouseUp: (bundleID: String?, at: Date)?
    // 主线程：最近一次像是复制的快捷键（⌃C、⇧⌘C、⌃Insert 这类 Copi 不接管的）、终端和密码管理器里的回车时拿着焦点的 App
    private var lastShortcut: (bundleID: String?, at: Date)?
    private var lockObservers: [NSObjectProtocol] = []
    private var healthTimer: Timer?
    private var activity: NSObjectProtocol?
    private var inactiveTapTicks = 0
    private var pausedNotified = false
    // 安全剪贴板里的内容是不是比系统剪贴板上的更新（之后系统剪贴板上出现过别人的复制就不是了）
    private var safeCopyIsNewest = false
    // 最近一次安全复制的时间：紧接着、用户没有任何新操作时出现在系统剪贴板上的内容不是用户复制的（见 handleSystemPasteboardChange）
    private var lastSafeCopyAt: Date?
    // 开始保护时把系统剪贴板上已有的内容当作一次新复制重新处理：这次不是用户刚复制的，不要提示"经过了系统剪贴板"
    private var reprocessingChangeCount: Int?
    // 主线程：最近一次当作"不是在复制文字"放行了原生 ⌘C 的地方（"bundleID|AX 角色"）、时间，以及之后剪贴板上的第一版
    //（见 noteNonTextMisjudged）
    private var nonTextPassThrough: (key: String, at: Date, changeCount: Int?)?
    // 主线程：最近一次交给虚拟机、远程桌面客户机画面的 ⌘C/⌘X（客户机用它自己的剪贴板复制），以及那时安全剪贴板的版本
    // （它的剪贴板共享随后写进来、被转进 Copi 的那一份也算进去）。之后在同一个 App 的客户机画面里 ⌘V、Copi 里又没有更新的复制时，
    // 交给客户机用它自己的剪贴板粘贴（见 performPaste）
    private var guestCopy: GuestCopy?
    // 主线程：用户确认之后交给 App 自己做的复制（见 CopyThroughAppConsent）：哪个 App、什么时候。随后写进来的文字照常转进 Copi，
    // 通知说明是怎么回事
    private var consentedCopyPassedAt: (bundleID: String?, at: Date)?
    private struct GuestCopy {
        let pid: pid_t
        var secureVersion: Int
    }
    // 正在读哪一版剪贴板的数据（偏好设置里）：读的时候卡死、被看门进程重开后，不要再去读它（见 initialize）
    static let readingPasteboardKey = "readingPasteboardChangeCount"
    // 带 Transient 标记、暂时没有转移的复制：稍后再看一眼，如果一直没被恢复/替换，就当作普通复制转移
    private var transientRecheckChangeCount: Int?
    // 手动模式下最近一次看到 Transient 内容的时间：紧随其后的那次变化多半是工具在恢复原来的剪贴板
    private var lastTransientSeenAt: Date?

    // 给 event tap 线程读写的状态
    private let stateLock = NSLock()
    private var overrideActiveSnapshot = false
    // ⌘C/⌘X 已经交给主线程、还没处理完的个数（stateLock）
    private var copyDecisionsPending = 0
    // isProtecting 的副本，给 event tap 线程读（stateLock）
    private var protectingSnapshot = false
    private var nativePastePassedAt: Date?
    // 刚把一次原生 ⌘X 放行给 App：它剪切的图文混合内容不能只收走文字——图片已经从文档里删掉了（stateLock）
    private var nativeCutPassedAt: Date?
    // 主线程忙的时候从系统剪贴板上取下来、还没处理的复制（见 PasteboardQuarantine）：这时按下的 ⌘V 要交给 Copi（stateLock）
    private var quarantinePending = false
    // event tap 线程看到的 ⌘ 是否按着（stateLock）
    private var commandHeld = false
    // 上一次因为按了组合键而加密检查剪贴板的时间（stateLock）
    private var lastShortcutCheckAt = Date.distantPast

    // 文本扩展、剪贴板工具"写入 → 模拟 ⌘V → 恢复"时写进来的临时文字（带 Transient/AutoGenerated 标记）：一出现就从
    // 系统剪贴板上撤下来放在这里，不取代安全剪贴板里用户的复制；紧接着的 ⌘V 粘贴它。3 秒内没被马上粘贴的（有的 App 给所有复制
    // 都打这个标记）当作普通复制收进安全剪贴板
    private struct PendingSnippet {
        let text: String
        let concealed: Bool
        let at: Date
        // 写进来时安全剪贴板的版本：之后用户又复制了别的，就不再收它
        let secureVersion: Int
        var pastedAt: Date?
    }
    private var pendingSnippet: PendingSnippet? {
        didSet {
            stateLock.lock()
            hasPendingSnippet = pendingSnippet != nil
            stateLock.unlock()
            // Secure Input 期间靠 ⌘V 热键接管：有临时文字等着粘贴时也要注册
            secureInputHotKeys.updateNow()
        }
    }
    // event tap 线程据此决定 ⌘V 要不要交给主线程（stateLock）
    private var hasPendingSnippet = false
    // 这个剪贴板版本的临时文字在被撤下之前已经被原生粘贴过了
    private var snippetPastedNatively: Int?

    // Override 模式已开启并且有辅助功能权限
    private(set) var isOverrideActive = false
    // 并且 ⌘C/⌘V 拦截器确实在工作；只有这时才没收系统剪贴板上的复制，否则用户会什么都粘贴不了
    private(set) var isProtecting = false

    func initialize() {
        // 上次是在读剪贴板上的这一版时卡住的（提供数据的 App 不响应），之后被看门进程结束、重新打开：不再读它，直接清掉
        let defaults = UserDefaults.standard
        let stuckChangeCount = defaults.object(forKey: Self.readingPasteboardKey) as? Int
        defaults.removeObject(forKey: Self.readingPasteboardKey)
        if let stuckChangeCount, stuckChangeCount == NSPasteboard.general.changeCount {
            NSPasteboard.general.markSeen(NSPasteboard.general.clearContents())
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                notifyCopiNotice("Copi got stuck reading something an app put on the clipboard, so it removed it from the clipboard when it restarted.")
            }
        }
        KeyboardLayout.startCaching()
        NSPasteboard.general.onNewCopy { _ in
            GlobalMode.shared.handleSystemPasteboardChange()
        }
        PasteboardQuarantine.shared.handler = { copy in
            GlobalMode.shared.handleQuarantinedCopy(copy)
        }
        updateOverrideState()
        // Defaults.observe(keys:) 在注册时会针对每个 key 各自立即回调一次，
        // 这里统一走 updateOverrideState()（内部是幂等的），避免启动瞬间反复创建/销毁事件监听器。
        // 回调跑在修改设置的那个线程上，这里的处理都要在主线程。
        fallbackObservation = Defaults.observe(keys: .allowClipboardFallback) {
            // 关掉剪贴板回退时撤下还挂在系统剪贴板上的临时粘贴内容
            DispatchQueue.main.async {
                if ZeroExposurePolicy.isStrict {
                    TransientPaste.shared.finish()
                }
            }
        }
        observeLockAndSleep()
        // 从放行列表里移除了 App：它留在系统剪贴板上的复制重新处理一遍（收进 Copi、从系统剪贴板上撤下）
        normalClipboardAppsObservation = Defaults.observe(keys: .normalClipboardApps) {
            DispatchQueue.main.async {
                let mode = GlobalMode.shared
                let apps = Set(Defaults[.normalClipboardApps])
                let removed = mode.knownNormalClipboardApps.subtracting(apps)
                mode.knownNormalClipboardApps = apps
                // 只在系统剪贴板上留着的正是被移除的那个 App 的复制时才重新处理
                let pasteboard = NSPasteboard.general
                if mode.isProtecting, let left = mode.leftForNormalClipboardApp, removed.contains(left.bundleID),
                   left.changeCount == pasteboard.changeCount {
                    mode.leftForNormalClipboardApp = nil
                    mode.reprocessingChangeCount = pasteboard.changeCount
                    pasteboard.forgetLastCheckedChangeCount()
                }
            }
        }
        // 打开"立即发现剪贴板变化"时优先用系统的变化信号（PasteboardChangeSignal）；用不上时剪贴板正空着就马上占住。
        // 关掉时撤掉占位项（注册时会立即回调一次，启动时也走这里）
        ownershipObservation = Defaults.observe(keys: .instantClipboardDetection) {
            DispatchQueue.main.async {
                let pasteboard = NSPasteboard.general
                let on = Defaults[.instantClipboardDetection]
                PasteboardChangeSignal.setEnabled(on)
                if on, !PasteboardChangeSignal.isHealthy {
                    PasteboardOwnership.shared.claimIfEmpty(pasteboard)
                } else {
                    PasteboardOwnership.shared.release(pasteboard)
                }
            }
        }
        constantFastCheckObservation = Defaults.observe(keys: .constantFastCheck) {
            DispatchQueue.main.async {
                GlobalMode.shared.updateConstantFastCheck()
            }
        }
        // 改了自动清除的时间：按新的设置重新安排（从内容存进来的时候算起）
        autoClearObservation = Defaults.observe(keys: .autoClearMinutes) {
            DispatchQueue.main.async {
                SecureClipboard.shared.scheduleExpiry()
            }
        }
        observation = Defaults.observe(keys: .isOn, .overrideShortcuts) {
            if Thread.isMainThread {
                GlobalMode.shared.updateOverrideState()
            } else {
                DispatchQueue.main.async { GlobalMode.shared.updateOverrideState() }
            }
        }
        // 定期体检：辅助功能权限可能在运行中被授予或撤销（本地重新编译后旧的授权会失效，
        // 系统设置里却仍显示已开启），tap 也可能被系统停用或作废。
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            GlobalMode.shared.updateOverrideState()
            SystemClipboardFeatures.refresh()
            GlobalMode.shared.correctLockState()
        }
        RunLoop.main.add(timer, forMode: .common)
        healthTimer = timer
        // 稍等一下再提醒：刚启动时通知权限的申请可能还没完成
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            SystemClipboardFeatures.noticeSpotlightHistoryOnce()
        }
    }

    // 任意线程：键盘拦截器在处理按键（Override 模式开着、tap 起来了）
    var isInterceptingKeys: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return overrideActiveSnapshot && protectingSnapshot
    }

    // 任意线程：⌘C/⌘V 拦截器确实在工作
    var isProtectingNow: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return protectingSnapshot
    }

    // 任意线程：有没有要由 Copi 粘贴的内容（安全剪贴板，或者刚撤下来的临时文字）
    var hasSomethingToPaste: Bool {
        stateLock.lock()
        let snippet = hasPendingSnippet || quarantinePending
        stateLock.unlock()
        return snippet || SecureClipboard.shared.hasText || NonTextClipboard.shared.hasContent
    }

    // 主线程：菜单里点了"粘贴"（PointerInterceptor）。返回 false 时调用方替 App 按一次快捷键，粘贴系统剪贴板上的内容。
    // deliberate：是用户亲手点的、按的回车（见 hardwareInput）
    func handleMenuPaste(shift: Bool, option: Bool, keyTime: Date, deliberate: Bool) -> Bool {
        if deliberate {
            PastePress.noteDeliberate(at: keyTime)
        }
        let chord: PasteChord = option ? .optionShiftCommand : (shift ? .shiftCommand : .command)
        return handlePaste(chord: chord, isStale: { userActedSince(keyTime) }, keyTime: keyTime)
    }

    // 任意线程：刚（1 秒内）放行过一次原生 ⌘X。clear：用掉这次记录
    private func nativeCutJustPassed(clear: Bool = false) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let cutAt = nativeCutPassedAt, Date().timeIntervalSince(cutAt) < 1 else {
            return false
        }
        if clear {
            nativeCutPassedAt = nil
        }
        return true
    }

    // 任意线程：刚（0.5 秒内）放行过一次原生 ⌘V，App 可能正在读系统剪贴板
    private var nativePasteJustPassed: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return nativePastePassedAt.map { Date().timeIntervalSince($0) < 0.5 } ?? false
    }

    // 任意线程：从 date 起放行过原生 ⌘V（例如读一份很大的复制的那几秒里）
    private func nativePastePassed(since date: Date) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return nativePastePassedAt.map { $0 >= date } ?? false
    }

    // 任意线程（PasteboardWatcher 在后台线程上问）：主线程忙的时候，后台线程可不可以替它把系统剪贴板上新出现的文字取下来。
    // 只在照常处理也一定会转移走的情况下：正在保护、没有刚放行的原生粘贴/剪切（App 可能正要读、或者内容带着刚剪掉的图片）、
    // 拿着焦点的不是放行的 App（它自己的复制要留在系统剪贴板上）。内容本身（文件、通用剪贴板、临时内容……）由后台线程看
    var mayQuarantineNewCopies: Bool {
        guard isProtectingNow, Defaults[.isOn], Defaults[.overrideShortcuts], !nativePasteJustPassed, !nativeCutJustPassed() else {
            return false
        }
        return !ZeroExposurePolicy.usesNormalClipboard(focusedApplication()?.bundleIdentifier)
    }

    // 主线程（PasteboardQuarantine、captureNonText）：要取下一份复制了。刚放行了原生 ⌘V（App 可能正在读）就不取；否则从现在起 ⌘V 交给 Copi。
    // 判断和登记一起做（event tap 线程同时在看这两个状态）
    func beginQuarantine() -> Bool {
        stateLock.lock()
        if let passedAt = nativePastePassedAt, Date().timeIntervalSince(passedAt) < 0.5 {
            stateLock.unlock()
            return false
        }
        quarantinePending = true
        stateLock.unlock()
        // Secure Input 期间靠 ⌘V 热键接管：有取下来的复制等着时也要注册（在清空剪贴板之前注册好，免得这期间的 ⌘V 原生粘贴出空的）
        secureInputHotKeys.updateNow()
        return true
    }

    // 主线程：取下来的复制都处理完了
    func endQuarantine() {
        stateLock.lock()
        let wasPending = quarantinePending
        quarantinePending = false
        stateLock.unlock()
        if wasPending {
            secureInputHotKeys.updateNow()
        }
    }

    // 主线程：鼠标键松开（MouseEventCatcher）
    // 主线程：用户在这个 App 的菜单里选了"拷贝/剪切"（放行的 App：照常进系统剪贴板，这是它自己的复制）
    func noteUserCommand(in bundleID: String?) {
        lastShortcut = (bundleID, Date())
    }

    // 主线程：鼠标松开。只有点在拿着焦点的 App 自己的窗口里才算它的点击（点别的 App 的菜单栏图标、不激活自己的浮窗不算）：
    // 放行的 App 接下来一秒里的复制算它自己的
    // windowNumber：按下时指针下面的窗口（事件里带的，不是处理时指针在的地方）
    func noteMouseUp(windowNumber: Int? = nil) {
        let focused = focusedApplication()
        func owner(of number: Int) -> pid_t? {
            guard number > 0, let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(number)) as? [[String: Any]] else {
                return nil
            }
            return (info.first?[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
        }
        // 事件里没带窗口时按现在指针下面的窗口查。带了、但这时已经关了（别的 App 的菜单）：不算谁的点击
        let owner = (windowNumber ?? 0) > 0 ? owner(of: windowNumber ?? 0)
            : owner(of: NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0))
        lastMouseUp = (owner != nil && owner == focused?.processIdentifier ? focused?.bundleIdentifier : nil, Date())
    }

    // 系统剪贴板上的新内容确实是这个放行的 App 自己复制的：它声明了来源（nspasteboard.org 的 source 类型），
    // 或者刚刚在它里面放行了 ⌘C/⌘X、点了鼠标（菜单、按钮里的"拷贝"、选中即复制）。放行的 App 在前台时，后台程序
    // （pbcopy、密码管理器、同步工具）写进来的内容不算——只有这个 App 出来的文字可以留在系统剪贴板上
    // changeCount：正在处理的那一版（调用方拿到 items 时的）
    private func copiedByNormalClipboardApp(_ bundleID: String, pasteboard: NSPasteboard, changeCount: Int) -> Bool {
        if let source = pasteboard.string(forType: NSPasteboard.PasteboardType("org.nspasteboard.source")), !source.isEmpty {
            return source == bundleID
        }
        let now = Date()
        // 刚放行给它的 ⌘C/⌘X：之后剪贴板上的第一版确定是它自己的复制（之后别的程序再写进来的不算）
        // （写得慢的 App 一次复制会分几版写完：绑定之后 0.3 秒内紧接着的几版也算）
        if var passed = normalCopyPassedAt, passed.bundleID == bundleID, now.timeIntervalSince(passed.at) < 2 {
            if passed.changeCount == nil {
                passed.changeCount = changeCount
                passed.boundAt = now
                normalCopyPassedAt = passed
            }
            if let bound = passed.changeCount,
               changeCount == bound || (changeCount > bound && now.timeIntervalSince(passed.boundAt ?? now) < 0.3) {
                return true
            }
        }
        // 机密内容（密码管理器的浮窗、Raycast 里复制的密码）：只凭点击、快捷键这类旁证不算它的复制（浮窗复制完就关了，焦点回到
        // 下面的 App），除非这个 App 本身就是密码管理器
        if pasteboard.types?.contains(.nspasteboardConcealed) == true, !ZeroExposurePolicy.isPasswordManager(bundleID) {
            return false
        }
        // 它自己的复制快捷键（⌃C、⇧⌘C……）、终端和密码管理器里的回车
        if let shortcut = lastShortcut, shortcut.bundleID == bundleID, now.timeIntervalSince(shortcut.at) < 1 {
            return true
        }
        if let click = lastMouseUp, click.bundleID == bundleID, now.timeIntervalSince(click.at) < 1 {
            return true
        }
        return false
    }

    // 刚存入了一份安全复制（并且已经清掉了系统剪贴板上更旧的内容，如果需要的话）
    func noteSafeCopy() {
        safeCopyIsNewest = true
        lastSafeCopyAt = Date()
    }

    // 锁屏、睡眠、切换到别的用户时清空 Copi 剪贴板：离开电脑后它不该还能被粘贴出来，菜单栏面板里也不该还看得到
    private func observeLockAndSleep() {
        // 锁屏通知没有公开的常量；必须要求立即送达，否则后台的菜单栏 App 要等到下次被激活才收到
        DistributedNotificationCenter.default().addObserver(lockObserver,
                                                            selector: #selector(LockObserver.screenDidLock(_:)),
                                                            name: NSNotification.Name("com.apple.screenIsLocked"),
                                                            object: nil,
                                                            suspensionBehavior: .deliverImmediately)
        DistributedNotificationCenter.default().addObserver(lockObserver,
                                                            selector: #selector(LockObserver.screenDidUnlock(_:)),
                                                            name: NSNotification.Name("com.apple.screenIsUnlocked"),
                                                            object: nil,
                                                            suspensionBehavior: .deliverImmediately)
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            lockObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { _ in
                GlobalMode.clearSecureClipboardIfWanted()
            })
        }
        // 没人在用这台 Mac 时"持续快速检查"暂停，省电
        let awayChanges: [(NSNotification.Name, AwayReason, Bool)] = [
            (NSWorkspace.screensDidSleepNotification, .screensAsleep, true), (NSWorkspace.screensDidWakeNotification, .screensAsleep, false),
            (NSWorkspace.sessionDidResignActiveNotification, .sessionInactive, true),
            (NSWorkspace.sessionDidBecomeActiveNotification, .sessionInactive, false),
        ]
        for (name, reason, away) in awayChanges {
            lockObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { _ in
                GlobalMode.shared.setAway(reason, away)
                // 快速切换用户切到了别的用户（只看通知：屏幕共享的虚拟会话一直不在 console 上，却是用户正在用的会话）
                if reason == .sessionInactive {
                    SessionActivity.setSwitchedAway(away)
                }
            })
        }
        // 启动时就已经锁屏、显示器睡着了（例如崩溃后被看门进程重新打开）：通知不会再来，先查一次现在的状态
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        if session?["CGSSessionScreenIsLocked"] as? Bool == true {
            awayReasons.insert(.locked)
        }
        if session?["kCGSSessionOnConsoleKey"] as? Bool == false {
            awayReasons.insert(.sessionInactive)
        }
        if CGDisplayIsAsleep(CGMainDisplayID()) != 0 {
            awayReasons.insert(.screensAsleep)
        }
        updateConstantFastCheck()
    }

    private let lockObserver = LockObserver()

    fileprivate static func clearSecureClipboardIfWanted() {
        guard Defaults[.clearOnLock] else {
            return
        }
        // 正在借助系统剪贴板复制（手动模式的回退）：晚到的结果不能在锁屏之后又填回来
        ClipboardCapture.shared.cancel()
        SecureClipboard.shared.setText(nil)
        TransientPaste.shared.finish()
        GlobalMode.shared.pendingSnippet = nil
    }

    func updateOverrideState() {
        dispatchPrecondition(condition: .onQueue(.main))
        let wanted = Defaults[.isOn] && Defaults[.overrideShortcuts]
        let trusted = AXIsProcessTrusted()
        defer {
            // Copi 开着却没有辅助功能权限（重新编译、系统更新后授权会失效，系统设置里却仍显示已开启），
            // 或者 Override 模式下拦截器起不来：提醒一次，恢复正常后再出问题时再提醒
            let healthy = !Defaults[.isOn] || (trusted && (!wanted || isProtecting))
            if healthy {
                pausedNotified = false
            } else if !pausedNotified {
                pausedNotified = true
                notifyProtectionPaused()
            }
            // 菜单栏图标、面板上一直看得到的状态（通知可能被关掉了）
            let state: ProtectionStatus.State
            if !Defaults[.isOn] {
                state = .off
            } else if !trusted {
                state = .paused(needsAccessibility: true)
            } else if !wanted {
                state = .manual
            } else {
                state = !isProtecting ? .paused(needsAccessibility: false)
                    : SystemClipboardFeatures.cachedPasteboardAccess == .allowed ? .protecting : .limited
            }
            ProtectionStatus.shared.update(state)
        }
        let active = wanted && trusted
        setOverrideActive(active)
        guard active else {
            keyTap.stop()
            inactiveTapTicks = 0
            setProtecting(false)
            return
        }
        keyTap.start()
        keyTap.ensureEnabled()
        if keyTap.isActive {
            inactiveTapTicks = 0
            setProtecting(true)
            PointerInterceptor.shared.ensureRunning()
            return
        }
        // 偶尔一次没启用上先不动；连续两次就重建（mach port 可能已经被系统作废）
        inactiveTapTicks += 1
        guard inactiveTapTicks >= 2 else {
            return
        }
        inactiveTapTicks = 0
        keyTap.stop()
        setProtecting(keyTap.start() && keyTap.isActive)
    }

    private func setOverrideActive(_ active: Bool) {
        guard active != isOverrideActive else {
            return
        }
        isOverrideActive = active
        stateLock.lock()
        overrideActiveSnapshot = active
        stateLock.unlock()
        if active {
            // 一直在后台的菜单栏 App 容易被 App Nap 拉长计时器（剪贴板轮询、粘贴后的撤下……）
            activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                             reason: "Copi protects ⌘C/⌘V")
            // Secure Input 期间 tap 本来就看不到按键，⌘C/⌘V 热键不依赖 tap 是否健康
            secureInputHotKeys.start()
        } else {
            if let activity {
                ProcessInfo.processInfo.endActivity(activity)
            }
            activity = nil
            secureInputHotKeys.stop()
            TransientPaste.shared.finish()
        }
    }

    private func setProtecting(_ protecting: Bool) {
        guard protecting != isProtecting else {
            return
        }
        isProtecting = protecting
        stateLock.lock()
        protectingSnapshot = protecting
        stateLock.unlock()
        // 菜单里的拷贝粘贴、拖动文字：跟着 ⌘C/⌘V 的接管一起开关
        if protecting {
            PointerInterceptor.shared.start()
            FindPasteboardScrubber.shared.start()
        } else {
            PointerInterceptor.shared.stop()
            FindPasteboardScrubber.shared.stop()
            PasteboardOwnership.shared.release(NSPasteboard.general)
        }
        updateConstantFastCheck()
        guard protecting else {
            return
        }
        let pasteboard = NSPasteboard.general
        if SecureClipboard.shared.hasText, safeCopyIsNewest {
            // 系统剪贴板上的内容比安全剪贴板里的旧（例如手动模式下 ⌥C 之后才打开 Override）：清掉它，⌘V 粘贴安全剪贴板
            if !TransientPaste.shared.isActive {
                pasteboard.markSeen(pasteboard.copiClear())
            }
        } else {
            // 开始保护前系统剪贴板上已有的文本也收进安全剪贴板（和启动时的行为一致）
            reprocessingChangeCount = pasteboard.changeCount
            pasteboard.forgetLastCheckedChangeCount()
        }
        // 剪贴板空着就马上占住（开着"立即发现剪贴板变化"时）
        PasteboardOwnership.shared.claimIfEmpty(pasteboard)
    }

    // 主线程："持续快速检查"只在保护期间生效
    private func updateConstantFastCheck() {
        PasteboardQuarantine.shared.setConstantFastCheck(isProtecting && Defaults[.constantFastCheck] && awayReasons.isEmpty)
    }

    // 主线程
    // 主线程：收到了锁屏通知。任何程序都能发这个通知（不用任何权限）：先确认真的锁屏了才算（系统的状态可能稍晚一点才变），
    // 免得被伪造的通知悄悄停掉用户打开的"持续快速检查"
    fileprivate func confirmLocked(attempt: Int = 0) {
        let delays: [TimeInterval] = [0.1, 0.5, 1, 2]
        guard attempt < delays.count else {
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delays[attempt]) {
            if screenIsLockedNow() {
                GlobalMode.shared.setAway(.locked, true)
            } else {
                GlobalMode.shared.confirmLocked(attempt: attempt + 1)
            }
        }
    }

    // 主线程，每秒的体检里：以为锁着屏、其实没有（解锁的通知丢了）时改过来
    fileprivate func correctLockState() {
        if awayReasons.contains(.locked), !screenIsLockedNow() {
            setAway(.locked, false)
        }
    }

    fileprivate func setAway(_ reason: AwayReason, _ away: Bool) {
        if away {
            awayReasons.insert(reason)
        } else {
            awayReasons.remove(reason)
        }
        updateConstantFastCheck()
    }

    private func notifyProtectionPaused() {
        // 稍等一下再发：刚启动时通知权限的申请可能还没完成；到时候已经恢复了就不发
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            guard GlobalMode.shared.pausedNotified else {
                return
            }
            let content = UNMutableNotificationContent()
            content.title = "Copi"
            content.body = AXIsProcessTrusted()
                ? "Copy/paste protection is paused: Copi couldn't start intercepting ⌘C/⌘V. Copies stay on the system clipboard meanwhile."
                : "Copy/paste protection is paused: Copi needs Accessibility permission again (System Settings › Privacy & Security). Copies stay on the system clipboard meanwhile."
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "copi.paused", content: content, trigger: nil))
        }
    }

    // MARK: - 系统剪贴板变化

    private func handleSystemPasteboardChange() {
        guard !ClipboardCapture.shared.isActive else {
            return
        }
        let pasteboard = NSPasteboard.general
        guard let items = pasteboard.pasteboardItems, !items.isEmpty else {
            return
        }
        // 我们自己挂上去的粘贴内容（被读取时剪贴板计数可能会变）、Copi 占住剪贴板的占位项
        if TransientPaste.shared.owns(items) {
            pasteboard.markSeen(pasteboard.changeCount)
            return
        }
        if PasteboardOwnership.isPlaceholder(items) {
            pasteboard.markSeen(pasteboard.changeCount)
            // 不是 Copi 现在占着的那一份：重新占住，否则收不到下一次写入的通知
            PasteboardOwnership.shared.claimIfEmpty(pasteboard)
            return
        }
        let types = Set(items.flatMap { $0.types })
        let changeCount = pasteboard.changeCount
        let reprocessing = reprocessingChangeCount == changeCount
        reprocessingChangeCount = nil
        // 下面读数据时可能卡住（提供数据的 App 不响应）：记下这一版，卡死被重开后不再读它。
        // "从其他 App 粘贴"设成"询问"（或者还没问过）时，读的时候系统会弹出询问、等用户回答：这不是卡住，请看门进程这期间
        //（最多 2 分钟）别把 Copi 当成卡死
        let mayAsk = SystemClipboardFeatures.cachedMayPrompt
        if mayAsk {
            CrashWatchdog.pauseHangCheck()
        }
        UserDefaults.standard.set(changeCount, forKey: Self.readingPasteboardKey)
        // 这次有没有真的读过内容（只看类型不会弹出询问）
        var didReadContents = false
        defer {
            if mayAsk {
                CrashWatchdog.resumeHangCheck()
                if didReadContents {
                    SystemClipboardFeatures.noteReadCompleted()
                }
            }
            UserDefaults.standard.removeObject(forKey: Self.readingPasteboardKey)
        }
        // 刚才当作"不是在复制文字"放行的 ⌘C：只看紧接着的这一版（见 noteNonTextMisjudged）。这一版可能要再处理几次
        //（还没写完、读不出来时的复查），记住是哪一版
        if var pending = nonTextPassThrough {
            if pending.changeCount == nil {
                pending.changeCount = changeCount
                nonTextPassThrough = pending
            } else if pending.changeCount != changeCount {
                nonTextPassThrough = nil
            }
        }
        let passThrough = nonTextPassThrough.flatMap { $0.changeCount == changeCount ? (key: $0.key, at: $0.at) : nil }
        // 刚做完一次安全复制、用户还没有任何新的按键或点击，就有新内容出现在系统剪贴板上：这不是用户复制的——他的 ⌘C 已经被
        // Copi 处理掉，App 根本没收到。典型的是剪贴板劫持工具趁用户复制时写入自己的内容（例如换掉钱包地址）。不管它带什么类型
        // （任何程序都能给自己的内容加上"通用剪贴板""临时""文件"的标记），都不收、不让它取代用户的复制，从系统剪贴板上清掉。
        // Copi 自己模拟 ⌘C 之后晚到的复制（见 ClipboardCapture）除外。
        if Defaults[.isOn], Defaults[.overrideShortcuts], isProtecting, !ClipboardCapture.shared.hasPendingLateWrite,
           let copiedAt = lastSafeCopyAt, Date().timeIntervalSince(copiedAt) < 3, !userActedSince(copiedAt) {
            pasteboard.markSeen(pasteboard.copiClear())
            notifyCopiNotice("Copi blocked something another app put on the clipboard right after your copy, and kept what you copied.")
            return
        }
        // 从用户的其他 Apple 设备经"通用剪贴板"同步过来的复制：那边的剪贴板上本来就有，不是 Copi 要保护的内容。
        // 原样留着照常粘贴（像别的设备上新复制了东西一样，它取代安全剪贴板里更早的内容）。不能读它的数据：
        // 第一次读会触发从那台设备传输，可能卡住主线程好几秒，还会在本机留下缓存文件
        if types.contains(.universalClipboardRemote) {
            safeCopyIsNewest = false
            if Defaults[.isOn], isProtecting || !Defaults[.overrideShortcuts] {
                SecureClipboard.shared.setText(nil)
            }
            return
        }
        // 别的工具把我们挂上去的内容原样存下来又恢复了回去：这是一份泄漏出去的副本，清掉
        // （任何模式下都清：它从定义上就是 Copi 自己挂上去的明文，例如手动模式下粘贴时崩溃留下的）
        if types.contains(where: { $0.isCopiStaged }) {
            pasteboard.markSeen(pasteboard.copiClear())
            return
        }
        // 文本扩展、剪贴板管理工具"写入 → 模拟 ⌘V → 恢复"的临时内容：原样留给它们自己的粘贴，
        // 也不影响安全剪贴板里用户真正复制的内容。但有的 App（例如 Enpass）给所有复制都打这个标记，
        // 所以过 3 秒还没被恢复/替换的，就当作普通复制处理。
        // （只有富文本、网页内容的也取出文字；有文字类型却还读不出来的，像普通复制一样半秒内再读几次，不要盲等 3 秒）
        var transientSnippet: String?
        if !types.isDisjoint(with: [.nspasteboardTransient, .nspasteboardAutoGenerated]), Defaults[.isOn], Defaults[.overrideShortcuts], isProtecting,
           !types.contains(.fileURL) {
            transientSnippet = items.lazy.compactMap({ $0.string(forType: .string) }).first ?? copiTextFromRichContent(items)
            didReadContents = true
            if transientSnippet == nil, !types.isDisjoint(with: textTypes), SystemClipboardFeatures.cachedPasteboardAccess == .allowed,
               pasteboard.recheckUntilComplete(changeCount: changeCount, retryRead: true) {
                return
            }
        }
        if let snippet = transientSnippet, !snippet.isEmpty, !snippet.contains("\u{FFFC}") {
            // 写入者声明的来源：清空之前读（清空之后这些 item 就读不到了）
            let snippetSource = types.contains(NSPasteboard.PasteboardType("org.nspasteboard.source"))
                ? items.lazy.compactMap({ $0.string(forType: NSPasteboard.PasteboardType("org.nspasteboard.source")) }).first : nil
            // 放行的 App 自己复制的（有的 App 给所有复制都打这个标记）：照常留在系统剪贴板上
            if let bundleID = focusedApplication()?.bundleIdentifier, ZeroExposurePolicy.usesNormalClipboard(bundleID),
               copiedByNormalClipboardApp(bundleID, pasteboard: pasteboard, changeCount: changeCount) {
                safeCopyIsNewest = false
                leftForNormalClipboardApp = (bundleID, changeCount)
                return
            }
            // 刚把一次原生 ⌘V 放行给 App（那时 Copi 还没看到这段文字），App 可能正在读它：稍后再撤下，并记下它已经粘贴过。
            // 判断和"从现在起 ⌘V 交给主线程"要一起做（event tap 线程同时在看这两个状态）
            stateLock.lock()
            let passedAt = nativePastePassedAt
            let deferIt = passedAt.map { Date().timeIntervalSince($0) < 0.5 && (pasteboard.lastUnchangedCheckAt ?? .distantPast) <= $0 } ?? false
            if !deferIt {
                hasPendingSnippet = true
            }
            stateLock.unlock()
            if deferIt {
                snippetPastedNatively = changeCount
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    if NSPasteboard.general.changeCount == changeCount {
                        NSPasteboard.general.forgetLastCheckedChangeCount()
                    }
                }
                return
            }
            pasteboard.markSeen(pasteboard.copiClear())
            // 上一段临时文字还没有被它的工具马上粘贴、之后也没有新的复制（例如密码管理器的复制）：先收进安全剪贴板，不能丢
            if let old = pendingSnippet, old.text != snippet, SecureClipboard.shared.version == old.secureVersion,
               old.pastedAt.map({ $0.timeIntervalSince(old.at) >= 0.5 }) ?? true {
                SecureClipboard.shared.setText(old.text, concealed: old.concealed)
                safeCopyIsNewest = true
            }
            let arrived = Date()
            let pending = PendingSnippet(text: snippet, concealed: types.contains(.nspasteboardConcealed)
                                            || ZeroExposurePolicy.isPasswordManager(focusedApplication()?.bundleIdentifier)
                                            || ZeroExposurePolicy.isPasswordManager(snippetSource), at: arrived,
                                         secureVersion: SecureClipboard.shared.version,
                                         pastedAt: snippetPastedNatively == changeCount ? arrived : nil)
            snippetPastedNatively = nil
            pendingSnippet = pending
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                GlobalMode.shared.resolvePendingSnippet(arrivedAt: pending.at)
            }
            return
        }
        if !types.isDisjoint(with: [.nspasteboardTransient, .nspasteboardAutoGenerated]), transientRecheckChangeCount != changeCount {
            lastTransientSeenAt = Date()
            transientRecheckChangeCount = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                guard NSPasteboard.general.changeCount == changeCount else {
                    return
                }
                GlobalMode.shared.transientRecheckChangeCount = changeCount
                NSPasteboard.general.forgetLastCheckedChangeCount()
            }
            return
        }
        guard Defaults[.isOn] else {
            safeCopyIsNewest = false
            return
        }
        // 读文本可能要等源 App 当场生成，只在真正用得到时读。读不出来时返回 nil（和空字符串区分开）
        func readText() -> String? {
            didReadContents = true
            return items.lazy.compactMap { $0.string(forType: .string) }.first
        }
        if ClipboardCapture.shared.hasPendingLateWrite, let lateText = readText() ?? copiTextFromRichContent(items), !lateText.isEmpty,
           ClipboardCapture.shared.handleLateWrite(pasteboard, text: lateText) {
            return
        }
        guard Defaults[.overrideShortcuts] else {
            // 手动模式：系统剪贴板有了新内容，安全剪贴板里的旧内容就作废——
            // 除非这是文本扩展工具紧接着把原来的剪贴板内容恢复回去
            if let lastTransientSeenAt, Date().timeIntervalSince(lastTransientSeenAt) < 3 {
                self.lastTransientSeenAt = nil
                return
            }
            safeCopyIsNewest = false
            SecureClipboard.shared.setText(nil)
            return
        }
        // ⌘V 拦截器没在工作时（没有辅助功能权限等）不能没收系统剪贴板，否则用户什么都粘贴不了
        guard isProtecting else {
            safeCopyIsNewest = false
            return
        }
        // 用户放行、照常使用系统剪贴板的 App 自己的复制：原样留在系统剪贴板上，安全剪贴板里更旧的内容作废
        // （按真正拿着焦点的 App 判断：放行的 App 在前台时，浮动面板里的复制、后台程序写进来的内容照样要转移）
        if let bundleID = focusedApplication()?.bundleIdentifier, ZeroExposurePolicy.usesNormalClipboard(bundleID),
           copiedByNormalClipboardApp(bundleID, pasteboard: pasteboard, changeCount: changeCount) {
            safeCopyIsNewest = false
            SecureClipboard.shared.setText(nil)
            leftForNormalClipboardApp = (bundleID, changeCount)
            return
        }
        // 没有纯文本时，从富文本、网页内容、链接里取出文字（不取的话它会被当作图片之类的内容留在系统剪贴板上）
        let readStarted = Date()
        guard let text = readText() ?? copiTextFromRichContent(items) ?? (types.isDisjoint(with: textTypes) ? "" : nil) else {
            // 明明有文本却读不出来。写入方可能只声明了类型、还没写进数据：半秒内每 50 毫秒再读一次。读得很慢的（提供数据的 App
            // 卡住了）不再读，macOS 不让 Copi 读、或者读的时候会弹窗问的也不重读
            let access = SystemClipboardFeatures.cachedPasteboardAccess
            if Date().timeIntervalSince(readStarted) < 0.1, access == .allowed,
               pasteboard.recheckUntilComplete(changeCount: changeCount, retryRead: true) {
                return
            }
            // 它比安全剪贴板里的内容更新，旧的作废。0 暴露：读不出来的文字也不能一直留在系统剪贴板上（别的 App 读得到），
            // 清掉并告诉用户；允许剪贴板回退时照旧留着，照常原生粘贴（不丢这次复制）
            safeCopyIsNewest = false
            SecureClipboard.shared.setText(nil)
            // 带着文件、图片的（访达里复制的文件也带着一份文件名文字）不是文字的复制：照常留着
            let nonText: Set<NSPasteboard.PasteboardType> = [
                .fileURL, .tiff, .png, .pdf, NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("public.heic"),
                NSPasteboard.PasteboardType("NSFilenamesPboardType"), NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url"),
                NSPasteboard.PasteboardType("com.apple.NSFilePromiseItemMetaData"),
            ]
            if ZeroExposurePolicy.isStrict, types.isDisjoint(with: nonText) {
                pasteboard.markSeen(pasteboard.copiClear())
                notifyCopiNotice(access == .allowed
                    ? "Copi couldn't read text an app put on the clipboard, so it removed it instead of leaving it there for other apps. Copy it again."
                    : "macOS didn't let Copi read text an app put on the clipboard, so Copi removed it instead of leaving it there for other apps. Set Copi to Allow under Privacy & Security › Paste from Other Apps.")
            }
            return
        }
        let plainText = text.replacingOccurrences(of: "\u{FFFC}", with: "")
        let hasMeaningfulText = !plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // 文字里夹着图片等附件（U+FFFC 占位符）的富文本：文字照样转移走（附件不经过剪贴板就带不走，丢掉并告诉用户），
        // 不能为了附件把文字留在系统剪贴板上
        let droppedAttachments = text.contains("\u{FFFC}") && hasMeaningfulText
        if droppedAttachments, nativeCutJustPassed(clear: true) {
            // 刚放行的原生剪切：图片已经从文档里删掉，只收走文字就等于把它们弄丢，原样留在系统剪贴板上
            safeCopyIsNewest = false
            SecureClipboard.shared.setText(nil)
            return
        }
        // 只看到标记、还没有任何内容（写入方先写标记、再写文字）：先等一等，不要清空——清空之后它接下来的写入就失败了
        if text.isEmpty, types.isDisjoint(with: textTypes), types.isSubset(of: plainTextTypes),
           pasteboard.recheckUntilComplete(changeCount: changeCount, retryRead: false) {
            return
        }
        if types.contains(.fileURL) || (!hasMeaningfulText && !types.isSubset(of: plainTextTypes)) {
            // Finder 里复制的文件、只有图片之类不是文字的内容：它比安全剪贴板里的内容更新，旧的作废。
            // 写入方可能还没写完（先写了图片、来源标记，文字最后才写）：半秒内类型有了变化就重新处理。
            // 写完之后整个取下来存进 Copi、从系统剪贴板上清掉，粘贴时才短暂放上去（见 captureNonText）
            if !types.contains(.fileURL) {
                _ = pasteboard.recheckUntilComplete(changeCount: changeCount, retryRead: false)
            }
            safeCopyIsNewest = false
            SecureClipboard.shared.setText(nil)
            // 挂着的粘贴内容（给附近的设备的一分钟、读后还留着的文件）已经被这份取代：只是复位，否则 captureNonText 以为还挂着，就不取了
            TransientPaste.shared.finish()
            // 客户机里刚复制、它的剪贴板共享写过来的图片、文件：和文字一样（见下面），在客户机里粘贴照样交给客户机
            if let guest = guestCopy, focusedApplication()?.processIdentifier == guest.pid {
                guestCopy?.secureVersion = SecureClipboard.shared.version
            }
            scheduleNonTextCapture(changeCount: changeCount)
            return
        }
        // 刚把一次原生 ⌘V 放行给 App（当时安全剪贴板是空的），App 可能还没读完剪贴板：
        // 例如"写入 → 模拟 ⌘V"的工具刚写进来的内容，这时转移走它就粘贴不出来了。稍后再转移。
        // 只针对可能早于这次 ⌘V 的变化：放行之后已经检查到过"没有变化"，说明这次变化是之后才有的新复制，照常立即转移。
        stateLock.lock()
        let passedAt = nativePastePassedAt
        stateLock.unlock()
        if let passedAt, Date().timeIntervalSince(passedAt) < 0.5,
           (pasteboard.lastUnchangedCheckAt ?? .distantPast) <= passedAt {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if NSPasteboard.general.changeCount == changeCount {
                    NSPasteboard.general.forgetLastCheckedChangeCount()
                }
            }
            return
        }
        // 不管这次复制是怎么触发的——Accessibility 读不到时放行的 ⌘C、App 自带的"选中即复制"、
        // 点击 App 里的复制按钮……一律转移到安全剪贴板并清空系统剪贴板，暴露窗口压缩到一次轮询间隔内。
        // 密码管理器的复制（Concealed 标记）同样转移，但到期自动清除，保持它们"定时清除"的语义。
        // 来源：写入的 App 自己声明的（nspasteboard.org 的来源标记），否则当时拿着焦点的 App。清空之前读
        let declaredSource = types.contains(NSPasteboard.PasteboardType("org.nspasteboard.source"))
            ? items.lazy.compactMap({ $0.string(forType: NSPasteboard.PasteboardType("org.nspasteboard.source")) }).first : nil
        TransientPaste.shared.finish()
        pasteboard.markSeen(pasteboard.copiClear())
        guard hasMeaningfulText || !plainText.isEmpty else {
            // 只有一个空字符串（有的工具用写入空串来"清空"剪贴板）：清掉，免得它挡住 ⌘V 粘贴安全剪贴板
            return
        }
        // 机密内容：带 Concealed 标记，或者是在密码管理器里复制的（它可能还没来得及补上标记就被 Copi 转走了）
        let fromPasswordManager = ZeroExposurePolicy.isPasswordManager(focusedApplication()?.bundleIdentifier)
            || ZeroExposurePolicy.isPasswordManager(declaredSource)
        SecureClipboard.shared.setText(plainText, concealed: types.contains(.nspasteboardConcealed) || fromPasswordManager,
                                       source: declaredSource ?? focusedApplication()?.bundleIdentifier)
        // 客户机里刚复制、它的剪贴板共享写到这台 Mac 上的那一份：客户机自己的剪贴板上也是它，在客户机里粘贴照样交给客户机
        if let guest = guestCopy, focusedApplication()?.processIdentifier == guest.pid {
            guestCopy?.secureVersion = SecureClipboard.shared.version
        }
        safeCopyIsNewest = true
        lastSafeCopyAt = nil
        if droppedAttachments {
            notifyCopiNotice("Copi moved the copied text off the system clipboard and left out its images and attachments (they can't be kept without the clipboard). If you cut it, press ⌘Z in the app to get the images back.")
        } else if reprocessing {
            // 开始保护时系统剪贴板上本来就有的文字，不是刚才经过的
            notifyProtected("Moved text that was on the system clipboard into Copi")
        } else if let focused = focusedApplication(), ZeroExposurePolicy.usesNormalClipboard(focused.bundleIdentifier) {
            // 放行的 App 在前台时别的程序写进来的内容（pbcopy、密码管理器、同步工具）
            let name = focused.localizedName ?? "the app in front"
            notifyCopiNotice("Something put text on the system clipboard while \(name) was in front, but not with ⌘C, ⌘X or a click in \(name), so Copi moved it. Only \(name)'s own copies stay on the clipboard.")
        } else if let consented = consentedCopyPassedAt, Date().timeIntervalSince(consented.at) < 2,
                  consented.bundleID == nil || consented.bundleID == focusedApplication()?.bundleIdentifier {
            // 用户确认之后交给 App 自己做的复制
            consentedCopyPassedAt = nil
            notifyCopiNotice("Copied. The text was on the system clipboard for a moment before Copi moved it in.")
        } else if noteNonTextMisjudged(passThrough, types: types, declaredSource: declaredSource) {
            // 刚把这次 ⌘C 当作复制文件、图片放行了，结果是文字：以后在这里拒绝（noteNonTextMisjudged 已经告诉用户）
        } else if ZeroExposurePolicy.isStrict {
            // 按钮里的"拷贝"、选中即复制、别的程序写进来的之类 Copi 拦不住的复制：文字已经在系统剪贴板上停留过，告诉用户
            let front = NSWorkspace.shared.frontmostApplication
            let appName = front?.localizedName ?? "an app"
            notifyCopiNotice("Text copied in \(appName) in a way Copi can't intercept (a button, copy-on-select, another program) was on the system clipboard for a moment before Copi moved it. Copy with ⌘C or the Copy menu item to keep it off."
                + copyOnSelectHint(bundleID: front?.bundleIdentifier))
        } else {
            notifyProtected("Moved a copy off the system clipboard")
        }
    }

    // 刚才当作"不是在复制文字"放行的 ⌘C（文件管理器、图片里），1 秒内复制出来的却是不带图片、文件的文字：判断错了。
    // 记下这个地方（App 和焦点的角色），以后在这里拒绝；返回 true 表示是这种情况（已经告诉用户）
    // 只认得准的情况：放行之后的第一版就是它，用户这期间没有别的操作，前台还是那个 App（写入者声明了自己是谁的话也得是它），
    // 免得把别的程序恰好写进来的文字（密码管理器、选中即复制）算到它头上，让这个地方以后都复制不了文件
    private func noteNonTextMisjudged(_ passThrough: (key: String, at: Date)?, types: Set<NSPasteboard.PasteboardType>,
                                      declaredSource: String?) -> Bool {
        guard let passed = passThrough, Date().timeIntervalSince(passed.at) < 1, !userActedSince(passed.at),
              let bundleID = passed.key.split(separator: "|").first.map(String.init),
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID,
              declaredSource == nil || declaredSource == bundleID else {
            return false
        }
        let nonText = NSPasteboard.PasteboardType.copiAttachmentTypes.union([.fileURL, .pdf, NSPasteboard.PasteboardType("NSFilenamesPboardType")])
        guard types.isDisjoint(with: nonText), !Defaults[.misjudgedNonTextContexts].contains(passed.key) else {
            return false
        }
        Defaults[.misjudgedNonTextContexts].append(passed.key)
        notifyCopiNotice("Copi let that ⌘C through because it looked like copying a file or picture, but it copied text, which was on the system clipboard for a moment before Copi moved it. Copi will refuse ⌘C there from now on.")
        return true
    }

    // 终端的"选中即复制"：告诉用户在哪里关掉
    private func copyOnSelectHint(bundleID: String?) -> String {
        switch bundleID {
        case "com.googlecode.iterm2"?:
            let copySelection = CFPreferencesCopyAppValue("CopySelection" as CFString, "com.googlecode.iterm2" as CFString) as? Bool ?? true
            return copySelection ? " iTerm2 copies every selection: turn off Copy to pasteboard on selection in iTerm2 › Settings › General › Selection." : ""
        case "com.github.wez.wezterm"?:
            return " WezTerm copies every selection by default: change its mouse_bindings so that selecting copies only to PrimarySelection."
        default:
            return ""
        }
    }

    // 主线程：主线程忙的时候，后台线程替它从系统剪贴板上取下来的一次复制（见 PasteboardWatcher），系统剪贴板已经清空。
    // 由 checkForChangesInPasteboard 在处理系统剪贴板上的新内容之前按先后顺序调用（取下来的总比剪贴板上现在的旧）。
    // 后台线程只取一眼就能认出该转移的文字；这里按处理普通复制的规则再确认一遍，照常处理也会留在系统剪贴板上的（期间关掉了保护、
    // 放行的 App 拿到了焦点、刚放行了原生粘贴……）放回去，交给 handleSystemPasteboardChange 按原来的规则处理。
    // 返回 false 表示现在还不能处理（正在借助系统剪贴板复制），稍后再来
    func handleQuarantinedCopy(_ copy: QuarantinedCopy) -> Bool {
        // 正在借助系统剪贴板复制：等它做完，免得放回去的内容被当成它的结果
        guard !ClipboardCapture.shared.isActive else {
            return false
        }
        let pasteboard = NSPasteboard.general
        let focused = focusedApplication()
        let plainText = copy.text.replacingOccurrences(of: "\u{FFFC}", with: "")
        let droppedAttachments = copy.text.contains("\u{FFFC}")
        // （刚放行的原生剪切不用看：取下来的时候一定还没有放行它，这份复制比它早，不是它剪下来的）
        // 放行的 App 在前台：机密内容只有它自己声明的、或者它就是密码管理器时才留给它（见 copiedByNormalClipboardApp）
        let leftForNormalApp = ZeroExposurePolicy.usesNormalClipboard(focused?.bundleIdentifier)
            && (!copy.concealed || copy.source == focused?.bundleIdentifier || ZeroExposurePolicy.isPasswordManager(focused?.bundleIdentifier))
        let stillMoves = Defaults[.isOn] && Defaults[.overrideShortcuts] && isProtecting
            && !ClipboardCapture.shared.hasPendingLateWrite
            && !leftForNormalApp
            && !nativePasteJustPassed
        guard stillMoves else {
            PasteboardQuarantine.shared.restore(copy)
            return true
        }
        NotificationCenter.default.post(name: .copiSystemPasteboardDidChange, object: pasteboard)
        // 剪贴板劫持（见 handleSystemPasteboardChange）：不收
        if let copiedAt = lastSafeCopyAt, copy.at.timeIntervalSince(copiedAt) < 3, !userActedSince(copiedAt) {
            notifyCopiNotice("Copi blocked something another app put on the clipboard right after your copy, and kept what you copied.")
            return true
        }
        // 取下来时系统剪贴板已经清空，那时挂着的粘贴内容也没了，这里只是把它的状态复位。还在剪贴板上的是之后才挂上去的
        // （一次正在进行的 ⌘V），不能撤
        if !TransientPaste.shared.isOnPasteboard {
            TransientPaste.shared.finish()
        }
        // （开着"立即发现剪贴板变化"时，取下来的时候已经占住了剪贴板；这里不再去占：别的 App 可能正清空了剪贴板、还没写完）
        let fromPasswordManager = ZeroExposurePolicy.isPasswordManager(focused?.bundleIdentifier)
            || ZeroExposurePolicy.isPasswordManager(copy.source)
        SecureClipboard.shared.setText(plainText, concealed: copy.concealed || fromPasswordManager, source: copy.source ?? focused?.bundleIdentifier)
        safeCopyIsNewest = true
        lastSafeCopyAt = nil
        if droppedAttachments {
            notifyCopiNotice("Copi moved the copied text off the system clipboard and left out its images and attachments (they can't be kept without the clipboard). If you cut it, press ⌘Z in the app to get the images back.")
        } else if ZeroExposurePolicy.isStrict {
            let appName = focused?.localizedName ?? "an app"
            notifyCopiNotice("Text copied in \(appName) in a way Copi can't intercept (a button, copy-on-select, another program) was on the system clipboard for a moment before Copi moved it. Copy with ⌘C or the Copy menu item to keep it off.")
        } else {
            notifyProtected("Moved a copy off the system clipboard")
        }
        return true
    }

    // 临时文字写进来 3 秒后：写进来之后马上（0.5 秒内）被粘贴的是文本扩展这类工具自己的粘贴，丢掉；没有被马上粘贴、
    // 这期间用户也没有新的复制的，当作一次普通复制收进安全剪贴板
    private func resolvePendingSnippet(arrivedAt: Date) {
        guard let pending = pendingSnippet, pending.at == arrivedAt else {
            return
        }
        pendingSnippet = nil
        if let pastedAt = pending.pastedAt, pastedAt.timeIntervalSince(pending.at) < 0.5 {
            return
        }
        guard SecureClipboard.shared.version == pending.secureVersion else {
            return
        }
        TransientPaste.shared.finish()
        SecureClipboard.shared.setText(pending.text, concealed: pending.concealed)
        safeCopyIsNewest = true
        notifyProtected("Moved a copy off the system clipboard")
    }

    // 纯文本的几种表示形式
    private let textTypes: Set<NSPasteboard.PasteboardType> = [
        .string,
        NSPasteboard.PasteboardType("public.utf16-plain-text"),
        NSPasteboard.PasteboardType("public.utf16-external-plain-text"),
        NSPasteboard.PasteboardType("NSStringPboardType"),
    ]
    private var plainTextTypes: Set<NSPasteboard.PasteboardType> {
        textTypes.union([.nspasteboardConcealed])
    }

    // 系统剪贴板上有没有需要原生粘贴的内容（有的话说明是 Copi 有意留下的，比安全剪贴板里的更新）
    private func systemPasteboardHasContent(_ pasteboard: NSPasteboard) -> Bool {
        let markers: Set<NSPasteboard.PasteboardType> = [.nspasteboardConcealed, .nspasteboardTransient, .nspasteboardAutoGenerated,
                                                         PasteboardOwnership.placeholderType]
        for item in pasteboard.pasteboardItems ?? [] {
            let types = Set(item.types.filter { !$0.isCopiStaged }).subtracting(markers)
            if types.isEmpty {
                continue
            }
            // 只有一个空字符串：不算内容（读不出来的不算空，照样当作有内容）
            if types.isSubset(of: plainTextTypes), let string = item.string(forType: .string), string.isEmpty {
                continue
            }
            return true
        }
        return false
    }

    // MARK: - ⌘C / ⌘V 拦截

    // event tap 线程：硬件层刚（0.25 秒内）记下过一次按键，刚收到的这个按键多半是用户亲手按的（和 hardwareInput 一样）。
    // 只是推测，不看这个事件本身是谁发的：别的程序紧跟在用户自己的按键之后合成的、或者经硬件层（HID）发来的按键也会被当成亲手按的
    //（键位重映射工具、宏工具、Copi 自己的自测程序都这样发）
    private static func pressedOnKeyboard() -> Bool {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown) < 0.25
    }

    // 运行在 event tap 线程上，只负责识别按键；真正的处理在主线程完成
    private func shouldSwallow(_ event: CGEvent) -> Bool {
        stateLock.lock()
        let active = overrideActiveSnapshot
        stateLock.unlock()
        guard active else {
            return false
        }
        if event.type == .flagsChanged {
            // Secure Input 期间 tap 收不到按键，但修饰键的变化照样收得到：⌘ 一按下就去检查要不要注册 ⌘C/⌘V 热键，
            // 不必等下一次轮询
            // ⌘ 刚按下时稍等主线程注册好（最多 25 毫秒）：紧接着按下的 C/V 在 Secure Input 下不会经过 tap，只能靠热键
            let commandDown = event.flags.contains(.maskCommand)
            stateLock.lock()
            let commandJustPressed = commandDown && !commandHeld
            commandHeld = commandDown
            stateLock.unlock()
            if commandDown {
                let registered = DispatchSemaphore(value: 0)
                DispatchQueue.main.async {
                    KeyboardLayout.refreshCache()
                    GlobalMode.shared.secureInputHotKeys.updateNow()
                    registered.signal()
                    // Secure Input 期间 tap 看不到按键（密码管理器里用快捷键复制密码）：⌘ 一按下就加密检查剪贴板
                    if commandJustPressed, IsSecureEventInputEnabled(), GlobalMode.shared.isProtecting {
                        NSPasteboard.general.checkFrequently(for: 1)
                    }
                }
                if commandJustPressed {
                    _ = registered.wait(timeout: .now() + 0.025)
                }
            }
            return false
        }
        // Copi 正在模拟键入时按下的键：先不给 App（回车会把打了一半的消息、命令发出去、执行，别的键会夹进打到一半的文字里），
        // 键入停下；Esc 就是让它停下（见 TypingInterrupt）
        if event.type == .keyDown, event.getIntegerValueField(.eventSourceUserData) != copiSyntheticEventMarker,
           TypingInterrupt.swallowKey(event.getIntegerValueField(.keyboardEventKeycode),
                                      isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0) {
            return true
        }
        // 菜单开着时按回车选了"拷贝/剪切/粘贴"（见 PointerInterceptor.interceptMenuKey）
        if PointerInterceptor.shared.interceptMenuKey(event) {
            return true
        }
        let flags = event.flags
        let keyTime = Date()
        let chord: PasteChord
        if flags.check(is: .maskCommand) {
            let isCopy = event.isLetter("c", ansiKeyCode: kVK_ANSI_C)
            if isCopy || event.isLetter("x", ansiKeyCode: kVK_ANSI_X) {
                // 按住不放的自动重复、硬件层刚才没记下按键时别的程序合成的按键不算用户亲手再复制一次（见 CopyThroughAppConsent、pressedOnKeyboard）
                if event.getIntegerValueField(.keyboardEventAutorepeat) == 0, Self.pressedOnKeyboard() {
                    CopyPress.noteDeliberate(at: keyTime)
                }
                // 等不到主线程就先吞掉 ⌘C/⌘X（之后由主线程决定是复制、拒绝还是原样补发），不能直接放行给 App——那样文字就以普通复制的
                // 身份（没有不记录的标记、会经通用剪贴板同步）进了系统剪贴板；允许剪贴板回退时也一样
                // ⌘X 一律先吞掉：等不到主线程时如果放行，App 自己剪切一次，主线程稍后又删一次选区
                // 作废时按拒绝处理：用户以为复制成功了，接下来的 ⌘V 不能粘贴出更早的内容
                // 这次 ⌘C/⌘X 还没处理完时按下的 ⌘V 也交给主线程，排在它后面（不能先原生粘贴出系统剪贴板上更早的内容）
                stateLock.lock()
                copyDecisionsPending += 1
                stateLock.unlock()
                // 只算一次（处理完之后补发时太晚，还会再调一次 onDropped）
                let once = DecisionOnce()
                let decided = {
                    guard once.claim() else {
                        return
                    }
                    GlobalMode.shared.stateLock.lock()
                    GlobalMode.shared.copyDecisionsPending -= 1
                    GlobalMode.shared.stateLock.unlock()
                }
                return decideOnMainThread(event, timeout: decisionTimeout, swallowOnTimeout: true, onDropped: {
                    decided()
                    GlobalMode.shared.refuseCopy(app: RefusedApp(target: nil), cut: !isCopy, reason: .busy)
                }) { _ in
                    // 处理完之后可能还要补发这次 ⌘C：等主线程这一轮做完（补发也做完）再减
                    defer { DispatchQueue.main.async { decided() } }
                    return GlobalMode.shared.handleCopy(cut: !isCopy, keyTime: keyTime)
                }
            }
            chord = .command
        } else if flags.check(is: [.maskCommand, .maskShift]) {
            // ⇧⌘V、⌥⇧⌘V（"粘贴为纯文本""粘贴并匹配样式"）：之前不拦截，App 读到的是被清空的系统剪贴板
            chord = .shiftCommand
        } else if flags.check(is: [.maskCommand, .maskShift, .maskAlternate]) {
            chord = .optionShiftCommand
        } else {
            InputActivity.noteInput()
            noteShortcutKey(event)
            // ⌥⌘V：文件管理器的"移动到这里"自己读剪贴板上的文件。Copi 里存着不是文字的复制、或者正在把一份复制取下来时交给主线程看一眼
            // （见 handleMoveItemHere；取下来的那一下占着主线程，它排在后面，看到的是存进 Copi 的那一份），等不到就照常放行
            // （别的 App 里它是"粘贴样式"之类，不能因为 Copi 忙就吞掉）。
            // 和 ⌘V 一样，判断和记下"放行了一次原生 ⌥⌘V"一起做：访达复制的文件还没取下来时，它读的是系统剪贴板上的那一份，
            // captureNonText 要等它读完再清（见 beginQuarantine）
            if flags.check(is: [.maskCommand, .maskAlternate]), event.isLetter("v", ansiKeyCode: kVK_ANSI_V) {
                stateLock.lock()
                let route = NonTextClipboard.shared.hasContent || quarantinePending
                if !route, !SecureClipboard.shared.hasText, !hasPendingSnippet {
                    nativePastePassedAt = Date()
                }
                stateLock.unlock()
                if route {
                    let deliberate = event.getIntegerValueField(.keyboardEventAutorepeat) == 0 && Self.pressedOnKeyboard()
                    return decideOnMainThread(event, timeout: decisionTimeout, swallowOnTimeout: false) { isStale in
                        GlobalMode.shared.handleMoveItemHere(keyTime: keyTime, deliberate: deliberate, isStale: isStale)
                    }
                }
            }
            return false
        }
        guard event.isLetter("v", ansiKeyCode: kVK_ANSI_V) else {
            // 打字、改选区、删除、撤销……：浏览器要过一会儿才把新内容、新选区同步到无障碍树，复制/粘贴时据此稍等或换一种方式
            InputActivity.noteInput()
            noteShortcutKey(event)
            return false
        }
        // 安全剪贴板是空的（也没有刚撤下来的临时文字）就没什么要做的，直接放行，不去打扰主线程。
        // 判断和记下"放行了一次原生 ⌘V"要一起做（主线程同时可能正要把一段临时文字撤下来）
        stateLock.lock()
        let route = SecureClipboard.shared.hasText || NonTextClipboard.shared.hasContent || hasPendingSnippet || quarantinePending
            || copyDecisionsPending > 0
        if !route {
            nativePastePassedAt = Date()
        }
        stateLock.unlock()
        guard route else {
            InputActivity.noteInput()
            noteShortcutKey(event)
            return false
        }
        // 按住 ⌘V 不放的自动重复、硬件层刚才没记下按键时别的程序合成的按键不算用户亲手再粘贴一次（见 PasteConfirmation、pressedOnKeyboard）
        if event.getIntegerValueField(.keyboardEventAutorepeat) == 0, Self.pressedOnKeyboard() {
            PastePress.noteDeliberate(at: keyTime)
        }
        return decideOnMainThread(event, timeout: decisionTimeout, swallowOnTimeout: true, onDropped: {
            notifyCopiNotice("Copi was busy and skipped a ⌘V to avoid pasting into the wrong place. Press ⌘V again.")
        }) { isStale in
            GlobalMode.shared.handlePaste(chord: chord, isStale: isStale, keyTime: keyTime)
        }
    }

    // event tap 线程：按了带 ⌘ 或 ⌃ 的组合键、回车——密码管理器、剪贴板工具常用这些键把内容复制进系统剪贴板
    // （例如在密码列表里回车复制密码）。接下来半秒加密检查剪贴板，一写进来就尽快转移走（和点击之后一样）。
    // ⌥（很多键盘布局用它打字）、空格、按住不放的自动重复不算：打字时不必一直高频检查
    private func noteShortcutKey(_ event: CGEvent) {
        guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else {
            return
        }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        // 像是复制、剪切的快捷键：C、X 加 ⌃、⌃⇧ 或 ⇧⌘（⌘C/⌘X 本身由 Copi 处理），⌃Insert，⇧Delete（PC 的剪切，虚拟机、远程桌面里常用）；
        // 回车只在终端、密码管理器里算（复制模式里的回车、列表里按回车复制密码）。别的组合键（⌘S、⌃⌥ 开头的全局热键……）不算，
        // 免得别的程序这时写进来的内容被当成放行 App 的复制
        let flags = event.flags.intersection([.maskCommand, .maskControl, .maskShift, .maskAlternate])
        let isReturn = keyCode == Int64(kVK_Return) || keyCode == Int64(kVK_ANSI_KeypadEnter)
        let copyLike = ((event.isLetter("c", ansiKeyCode: kVK_ANSI_C) || event.isLetter("x", ansiKeyCode: kVK_ANSI_X))
                        && (flags == .maskControl || flags == [.maskControl, .maskShift] || flags == [.maskCommand, .maskShift]))
            || (keyCode == Int64(kVK_Help) && flags.contains(.maskControl))
            || (keyCode == Int64(kVK_ForwardDelete) && flags == .maskShift)
        if copyLike || isReturn {
            DispatchQueue.main.async {
                let bundleID = focusedApplication()?.bundleIdentifier
                if copyLike || (bundleID.map { knownTerminalBundleIDs.contains($0) || ZeroExposurePolicy.isPasswordManager($0) } ?? false) {
                    GlobalMode.shared.lastShortcut = (bundleID, Date())
                }
            }
        }
        guard !event.flags.isDisjoint(with: [.maskCommand, .maskControl]) || isReturn || copyLike else {
            return
        }
        stateLock.lock()
        let now = Date()
        let due = now.timeIntervalSince(lastShortcutCheckAt) > 0.1
        if due {
            lastShortcutCheckAt = now
        }
        stateLock.unlock()
        guard due else {
            return
        }
        DispatchQueue.main.async {
            if GlobalMode.shared.isProtecting {
                NSPasteboard.general.checkFrequently(for: 0.5)
            }
        }
    }


    private enum PasteChord {
        case command
        case shiftCommand
        case optionShiftCommand
    }

    // 拒绝了一次复制：安全剪贴板里更早的内容也作废——用户以为刚才复制成功了，接下来的 ⌘V 不能把更早的（可能是机密的）内容插进去。
    // 为放行的 App 临时挂在系统剪贴板上的内容也撤下
    // offerApp：通知里说明再复制一次就交给 App 自己复制（见 CopyThroughAppConsent）
    func refuseCopy(app: RefusedApp, cut: Bool, reason: CopyRefusal = .unreadable, offerApp: Bool = false) {
        TransientPaste.shared.finish()
        pendingSnippet = nil
        SecureClipboard.shared.setText(nil)
        safeCopyIsNewest = false
        // 确实选中了内容（只是读不出来）时，Override 模式下系统剪贴板上留着的更早内容（放行的 App 里的复制……）也清掉：
        // 否则接下来的 ⌘V 会原样粘贴它，而真正复制成功的话它本来也会被取代。确定什么都没选中时不动它（原生的 ⌘C 这时什么都不做）
        // 放行的 App 里这次 ⌘C 因为 Copi 太忙被丢掉了：它更早的复制也清掉，免得接下来的 ⌘V 粘贴出旧内容
        if reason != .emptySelection, isProtecting, !ZeroExposurePolicy.usesNormalClipboard(app.bundleID) || reason == .busy {
            let pasteboard = NSPasteboard.general
            // 这次处理期间取下来的别的程序的复制比这次复制早：照常处理时也会被这里清掉，一起作废
            PasteboardQuarantine.shared.discardQueued()
            pasteboard.markSeen(pasteboard.copiClear())
        }
        notifyCopyRefused(app: app, cut: cut, reason: reason, offerApp: offerApp)
    }

    // 返回 true 表示吞掉原始的 ⌘C/⌘X。cut：⌘X——读出选中的文字存进安全剪贴板，再按一次退格把它删掉
    func handleCopy(cut: Bool, keyTime: Date) -> Bool {
        // Copi 自己的窗口（设置面板里的 kitty 设置说明）：照常复制（写进来的内容随后照常被转进 Copi）
        guard isOverrideActive, focusedApplication()?.processIdentifier != getpid() else {
            return false
        }
        // 锁屏时（登录窗口里）什么都不做
        if sessionIsLockedNow() {
            return true
        }
        let pasteboard = NSPasteboard.general
        let strict = ZeroExposurePolicy.isStrict
        // 用户放行的 App：原生 ⌘C/⌘X 照常进系统剪贴板，并且留在那里（见 handleSystemPasteboardChange）。
        // 按真正拿着焦点的 App 判断（只问系统，不问目标 App，所以在 awaitingRead 时也可以）
        if let bundleID = focusedApplication()?.bundleIdentifier, ZeroExposurePolicy.usesNormalClipboard(bundleID) {
            normalCopyPassedAt = (bundleID, Date(), nil, nil)
            return false
        }
        // 上一次粘贴挂上去的内容还没被读走：目标 App 可能正卡在读剪贴板上、等我们的主线程提供数据，这时不去问它 Accessibility
        if TransientPaste.shared.awaitingRead {
            guard strict else {
                return passCopyThrough(pasteboard, cut: cut)
            }
            refuseCopy(app: RefusedApp(target: nil), cut: cut, reason: .busy)
            return true
        }
        let attempt = withAXBudget(axBudget) { () -> CopyAttempt in
            guard let target = focusedTarget() else {
                return CopyAttempt(text: nil, target: nil)
            }
            if ZeroExposurePolicy.usesNormalClipboard(target.bundleIdentifier) {
                return CopyAttempt(text: nil, target: target, passThrough: true)
            }
            // VS Code 系编辑器装了 Copi 的桥接扩展：先问清是哪个窗口、焦点在哪里。编辑器里的复制交给扩展（和编辑器自己的复制一样，
            // 包括多光标、复制整行），终端里由扩展读出选中的文字；别的地方照常往下走
            if target.isElectronCodeEditorApp, EditorBridge.shared.isConnected(appPID: target.pid),
               let focus = EditorBridge.shared.locateFocus(appPID: target.pid, timeout: min(0.3, axBudgetRemaining ?? 0.3)) {
                switch focus.place {
                case .editor:
                    return editorBridgeCopyAttempt(focus: focus, target: target, cut: cut)
                case .terminal:
                    if let attempt = editorBridgeTerminalCopyAttempt(focus: focus, target: target) {
                        return attempt
                    }
                case .simpleEditor, .other:
                    break
                }
            }
            // 选了多段（⌘-拖选、多光标）：原生文本视图里一段一段读出来（剪切时一次退格会把每一段都删掉，正好）；
            // 读不全（网页、IDE 的多光标）就不接手——只读第一段会丢掉其余几段，退格却会把它们都删掉
            if target.hasMultipleSelections {
                if let raw = target.multipleSelectionText, target.webEngine(attributeNames: target.attributeNames) == nil, !target.isJavaIDE,
                   let copied = copiedSelection(fromRaw: raw) {
                    // 选段里有图片：只复制文字，不删（退格会把图片也删掉）
                    return CopyAttempt(text: copied.text, target: target,
                                       deletable: cut && target.isEditableTextControl && !copied.droppedAttachments,
                                       droppedAttachments: copied.droppedAttachments)
                }
                return CopyAttempt(text: nil, target: target, passThrough: !strict, multipleSelections: true)
            }
            // Firefox 看不出选了几段：用 ⌘ 添过选区的地方拒绝。允许剪贴板回退时也不交给它（可能只是 ⌘点了一下，本来读得出来）
            if target.mayHaveUnlistedSelections {
                return CopyAttempt(text: nil, target: target, multipleSelections: true)
            }
            // JetBrains：IDE 卡住时读选区会在 1 秒后得到空字符串而不是报错，不能当成"没选中"；没选中时和 IDE 自己的复制一样复制整行
            if target.isJavaIDE {
                let attempt = jetBrainsCopyAttempt(target, cut: cut)
                // 允许剪贴板回退时，删不掉的剪切交给 IDE 自己做（之后从系统剪贴板转移走）
                if cut, !strict, attempt.jetBrainsCutRange == nil {
                    return CopyAttempt(text: nil, target: target, passThrough: true)
                }
                return attempt
            }
            if cut {
                // ⌘X 只在能删掉选中内容的可编辑控件里按退格（看不出有几段选区的 IDE 除外）
                let editable = target.isEditableTextControl && !target.isJavaIDE
                // 选区里有图片：只复制了文字，不删（退格会把图片也删掉）
                let copied = zeroExposureCopySelection(from: target)
                // 不可编辑的地方读不出来、又允许剪贴板回退：交给 App 自己剪切（之后从系统剪贴板转移走）。读得出来时照样只复制、不删：
                // App 自己的剪切在不可编辑的地方往往什么都不做（例如 Safari 的网页正文），交给它用户就什么都没复制上
                if copied == nil, !editable, !strict {
                    return CopyAttempt(text: nil, target: target, passThrough: true)
                }
                return CopyAttempt(text: copied?.text, target: target, deletable: editable && copied?.droppedAttachments != true,
                                   droppedAttachments: copied?.droppedAttachments ?? false)
            }
            let copied = zeroExposureCopySelection(from: target)
            return CopyAttempt(text: copied?.text, target: target, droppedAttachments: copied?.droppedAttachments ?? false)
        }
        guard let text = attempt.text, let target = attempt.target else {
            // 编辑器自己的复制这时也什么都不做（没有选中内容、并且关掉了"空选区复制整行"）
            if attempt.editorCopiedNothing {
                return true
            }
            // 虚拟机、远程桌面的客户机画面：Copi 读不到里面选中的东西，交给客户机用它自己的剪贴板复制（和在客户机里按 Ctrl+C 一样）。
            // 它把剪贴板共享给这台 Mac 时，文字写到系统剪贴板上，照常在几毫秒内转进 Copi
            if let app = focusedApplication(), isRemoteDesktopGuestDisplay(attempt.target, bundleID: app.bundleIdentifier) {
                guestCopy = GuestCopy(pid: app.processIdentifier, secureVersion: SecureClipboard.shared.version)
                return passCopyThrough(pasteboard, cut: cut)
            }
            if attempt.busy {
                guard strict else {
                    return passCopyThrough(pasteboard, cut: cut)
                }
                refuseCopy(app: RefusedApp(target: attempt.target), cut: cut, reason: .busy)
                return true
            }
            if attempt.emptySelection {
                guard strict else {
                    return passCopyThrough(pasteboard, cut: cut)
                }
                refuseCopy(app: RefusedApp(target: attempt.target), cut: cut, reason: .emptySelection)
                return true
            }
            if attempt.passThrough {
                return passCopyThrough(pasteboard, cut: cut)
            }
            if attempt.multipleSelections {
                // 再复制一次就交给 App 自己复制：它自己的复制会带上每一段
                guard CopyThroughAppConsent.isAvailable(cut: cut) else {
                    refuseCopy(app: RefusedApp(target: attempt.target), cut: cut, reason: .multipleSelections)
                    return true
                }
                if CopyThroughAppConsent.needsConfirmation(pid: attempt.target?.pid, element: attempt.target?.element, cut: cut, keyTime: keyTime) {
                    refuseCopy(app: RefusedApp(target: attempt.target), cut: cut, reason: .multipleSelections, offerApp: true)
                    return true
                }
                consentedCopyPassedAt = (attempt.target?.bundleIdentifier, Date())
                return passCopyThrough(pasteboard, cut: cut)
            }
            // 默认（不回退剪贴板）：除非确定不是在复制文字（文件、图片），否则没有不经过系统剪贴板的办法就拒绝——
            // 包括 Accessibility 读不出来、判断不了的情况
            if strict {
                let target = attempt.target
                let (nonText, isSecure, hasSelection): (Bool, Bool, Bool?) = target.map { target in
                    withAXBudget(0.2) { (target.isKnownNonTextContext, target.isSecureTextField, target.hasSelection) }
                } ?? (false, false, nil)
                if nonText {
                    if let bundleID = target?.bundleIdentifier, let role = target?.role {
                        nonTextPassThrough = (FocusedTarget.contextKey(bundleID: bundleID, role: role), Date(), nil)
                    }
                    return passCopyThrough(pasteboard, cut: cut)
                }
                // 密码框本来就不允许复制：静默吞掉。没有选中文字时也拒绝并清掉安全剪贴板：有的 App 这时会复制别的东西
                // （代码编辑器复制整行，KeePassXC 复制选中条目的密码），用户接下来的 ⌘V 不能粘贴出更早的内容
                if isSecure {
                    return true
                }
                // 读不出来（或者看不到选中的文字：有的编辑器这时复制整行，密码管理器复制选中条目的密码）：第一次说明为什么，
                // 8 秒内在同一个地方再复制一次就交给 App 自己复制（文字在系统剪贴板上停几毫秒，随后转进 Copi）。不能复制就等于什么都做不了
                let reason: CopyRefusal = hasSelection == false ? .emptySelection : .unreadable
                // 读不到焦点控件时退回系统报告的焦点 App：确认只算在通知里点名的这个 App 里，换到别的 App 再按一次不算
                let app = RefusedApp(target: target)
                guard CopyThroughAppConsent.isAvailable(cut: cut) else {
                    refuseCopy(app: app, cut: cut, reason: reason)
                    return true
                }
                if CopyThroughAppConsent.needsConfirmation(pid: app.pid, element: target?.element, cut: cut, keyTime: keyTime) {
                    refuseCopy(app: app, cut: cut, reason: reason, offerApp: true)
                    return true
                }
                consentedCopyPassedAt = (app.bundleID, Date())
                return passCopyThrough(pasteboard, cut: cut)
            }
            return passCopyThrough(pasteboard, cut: cut)
        }
        storeSafeCopy(text, metadata: attempt.metadata, source: target.bundleIdentifier)
        if cut, let bridgeCut = attempt.editorBridgeCut {
            cutThroughEditorBridge(bridgeCut, target: target)
        } else if cut, let range = attempt.jetBrainsCutRange {
            jetBrainsCut(target, range: range, text: text)
        } else if cut, attempt.deletable {
            KeystrokeTyper.shared.deleteSelection(in: target, keyTime: keyTime)
        } else if cut, attempt.droppedAttachments {
            notifyCopiNotice("Copi copied only the text: the images in the selection can't be copied without the system clipboard, so it didn't delete the selection either.")
        } else if cut {
            notifyCopiNotice("Copi copied the selection but can't delete it in \(target.applicationName) without the system clipboard. Delete it yourself if you meant to cut it.")
        } else if attempt.droppedAttachments {
            notifyCopiNotice("Copi copied only the text. Images and attachments in the selection can't be copied without the system clipboard.")
        } else {
            notifyProtected("Copied safely")
        }
        return true
    }

    // 存进安全剪贴板：先处理掉更早的剪贴板变化（别让它晚一步把这次复制覆盖），撤下临时挂着的粘贴内容，
    // 清掉系统剪贴板上更旧的内容（⌘V 只在系统剪贴板为空时才粘贴安全剪贴板）
    private func storeSafeCopy(_ text: String, metadata: EditorPasteMetadata? = nil, source: String? = nil) {
        let pasteboard = NSPasteboard.general
        pasteboard.checkForChangesInPasteboard()
        pendingSnippet = nil
        // 在密码管理器里复制的（显示出来的密码、恢复码）：和它们自己的复制一样按机密处理（不显示、90 秒后清除）
        SecureClipboard.shared.setText(text, concealed: ZeroExposurePolicy.isPasswordManager(source ?? focusedApplication()?.bundleIdentifier),
                                       metadata: metadata, source: source)
        TransientPaste.shared.finish()
        pasteboard.markSeen(pasteboard.copiClear())
        noteSafeCopy()
    }

    // 通过桥接扩展复制：扩展读出和编辑器自己的复制一样的内容。剪切分两步：先只读出文字存好，再请扩展用编辑器自己的 cut 删掉
    // （文档、选区在这期间没变过才删），这样删除那一步超时也不会丢东西
    private func editorBridgeCopyAttempt(focus: EditorBridge.Focus, target: FocusedTarget, cut: Bool) -> CopyAttempt {
        // 等回音也算在这次处理的时间预算里（event tap 线程不会一直等主线程）
        let wait = min(0.5, axBudgetRemaining ?? 0.5)
        guard wait >= 0.05 else {
            return CopyAttempt(text: nil, target: target, busy: true)
        }
        switch EditorBridge.shared.request(["cmd": "copy"], to: focus, timeout: wait) {
        case .response(let response) where response["ok"] as? Bool == true:
            guard let text = response["text"] as? String, !text.isEmpty else {
                return CopyAttempt(text: nil, target: target, editorCopiedNothing: true)
            }
            let metadata = EditorPasteMetadata(pasteOnNewLine: response["isFromEmptySelection"] as? Bool ?? false,
                                               multicursorText: response["multicursorText"] as? [String])
            let token = response["token"] as? String
            return CopyAttempt(text: text, target: target, metadata: metadata,
                               editorBridgeCut: cut ? token.map { EditorBridgeCut(focus: focus, token: $0) } : nil)
        case .timedOut:
            return CopyAttempt(text: nil, target: target, busy: true)
        default:
            return CopyAttempt(text: nil, target: target)
        }
    }

    // 编辑器的集成终端：扩展读出终端里选中的文字（编辑器还不支持时返回 nil，照常往下走）
    private func editorBridgeTerminalCopyAttempt(focus: EditorBridge.Focus, target: FocusedTarget) -> CopyAttempt? {
        let wait = min(0.4, axBudgetRemaining ?? 0.4)
        guard wait >= 0.05 else {
            return CopyAttempt(text: nil, target: target, busy: true)
        }
        switch EditorBridge.shared.request(["cmd": "terminalSelection"], to: focus, timeout: wait) {
        case .response(let response) where response["ok"] as? Bool == true:
            guard let text = response["text"] as? String, !text.isEmpty else {
                return CopyAttempt(text: nil, target: target, emptySelection: true)
            }
            return CopyAttempt(text: text, target: target)
        case .timedOut:
            return CopyAttempt(text: nil, target: target, busy: true)
        default:
            return nil
        }
    }

    private func cutThroughEditorBridge(_ bridgeCut: EditorBridgeCut, target: FocusedTarget) {
        switch EditorBridge.shared.request(["cmd": "cut", "token": bridgeCut.token], to: bridgeCut.focus, timeout: 0.5) {
        case .response(let response) where response["ok"] as? Bool == true && response["cut"] as? Bool == true:
            notifyProtected("Cut safely")
        case .timedOut:
            notifyCopiNotice("Copi copied the text, but isn't sure it was deleted from \(target.applicationName). Check before cutting again.")
        default:
            notifyCopiNotice("Copi copied the text but couldn't delete it in \(target.applicationName). Delete it yourself if you meant to cut it.")
        }
    }

    private struct EditorBridgeCut {
        let focus: EditorBridge.Focus
        let token: String
    }

    // JetBrains 的复制：有选中内容就读选中的文字（读出空字符串说明 IDE 卡住了，按读不出来处理）；没有选中内容时读出光标所在的整行
    // （带上换行，粘贴回编辑器时插到当前行上面，和 IDE 自己一样）。剪切只在文件编辑器里删除选中的内容（确认选区没变之后），
    // 整行剪切不删（IDE 的写入是异步的，删除和读出对不上时会删错）
    private func jetBrainsCopyAttempt(_ target: FocusedTarget, cut: Bool) -> CopyAttempt {
        // 密码框：IDE 自己也不允许复制（辅助功能却会给出真正的字符）。开着"支持屏幕阅读器"时读出来的是折叠后看到的文字，不是真正的内容
        guard !target.isSecureTextField, !jetBrainsScreenReaderSupportEnabled(pid: target.pid), let range = target.selectedRange else {
            return CopyAttempt(text: nil, target: target)
        }
        if range.length > 0 {
            // 文件编辑器里剪切：存好之后把选中的内容写成空（见 jetBrainsCut）
            let text = target.selectedText
            let cutRange = cut && text?.isEmpty == false && target.isJetBrainsFileEditor ? range : nil
            return CopyAttempt(text: text, target: target, jetBrainsCutRange: cutRange)
        }
        guard let line = (copyAXAttribute(target.element, kAXInsertionPointLineNumberAttribute) as? NSNumber)?.intValue,
              let lineRange = copyAXParameterizedAttribute(target.element, "AXRangeForLine", NSNumber(value: line)),
              CFGetTypeID(lineRange) == AXValueGetTypeID(),
              let text = copyAXParameterizedAttribute(target.element, "AXStringForRange", lineRange) as? String else {
            return CopyAttempt(text: nil, target: target)
        }
        let lineText = text.hasSuffix("\n") ? text : text + "\n"
        return CopyAttempt(text: lineText, target: target, metadata: EditorPasteMetadata(pasteOnNewLine: true, multicursorText: nil))
    }

    private struct CopyAttempt {
        var text: String?
        var target: FocusedTarget?
        // 编辑器附带的复制信息（整行复制）
        var metadata: EditorPasteMetadata?
        // 剪切时由 VS Code 系编辑器里的桥接扩展删掉复制的内容
        var editorBridgeCut: EditorBridgeCut? = nil
        // 编辑器自己的复制这时也什么都不做
        var editorCopiedNothing = false
        // 编辑器没有及时回应
        var busy = false
        // 确定什么都没选中
        var emptySelection = false
        // 剪切时在 JetBrains 的文件编辑器里删掉的选区
        var jetBrainsCutRange: CFRange? = nil
        // 原样交给 App（用户放行的 App；允许剪贴板回退时 Copi 处理不了的 ⌘X）
        var passThrough = false
        // ⌘X 时选了不止一段
        var multipleSelections = false
        // ⌘X 时可以用退格删掉选中内容
        var deletable = false
        // 选区里夹着图片等附件，只复制了其中的文字
        var droppedAttachments = false
    }

    // 放行真正的 ⌘C/⌘X：App 写进系统剪贴板后由 handleSystemPasteboardChange 转移到安全剪贴板（用户放行的 App 除外），
    // 这段时间加密检查。这次复制要立即转移，不受刚放行过原生 ⌘V 的推迟影响。
    // MARK: - 不是文字的复制

    // 主线程：系统剪贴板上是不是文字的复制（图片、文件……）。等它写完再整个取下来存进 Copi：刚放行给访达、图片的 ⌘C，App 在处理这次
    // 按键时就写完了；别的程序写进来的可能分几次写（先写图片、过一会儿才补上文字，见 lateWriteIsDue），清掉之后它就补不上了，多等一会儿
    private func scheduleNonTextCapture(changeCount: Int) {
        let quick = nonTextPassThrough.map { Date().timeIntervalSince($0.at) < 1 } ?? false
        DispatchQueue.main.asyncAfter(deadline: .now() + (quick ? 0.5 : 3.5)) { [weak self] in
            self?.captureNonText(changeCount: changeCount)
        }
    }

    // 主线程：取下来存进 Copi、从系统剪贴板上清掉。期间剪贴板换了内容、保护停了、读不全（见 copiNonTextSnapshot）就照旧留着
    private func captureNonText(changeCount: Int) {
        let pasteboard = NSPasteboard.general
        guard Defaults[.isOn], Defaults[.overrideShortcuts], isProtecting, pasteboard.changeCount == changeCount else {
            return
        }
        // 锁着屏、切到了别的用户、登录窗口在前台：这时不读，回来之后再取。这一份已经记为检查过，不会再被当成新的复制，
        // 这里放弃的话它就一直以普通复制的形式（没有标记、不只留在本机）留在系统剪贴板上。有了新的复制、保护停了，上面就不再重试
        if sessionIsLockedNow() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.captureNonText(changeCount: changeCount)
            }
            return
        }
        guard !TransientPaste.shared.isActive, !ClipboardCapture.shared.isActive,
              !SecureClipboard.shared.hasText, leftForNormalClipboardApp?.changeCount != changeCount,
              SystemClipboardFeatures.cachedPasteboardAccess == .allowed,
              let items = pasteboard.pasteboardItems, !items.isEmpty else {
            return
        }
        // 这期间补上了文字（还没被转走）：交给文字的处理，不当作图片、文件存。和 handleSystemPasteboardChange 一样只看第一份文字、
        // 不算附件占位符（U+FFFC，例如只选中了文档里的一张图片）：两边判断不一致的话，它就一直留在系统剪贴板上
        let types = Set(items.flatMap { $0.types })
        let text = items.lazy.compactMap { $0.string(forType: .string) }.first ?? ""
        if !types.contains(.fileURL),
           !text.replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            pasteboard.forgetLastCheckedChangeCount()
            return
        }
        // 刚放行了原生 ⌘V（那时 Copi 里还没有它），App 可能正在读：不清，过半秒整个再来一遍
        func retryLater() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.captureNonText(changeCount: changeCount)
            }
        }
        // 在看之前记下时刻：这之前的 ⌘V 下面马上看，之后的（读的那几秒里的）读完再看，中间不漏
        let checkedAt = Date()
        if nativePasteJustPassed {
            retryLater()
            return
        }
        // 源 App 当场生成一张大图可能要一会儿：这期间请看门进程别把 Copi 当成卡死
        UserDefaults.standard.set(changeCount, forKey: Self.readingPasteboardKey)
        CrashWatchdog.pauseHangCheck()
        let snapshot = pasteboard.copiNonTextSnapshot(items)
        CrashWatchdog.resumeHangCheck()
        UserDefaults.standard.removeObject(forKey: Self.readingPasteboardKey)
        guard let snapshot, pasteboard.changeCount == changeCount else {
            return
        }
        // 读的时候放行了原生 ⌘V：App 可能也在等这一份、还没读完（读一张大图可能要好几秒，beginQuarantine 只看最近半秒），过半秒再来
        if nativePastePassed(since: checkedAt) {
            retryLater()
            return
        }
        // 从这里到清掉之前的 ⌘V：判断和"从现在起 ⌘V 交给 Copi"一起做（见 beginQuarantine），之后的 ⌘V 等这里做完，粘贴存进 Copi 的这一份
        guard beginQuarantine() else {
            retryLater()
            return
        }
        defer {
            endQuarantine()
        }
        // 登记时（注册热键要和窗口服务器通信）又有了新的复制：这次不取
        guard pasteboard.changeCount == changeCount else {
            return
        }
        // 客户机的剪贴板共享写过来的（见 handleSystemPasteboardChange）：存进 Copi 之后照样算客户机自己的复制
        let fromGuest = guestCopy?.secureVersion == SecureClipboard.shared.version
        NonTextClipboard.shared.store(snapshot, summary: Self.nonTextSummary(items))
        if fromGuest {
            guestCopy?.secureVersion = SecureClipboard.shared.version
        }
        pasteboard.markSeen(pasteboard.copiClear())
    }

    // 菜单里显示的说明
    private static func nonTextSummary(_ items: [NSPasteboardItem]) -> String {
        let files = items.filter { $0.types.contains(.fileURL) }.count
        if files > 0 {
            return files == 1 ? "A file" : "\(files) files"
        }
        let images = items.filter { item in item.types.contains { NSImage.imageTypes.contains($0.rawValue) } }.count
        if images == items.count {
            return images == 1 ? "An image" : "\(images) images"
        }
        return "Something that isn't text"
    }

    // 主线程：替 App 自己读剪贴板的命令（"从剪贴板新建"）把 Copi 里不是文字的复制放回剪贴板，和粘贴时一样短暂、带标记。
    // time：用户选这一项的时刻；deliberate：是用户亲手选的（见 PointerInterceptor.perform）。返回 false 表示这次只提醒、没有放回去，
    // 不要替用户按下这一项
    func stageNonTextForApp(pid: pid_t, time: Date, deliberate: Bool) -> Bool {
        guard let items = NonTextClipboard.shared.items, !SecureClipboard.shared.hasText,
              !systemPasteboardHasContent(NSPasteboard.general) else {
            return true
        }
        // 和 ⌘V 粘贴它时一样（见 pasteNonText）：有会把本机剪贴板同步出去的 App 在运行时先提醒，8 秒内再选一次这一项（或按 ⌘V）才放上去
        if deliberate {
            PastePress.noteDeliberate(at: time)
        }
        if let reason = remoteClipboardConfirmationBeforeFallback("\u{0}non-text \(NonTextClipboard.shared.version)", targetPID: pid, keyTime: time) {
            notifyPasteRefused(reason, app: RefusedApp(target: nil))
            return false
        }
        TransientPaste.shared.stageItems(items, for: pid)
        return true
    }

    // 主线程：粘贴 Copi 里不是文字的复制。没有不经过剪贴板的办法：按需提供、带不记录的标记、只留在本机，App 读走一会儿就撤下，
    // 然后放行这次 ⌘V。返回 true 表示吞掉这次按键
    private func pasteNonText(chord: PasteChord, isStale: () -> Bool, keyTime: Date) -> Bool {
        guard let items = NonTextClipboard.shared.items else {
            return false
        }
        let focused = focusedApplication()
        if chord != .command, let focused, !shiftPasteIsPaste(in: focused, option: chord == .optionShiftCommand, wait: true) {
            return false
        }
        if isStale() {
            return true
        }
        // 有会把本机剪贴板同步出去的 App 在运行：先提醒
        if let reason = remoteClipboardConfirmationBeforeFallback("\u{0}non-text \(NonTextClipboard.shared.version)",
                                                                  targetPID: focused?.processIdentifier, keyTime: keyTime) {
            notifyPasteRefused(reason, app: RefusedApp(target: nil))
            return true
        }
        TransientPaste.shared.stageItems(items, for: focused?.processIdentifier)
        return false
    }

    // 主线程：⌥⌘V。文件管理器（访达、ForkLift……）里它是"移动到这里"，自己去读剪贴板上的文件：Copi 里存着复制的文件、系统剪贴板空着时，
    // 和 ⌘V 一样先短暂放回去（见 pasteNonText），再放行这次按键，由它把文件移过来。别的 App 里 ⌥⌘V 是"粘贴样式"之类，照常交给 App。
    // keyTime：按下的时刻；deliberate：是亲手按的（再按一次确认提醒时才算数，见 PasteConfirmation）。返回 true 表示吞掉这次按键
    private func handleMoveItemHere(keyTime: Date, deliberate: Bool, isStale: () -> Bool) -> Bool {
        guard isOverrideActive, !sessionIsLockedNow(), let focused = focusedApplication(), focused.processIdentifier != getpid(),
              let bundleID = focused.bundleIdentifier, fileManagerBundleIDs.contains(bundleID) else {
            return false
        }
        if deliberate {
            PastePress.noteDeliberate(at: keyTime)
        }
        // 先处理还没轮询到的剪贴板变化（和 planPaste 一样）：系统剪贴板上有更新的内容就照常让它读那个
        let pasteboard = NSPasteboard.general
        pasteboard.checkForChangesInPasteboard()
        guard NonTextClipboard.shared.hasContent, !SecureClipboard.shared.hasText, !systemPasteboardHasContent(pasteboard) else {
            return false
        }
        return pasteNonText(chord: .command, isStale: isStale, keyTime: keyTime)
    }

    // 主线程：手动模式的 Safe Paste，Copi 里存着的是不是文字的复制（关掉 Override 之前收进来的图片、文件）：手动模式下只有这里粘贴得出来，
    // 和文字一样。和 Override 模式的 ⌘V 一样先短暂放回剪贴板（见 pasteNonText），再替用户按一次 ⌘V。系统剪贴板上有更新的内容时什么都不做
    // （上一次粘贴挂上去、还没撤下的那一份不算：贴进第二个地方、点对了位置再按，照样重新挂上去、再按一次 ⌘V）
    // keyTime：按下 Safe Paste 的时刻（再按一次确认提醒时用，见 PasteConfirmation）
    func safePasteNonText(keyTime: Date) {
        guard !SecureClipboard.shared.hasText, NonTextClipboard.shared.hasContent,
              TransientPaste.shared.isOnPasteboard || !systemPasteboardHasContent(NSPasteboard.general) else {
            return
        }
        // pasteNonText 返回 true：有会把本机剪贴板同步出去的 App 在运行，这次只提醒、没有放回去
        if !pasteNonText(chord: .command, isStale: { false }, keyTime: keyTime) {
            postPasteKeystroke()
        }
    }

    // 主线程：退回剪贴板方式、挂上要粘贴的内容之后，替用户按一次 ⌘V。Secure Input 期间不能让 Copi 自己的 ⌘V 热键接住它（见 SecureInputHotKeys.postPaste）
    func postFallbackPaste() {
        secureInputHotKeys.postPaste()
    }

    private func passCopyThrough(_ pasteboard: NSPasteboard, cut: Bool = false) -> Bool {
        stateLock.lock()
        nativeCutPassedAt = cut ? Date() : nil
        nativePastePassedAt = nil
        stateLock.unlock()
        if isProtecting {
            pasteboard.checkFrequently(for: 0.5)
        }
        return false
    }

    private enum PastePlan {
        // 让原始按键照常到达 App，粘贴系统剪贴板上现有的内容
        case native
        // 粘贴这段安全剪贴板里的文本。concealed：刚写进来、还没收进安全剪贴板的临时文字是不是机密（nil：看安全剪贴板）
        case secureText(String, concealed: Bool? = nil)
        // 粘贴 Copi 里不是文字的复制（图片、文件……，见 NonTextClipboard）
        case nonText
    }

    // 用 ⇧⌘V 呼出历史的剪贴板管理工具在运行
    private func shiftPasteClipboardManagerIsRunning() -> Bool {
        let managers = ["com.wiheads.paste", "com.generalarcade.flycut", "com.clipy-app.Clipy", "com.cleanclip", "com.tapbots.Pastebot"]
        return NSWorkspace.shared.runningApplications.contains { app in
            app.bundleIdentifier.map { id in managers.contains { id.hasPrefix($0) } } ?? false
        }
    }

    // 刚写进来的临时文字（还没收进安全剪贴板）这次没有粘贴出去（被拒绝、要用户确认）：别把它记成"已经被它的工具粘贴过"，
    // 用户确认后再按一次要粘贴的还是它
    private func keepPendingSnippetUnpasted(_ text: String, plannedFromPending: Bool) {
        if plannedFromPending, pendingSnippet?.text == text {
            pendingSnippet?.pastedAt = nil
        }
    }

    private func planPaste() -> PastePlan {
        let pasteboard = NSPasteboard.general
        // 先处理还没轮询到的剪贴板变化（例如文本扩展、剪贴板管理工具刚写入、紧接着就模拟了 ⌘V），保证粘贴最新内容
        pasteboard.checkForChangesInPasteboard()
        // 刚写进来的临时文字（文本扩展的粘贴）：比安全剪贴板里的更新。已经被它的工具马上粘贴过、或者之后又有了新的复制
        // （包括被拒绝的复制、留在系统剪贴板上的文件）的，不再粘贴它
        if var pending = pendingSnippet {
            // Copi 自己为回退挂上去的内容不算
            let superseded = SecureClipboard.shared.version != pending.secureVersion
                || (!TransientPaste.shared.isOnPasteboard && systemPasteboardHasContent(pasteboard))
            let usedByItsTool = pending.pastedAt.map { $0.timeIntervalSince(pending.at) < 0.5 } ?? false
            if superseded || usedByItsTool {
                pendingSnippet = nil
            } else if Date().timeIntervalSince(pending.at) < 3 {
                if pending.pastedAt == nil {
                    pending.pastedAt = Date()
                    pendingSnippet = pending
                }
                return .secureText(pending.text, concealed: pending.concealed)
            }
        }
        guard let text = SecureClipboard.shared.text else {
            // Copi 里是不是文字的复制，系统剪贴板上又没有更新的东西：粘贴它
            if NonTextClipboard.shared.hasContent, !systemPasteboardHasContent(pasteboard) {
                return .nonText
            }
            return .native
        }
        if TransientPaste.shared.isOnPasteboard {
            return .secureText(text)
        }
        TransientPaste.shared.finish()
        // 系统剪贴板上还有内容，只可能是有意留下的（文件、图片、放行的 App 里的复制……），它比安全剪贴板里的更新，照常原生粘贴
        if systemPasteboardHasContent(pasteboard) {
            return .native
        }
        return .secureText(text)
    }

    // 这些 App 里 ⇧⌘V 不是"粘贴为纯文本"（JetBrains 是"从历史粘贴"，会把剪贴板内容记进 IDE 的历史；
    // 终端是"粘贴选中内容"；VS Code 是 Markdown 预览），不要为它把内容挂上剪贴板。⌥⇧⌘V 不受影响（JetBrains 里它正是纯文本粘贴）。
    private let shiftPasteIsNotPasteBundleIDPrefixes = [
        "com.jetbrains.", "com.google.android.studio", "com.apple.Terminal", "com.microsoft.VSCode", "com.vscodium",
    ]

    // 主线程：⇧⌘V（option：⌥⇧⌘V）在这个 App 里要不要由 Copi 接管。App 自己的菜单栏把它当作"粘贴"时接管；不是的话交给 App
    // （别的程序的快捷键、剪贴板管理工具呼出历史），只有浏览器里的 ⇧⌘V（网页里的"无格式粘贴"）在没有用 ⇧⌘V 呼出历史的
    // 剪贴板管理工具在运行时也接管。还没读到它的菜单栏时：wait 为 true 读一下、最多等 80 毫秒；为 false 只开始读，这次当作不接管
    // （按键拦截和 Secure Input 期间的热键用的是同一条规则）
    func shiftPasteIsPaste(in app: NSRunningApplication, option: Bool, wait: Bool) -> Bool {
        let bundleID = app.bundleIdentifier ?? ""
        if !option, shiftPasteIsNotPasteBundleIDPrefixes.contains(where: { bundleID.hasPrefix($0) })
            || isIntelliJPlatformApp(pid: app.processIdentifier, bundleID: bundleID) {
            return false
        }
        var binds = PointerInterceptor.shared.menuBindsShiftPaste(pid: app.processIdentifier, option: option)
        if binds == nil {
            PointerInterceptor.shared.loadLocalizedTitles(pid: app.processIdentifier)
            if wait {
                PointerInterceptor.shared.waitForTitles(pid: app.processIdentifier)
                binds = PointerInterceptor.shared.menuBindsShiftPaste(pid: app.processIdentifier, option: option)
            }
        }
        let browser = browserBundleIDPrefixes.contains { bundleID.hasPrefix($0) }
        return binds == true || (!option && browser && !shiftPasteClipboardManagerIsRunning())
    }

    // 返回 true 表示吞掉原始按键；返回 false 时原始按键照常到达 App——需要时我们已经先把要粘贴的内容挂到了
    // 系统剪贴板上，App 执行的是一次真正的粘贴：按键顺序、焦点、键盘布局、修饰键都和用户按下时一致。
    // isStale 为 true 时这次按键已经拖得太久，吞掉并放弃（见 decideOnMainThread）
    private func handlePaste(chord: PasteChord, isStale: () -> Bool, keyTime: Date) -> Bool {
        let swallow = performPaste(chord: chord, isStale: isStale, keyTime: keyTime)
        if !swallow {
            // 原生 ⌘V 会改动输入框的内容
            InputActivity.noteInput()
        }
        return swallow
    }

    private func performPaste(chord: PasteChord, isStale: () -> Bool, keyTime: Date) -> Bool {
        // Copi 自己的窗口（设置面板、它的文件面板）：照常粘贴
        guard isOverrideActive, focusedApplication()?.processIdentifier != getpid() else {
            return false
        }
        // 锁屏时（登录窗口的密码框）绝不把 Copi 里的文字粘贴、键入进去：吞掉，什么都不做
        if sessionIsLockedNow() {
            return SecureClipboard.shared.hasText
        }
        let plan = planPaste()
        if case .native = plan {
            return false
        }
        // 真正拿着焦点的 App（可能是不激活自身的浮动面板）
        let focused = focusedApplication()
        // 虚拟机、远程桌面的客户机画面里刚复制过（交给了客户机自己），Copi 里也没有更新的复制：客户机自己的剪贴板上就是它，
        // 交给客户机粘贴，不经过这台 Mac 的剪贴板。Copi 里更早的图片、文件也不能挂上去顶替它（存进它们时安全剪贴板的版本也会变）
        if chord == .command, let focused, let guest = guestCopy, guest.pid == focused.processIdentifier,
           guest.secureVersion == SecureClipboard.shared.version,
           withAXBudget(0.2, { isRemoteDesktopGuestDisplay(focusedTarget(), bundleID: focused.bundleIdentifier) }) {
            return false
        }
        if case .nonText = plan {
            return pasteNonText(chord: chord, isStale: isStale, keyTime: keyTime)
        }
        guard case .secureText(let text, let concealed) = plan else {
            return false
        }
        // ⇧⌘V、⌥⇧⌘V：只在它们在这个 App 里是一种"粘贴"时接管（见 shiftPasteIsPaste）
        if chord != .command, let focused, !shiftPasteIsPaste(in: focused, option: chord == .optionShiftCommand, wait: true) {
            return false
        }
        if isStale() {
            return true
        }
        let strict = ZeroExposurePolicy.isStrict
        // 上一次退回剪贴板方式挂上去的这段文字还在（在同一个 App 里连按 ⌘V）：续期后照常放行。续期也是退回剪贴板：有会把本机
        // 剪贴板同步出去的 App 在运行时（可能是挂上去之后才打开的）一样先提醒，并且马上撤下挂着的这一份
        if TransientPaste.shared.isOnPasteboard, TransientPaste.shared.isStaged(text, for: focused?.processIdentifier), !strict {
            // Copi 还在往这个 App 里键入上一次粘贴（或者刚打到一半停下）：续期粘贴进去的文字也会和打了一半的那段混在一起
            if let pid = focused?.processIdentifier, KeystrokeTyper.shared.isTypingOrJustStopped(into: pid, element: nil, keyTime: keyTime) {
                keepPendingSnippetUnpasted(text, plannedFromPending: concealed != nil)
                notifyPasteRefused(.stillTyping, app: RefusedApp(target: nil))
                return true
            }
            if let reason = remoteClipboardConfirmationBeforeFallback(text, targetPID: focused?.processIdentifier, keyTime: keyTime) {
                TransientPaste.shared.finish()
                keepPendingSnippetUnpasted(text, plannedFromPending: concealed != nil)
                notifyPasteRefused(reason, app: RefusedApp(target: nil))
                return true
            }
            TransientPaste.shared.stage(text, restorePrevious: false, for: focused?.processIdentifier)
            return false
        }
        // 0 暴露：直接写进焦点控件或模拟键入，全程不经过系统剪贴板。安全剪贴板里的文字是从别的 App 复制来的，
        // 粘贴进放行的 App 时也一样（放行只让那个 App 自己复制的文字留在系统剪贴板上）
        let normalClipboard = ZeroExposurePolicy.usesNormalClipboard(focused?.bundleIdentifier)
        let (result, app, element) = withAXBudget(axBudget) { () -> (ZeroExposurePasteResult, RefusedApp, AXUIElement?) in
            let target = focusedTarget()
            return (zeroExposurePaste(text, into: target, keyTime: keyTime, concealed: concealed), RefusedApp(target: target), target?.element)
        }
        switch result {
        case .inserted, .typing:
            return true
        case .unavailable(let reason):
            if !reason.allowsClipboardFallback {
                keepPendingSnippetUnpasted(text, plannedFromPending: concealed != nil)
                notifyPasteRefused(reason, app: app, suffix: normalClipboard ? normalClipboardPasteNote : "")
                return true
            }
            // 默认（不允许剪贴板回退）：这里没有不经过剪贴板的办法。第一次说明为什么，8 秒内用户亲手再粘贴一次才经过剪贴板粘贴
            if strict, ClipboardPasteConsent.needsConfirmation(text, targetPID: focused?.processIdentifier, element: element, keyTime: keyTime) {
                keepPendingSnippetUnpasted(text, plannedFromPending: concealed != nil)
                notifyPasteRefused(reason, app: app, suffix: (normalClipboard ? normalClipboardPasteNote : "") + ClipboardPasteConsent.offer(appName: app.name),
                                   prompts: true)
                return true
            }
        }
        if isStale() {
            return true
        }
        // 有会把本机剪贴板同步出去的 App 在运行：先提醒
        if let reason = remoteClipboardConfirmationBeforeFallback(text, targetPID: focused?.processIdentifier, keyTime: keyTime) {
            keepPendingSnippetUnpasted(text, plannedFromPending: concealed != nil)
            notifyPasteRefused(reason, app: app)
            return true
        }
        // 退回加固过的剪贴板方式（按需提供、带不记录标记、只留在本机、读走即撤）
        TransientPaste.shared.stage(text, restorePrevious: false, for: focused?.processIdentifier)
        return false
    }
}

// 只让第一次调用生效（任意线程）
private final class DecisionOnce {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else {
            return false
        }
        claimed = true
        return true
    }
}

// 菜单栏图标、设置面板顶上显示的保护状态（主线程）。只靠通知不够：用户可能关掉了 Copi 的通知
final class ProtectionStatus: ObservableObject {
    static let shared = ProtectionStatus()

    enum State: Equatable {
        case protecting
        // 没有接管 ⌘C/⌘V，只有 Copi 自己的快捷键和 Action Bar 受保护
        case manual
        case off
        // 应该在保护却没能接管：缺辅助功能权限，或者拦截器起不来
        case paused(needsAccessibility: Bool)
        // ⌘C/⌘V 受保护，但 macOS 不让 Copi 读别的 App 写进剪贴板的内容（"从其他 App 粘贴"设成了询问或拒绝），这些复制转不走
        case limited
    }

    @Published private(set) var state: State = .protecting
    // 别的程序调低了保护（见 SettingsGuard）、用户还没看过：菜单栏图标也显示警告，面板顶上写着改了什么。
    // 存在偏好设置里：用户看到之前 Copi 重开了（重启、更新、被结束）也还在
    @Published private(set) var unexplainedChange: String?
    private static let unexplainedKey = "settingsGuardUnexplained"
    // （偏好设置别的程序也能写：读出来时清理、限长，最多 8 条）
    private var unexplainedChanges: [String] = (UserDefaults.standard.stringArray(forKey: ProtectionStatus.unexplainedKey) ?? [])
        .suffix(8).map { noticeSafeSentence($0) }.filter { !$0.isEmpty }

    init() {
        unexplainedChange = Self.describe(unexplainedChanges)
    }

    func noteUnexplainedChange(_ description: String) {
        let description = noticeSafeSentence(description)
        if !unexplainedChanges.contains(description) {
            unexplainedChanges.append(description)
        }
        unexplainedChanges = Array(unexplainedChanges.suffix(8))
        UserDefaults.standard.set(unexplainedChanges, forKey: Self.unexplainedKey)
        unexplainedChange = Self.describe(unexplainedChanges)
    }

    func dismissUnexplainedChange() {
        unexplainedChanges = []
        UserDefaults.standard.removeObject(forKey: Self.unexplainedKey)
        unexplainedChange = nil
    }

    private static func describe(_ changes: [String]) -> String? {
        guard !changes.isEmpty else {
            return nil
        }
        let shown = changes.suffix(4).joined(separator: " ")
        return changes.count > 4 ? "\(shown) (and \(changes.count - 4) earlier)" : shown
    }

    func update(_ newState: State) {
        if newState != state {
            state = newState
        }
    }
}

private final class LockObserver: NSObject {
    @objc func screenDidLock(_ notification: Notification) {
        DispatchQueue.main.async {
            // 清空不等确认（宁可多清一次）
            GlobalMode.clearSecureClipboardIfWanted()
            GlobalMode.shared.confirmLocked()
        }
    }

    @objc func screenDidUnlock(_ notification: Notification) {
        DispatchQueue.main.async {
            GlobalMode.shared.setAway(.locked, false)
        }
    }
}

// 网页密码框、原生密码框获得焦点（或终端开了"安全键盘输入"）时，系统会开启 Secure Event Input：这期间系统不再把
// 键盘事件交给任何 event tap，上面的 ⌘C/⌘V 拦截完全看不到按键；而 Override 模式下系统剪贴板已经被清空，原生 ⌘V
// 只能粘贴出空内容——这就是"网页密码框里粘贴不了"。Carbon 全局热键在 Secure Input 下照常触发，所以这段时间临时
// 注册 ⌘V（有安全内容时）和 ⌘C 热键来接管。⇧⌘V、⌥⇧⌘V 只在 ⌘ 按着、拿着焦点的 App 里它们是一种"粘贴"时注册
// （和 Secure Input 之外接管它们的规则一样，见 GlobalMode.shiftPasteIsPaste），别处（终端的"粘贴选中内容"、JetBrains 的
// "从历史粘贴"……）不注册，按键照常交给 App。
final class SecureInputHotKeys {
    private static let signature: OSType = 0x4350_5356 // "CPSV"

    private final class Slot {
        let id: UInt32
        let letter: Character
        let ansiKeyCode: Int
        // 热键的修饰键（Carbon），补发按键时带的修饰键
        let modifiers: Int
        let flags: CGEventFlags
        // 按下时调用（参数是按键真正按下的时刻）；返回 true 表示松开时要补发这个按键（热键已经把用户的按键吞掉了）
        let onPress: (Date) -> Bool
        var ref: EventHotKeyRef?
        var keyCode: CGKeyCode
        var pressedAt: Date?
        var postOnRelease = false
        // 刚补发过的这段时间里不要重新注册，免得把自己合成的按键当成用户按下的又接一次
        var suppressedUntil = Date.distantPast

        init(id: UInt32, letter: Character, ansiKeyCode: Int, modifiers: Int = cmdKey, flags: CGEventFlags = .maskCommand,
             onPress: @escaping (Date) -> Bool) {
            self.id = id
            self.letter = letter
            self.ansiKeyCode = ansiKeyCode
            self.modifiers = modifiers
            self.flags = flags
            self.keyCode = CGKeyCode(ansiKeyCode)
            self.onPress = onPress
        }
    }

    private let paste: Slot
    private let shiftPaste: Slot
    private let optionShiftPaste: Slot
    private let copy: Slot
    private let cut: Slot
    private var slots: [Slot] { [paste, shiftPaste, optionShiftPaste, copy, cut] }
    private var handlerRef: EventHandlerRef?
    private var timer: Timer?
    private var layoutObserver: NSObjectProtocol?

    // onPastePress 后两个参数：按的是不是 ⇧⌘V、⌥⇧⌘V
    init(onPastePress: @escaping (Date, Bool, Bool) -> Bool, onCopyPress: @escaping (Date) -> Bool, onCutPress: @escaping (Date) -> Bool) {
        paste = Slot(id: 1, letter: "v", ansiKeyCode: kVK_ANSI_V) { onPastePress($0, false, false) }
        shiftPaste = Slot(id: 4, letter: "v", ansiKeyCode: kVK_ANSI_V, modifiers: cmdKey | shiftKey, flags: [.maskCommand, .maskShift]) {
            onPastePress($0, true, false)
        }
        optionShiftPaste = Slot(id: 5, letter: "v", ansiKeyCode: kVK_ANSI_V, modifiers: cmdKey | shiftKey | optionKey,
                                flags: [.maskCommand, .maskShift, .maskAlternate]) { onPastePress($0, true, true) }
        copy = Slot(id: 2, letter: "c", ansiKeyCode: kVK_ANSI_C, onPress: onCopyPress)
        cut = Slot(id: 3, letter: "x", ansiKeyCode: kVK_ANSI_X, onPress: onCutPress)
    }

    func start() {
        guard timer == nil else {
            return
        }
        // 浏览器在焦点切换后才异步开启 Secure Input，没有通知可以订阅，只能轮询（另外 ⌘ 按下时也会立即检查一次）
        let timer = Timer(timeInterval: 0.02, repeats: true) { [weak self] _ in
            self?.updateNow()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        // 切换了键盘布局：⌘V/⌘C 对应的键可能变了，重新注册
        layoutObserver = NotificationCenter.default.addObserver(forName: KeyboardLayout.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else {
                return
            }
            for slot in self.slots where slot.pressedAt == nil && slot.ref != nil {
                if (KeyboardLayout.commandKeyCode(for: slot.letter) ?? CGKeyCode(slot.ansiKeyCode)) != slot.keyCode {
                    self.unregister(slot)
                }
            }
            self.updateNow()
        }
        updateNow()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let layoutObserver {
            NotificationCenter.default.removeObserver(layoutObserver)
        }
        layoutObserver = nil
        for slot in slots {
            slot.pressedAt = nil
            unregister(slot)
        }
    }

    func updateNow() {
        guard timer != nil else {
            return
        }
        let secureInput = IsSecureEventInputEnabled()
        let pasteWanted = secureInput && GlobalMode.shared.hasSomethingToPaste
        update(paste, wanted: pasteWanted)
        update(copy, wanted: secureInput)
        update(cut, wanted: secureInput)
        // ⇧⌘V、⌥⇧⌘V 要看焦点在哪个 App（辅助功能查询）：只在 ⌘ 按着时看（⌘ 一按下 tap 就会让这里马上再检查一次），不必每次轮询都查。
        // ⌘ 按没按着看键盘本身的状态：不依赖 tap，tap 漏掉了 ⌘ 的松开（停用、重建期间）也不会一直当作按着、每次轮询都去查焦点。
        // 注册之后、按下之前焦点换了的，按下时 performPaste 会再按同一条规则看一遍，不是"粘贴"就松开后原样补发
        let commandDown = CGEventSource.flagsState(.hidSystemState).contains(.maskCommand)
        let focused = pasteWanted && commandDown ? focusedApplication() : nil
        update(shiftPaste, wanted: focused.map { GlobalMode.shared.shiftPasteIsPaste(in: $0, option: false, wait: false) } ?? false)
        update(optionShiftPaste, wanted: focused.map { GlobalMode.shared.shiftPasteIsPaste(in: $0, option: true, wait: false) } ?? false)
    }

    private func update(_ slot: Slot, wanted: Bool) {
        if let pressedAt = slot.pressedAt {
            // 等用户松开再说（松开事件要靠热键还注册着才能收到）；太久没松开就当作丢了
            guard Date().timeIntervalSince(pressedAt) > 3 else {
                return
            }
            slot.pressedAt = nil
        }
        if wanted, Date() >= slot.suppressedUntil {
            register(slot)
        } else {
            unregister(slot)
        }
    }

    private func register(_ slot: Slot) {
        guard slot.ref == nil else {
            return
        }
        installHandlerIfNeeded()
        let keyCode = KeyboardLayout.commandKeyCode(for: slot.letter) ?? CGKeyCode(slot.ansiKeyCode)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(keyCode),
                                         UInt32(slot.modifiers),
                                         EventHotKeyID(signature: Self.signature, id: slot.id),
                                         GetEventDispatcherTarget(),
                                         0,
                                         &ref)
        guard status == noErr, let ref else {
            return
        }
        slot.ref = ref
        slot.keyCode = keyCode
    }

    private func unregister(_ slot: Slot) {
        guard let ref = slot.ref else {
            return
        }
        UnregisterEventHotKey(ref)
        slot.ref = nil
    }

    private func slot(withID id: UInt32) -> Slot? {
        slots.first { $0.id == id }
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else {
            return
        }
        let eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, userData -> OSStatus in
            guard let event, let userData else {
                return OSStatus(eventNotHandledErr)
            }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event,
                                           EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID),
                                           nil,
                                           MemoryLayout<EventHotKeyID>.size,
                                           nil,
                                           &hotKeyID)
            // 不是我们的热键（例如手动模式的 ⌥C/⌥V）就交给其他处理器
            let hotKeys = Unmanaged<SecureInputHotKeys>.fromOpaque(userData).takeUnretainedValue()
            guard status == noErr, hotKeyID.signature == SecureInputHotKeys.signature, let slot = hotKeys.slot(withID: hotKeyID.id) else {
                return OSStatus(eventNotHandledErr)
            }
            if GetEventKind(event) == UInt32(kEventHotKeyPressed) {
                // 事件自带按下的时刻（开机以来的秒数）
                let age = max(0, GetCurrentEventTime() - GetEventTime(event))
                hotKeys.handlePress(slot, keyTime: Date(timeIntervalSinceNow: -age))
            } else {
                hotKeys.handleRelease(slot)
            }
            return noErr
        }, eventTypes.count, eventTypes, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
    }

    // 按下时就处理（直接写入、安排模拟键入，或者把要粘贴的内容挂上剪贴板）
    private func handlePress(_ slot: Slot, keyTime: Date) {
        guard slot.pressedAt == nil else {
            return
        }
        slot.pressedAt = Date()
        slot.postOnRelease = slot.onPress(keyTime)
    }

    // 需要时在松开后补发按键。等松开再发，是因为按键还按着的时候合成同一个键可能被系统丢掉。
    private func handleRelease(_ slot: Slot) {
        guard slot.pressedAt != nil else {
            return
        }
        slot.pressedAt = nil
        guard slot.postOnRelease else {
            return
        }
        // 先注销热键，免得合成的按键又被自己接住；合成的按键处理完之后马上重新注册，不留空窗
        unregister(slot)
        slot.suppressedUntil = Date().addingTimeInterval(0.08)
        postKeystroke(keyCode: slot.keyCode, flags: slot.flags)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.updateNow()
        }
    }

    // 主线程：Copi 自己替用户按一次 ⌘V（用户确认之后退回剪贴板方式，见 refuseOrFallBack、safePaste）。⌘V 热键注册着时
    //（Secure Input 期间）合成的按键会被自己接住、当成用户又按了一次（不是亲手按的，确认不了），粘贴永远到不了 App：
    // 和 handleRelease 一样先注销、发完马上重新注册。用户还按着 ⌘V 时等松开再发（按着的时候合成同一个键可能被系统丢掉），
    // 松开时由 handleRelease 照常先注销再补发
    func postPaste() {
        guard paste.ref != nil else {
            postPasteKeystroke()
            return
        }
        if let pressedAt = paste.pressedAt, Date().timeIntervalSince(pressedAt) <= 3 {
            paste.postOnRelease = true
            return
        }
        paste.pressedAt = nil
        unregister(paste)
        paste.suppressedUntil = Date().addingTimeInterval(0.08)
        postKeystroke(keyCode: paste.keyCode, flags: paste.flags)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.updateNow()
        }
    }
}
