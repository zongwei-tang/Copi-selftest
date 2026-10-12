// CopiSelfTest 的第二批测试：复制按钮、浏览器菜单/右键/拖动、假 sudo、虚拟机时的剪贴板回退、
// Slack、VS Code Copi Bridge、密码管理器式的复制（地址栏、Spotlight、90 秒清除）、锁屏。
// 和 main.swift 一样：发按键前过 gate，只读剪贴板类型，结果只记长度、哈希、真假。

import AppKit
import ApplicationServices
import Carbon

// MARK: - 通用

// 后台每 intervalUS 微秒看一次某个剪贴板：文字出现的第一次、最后一次（相对开始的毫秒）。
// baselineChangeCount：剪贴板还是这一版时不算（之前留下的旧内容）
final class PasteboardSampler {
    private let pasteboard: NSPasteboard
    private let intervalUS: useconds_t
    private let baseline: Int?
    private let lock = NSLock()
    private let finished = DispatchSemaphore(value: 0)
    private var running = true
    private var first: Int?
    private var last: Int?
    private let start = Date()

    init(_ pasteboard: NSPasteboard, intervalUS: useconds_t = 1000, baselineChangeCount: Int? = nil) {
        self.pasteboard = pasteboard
        self.intervalUS = intervalUS
        self.baseline = baselineChangeCount
        Thread { [self] in
            while isRunning {
                if baseline.map({ self.pasteboard.changeCount != $0 }) ?? true, pasteboardHasText(self.pasteboard) {
                    let ms = Int(Date().timeIntervalSince(start) * 1000)
                    lock.lock()
                    first = first ?? ms
                    last = ms
                    lock.unlock()
                }
                usleep(self.intervalUS)
            }
            finished.signal()
        }.start()
    }

    private var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    // 等取样的线程真正停下来再返回
    func stop() {
        lock.lock()
        let wasRunning = running
        running = false
        lock.unlock()
        if wasRunning {
            finished.wait()
        }
    }

    var firstSeenMS: Int? {
        lock.lock()
        defer { lock.unlock() }
        return first
    }

    var lastSeenMS: Int? {
        lock.lock()
        defer { lock.unlock() }
        return last
    }

    // 文字在剪贴板上大约停了多久（毫秒）
    var exposureMS: Int? {
        firstSeenMS.map { (lastSeenMS ?? $0) - $0 + 1 }
    }

    var summary: String {
        firstSeenMS.map { "文字在剪贴板上约 \(exposureMS ?? 0) ms（从 \($0) ms 到 \(lastSeenMS ?? $0) ms）" } ?? "剪贴板上一直没有文字"
    }
}

func findAll(_ root: AXUIElement, maxDepth: Int = 40, limit: Int = 4000, _ predicate: (AXUIElement) -> Bool) -> [AXUIElement] {
    var found: [AXUIElement] = []
    var level = [root]
    var visited = 0
    for _ in 0..<maxDepth where !level.isEmpty {
        var next: [AXUIElement] = []
        for element in level {
            visited += 1
            if visited > limit {
                return found
            }
            if predicate(element) {
                found.append(element)
            }
            next.append(contentsOf: axChildren(element))
        }
        level = next
    }
    return found
}

func focusedElementValue(_ pid: pid_t) -> String? {
    axElement(ax(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute)).flatMap { axString($0, kAXValueAttribute) }
}

func button(in root: AXUIElement, titles: [String]) -> AXUIElement? {
    findDescendant(root, maxDepth: 40) { element in
        role(element) == kAXButtonRole
            && ([axString(element, kAXTitleAttribute), axString(element, kAXDescriptionAttribute)].contains { title in titles.contains(title ?? "") })
    }
}

// 屏幕上这一点是哪个界面元素
func elementAt(_ point: CGPoint) -> AXUIElement? {
    var hit: AXUIElement?
    guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit) == .success else {
        return nil
    }
    return hit
}

// element 是 ancestor 本身，或者在它里面（往上最多 levels 层）
func isWithin(_ element: AXUIElement?, _ ancestor: AXUIElement, levels: Int = 6) -> Bool {
    var node = element
    for _ in 0...levels {
        guard let current = node else {
            return false
        }
        if CFEqual(current, ancestor) {
            return true
        }
        node = axElement(ax(current, kAXParentAttribute))
    }
    return false
}

// 往上 8 层以内有能点的东西（按钮、链接……）：在它上面按下、松开鼠标会点到它
func hasClickableAncestor(_ element: AXUIElement) -> Bool {
    let clickable: Set<String> = ["AXButton", "AXLink", "AXCheckBox", "AXRadioButton", "AXMenuButton", "AXPopUpButton", "AXDisclosureTriangle", "AXTab"]
    var node: AXUIElement? = element
    for _ in 0..<8 {
        guard let current = node else {
            return false
        }
        if clickable.contains(role(current) ?? "") {
            return true
        }
        node = axElement(ax(current, kAXParentAttribute))
    }
    return false
}

func focusedElement(_ pid: pid_t) -> AXUIElement? {
    axElement(ax(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute))
}

// 网页里选中了多少字（读不到为 -1）
func webSelectionLength(_ target: TestWindow) -> Int {
    guard let focused = focusedElement(target.pid), let range = ax(focused, "AXSelectedTextMarkerRange") else {
        return -1
    }
    var out: CFTypeRef?
    guard AXUIElementCopyParameterizedAttributeValue(focused, "AXLengthForTextMarkerRange" as CFString, range, &out) == .success else {
        return -1
    }
    return (out as? NSNumber)?.intValue ?? -1
}

func notify(_ message: String) {
    _ = run("/usr/bin/osascript", ["-e", "display notification \"\(message)\" with title \"Copi 自动测试\" sound name \"Glass\""])
}

// 在浏览器里对某一点点右键，点标题是 titles 之一的菜单项
func browserContextMenuClick(_ target: TestWindow, at point: CGPoint, titles: [String]) throws -> Bool {
    try gate(target)
    rightClick(point)
    let app = AXUIElementCreateApplication(target.pid)
    func openMenus() -> [AXUIElement] {
        findAll(app, maxDepth: 5, limit: 20000) { role($0) == kAXMenuRole }.filter { menu in
            // 不要菜单栏里的菜单
            var node = axElement(ax(menu, kAXParentAttribute))
            for _ in 0..<3 {
                if let current = node, role(current) == kAXMenuBarRole || role(current) == kAXMenuBarItemRole {
                    return false
                }
                node = node.flatMap { axElement(ax($0, kAXParentAttribute)) }
            }
            return true
        }
    }
    // 右键菜单要等网页处理完右键才出现：最多等 2 秒。它不一定挂在 App 的无障碍树里：在点击位置右下方做命中测试找它
    func menuNearPoint() -> [AXUIElement] {
        for offset in [CGPoint(x: 20, y: 20), CGPoint(x: 20, y: 45), CGPoint(x: 45, y: 20), CGPoint(x: 20, y: 70), CGPoint(x: 60, y: 45)] {
            guard let hit = elementAt(CGPoint(x: point.x + offset.x, y: point.y + offset.y)), role(hit) == kAXMenuItemRole else {
                continue
            }
            var hitPID: pid_t = 0
            guard AXUIElementGetPid(hit, &hitPID) == .success, hitPID == target.pid, let menu = axElement(ax(hit, kAXParentAttribute)),
                  role(menu) == kAXMenuRole else {
                continue
            }
            return [menu]
        }
        return []
    }
    var menus = openMenus()
    for _ in 0..<10 where menus.isEmpty {
        sleepMS(200)
        menus = openMenus()
        if menus.isEmpty {
            menus = menuNearPoint()
        }
    }
    guard let item = menus.lazy.flatMap({ axChildren($0) }).first(where: { titles.contains(axString($0, kAXTitleAttribute) ?? "") }),
          let itemFrame = frame(item) else {
        if focusedApp()?.pid == target.pid {
            chord(CGKeyCode(kVK_Escape))
        }
        return false
    }
    click(center(itemFrame))
    sleepMS(300)
    return true
}

