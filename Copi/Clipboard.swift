//
//  Clipboard.swift
//  SecureYourClipboard
//
//  Created by lixindong on 2024/3/25.
//

import Foundation
import AppKit
import Defaults

typealias OnNewCopyHook = ([NSPasteboardItem]) -> Void

extension Notification.Name {
    // 系统剪贴板出现了一次不是 Copi 自己造成的变化（所有 onNewCopy 钩子跑完之后发出），
    // 或者 Copi 撤下了临时挂上去的粘贴内容
    static let copiSystemPasteboardDidChange = Notification.Name("CopiSystemPasteboardDidChange")
}

// last checked changeCount
private var kLastCheckedChangeCount = 0
extension NSPasteboard {
    var lastCheckedChangeCount: Int? {
        get {
            // 没检查过时是 -1（和"重新处理"一样）：启动后第一次检查把剪贴板上已有的内容当作新复制处理
            objc_getAssociatedObject(self, &kLastCheckedChangeCount) as? Int ?? -1
        }
        set {
            objc_setAssociatedObject(self, &kLastCheckedChangeCount, newValue, .OBJC_ASSOCIATION_RETAIN)
        }
    }
}
// OnNewCopyHooks
private var kOnNewCopyHooks = 0
extension NSPasteboard {
    var onNewCopyHooks: [OnNewCopyHook] {
        get {
            objc_getAssociatedObject(self, &kOnNewCopyHooks) as? [OnNewCopyHook] ?? []
        }
        set {
            objc_setAssociatedObject(self, &kOnNewCopyHooks, newValue, .OBJC_ASSOCIATION_RETAIN)
        }
    }
}
// 最近一次检查时剪贴板没有变化的时间（据此判断一次变化是不是发生在某个时刻之后）
private var kLastUnchangedCheckAt = 0
extension NSPasteboard {
    var lastUnchangedCheckAt: Date? {
        get {
            objc_getAssociatedObject(self, &kLastUnchangedCheckAt) as? Date
        }
        set {
            objc_setAssociatedObject(self, &kLastUnchangedCheckAt, newValue, .OBJC_ASSOCIATION_RETAIN)
        }
    }
}
// 加密检查的截止时间（见 checkFrequently）
private var kFrequentCheckDeadline = 0
extension NSPasteboard {
    fileprivate var frequentCheckDeadline: Date? {
        get {
            objc_getAssociatedObject(self, &kFrequentCheckDeadline) as? Date
        }
        set {
            objc_setAssociatedObject(self, &kFrequentCheckDeadline, newValue, .OBJC_ASSOCIATION_RETAIN)
        }
    }
}
// 刚看到一个空剪贴板后，短时间内继续复查的截止时间（见 checkForChangesInPasteboard）
private var kEmptyRecheckDeadline = 0
extension NSPasteboard {
    fileprivate var emptyRecheckDeadline: Date? {
        get {
            objc_getAssociatedObject(self, &kEmptyRecheckDeadline) as? Date
        }
        set {
            objc_setAssociatedObject(self, &kEmptyRecheckDeadline, newValue, .OBJC_ASSOCIATION_RETAIN)
        }
    }
}

// 这一版剪贴板看起来还没写完时的复查（见 recheckUntilComplete）
struct PasteboardRecheck {
    let changeCount: Int
    // 当时看到的类型
    var types: Set<String>
    let deadline: Date
    // 当时有文字类型却读不出来：每隔一会儿重读一次（不只是等类型变化）
    var retryRead: Bool
    var lastRetry: Date
    // 到期后最后再处理的那一次已经安排过了
    var finalPass = false
}
// 复查完了还是空的、或者只有图片或标记，Copi 也没有动的那一版（见 lateWriteIsDue）
struct PasteboardLateWatch {
    let changeCount: Int
    // 当时看到的类型
    let types: Set<String>
    var lastCheck: Date
}
private var kPendingRecheck = 0
private var kExhaustedRecheck = 0
private var kLateWatch = 0
extension NSPasteboard {
    // 已经复查完（等过 0.5 秒）的那一版：同一版不再开始新的复查（处理它的路上不止一处会要求复查，不能一轮接一轮）。
    // 之后又多出了类型的除外（见 lateWriteIsDue）
    fileprivate var exhaustedRecheckChangeCount: Int? {
        get {
            objc_getAssociatedObject(self, &kExhaustedRecheck) as? Int
        }
        set {
            objc_setAssociatedObject(self, &kExhaustedRecheck, newValue, .OBJC_ASSOCIATION_RETAIN)
        }
    }

    fileprivate var pendingRecheck: PasteboardRecheck? {
        get {
            objc_getAssociatedObject(self, &kPendingRecheck) as? PasteboardRecheck
        }
        set {
            objc_setAssociatedObject(self, &kPendingRecheck, newValue, .OBJC_ASSOCIATION_RETAIN)
        }
    }

    fileprivate var lateWatch: PasteboardLateWatch? {
        get {
            objc_getAssociatedObject(self, &kLateWatch) as? PasteboardLateWatch
        }
        set {
            objc_setAssociatedObject(self, &kLateWatch, newValue, .OBJC_ASSOCIATION_RETAIN)
        }
    }

    // 主线程，onNewCopy 钩子里调用：这一版（changeCount）看起来还没写完——只看到标记、只看到非文字的类型（写入方往往先清空，
    // 再分几次写，文字可能最后才写）、或者有文字类型却读不出来（只声明了类型还没写数据）。接下来 0.5 秒里继续看：
    // 类型有了变化（补写进了文字），或者 retryRead 时每 50 毫秒，把它当作新复制重新处理。
    // 返回 false 表示这一版已经等过 0.5 秒了（调用方按最终结果处理）；只等类型变化的，之后接着慢慢看（见 lateWriteIsDue）
    func recheckUntilComplete(changeCount: Int, retryRead: Bool) -> Bool {
        if exhaustedRecheckChangeCount == changeCount {
            // 复查完之后又来处理它（最后那次处理走了别的路、开始保护时重新处理……）：还没在慢慢看的，也接着慢慢看
            if !retryRead, lateWatch?.changeCount != changeCount {
                lateWatch = PasteboardLateWatch(changeCount: changeCount, types: Set((self.types ?? []).map(\.rawValue)), lastCheck: Date())
            }
            return false
        }
        let now = Date()
        let types = Set((self.types ?? []).map(\.rawValue))
        if var recheck = pendingRecheck, recheck.changeCount == changeCount {
            guard now < recheck.deadline, !recheck.finalPass else {
                pendingRecheck = nil
                exhaustedRecheckChangeCount = changeCount
                if !retryRead {
                    lateWatch = PasteboardLateWatch(changeCount: changeCount, types: types, lastCheck: now)
                }
                return false
            }
            recheck.types = types
            recheck.retryRead = retryRead
            pendingRecheck = recheck
            return true
        }
        pendingRecheck = PasteboardRecheck(changeCount: changeCount, types: types, deadline: now.addingTimeInterval(0.5),
                                           retryRead: retryRead, lastRetry: now)
        checkFrequently(for: 0.5)
        return true
    }

