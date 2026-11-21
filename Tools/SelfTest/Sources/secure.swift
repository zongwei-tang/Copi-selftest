// Secure Input 开着时的复制粘贴。测试程序自己打开 Secure Input（和网页密码框、终端的"安全键盘输入"开着时一样）：
// 这时 macOS 不把按键交给 Copi 的按键拦截（tap），⌘C、⌘V 改由热键接住，硬件层的按键记录里也没有这些按键。
// Copi 认"再按一次"是不是亲手按的、键入时用户按了什么、复制之后用户有没有操作，都要另找依据。

import AppKit
import ApplicationServices
import Carbon
import IOKit.pwr_mgt

// 排在会话层最后、什么都不拦的 tap：数某个键（默认 F18）的按下和修饰键变化（Secure Input 开着时会话层的 tap 还收得到什么）
private let secureProbeLock = NSLock()
private var secureProbeKeys = 0
private var secureProbeFlags = 0
private var secureProbeKeyCode = Int64(kVK_F18)

private func secureProbeCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    secureProbeLock.lock()
    if type == .keyDown, event.getIntegerValueField(.keyboardEventKeycode) == secureProbeKeyCode {
        secureProbeKeys += 1
    } else if type == .flagsChanged {
        secureProbeFlags += 1
    }
    secureProbeLock.unlock()
    return Unmanaged.passUnretained(event)
}

private final class SecureProbe {
    private var port: CFMachPort?
    private var loop: CFRunLoop?

    static func start(counting keyCode: Int = kVK_F18) -> SecureProbe? {
        secureProbeLock.lock()
        secureProbeKeyCode = Int64(keyCode)
        secureProbeLock.unlock()
        let probe = SecureProbe()
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread {
            let mask = (CGEventMask(1) << CGEventMask(CGEventType.keyDown.rawValue)) | (CGEventMask(1) << CGEventMask(CGEventType.flagsChanged.rawValue))
            guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .defaultTap,
                                               eventsOfInterest: mask, callback: secureProbeCallback, userInfo: nil) else {
                ready.signal()
                return
            }
            CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0), .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            probe.port = port
            probe.loop = CFRunLoopGetCurrent()
            ready.signal()
            CFRunLoopRun()
        }
        thread.start()
        _ = ready.wait(timeout: .now() + 2)
        secureProbeLock.lock()
        secureProbeKeys = 0
        secureProbeFlags = 0
        secureProbeLock.unlock()
        return probe.port == nil ? nil : probe
    }

    func counts() -> (keys: Int, flags: Int) {
        secureProbeLock.lock()
        defer { secureProbeLock.unlock() }
        return (secureProbeKeys, secureProbeFlags)
    }

    func stop() {
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let loop {
            CFRunLoopStop(loop)
        }
    }
}

// 只按一下修饰键（和真人一样发 flagsChanged：按下时带着它，松开时不带）
private func tapModifier(_ code: Int, _ flag: CGEventFlags) {
    for down in [true, false] {
        if let event = CGEvent(keyboardEventSource: eventSource, virtualKey: CGKeyCode(code), keyDown: down) {
            event.type = .flagsChanged
            event.flags = down ? flag : []
            event.post(tap: .cghidEventTap)
        }
        sleepMS(down ? 40 : 80)
    }
}

// 声明一次用户在操作（显示器睡眠的计时归零）。成功时返回 true
private func declareUserActivity() -> Bool {
    var assertion = IOPMAssertionID(0)
    guard IOPMAssertionDeclareUserActivity("Copi self-test" as CFString, kIOPMUserActiveLocal, &assertion) == kIOReturnSuccess else {
        return false
    }
    IOPMAssertionRelease(assertion)
    return true
}

// 网页富文本编辑区（contenteditable，id 为 kd）里的文字
private func secureEditableText(_ page: TestWindow) -> String? {
    findDescendant(page.window, maxDepth: 30, { axString($0, "AXDOMIdentifier") == "kd" }).flatMap { axString($0, kAXValueAttribute) }
}

// ---- 诊断用（S.8）：测试程序自己注册几个不带 ⌘ 的热键（和 Copi 键入期间用来接住按键的那些一样），在硬件层按下去：
// 注册得上没有、热键收到没有、键落没落进文档 ----
private let probeHotKeySignature: OSType = 0x4350_5354 // "CPST"
// 下面三个只在主线程上读写
private var probeHotKeyHits: [UInt32: Int] = [:]
private var probeHotKeyRefs: [EventHotKeyRef] = []
private var probeHotKeyHandler: EventHandlerRef?