// 把一段已知文字放进 Copi（在 TextEdit 里 ⌘A ⌘C）
func loadCopi(_ text: String, _ name: String, _ openedWindows: inout [TestWindow]) throws {
    let (source, _, _) = try copyFromTextEdit(name, text)
    openedWindows.append(source)
}

// 粘贴进一个新的 TextEdit 文档，返回里面的文字
func pasteIntoNewTextEdit(_ name: String, _ openedWindows: inout [TestWindow], chord pasteChord: [CGKeyCode: CGEventFlags] = cmd) throws -> String? {
    let destination = try openTextEdit(name, "")
    openedWindows.append(destination)
    try gate(destination)
    chord(keyV(), pasteChord)
    sleepMS(900)
    return textValue(destination)
}

let brave = ("com.brave.Browser", "Brave Browser")
// 别的测试借用的浏览器（打开测试页）：GitHub 的虚拟机上用 Safari（Brave 在那里拿不到焦点，原因见 run.log）
var helperBrowser: (String, String) {
    onCI ? ("com.apple.Safari", "Safari") : brave
}
let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

// MARK: - 浏览器里的复制按钮、菜单、右键、拖动

func browserMoreTests(_ browser: (String, String), short: String, _ openedWindows: inout [TestWindow]) throws {
    // 网页上的复制按钮（App 自己写系统剪贴板）：Copi 应在几毫秒内挪走，文字进 Copi
    let buttonPage = try openPage(browser, mode: "copybtn")
    openedWindows.append(buttonPage)
    sleepMS(500)
    if let copyButton = button(in: buttonPage.window, titles: ["Copy test"]), let buttonFrame = frame(copyButton) {
        try gate(buttonPage)
        let sampler = PasteboardSampler(.general)
        click(center(buttonFrame))
        sleepMS(600)
        sampler.stop()
        let pasted = try pasteIntoNewTextEdit("dst-\(short)-button.txt", &openedWindows)
        // 点击之后 Copi 每 3～4 ms 看一次剪贴板
        let limit = 15
        let exposure = sampler.exposureMS ?? 0
        let status = pasted != "COPI-BUTTON-TEXT-42" || exposure > 50 ? "FAIL" : (exposure <= limit ? "PASS" : "CHECK")
        record("\(short).6", "\(short) 网页复制按钮（App 自己写剪贴板）：几毫秒内挪走、文字进 Copi", status,
               "\(sampler.summary)（PASS 的界限 \(limit) ms）；之后 ⌘V 粘贴出的内容\(pasted == "COPI-BUTTON-TEXT-42" ? "正确" : "不对（\(describeDiff(pasted, "COPI-BUTTON-TEXT-42"))）")")
    } else {
        record("\(short).6", "\(short) 网页复制按钮", "SKIP", "找不到测试页上的按钮")
    }

    let plain = try openPage(browser, mode: "plain")
    openedWindows.append(plain)
    sleepMS(600)
    guard let alpha = staticTextFrame(plain.window, prefix: "Alpha paragraph"),
          let gamma = staticTextFrame(plain.window, prefix: "Gamma paragraph") else {
        record("\(short).7", "\(short) 菜单/右键/拖动", "SKIP", "找不到段落的位置")
        return
    }
    let expected = paraTexts.joined(separator: "\n")
    let expectedWebKit = paraTexts.joined(separator: "\n\n")

    // 编辑菜单 › 拷贝（鼠标点菜单项）。偶尔才出问题：重复几次，每次之前先在 Copi 里放一段别的文字，复制没成功就看得出来
    let menuTries = short == "Safari" ? 2 : 4
    var menuNotes: [String] = []
    var menuPassed = 0
    for attempt in 1...menuTries {
        try loadCopi("Copi menu sentinel \(attempt)", "src-\(short)-sentinel-\(attempt).txt", &openedWindows)
        bringToFront(plain)
        try gate(plain)
        // 先在段落右边的空白处点一下，取消上一次的选区：在选中的文字上按下拖动是拖放文字（Copi 会拦下），不是重新选择
        click(CGPoint(x: alpha.maxX + 60, y: alpha.midY))
        try gate(plain)
        mouseSelect(from: CGPoint(x: alpha.minX + 1, y: alpha.midY), to: CGPoint(x: gamma.maxX - 1, y: gamma.midY))
        guard webSelectionLength(plain) > 0 else {
            menuNotes.append("第 \(attempt) 次：拖选之后网页里没有选区，跳过")
            continue
        }
        let menuSampler = PasteboardSampler(.general)
        let menuClicked = try clickMenuItem(plain, commandChar: "C")
        let menuState = lastMenuClickState
        sleepMS(500)
        menuSampler.stop()
        let menuValue = try pasteIntoNewTextEdit("dst-\(short)-menu-\(attempt).txt", &openedWindows)
        let ok = menuClicked && (menuValue == expected || menuValue == expectedWebKit) && menuSampler.firstSeenMS == nil
        menuPassed += ok ? 1 : 0
        menuNotes.append("第 \(attempt) 次：点到菜单项=\(menuClicked)（\(menuState)），\(menuSampler.summary)，\(menuValue == expected || menuValue == expectedWebKit ? "内容一致" : (menuValue == "Copi menu sentinel \(attempt)" ? "Copi 里还是复制之前放的那段（没复制上）" : describeDiff(menuValue, expected)))")
    }
    record("\(short).7", "\(short) 编辑菜单 › 拷贝（网页正文，\(menuTries) 次）", menuPassed == menuTries ? "PASS" : (menuNotes.allSatisfy { $0.contains("跳过") } ? "SKIP" : "FAIL"),
           "\(menuPassed)/\(menuTries) 次成功；" + menuNotes.joined(separator: "；"))

    // 右键 › 拷贝（README：在输入框以外的地方，执行 App 自己的拷贝，经过系统剪贴板，Copi 几毫秒内挪走）
    bringToFront(plain)
    try gate(plain)
    // 先点一下段落右边的空白处，取消上一次的选区（在选中的文字上按下拖动是拖放文字，不是重新选择）
    click(CGPoint(x: alpha.maxX + 60, y: alpha.midY))
    try gate(plain)
    mouseSelect(from: CGPoint(x: alpha.minX + 1, y: alpha.midY), to: CGPoint(x: alpha.maxX - 1, y: alpha.midY))
    let rightSampler = PasteboardSampler(.general)
    let rightClicked = try browserContextMenuClick(plain, at: CGPoint(x: alpha.midX, y: alpha.midY), titles: ["Copy", "拷贝", "复制"])
    sleepMS(600)
    rightSampler.stop()
    let rightValue = try pasteIntoNewTextEdit("dst-\(short)-right.txt", &openedWindows)
    let rightOK = rightClicked && rightValue?.trimmingCharacters(in: .whitespacesAndNewlines) == paraTexts[0] && (rightSampler.exposureMS ?? 0) <= 50
    record("\(short).8", "\(short) 右键 › 拷贝（网页正文，README：经系统剪贴板、几毫秒内挪走）", rightClicked ? (rightOK ? "PASS" : "FAIL") : "SKIP",
           "点到菜单项=\(rightClicked)；\(rightSampler.summary)；\(rightValue?.trimmingCharacters(in: .whitespacesAndNewlines) == paraTexts[0] ? "内容一致" : describeDiff(rightValue, paraTexts[0]))")

    // 拖动选中的网页文字
    guard copiBool("blockTextDragging", true) else {
        record("\(short).9", "\(short) 拖动选中的网页文字", "N/A", "Copi 的 Block Dragging Text 关着")
        return
    }
    bringToFront(plain)
    try gate(plain)
    click(CGPoint(x: alpha.maxX + 60, y: alpha.midY))
    try gate(plain)
    mouseSelect(from: CGPoint(x: alpha.minX + 1, y: alpha.midY), to: CGPoint(x: alpha.maxX - 1, y: alpha.midY))
    guard webSelectionLength(plain) > 0 else {
        record("\(short).9", "\(short) 拖动选中的网页文字", "SKIP", "拖选之后网页里没有选区（读到的长度 \(webSelectionLength(plain))）")
        return
    }
    let start = CGPoint(x: alpha.minX + 40, y: alpha.midY)
    let dragBefore = NSPasteboard(name: .drag).changeCount
    let dragSampler = PasteboardSampler(NSPasteboard(name: .drag), intervalUS: 2000, baselineChangeCount: dragBefore)
    mouse(.mouseMoved, start)
    sleepMS(100)
    mouse(.leftMouseDown, start)
    sleepMS(400)
    for step in 1...12 {
        mouse(.leftMouseDragged, CGPoint(x: start.x + CGFloat(step * 12), y: start.y + CGFloat(step * 8)))
        sleepMS(40)
    }
    mouse(.leftMouseUp, CGPoint(x: start.x + 144, y: start.y + 96))
    sleepMS(1000)
    dragSampler.stop()
    let changed = NSPasteboard(name: .drag).changeCount != dragBefore
    let after = changed && pasteboardHasText(NSPasteboard(name: .drag))
    record("\(short).9", "\(short) 拖动选中的网页文字（README：拦下或拖放一开始就清掉）", (dragSampler.exposureMS ?? 0) <= 20 && !after ? "PASS" : "FAIL",
           "\(dragSampler.firstSeenMS.map { _ in "新的文字在拖放剪贴板上约 \(dragSampler.exposureMS ?? 0) ms" } ?? "拖放剪贴板上没有出现新的文字")；拖放剪贴板变过=\(changed)；放下 1 秒后还有文字=\(after)")
}