    // 还没写完的这一版有了变化、该重新处理了（或者等够了、该最后再处理一次）
    fileprivate func recheckIsDue(changeCount: Int) -> Bool {
        guard var recheck = pendingRecheck else {
            return false
        }
        guard recheck.changeCount == changeCount else {
            pendingRecheck = nil
            return false
        }
        let now = Date()
        if now >= recheck.deadline {
            // 到期：最后再处理一次（那一次 recheckUntilComplete 返回 false，按最终结果处理），只此一次。读不出来的一定再处理；
            // 只是等类型变化的，类型变了才再处理（主线程这期间可能一直很忙，没来得及看）
            guard !recheck.finalPass else {
                pendingRecheck = nil
                exhaustedRecheckChangeCount = changeCount
                return false
            }
            let types = Set((types ?? []).map(\.rawValue))
            guard recheck.retryRead || types != recheck.types else {
                pendingRecheck = nil
                exhaustedRecheckChangeCount = changeCount
                lateWatch = PasteboardLateWatch(changeCount: changeCount, types: types, lastCheck: now)
                return false
            }
            recheck.finalPass = true
            recheck.types = types
            pendingRecheck = recheck
            return true
        }
        if recheck.retryRead, now.timeIntervalSince(recheck.lastRetry) >= 0.05 {
            recheck.lastRetry = now
            pendingRecheck = recheck
            return true
        }
        // 类型有了变化：重新处理一次（记下这次的类型，免得每次都算变化）
        let types = Set((types ?? []).map(\.rawValue))
        guard types != recheck.types else {
            return false
        }
        recheck.types = types
        pendingRecheck = recheck
        return true
    }

    // 别的程序清空剪贴板之后，只有它自己还能往这一版里写，写数据又不改变计数：复查完了还是空的、只有图片或标记，Copi 也没有动的
    // 那一版，文字可能很晚才写进来。直到计数变了，每 0.1 秒看一次类型（不读数据），多出了类型就重新处理，又可以复查半秒。
    // 搭平时 20 毫秒的检查，不另开计时器。不在保护时不看（照常处理也不转移）；正在借助系统剪贴板复制时先不看（这次变化会被跳过）
    fileprivate func lateWriteIsDue(changeCount: Int) -> Bool {
        guard var watch = lateWatch else {
            return false
        }
        guard watch.changeCount == changeCount else {
            lateWatch = nil
            return false
        }
        let now = Date()
        guard now.timeIntervalSince(watch.lastCheck) >= 0.1, GlobalMode.shared.isProtecting, !ClipboardCapture.shared.isActive else {
            return false
        }
        watch.lastCheck = now
        // 同一版里类型只会增加（偶尔读不到类型时不算变化）
        let types = Set((types ?? []).map(\.rawValue))
        guard !types.isSubset(of: watch.types) else {
            lateWatch = watch
            return false
        }
        // 只看这一次：还是没写完的，由重新处理时的复查接着看
        lateWatch = nil
        exhaustedRecheckChangeCount = nil
        return true
    }
}

extension NSPasteboard {

    private var timerInterval: TimeInterval { 0.02 }
    private var pasteboard: NSPasteboard { self }

    func onNewCopy(_ hook: @escaping OnNewCopyHook) {
        onNewCopyHooks.append(hook)
    }

    func startListening() {
        let timer = Timer(timeInterval: timerInterval,
                          target: self,
                          selector: #selector(checkForChangesInPasteboard),
                          userInfo: nil,
                          repeats: true)
        // 加到 common modes：菜单、面板处于事件追踪模式时也要继续检测
        RunLoop.main.add(timer, forMode: .common)
    }

    // 接下来一小段时间内加密检查：放行真正的 ⌘C、点击之后调用，App 一写进来就尽快转移走。
    // 同一时间只有一个加密检查的计时器，再次调用只是把截止时间往后推。
    // 打开"持续快速检查"时它一直跑（见 setConstantFastCheck），间隔也更短
    func checkFrequently(for duration: TimeInterval) {
        let deadline = Date().addingTimeInterval(duration)
        if let current = frequentCheckDeadline, current >= deadline {
            return
        }
        let alreadyRunning = frequentCheckDeadline != nil
        frequentCheckDeadline = deadline
        guard !alreadyRunning else {
            return
        }
        let constant = PasteboardQuarantine.shared.constantFastCheck
        let timer = Timer(timeInterval: constant ? 0.003 : 0.004, repeats: true) { [weak self] timer in
            guard let self, let deadline = self.frequentCheckDeadline else {
                timer.invalidate()
                return
            }
            // 也复查"刚清空、还没写进内容""还没写完"的剪贴板（写数据不会再改变计数）
            if self.changeCount != self.lastCheckedChangeCount || self.emptyRecheckDeadline != nil || self.pendingRecheck != nil {
                self.checkForChangesInPasteboard()
            }
            FindPasteboardScrubber.shared.poll()
            let keepGoing = PasteboardQuarantine.shared.constantFastCheck
            // 开关改了：按新的间隔重新开一个
            if keepGoing != constant {
                timer.invalidate()
                self.frequentCheckDeadline = nil
                self.checkFrequently(for: max(0.5, deadline.timeIntervalSinceNow))
                return
            }
            if Date() >= deadline, !keepGoing {
                timer.invalidate()
                self.frequentCheckDeadline = nil
                self.checkForChangesInPasteboard()
            }
        }
        // 允许系统把唤醒合并一点，省电
        timer.tolerance = constant ? 0.001 : 0.002
        RunLoop.main.add(timer, forMode: .common)
    }

    // 把加密检查的截止时间提前到 seconds 秒后（只会提前，不会推后）。"持续快速检查"开着时不管
    func limitFrequentCheck(to seconds: TimeInterval) {
        guard let current = frequentCheckDeadline, !PasteboardQuarantine.shared.constantFastCheck else {
            return
        }
        frequentCheckDeadline = min(current, Date().addingTimeInterval(seconds))
    }

    // Copi 自己写入/清空系统剪贴板之后调用，参数用写入/清空操作返回的 changeCount（不要事后再查一次，
    // 否则别的 App 恰好夹在中间的复制也会被当成已处理）：把这次变化标记为已处理，免得 onNewCopy 钩子
    // 把它当成用户的一次新复制
    func markSeen(_ changeCount: Int) {
        lastCheckedChangeCount = changeCount
        emptyRecheckDeadline = nil
        pendingRecheck = nil
        lateWatch = nil
        // Copi 自己写剪贴板也会带来一次信号：不算到别人的写入头上
        if self == NSPasteboard.general {
            PasteboardChangeSignal.noteCheck(foreignChange: false)
        }
    }

    // 下次检查时把当前内容当作一次新复制重新处理
    func forgetLastCheckedChangeCount() {
        lastCheckedChangeCount = -1
    }

    func copy(_ string: String, updateChangeCount: Bool = false) {
        // 只留在本机，不经"通用剪贴板"同步到用户的其他设备
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        pasteboard.copiExcludeFromHistory()
        pasteboard.setString(string, forType: .string)
        if updateChangeCount {
            lastCheckedChangeCount = pasteboard.changeCount
        }
        checkForChangesInPasteboard()
    }

    func clear() {
        pasteboard.clearContents()
    }

    // Copi 清空系统剪贴板都用它：开着"立即发现剪贴板变化"时清空之后顺手占住它（见 PasteboardOwnership）。
    // 返回清空后的 changeCount（交给 markSeen）
    func copiClear() -> Int {
        PasteboardOwnership.shared.clear(pasteboard)
    }