private func hotKeyProbe(_ doc: TestWindow) throws -> String {
    // 注册的热键（键码、Carbon 修饰键）
    let keys: [(code: Int, carbon: Int)] = [
        (kVK_ANSI_J, 0), (kVK_ANSI_J, shiftKey), (kVK_ANSI_5, 0), (kVK_Space, 0), (kVK_Tab, 0), (kVK_Return, 0), (kVK_Delete, 0),
        (kVK_LeftArrow, 0), (kVK_Escape, 0), (kVK_F18, 0),
        (kVK_ANSI_Comma, 0), (kVK_ANSI_Keypad5, 0), (kVK_Home, 0), (kVK_ForwardDelete, 0), (kVK_Tab, shiftKey),
    ]
    // 依次按下的键：名字、对应哪个热键（keys 里的序号）、按着的修饰键、按键事件另外带上的标记（真键盘的方向键带 fn、小键盘标记，
    // F 键带 fn 标记；chord 发的不带）
    let presses: [(name: String, key: Int, modifiers: [CGKeyCode: CGEventFlags], extra: CGEventFlags)] = [
        ("J", 0, [:], []), ("⇧J", 1, [CGKeyCode(kVK_Shift): .maskShift], []), ("5", 2, [:], []), ("空格", 3, [:], []),
        ("Tab", 4, [:], []), ("回车", 5, [:], []), ("Delete", 6, [:], []),
        // 这几个在两次 ← 之前按：没被接住的 ← 会把光标往左移，之后落进来的字就不按先后顺序排了
        ("逗号", 10, [:], []), ("小键盘 5（带小键盘标记）", 11, [:], [.maskNumericPad]), ("Home（带 fn 标记）", 12, [:], [.maskSecondaryFn]),
        ("⌦（带 fn 标记）", 13, [:], [.maskSecondaryFn]), ("⇧Tab", 14, [CGKeyCode(kVK_Shift): .maskShift], []),
        ("←", 7, [:], []), ("←（带 fn、小键盘标记）", 7, [:], [.maskSecondaryFn, .maskNumericPad]), ("Esc", 8, [:], []), ("F18", 9, [:], []),
        ("F18（带 fn 标记）", 9, [:], [.maskSecondaryFn]),
    ]
    bringToFront(doc)
    try gate(doc)
    chord(keyA(), cmd)
    chord(CGKeyCode(kVK_Delete))
    sleepMS(150)
    let statuses: [OSStatus] = DispatchQueue.main.sync {
        probeHotKeyHits = [:]
        if probeHotKeyHandler == nil {
            let types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))]
            InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ -> OSStatus in
                var hotKeyID = EventHotKeyID()
                guard let event,
                      GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                        MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID) == noErr,
                      hotKeyID.signature == probeHotKeySignature else {
                    return OSStatus(eventNotHandledErr)
                }
                probeHotKeyHits[hotKeyID.id, default: 0] += 1
                return noErr
            }, types.count, types, nil, &probeHotKeyHandler)
        }
        return keys.enumerated().map { pair in
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(pair.element.code), UInt32(pair.element.carbon),
                                             EventHotKeyID(signature: probeHotKeySignature, id: UInt32(pair.offset + 1)),
                                             GetEventDispatcherTarget(), 0, &ref)
            if let ref {
                probeHotKeyRefs.append(ref)
            }
            return status
        }
    }
    // 每按一下，看这个热键多收到几次
    var received: [Int] = []
    for press in presses {
        let id = UInt32(press.key + 1)
        let before: Int = DispatchQueue.main.sync { probeHotKeyHits[id] ?? 0 }
        if press.extra.isEmpty {
            chord(CGKeyCode(keys[press.key].code), press.modifiers)
        } else {
            pressWithFlags(CGKeyCode(keys[press.key].code), press.extra)
        }
        sleepMS(150)
        received.append(DispatchQueue.main.sync { probeHotKeyHits[id] ?? 0 } - before)
    }
    sleepMS(300)
    DispatchQueue.main.sync {
        for ref in probeHotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        probeHotKeyRefs = []
    }
    sleepMS(200)
    let landed = (textValue(doc) ?? "读不到").map { $0 == "\t" ? "⇥" : ($0 == "\n" ? "↩" : ($0 == " " ? "␣" : String($0))) }.joined()
    let perKey = presses.enumerated().map { pair in
        let status = statuses[pair.element.key]
        return "\(pair.element.name) 注册\(status == noErr ? "成功" : "失败（\(status)）")、收到 \(received[pair.offset]) 次"
    }.joined(separator: "，")
    return "\(perKey)；文档里落进了「\(landed.prefix(40))」（Delete 会删掉它前面落进来的一个字）"
}