// MARK: - 假 sudo 的密码提示符

func fakeSudoTest(_ openedWindows: inout [TestWindow]) throws {
    let fakeSudo = baseDir.appendingPathComponent("fakesudo/sudo")
    guard FileManager.default.isExecutableFile(atPath: fakeSudo.path) else {
        record("T.7", "sudo 密码提示符", "SKIP", "找不到测试用的假 sudo")
        return
    }
    guard let opened = openTestTerminal() else {
        record("T.7", "sudo 密码提示符", "SKIP", "Terminal 没有打开带测试提示符的新窗口")
        return
    }
    let term = opened.term
    bringToFront(term)
    sleepMS(1200)
    let markers = fixtures.appendingPathComponent("markers")
    try? FileManager.default.createDirectory(at: markers, withIntermediateDirectories: true)
    // 最近一次启动的假 sudo 写结果的文件（还没有这个文件：它还在等一行）
    var waiting: URL?
    // 半路中止时：假 sudo 还在等一行，清掉这一行（⌃U）再按回车让它结束（它自己 60 秒后也会退出），再退出测试 shell
    defer {
        if (try? gate(term)) != nil {
            if let waiting, !FileManager.default.fileExists(atPath: waiting.path) {
                chord(CGKeyCode(kVK_ANSI_U), ctrl)
                pressReturn()
                sleepMS(500)
            }
            typeText("exit")
            pressReturn()
        }
    }
    // 启动假 sudo，经 Copi 粘贴 text 再按回车，返回提示符读到的一行（长度和哈希）。没读到时为 nil，并且清掉这一行再按回车，
    // 让假 sudo 结束（打进去的字占满了终端的行缓冲区时，回车也进不去）
    func pasteAtFakeSudo(_ text: String, _ name: String, typingMS: Int) throws -> String? {
        let result = markers.appendingPathComponent("\(name).txt")
        try? FileManager.default.removeItem(at: result)
        try gate(term)
        typeText("'\(fakeSudo.path)' '\(result.path)'")
        pressReturn()
        waiting = result
        sleepMS(1500)
        try loadCopi(text, "src-\(name).txt", &openedWindows)
        bringToFront(term)
        try gate(term)
        chord(keyV(), cmd)
        sleepMS(typingMS)
        try gate(term)
        pressReturn()
        sleepMS(1500)
        let written = (try? String(contentsOf: result, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        if written == nil {
            try gate(term)
            chord(CGKeyCode(kVK_ANSI_U), ctrl)
            pressReturn()
            sleepMS(1000)
        }
        return written
    }
    let secret = "Not-a-real-password_42"
    let written = try pasteAtFakeSudo(secret, "fakesudo", typingMS: 3000)
    let want = "len=\(secret.utf16.count)|h=\(djb2(secret))"
    let shown = terminalText(term).contains(secret)
    record("T.7", "sudo 密码提示符（假 sudo：进程名 sudo、关回显整行读）", written == want && !shown ? "PASS" : "FAIL",
           "提示符读到的内容\(written == want ? "完全一致" : "不对（读到 \(written ?? "nil")，期望 \(want)）")；密码出现在屏幕上=\(shown)")

    // README：整行读的提示符（终端的行缓冲区只有 1024 字节，多出来的连同回车都被丢掉）一行超过约 1000 字节时 Copi 一个字都不打。
    // 400 个汉字是 1200 字节、只有 400 个 UTF-16 单元：按字节算才会拒绝，回车之后提示符读到空行；正好 1000 字节的一行照常完整打进去
    let longLine = String(repeating: "测试文字", count: 100)
    let longWritten = try pasteAtFakeSudo(longLine, "fakesudo-long", typingMS: 3000)
    let empty = "len=0|h=\(djb2(""))"
    record("T.7b", "sudo 密码提示符：一行 1200 字节（400 个汉字）一个字都不打", longWritten == empty ? "PASS" : "FAIL",
           longWritten == empty ? "提示符读到空行" : "提示符读到 \(longWritten ?? "nil（回车没进去，行缓冲区可能被占满了）")，期望空行")
    let fullLine = String(repeating: "Not-a-real-password_", count: 50)
    let fullWritten = try pasteAtFakeSudo(fullLine, "fakesudo-full", typingMS: 4000)
    let fullWant = "len=\(fullLine.utf16.count)|h=\(djb2(fullLine))"
    record("T.7c", "sudo 密码提示符：一行正好 1000 字节照常完整打进去", fullWritten == fullWant ? "PASS" : "FAIL",
           fullWritten == fullWant ? "完全一致" : "读到 \(fullWritten ?? "nil")，期望 \(fullWant)")
}

// MARK: - 虚拟机、远程桌面在运行时：经过剪贴板的粘贴先询问

// 和 Copi 一样认虚拟机、远程桌面（ZeroExposure.swift 的 remoteDesktopBundleIDPrefixes、remoteHostAgentBundleIDPrefixes）
let remoteDesktopPrefixes = [
    "com.parallels.", "com.vmware.fusion", "com.vmware.horizon", "com.omnissa.", "com.utmapp.", "org.virtualbox.",
    "com.microsoft.rdc", "com.apple.ScreenSharing", "com.citrix.", "com.realvnc.", "com.teamviewer.", "com.philandro.anydesk",
    "com.p5sys.jump", "com.apple.iphonesimulator", "com.apple.ScreenContinuity", "tv.parsec.www", "com.carriez.rustdesk",
    "com.moonlight-stream.", "codes.rambo.VirtualBuddy", "com.amazon.workspaces", "com.lemonmojo.RoyalTSX", "com.edovia.screens",
]
let remoteHostAgentPrefixes = ["com.realvnc.", "com.teamviewer.", "com.philandro.anydesk", "com.carriez.rustdesk", "com.p5sys.jump"]

func runningRemoteDesktops() -> Int {
    NSWorkspace.shared.runningApplications.filter { app in
        guard let id = app.bundleIdentifier, remoteDesktopPrefixes.contains(where: { id.hasPrefix($0) }) else {
            return false
        }
        return app.activationPolicy == .regular || remoteHostAgentPrefixes.contains(where: { id.hasPrefix($0) })
    }.count
}

func vmFallbackTests(_ openedWindows: inout [TestWindow]) throws {
    guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: helperBrowser.0) != nil else {
        record("6", "虚拟机/远程桌面", "SKIP", "需要浏览器打开测试页")
        return
    }
    // 已经有虚拟机、远程桌面在运行（可能连着别的电脑）：不测，免得测试文字经剪贴板同步过去
    let alreadyRunning = runningRemoteDesktops()
    guard alreadyRunning == 0 else {
        record("6", "虚拟机/远程桌面", "SKIP", "已经有 \(alreadyRunning) 个虚拟机/远程桌面在运行，可能连着别的电脑，不测")
        return
    }
    let screenSharing = "com.apple.ScreenSharing"
    // 打开"允许剪贴板回退"（网页代码编辑器里带括号的文字只能经剪贴板粘贴）；结束时恢复成原来的值（原来没设过就删掉）
    let original = copiDefault("allowClipboardFallback")
    if original != "1" {
        _ = run("/usr/bin/defaults", ["write", "com.gokoding.Copi", "allowClipboardFallback", "-bool", "true"])
        sleepMS(1500)
    }
    defer {
        if original == nil {
            _ = run("/usr/bin/defaults", ["delete", "com.gokoding.Copi", "allowClipboardFallback"])
        } else if original != "1" {
            _ = run("/usr/bin/defaults", ["write", "com.gokoding.Copi", "allowClipboardFallback", "-bool", "false"])
        }
        sleepMS(1500)
        let restored = copiDefault("allowClipboardFallback") == original
        record("6.9", "allowClipboardFallback 恢复成测试前的值", restored ? "PASS" : "FAIL", "测试前=\(original ?? "没设过")，现在=\(copiDefault("allowClipboardFallback") ?? "没设过")")
    }
    // 三轮：对照组粘贴（经剪贴板、不询问）之后马上打开屏幕共享，再复制一段新文字、粘贴两次。
    // 上一轮这里第二次粘贴出了对照组的旧文字，只偶尔出现：每轮文字都不一样，Copi 的诊断日志里分得清
    for round in 1...3 {
        let controlText = "f(x) { return [1, \(round)]; }"
        try loadCopi(controlText, "src-vm-control-\(round).txt", &openedWindows)
        let controlPage = try openPage(helperBrowser, mode: "focus-ce")
        openedWindows.append(controlPage)
        try gate(controlPage)
        chord(keyV(), cmd)
        // 屏幕共享在对照组的文字刚挂到剪贴板上时就打开（不连接任何电脑）
        _ = run("/usr/bin/open", ["-a", "Screen Sharing"])
        let (controlStatus, controlNote) = fieldResult(controlPage, field: "ce", expected: controlText)
        record("6.0.\(round)", "对照：允许回退、没有远程桌面时，代码编辑器里第一次 ⌘V 就粘贴", controlStatus, controlNote)
        sleepMS(3000)
        defer {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: screenSharing) {
                app.terminate()
            }
            sleepMS(1500)
            // 没连接任何电脑的屏幕共享里没有要保存的东西：还在就强制退出
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: screenSharing) {
                app.forceTerminate()
            }
            sleepMS(500)
        }
        guard !pids(screenSharing).isEmpty else {
            record("6.1.\(round)", "虚拟机/远程桌面在运行时先询问", "SKIP", "屏幕共享没有打开")
            continue
        }
        let text = "g(y) { return [3, \(round)]; }"
        try loadCopi(text, "src-vm-\(round).txt", &openedWindows)
        let page = try openPage(helperBrowser, mode: "focus-ce")
        openedWindows.append(page)
        try gate(page)
        chord(keyV(), cmd)
        sleepMS(1500)
        let titleBeforeSecond = axString(page.window, kAXTitleAttribute) ?? ""
        let afterFirst = titleBeforeSecond.contains("COPI|ce|")
        try gate(page)
        chord(keyV(), cmd)
        let (status, note) = fieldResult(page, field: "ce", expected: text)
        // 直接读网页里代码编辑器的内容，和标题对照
        let editorValue = findDescendant(page.window, maxDepth: 30, { axString($0, "AXDOMIdentifier") == "ce" }).flatMap { axString($0, kAXValueAttribute) }
        let editorIs = editorValue == text ? "新的这段" : (editorValue == controlText ? "对照组的旧" : (editorValue.map { "别的 \($0.utf16.count) 字符" } ?? "读不到"))
        record("6.1.\(round)", "屏幕共享在运行：经剪贴板的粘贴先询问，8 秒内再按一次才粘贴", !afterFirst && status == "PASS" ? "PASS" : "FAIL",
               "第一次 ⌘V 后粘贴了=\(afterFirst)；第二次：\(note)；网页编辑器里实际是\(editorIs)文字")
        // 之后再看 Copi 里是什么（粘贴进 TextEdit 不经过剪贴板，不用询问）
        let held = try pasteIntoNewTextEdit("dst-vm-held-\(round).txt", &openedWindows)
        record("6.1c.\(round)", "屏幕共享在运行：之后 Copi 里是刚复制的文字", held == text ? "PASS" : "FAIL",
               held == controlText ? "粘贴出来的是对照组的旧文字" : describeDiff(held, text))
    }
}