    @objc
    func checkForChangesInPasteboard() {
        let isGeneral = self == NSPasteboard.general
        if isGeneral {
            // 处理新内容的过程中不再去取剪贴板上的东西（见 PasteboardQuarantine.checkpoint）
            PasteboardQuarantine.shared.suspend()
            // 主线程忙的时候取下来的复制比剪贴板上现在的旧，先处理
            PasteboardQuarantine.shared.drain()
        }
        defer {
            if isGeneral {
                PasteboardQuarantine.shared.resume()
                FindPasteboardScrubber.shared.poll()
            }
        }
        let changeCount = pasteboard.changeCount
        // 看看系统的变化信号是不是可靠：发现了一次自然的变化（不是"重新处理"）时，之前有没有来过信号
        if isGeneral {
            PasteboardChangeSignal.noteCheck(foreignChange: changeCount != lastCheckedChangeCount && lastCheckedChangeCount != -1)
        }
        guard changeCount != lastCheckedChangeCount else {
            lastUnchangedCheckAt = Date()
            // 这一版还没写完（见 recheckUntilComplete）：有了变化就重新处理
            if isGeneral, recheckIsDue(changeCount: changeCount), let pasteboardItems = pasteboard.pasteboardItems {
                notifyNewCopy(pasteboardItems)
                return
            }
            // 复查完之后还慢慢看着的那一版（见 lateWriteIsDue）：补写进了东西就重新处理
            if isGeneral, lateWriteIsDue(changeCount: changeCount), let pasteboardItems = pasteboard.pasteboardItems {
                notifyNewCopy(pasteboardItems)
                return
            }
            // 别的 App 复制时通常先 clearContents（计数就在这一刻变了）再写数据，而写数据本身不会再改变计数。
            // 如果恰好在两步之间检查，看到的是空剪贴板；之后短时间内再复查几次，免得漏掉这次复制。
            guard let deadline = emptyRecheckDeadline else {
                return
            }
            guard Date() < deadline else {
                emptyRecheckDeadline = nil
                // 到期了也最后看一眼：主线程这期间可能一直很忙，没来得及复查，写入方早就写完了
                if let pasteboardItems = pasteboard.pasteboardItems, !pasteboardItems.isEmpty {
                    notifyNewCopy(pasteboardItems)
                } else if isGeneral {
                    // 还是空的：清空它的程序可能更晚才写进来，之后慢慢看着
                    lateWatch = PasteboardLateWatch(changeCount: changeCount, types: [], lastCheck: Date())
                }
                return
            }
            guard let pasteboardItems = pasteboard.pasteboardItems, !pasteboardItems.isEmpty else {
                return
            }
            emptyRecheckDeadline = nil
            notifyNewCopy(pasteboardItems)
            return
        }
        lastCheckedChangeCount = changeCount

        guard let pasteboardItems = pasteboard.pasteboardItems else {
            return
        }
        emptyRecheckDeadline = pasteboardItems.isEmpty ? Date().addingTimeInterval(0.2) : nil
        notifyNewCopy(pasteboardItems)
    }

    private func notifyNewCopy(_ pasteboardItems: [NSPasteboardItem]) {
        onNewCopyHooks.forEach {
            $0(pasteboardItems)
        }
        NotificationCenter.default.post(name: .copiSystemPasteboardDidChange, object: self)
    }
}

// MARK: - 占住系统剪贴板，别人一写就知道

// 系统剪贴板没有"内容变了"的通知，只能轮询（平时每 20 毫秒，点击、组合键之后每 4 毫秒），别的程序自己写进来的内容
// （密码管理器的"复制密码"、网页的复制按钮）在被转走之前会停留这么久。
// 打开"立即发现剪贴板变化"后，Copi 清空剪贴板时不让它真的空着，而是放一个别人认不出的占位项（只留在本机、带 nspasteboard.org
// 的临时/机密标记，剪贴板管理工具不会记录），数据由 Copi 按需提供。别的程序一往剪贴板里写（先清空），剪贴板服务就会告诉 Copi
// 不再需要它提供数据（pasteboardFinishedWithDataProvider），Copi 当场去看新内容，不用等下一次轮询。
// 别的 App 看到的仍是"没有可以粘贴的东西"：占位项不是任何它们认得的类型。
final class PasteboardOwnership: NSObject, NSPasteboardItemDataProvider {
    static let shared = PasteboardOwnership()

    static let placeholderType = NSPasteboard.PasteboardType("com.gokoding.copi.placeholder")

    // 现在占着的那一版剪贴板（changeCount）；没占着时为 nil
    private var ownedChangeCount: Int?

    // 主线程。系统的变化信号（PasteboardChangeSignal）用得上时不用占位项：占位项别的 App 看得见
    private var isEnabled: Bool {
        Defaults[.isOn] && Defaults[.instantClipboardDetection] && GlobalMode.shared.isProtecting && !PasteboardChangeSignal.isHealthy
    }

    // 系统剪贴板上是不是只有 Copi 的占位项（当作空的）
    // 只认不带任何内容的占位项：别的程序给自己的文字也加上占位类型时，它不是占位项（否则它能躲过"复制后紧接着写进来的不收"）
    static func isPlaceholder(_ items: [NSPasteboardItem]) -> Bool {
        !items.isEmpty && items.allSatisfy { item in
            let types = Set(item.types)
            return types.contains(placeholderType) && types.isDisjoint(with: contentTypes)
        }
    }

    private static let contentTypes: Set<NSPasteboard.PasteboardType> = [
        .string, .rtf, .rtfd, .html, .URL, .fileURL, .tiff, .png, .pdf, .tabularText,
        NSPasteboard.PasteboardType("public.utf16-plain-text"), NSPasteboard.PasteboardType("public.utf16-external-plain-text"),
        NSPasteboard.PasteboardType("NSStringPboardType"), NSPasteboard.PasteboardType("com.apple.flat-rtfd"),
        NSPasteboard.PasteboardType("public.url-name"), NSPasteboard.PasteboardType("public.jpeg"),
    ]

    // 主线程：清空系统剪贴板；开着这个功能时占住它。返回清空后的 changeCount
    func clear(_ pasteboard: NSPasteboard) -> Int {
        guard pasteboard == NSPasteboard.general, isEnabled else {
            ownedChangeCount = nil
            return pasteboard.clearContents()
        }
        let changeCount = pasteboard.prepareForNewContents(with: .currentHostOnly)
        // 占位项不要进 Spotlight 的剪贴板历史（不设到期时间：到期后剪贴板服务撤掉它，Copi 就不再占着剪贴板了）
        pasteboard.copiExcludeFromHistory()
        let item = NSPasteboardItem()
        item.setDataProvider(self, forTypes: [Self.placeholderType])
        for marker in [NSPasteboard.PasteboardType.nspasteboardConcealed, .nspasteboardTransient, .nspasteboardAutoGenerated] {
            item.setData(Data(), forType: marker)
        }
        guard pasteboard.writeObjects([item]) else {
            ownedChangeCount = nil
            return changeCount
        }
        ownedChangeCount = changeCount
        return changeCount
    }

    // 主线程：剪贴板空着、或者只有一个不归 Copi 现在管的占位项（文本扩展工具存下又写回的、上次异常退出留下的）时占住它。
    // 只在打开开关、开始保护、看到这种占位项时调用：别的程序刚清空剪贴板、还没写完时不能去抢
    func claimIfEmpty(_ pasteboard: NSPasteboard) {
        guard pasteboard == NSPasteboard.general, isEnabled, ownedChangeCount != pasteboard.changeCount,
              let items = pasteboard.pasteboardItems, items.isEmpty || Self.isPlaceholder(items) else {
            return
        }
        pasteboard.markSeen(clear(pasteboard))
    }

    // 主线程：关掉这个功能、Copi 停止保护或退出时，把占位项撤掉（剪贴板回到真正的空）
    func release(_ pasteboard: NSPasteboard) {
        guard let owned = ownedChangeCount else {
            return
        }
        ownedChangeCount = nil
        if pasteboard.changeCount == owned {
            pasteboard.markSeen(pasteboard.clearContents())
            NotificationCenter.default.post(name: .copiSystemPasteboardDidChange, object: pasteboard)
        }
    }