// 按一下 code，按键事件带上 flags（不按修饰键）
private func pressWithFlags(_ code: CGKeyCode, _ flags: CGEventFlags) {
    for down in [true, false] {
        if let event = CGEvent(keyboardEventSource: eventSource, virtualKey: code, keyDown: down) {
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
        sleepMS(down ? 40 : 105)
    }
}

// 诊断：接下来 total 毫秒里每 100 ms 记一次硬件层的 keyDown 记录、修饰键记录、系统输入空闲时间（都是多少毫秒以前）
private func sampleInputRecords(forMS total: Int) -> String {
    func ms(_ type: CGEventType) -> String {
        let seconds = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: type)
        return seconds > 1e6 ? "很久" : "\(Int(seconds * 1000))"
    }
    var parts: [String] = []
    let start = Date()
    while true {
        let elapsed = Int(Date().timeIntervalSince(start) * 1000)
        parts.append("\(elapsed) ms：keyDown \(ms(.keyDown))、修饰键 \(ms(.flagsChanged))、HIDIdle \(hidIdleMS().map(String.init) ?? "读不到")")
        if elapsed >= total {
            break
        }
        sleepMS(100)
    }
    return parts.joined(separator: "；")
}

func secureInputTests(_ openedWindows: inout [TestWindow]) throws {
    let name0 = "测试程序打开 Secure Input：会话层的 tap 收不到按键（和密码框、终端的安全键盘输入开着时一样）"
    let heldBefore = IsSecureEventInputEnabled()
    guard EnableSecureEventInput() == noErr else {
        record("S.0", name0, "SKIP", "打开 Secure Input 失败")
        return
    }
    defer {
        DisableSecureEventInput()
        sleepMS(500)
        record("S.9", "测完关掉测试程序打开的 Secure Input", "INFO", "现在开着=\(IsSecureEventInputEnabled())\(secureInputHolder())")
    }
    // Copi 每 20 ms 看一次 Secure Input，开着时改用热键接 ⌘C、⌘V
    sleepMS(800)

    // ---- S.0：这时会话层的 tap 收不收得到按键、修饰键；测试程序的按键、"声明用户在操作"会不会让系统输入空闲时间归零 ----
    guard let probe = SecureProbe.start() else {
        record("S.0", name0, "SKIP", "建不了 tap")
        return
    }
    sleepMS(400)
    let idleBeforeKey = hidIdleMS()
    // Copi 认"再按一次"看热键接住按键时这个键在硬件层是不是按着：Secure Input 开着时还读不读得到
    var keyHeld = false
    chord(CGKeyCode(kVK_F18)) {
        usleep(5000)
        keyHeld = CGEventSource.keyState(.hidSystemState, key: CGKeyCode(kVK_F18))
    }
    // chord 松开按键后等 105 ms 才返回
    let idleAfterKey = hidIdleMS()
    sleepMS(200)
    tapModifier(kVK_Shift, .maskShift)
    sleepMS(200)
    let counts = probe.counts()
    probe.stop()
    sleepMS(400)
    let idleBeforeDeclare = hidIdleMS()
    let declared = declareUserActivity()
    let idleAfterDeclare = hidIdleMS()
    // 真键盘的按键让 HIDIdleTime 归零。测试程序发的按键不会时，按键之前声明一次用户在操作，效果一样
    let keyResetsIdle = (idleBeforeKey ?? 0) >= 300 && (idleAfterKey ?? .max) < 200
    let declareResetsIdle = declared && (idleBeforeDeclare ?? 0) >= 300 && (idleAfterDeclare ?? .max) < 100
    let assist = !keyResetsIdle && declareResetsIdle
    let tapBlind = counts.keys == 0
    record("S.0", name0, tapBlind ? "PASS" : "INFO",
           "测试前 Secure Input 开着=\(heldBefore)；现在开着=\(IsSecureEventInputEnabled())\(secureInputHolder())；会话层的 tap 收到 F18 \(counts.keys) 次、修饰键变化 \(counts.flags) 次（⇧ 按下松开）"
               + "；F18 按着时硬件层的按键状态里它按着=\(keyHeld)；F18 之前 HIDIdleTime=\(idleBeforeKey.map(String.init) ?? "读不到") ms、之后 \(idleAfterKey.map(String.init) ?? "读不到") ms"
               + "；声明用户在操作\(declared ? "成功" : "失败")，之前 \(idleBeforeDeclare.map(String.init) ?? "读不到") ms、之后 \(idleAfterDeclare.map(String.init) ?? "读不到") ms"
               + "；这一组按键之前\(assist ? "声明一次用户在操作（测试程序的按键不让它归零，真键盘会）" : "不另外声明")")
    let groupNames: [(String, String)] = [
        ("S.1", "Secure Input 开着时，代码编辑器里连按两次 ⌘V"),
        ("S.2", "Secure Input 开着时，代码编辑器里连按两次 ⌘C"),
        ("S.3", "Secure Input 开着时，长文字键入中按 Esc"),
        ("S.4", "Secure Input 开着时，长文字键入中按回车"),
        ("S.5", "Secure Input 开着时，复制后按 ⇧ 再有程序写进来"),
        ("S.6", "Secure Input 开着时，复制后马上有程序写进来（劫持）"),
        ("S.7", "Secure Input 开着时，复制后点一下鼠标再有程序写进来"),
        ("S.8", "诊断：不带 ⌘ 的热键在 Secure Input 开着、关着时收不收得到按键"),
        ("S.10", "Secure Input 开着时，长文字键入中按字母键（macOS 不让程序接住，只记录）"),
        ("S.11", "Secure Input 开着时，长文字键入中按空格"),
    ]
    guard tapBlind else {
        for (id, name) in groupNames {
            record(id, name, "SKIP", "测试程序打开的 Secure Input 没起作用（tap 照样收到按键），测到的会是平时的路线")
        }
        return
    }
    // 和真人一样按键：真键盘的按键让系统输入空闲时间归零，测试程序发的按键不会时先声明一次用户在操作
    func press(_ code: CGKeyCode, _ modifiers: [CGKeyCode: CGEventFlags] = [:]) {
        if assist {
            _ = declareUserActivity()
        }
        chord(code, modifiers)
    }
    // Copi 认得出是亲手按的：热键接住时这个键按着，或者那一刻系统记下了输入
    let canConfirm = keyHeld || keyResetsIdle || declareResetsIdle

    let source = try openTextEdit("src-secure.txt", sentinelText)
    openedWindows.append(source)
    let probeDoc = try openTextEdit("dst-secure.txt", "")
    openedWindows.append(probeDoc)
    let docs = MatrixDocs(source: source, probe: probeDoc)
    let plain: Set<String> = [NSPasteboard.PasteboardType.string.rawValue]
    let expectedMarkers: Set<String> = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType"]

    // ---- S.1：默认设置下第一次 ⌘V 不粘贴，8 秒内再按一次经过系统剪贴板粘贴（再按的那一次要认得出是亲手按的） ----
    matrixCase("S.1", groupNames[0].1) {
        let name = "Secure Input 开着时，代码编辑器里粘贴带括号的文字：第一次 ⌘V 不粘贴，再按一次经系统剪贴板粘贴"
        guard canConfirm else {
            record("S.1", name, "SKIP", "这台机器上测试程序按着的键在硬件层读不到、它的按键和声明用户在操作也不让系统输入空闲时间归零，测不到")
            return
        }
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: helperBrowser.0) != nil, runningRemoteDesktops() == 0 else {
            record("S.1", name, "SKIP", "需要浏览器打开测试页，且没有虚拟机/远程桌面在运行")
            return
        }
        let text = "s1(x) { return [1]; }"
        try loadCopi(text, "src-s1.txt", &openedWindows)
        let page = try openPage(helperBrowser, mode: "focus-ce")
        openedWindows.append(page)
        try gate(page)
        let watcher = TypeWatcher(.general) { $0.contains { $0.hasPrefix(stagedPrefix) } }
        press(keyV(), cmd)
        let firstHUD = waitForCopiHUD(upToMS: 2500)
        sleepMS(max(0, 2500 - (firstHUD?.ms ?? 2500)))
        let firstPasted = (axString(page.window, kAXTitleAttribute) ?? "").contains("COPI|ce|")
        try gate(page)
        press(keyV(), cmd)
        let secondRecords = inputRecordsDiag()
        sleepMS(4000)
        let secondHUD = copiHUDText()
        let (presence, types) = watcher.stop()
        let markers = types.filter { $0.hasPrefix("org.nspasteboard.") }
        let (status, note) = fieldResult(page, field: "ce", expected: text)
        let ok = !firstPasted && status == "PASS" && markers.isSuperset(of: expectedMarkers) && presence.ms <= 1500
        record("S.1", name, ok ? "PASS" : (status == "PASS" && !firstPasted ? "CHECK" : "FAIL"),
               "第一次 ⌘V 后页面收到了=\(firstPasted)；\(presence.summary("Copi 挂上去的文字"))；带的标记：\(markers.map { $0.replacingOccurrences(of: "org.nspasteboard.", with: "") }.sorted().joined(separator: ","))；网页：\(note)"
                   + "；（诊断）第一次 ⌘V 后 Copi 的小窗口\(describeHUD(firstHUD, within: 2500))，第二次后：\(secondHUD.map { "「\($0.prefix(80))」" } ?? "没显示")；第二次刚按完\(secondRecords)")
    }

    // ---- S.2：读不出来的代码编辑器里第一次 ⌘C 不复制，8 秒内再按一次交给 App 自己复制，Copi 马上挪走 ----
    let chromium = onCI ? ("com.google.Chrome", "Google Chrome") : brave
    matrixCase("S.2", groupNames[1].1) {
        let name = "Secure Input 开着时，代码编辑器里 ⌘C：第一次不复制，再按一次 App 自己复制、Copi 挪走"
        guard canConfirm else {
            record("S.2", name, "SKIP", "这台机器上测试程序按着的键在硬件层读不到、它的按键和声明用户在操作也不让系统输入空闲时间归零，测不到")
            return
        }
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: chromium.0) != nil else {
            record("S.2", name, "SKIP", "需要 Chromium 浏览器打开测试页")
            return
        }
        let page = try openPage(chromium, mode: "kind-cm-content")
        openedWindows.append(page)
        sleepMS(600)
        // 和 K.17 一样，放好哨兵之后操作一下（这时 Copi 看得到的是修饰键），后面 App 自己写进来的不当成劫持
        try loadSentinel(docs, act: false)
        tapModifier(kVK_Shift, .maskShift)
        sleepMS(700)
        bringToFront(page)
        sleepMS(300)
        try gate(page)
        let firstWatcher = TypeWatcher(.general) { !$0.isDisjoint(with: plain) }
        press(keyC(), cmd)
        sleepMS(600)
        let firstPresence = firstWatcher.stop().presence
        let firstGot = try probeCopi(docs)
        bringToFront(page)
        sleepMS(300)
        try gate(page)
        let watcher = TypeWatcher(.general) { !$0.isDisjoint(with: plain) }
        press(keyC(), cmd)
        let secondRecords = inputRecordsDiag()
        sleepMS(800)
        let presence = watcher.stop().presence
        let stillThere = hasAny(.general, plain)
        let got = try probeCopi(docs)
        let same = got?.trimmingCharacters(in: .whitespacesAndNewlines) == "Copi blocked cm-content text"
        let firstRefused = firstGot == "" && firstPresence.first == nil
        record("S.2", name, firstRefused && same ? moveStatus(presence, stillThere: stillThere) : "FAIL",
               "第一次：\(firstPresence.summary("文字"))，之后 ⌘V 粘贴出\(shortDescription(firstGot))；第二次：\(presence.summary("文字"))；最后还在=\(stillThere)；之后 ⌘V 粘贴出\(same ? "这段文字" : shortDescription(got))"
                   + "；（诊断）第二次刚按完\(secondRecords)")
    }

    // ---- S.3、S.4、S.11：往网页富文本编辑区键入长文字，中途按 Esc / 回车 / 空格：键入停下，按的键不落进文字。
    // 空格是 Copi 临时接住的"别的键"里 macOS 照样交给热键的一个（见 S.8），走的是和回车、Esc 不同的那条路 ----
    // ---- S.10：中途按字母键 Q。Secure Input 开着时 macOS 不把字母这类字符键交给任何程序的热键（见 S.8），Q 会落进文字：只记下
    // 键入停没停、Q 落在哪、Copi 那时看得到什么。系统剪贴板上出现了文字、落进了别的字符、Q 落进去不止一次、进度一直不消失才算 FAIL ----
    let typingBrowser = onCI ? ("com.google.Chrome", "Google Chrome") : brave
    let typingCases: [(id: String, key: CGKeyCode, keyName: String, character: Character?)] = [
        ("S.3", CGKeyCode(kVK_Escape), "Esc", nil), ("S.4", CGKeyCode(kVK_Return), "回车", nil), ("S.10", CGKeyCode(kVK_ANSI_Q), "Q", "q"),
        ("S.11", CGKeyCode(kVK_Space), "空格", nil),
    ]
    for (id, key, keyName, character) in typingCases {
        let caseName = groupNames.first { $0.0 == id }?.1 ?? id
        matrixCase(id, caseName) {
            let name = character == nil
                ? "Secure Input 开着时，粘贴 20000 个字到网页富文本编辑区（键入）中途按 \(keyName)：键入停下，\(keyName) 不落进文字，系统剪贴板上一直没有文字"
                : "Secure Input 开着时，粘贴 20000 个字到网页富文本编辑区（键入）中途按字母键 \(keyName)（macOS 这时不让任何程序接住字母，它会落进文字）：记下键入停没停、它落在哪；系统剪贴板上一直没有文字"
            guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: typingBrowser.0) != nil else {
                record(id, name, "SKIP", "需要浏览器打开测试页")
                return
            }
            let total = 20000
            try loadCopi(String(repeating: "z", count: total), "src-\(id.lowercased()).txt", &openedWindows)
            let page = try openPage(typingBrowser, mode: "kind-plain-edit")
            openedWindows.append(page)
            sleepMS(600)
            try gate(page)
            let watcher = TypeWatcher(.general) { !$0.isDisjoint(with: plain) }
            chord(keyV(), cmd)
            sleepMS(1500)
            let hud = copiHUDVisible()
            let during = secureEditableText(page)?.count ?? -1
            try gate(page)
            // （诊断）会话层的 tap 收没收到这个键（没被 Copi 扣下、Secure Input 也没挡住时才收得到）
            let keyProbe = SecureProbe.start(counting: Int(key))
            press(key)
            let records = inputRecordsDiag()
            // 字母键：之后硬件层的按键记录、系统输入空闲时间怎么变（Copi 靠什么察觉到它）
            let samples = character == nil ? nil : sampleInputRecords(forMS: 600)
            sleepMS(character == nil ? 800 : 200)
            let panel = copiHUDText()
            let tapKeys = keyProbe?.counts().keys
            keyProbe?.stop()
            let first = secureEditableText(page)
            sleepMS(1200)
            let second = secureEditableText(page)
            let hudAfter = copiHUDVisible()
            let panelAfter = copiHUDText()
            // 字母键：键入可能没停，按 Esc 停下（Esc 接得住），免得它接着往页面里打字、影响后面的测试
            var stoppedWithEsc = false
            if character != nil, hudAfter {
                press(CGKeyCode(kVK_Escape))
                sleepMS(1500)
                stoppedWithEsc = true
            }
            let presence = watcher.stop().presence
            let firstCount = first?.count ?? -1
            let secondCount = second?.count ?? -1
            let stopped = firstCount == secondCount && firstCount > 0 && firstCount < total
            let others = (second ?? "").enumerated().filter { $0.element != "z" }
            let leaked = !others.isEmpty
            let strays = others.prefix(3).map { pair in
                "「\(pair.element.unicodeScalars.map { $0.value < 0x20 ? String(format: "U+%04X", $0.value) : String($0) }.joined())」在第 \(pair.offset + 1) 个"
            }
            let detail = "1.5 秒时显示进度=\(hud)、已打 \(during) 字；按 \(keyName) 后 0.8 秒 \(firstCount) 字、再过 1.2 秒 \(secondCount) 字；文字里有 z 以外的字=\(leaked)\(strays.isEmpty ? "" : "（\(strays.joined(separator: "、"))）")；之后还显示进度=\(hudAfter)；\(presence.summary("文字"))"
                + "；（诊断）会话层的 tap 收到 \(keyName) \(tapKeys.map(String.init) ?? "（建不了 tap）") 次；刚按完\(records)；0.8 秒时 Copi 的小窗口：\(panel.map { "「\($0.prefix(100))」" } ?? "没显示")"
            guard let character else {
                record(id, name, hud && stopped && !leaked && !hudAfter && presence.first == nil ? "PASS" : "FAIL", detail)
                return
            }
            // 落进来的只有这一个字母（至多一次）、剪贴板上没有文字、键入最后结束了：照实记下（INFO）
            let onlyIt = others.allSatisfy { $0.element == character } && others.count <= 1
            let typedAfter = others.first.map { "，它后面又打了 \(max(0, firstCount - $0.offset - 1)) 字" } ?? ""
            record(id, name, hud && onlyIt && presence.first == nil && (!hudAfter || stoppedWithEsc && !copiHUDVisible()) ? "INFO" : "FAIL",
                   "键入停下=\(stopped)\(typedAfter)\(stoppedWithEsc ? "（2 秒时还在打，按 Esc 停下）" : "")；" + detail
                       + "；按完之后每 100 ms：\(samples ?? "")；2 秒时 Copi 的小窗口：\(panelAfter.map { "「\($0.prefix(140))」" } ?? "没显示")")
        }
    }

    // ---- S.5–S.7：安全复制之后 3 秒内别的程序写进来：用户没有操作时当成劫持清掉；按过修饰键、点过鼠标就照常收 ----
    func writeAfterCopy(_ text: String, act: () throws -> Void) throws -> (presence: Presence, stillThere: Bool, got: String?) {
        try loadSentinel(docs, act: false)
        try act()
        let start = Date()
        writeGeneral([(.string, utf8(text))])
        var presence = Presence()
        sample(.general, plain, from: start, untilMS: 1200, into: &presence)
        let stillThere = hasAny(.general, plain)
        let got = try probeCopi(docs)
        return (presence, stillThere, got)
    }
    matrixCase("S.5", groupNames[4].1) {
        let text = "Copi S5 after shift"
        let (presence, stillThere, got) = try writeAfterCopy(text) {
            tapModifier(kVK_Shift, .maskShift)
            sleepMS(200)
        }
        record("S.5", "Secure Input 开着时，复制后按一下 ⇧、别的程序再写进文字：照常挪进 Copi", got == text ? moveStatus(presence, stillThere: stillThere) : "FAIL",
               "\(presence.summary("文字"))；最后还在=\(stillThere)；之后 ⌘V 粘贴出\(shortDescription(got))")
    }
    matrixCase("S.6", groupNames[5].1) {
        let (presence, stillThere, got) = try writeAfterCopy("Copi S6 hijack") {}
        record("S.6", "Secure Input 开着时，复制后 3 秒内、没有操作时别的程序写进文字：清掉，Copi 保留刚复制的",
               got == sentinelText ? moveStatus(presence, stillThere: stillThere) : "FAIL",
               "\(presence.summary("文字"))；最后还在=\(stillThere)；之后 ⌘V 粘贴出\(shortDescription(got))（期望还是哨兵）")
    }
    matrixCase("S.7", groupNames[6].1) {
        let text = "Copi S7 after click"
        let (presence, stillThere, got) = try writeAfterCopy(text) {
            // 点源文档里文字的末尾（只移动光标）
            try gate(docs.source)
            if let area = textArea(docs.source), let areaFrame = frame(area) {
                click(CGPoint(x: areaFrame.maxX - 20, y: areaFrame.maxY - 20))
            }
            sleepMS(200)
        }
        record("S.7", "Secure Input 开着时，复制后点一下鼠标、别的程序再写进文字：照常挪进 Copi", got == text ? moveStatus(presence, stillThere: stillThere) : "FAIL",
               "\(presence.summary("文字"))；最后还在=\(stillThere)；之后 ⌘V 粘贴出\(shortDescription(got))")
    }

    // ---- S.8（诊断）：不带 ⌘ 的热键（Copi 键入期间用来接住按键）在 Secure Input 开着、关着时收不收得到按下的键 ----
    matrixCase("S.8", groupNames[7].1) {
        let on = try hotKeyProbe(docs.probe)
        let off: String
        do {
            DisableSecureEventInput()
            defer {
                _ = EnableSecureEventInput()
                sleepMS(800)
            }
            sleepMS(600)
            let stillOn = IsSecureEventInputEnabled()
            let probed = try hotKeyProbe(docs.probe)
            off = "（关掉之后还开着=\(stillOn)）\(probed)"
        }
        record("S.8", "诊断：测试程序注册不带 ⌘ 的热键，Secure Input 开着、关着时在硬件层按下去", "INFO", "开着：\(on) / 关着\(off)")
    }
}