// MARK: - Slack

func slackTests(_ openedWindows: inout [TestWindow]) throws {
    let slack = ("com.tinyspeck.slackmacgap", "Slack")
    guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: slack.0) != nil else {
        record("S", "Slack", "SKIP", "没有安装")
        return
    }
    // 原来没开着：测完退出
    let wasRunning = !pids(slack.0).isEmpty
    if !wasRunning {
        _ = run("/usr/bin/open", ["-a", slack.1])
        sleepMS(9000)
    }
    defer {
        if !wasRunning {
            NSRunningApplication.runningApplications(withBundleIdentifier: slack.0).forEach { $0.terminate() }
        }
    }
    guard let pid = pids(slack.0).first,
          let window = axElement(ax(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute)) ?? windows(pid).first else {
        record("S", "Slack", "SKIP", "Slack 没有窗口")
        return
    }
    let target = TestWindow(bundleID: slack.0, appName: slack.1, pid: pid, window: window)
    // Electron App 默认不建网页部分的无障碍树：像读屏软件一样请它建
    AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), "AXManualAccessibility" as CFString, kCFBooleanTrue)
    bringToFront(target)
    sleepMS(2500)
    guard let windowFrame = frame(window) else {
        record("S", "Slack", "SKIP", "读不到 Slack 窗口的位置")
        return
    }
    // 输入框：窗口里最下面、够宽的文本区域
    func findComposer() -> (element: AXUIElement, frame: CGRect)? {
        findAll(window, maxDepth: 45, limit: 15000) { role($0) == kAXTextAreaRole }
            .compactMap { element in frame(element).map { (element, $0) } }
            .filter { windowFrame.contains(center($0.1)) && $0.1.width > 200 && $0.1.height > 16 }
            .max { $0.1.maxY < $1.1.maxY }
    }
    var composerFound = findComposer()
    for _ in 0..<10 where composerFound == nil {
        sleepMS(1000)
        composerFound = findComposer()
    }
    guard let found = composerFound else {
        let areas = findAll(window, maxDepth: 45, limit: 15000) { role($0) == kAXTextAreaRole }.count
        let webAreas = findAll(window, maxDepth: 45, limit: 15000) { role($0) == "AXWebArea" }.count
        record("S", "Slack", "SKIP", "找不到输入框（文本区域 \(areas) 个、网页区域 \(webAreas) 个；没有打开频道，或者网页部分的无障碍树没建好）")
        return
    }
    let composer = found.element
    let composerFrame = found.frame
    func focusIsComposer() -> Bool {
        isWithin(focusedElement(pid), composer)
    }

    // 复制一条消息：消息区里最下面一行文字。用无障碍接口直接设好选区（不点鼠标，不会点到链接、按钮），只记长度
    let lines = findAll(window, maxDepth: 45, limit: 15000) { element in
        guard role(element) == kAXStaticTextRole, let f = frame(element), let value = axString(element, kAXValueAttribute) else {
            return false
        }
        return f.minX >= composerFrame.minX - 8 && f.maxX <= composerFrame.maxX + 8 && f.maxY < composerFrame.minY - 30
            && f.minY > windowFrame.minY + 90 && f.height < 30 && f.width > 80 && (15...300).contains(value.count)
    }.sorted { (frame($0)?.minY ?? 0) > (frame($1)?.minY ?? 0) }
    func webArea(of element: AXUIElement) -> AXUIElement? {
        var node = axElement(ax(element, kAXParentAttribute))
        for _ in 0..<45 {
            guard let current = node else {
                return nil
            }
            if role(current) == "AXWebArea" {
                return current
            }
            node = axElement(ax(current, kAXParentAttribute))
        }
        return nil
    }
    var selectedLine: (element: AXUIElement, length: Int)?
    for line in lines.prefix(5) {
        guard let area = webArea(of: line) else {
            continue
        }
        var range: CFTypeRef?
        let rangeResult = AXUIElementCopyParameterizedAttributeValue(area, "AXTextMarkerRangeForUIElement" as CFString, line, &range)
        guard rangeResult == .success, let range else {
            continue
        }
        AXUIElementSetAttributeValue(area, "AXSelectedTextMarkerRange" as CFString, range)
        sleepMS(400)
        var selectedLength: CFTypeRef?
        if let selected = ax(area, "AXSelectedTextMarkerRange") {
            AXUIElementCopyParameterizedAttributeValue(area, "AXLengthForTextMarkerRange" as CFString, selected, &selectedLength)
        }
        if let length = (selectedLength as? NSNumber)?.intValue, length > 0 {
            selectedLine = (line, (axString(line, kAXValueAttribute) ?? "").utf16.count)
            break
        }
    }
    if let selectedLine {
        let lineLength = selectedLine.length
        // 不管怎么结束，都把 Copi 里的这条消息换成测试文字
        defer { try? loadCopi("Copi test 123", "src-slack.txt", &openedWindows) }
        let sampler = PasteboardSampler(.general)
        try gate(target)
        chord(keyC(), cmd)
        sleepMS(500)
        sampler.stop()
        // 粘贴到测试页的 textarea（不落盘），只比长度；读完马上清空、关掉这个标签页
        let page = try openPage(helperBrowser, mode: "focus-ta")
        // 不管怎么结束，都清空测试页的 textarea（只在当前标签页确实是测试页时，按元素 id 找），再关掉这个标签页
        var pageClosed = false
        func clearAndClosePage() {
            guard !pageClosed else {
                return
            }
            pageClosed = true
            if (axString(page.window, kAXTitleAttribute) ?? "").contains("COPI|"),
               let field = findDescendant(page.window, maxDepth: 30, { axString($0, "AXDOMIdentifier") == "ta" }) {
                AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, "" as CFString)
                sleepMS(300)
            }
            closeTab(page)
        }
        defer { clearAndClosePage() }
        try gate(page)
        chord(keyV(), cmd)
        let title = waitTitle(page, prefix: "COPI|ta|") ?? ""
        clearAndClosePage()
        let pastedLength = title.contains("COPI|ta|") ? title.range(of: "len=").flatMap { Int(title[$0.upperBound...].prefix { $0.isNumber }) } ?? 0 : 0
        let ok = sampler.firstSeenMS == nil && pastedLength >= lineLength - 3 && pastedLength <= lineLength + 3
        record("S.1", "Slack 复制一条消息的文字（⌘C）", ok ? "PASS" : "FAIL",
               "选中的一行 \(lineLength) 字符，Copi 粘贴出 \(pastedLength) 字符；\(sampler.summary)")
    } else {
        record("S.1", "Slack 复制一条消息", "SKIP", "消息区里找到 \(lines.count) 行文字，但设不上选区")
    }

    // 粘贴进输入框（不发送）。输入框必须读得到、而且是空的；点进去之后焦点必须确实在它上面
    bringToFront(target)
    sleepMS(600)
    guard let draft = axString(composer, kAXValueAttribute) else {
        record("S.2", "Slack 粘贴进输入框", "SKIP", "读不到输入框内容，不动它")
        return
    }
    guard draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        record("S.2", "Slack 粘贴进输入框", "SKIP", "输入框里已经有你的草稿，不动它")
        return
    }
    let text = "Copi test 123"
    try loadCopi(text, "src-slack-paste.txt", &openedWindows)
    bringToFront(target)
    let clickPoint = center(composerFrame)
    guard isWithin(elementAt(clickPoint), composer) else {
        record("S.2", "Slack 粘贴进输入框", "SKIP", "输入框中间那一点不是输入框本身，不点")
        return
    }
    try gate(target)
    click(clickPoint)
    sleepMS(500)
    guard focusIsComposer() else {
        record("S.2", "Slack 粘贴进输入框", "SKIP", "点了之后焦点不在输入框上，没有粘贴")
        return
    }
    // 只清掉恰好是测试文字的内容（中止时也清）；绝不按回车
    var cleared = false
    func clearTestText() {
        guard !cleared else {
            return
        }
        let current = axString(composer, kAXValueAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if current == "" {
            cleared = true
            return
        }
        guard current == text, focusIsComposer(), (try? gate(target)) != nil else {
            return
        }
        chord(keyA(), cmd)
        chord(CGKeyCode(kVK_Delete))
        sleepMS(600)
        cleared = axString(composer, kAXValueAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines) == ""
    }
    defer { clearTestText() }
    try gate(target)
    chord(keyV(), cmd)
    sleepMS(1500)
    let value = axString(composer, kAXValueAttribute)
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
    // 从输入框里复制（里面正好是测试文字时）：全选、⌘C，之后粘贴进 TextEdit 比对
    var composerCopy: String?? = nil
    if trimmed == text, focusIsComposer(), (try? gate(target)) != nil {
        try loadCopi("Copi slack sentinel", "src-slack-sentinel.txt", &openedWindows)
        bringToFront(target)
        if focusIsComposer(), (try? gate(target)) != nil {
            chord(keyA(), cmd)
            let composerSampler = PasteboardSampler(.general)
            chord(keyC(), cmd)
            sleepMS(500)
            composerSampler.stop()
            composerCopy = .some(try pasteIntoNewTextEdit("dst-slack-composer.txt", &openedWindows))
            bringToFront(target)
        }
    }
    clearTestText()
    let status = trimmed == nil ? "CHECK" : (trimmed == text ? "PASS" : "FAIL")
    record("S.2", "Slack 粘贴进输入框（不发送）", status,
           "输入框里\(trimmed == text ? "正好是" : "不是")粘贴的测试文字（内容长度 \(value?.utf16.count ?? -1)）；测完清空=\(cleared)\(cleared ? "" : "（请看一眼 Slack 输入框，把测试文字删掉）")；没有按回车，没有发送")
    if let copied = composerCopy {
        record("S.3", "Slack 输入框里 ⌘A ⌘C", copied == text ? "PASS" : "FAIL",
               copied == "Copi slack sentinel" ? "Copi 里还是复制之前放的那段（没复制上）" : describeDiff(copied, text))
    } else {
        record("S.3", "Slack 输入框里 ⌘A ⌘C", "SKIP", "输入框里不是测试文字，或者焦点不在输入框上")
    }
}