    // MARK: NSPasteboardItemDataProvider

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        item.setData(Data(), forType: type)
    }

    // 剪贴板不再需要占位项的数据：别的程序清空了剪贴板，马上要写进它的内容。稍等 5 毫秒再看（它往往要分几次写完：先写文字，
    // 再单独补上"机密""临时"标记，太早读会把密码当成普通文字），之后半秒加密检查
    func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {
        DispatchQueue.main.async { [self] in
            let general = NSPasteboard.general
            // Copi 自己又清空、重新占住了：不是别人写的
            guard ownedChangeCount != general.changeCount else {
                return
            }
            ownedChangeCount = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.005) {
                general.checkForChangesInPasteboard()
                general.checkFrequently(for: 0.5)
            }
        }
    }
}

// MARK: - 主线程忙的时候

// 主线程忙的时候替它从系统剪贴板上取下来的一次复制（见 PasteboardQuarantine）。只记文字和两个标记：读别的表示形式（富文本、
// HTML）要源 App 当场生成，可能很慢；万一要放回系统剪贴板（很少见），放回的是纯文字
struct QuarantinedCopy {
    let text: String
    // 带 nspasteboard.org 的机密标记（密码管理器的复制）
    let concealed: Bool
    // nspasteboard.org 的来源标记（写入的 App 自己声明的 bundle ID）
    let source: String?
    let at: Date
}

// 主线程在处理一次 ⌘C/⌘V（等目标 App 回应 Accessibility、等编辑器扩展回音……，最多约 0.45 秒）时，轮询剪贴板的计时器轮不到，
// 别的程序这时写进系统剪贴板的文字要等它忙完才转走。系统剪贴板只能在主线程上读写（NSPasteboard、Pasteboard Manager 都不是
// 线程安全的，在后台线程上清空剪贴板会在 AppKit 里崩溃），所以改为在这些等待的间隙里看一眼（checkpoint，每次 Accessibility
// 查询之后、等待被切成几毫秒一段）：别的程序刚写进来的普通文字当场取下来、清空系统剪贴板，等这次处理做完再交给 GlobalMode
// 按原来的规则处理。只取一眼就能认出该转移的；文件、图片、通用剪贴板同步来的、文本扩展工具的临时内容、Copi 自己挂上去的，
// 以及刚放行原生粘贴/剪切、放行的 App 拿着焦点时，都留给主线程空下来之后照常处理。
// 单独一次 Accessibility 查询卡住时（目标 App 没有响应，最多 0.2 秒）间隙里也看不了
final class PasteboardQuarantine {
    static let shared = PasteboardQuarantine()

    // 以下都只在主线程上用
    // 取下来、还没处理的复制（先后顺序）
    private var queue: [QuarantinedCopy] = []
    // 由 GlobalMode 设置：处理一份取下来的复制，返回 false 表示现在还不能处理（稍后再来）
    var handler: ((QuarantinedCopy) -> Bool)?
    private var lastCheckpointAt = Date.distantPast
    private var suspended = 0
    // 看过、决定不取的那一版剪贴板（主线程空下来之前不再反复读）
    private var examinedChangeCount: Int?
    // 上一次放回系统剪贴板的那一版：同一次处理里更新的一份也要放回时可以覆盖它
    private var restoredChangeCount: Int?
    // "持续快速检查"开着并且正在保护
    private(set) var constantFastCheck = false

    // 留给主线程照常处理的类型
    private let leaveAloneTypes: Set<NSPasteboard.PasteboardType> = [
        .fileURL, .universalClipboardRemote, .nspasteboardTransient, .nspasteboardAutoGenerated,
        NSPasteboard.PasteboardType("NSFilenamesPboardType"),
        NSPasteboard.PasteboardType("NSPromiseContentsPboardType"),
        NSPasteboard.PasteboardType("com.apple.NSFilePromiseItemMetaData"),
        NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url"),
    ]
    private let sourceType = NSPasteboard.PasteboardType("org.nspasteboard.source")

    func setConstantFastCheck(_ on: Bool) {
        guard on != constantFastCheck else {
            return
        }
        constantFastCheck = on
        if on {
            // 加密检查的计时器在这个开关开着时一直跑
            NSPasteboard.general.checkFrequently(for: 0.5)
        }
    }

    func suspend() {
        suspended += 1
    }

    func resume() {
        suspended = max(0, suspended - 1)
    }

    // 主线程正忙的时候（Accessibility 查询之后、等待的间隙）调用：到了该查的时候看一眼系统剪贴板
    func checkpoint() {
        // 系统读别的 App 的剪贴板内容前要问用户时，不在这里读（询问是模态的，会卡住正在处理的 ⌘C/⌘V）
        guard Thread.isMainThread, suspended == 0, SystemClipboardFeatures.cachedPasteboardAccess == .allowed,
              !SystemClipboardFeatures.cachedMayPrompt else {
            return
        }
        let now = Date()
        // 系统刚发来"剪贴板变了"的信号就不等节流
        guard PasteboardChangeSignal.consumeSignal() || now.timeIntervalSince(lastCheckpointAt) >= (constantFastCheck ? 0.003 : 0.004) else {
            return
        }
        lastCheckpointAt = now
        // 下面的判断里也有 Accessibility 查询，不要重入
        suspend()
        defer {
            resume()
            FindPasteboardScrubber.shared.poll()
        }
        let pasteboard = NSPasteboard.general
        let changeCount = pasteboard.changeCount
        guard changeCount != pasteboard.lastCheckedChangeCount, changeCount != examinedChangeCount else {
            return
        }
        // 刚清空、还没写进内容：下次再看
        guard let items = pasteboard.pasteboardItems, !items.isEmpty else {
            return
        }
        examinedChangeCount = changeCount
        // 读数据时可能卡住（提供数据的 App 不响应）：记下这一版，卡死被重开后不再读它（见 GlobalMode.initialize）；
        // 系统可能弹出"从其他 App 粘贴"的询问时请看门进程等一等
        let mayAsk = SystemClipboardFeatures.cachedMayPrompt
        if mayAsk {
            CrashWatchdog.pauseHangCheck()
        }
        UserDefaults.standard.set(changeCount, forKey: GlobalMode.readingPasteboardKey)
        defer {
            if mayAsk {
                CrashWatchdog.resumeHangCheck()
            }
            UserDefaults.standard.removeObject(forKey: GlobalMode.readingPasteboardKey)
        }
        let types = Set(items.flatMap { $0.types })
        guard types.contains(.string), types.isDisjoint(with: leaveAloneTypes), !types.contains(where: { $0.isCopiStaged }),
              !TransientPaste.shared.owns(items), !ClipboardCapture.shared.isActive, !ClipboardCapture.shared.hasPendingLateWrite,
              GlobalMode.shared.mayQuarantineNewCopies,
              let text = items.lazy.compactMap({ $0.string(forType: .string) }).first,
              !text.replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        let source = types.contains(sourceType) ? items.lazy.compactMap({ $0.string(forType: self.sourceType) }).first : nil
        // 读的过程中又有了新的复制：留给主线程照常处理（这一份已经被它取代）。
        // 同时向 GlobalMode 登记"有一份取下来的复制等着处理"（期间按下的 ⌘V 要交给 Copi，不能原生粘贴已经清空的剪贴板）；
        // 刚放行了原生 ⌘V 就不取（App 可能正在读）
        guard pasteboard.changeCount == changeCount, GlobalMode.shared.beginQuarantine() else {
            return
        }
        // 登记时（注册热键要和窗口服务器通信）又有了新的复制：这次不取
        guard pasteboard.changeCount == changeCount else {
            if queue.isEmpty {
                GlobalMode.shared.endQuarantine()
            }
            return
        }
        pasteboard.markSeen(pasteboard.copiClear())
        queue.append(QuarantinedCopy(text: text, concealed: types.contains(.nspasteboardConcealed), source: source, at: now))
        // 忙完马上处理
        DispatchQueue.main.async {
            NSPasteboard.general.checkForChangesInPasteboard()
        }
    }