// MARK: - VS Code Copi Bridge

// 打开 Copi 的面板，在里面读东西，再关掉
func copiPanel(_ body: (AXUIElement) -> Void) {
    guard let menu = openCopiMenu() else {
        return
    }
    body(menu.app)
    closeCopiMenu(menu.pid)
}

// Copi 面板是滚动的列表：滚到看不见的行可能不在无障碍树里。先直接找，找不到就从上到下滚几次再找
func findInCopiPanel(_ app: AXUIElement, _ predicate: (AXUIElement) -> Bool) -> AXUIElement? {
    if let found = findAll(app, maxDepth: 40, limit: 30000, predicate).first {
        return found
    }
    for area in findAll(app, maxDepth: 25, limit: 30000, { role($0) == kAXScrollAreaRole }) {
        guard let bar = axElement(ax(area, kAXVerticalScrollBarAttribute)) else {
            continue
        }
        for position in [0.25, 0.5, 0.75, 1.0] {
            AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, NSNumber(value: position))
            sleepMS(350)
            if let found = findAll(app, maxDepth: 40, limit: 30000, predicate).first {
                return found
            }
        }
    }
    return nil
}

// 焦点在 VS Code 的终端里（xterm 的输入框）
func focusIsXterm(_ pid: pid_t) -> Bool {
    var node = focusedElement(pid)
    for _ in 0..<5 {
        guard let current = node else {
            return false
        }
        if let classes = ax(current, "AXDOMClassList") as? [String], classes.contains("xterm-helper-textarea") || classes.contains("xterm") {
            return true
        }
        node = axElement(ax(current, kAXParentAttribute))
    }
    return false
}