    // 主线程：按先后顺序处理取下来的复制（checkForChangesInPasteboard 一开始调用）
    func drain() {
        defer {
            if queue.isEmpty {
                GlobalMode.shared.endQuarantine()
            }
        }
        while let copy = queue.first {
            guard handler?(copy) ?? true else {
                return
            }
            queue.removeFirst()
        }
        restoredChangeCount = nil
    }

    // 主线程：拒绝了一次复制、清掉系统剪贴板时，还没处理的取下来的复制一起作废（它们比这次复制早，照常处理时也会被这次清掉）
    func discardQueued() {
        queue.removeAll()
        GlobalMode.shared.endQuarantine()
    }

    // 主线程：按规则这份复制应该留在系统剪贴板上，放回去，交给 checkForChangesInPasteboard 照常处理。
    // 系统剪贴板上已经有了更新的内容时这份作废（同一次处理里先放回的更早的一份除外）
    func restore(_ copy: QuarantinedCopy) {
        let pasteboard = NSPasteboard.general
        let current = pasteboard.pasteboardItems ?? []
        guard current.isEmpty || PasteboardOwnership.isPlaceholder(current) || pasteboard.changeCount == restoredChangeCount else {
            return
        }
        let item = NSPasteboardItem()
        item.setString(copy.text, forType: .string)
        if copy.concealed {
            item.setData(Data(), forType: .nspasteboardConcealed)
        }
        if let source = copy.source {
            item.setString(source, forType: sourceType)
        }
        // 只留在本机：它之前已经被取下来过一次，不再同步到别的设备
        let changeCount = pasteboard.prepareForNewContents(with: .currentHostOnly)
        pasteboard.copiExcludeFromHistory()
        pasteboard.writeObjects([item])
        restoredChangeCount = changeCount
        pasteboard.forgetLastCheckedChangeCount()
    }
}

// MARK: - 瞬时剪贴板粘贴

// Accessibility 写入不可靠的场合（网页输入框、终端、密码框、Electron App……）使用的粘贴方式：
// 把安全剪贴板里的文本以"按需提供"的方式短暂挂到系统剪贴板上，让紧接着到达目标 App 的 ⌘V 读取，
// App 读走之后（或超时）立刻撤下。
//  - 之前是写入后固定 50ms 就恢复，而 Chrome/Electron 这类 App 处理 ⌘V 要经过渲染进程，读剪贴板经常晚于
//    50ms，读到的就是已经恢复（Override 模式下是已清空）的剪贴板——表现为"要按两次才能粘贴出来"。
//    现在由数据提供回调告诉我们 App 什么时候真的读了。
//  - 带上 nspasteboard.org 的 Concealed/Transient/AutoGenerated 标记，剪贴板管理工具不会把它记进历史；
//    并且只留在本机，不经"通用剪贴板"同步到用户的其他设备。
final class TransientPaste: NSObject, NSPasteboardItemDataProvider {
    static let shared = TransientPaste()

    // App 读走之后再留一会儿，给它在同一次粘贴里的后续读取留余量
    private let graceAfterRead: TimeInterval = 0.3
    // 挂上去之后至少留这么久：不遵守 nspasteboard.org 约定的工具抢先读一次时，慢一点的目标 App 也还能读到
    private let minLifetime: TimeInterval = 0.8
    // 一直没有 App 来读时最多挂这么久（目标 App 很忙时，例如 Electron 渲染进程、Java 事件线程卡住，可能要过一会儿才读）；
    // 期间用户切到别的 App 就提前撤下
    fileprivate let maxLifetime: TimeInterval = 3
    // 不是文字的复制（见 stageItems）：读文件、图片的 App 一次粘贴往往读好几种类型、分几次读，每读一次都再留这么久；最多挂这么久
    private let itemsGraceAfterRead: TimeInterval = 1.5
    private let itemsMaxLifetime: TimeInterval = 5

    private(set) var isActive = false
    private var text = ""
    // 挂着的是不是不是文字的复制，以及每一项的数据（按项的对象认）
    private var stagesItems = false
    // 挂着的是用户要给附近的设备粘贴的文字（见 shareWithNearbyDevices）：不只留在本机，读过也不提前撤下
    private(set) var sharesWithNearbyDevices = false
    private let nearbyLifetime: TimeInterval = 60
    private var itemPayloads: [ObjectIdentifier: [NSPasteboard.PasteboardType: Data]] = [:]
    private var stagedType = NSPasteboard.PasteboardType.copiStaged(token: "")
    private var writtenChangeCount = 0
    private var archive: [NSPasteboardItem]?
    private var generation = 0
    private var hasBeenRead = false
    private var stagedAt = Date.distantPast
    // 挂上去时拿着焦点的 App（这次粘贴的目标）
    private var stagedPID: pid_t?
    private var activationObserver: NSObjectProtocol?

    // 挂着但还没有 App 读过：这时目标 App 可能正卡在读剪贴板上、等我们的主线程提供数据，
    // 不要再去对它发 Accessibility 请求（它要等我们，我们又在等它）。
    // 给附近的设备的不算：没有哪个 App 在等着粘贴它（读了也不记下来），这一分钟里照常复制，新的复制会把它撤下
    var awaitingRead: Bool {
        isActive && !hasBeenRead && !sharesWithNearbyDevices
    }

    // 我们挂上去的内容是否还在系统剪贴板上（期间没被别的 App 覆盖）。
    // 除了比较 changeCount，还认 token：按需提供的数据被兑现时 changeCount 是否会变，文档没有说清楚。
    var isOnPasteboard: Bool {
        guard isActive else {
            return false
        }
        let pasteboard = NSPasteboard.general
        return pasteboard.changeCount == writtenChangeCount || (pasteboard.types ?? []).contains(stagedType)
    }

    // 系统剪贴板上这一份是不是我们当前挂着的内容
    func owns(_ items: [NSPasteboardItem]) -> Bool {
        isActive && items.contains { $0.types.contains(stagedType) }
    }

    // 挂着的内容是不是为这个 App 挂的：只有在同一个 App 里连按粘贴才续期，换了 App 就重新判断该怎么粘贴
    func isStaged(for pid: pid_t?) -> Bool {
        isActive && pid != nil && stagedPID == pid
    }

    // 挂着的是不是为这个 App 挂的这段文字。挂着期间 Copi 剪贴板里可能换成了别的文字（别的程序写进来、被取下来的复制）：
    // 那就不是"连按粘贴"，要重新判断该怎么粘贴（先试不经过剪贴板的路线）
    func isStaged(_ text: String, for pid: pid_t?) -> Bool {
        isStaged(for: pid) && self.text == text
    }