func vscodeTests(_ openedWindows: inout [TestWindow]) throws {
    let vscode = ("com.microsoft.VSCode", "Visual Studio Code")
    guard let vscodeApp = NSWorkspace.shared.urlForApplication(withBundleIdentifier: vscode.0) else {
        record("V", "VS Code", "SKIP", "没有安装")
        return
    }
    let cli = vscodeApp.appendingPathComponent("Contents/Resources/app/bin/code")
    guard FileManager.default.isExecutableFile(atPath: cli.path) else {
        record("V", "VS Code", "SKIP", "找不到 VS Code 自带的命令行工具")
        return
    }
    let extensions = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".vscode/extensions")
    // 这一版 Copi 自带的 Bridge（EditorBridge.swift 的 EditorBridgeExtension.version）
    let currentBridge = "copi.copi-bridge-1.2.1"
    func bridgeInstalled() -> Bool {
        ((try? FileManager.default.contentsOfDirectory(atPath: extensions.path)) ?? []).contains { $0.lowercased() == currentBridge }
    }
    func vscodeRow(_ app: AXUIElement) -> CGRect? {
        findInCopiPanel(app) { role($0) == kAXStaticTextRole && axString($0, kAXValueAttribute) == vscode.1 }.flatMap { frame($0) }
    }
    // VS Code 那一行显示的状态（Copi 的固定几个词）
    func vscodeStatus(_ app: AXUIElement, row: CGRect) -> String {
        findAll(app, maxDepth: 40, limit: 30000) { element in
            role(element) == kAXStaticTextRole && ["Connected", "Outdated", "Installed", "Not installed"].contains(axString(element, kAXValueAttribute) ?? "")
                && abs((frame(element)?.midY ?? 9999) - row.midY) < 20
        }.first.flatMap { axString($0, kAXValueAttribute) } ?? "没找到"
    }
    // 在 Copi 菜单 › Editor Bridge 里点 VS Code 那一行的 Install
    var pressed = false
    var rowFound = false
    let installedBefore = bridgeInstalled()
    if !installedBefore {
        copiPanel { app in
            guard let labelFrame = vscodeRow(app) else {
                return
            }
            rowFound = true
            let buttons = findAll(app, maxDepth: 40, limit: 30000) { element in
                role(element) == kAXButtonRole
                    && [axString(element, kAXTitleAttribute), axString(element, kAXDescriptionAttribute)].contains { ["Install", "Reinstall"].contains($0 ?? "") }
            }
            if let row = buttons.min(by: { abs((frame($0)?.midY ?? 9999) - labelFrame.midY) < abs((frame($1)?.midY ?? 9999) - labelFrame.midY) }),
               abs((frame(row)?.midY ?? 9999) - labelFrame.midY) < 20 {
                pressed = AXUIElementPerformAction(row, kAXPressAction as CFString) == .success
            }
            if pressed {
                for _ in 0..<120 where !bridgeInstalled() {
                    sleepMS(1000)
                }
            }
        }
    }
    if installedBefore {
        record("V.0", "VS Code：Copi Bridge 已安装", "PASS", "这一版的扩展本来就装着")
    } else {
        record("V.0", "VS Code：在 Copi 菜单里安装 Copi Bridge", bridgeInstalled() ? "PASS" : (pressed ? "FAIL" : "SKIP"),
               pressed ? "点了 Install，扩展已装好=\(bridgeInstalled())" : (rowFound ? "VS Code 那一行找不到 Install 按钮" : "Copi 面板里找不到 VS Code 那一行"))
    }
    guard bridgeInstalled() else {
        return
    }

    // 单独开一个 VS Code（自己的用户数据目录）：不动你开着的 VS Code、它的窗口和终端。扩展目录是同一个，所以 Bridge 也会加载
    let userData = fixtures.appendingPathComponent("vscode-ud")
    let userSettings = userData.appendingPathComponent("User")
    try? FileManager.default.createDirectory(at: userSettings, withIntermediateDirectories: true)
    let settings: [String: Any] = [
        "window.restoreWindows": "none",
        "security.workspace.trust.enabled": false,
        "workbench.startupEditor": "none",
        "workbench.tips.enabled": false,
        "workbench.enableExperiments": false,
        "telemetry.telemetryLevel": "off",
        "update.mode": "none",
        "update.showReleaseNotes": false,
        "workbench.secondarySideBar.defaultVisibility": "hidden",
        "chat.disableAIFeatures": true,
        "extensions.autoCheckUpdates": false,
        "extensions.autoUpdate": false,
        "git.enabled": false,
        "files.insertFinalNewline": false,
        "editor.formatOnPaste": false,
        "terminal.integrated.enablePersistentSessions": false,
        "terminal.integrated.confirmOnExit": "never",
        "terminal.integrated.confirmOnKill": "never",
        "terminal.integrated.cwd": fixtures.path,
        // 终端里跑测试用的 zsh：不读你的配置，不写你的历史记录
        "terminal.integrated.profiles.osx": ["copitest": ["path": "/bin/zsh", "args": ["-i"], "env": ["ZDOTDIR": fixtures.appendingPathComponent("zdot").path]]],
        "terminal.integrated.defaultProfile.osx": "copitest",
    ]
    if let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted]) {
        try? data.write(to: userSettings.appendingPathComponent("settings.json"))
    }
    // 单独的扩展目录，里面只有 Copi Bridge：新的配置里别的扩展会打开欢迎页，换掉当前编辑器
    let privateExtensions = fixtures.appendingPathComponent("vscode-ext")
    try? FileManager.default.removeItem(at: privateExtensions)
    try? FileManager.default.createDirectory(at: privateExtensions, withIntermediateDirectories: true)
    let bridgeCopy = privateExtensions.appendingPathComponent(currentBridge)
    try? FileManager.default.copyItem(at: extensions.appendingPathComponent(currentBridge), to: bridgeCopy)
    let extensionList: [[String: Any]] = [[
        "identifier": ["id": "copi.copi-bridge"], "version": String(currentBridge.dropFirst("copi.copi-bridge-".count)),
        "location": ["$mid": 1, "path": bridgeCopy.path, "scheme": "file"], "relativeLocation": currentBridge,
    ]]
    if let data = try? JSONSerialization.data(withJSONObject: extensionList) {
        try? data.write(to: privateExtensions.appendingPathComponent("extensions.json"))
    }
    var environment = ProcessInfo.processInfo.environment
    for name in ["VSCODE_IPC_HOOK_CLI", "ELECTRON_RUN_AS_NODE", "NODE_OPTIONS", "VSCODE_CWD", "VSCODE_PID"] {
        environment[name] = nil
    }
    func codeCLI(_ arguments: [String]) {
        let process = Process()
        process.executableURL = cli
        process.arguments = ["--user-data-dir", userData.path, "--extensions-dir", privateExtensions.path] + arguments
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        let deadline = Date().addingTimeInterval(30)
        while process.isRunning, Date() < deadline {
            sleepMS(100)
        }
    }
    let sourceText = "alpha line\n    beta(1) indented\ngamma\n"
    let source = writeFixture("vsc-src.txt", sourceText)
    let destination = writeFixture("vsc-dst.txt", "")
    let before = Set(pids(vscode.0))
    codeCLI(["--new-window", source.path])
    var ours: Set<pid_t> = []
    defer {
        // 只结束这个单独开的 VS Code
        for pid in ours {
            NSRunningApplication(processIdentifier: pid)?.terminate()
        }
        for _ in 0..<20 where ours.contains(where: { NSRunningApplication(processIdentifier: $0) != nil }) {
            sleepMS(250)
        }
        for pid in ours {
            NSRunningApplication(processIdentifier: pid)?.forceTerminate()
        }
    }
    func editorWindow(_ name: String, timeout: TimeInterval) -> TestWindow? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            // 只认命令行里带着测试用户数据目录的新进程
            ours = Set(pids(vscode.0)).subtracting(before).filter { run("/bin/ps", ["-o", "args=", "-p", "\($0)"]).output.contains(userData.path) }
            for pid in ours {
                for window in windows(pid) where (axString(window, kAXTitleAttribute) ?? "").contains(name) {
                    var target = TestWindow(bundleID: vscode.0, appName: vscode.1, pid: pid, window: window)
                    // 发按键前确认当前编辑器还是这个测试文件
                    target.titleCheck = { $0.contains(name) }
                    return target
                }
            }
            sleepMS(250)
        }
        return nil
    }
    guard let editor = editorWindow("vsc-src.txt", timeout: 40) else {
        record("V", "VS Code", "SKIP", "单独开的 VS Code 没有打开测试文件")
        return
    }
    AXUIElementSetAttributeValue(AXUIElementCreateApplication(editor.pid), "AXManualAccessibility" as CFString, kCFBooleanTrue)
    bringToFront(editor)
    // 等 Bridge 连上 Copi：每 3 秒看一次 Copi 菜单，最多 30 秒
    var connected = false
    var lastStatus = "没打开 Copi 面板"
    for _ in 0..<10 where !connected {
        sleepMS(3000)
        copiPanel { app in
            if let labelFrame = vscodeRow(app) {
                lastStatus = vscodeStatus(app, row: labelFrame)
                connected = lastStatus == "Connected"
            } else {
                lastStatus = "面板里找不到 VS Code 那一行"
            }
        }
    }
    record("V.1", "VS Code 打开后 Copi Bridge 显示 Connected", connected ? "PASS" : "FAIL",
           "Copi 面板里 VS Code 那一行最后显示「\(lastStatus)」")
    guard connected else {
        record("V.2", "VS Code 编辑器、终端里的复制粘贴", "SKIP", "Bridge 没有连上")
        return
    }

    // 编辑器里复制（⌘1：焦点放到编辑器上）
    bringToFront(editor)
    try gate(editor)
    chord(CGKeyCode(kVK_ANSI_1), cmd)
    try gate(editor)
    chord(keyA(), cmd)
    let copySampler = PasteboardSampler(.general)
    try gate(editor)
    chord(keyC(), cmd)
    sleepMS(600)
    copySampler.stop()
    let copied = try pasteIntoNewTextEdit("dst-vsc-copy.txt", &openedWindows)
    record("V.2", "VS Code 编辑器里 ⌘C（经 Copi Bridge）", copied == sourceText && copySampler.firstSeenMS == nil ? "PASS" : "FAIL",
           "\(copySampler.summary)；\(describeDiff(copied, sourceText))")

    // 编辑器里粘贴（多行、带缩进），保存后读文件
    let pasteText = "first\n    second(2)\nthird"
    try loadCopi(pasteText, "src-vsc-paste.txt", &openedWindows)
    codeCLI(["--reuse-window", destination.path])
    guard let destinationEditor = editorWindow("vsc-dst.txt", timeout: 20) else {
        record("V.3", "VS Code 编辑器里 ⌘V", "SKIP", "VS Code 没有打开 vsc-dst.txt")
        return
    }
    bringToFront(destinationEditor)
    sleepMS(1200)
    try gate(destinationEditor)
    chord(CGKeyCode(kVK_ANSI_1), cmd)
    try gate(destinationEditor)
    chord(keyV(), cmd)
    sleepMS(1200)
    try gate(destinationEditor)
    chord(CGKeyCode(kVK_ANSI_S), cmd)
    sleepMS(1200)
    let saved = try? String(contentsOf: destination, encoding: .utf8)
    record("V.3", "VS Code 编辑器里 ⌘V（多行、带缩进，经 Copi Bridge）", saved == pasteText || saved == pasteText + "\n" ? "PASS" : "FAIL",
           saved == pasteText + "\n" ? "内容一致（保存时末尾多了一个换行，是编辑器设置）" : describeDiff(saved, pasteText))

    // 集成终端里粘贴：插入不执行，回车后命令完整。⌃⇧` 总是新开一个终端（跑测试用的 zsh）
    let markers = fixtures.appendingPathComponent("markers")
    try? FileManager.default.createDirectory(at: markers, withIntermediateDirectories: true)
    let marker = markers.appendingPathComponent("vsc-term")
    try? FileManager.default.removeItem(at: marker)
    try loadCopi("touch '\(marker.path)'", "src-vsc-term.txt", &openedWindows)
    bringToFront(destinationEditor)
    try gate(destinationEditor)
    chord(CGKeyCode(kVK_ANSI_Grave), [CGKeyCode(kVK_Shift): .maskShift, CGKeyCode(kVK_Control): .maskControl])
    sleepMS(3500)
    guard focusIsXterm(destinationEditor.pid) else {
        record("V.4", "VS Code 集成终端里 ⌘V", "SKIP", "新开终端之后焦点不在终端里，没有粘贴")
        return
    }
    try gate(destinationEditor)
    chord(keyV(), cmd)
    sleepMS(2500)
    let ranEarly = FileManager.default.fileExists(atPath: marker.path)
    guard focusIsXterm(destinationEditor.pid) else {
        record("V.4", "VS Code 集成终端里 ⌘V", "SKIP", "粘贴之后焦点不在终端里，没有按回车（按回车前就被执行了=\(ranEarly)）")
        return
    }
    try gate(destinationEditor)
    pressReturn()
    sleepMS(2000)
    let ranAfter = FileManager.default.fileExists(atPath: marker.path)
    record("V.4", "VS Code 集成终端里 ⌘V（经 Copi Bridge）", !ranEarly && ranAfter ? "PASS" : "FAIL",
           "按回车前就被执行了=\(ranEarly)；按回车后命令完整执行=\(ranAfter)")
}

// MARK: - 密码管理器式的复制（测试程序自己写一段带 Concealed 标记的假密码，不是真的密码管理器）

// 粘贴进新的 TextEdit 文档，"应该为空"的检查用：不为空就马上清掉，免得存进文件
func pasteExpectingEmpty(_ name: String, _ openedWindows: inout [TestWindow]) throws -> Bool? {
    let value = try pasteIntoNewTextEdit(name, &openedWindows)
    if let value, !value.isEmpty, let window = openedWindows.last, (try? gate(window)) != nil {
        chord(keyA(), cmd)
        chord(CGKeyCode(kVK_Delete))
        sleepMS(300)
    }
    return value.map { $0.isEmpty }
}

func concealedTests(_ openedWindows: inout [TestWindow]) throws {
    let secret = "copi-dummy-secret-7"
    // Copi 不收"上一次复制之后 3 秒内、用户没有操作时"出现在剪贴板上的内容（防剪贴板劫持）：先等过这 3 秒
    sleepMS(3300)
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    let item = NSPasteboardItem()
    item.setString(secret, forType: .string)
    item.setData(Data(), forType: concealedType)
    pasteboard.writeObjects([item])
    let copiedAt = Date()
    // 同一个线程上取样：文字在系统剪贴板上停了多久
    var first: Int?
    var last: Int?
    while Date().timeIntervalSince(copiedAt) < 0.5 {
        if pasteboardHasText(pasteboard) {
            let ms = Int(Date().timeIntervalSince(copiedAt) * 1000)
            first = first ?? ms
            last = ms
        }
        usleep(1000)
    }
    let exposure = first.map { (last ?? $0) - $0 + 1 } ?? 0
    let limit = copiBool("constantFastCheck", false) ? 10 : (copiBool("instantClipboardDetection", true) ? 15 : 35)
    let stillThere = pasteboardHasText(.general)
    let c1 = stillThere || exposure > 50 ? "FAIL" : (exposure <= limit ? "PASS" : "CHECK")
    record("C.1", "密码管理器式的复制（带 Concealed 标记）：Copi 挪走", c1,
           "测试程序自己写进去的假密码；文字在系统剪贴板上约 \(exposure) ms（PASS 的界限 \(limit) ms）；现在系统剪贴板上有文字=\(stillThere)")

    // 普通输入框：照常粘贴（同时确认 Copi 里确实是这段假密码）
    let normal = try pasteIntoNewTextEdit("dst-concealed.txt", &openedWindows)
    let c4 = normal == secret
    record("C.4", "密码管理器的复制粘贴到普通输入框：照常粘贴", c4 ? "PASS" : "FAIL", describeDiff(normal, secret))

    // 地址栏、Spotlight：只有 Copi 里确实是这段假密码、系统剪贴板上没有文字时才测（⌘V 只可能粘出这段假密码）
    if c1 == "FAIL" || !c4 || pasteboardHasText(.general) {
        record("C.2", "密码管理器的复制粘贴到地址栏、Spotlight", "SKIP", "Copi 里没有这段假密码，或者系统剪贴板上还有文字：不往地址栏、Spotlight 粘贴")
    } else {
        // 浏览器地址栏：先询问（只按一次）
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: helperBrowser.0) != nil {
            let page = try openPage(helperBrowser, mode: "plain")
            openedWindows.append(page)
            try gate(page)
            chord(CGKeyCode(kVK_ANSI_L), cmd)
            sleepMS(500)
            try gate(page)
            chord(keyV(), cmd)
            sleepMS(1500)
            let after = focusedElementValue(page.pid)
            let pasted = (after ?? "").contains(secret)
            try gate(page)
            chord(CGKeyCode(kVK_Escape))
            chord(CGKeyCode(kVK_Escape))
            record("C.2", "密码管理器的复制粘贴到浏览器地址栏：先询问", after == nil ? "CHECK" : (pasted ? "FAIL" : "PASS"),
                   after == nil ? "读不到地址栏的内容" : "第一次 ⌘V 后地址栏里出现了这段假密码=\(pasted)；只按了一次")
        }
        // Spotlight：先询问（⌘Space 前焦点在测试程序自己的 TextEdit 窗口上）
        if let window = openedWindows.last(where: { $0.bundleID == textEdit.0 }) {
            bringToFront(window)
            try gate(window)
            chord(CGKeyCode(kVK_Space), cmd)
            sleepMS(900)
            let focused = focusedApp()
            let id = focused?.bundleID ?? "nil"
            // 系统自己的界面（com.apple.*）、Copi 认的启动器才写出 bundle ID
            let shownID = id == "nil" || id.hasPrefix("com.apple.") || knownAppIDs.contains(id) ? id : "其他 App"
            let launchers = ["com.apple.Spotlight", "com.raycast.macos", "com.runningwithcrayons.Alfred"]
            // 系统界面时再记下焦点控件的角色（Copi 对 AXSearchField 也会先询问）
            let element = focused.flatMap { focusedElement($0.pid) }
            let isSearchField = element.flatMap { axString($0, kAXSubroleAttribute) } == "AXSearchField"
            if let focused, launchers.contains(id) || (id.hasPrefix("com.apple.") && isSearchField) {
                chord(keyV(), cmd)
                sleepMS(1500)
                let value = focusedElementValue(focused.pid)
                for _ in 0..<2 where focusedApp()?.bundleID == id {
                    chord(CGKeyCode(kVK_Escape))
                    sleepMS(300)
                }
                record("C.3", "密码管理器的复制粘贴到 Spotlight（\(id)）：先询问", value == nil ? "CHECK" : (value!.contains(secret) ? "FAIL" : "PASS"),
                       value == nil ? "读不到输入框的内容" : "第一次 ⌘V 后输入框里出现了这段假密码=\(value!.contains(secret))；只按了一次")
            } else {
                // 打开的是别的系统界面：再按一次 ⌘Space 把它关掉（不往里面发别的键）
                if id != textEdit.0, id == "nil" || id.hasPrefix("com.apple.") {
                    chord(CGKeyCode(kVK_Space), cmd)
                    sleepMS(600)
                }
                _ = ["com.apple.keylayout.ABC", "com.apple.keylayout.US"].first { selectInputSource($0) }
                record("C.3", "密码管理器的复制粘贴到 Spotlight", "SKIP",
                       "⌘Space 之后焦点在 \(shownID)（不是 Copi 认的启动器 \(launchers.joined(separator: "、"))），没有粘贴")
            }
            bringToFront(window)
        }
    }

    // 90 秒后清除：80 秒时还在（对照），92 秒时没了
    notify("接下来约 90 秒请不要复制任何东西（测试 Copi 90 秒后清除密码）。")
    let early = 80 - Date().timeIntervalSince(copiedAt)
    if early > 0 {
        Thread.sleep(forTimeInterval: early)
    }
    let stillHeld = try pasteIntoNewTextEdit("dst-concealed-80s.txt", &openedWindows)
    let wait = 92 - Date().timeIntervalSince(copiedAt)
    if wait > 0 {
        log("waiting \(Int(wait)) s for the concealed copy to expire")
        Thread.sleep(forTimeInterval: wait)
    }
    let expired = try pasteExpectingEmpty("dst-concealed-expired.txt", &openedWindows)
    let c5 = stillHeld != secret ? "SKIP" : (expired == nil ? "CHECK" : (expired! ? "PASS" : "FAIL"))
    record("C.5", "密码管理器的复制 90 秒后从 Copi 清除", c5,
           "80 秒时还能粘贴出这段假密码=\(stillHeld == secret)；92 秒后 ⌘V 粘贴为空=\(expired.map { "\($0)" } ?? "读不到")")
}