    // restorePrevious：撤下时是否放回原来的剪贴板内容（手动模式需要；Override 模式下原来的内容早已过时，直接清空）。
    // pid：这次粘贴的目标 App（拿着键盘焦点的那个，可能是不激活自身的浮动面板）
    func stage(_ text: String, restorePrevious: Bool, for pid: pid_t?) {
        if isOnPasteboard, self.text == text, !hasBeenRead, isStaged(for: pid) {
            // 在同一个 App 里连按 ⌘V，而上一次挂上去的还没人读过：续期即可
            stagedAt = Date()
            scheduleFinish(after: maxLifetime)
            return
        }
        // 已经被读过的话重新挂一份：数据第一次被读取后由剪贴板服务缓存，不会再回调我们，
        // 只有重新挂才能知道这一次 App 什么时候读完，及时撤下
        let previousArchive = isOnPasteboard ? archive : nil
        finish(restoring: false)

        let pasteboard = NSPasteboard.general
        archive = restorePrevious ? (previousArchive ?? pasteboard.copiSnapshot()) : nil
        self.text = text
        stagesItems = false
        itemPayloads = [:]
        sharesWithNearbyDevices = false
        stagedType = .copiStaged(token: UUID().uuidString)
        hasBeenRead = false
        stagedAt = Date()
        stagedPID = pid
        observeActivationIfNeeded()

        let item = NSPasteboardItem()
        item.setDataProvider(self, forTypes: [.string])
        for marker in [NSPasteboard.PasteboardType.nspasteboardConcealed, .nspasteboardTransient, .nspasteboardAutoGenerated] {
            item.setData(Data(), forType: marker)
        }
        item.setData(Data(), forType: stagedType)
        writtenChangeCount = pasteboard.prepareForNewContents(with: .currentHostOnly)
        // 紧接着清空之后：让系统剪贴板服务到期自己撤下（Copi 万一崩溃也不会一直留着），并且不进 Spotlight 的剪贴板历史
        pasteboard.copiSetPrivateLifetime(until: Date().addingTimeInterval(maxLifetime + 2))
        guard pasteboard.writeObjects([item]) else {
            archive = nil
            return
        }
        pasteboard.markSeen(writtenChangeCount)
        isActive = true
        scheduleFinish(after: maxLifetime)
    }

    // 用户在菜单里要让附近的设备（iPhone、iPad、另一台 Mac）通过"通用剪贴板"粘贴这段文字：挂上去一分钟，不带"只留在本机"，
    // 其余和平时一样（按需提供、带剪贴板管理工具不记录的标记、不进 Spotlight 的剪贴板历史）。这期间这台 Mac 上的 App 也读得到
    func shareWithNearbyDevices(_ text: String) {
        finish(restoring: false)
        let pasteboard = NSPasteboard.general
        archive = nil
        self.text = text
        stagesItems = false
        itemPayloads = [:]
        sharesWithNearbyDevices = true
        stagedType = .copiStaged(token: UUID().uuidString)
        hasBeenRead = false
        stagedAt = Date()
        stagedPID = nil
        let item = NSPasteboardItem()
        item.setDataProvider(self, forTypes: [.string])
        for marker in [NSPasteboard.PasteboardType.nspasteboardConcealed, .nspasteboardTransient, .nspasteboardAutoGenerated] {
            item.setData(Data(), forType: marker)
        }
        item.setData(Data(), forType: stagedType)
        writtenChangeCount = pasteboard.prepareForNewContents(with: [])
        pasteboard.copiSetPrivateLifetime(until: Date().addingTimeInterval(nearbyLifetime + 2))
        guard pasteboard.writeObjects([item]) else {
            sharesWithNearbyDevices = false
            return
        }
        pasteboard.markSeen(writtenChangeCount)
        isActive = true
        scheduleFinish(after: nearbyLifetime)
    }

    // 粘贴 Copi 里不是文字的复制（见 NonTextClipboard）：和文字一样按需提供、带不记录的标记、只留在本机，读走一会儿就撤下。
    // pid：这次粘贴的目标 App
    func stageItems(_ items: [NonTextClipboard.Item], for pid: pid_t?) {
        finish(restoring: false)
        let pasteboard = NSPasteboard.general
        archive = nil
        text = ""
        sharesWithNearbyDevices = false
        stagedType = .copiStaged(token: UUID().uuidString)
        hasBeenRead = false
        stagedAt = Date()
        stagedPID = pid
        observeActivationIfNeeded()

        var objects: [NSPasteboardItem] = []
        var payloads: [ObjectIdentifier: [NSPasteboard.PasteboardType: Data]] = [:]
        for (index, entries) in items.enumerated() {
            let item = NSPasteboardItem()
            var payload: [NSPasteboard.PasteboardType: Data] = [:]
            for entry in entries {
                payload[entry.type] = entry.data
            }
            item.setDataProvider(self, forTypes: entries.map { $0.type })
            // 标记和 Copi 自己的类型只放在第一项上：读文件列表的 App 不会多看到几项
            if index == 0 {
                for marker in [NSPasteboard.PasteboardType.nspasteboardConcealed, .nspasteboardTransient, .nspasteboardAutoGenerated] {
                    item.setData(Data(), forType: marker)
                }
                item.setData(Data(), forType: stagedType)
            }
            payloads[ObjectIdentifier(item)] = payload
            objects.append(item)
        }
        guard !objects.isEmpty else {
            return
        }
        stagesItems = true
        itemPayloads = payloads
        writtenChangeCount = pasteboard.prepareForNewContents(with: .currentHostOnly)
        pasteboard.copiSetPrivateLifetime(until: Date().addingTimeInterval(itemsMaxLifetime + 2))
        guard pasteboard.writeObjects(objects) else {
            stagesItems = false
            itemPayloads = [:]
            return
        }
        pasteboard.markSeen(writtenChangeCount)
        isActive = true
        scheduleFinish(after: itemsMaxLifetime)
    }

    // 立即撤下（如果还挂着的话）
    func finish() {
        finish(restoring: true)
    }

    private func finish(restoring: Bool) {
        guard isActive else {
            return
        }
        let stillOnPasteboard = isOnPasteboard
        isActive = false
        generation += 1
        // 期间别的 App 写过剪贴板，就保留人家的新内容
        if stillOnPasteboard {
            let pasteboard = NSPasteboard.general
            if restoring, let archive {
                pasteboard.copiRestore(archive)
            } else {
                pasteboard.markSeen(pasteboard.copiClear())
            }
            NotificationCenter.default.post(name: .copiSystemPasteboardDidChange, object: pasteboard)
        }
        archive = nil
        text = ""
        stagesItems = false
        itemPayloads = [:]
        sharesWithNearbyDevices = false
    }

    fileprivate func scheduleFinish(after delay: TimeInterval) {
        generation += 1
        let scheduledGeneration = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.generation == scheduledGeneration else {
                return
            }
            self.finish()
        }
    }

    // 没人读过就切到了别的 App：缩短剩余的挂载时间。不能立刻撤下——⌘V 已经排在目标 App 的事件队列里，
    // 它被切到后台之后照样会处理，很忙的 App 可能这时才来读。
    private func observeActivationIfNeeded() {
        guard activationObserver == nil else {
            return
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { notification in
            let transientPaste = TransientPaste.shared
            guard transientPaste.awaitingRead, !transientPaste.sharesWithNearbyDevices else {
                return
            }
            let activated = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if activated?.processIdentifier == transientPaste.stagedPID {
                return
            }
            let remaining = transientPaste.maxLifetime - Date().timeIntervalSince(transientPaste.stagedAt)
            if remaining > 1 {
                transientPaste.scheduleFinish(after: 1)
            }
        }
    }

    // MARK: NSPasteboardItemDataProvider

    // 有 App 真正读取文本时由系统在主线程回调；同一份数据提供一次之后由剪贴板服务缓存，不会再来问
    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        if isActive, stagesItems {
            guard let data = itemPayloads[ObjectIdentifier(item)]?[type] else {
                return
            }
            item.setData(data, forType: type)
            hasBeenRead = true
            scheduleFinish(after: max(itemsGraceAfterRead, minLifetime - Date().timeIntervalSince(stagedAt)))
            return
        }
        guard isActive, type == .string else {
            return
        }
        item.setString(text, forType: .string)
        // 给附近的设备的：一分钟里谁来读都给，不提前撤下、不提示
        if sharesWithNearbyDevices {
            return
        }
        if !hasBeenRead {
            hasBeenRead = true
            // 借助系统剪贴板粘贴的不说"安全"（和 didSafeCopy 里借助剪贴板的复制一样）
            notifyProtected(ZeroExposurePolicy.isStrict
                ? "Pasted through the system clipboard as you confirmed, so other apps could read it for a moment"
                : "Pasted through the system clipboard (Allow Clipboard Fallback is on), so other apps could read it for a moment")
        }
        scheduleFinish(after: max(graceAfterRead, minLifetime - Date().timeIntervalSince(stagedAt)))
    }
}