// MARK: - 锁屏（需要用户锁屏、解锁一次）

func screenIsLocked() -> Bool {
    (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool == true
}

func lockTest(_ openedWindows: inout [TestWindow]) throws {
    guard copiBool("clearOnLock", true) else {
        record("8", "锁屏后 Copi 剪贴板清空", "N/A", "Copi 的 Clear Copi Clipboard When Mac Locks 关着")
        return
    }
    try loadCopi("lock test text", "src-lock.txt", &openedWindows)
    // 对照：锁屏前 Copi 里确实是这段文字
    let control = try pasteIntoNewTextEdit("dst-lock-before.txt", &openedWindows)
    guard control == "lock test text" else {
        record("8", "锁屏后 Copi 剪贴板清空", "SKIP", "锁屏前 Copi 里就没有测试文字（\(describeDiff(control, "lock test text"))）")
        return
    }
    notify("现在请按 ⌃⌘Q 锁屏，然后马上解锁（2 分钟内）。解锁后几秒内请不要复制东西。")
    log("waiting for the user to lock the screen")
    var locked = false
    for _ in 0..<240 {
        if screenIsLocked() {
            locked = true
            break
        }
        sleepMS(500)
    }
    guard locked else {
        record("8", "锁屏后 Copi 剪贴板清空", "SKIP", "2 分钟内没有锁屏")
        return
    }
    for _ in 0..<360 where screenIsLocked() {
        sleepMS(500)
    }
    sleepMS(3000)
    let empty = try pasteExpectingEmpty("dst-lock.txt", &openedWindows)
    record("8", "锁屏、解锁后 Copi 剪贴板已清空", empty == nil ? "CHECK" : (empty! ? "PASS" : "FAIL"),
           "锁屏前能粘贴出测试文字；解锁后 ⌘V 粘贴为空=\(empty.map { "\($0)" } ?? "读不到")")
}