// MARK: - 借助系统剪贴板复制

// 手动模式（⌥C 快捷键、Action Bar）下，Accessibility 读不到选中文字时（网页内容、Electron App 等）的回退：
// 模拟一次真正的 ⌘C 让目标 App 自己把内容写进系统剪贴板，拿到文本后立刻放回原来的剪贴板内容。
final class ClipboardCapture {
    static let shared = ClipboardCapture()

    private let pollInterval: TimeInterval = 0.01
    private let timeout: TimeInterval = 1.0
    // 超时之后 App 才写进来（渲染进程很忙、远程桌面同步慢……）时，还认这么久
    private let lateWriteWindow: TimeInterval = 3

    // 拿到的文本，以及它是否带 Concealed 标记（密码管理器的复制）
    typealias Completion = (_ text: String, _ concealed: Bool) -> Void

    // 进行中时 onNewCopy 钩子不要插手这次剪贴板变化
    private(set) var isActive = false
    private var lateWrite: (deadline: Date, pid: pid_t?, archive: [NSPasteboardItem]?, completion: Completion)?
    // 每次开始或取消都加一：取消之后还在跑的轮询据此放弃
    private var generation = 0

    func captureCopy(completion: @escaping Completion) {
        guard !isActive, !sessionIsLockedNow() else {
            return
        }
        TransientPaste.shared.finish()
        lateWrite = nil
        isActive = true
        generation += 1
        let pasteboard = NSPasteboard.general
        let archive = pasteboard.copiSnapshot()
        let startChangeCount = pasteboard.changeCount
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        postCopyKeystroke()
        poll(startChangeCount: startChangeCount, pid: pid, archive: archive, deadline: Date().addingTimeInterval(timeout),
             generation: generation, completion: completion)
    }

    // 放弃进行中的复制（锁屏时）：之后才到的复制不再收进安全剪贴板，但照样放回原来的剪贴板内容（不能让它留在系统剪贴板上）。
    // 还在轮询的那次保持 isActive，直到 poll 发现已取消并放回为止，免得 App 这时写进来的内容被当成普通复制处理
    func cancel() {
        generation += 1
        lateWrite?.completion = { _, _ in }
    }

    var hasPendingLateWrite: Bool {
        guard let lateWrite else {
            return false
        }
        return Date() < lateWrite.deadline
    }

    // 由 onNewCopy 钩子在处理一次普通的文本复制之前调用：如果这是一次超时后才到的复制（还是同一个 App），
    // 就当作那次安全复制的结果收下，并放回原来的剪贴板内容
    func handleLateWrite(_ pasteboard: NSPasteboard, text: String) -> Bool {
        guard let lateWrite else {
            return false
        }
        guard Date() < lateWrite.deadline else {
            self.lateWrite = nil
            return false
        }
        guard lateWrite.pid == nil || lateWrite.pid == NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            return false
        }
        self.lateWrite = nil
        return deliver(text, from: pasteboard, archive: lateWrite.archive, completion: lateWrite.completion)
    }

    // 收下 App 复制出来的内容，放回原来的剪贴板内容。返回 false 表示没有收下、App 的复制原样留在系统剪贴板上。
    @discardableResult
    private func deliver(_ text: String, from pasteboard: NSPasteboard, archive: [NSPasteboardItem]?, completion: Completion) -> Bool {
        let types = Set(pasteboard.types ?? [])
        // 只有图片等附件、没有文字：Copi 保管不了。Override 模式下把 App 的复制原样留在系统剪贴板上（由 onNewCopy 钩子
        // 按"不是文字的内容"处理）；手动模式下放回原来的内容。图文混合的照常收下文字（didSafeCopy 去掉占位符并提示）
        let attachmentsOnly = text.contains("\u{FFFC}")
            && text.replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if attachmentsOnly, !types.isDisjoint(with: NSPasteboard.PasteboardType.copiAttachmentTypes) {
            if GlobalMode.shared.isProtecting {
                return false
            }
            pasteboard.copiRestore(archive)
            return true
        }
        pasteboard.copiRestore(archive)
        completion(text, types.contains(.nspasteboardConcealed))
        return true
    }

    private func poll(startChangeCount: Int, pid: pid_t?, archive: [NSPasteboardItem]?, deadline: Date, generation: Int, completion: @escaping Completion) {
        guard generation == self.generation else {
            // 取消了：把系统剪贴板放回原来的内容
            isActive = false
            NSPasteboard.general.copiRestore(archive)
            return
        }
        let pasteboard = NSPasteboard.general
        let changed = pasteboard.changeCount != startChangeCount
        // App 往往先清空再写数据，变了但还读不到文本时继续等到超时
        // 只写了富文本、网页内容的 App：从里面取出文字
        let text = changed ? pasteboard.string(forType: .string) ?? copiTextFromRichContent(pasteboard.pasteboardItems ?? []) : nil
        if text != nil || Date() >= deadline {
            isActive = false
            if let text, !text.isEmpty {
                // 没有收下（留在系统剪贴板上）：这次变化可能已经在复制进行中被轮询看过、跳过了，让 onNewCopy 钩子重新处理
                if !deliver(text, from: pasteboard, archive: archive, completion: completion) {
                    pasteboard.forgetLastCheckedChangeCount()
                }
            } else if changed {
                pasteboard.copiRestore(archive)
            } else {
                lateWrite = (Date().addingTimeInterval(lateWriteWindow), pid, archive, completion)
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval) { [weak self] in
            self?.poll(startChangeCount: startChangeCount, pid: pid, archive: archive, deadline: deadline, generation: generation, completion: completion)
        }
    }
}

// MARK: - 查找剪贴板

// ⌘E（"用所选内容查找"）、各 App 的查找栏会把要找的文字放进系统的"查找剪贴板"，好让别的 App 用 ⌘G 接着找。
// 它和系统剪贴板一样任何程序都能读，而且一直留着（直到下一次查找）。Copi 保护期间跟着系统剪贴板的检查一起看它（平时每 20 毫秒，
// 按了组合键、点击之后、主线程忙的间隙里最多每 10 毫秒），里面有文字时，稍等 50 毫秒（写入的 App 自己马上要用的话）就清掉。
// 写入的 App 自己的查找不受影响（它们记着自己的查找文字）；代价是别的 App 不能再用 ⌘G 接着找同一个词
final class FindPasteboardScrubber {
    static let shared = FindPasteboardScrubber()

    // 查找剪贴板；Ghostty 的"选中即复制"（默认开着）在 macOS 上把每次选中的文字放进它自己的一个命名剪贴板（模拟 X11 的选区，
    // 给鼠标中键粘贴用），Emacs 也有类似的，任何程序按名字都能读：一样清掉，只是多留一会儿给中键粘贴
    private let scrubbers = [
        NamedPasteboardScrubber(name: .find, grace: 0.05, pollInterval: 0.01),
        NamedPasteboardScrubber(name: NSPasteboard.Name("com.mitchellh.ghostty.selection"), grace: 10, pollInterval: 0.1),
        // GNU Emacs（NS 版：emacs-plus、Emacs for Mac OS X）把每次选中的区域写进 "Selection"（PRIMARY），⌘C 还会写 "Secondary"。
        // 和 Ghostty 一样留 10 秒（鼠标中键粘贴、M-mouse-2 在这期间照常可用；选区还在时 Emacs 每个命令都重写，从最后一次算起）
        NamedPasteboardScrubber(name: NSPasteboard.Name("Selection"), grace: 10, pollInterval: 0.1),
        NamedPasteboardScrubber(name: NSPasteboard.Name("Secondary"), grace: 10, pollInterval: 0.1),
    ]

    func start() {
        scrubbers.forEach { $0.start() }
    }

    func stop() {
        scrubbers.forEach { $0.stop() }
    }

    func poll() {
        scrubbers.forEach { $0.poll() }
    }
}

final class NamedPasteboardScrubber {
    private let name: NSPasteboard.Name
    // 写进来之后留给写入的 App 的时间
    private let grace: TimeInterval
    // 最多多久看一次
    private let pollInterval: TimeInterval

    init(name: NSPasteboard.Name, grace: TimeInterval, pollInterval: TimeInterval) {
        self.name = name
        self.grace = grace
        self.pollInterval = pollInterval
    }

    // 以下都只在主线程上用
    private var isActive = false
    private var lastChangeCount: Int?
    private var recheckUntil: Date?
    // 这一版是开始之后别的程序写的（不是开始时就有的）：半秒之后也接着看（见 check）
    private var watchesLate = false
    private var lastLateCheck = Date.distantPast
    private var pending: DispatchWorkItem?
    private var lastPoll = Date.distantPast

    private let textTypes: Set<NSPasteboard.PasteboardType> = [
        .string, .rtf, .rtfd, .html,
        NSPasteboard.PasteboardType("public.utf16-plain-text"),
        NSPasteboard.PasteboardType("com.apple.flat-rtfd"),
        NSPasteboard.PasteboardType("NSStringPboardType"),
    ]

    func start() {
        guard !isActive else {
            return
        }
        isActive = true
        // 开始时就有的内容（以前留下的）也清掉
        lastChangeCount = nil
        recheckUntil = nil
        check()
    }

    func stop() {
        isActive = false
        pending?.cancel()
        pending = nil
    }

    // 系统剪贴板的每次检查、加密检查、主线程忙的间隙里调用（最多每 pollInterval 看一次）
    func poll() {
        guard isActive, Date().timeIntervalSince(lastPoll) >= pollInterval else {
            return
        }
        check()
    }

    private func check() {
        lastPoll = Date()
        let pasteboard = NSPasteboard(name: name)
        let changeCount = pasteboard.changeCount
        if changeCount == lastChangeCount {
            // 刚清空、还没写进文字的那一版（写数据不会再改变计数）：半秒内再看几次。别的程序写的那一版只有它自己还能往里写，
            // 文字可能更晚才写进来：之后每 0.1 秒看一次类型，直到计数变了
            guard let until = recheckUntil else {
                return
            }
            if Date() >= until {
                guard watchesLate else {
                    recheckUntil = nil
                    return
                }
                guard Date().timeIntervalSince(lastLateCheck) >= 0.1 else {
                    return
                }
                lastLateCheck = Date()
            }
        } else {
            watchesLate = lastChangeCount != nil
            lastChangeCount = changeCount
            recheckUntil = Date().addingTimeInterval(0.5)
        }
        guard !Set(pasteboard.types ?? []).isDisjoint(with: textTypes) else {
            return
        }
        recheckUntil = nil
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isActive, pasteboard.changeCount == changeCount else {
                return
            }
            self.lastChangeCount = pasteboard.clearContents()
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + grace, execute: work)
    }
}

// MARK: - 拖放剪贴板

// 拖动选中的文字时，文字被放进系统的"拖放剪贴板"，放下之后仍一直留在那里（直到下一次拖放），任何进程都能读。
// 拖动的过程中它必须在那里（放下的地方要读），鼠标松开（拖放结束）半秒之后清掉——带链接、图片、富文本的也清
// （放下时目标 App 已经读完了）。只有文件和文件承诺（例如把邮件附件拖到 Finder，放下之后才去生成文件）不动。
final class DragPasteboardScrubber {
    static let shared = DragPasteboardScrubber()

    private var lastChangeCount: Int?
    private var pending: DispatchWorkItem?
    // 带着文件承诺的拖动：过一会儿再清（见 scrub）
    private var delayed: DispatchWorkItem?

    // 不能马上清掉的类型：拖的是文件，或者放下之后目标 App 还要回头来要文件内容（文件承诺）
    private let keepTypes: Set<NSPasteboard.PasteboardType> = [
        .fileURL,
        NSPasteboard.PasteboardType("NSFilenamesPboardType"),
        NSPasteboard.PasteboardType("NSPromiseContentsPboardType"),
        NSPasteboard.PasteboardType("com.apple.NSFilePromiseItemMetaData"),
        NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url"),
        NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-content-type"),
        NSPasteboard.PasteboardType("com.apple.pasteboard.promised-suggested-file-name"),
    ]

    // 含有文字的类型（纯文本、富文本、HTML、网页存档）
    private let textBearingTypes: Set<NSPasteboard.PasteboardType> = [
        .string, .rtf, .rtfd, .html, .URL,
        NSPasteboard.PasteboardType("public.utf16-plain-text"),
        NSPasteboard.PasteboardType("public.utf16-external-plain-text"),
        NSPasteboard.PasteboardType("com.apple.flat-rtfd"),
        NSPasteboard.PasteboardType("Apple Web Archive pasteboard type"),
        NSPasteboard.PasteboardType("com.apple.webarchive"),
    ]

    // 主线程：鼠标左键松开时调用
    func mouseUp() {
        guard Defaults[.isOn] else {
            return
        }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.scrub()
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func scrub() {
        pending = nil
        // 又开始拖了：等这次松开
        guard NSEvent.pressedMouseButtons == 0 else {
            return
        }
        let pasteboard = NSPasteboard(name: .drag)
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else {
            return
        }
        lastChangeCount = changeCount
        let types = Set(pasteboard.types ?? [])
        guard !types.isDisjoint(with: textBearingTypes) else {
            return
        }
        guard types.isDisjoint(with: keepTypes) else {
            // 拖的是文件（文件名也算文字）：不动。带着正文的（邮件、笔记、联系人拖出来的，往往同时有整段文字和文件承诺）：
            // 放下之后对方可能还要回头来要文件（源 App 写文件可能很慢），30 秒后再清
            let richTypes = textBearingTypes.subtracting([.string, .URL, NSPasteboard.PasteboardType("public.utf16-plain-text"),
                                                          NSPasteboard.PasteboardType("public.utf16-external-plain-text")])
            let promiseTypes = keepTypes.subtracting([.fileURL, NSPasteboard.PasteboardType("NSFilenamesPboardType")])
            guard !types.isDisjoint(with: richTypes) || !types.isDisjoint(with: promiseTypes) else {
                return
            }
            delayed?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.scrubLater(changeCount)
            }
            delayed = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
            return
        }
        lastChangeCount = pasteboard.clearContents()
    }

    private func scrubLater(_ changeCount: Int) {
        delayed = nil
        let pasteboard = NSPasteboard(name: .drag)
        // 之后又拖过别的东西：那一次自己处理
        guard pasteboard.changeCount == changeCount else {
            return
        }
        // 正在拖：等一会儿再看
        guard NSEvent.pressedMouseButtons == 0 else {
            let work = DispatchWorkItem { [weak self] in
                self?.scrubLater(changeCount)
            }
            delayed = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
            return
        }
        lastChangeCount = pasteboard.clearContents()
    }
}
