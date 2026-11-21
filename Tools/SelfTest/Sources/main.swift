// CopiSelfTest：自动驱动真实的系统按键/鼠标事件，测试 Copi 的复制粘贴。
// 只操作它自己在 build/selftest/fixtures 下生成的文件、网页和终端窗口；每次发按键前确认前台窗口确实是测试窗口，否则整轮中止。
// 只读剪贴板的类型（不读内容）。报告写到 build/selftest/report.md。

import AppKit
import ApplicationServices
import Carbon
import IOKit
import IOKit.pwr_mgt

// MARK: - 路径、日志、报告

let appURL = Bundle.main.bundleURL
let baseDir = appURL.deletingLastPathComponent()
let fixtures = baseDir.appendingPathComponent("fixtures")
let reportURL = baseDir.appendingPathComponent("report.md")
let logURL = baseDir.appendingPathComponent("run.log")
let startTime = Date()
// 只跑指定的几组（run.sh --only=basic,browsers,browsermore,terminal,sudo,guard,watchdog,iterm,vm,slack,vscode,matrix,concealed,secure,lock）
let onlyGroups: Set<String>? = CommandLine.arguments.first { $0.hasPrefix("--only=") }
    .map { Set($0.dropFirst("--only=".count).split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }) }
func wants(_ group: String) -> Bool {
    onlyGroups?.contains(group) ?? true
}
// 矩阵里只跑指定的几项（--cases=K.11,K.11m）：查一项时不用整组重跑
let onlyCases: Set<String>? = CommandLine.arguments.first { $0.hasPrefix("--cases=") }
    .map { Set($0.dropFirst("--cases=".count).split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }) }

// 在 GitHub Actions 的虚拟机上跑（一次性的机器，没有个人信息）
let onCI = ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true"

// 这一轮的标记：测试终端的提示符里带着它，用来认出测试程序自己打开的终端窗口（Terminal 启动时恢复出来的窗口没有）
let runID = String(format: "%04x", arc4random_uniform(0x10000))

var logLines: [String] = []
func log(_ message: String) {
    logLines.append(String(format: "%7.2f ", Date().timeIntervalSince(startTime))
                    + message.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
    try? logLines.joined(separator: "\n").write(to: logURL, atomically: true, encoding: .utf8)
}

struct TestResult {
    let id: String
    let name: String
    let status: String
    let note: String
}
var results: [TestResult] = []

func record(_ id: String, _ name: String, _ status: String, _ note: String) {
    // 你的电脑上：路径里的用户目录写成 ~（报告里不留用户名）
    let note = note.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    results.append(TestResult(id: id, name: name, status: status, note: note))
    log("RESULT \(id) \(status) \(name) | \(note)")
    writeReport()
}

func writeReport(final: Bool = false, aborted: String? = nil) {
    var out = "# Copi 自动测试报告\n\n"
    out += "- 开始：\(startTime)\n"
    if let aborted {
        out += "- **中止**：\(aborted)\n"
    }
    out += final ? "- 状态：完成（用时 \(Int(Date().timeIntervalSince(startTime))) 秒）\n\n" : "- 状态：进行中\n\n"
    out += "| # | 测试 | 结果 | 说明 |\n|---|---|---|---|\n"
    for r in results {
        let note = r.note.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ⏎ ")
        out += "| \(r.id) | \(r.name) | \(r.status) | \(note) |\n"
    }
    try? out.write(to: reportURL, atomically: true, encoding: .utf8)
}

struct Abort: Error {
    let reason: String
}

// MARK: - 合成事件

let eventSource = CGEventSource(stateID: .hidSystemState)

func sleepMS(_ ms: Int) {
    usleep(useconds_t(ms * 1000))
}

private func postKeyEvent(_ code: CGKeyCode, down: Bool, flags: CGEventFlags) {
    guard let event = CGEvent(keyboardEventSource: eventSource, virtualKey: code, keyDown: down) else {
        return
    }
    event.flags = flags
    event.post(tap: .cghidEventTap)
}

// 和真人一样：先按下修饰键，再按键，松开键，最后松开修饰键。whileHeld：键按下之后、松开之前调用（诊断用）
func chord(_ code: CGKeyCode, _ modifiers: [CGKeyCode: CGEventFlags] = [:], holdMS: Int = 40, whileHeld: (() -> Void)? = nil) {
    var flags: CGEventFlags = []
    let order: [CGKeyCode] = [CGKeyCode(kVK_Command), CGKeyCode(kVK_Shift), CGKeyCode(kVK_Option), CGKeyCode(kVK_Control)]
    let pressed = order.filter { modifiers[$0] != nil }
    for modifier in pressed {
        flags.insert(modifiers[modifier]!)
        if let event = CGEvent(keyboardEventSource: eventSource, virtualKey: modifier, keyDown: true) {
            event.type = .flagsChanged
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
        sleepMS(25)
    }
    postKeyEvent(code, down: true, flags: flags)
    whileHeld?()
    sleepMS(holdMS)
    postKeyEvent(code, down: false, flags: flags)
    sleepMS(25)
    for modifier in pressed.reversed() {
        flags.remove(modifiers[modifier]!)
        if let event = CGEvent(keyboardEventSource: eventSource, virtualKey: modifier, keyDown: false) {
            event.type = .flagsChanged
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
        sleepMS(25)
    }
    sleepMS(80)
}

let cmd: [CGKeyCode: CGEventFlags] = [CGKeyCode(kVK_Command): .maskCommand]
let cmdShift: [CGKeyCode: CGEventFlags] = [CGKeyCode(kVK_Command): .maskCommand, CGKeyCode(kVK_Shift): .maskShift]
let cmdShiftOpt: [CGKeyCode: CGEventFlags] = [CGKeyCode(kVK_Command): .maskCommand, CGKeyCode(kVK_Shift): .maskShift,
                                              CGKeyCode(kVK_Option): .maskAlternate]
let ctrl: [CGKeyCode: CGEventFlags] = [CGKeyCode(kVK_Control): .maskControl]

func keyA() -> CGKeyCode { CGKeyCode(kVK_ANSI_A) }
func keyC() -> CGKeyCode { CGKeyCode(kVK_ANSI_C) }
func keyV() -> CGKeyCode { CGKeyCode(kVK_ANSI_V) }
func keyE() -> CGKeyCode { CGKeyCode(kVK_ANSI_E) }
func keyW() -> CGKeyCode { CGKeyCode(kVK_ANSI_W) }

// 打字（只用于往测试终端里输入命令），一个字一个字地发
func typeText(_ text: String) {
    for unit in text.utf16 {
        var character = unit
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: down) else {
                continue
            }
            event.flags = []
            event.keyboardSetUnicodeString(stringLength: 1, unicodeString: &character)
            event.post(tap: .cghidEventTap)
            sleepMS(6)
        }
        sleepMS(6)
    }
    sleepMS(80)
}

func pressReturn() {
    chord(CGKeyCode(kVK_Return))
}

func mouse(_ type: CGEventType, _ point: CGPoint, _ button: CGMouseButton = .left) {
    CGEvent(mouseEventSource: eventSource, mouseType: type, mouseCursorPosition: point, mouseButton: button)?.post(tap: .cghidEventTap)
}

func click(_ point: CGPoint) {
    mouse(.mouseMoved, point)
    sleepMS(80)
    mouse(.leftMouseDown, point)
    sleepMS(60)
    mouse(.leftMouseUp, point)
    sleepMS(150)
}

func rightClick(_ point: CGPoint) {
    mouse(.mouseMoved, point)
    sleepMS(80)
    mouse(.rightMouseDown, point, .right)
    sleepMS(60)
    mouse(.rightMouseUp, point, .right)
    sleepMS(400)
}

// MARK: - Accessibility

func ax(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
}

func axString(_ element: AXUIElement, _ attribute: String) -> String? {
    ax(element, attribute) as? String
}

func axElement(_ value: CFTypeRef?) -> AXUIElement? {
    guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
        return nil
    }
    return (value as! AXUIElement)
}

func axChildren(_ element: AXUIElement) -> [AXUIElement] {
    (ax(element, kAXChildrenAttribute) as? [AnyObject] ?? []).compactMap { axElement($0) }
}

func findDescendant(_ root: AXUIElement, maxDepth: Int = 12, _ predicate: (AXUIElement) -> Bool) -> AXUIElement? {
    var level = [root]
    for _ in 0..<maxDepth {
        var next: [AXUIElement] = []
        for element in level {
            if predicate(element) {
                return element
            }
            next.append(contentsOf: axChildren(element))
        }
        if next.isEmpty {
            return nil
        }
        level = next
    }
    return nil
}

func role(_ element: AXUIElement) -> String? {
    axString(element, kAXRoleAttribute)
}

func frame(_ element: AXUIElement) -> CGRect? {
    guard let positionValue = ax(element, kAXPositionAttribute), let sizeValue = ax(element, kAXSizeAttribute) else {
        return nil
    }
    var position = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
          AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else {
        return nil
    }
    return CGRect(origin: position, size: size)
}

func center(_ rect: CGRect) -> CGPoint {
    CGPoint(x: rect.midX, y: rect.midY)
}

// 系统报告的焦点 App（不靠 NSWorkspace 的缓存）
func focusedApp() -> (pid: pid_t, bundleID: String?)? {
    guard let app = axElement(ax(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute)) else {
        return nil
    }
    var pid: pid_t = 0
    guard AXUIElementGetPid(app, &pid) == .success else {
        return nil
    }
    return (pid, NSRunningApplication(processIdentifier: pid)?.bundleIdentifier)
}

func windows(_ pid: pid_t) -> [AXUIElement] {
    (ax(AXUIElementCreateApplication(pid), kAXWindowsAttribute) as? [AnyObject] ?? []).compactMap { axElement($0) }
}

func pids(_ bundleID: String) -> [pid_t] {
    NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).map(\.processIdentifier)
}

// MARK: - 打开、前台、安全闸门

func run(_ path: String, _ arguments: [String], timeout: TimeInterval = 20) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
        try process.run()
    } catch {
        return (-1, "launch failed: \(error)")
    }
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning, Date() < deadline {
        sleepMS(20)
    }
    if process.isRunning {
        // 超时：结束它。terminate 之后进程不会马上退出，这时读 terminationStatus 会抛异常、让测试程序整个崩掉：等它退出再读。
        // 还不退出就 SIGKILL；输出不读（它启动的子进程可能还拿着管道，读到底会一直等）
        process.terminate()
        let killDeadline = Date().addingTimeInterval(2)
        while process.isRunning, Date() < killDeadline {
            sleepMS(20)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            sleepMS(200)
        }
        return (process.isRunning ? -2 : process.terminationStatus, "timed out")
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

func openWith(_ appName: String, _ target: String) {
    _ = run("/usr/bin/open", ["-a", appName, target])
}

struct TestWindow {
    let bundleID: String
    let appName: String
    let pid: pid_t
    let window: AXUIElement
    // 窗口对了还不够时（浏览器的当前标签页、VS Code 的当前编辑器）：窗口标题必须满足它
    var titleCheck: ((String) -> Bool)? = nil
    // 窗口里显示的内容也要对（Terminal：当前标签页里是测试用的 shell）
    var contentCheck: (() -> Bool)? = nil
}

// 等某个 App 出现标题含 titleContains 的窗口
func waitWindow(_ bundleID: String, _ appName: String, titleContains: String, timeout: TimeInterval = 12) -> TestWindow? {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        for pid in pids(bundleID) {
            for window in windows(pid) where (axString(window, kAXTitleAttribute) ?? "").contains(titleContains) {
                return TestWindow(bundleID: bundleID, appName: appName, pid: pid, window: window)
            }
        }
        sleepMS(150)
    }
    return nil
}

func bringToFront(_ target: TestWindow) {
    if pids(target.bundleID).count > 1 {
        // 同一个 App 开着好几个（例如单独开的 VS Code）：open -a 不知道会切到哪一个，直接让这个进程到前台
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(target.pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    } else {
        _ = run("/usr/bin/open", ["-a", target.appName])
    }
    sleepMS(250)
    AXUIElementPerformAction(target.window, kAXRaiseAction as CFString)
    AXUIElementSetAttributeValue(target.window, kAXMainAttribute as CFString, kCFBooleanTrue)
    AXUIElementSetAttributeValue(target.window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    sleepMS(350)
}

// 报告、日志里只写出这些 App 的名字（别的 App 不写，报告里不留用户在用什么）
let knownAppIDs: Set<String> = ["com.apple.TextEdit", "com.brave.Browser", "com.apple.Safari", "com.apple.Terminal", "com.gokoding.Copi",
                                "com.googlecode.iterm2", "com.microsoft.VSCode", "com.tinyspeck.slackmacgap", "com.apple.ScreenSharing",
                                "com.apple.UserNotificationCenter", "com.apple.notificationcenterui", "com.apple.loginwindow",
                                "com.apple.Spotlight", "com.apple.dock", "com.apple.systemuiserver", "com.apple.controlcenter",
                                "com.raycast.macos", "com.runningwithcrayons.Alfred", "com.google.Chrome"]

// GitHub Actions 的虚拟机上弹出的系统对话框（权限询问之类，由 UserNotificationCenter 显示）：写出上面的文字和按钮，
// 好知道是什么弹出来的。只在虚拟机上读（你的电脑上不读别的程序的窗口）
func systemAlertText() -> String? {
    guard onCI, let focused = focusedApp(), focused.bundleID == "com.apple.UserNotificationCenter" else {
        return nil
    }
    var texts: [String] = []
    func walk(_ element: AXUIElement, depth: Int) {
        guard depth < 8, texts.count < 20 else {
            return
        }
        let role = axString(element, kAXRoleAttribute) ?? ""
        if role == kAXStaticTextRole, let value = axString(element, kAXValueAttribute), !value.isEmpty {
            texts.append(value)
        } else if role == kAXButtonRole, let title = axString(element, kAXTitleAttribute), !title.isEmpty {
            texts.append("[\(title)]")
        }
        axChildren(element).forEach { walk($0, depth: depth + 1) }
    }
    windows(focused.pid).forEach { walk($0, depth: 0) }
    return texts.isEmpty ? "（读不到文字）" : texts.joined(separator: " ").replacingOccurrences(of: "\n", with: " ")
}

// 系统对话框已经写进报告的（同一段文字只写一次）
var reportedSystemAlerts: Set<String> = []

// 发按键之前必须通过：焦点 App 是目标 App，焦点窗口就是测试窗口。否则先试着带到前台，还不行就中止整轮测试
func gate(_ target: TestWindow) throws {
    func passes() -> Bool {
        if let focused = focusedApp(), focused.pid == target.pid,
           let window = axElement(ax(AXUIElementCreateApplication(target.pid), kAXFocusedWindowAttribute)),
           CFEqual(window, target.window),
           target.titleCheck?(axString(target.window, kAXTitleAttribute) ?? "") ?? true,
           target.contentCheck?() ?? true {
            return true
        }
        return false
    }
    for round in 0..<2 {
        for attempt in 0..<3 {
            if passes() {
                return
            }
            if attempt < 2 {
                bringToFront(target)
            }
        }
        // 虚拟机上系统对话框挡在前面：写进报告，等它自己消失（最多 30 秒）再试一轮。不按它的按钮（不替用户回答权限询问）
        guard round == 0, let alert = systemAlertText() else {
            break
        }
        if reportedSystemAlerts.insert(alert).inserted {
            record("alert", "系统对话框挡在前面", "INFO", alert)
        }
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline, focusedApp()?.bundleID == "com.apple.UserNotificationCenter" {
            sleepMS(1000)
            bringToFront(target)
        }
    }
    // 只说出测试相关的 App，别的 App 不写名字（报告里不留用户在用什么）
    let focusedID = focusedApp()?.bundleID ?? "nil"
    // GitHub Actions 的虚拟机里没有个人信息：直接写出是哪个 App 拿走了焦点
    let shown = knownAppIDs.contains(focusedID) || ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" ? focusedID : "其他 App"
    var detail = ""
    if let focused = focusedApp(), focused.pid == target.pid,
       let window = axElement(ax(AXUIElementCreateApplication(target.pid), kAXFocusedWindowAttribute)) {
        detail = CFEqual(window, target.window) ? "；测试窗口当前显示的不是测试内容（别的标签页或文件）"
            : "；焦点在同一个 App 的另一个窗口（\(axString(window, kAXSubroleAttribute) ?? "nil")）"
    }
    if let alert = systemAlertText() {
        detail += "；系统对话框：\(alert)"
    }
    throw Abort(reason: "焦点不在测试窗口（期望 \(target.bundleID)，实际 \(shown)\(detail)），为安全起见停止")
}

// MARK: - 剪贴板（只看类型）

let textTypes: Set<String> = ["public.utf8-plain-text", "public.utf16-plain-text", "public.utf16-external-plain-text",
                              "NSStringPboardType", "public.rtf", "public.html", "com.apple.flat-rtfd", "public.rtfd"]

func pasteboardHasText(_ pasteboard: NSPasteboard) -> Bool {
    let types = (pasteboard.pasteboardItems ?? []).flatMap { $0.types.map(\.rawValue) }
    return types.contains { textTypes.contains($0) }
}

func pasteboardSummary(_ pasteboard: NSPasteboard) -> String {
    let items = pasteboard.pasteboardItems ?? []
    return "items=\(items.count) hasText=\(pasteboardHasText(pasteboard))"
}

// 复制之后的一小段时间里反复看系统剪贴板：文字出现过多久（按 2ms 取样）
func watchGeneralPasteboard(ms: Int) -> (sawText: Bool, sawForMS: Int) {
    var saw = 0
    let deadline = Date().addingTimeInterval(Double(ms) / 1000)
    while Date() < deadline {
        if pasteboardHasText(.general) {
            saw += 2
        }
        usleep(2000)
    }
    return (saw > 0, saw)
}

// MARK: - 文字比对

func djb2(_ text: String) -> String {
    var hash: UInt32 = 5381
    for unit in text.utf16 {
        hash = (hash &* 33) ^ UInt32(unit)
    }
    return String(hash, radix: 16)
}

func describeDiff(_ actual: String?, _ expected: String) -> String {
    guard let actual else {
        return "读不到结果"
    }
    if actual == expected {
        return "完全一致（\(expected.utf16.count) 字符）"
    }
    let a = Array(actual.utf16)
    let e = Array(expected.utf16)
    var index = 0
    while index < min(a.count, e.count), a[index] == e[index] {
        index += 1
    }
    let lineA = actual.split(separator: "\n", omittingEmptySubsequences: false).count
    let lineE = expected.split(separator: "\n", omittingEmptySubsequences: false).count
    return "不一致：实际 \(a.count) 字符/\(lineA) 行，期望 \(e.count) 字符/\(lineE) 行，第一个不同在第 \(index) 个字符"
}

// MARK: - 测试素材

let basicText = "Copi selftest basic line 123 Omega Ω 中文 ✓"
let passwordText = "CopiPw-123_test"
let paraTexts = ["Alpha paragraph for Copi selftest.", "Beta paragraph, second one.", "Gamma paragraph closes it."]
let longLines = (1...400).map { String(format: "Line %03d of the long Copi selftest selection.", $0) } + ["Final text line."]

func writeFixture(_ name: String, _ content: String) -> URL {
    let url = fixtures.appendingPathComponent(name)
    try? content.write(to: url, atomically: true, encoding: .utf8)
    return url
}

func pageHTML(mode: String) -> String {
    // 只有一行命令的页面（浏览器文字 → Terminal 的测试）：命令只在测试目录里建一个标记文件
    if mode == "cmd" {
        return """
        <!doctype html><html><head><meta charset="utf-8"><title>COPI|ready|cmd</title>
        <style>body{font:15px -apple-system;margin:40px}</style></head>
        <body><p id="cmd">touch markers/t4</p></body></html>
        """
    }
    let para = paraTexts.map { "<p>\($0)</p>" }.joined()
    let long = longLines.map { "<p>\($0)</p>" }.joined()
    let icon = "<img alt=\"\" width=\"16\" height=\"16\" src=\"data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='16' height='16'><circle cx='8' cy='8' r='7' fill='red'/></svg>\"><button>Icon</button>"
    // kind-<class>：页面最前面一个带这个 class 的可编辑区（代码编辑器、网页终端、Google Docs、Sheets 的识别靠 class），选中它的文字。
    // 放在表单控件前面：Chromium 里起点紧挨表单控件的脚本选区读不出来（已知限制），不能让它混进这里的结果
    let kindClass = mode.hasPrefix("kind-") ? String(mode.dropFirst("kind-".count)) : nil
    let kindHTML = kindClass.map { "<div class=\"\($0)\" id=\"kd\" contenteditable=\"true\" style=\"border:1px solid #888;margin-bottom:12px\">Copi blocked \($0) text</div>" } ?? ""
    let linkHTML = mode == "link" ? "<p style=\"font-size:22px\"><a id=\"lnk\" href=\"https://example.com/copi-link\">Copi test link</a></p>" : ""
    return """
    <!doctype html><html><head><meta charset="utf-8"><title>COPI|loading|\(mode)</title>
    <style>body{font:15px -apple-system;margin:20px} #long p{margin:0} textarea,input{display:block;margin:8px 0;width:420px}</style></head>
    <body>
    \(kindHTML)\(linkHTML)
    <textarea id="ta" rows="3"></textarea><input id="in"><input id="pw" type="password" autocomplete="new-password">
    <button id="cb" onclick="copyTest()">Copy test</button>
    <div class="cm-editor"><div class="cm-content" id="ce" contenteditable="true" style="min-height:30px;border:1px solid #888"></div></div>
    <div id="para">\(para)</div><hr><div id="long">\(long)\(icon)</div>
    <script>
    const MODE = "\(mode)";
    function h(s){let x=5381;for(let i=0;i<s.length;i++){x=((x*33)^s.charCodeAt(i))>>>0;}return x.toString(16);}
    const last = {};
    function report(id){const v=document.getElementById(id).value;document.title=`COPI|${id}|len=${v.length}|h=${h(v)}`;}
    setInterval(()=>{for(const id of ['ta','in','pw']){const v=document.getElementById(id).value;if(last[id]!==v){last[id]=v;if(v.length)report(id);}}
      const c=document.getElementById('ce').textContent;if(last.ce!==c){last.ce=c;if(c.length)document.title=`COPI|ce|len=${c.length}|h=${h(c)}`;}},100);
    function copyTest(){const t=document.createElement('textarea');t.value='COPI-BUTTON-TEXT-42';document.body.appendChild(t);t.select();document.execCommand('copy');t.remove();}
    window.addEventListener('load',()=>{
      if(MODE.startsWith('sel-')){const el=document.getElementById(MODE.slice(4));const r=document.createRange();r.selectNodeContents(el);const s=getSelection();s.removeAllRanges();s.addRange(r);}
      else if(MODE.startsWith('focus-')){const el=document.getElementById(MODE.slice(6));if('value' in el)el.value='';el.focus();}
      else if(MODE==='pw-filled'){const el=document.getElementById('pw');el.value='CopiPw-filled-1';last.pw=el.value;el.focus();el.select();}
      else if(MODE.startsWith('long-')){const el=document.getElementById('in');el.value='x'.repeat(parseInt(MODE.slice(5)));last.in=el.value;el.focus();el.select();}
      else if(MODE==='lone-in'){const el=document.getElementById('in');el.value='ab'+String.fromCharCode(0xD800)+'cd';last.in=el.value;el.focus();el.setSelectionRange(0,0);}
      else if(MODE.startsWith('kind-')){const el=document.getElementById('kd');el.focus();const r=document.createRange();r.selectNodeContents(el);const s=getSelection();s.removeAllRanges();s.addRange(r);}
      document.title=`COPI|ready|${MODE}`;
    });
    </script></body></html>
    """
}

func prepareFixtures() {
    try? FileManager.default.removeItem(at: fixtures)
    try? FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: fixtures.appendingPathComponent("markers"), withIntermediateDirectories: true)
    for mode in ["sel-para", "sel-long", "focus-ta", "focus-in", "focus-pw", "plain", "copybtn", "focus-ce", "cmd",
                 "pw-filled", "long-10000", "long-9900", "long-8000", "lone-in", "link", "kind-plain-edit", "kind-cm-content", "kind-xterm", "kind-kix-appview-editor", "kind-cell-input"] {
        _ = writeFixture("page-\(mode).html", pageHTML(mode: mode))
    }
    // 独立的 zsh：不读用户自己的配置，不写用户的历史记录；提示符里带着这一轮的标记
    let zdot = fixtures.appendingPathComponent("zdot")
    try? FileManager.default.createDirectory(at: zdot, withIntermediateDirectories: true)
    try? "PS1='copitest\(runID)%# '\nunsetopt beep\n"
        .write(to: zdot.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
    let command = fixtures.appendingPathComponent("copiterm.command")
    try? "#!/bin/zsh\ncd \"$(dirname \"$0\")\"\nexport ZDOTDIR=\"$PWD/zdot\"\nexec /bin/zsh -i\n"
        .write(to: command, atomically: true, encoding: .utf8)
    chmod(command.path, 0o755)
}

// MARK: - TextEdit

let textEdit = ("com.apple.TextEdit", "TextEdit")

func openTextEdit(_ name: String, _ content: String) throws -> TestWindow {
    let url = writeFixture(name, content)
    openWith(textEdit.1, url.path)
    let stem = (name as NSString).deletingPathExtension
    guard let window = waitWindow(textEdit.0, textEdit.1, titleContains: stem) else {
        throw Abort(reason: "TextEdit 没有打开 \(name)")
    }
    bringToFront(window)
    return window
}

func textArea(_ target: TestWindow) -> AXUIElement? {
    findDescendant(target.window) { role($0) == kAXTextAreaRole }
}

func textValue(_ target: TestWindow) -> String? {
    textArea(target).flatMap { axString($0, kAXValueAttribute) }
}

func selectRange(_ target: TestWindow, _ location: Int, _ length: Int) {
    guard let area = textArea(target) else {
        return
    }
    var range = CFRange(location: location, length: length)
    if let value = AXValueCreate(.cfRange, &range) {
        AXUIElementSetAttributeValue(area, kAXSelectedTextRangeAttribute as CFString, value)
    }
    sleepMS(150)
}

func boundsOfRange(_ target: TestWindow, _ location: Int, _ length: Int) -> CGRect? {
    guard let area = textArea(target) else {
        return nil
    }
    var range = CFRange(location: location, length: length)
    guard let rangeValue = AXValueCreate(.cfRange, &range) else {
        return nil
    }
    var result: CFTypeRef?
    guard AXUIElementCopyParameterizedAttributeValue(area, kAXBoundsForRangeParameterizedAttribute as CFString, rangeValue, &result) == .success,
          let result else {
        return nil
    }
    var rect = CGRect.zero
    guard AXValueGetValue(result as! AXValue, .cgRect, &rect) else {
        return nil
    }
    return rect
}

func closeWindow(_ target: TestWindow) {
    guard (try? gate(target)) != nil else {
        return
    }
    chord(keyW(), cmd)
    sleepMS(400)
    dismissSaveSheet(target.window)
}

// 复制 TextEdit 里的一段文字（⌘A ⌘C），之后看系统剪贴板上有没有出现过文字
func copyFromTextEdit(_ name: String, _ content: String) throws -> (TestWindow, sawText: Bool, sawForMS: Int) {
    let source = try openTextEdit(name, content)
    try gate(source)
    chord(keyA(), cmd)
    try gate(source)
    chord(keyC(), cmd)
    let watch = watchGeneralPasteboard(ms: 400)
    return (source, watch.sawText, watch.sawForMS)
}

// MARK: - 浏览器

func openPage(_ browser: (String, String), mode: String) throws -> TestWindow {
    let url = fixtures.appendingPathComponent("page-\(mode).html")
    openWith(browser.1, url.path)
    guard var window = waitWindow(browser.0, browser.1, titleContains: "COPI|ready|\(mode)", timeout: 15) else {
        // 只记数量：浏览器有几个窗口、其中几个是测试页（停在加载中的、别的测试页的），别的窗口的标题不看
        let titles = pids(browser.0).flatMap { windows($0) }.map { axString($0, kAXTitleAttribute) ?? "" }
        let loading = titles.filter { $0.contains("COPI|loading|\(mode)") }.count
        let otherTests = titles.filter { $0.contains("COPI|") && !$0.contains("|\(mode)") }.count
        throw Abort(reason: "\(browser.1) 没有打开测试页 \(mode)（进程 \(pids(browser.0).count) 个、窗口 \(titles.count) 个，其中这个测试页停在加载中 \(loading) 个、别的测试页 \(otherTests) 个）")
    }
    // 窗口的标题就是当前标签页的标题：发按键前确认当前标签页还是测试页
    window.titleCheck = { $0.contains("COPI|") }
    bringToFront(window)
    return window
}

func waitTitle(_ target: TestWindow, prefix: String, timeout: TimeInterval = 4) -> String? {
    let deadline = Date().addingTimeInterval(timeout)
    var last: String?
    while Date() < deadline {
        last = axString(target.window, kAXTitleAttribute)
        if let last, last.contains(prefix) {
            return last
        }
        sleepMS(100)
    }
    return last
}

// 网页输入框里的结果（标题 "COPI|ta|len=..|h=.."）
// 等到期望的内容（框里原来就有内容、或者打字分几次到达时，第一次变化还不是最后的结果）
func fieldResult(_ target: TestWindow, field: String, expected: String) -> (String, String) {
    let want = "len=\(expected.utf16.count)|h=\(djb2(expected))"
    let title = waitTitle(target, prefix: "COPI|\(field)|\(want)") ?? "nil"
    if title.contains("COPI|\(field)|"), title.contains(want) {
        return ("PASS", "内容一致（\(expected.utf16.count) 字符）")
    }
    if let range = title.range(of: "COPI|\(field)|") {
        return ("FAIL", "页面收到 \(title[range.upperBound...].prefix(40))，期望 \(want)")
    }
    return ("FAIL", title.contains("COPI|") ? "页面没有收到粘贴（标题仍是 \(title.prefix(40))）" : "页面没有收到粘贴（当前标签页不是测试页）")
}

func closeTab(_ target: TestWindow) {
    guard (try? gate(target)) != nil, (axString(target.window, kAXTitleAttribute) ?? "").contains("COPI|") else {
        return
    }
    chord(keyW(), cmd)
    sleepMS(400)
}

// 浏览器里焦点在哪里、能不能看到选区（只记角色和长度）
func webSelectionDiag(_ target: TestWindow) -> String {
    let app = AXUIElementCreateApplication(target.pid)
    guard let focused = axElement(ax(app, kAXFocusedUIElementAttribute)) else {
        return "焦点元素=nil"
    }
    var names: CFArray?
    AXUIElementCopyAttributeNames(focused, &names)
    let list = names as? [String] ?? []
    var length = -1
    if let range = ax(focused, "AXSelectedTextMarkerRange") {
        var out: CFTypeRef?
        if AXUIElementCopyParameterizedAttributeValue(focused, "AXLengthForTextMarkerRange" as CFString, range, &out) == .success {
            length = (out as? NSNumber)?.intValue ?? -1
        }
    }
    return "焦点角色=\(role(focused) ?? "nil") 网页节点=\(list.contains("ChromeAXNodeId") || list.contains("AXDOMIdentifier")) 选区长度=\(length)"
}

// Chromium 里读不出网页选区时，照 Copi 的办法（ZeroExposure.swift 的 paragraphPreservingString）一段段走一遍，记下每一步：
// 只记长度、索引、出错代码；调试描述里只有测试页自己的文字
func chromiumSelectionTrace(_ target: TestWindow) -> String {
    let app = AXUIElementCreateApplication(target.pid)
    guard let focused = axElement(ax(app, kAXFocusedUIElementAttribute)) else {
        return "焦点元素=nil"
    }
    guard let raw = ax(focused, "AXSelectedTextMarkerRange"), CFGetTypeID(raw) == AXTextMarkerRangeGetTypeID() else {
        return "没有选区"
    }
    func param(_ attribute: String, _ parameter: CFTypeRef) -> (AXError, CFTypeRef?) {
        var out: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(focused, attribute as CFString, parameter, &out)
        return (error, out)
    }
    func marker(_ value: CFTypeRef?) -> AXTextMarker? {
        guard let value, CFGetTypeID(value) == AXTextMarkerGetTypeID() else {
            return nil
        }
        return (value as! AXTextMarker)
    }
    func length(_ from: AXTextMarker, _ to: AXTextMarker) -> Int {
        (param("AXLengthForTextMarkerRange", AXTextMarkerRangeCreate(kCFAllocatorDefault, from, to)).1 as? NSNumber)?.intValue ?? -1
    }
    func stringLength(_ from: AXTextMarker, _ to: AXTextMarker) -> Int {
        (param("AXStringForTextMarkerRange", AXTextMarkerRangeCreate(kCFAllocatorDefault, from, to)).1 as? String)?.utf16.count ?? -1
    }
    func describe(_ value: AXTextMarker) -> String {
        guard let text = param("AXTextMarkerDebugDescription", value).1 as? String else {
            return "nil"
        }
        return String(text.replacingOccurrences(of: "\n", with: "⏎").prefix(160))
    }
    let selection = raw as! AXTextMarkerRange
    let unordered = [AXTextMarkerRangeCopyStartMarker(selection), AXTextMarkerRangeCopyEndMarker(selection)] as CFArray
    guard let orderedRaw = param("AXTextMarkerRangeForUnorderedTextMarkers", unordered).1, CFGetTypeID(orderedRaw) == AXTextMarkerRangeGetTypeID() else {
        return "排不了序"
    }
    let ordered = orderedRaw as! AXTextMarkerRange
    let first = AXTextMarkerRangeCopyStartMarker(ordered)
    let last = AXTextMarkerRangeCopyEndMarker(ordered)
    var steps = ["总长=\(length(first, last)) 整段字符串=\(stringLength(first, last)) 起点=\(describe(first)) 终点=\(describe(last))"]
    var cursor = first
    var reanchored = false
    for step in 0..<6 {
        let (error, value) = param("AXNextParagraphEndTextMarkerForTextMarker", cursor)
        guard let end = marker(value) else {
            steps.append("第\(step)步找段落结尾：代码 \(error.rawValue)")
            break
        }
        let paragraph = length(cursor, end)
        let index = param("AXIndexForTextMarker", end)
        steps.append("第\(step)步：段长=\(paragraph) 字符串=\(stringLength(cursor, end)) 结尾索引="
                     + (index.0 == .success ? "\((index.1 as? NSNumber)?.intValue ?? -1)" : "代码 \(index.0.rawValue)") + " 结尾=\(describe(end))")
        guard paragraph == 0 else {
            cursor = end
            continue
        }
        // 和 Copi 一样：往后挪一个字再往前挪一个字，换成紧跟着的第一个字的开头（只换一次）
        guard !reanchored, let next = marker(param("AXNextTextMarkerForTextMarker", cursor).1),
              let start = marker(param("AXPreviousTextMarkerForTextMarker", next).1) else {
            steps.append("换不了起点")
            break
        }
        steps.append("换起点：间隔=\(length(cursor, start)) 往后一个字=\(describe(next)) 新起点=\(describe(start))")
        reanchored = true
        cursor = start
    }
    return steps.joined(separator: "；")
}

// 把键盘焦点放到网页上（不动选区）：浏览器打开新标签页时焦点有时留在地址栏
func focusWebArea(_ target: TestWindow) {
    if let webArea = findDescendant(target.window, maxDepth: 12, { role($0) == "AXWebArea" }) {
        AXUIElementSetAttributeValue(webArea, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        sleepMS(300)
    }
}

func staticTextFrame(_ window: AXUIElement, prefix: String) -> CGRect? {
    findDescendant(window, maxDepth: 40) {
        role($0) == kAXStaticTextRole && (axString($0, kAXValueAttribute) ?? "").hasPrefix(prefix)
    }.flatMap { frame($0) }
}

// 用鼠标拖选（和真人一样）
func mouseSelect(from start: CGPoint, to end: CGPoint) {
    mouse(.mouseMoved, start)
    sleepMS(100)
    mouse(.leftMouseDown, start)
    sleepMS(120)
    for step in 1...10 {
        let t = CGFloat(step) / 10
        mouse(.leftMouseDragged, CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t))
        sleepMS(30)
    }
    mouse(.leftMouseUp, end)
    sleepMS(400)
}

// 三击（按段落选中）
func tripleClick(_ point: CGPoint) {
    mouse(.mouseMoved, point)
    sleepMS(100)
    for count in 1...3 {
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            if let event = CGEvent(mouseEventSource: eventSource, mouseType: type, mouseCursorPosition: point, mouseButton: .left) {
                event.setIntegerValueField(.mouseEventClickState, value: Int64(count))
                event.post(tap: .cghidEventTap)
            }
            sleepMS(30)
        }
        sleepMS(40)
    }
    sleepMS(400)
}

// 在后台每 2ms 看一次拖放剪贴板：文字从什么时候出现、出现了多久
final class DragSampler {
    private var running = true
    private(set) var firstSeenMS: Int?
    private(set) var lastSeenMS: Int?
    private(set) var seenSamples = 0
    private let start = Date()
    private var thread: Thread?

    func begin() {
        thread = Thread { [self] in
            while running {
                if pasteboardHasText(NSPasteboard(name: .drag)) {
                    let ms = Int(Date().timeIntervalSince(start) * 1000)
                    firstSeenMS = firstSeenMS ?? ms
                    lastSeenMS = ms
                    seenSamples += 1
                }
                usleep(2000)
            }
        }
        thread?.start()
    }

    func end() {
        running = false
        sleepMS(20)
    }
}

// MARK: - 终端

let terminal = ("com.apple.Terminal", "Terminal")

func terminalText(_ target: TestWindow) -> String {
    textValue(target) ?? ""
}

// 只看命令输出的行（不带提示符的整行）
func outputLines(_ text: String) -> [String] {
    text.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.hasPrefix("copitest") }
}

func ran(_ marker: String, in text: String) -> Bool {
    outputLines(text).contains { $0.hasPrefix(marker) }
}

// MARK: - 输入法

// 输入法（TIS）的接口在主线程上调用：测试跑在另一个线程上，在那里调用时 macOS 有时直接让测试程序崩掉
// （输入法清单变过之后尤其如此，例如 CI 上刚启用了拼音）
func onMainThread<T>(_ body: () -> T) -> T {
    Thread.isMainThread ? body() : DispatchQueue.main.sync(execute: body)
}

// （诊断，只在 GitHub 的虚拟机上）Secure Input 开着时是哪个程序开的：登录会话信息里的 kCGSSessionSecureInputPID。
// Secure Input 开着时 Copi 的按键拦截看不到按键（⌘V 改走热键，键入时按下的回车拦不下）
func secureInputHolder() -> String {
    guard onCI, IsSecureEventInputEnabled() else {
        return ""
    }
    let output = run("/usr/sbin/ioreg", ["-l", "-w", "0", "-d", "1"], timeout: 10).output
    guard let range = output.range(of: "\"kCGSSessionSecureInputPID\"="),
          let pid = pid_t(String(output[range.upperBound...].prefix { $0.isNumber })) else {
        return "（开的程序：查不到）"
    }
    return "（开的程序：\(NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "pid \(pid)")）"
}

// 系统整体的输入空闲时间（IOHIDSystem 的 HIDIdleTime，毫秒）：键盘、鼠标、触控板的任何输入都让它归零，系统判断空闲、
// 显示器睡眠看的就是它。读不到时为 nil
func hidIdleMS() -> Int? {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
    guard service != 0 else {
        return nil
    }
    defer {
        IOObjectRelease(service)
    }
    guard let value = IORegistryEntryCreateCFProperty(service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber else {
        return nil
    }
    return Int(value.uint64Value / 1_000_000)
}

// （诊断）刚按完键时 macOS 各处的输入记录说上一次输入是多久以前（毫秒）：看 Secure Input 开着时哪些还记得测试程序发的按键
func inputRecordsDiag() -> String {
    func ms(_ state: CGEventSourceStateID, _ type: CGEventType) -> String {
        let seconds = CGEventSource.secondsSinceLastEventType(state, eventType: type)
        return seconds > 1e6 ? "很久" : "\(Int(seconds * 1000))"
    }
    let anyInput = CGEventType(rawValue: ~0)!
    return "按键记录 keyDown=\(ms(.hidSystemState, .keyDown))、keyUp=\(ms(.hidSystemState, .keyUp))、修饰键=\(ms(.hidSystemState, .flagsChanged))、"
        + "任意输入=\(ms(.hidSystemState, anyInput))、合并会话的 keyDown=\(ms(.combinedSessionState, .keyDown)) ms，"
        + "系统输入空闲 HIDIdleTime=\(hidIdleMS().map(String.init) ?? "读不到") ms"
}

// （诊断，在 chord 的 whileHeld 里调用）键还按着时硬件层的状态：这个键、⌘ 是不是按着，系统输入空闲多久了
func heldStateDiag(_ code: CGKeyCode) -> String {
    usleep(10_000)
    return "按着时：这个键按着=\(CGEventSource.keyState(.hidSystemState, key: code))、⌘ 按着=\(CGEventSource.flagsState(.hidSystemState).contains(.maskCommand))、"
        + "HIDIdleTime=\(hidIdleMS().map(String.init) ?? "读不到") ms"
}

func currentInputSourceID() -> String? {
    onMainThread {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
            return nil
        }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }
}

func selectInputSource(_ id: String) -> Bool {
    onMainThread {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as NSArray?, list.count > 0 else {
            return false
        }
        let source = list[0] as! TISInputSource
        return TISSelectInputSource(source) == noErr
    }
}

// 启用（不切换到）一个输入法：CI 上用
func enableInputSource(_ id: String) {
    onMainThread {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        if let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as NSArray?, list.count > 0 {
            _ = TISEnableInputSource(list[0] as! TISInputSource)
        }
    }
}

// MARK: - 测试

// Copi 现在的设置（偏好设置里没有这个键就是默认值）
func copiDefault(_ key: String) -> String? {
    let result = run("/usr/bin/defaults", ["read", "com.gokoding.Copi", key])
    return result.status == 0 ? result.output.trimmingCharacters(in: .whitespacesAndNewlines) : nil
}

func copiBool(_ key: String, _ defaultValue: Bool) -> Bool {
    copiDefault(key).map { $0 == "1" } ?? defaultValue
}

// 一组测试：焦点被拿走等原因中止时只记下这一组，接着跑下一组
func section(_ name: String, _ body: () throws -> Void) {
    do {
        try body()
    } catch let error as Abort {
        record("!", "\(name)（这一组中止）", "ABORT", error.reason)
    } catch {
        record("!", "\(name)（这一组出错）", "ABORT", "\(error)")
    }
}

func runTests() throws {
    prepareFixtures()
    let originalInputSource = currentInputSourceID()
    defer {
        if let originalInputSource {
            _ = selectInputSource(originalInputSource)
        }
    }
    // 测试程序自己打字（终端命令）要用 ABC
    _ = ["com.apple.keylayout.ABC", "com.apple.keylayout.US"].first { selectInputSource($0) }

    // Copi 没在运行：打开 Release build（build/DD/Build/Products/Release/Copi.app），等它启动
    var startedCopi = false
    if copiProcesses().main.isEmpty {
        let copiApp = baseDir.deletingLastPathComponent().appendingPathComponent("DD/Build/Products/Release/Copi.app")
        guard FileManager.default.fileExists(atPath: copiApp.path) else {
            throw Abort(reason: "Copi 没有在运行，也找不到 Release build")
        }
        _ = run("/usr/bin/open", [copiApp.path])
        for _ in 0..<40 where copiProcesses().main.isEmpty {
            sleepMS(250)
        }
        guard !copiProcesses().main.isEmpty else {
            throw Abort(reason: "Copi 没有在运行，启动也没成功")
        }
        startedCopi = true
        sleepMS(4000)
    }
    record("0", "前置检查", "INFO", (startedCopi ? "Copi 原本没有运行，测试程序打开了 Release build；测试程序有辅助功能权限" : "Copi 在运行；测试程序有辅助功能权限")
           + (onlyGroups.map { "；这一轮只跑：\($0.sorted().joined(separator: ","))" } ?? ""))
    // Copi 自己菜单顶部的状态提示（只取状态相关的几句，不读剪贴板区、程序列表）
    let status = copiStatusTexts()
    settingsWarningBeforeTests = status.contains("settingsChangeWarning")
    record("0.1", "Copi 菜单里的状态", "INFO", status.isEmpty ? "没有关闭、暂停、受限之类的提示"
           : status.joined(separator: " / ") + (settingsWarningBeforeTests ? "（测试前就有'设置被改'的警告：测试不会去点掉它）" : ""))
    let settings: [(String, Bool)] = [("isOn", true), ("overrideShortcuts", true), ("allowClipboardFallback", false), ("blockTextDragging", true),
                                      ("clearOnLock", true), ("refuseTypingWhenWatched", false), ("instantClipboardDetection", true),
                                      ("constantFastCheck", false), ("typePrivately", false), ("restartAfterCrash", true)]
    let settingsNote = settings.map { "\($0.0)=\(copiBool($0.0, $0.1))" }.joined(separator: " ") + " autoClearMinutes=\(copiDefault("autoClearMinutes") ?? "0")"
    record("0.3", "Copi 的设置", "INFO", settingsNote)
    // 自检：在 TextEdit 里复制一次，系统剪贴板上应该一直没有文字
    let (probe, probeSaw, probeMS) = try copyFromTextEdit("src-preflight.txt", "Copi preflight check")
    closeWindow(probe)
    guard !probeSaw else {
        record("0.2", "自检：Copi 在拦截 ⌘C", "FAIL", "复制后文字在系统剪贴板上出现了约 \(probeMS) ms：Copi 没在保护（关着、Override 关着、或者没有辅助功能权限而暂停了）")
        throw Abort(reason: "Copi 没有在拦截 ⌘C，测试没有意义：请打开 Copi 菜单确认 Copi is On、Override ⌘C/⌘V 开着、没有'暂停'提示")
    }
    record("0.2", "自检：Copi 在拦截 ⌘C", "PASS", "复制后系统剪贴板上一直没有文字")
    keyRecordDiagnostic()
    idleTimeDiagnostic()

    var openedWindows: [TestWindow] = []
    func closeOpened() {
        for window in openedWindows.reversed() {
            if window.bundleID == textEdit.0 {
                closeWindow(window)
            } else if [brave.0, "com.apple.Safari", "com.google.Chrome"].contains(window.bundleID) {
                closeTab(window)
            }
        }
        openedWindows.removeAll()
    }
    defer { closeOpened() }

    // ---- 1. TextEdit ⌘C / ⌘V ----
    if wants("basic") {
    section("TextEdit 基础") {
        do {
            let (source, sawText, sawMS) = try copyFromTextEdit("src-basic.txt", basicText)
            openedWindows.append(source)
            record("1.1", "TextEdit ⌘C 后系统剪贴板", sawText ? "FAIL" : "PASS",
                   sawText ? "文字在系统剪贴板上出现了约 \(sawMS) ms" : "400 ms 内系统剪贴板上一直没有文字（\(pasteboardSummary(.general))）")
            let destination = try openTextEdit("dst-basic.txt", "")
            openedWindows.append(destination)
            try gate(destination)
            chord(keyV(), cmd)
            sleepMS(700)
            let value = textValue(destination)
            record("1.2", "TextEdit ⌘V 粘贴内容", value == basicText ? "PASS" : "FAIL", describeDiff(value, basicText))
        }

        // ---- 2. 编辑菜单的拷贝/粘贴（鼠标点菜单项） ----
        do {
            let source = try openTextEdit("src-menu.txt", "Menu copy line for Copi selftest")
            openedWindows.append(source)
            try gate(source)
            chord(keyA(), cmd)
            let menuCopy = try clickMenuItem(source, commandChar: "C")
            let copyState = lastMenuClickState
            let watch = watchGeneralPasteboard(ms: 400)
            let destination = try openTextEdit("dst-menu.txt", "")
            openedWindows.append(destination)
            try gate(destination)
            let menuPaste = try clickMenuItem(destination, commandChar: "V")
            let pasteState = lastMenuClickState
            sleepMS(700)
            let value = textValue(destination)
            let ok = menuCopy && menuPaste && !watch.sawText && value == "Menu copy line for Copi selftest"
            record("2.1", "编辑菜单 › 拷贝/粘贴", ok ? "PASS" : "FAIL",
                   "点到菜单项：拷贝=\(menuCopy)（\(copyState)） 粘贴=\(menuPaste)（\(pasteState)）；系统剪贴板出现文字=\(watch.sawText)（\(watch.sawForMS) ms）；\(describeDiff(value, "Menu copy line for Copi selftest"))")
        }

        // ---- 3. 右键菜单的拷贝/粘贴 ----
        do {
            let text = "Context menu line for Copi selftest"
            let source = try openTextEdit("src-context.txt", text)
            openedWindows.append(source)
            try gate(source)
            selectRange(source, 0, (text as NSString).length)
            let copied = try contextMenuClick(source, location: 3, titles: ["Copy", "拷贝", "复制"])
            let watch = watchGeneralPasteboard(ms: 400)
            let destination = try openTextEdit("dst-context.txt", "")
            openedWindows.append(destination)
            try gate(destination)
            let pasted = try contextMenuClick(destination, location: 0, titles: ["Paste", "粘贴"])
            sleepMS(700)
            let value = textValue(destination)
            let ok = copied && pasted && !watch.sawText && value == text
            record("3.1", "右键菜单 › 拷贝/粘贴", copied && pasted ? (ok ? "PASS" : "FAIL") : "SKIP",
                   "点到菜单项：拷贝=\(copied) 粘贴=\(pasted)；系统剪贴板出现文字=\(watch.sawText)；\(describeDiff(value, text))")
        }

        // ---- 4. ⌘E 之后的查找剪贴板 ----
        do {
            let source = try openTextEdit("src-find.txt", "findme word for the find pasteboard")
            openedWindows.append(source)
            try gate(source)
            selectRange(source, 0, 6)
            chord(keyE(), cmd)
            var seenAt: [Int] = []
            var elapsed = 0
            for checkpoint in [20, 60, 150, 500] {
                sleepMS(checkpoint - elapsed)
                elapsed = checkpoint
                if pasteboardHasText(NSPasteboard(name: .find)) {
                    seenAt.append(checkpoint)
                }
            }
            let finalHasText = pasteboardHasText(NSPasteboard(name: .find))
            record("4.1", "⌘E 后查找剪贴板被清空", finalHasText ? "FAIL" : "PASS",
                   "取样时看到文字的时刻：\(seenAt.isEmpty ? "无" : seenAt.map { "\($0)ms" }.joined(separator: ","))；最终 hasText=\(finalHasText)")
        }

        // ---- 5. 拖动选中的文字 ----
        do {
            let text = "dragword then more text to drop somewhere"
            let source = try openTextEdit("src-drag.txt", text)
            openedWindows.append(source)
            try gate(source)
            selectRange(source, 0, 8)
            if let bounds = boundsOfRange(source, 0, 8) {
                let start = center(bounds)
                let dragBefore = NSPasteboard(name: .drag).changeCount
                let sampler = DragSampler()
                sampler.begin()
                mouse(.mouseMoved, start)
                sleepMS(100)
                mouse(.leftMouseDown, start)
                sleepMS(400)
                for step in 1...12 {
                    mouse(.leftMouseDragged, CGPoint(x: start.x + CGFloat(step * 12), y: start.y + CGFloat(step * 3)))
                    sleepMS(40)
                }
                mouse(.leftMouseUp, CGPoint(x: start.x + 144, y: start.y + 36))
                sleepMS(1000)
                sampler.end()
                let dragChanged = NSPasteboard(name: .drag).changeCount != dragBefore
                let after = pasteboardHasText(NSPasteboard(name: .drag))
                let moved = textValue(source) != text
                let seen = sampler.firstSeenMS.map { "文字在拖放剪贴板上：从按下后 \($0) ms 到 \(sampler.lastSeenMS ?? $0) ms（\(sampler.seenSamples) 次取样，约 \(sampler.seenSamples * 2) ms）" } ?? "拖放剪贴板上从没出现文字"
                let exposedMS = sampler.firstSeenMS.map { (sampler.lastSeenMS ?? $0) - $0 + 2 } ?? 0
                record("5.1", "拖动选中文字（README：拖放一开始就清掉）", !copiBool("blockTextDragging", true) ? "N/A" : (exposedMS <= 20 && !after ? "PASS" : "FAIL"),
                       "\(seen)；放下 1 秒后还有文字=\(after)；拖放剪贴板变过=\(dragChanged)；文档里的文字被拖动改变了=\(moved)")
            } else {
                record("5.1", "拖动选中文字", "SKIP", "取不到选区位置")
            }
        }
    }
    }

    // ---- 6/7. 浏览器 ----
    // GitHub 的虚拟机上 Brave 在最前面时，辅助功能接口查不到焦点 App（kAXErrorNoValue）：那里用 Chrome（同样是 Chromium）
    let chromium = onCI ? ("com.google.Chrome", "Google Chrome") : ("com.brave.Browser", "Brave Browser")
    for browser in [chromium, ("com.apple.Safari", "Safari")] {
        let short = browser.0 == "com.apple.Safari" ? "Safari" : (browser.0 == "com.google.Chrome" ? "Chrome" : "Brave")
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.0) != nil else {
            record("B-\(short)", "\(short)", "SKIP", "没有安装")
            continue
        }
        guard wants("browsers") else {
            if wants("browsermore") {
                section("\(short) 复制按钮/菜单/右键/拖动") { try browserMoreTests(browser, short: short, &openedWindows) }
            }
            continue
        }
        // 一个浏览器出问题（例如第一次启动时的系统对话框拿走了焦点）只中止这一组
        section("\(short) 浏览器") {
            // 网页正文复制（3 段）
            let paragraph = try openPage(browser, mode: "sel-para")
            openedWindows.append(paragraph)
            try gate(paragraph)
            sleepMS(600)
            focusWebArea(paragraph)
            let paraDiag = webSelectionDiag(paragraph)
            chord(keyC(), cmd)
            let watch = watchGeneralPasteboard(ms: 400)
            let destination = try openTextEdit("dst-\(short)-para.txt", "")
            openedWindows.append(destination)
            try gate(destination)
            chord(keyV(), cmd)
            sleepMS(800)
            let expectedParagraphs = paraTexts.joined(separator: "\n")
            // WebKit 在有外边距的段落之间多给一个空行（Safari 自己复制时也是这样）
            let expectedWebKit = paraTexts.joined(separator: "\n\n")
            let value = textValue(destination)
            let paraOK = (value == expectedParagraphs || value == expectedWebKit) && !watch.sawText
            // 已知限制：Chromium 里网页脚本选中、起点紧挨表单控件的选区读不出来，Copi 拒绝复制（粘贴为空）。读出了错的文字才算失败
            let paraKnown = short != "Safari" && (value ?? "").isEmpty && !watch.sawText
            record("\(short).1", "\(short) 网页 3 段正文（脚本选中）⌘C → TextEdit ⌘V", paraOK ? "PASS" : (paraKnown ? "KNOWN" : "FAIL"),
                   "按 ⌘C 前：\(paraDiag)；系统剪贴板出现文字=\(watch.sawText)；\(value == expectedWebKit ? "段落之间有空行（WebKit 的分段方式）" : describeDiff(value, expectedParagraphs))"
                   + (paraKnown ? "（已知限制：这种脚本选区 Copi 拒绝复制，不泄露、不出错字）" : "")
                   + (short != "Safari" && !paraOK ? "；逐段读：\(chromiumSelectionTrace(paragraph))" : ""))

            // 用鼠标拖选同样 3 段（和真人一样）
            let plain = try openPage(browser, mode: "plain")
            openedWindows.append(plain)
            try gate(plain)
            sleepMS(600)
            if let alpha = staticTextFrame(plain.window, prefix: "Alpha paragraph"), let gamma = staticTextFrame(plain.window, prefix: "Gamma paragraph") {
                try gate(plain)
                mouseSelect(from: CGPoint(x: alpha.minX + 1, y: alpha.midY), to: CGPoint(x: gamma.maxX - 1, y: gamma.midY))
                let mouseDiag = webSelectionDiag(plain)
                try gate(plain)
                chord(keyC(), cmd)
                let mouseWatch = watchGeneralPasteboard(ms: 400)
                let mouseDestination = try openTextEdit("dst-\(short)-mouse.txt", "")
                openedWindows.append(mouseDestination)
                try gate(mouseDestination)
                chord(keyV(), cmd)
                sleepMS(800)
                let mouseValue = textValue(mouseDestination)
                let mouseOK = (mouseValue == expectedParagraphs || mouseValue == expectedWebKit) && !mouseWatch.sawText
                record("\(short).1m", "\(short) 网页 3 段正文（鼠标拖选）⌘C → TextEdit ⌘V", mouseOK ? "PASS" : "FAIL",
                       "按 ⌘C 前：\(mouseDiag)；系统剪贴板出现文字=\(mouseWatch.sawText)；\(mouseValue == expectedWebKit ? "段落之间有空行（WebKit 的分段方式）" : describeDiff(mouseValue, expectedParagraphs))")

                // 三击选中一整段（Beta），⌘C
                if let beta = staticTextFrame(plain.window, prefix: "Beta paragraph") {
                    try gate(plain)
                    tripleClick(CGPoint(x: beta.midX, y: beta.midY))
                    let tripleDiag = webSelectionDiag(plain)
                    try gate(plain)
                    chord(keyC(), cmd)
                    let tripleWatch = watchGeneralPasteboard(ms: 400)
                    let tripleDestination = try openTextEdit("dst-\(short)-triple.txt", "")
                    openedWindows.append(tripleDestination)
                    try gate(tripleDestination)
                    chord(keyV(), cmd)
                    sleepMS(800)
                    let tripleValue = textValue(tripleDestination) ?? ""
                    let trimmed = tripleValue.trimmingCharacters(in: .newlines)
                    record("\(short).1t", "\(short) 三击选中一整段 ⌘C → TextEdit ⌘V", trimmed == paraTexts[1] && !tripleWatch.sawText ? "PASS" : "FAIL",
                           "按 ⌘C 前：\(tripleDiag)；系统剪贴板出现文字=\(tripleWatch.sawText)；\(trimmed == paraTexts[1] ? "内容一致（\(tripleValue.utf16.count) 字符，含首尾换行）" : describeDiff(trimmed, paraTexts[1]))")
                    bringToFront(plain)
                }

                // 点一下网页空白处，⌘A 全选整页，⌘C
                try gate(plain)
                click(CGPoint(x: alpha.maxX + 60, y: alpha.midY))
                try gate(plain)
                chord(keyA(), cmd)
                sleepMS(500)
                let allDiag = webSelectionDiag(plain)
                try gate(plain)
                chord(keyC(), cmd)
                let allWatch = watchGeneralPasteboard(ms: 600)
                let allDestination = try openTextEdit("dst-\(short)-all.txt", "")
                openedWindows.append(allDestination)
                try gate(allDestination)
                chord(keyV(), cmd)
                sleepMS(1500)
                let allValue = textValue(allDestination) ?? ""
                let allLines = allValue.split(separator: "\n", omittingEmptySubsequences: true).map { String($0) }
                let startIndex = allLines.firstIndex(of: longLines[0])
                let run = startIndex.map { index in zip(allLines[index...], longLines).prefix { $0 == $1 }.count } ?? 0
                let hasParas = paraTexts.allSatisfy { allLines.contains($0) }
                record("\(short).2a", "\(short) ⌘A 全选整页 ⌘C → TextEdit ⌘V", run == longLines.count && hasParas && !allWatch.sawText ? "PASS" : "FAIL",
                       "按 ⌘C 前：\(allDiag)；粘贴出 \(allValue.utf16.count) 字符；3 段正文都在=\(hasParas)；401 行连续逐字一致 \(run)/\(longLines.count)；系统剪贴板出现文字=\(allWatch.sawText)")
            } else {
                record("\(short).1m", "\(short) 鼠标拖选", "SKIP", "找不到段落的位置（网页的无障碍树没有建好）")
            }

            // 超长选区（401 行 + 末尾图标和按钮）
            let long = try openPage(browser, mode: "sel-long")
            openedWindows.append(long)
            try gate(long)
            sleepMS(600)
            focusWebArea(long)
            let longDiag = webSelectionDiag(long)
            chord(keyC(), cmd)
            let longWatch = watchGeneralPasteboard(ms: 600)
            let longDestination = try openTextEdit("dst-\(short)-long.txt", "")
            openedWindows.append(longDestination)
            try gate(longDestination)
            chord(keyV(), cmd)
            sleepMS(1500)
            let longValue = textValue(longDestination) ?? ""
            let lines = longValue.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let matching = zip(lines, longLines).prefix { $0 == $1 }.count
            let extra = lines.count - longLines.count
            let longKnown = short != "Safari" && longValue.isEmpty && !longWatch.sawText
            record("\(short).2", "\(short) 超长选区（脚本选中 401 段 + 末尾图标/按钮）", matching == longLines.count && !longWatch.sawText ? "PASS" : (longKnown ? "KNOWN" : "FAIL"),
                   "按 ⌘C 前：\(longDiag)；前 \(matching)/\(longLines.count) 行逐字一致；之后多出 \(extra) 行（\(lines.dropFirst(longLines.count).joined(separator: "⏎").utf16.count) 字符）；系统剪贴板出现文字=\(longWatch.sawText)"
                   + (short != "Safari" && longValue.isEmpty ? "；逐段读：\(chromiumSelectionTrace(long))" : ""))

            // 粘贴进网页输入框：先在 TextEdit 里复制一段已知文字
            let (basicSource, _, _) = try copyFromTextEdit("src-\(short)-field.txt", basicText)
            openedWindows.append(basicSource)
            for field in ["ta", "in"] {
                let page = try openPage(browser, mode: "focus-\(field)")
                openedWindows.append(page)
                try gate(page)
                chord(keyV(), cmd)
                let (status, note) = fieldResult(page, field: field, expected: basicText)
                record("\(short).3-\(field)", "\(short) ⌘V 粘贴进 \(field == "ta" ? "textarea" : "input")", status, note)
            }
            // input 里有落单的代理项、光标在开头：Chromium 读出来的值可能是空的。原有的 5 个字符还在算通过；
            // 整个值被换成粘贴的文字是已知限制（Copi 分不清这种输入框和空输入框，见 spliceValue），其他结果算失败
            if short != "Safari" {
                let lonePage = try openPage(browser, mode: "lone-in")
                openedWindows.append(lonePage)
                try gate(lonePage)
                chord(keyV(), cmd)
                let want = "COPI|in|len=\(basicText.utf16.count + 5)|"
                let title = waitTitle(lonePage, prefix: want) ?? "nil"
                let loneKnown = title.contains("COPI|in|len=\(basicText.utf16.count)|h=\(djb2(basicText))")
                record("\(short).3-lone", "\(short) ⌘V 粘贴进含落单代理项的 input（光标在开头）：原有内容还在", title.contains(want) ? "PASS" : (loneKnown ? "KNOWN" : "FAIL"),
                       title.contains(want) ? "长度一致（\(basicText.utf16.count) + 5 字符）" : "页面标题 \(title.prefix(48))，期望 \(want)"
                       + (loneKnown ? "（已知限制：读到的值是空的，整个输入框被换成了粘贴的文字）" : ""))
                // 空 input 里粘贴 4500 个字：应该一步整体改写值。空输入框要照常走这条路，不该退回逐字键入
                let bigText = String(repeating: "y", count: 4500)
                let (bigSource, _, _) = try copyFromTextEdit("src-\(short)-field-big.txt", bigText)
                openedWindows.append(bigSource)
                let bigPage = try openPage(browser, mode: "focus-in")
                openedWindows.append(bigPage)
                try gate(bigPage)
                chord(keyV(), cmd)
                let (bigStatus, bigNote) = fieldResult(bigPage, field: "in", expected: bigText)
                record("\(short).3-in-big", "\(short) ⌘V 粘贴 4500 个字进空的 input", bigStatus, bigNote)
            }
            // ⇧⌘V（Brave）/ ⌥⇧⌘V（Safari）
            let (variantSource, _, _) = try copyFromTextEdit("src-\(short)-variant.txt", basicText)
            openedWindows.append(variantSource)
            let variantPage = try openPage(browser, mode: "focus-ta")
            openedWindows.append(variantPage)
            try gate(variantPage)
            let secureBefore = IsSecureEventInputEnabled()
            if short == "Brave" {
                chord(keyV(), cmdShift)
            } else {
                chord(keyV(), cmdShiftOpt)
            }
            let (variantStatus, variantNote) = fieldResult(variantPage, field: "ta", expected: basicText)
            record("\(short).5", short == "Brave" ? "Brave ⇧⌘V 粘贴进 textarea" : "Safari ⌥⇧⌘V 粘贴进 textarea", variantStatus, variantNote + "（按键时 Secure Input=\(secureBefore)）")
            // 复制按钮、编辑菜单、右键、拖动
            section("\(short) 复制按钮/菜单/右键/拖动") { try browserMoreTests(browser, short: short, &openedWindows) }

            // 密码框
            let (passwordSource, _, _) = try copyFromTextEdit("src-\(short)-pw.txt", passwordText)
            openedWindows.append(passwordSource)
            let passwordPage = try openPage(browser, mode: "focus-pw")
            openedWindows.append(passwordPage)
            try gate(passwordPage)
            chord(keyV(), cmd)
            let (pwStatus, pwNote) = fieldResult(passwordPage, field: "pw", expected: passwordText)
            record("\(short).4", "\(short) ⌘V 粘贴进密码框（Secure Input）", pwStatus, pwNote)
            // ⇧⌘V（Brave）/ ⌥⇧⌘V（Safari）粘贴进密码框：Secure Input 期间 tap 看不到按键，靠这两个键的热键接管。
            // 用同一个页面（再开一页时 Safari 会弹出"是否存储密码"之类的提示打断）、换一段文字，清空密码框再粘贴
            let pwVariantText = "CopiPw-456_variant"
            let (pwVariantSource, _, _) = try copyFromTextEdit("src-\(short)-pw-variant.txt", pwVariantText)
            openedWindows.append(pwVariantSource)
            bringToFront(passwordPage)
            sleepMS(500)
            try gate(passwordPage)
            chord(keyA(), cmd)
            chord(CGKeyCode(kVK_Delete))
            sleepMS(300)
            try gate(passwordPage)
            let pwSecureBefore = IsSecureEventInputEnabled()
            chord(keyV(), short == "Brave" ? cmdShift : cmdShiftOpt)
            let (pwVariantStatus, pwVariantNote) = fieldResult(passwordPage, field: "pw", expected: pwVariantText)
            // 按键时 Secure Input 还没开：走的是按键拦截，热键这条路没测到
            record("\(short).4s", short == "Brave" ? "Brave ⇧⌘V 粘贴进密码框" : "\(short) ⌥⇧⌘V 粘贴进密码框",
                   pwVariantStatus == "PASS" && !pwSecureBefore ? "CHECK" : pwVariantStatus,
                   pwVariantNote + "（按键时 Secure Input=\(pwSecureBefore)\(pwSecureBefore ? "" : "：热键这条路没测到")）")
            // 测完把密码页关掉：Chrome 退到后台时不关它开的 Secure Input（焦点还在密码框里），之后的测试就都在 Secure Input 下跑，
            // 平常的路线（按键拦截）反而测不到了。Secure Input 下的路线由 secure 那一组专门测
            closeTab(passwordPage)
            openedWindows.removeAll { CFEqual($0.window, passwordPage.window) }
            var released = !IsSecureEventInputEnabled()
            for _ in 0..<30 where !released {
                sleepMS(100)
                released = !IsSecureEventInputEnabled()
            }
            record("\(short).4x", "\(short) 测完密码框后关掉那一页：Secure Input 随之关掉", "INFO", released ? "已关掉" : "还开着\(secureInputHolder())")
        }
    }

    // ---- 8. 终端 ----
    if wants("terminal") {
        section("Terminal") { try terminalTests(&openedWindows, app: terminal, prefix: "T") }
    }
    if wants("sudo") {
        section("sudo 提示符") { try fakeSudoTest(&openedWindows) }
    }

    // ---- 9. 设置守护 ----
    if wants("guard") {
        let before = copiStatusDescription()
        _ = run("/usr/bin/defaults", ["write", "com.gokoding.Copi", "isOn", "-bool", "false"])
        sleepMS(2500)
        let during = copiStatusDescription()
        _ = run("/usr/bin/defaults", ["write", "com.gokoding.Copi", "isOn", "-bool", "true"])
        sleepMS(2500)
        let after = copiStatusDescription()
        let cleaned = settingsWarningBeforeTests ? false : dismissCopiWarning()
        record("9.1", "设置守护（别的程序把 isOn 改成 false）", during != before && during.contains("Warning") ? "PASS" : "CHECK",
               "菜单栏图标描述：之前「\(before)」→ 改成 false 后「\(during)」→ 改回 true 后「\(after)」（README：要在菜单里 Dismiss 才消失）；测完点掉警告=\(cleaned)（通知是否出现需要人看；isOn 已改回 true）")
    }

    // ---- 10. watchdog（会重启 Copi） ----
    if wants("watchdog") {
        watchdogTests()
        sleepMS(4000)
    }

    // ---- 11. iTerm2 及其后各组：每组单独兜底，一组中止不影响下一组（每个按键前仍然过 gate） ----
    if wants("iterm") {
        section("iTerm2") { try itermTests(&openedWindows) }
    }
    if wants("vm") {
        section("虚拟机/远程桌面") { try vmFallbackTests(&openedWindows) }
    }
    if wants("slack") {
        section("Slack") { try slackTests(&openedWindows) }
    }
    if wants("vscode") {
        section("VS Code") { try vscodeTests(&openedWindows) }
    }
    if wants("matrix") {
        section("别的程序写剪贴板") { try clipboardMatrixTests(&openedWindows) }
        section("复制不了、经过剪贴板的复制") { try copyMatrixTests(&openedWindows) }
    }
    if wants("concealed") {
        section("密码管理器式复制") { try concealedTests(&openedWindows) }
    }
    if wants("secure") {
        section("Secure Input 开着时") { try secureInputTests(&openedWindows) }
    }
    // 上面改过 Copi 的设置（允许剪贴板回退）：点掉警告（测试前就有的警告不点）
    if !settingsWarningBeforeTests {
        _ = dismissCopiWarning()
    }
    // 锁屏之前把测试窗口都关掉：锁屏、解锁之后你可能已经在用电脑，那之后测试程序只往它自己新开的 TextEdit 窗口里粘贴，不再关窗口
    closeOpened()
    var lockWindows: [TestWindow] = []
    if wants("lock") {
        section("锁屏") { try lockTest(&lockWindows) }
    }
}

// 最近一次 clickMenuItem 点下去之前看到的（写进报告）：分辨"菜单没开、没点到""点了灰掉的项"和 Copi 自己的问题
var lastMenuClickState = ""

// 打开 App 的菜单，用鼠标点有这个快捷键（⌘ + commandChar）的菜单项
func clickMenuItem(_ target: TestWindow, commandChar: String) throws -> Bool {
    lastMenuClickState = ""
    let app = AXUIElementCreateApplication(target.pid)
    guard let menuBar = axElement(ax(app, kAXMenuBarAttribute)) else {
        return false
    }
    for barItem in axChildren(menuBar) {
        guard let menu = axChildren(barItem).first else {
            continue
        }
        let hasItem = axChildren(menu).contains {
            axString($0, kAXMenuItemCmdCharAttribute) == commandChar && (ax($0, kAXMenuItemCmdModifiersAttribute) as? NSNumber)?.intValue == 0
        }
        guard hasItem else {
            continue
        }
        guard let barFrame = frame(barItem) else {
            return false
        }
        try gate(target)
        click(center(barFrame))
        sleepMS(500)
        // 点之前确认菜单真的开着、那个位置就是这个菜单项（刚启动的 App 第一次打开菜单可能更慢，最多再等 1 秒）
        var found: (item: AXUIElement, frame: CGRect)?
        for _ in 0..<11 where found == nil {
            if let openMenu = axChildren(barItem).first,
               let item = axChildren(openMenu).first(where: {
                   axString($0, kAXMenuItemCmdCharAttribute) == commandChar && (ax($0, kAXMenuItemCmdModifiersAttribute) as? NSNumber)?.intValue == 0
               }),
               let itemFrame = frame(item), isWithin(elementAt(center(itemFrame)), item) {
                found = (item, itemFrame)
            } else {
                sleepMS(100)
            }
        }
        guard let found else {
            lastMenuClickState = "菜单没有打开（点的位置不是这个菜单项）"
            chord(CGKeyCode(kVK_Escape))
            return false
        }
        lastMenuClickState = "点之前菜单项可用=\((ax(found.item, kAXEnabledAttribute) as? Bool).map { "\($0)" } ?? "读不到")"
        click(center(found.frame))
        sleepMS(300)
        return true
    }
    return false
}

// 在文字上点右键，点标题是 titles 之一的菜单项
func contextMenuClick(_ target: TestWindow, location: Int, titles: [String]) throws -> Bool {
    let point: CGPoint
    if let bounds = boundsOfRange(target, location, 1), bounds.width > 0 {
        point = center(bounds)
    } else if let area = textArea(target), let areaFrame = frame(area) {
        point = CGPoint(x: areaFrame.minX + 30, y: areaFrame.minY + 12)
    } else {
        return false
    }
    try gate(target)
    rightClick(point)
    let app = AXUIElementCreateApplication(target.pid)
    var menus: [AXUIElement] = []
    var level = axChildren(app).filter { role($0) != kAXMenuBarRole }
    for _ in 0..<4 {
        var next: [AXUIElement] = []
        for element in level {
            if role(element) == kAXMenuRole {
                menus.append(element)
            } else {
                next.append(contentsOf: axChildren(element))
            }
        }
        level = next
    }
    let item = menus.lazy.flatMap { axChildren($0) }.first { titles.contains(axString($0, kAXTitleAttribute) ?? "") }
    guard let item, let itemFrame = frame(item) else {
        chord(CGKeyCode(kVK_Escape))
        return false
    }
    click(center(itemFrame))
    sleepMS(300)
    return true
}

// 各终端设备上的进程（终端设备、状态、程序名）
func ttyProcesses() -> [(tty: String, stat: String, name: String)] {
    run("/bin/ps", ["-A", "-o", "tty=,stat=,ucomm="]).output.split(separator: "\n").compactMap { line in
        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count == 3, parts[0] != "??" else {
            return nil
        }
        return (String(parts[0]), String(parts[1]), String(parts[2]).trimmingCharacters(in: .whitespaces))
    }
}

// Terminal 里前台在运行、又不是 shell 的程序有几个（只数个数，不记名字）
func terminalBusyTabs() -> Int {
    let terminalPIDs = Set(pids(terminal.0))
    var parent: [pid_t: pid_t] = [:]
    var rows: [(pid: pid_t, stat: String, name: String)] = []
    for line in run("/bin/ps", ["-A", "-o", "pid=,ppid=,stat=,ucomm="]).output.split(separator: "\n") {
        let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
        guard parts.count == 4, let pid = pid_t(parts[0]), let ppid = pid_t(parts[1]) else {
            continue
        }
        parent[pid] = ppid
        rows.append((pid, String(parts[2]), String(parts[3])))
    }
    func underTerminal(_ pid: pid_t) -> Bool {
        var current = pid
        for _ in 0..<30 {
            guard let up = parent[current], up > 1 else {
                return false
            }
            if terminalPIDs.contains(up) {
                return true
            }
            current = up
        }
        return false
    }
    let shells: Set<String> = ["zsh", "bash", "fish", "sh", "dash", "ksh", "tcsh", "csh", "login"]
    return rows.filter { $0.stat.contains("+") && !shells.contains($0.name.trimmingCharacters(in: CharacterSet(charactersIn: "-"))) && underTerminal($0.pid) }.count
}

// Terminal 窗口里有几个标签页（没有标签栏就是 1 个）
func terminalTabCount(_ window: AXUIElement) -> Int {
    guard let group = findDescendant(window, maxDepth: 4, { role($0) == kAXTabGroupRole }) else {
        return 1
    }
    return max(1, axChildren(group).filter { role($0) == kAXRadioButtonRole }.count)
}

// 各终端设备上的进程，带 pid
func ttyProcessList() -> [(pid: String, tty: String, stat: String, name: String)] {
    run("/bin/ps", ["-A", "-o", "pid=,tty=,stat=,ucomm="]).output.split(separator: "\n").compactMap { line in
        let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
        guard parts.count == 4, parts[1] != "??" else {
            return nil
        }
        return (String(parts[0]), String(parts[1]), String(parts[2]), String(parts[3]).trimmingCharacters(in: .whitespaces))
    }
}

// 进程启动时的环境变量（KERN_PROCARGS2，和 Copi 读的方法一样；只能读同一用户的进程）
// 进程的启动参数（KERN_PROCARGS2，和 processEnvironment 一样读）
func processArguments(pid: pid_t) -> [String]? {
    var argumentLimit: Int32 = 0
    var limitSize = MemoryLayout<Int32>.size
    var limitMIB: [Int32] = [CTL_KERN, KERN_ARGMAX]
    guard sysctl(&limitMIB, 2, &argumentLimit, &limitSize, nil, 0) == 0, argumentLimit > 0 else {
        return nil
    }
    var size = Int(argumentLimit)
    var buffer = [UInt8](repeating: 0, count: size)
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
        return nil
    }
    var argumentCount = 0
    for (offset, byte) in buffer.prefix(MemoryLayout<Int32>.size).enumerated() {
        argumentCount |= Int(byte) << (8 * offset)
    }
    var index = MemoryLayout<Int32>.size
    while index < size, buffer[index] != 0 {
        index += 1
    }
    while index < size, buffer[index] == 0 {
        index += 1
    }
    var arguments: [String] = []
    while argumentCount > 0, index < size {
        let start = index
        while index < size, buffer[index] != 0 {
            index += 1
        }
        arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
        index += 1
        argumentCount -= 1
    }
    return arguments
}

func processEnvironment(pid: pid_t) -> [String: String]? {
    var argumentLimit: Int32 = 0
    var limitSize = MemoryLayout<Int32>.size
    var limitMIB: [Int32] = [CTL_KERN, KERN_ARGMAX]
    guard sysctl(&limitMIB, 2, &argumentLimit, &limitSize, nil, 0) == 0, argumentLimit > 0 else {
        return nil
    }
    var size = Int(argumentLimit)
    var buffer = [UInt8](repeating: 0, count: size)
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
        return nil
    }
    // 布局：argc、程序路径、补齐用的 0、各个参数、各个环境变量（都以 0 结尾）
    var argumentCount = 0
    for (offset, byte) in buffer.prefix(MemoryLayout<Int32>.size).enumerated() {
        argumentCount |= Int(byte) << (8 * offset)
    }
    var index = MemoryLayout<Int32>.size
    while index < size, buffer[index] != 0 {
        index += 1
    }
    while index < size, buffer[index] == 0 {
        index += 1
    }
    while argumentCount > 0, index < size {
        while index < size, buffer[index] != 0 {
            index += 1
        }
        index += 1
        argumentCount -= 1
    }
    var environment: [String: String] = [:]
    while index < size {
        let start = index
        while index < size, buffer[index] != 0 {
            index += 1
        }
        guard index > start else {
            break
        }
        let entry = String(decoding: buffer[start..<index], as: UTF8.self)
        if let separator = entry.firstIndex(of: "=") {
            environment[String(entry[..<separator])] = String(entry[entry.index(after: separator)...])
        }
        index += 1
    }
    return environment
}

// 这个 zsh 是测试用的（环境里的 ZDOTDIR 指向测试用的配置目录）
func isTestShell(pid: String) -> Bool {
    guard let number = pid_t(pid), let zdot = processEnvironment(pid: number)?["ZDOTDIR"] else {
        return false
    }
    return zdot == fixtures.appendingPathComponent("zdot").path || zdot.hasSuffix("/selftest/fixtures/zdot")
}

// 这个终端设备上前台只有测试会用到的程序（测试 shell、T.3 的 /bin/bash、tmux、假 sudo）
func terminalForegroundIsOurs(_ tty: String) -> Bool {
    let foreground = ttyProcessList().filter { $0.tty == tty && $0.stat.contains("+") }.map(\.name)
    return !foreground.isEmpty && foreground.allSatisfy { ["zsh", "bash", "tmux", "sudo"].contains($0) || testForegroundProgram($0) }
}

// 测试自己在测试 shell 里启动的程序（Neovim、Python）：它在前台时测试窗口照样算是对的
var testForegroundProgram: (String) -> Bool = { _ in false }

// 测试 shell 里由测试启动、还没退出的程序：先 SIGTERM（让它自己恢复终端设置），2 秒后还在就 SIGKILL
func stopTestPrograms(on tty: String, _ matches: (String) -> Bool) {
    for signal in [SIGTERM, SIGKILL] {
        let leftover = ttyProcessList().filter { $0.tty == tty && matches($0.name) }.compactMap { pid_t($0.pid) }
        guard !leftover.isEmpty else {
            return
        }
        leftover.forEach { kill($0, signal) }
        sleepMS(2000)
    }
}

// 打开测试用的 Terminal 窗口：认准"新出现的那一个窗口"+"新出现的那一个终端设备，前台是测试用的 zsh"。
// Terminal 原本没在运行时先打开它、等它恢复上次的窗口，免得把恢复出来的窗口当成测试窗口。others：Terminal 里别的窗口、标签页数
// 上一次没打开测试窗口时看到的数量（只有数字：多出来的窗口、新终端设备、其中的测试 shell）
var lastTerminalOpenCounts = ""

func openTestTerminal() -> (term: TestWindow, others: Int, tty: String)? {
    if pids(terminal.0).isEmpty {
        _ = run("/usr/bin/open", ["-a", terminal.1])
        sleepMS(3500)
        // 虚拟机上 Terminal 自己开的空窗口关掉（Copi 只在测试窗口是唯一的标签页时走 tmux）；你的电脑上绝不关你的窗口
        if onCI {
            for pid in pids(terminal.0) {
                for window in windows(pid) {
                    if let close = axElement(ax(window, kAXCloseButtonAttribute)) {
                        AXUIElementPerformAction(close, kAXPressAction as CFString)
                    }
                }
            }
            sleepMS(1000)
        }
    }
    let command = fixtures.appendingPathComponent("copiterm.command")
    let existing = pids(terminal.0).flatMap { windows($0) }
    let ttysBefore = Set(ttyProcessList().map(\.tty))
    openWith(terminal.1, command.path)
    var deadline = Date().addingTimeInterval(20)
    // 有的 shell 启动时丢掉排进来的命令，Terminal 打开 .command 只剩一个空窗口：12 秒后还没看到测试 shell，就在这个窗口里
    // 自己打启动命令；连窗口都没有时改用 Terminal 的脚本接口（第一次会问要不要允许测试程序控制 Terminal）
    var triedScript = terminal.0 != "com.apple.Terminal"
    var scriptResult = "没试"
    let fallbackAt = Date().addingTimeInterval(12)
    while Date() < deadline {
        let processes = ttyProcessList()
        let newTTYs = Set(processes.map(\.tty)).subtracting(ttysBefore)
        let testTTYs = newTTYs.filter { tty in
            processes.contains { $0.tty == tty && $0.stat.contains("+") && $0.name == "zsh" && isTestShell(pid: $0.pid) }
        }
        var newWindows: [(pid: pid_t, window: AXUIElement)] = []
        for pid in pids(terminal.0) {
            for window in windows(pid) where !existing.contains(where: { CFEqual($0, window) }) {
                newWindows.append((pid, window))
            }
        }
        if newWindows.count == 1, testTTYs.count == 1, let tty = testTTYs.first {
            let (pid, window) = newWindows[0]
            var term = TestWindow(bundleID: terminal.0, appName: terminal.1, pid: pid, window: window)
            // 每次发按键前：窗口里只有这一个标签页，它的前台是测试用的程序
            term.contentCheck = { terminalTabCount(window) == 1 && terminalForegroundIsOurs(tty) }
            return (term, windows(pid).count - 1 + terminalTabCount(window) - 1, tty)
        }
        // 新终端设备上的前台进程：有几个、其中几个叫 zsh、几个 zsh 读得到环境变量（只记数量，不记进程名）
        let foreground = processes.filter { newTTYs.contains($0.tty) && $0.stat.contains("+") }
        let zshes = foreground.filter { $0.name == "zsh" }
        let readable = zshes.filter { pid_t($0.pid).flatMap { processEnvironment(pid: $0) } != nil }.count
        let withZDOTDIR = zshes.filter { pid_t($0.pid).flatMap { processEnvironment(pid: $0)?["ZDOTDIR"] } != nil }.count
        let withPATH = zshes.filter { pid_t($0.pid).flatMap { processEnvironment(pid: $0)?["PATH"] } != nil }.count
        // 只记是/否：新窗口里有没有出现测试 shell 的提示符（copitest…），不记窗口里别的内容
        let testPrompt = newWindows.contains { (pid, window) in
            (textValue(TestWindow(bundleID: terminal.0, appName: terminal.1, pid: pid, window: window)) ?? "").contains("copitest")
        }
        let ranScript = processes.filter { newTTYs.contains($0.tty) }
            .contains { pid_t($0.pid).flatMap { processArguments(pid: $0) }?.contains { $0.hasSuffix("copiterm.command") } == true }
        if !triedScript, Date() > fallbackAt, testTTYs.isEmpty {
            triedScript = true
            let dir = fixtures.path.replacingOccurrences(of: "'", with: "")
            let command = "cd '\(dir)' && export ZDOTDIR='\(dir)/zdot' && exec /bin/zsh -i"
            if newWindows.count == 1, newTTYs.count == 1, foreground.count == 1 {
                // 有的 shell 启动时丢掉之前排进来的命令（.command、脚本接口送进去的都是）：等它停在提示符前，在这个新窗口里自己把命令打进去，
                // 和用户手动输入一样。打字前照样确认焦点在这个窗口上
                let (pid, window) = newWindows[0]
                let fresh = TestWindow(bundleID: terminal.0, appName: terminal.1, pid: pid, window: window)
                bringToFront(fresh)
                if (try? gate(fresh)) != nil {
                    // 打字时用英文输入法（中文输入法会把字母变成候选字），打完切回
                    let previousSource = currentInputSourceID()
                    let switched = previousSource != "com.apple.keylayout.ABC" && selectInputSource("com.apple.keylayout.ABC")
                    typeText(command)
                    sleepMS(300)
                    // 只记是/否：窗口里看不看得到这条启动命令（不记窗口里别的内容）
                    let echoed = (textValue(fresh) ?? "").contains("ZDOTDIR=")
                    pressReturn()
                    if switched, let previousSource {
                        _ = selectInputSource(previousSource)
                    }
                    scriptResult = "在新窗口里打了启动命令（窗口里看得到这条命令=\(echoed)；换过英文输入法=\(switched)）"
                } else {
                    scriptResult = "新窗口没拿到焦点，没打启动命令"
                }
            } else {
                let result = run("/usr/bin/osascript", ["-e", "tell application \"Terminal\" to do script \"\(command)\""], timeout: 60)
                // 只记退出码和 AppleScript 的错误号（-1743：没有允许控制 Terminal），不记输出
                let code = result.output.range(of: #"\((-?\d+)\)"#, options: .regularExpression).map { String(result.output[$0]) } ?? ""
                scriptResult = result.status == 0 ? "脚本接口成功" : "脚本接口失败（退出码 \(result.status)\(code.isEmpty ? "" : "，错误 " + code)）"
            }
            deadline = Date().addingTimeInterval(20)
            continue
        }
        lastTerminalOpenCounts = "新窗口 \(newWindows.count) 个、新终端设备 \(newTTYs.count) 个、其中测试 shell \(testTTYs.count) 个；"
            + "新终端设备上的前台进程 \(foreground.count) 个、zsh \(zshes.count) 个、读得到环境变量的 zsh \(readable) 个、"
            + "设了 ZDOTDIR 的 \(withZDOTDIR) 个、读得到 PATH 的 \(withPATH) 个；窗口里出现测试提示符=\(testPrompt)；"
            + "有进程在运行测试的启动脚本=\(ranScript)；后备做法：\(scriptResult)"
        sleepMS(250)
    }
    return nil
}

// Terminal 读不准屏幕上的文字：和 iTerm2 一样用标记文件判断"有没有执行、内容全不全"
func terminalTests(_ openedWindows: inout [TestWindow], app terminal: (String, String), prefix T: String) throws {
    guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: terminal.0) != nil else {
        record(T, terminal.1, "SKIP", "没有安装")
        return
    }
    let busy = terminalBusyTabs()
    if busy > 0 {
        record("\(T).0", "Terminal 其他标签页", "INFO", "有 \(busy) 个前台程序不是 shell：Copi 按窗口标题判断前台程序，结果可能受影响")
    }
    guard let opened = openTestTerminal() else {
        record(T, terminal.1, "SKIP", "\(terminal.1) 没有打开测试用的新窗口（新窗口、新终端设备上的测试 shell 都要正好一个；看到的是：\(lastTerminalOpenCounts)）")
        return
    }
    let term = opened.term
    let otherWindows = opened.others
    bringToFront(term)
    sleepMS(800)
    let markers = fixtures.appendingPathComponent("markers")
    try? FileManager.default.createDirectory(at: markers, withIntermediateDirectories: true)
    // 测试 shell 的当前目录就是 fixtures：用相对路径，命令短，打字快
    let dir = "markers"
    func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: markers.appendingPathComponent(name).path)
    }
    // Copi 在 Terminal 里是一个个字打出来的：等它打完再看、再按回车
    func paste(_ text: String, _ sourceName: String, wait: Int? = nil) throws {
        let (source, _, _) = try copyFromTextEdit(sourceName, text)
        openedWindows.append(source)
        bringToFront(term)
        try gate(term)
        chord(keyV(), cmd)
        sleepMS(wait ?? min(12000, 2000 + 80 * text.utf16.count))
    }
    func enter() throws {
        try gate(term)
        pressReturn()
        sleepMS(1500)
    }
    func clearLine() throws {
        try gate(term)
        chord(CGKeyCode(kVK_ANSI_C), ctrl)
        sleepMS(400)
    }

    // 虚拟机上出错时写出终端最后的一段（测试 shell 的提示符和测试命令，没有别的内容），看出是没打进去、打晚了还是回车没到
    func screenTail() -> String {
        onCI ? "；终端末尾=" + String(terminalText(term).suffix(120)).debugDescription : ""
    }

    // 单行：插入，不执行；回车后内容完整
    try paste("touch \(dir)/t1", "src-term-1.txt")
    let ran1 = exists("t1")
    let beforeEnter1 = screenTail()
    try enter()
    let ok1 = !ran1 && exists("t1")
    record("\(T).1", "\(terminal.1) 单行粘贴：插入不执行、内容完整", ok1 ? "PASS" : "FAIL",
           "按回车前就被执行了=\(ran1)；按回车后命令完整执行（标记文件在）=\(exists("t1"))" + (ok1 ? "" : "（回车前\(beforeEnter1)）（回车后\(screenTail())）"))

    // 单行里夹着 Tab：zsh 里包成 bracketed paste 键入，Tab 原样插入；回车后文件里正好是 a⇥b。Tab 放在引号里：
    // 在标记外面键入的话补全会吞掉它或者补出别的东西，内容就不对
    try paste("printf '%s' 'a\tb' > \(dir)/t1t", "src-term-tab.txt")
    let ranTab = exists("t1t")
    try enter()
    let tabContent = try? String(contentsOf: markers.appendingPathComponent("t1t"), encoding: .utf8)
    record("\(T).1t", "\(terminal.1) 单行粘贴夹着 Tab：插入不执行、Tab 原样保留", !ranTab && tabContent == "a\tb" ? "PASS" : "FAIL",
           "按回车前就被执行了=\(ranTab)；按回车后文件内容=\(tabContent?.debugDescription ?? "没有文件")"
           // 出错时分清是哪一种：上一项的命令留在行上、和这一项拼成一行执行（会建出 t1printf），还是上一项的回车成了粘贴里的换行（t1 这时才出现）
           + (tabContent == "a\tb" ? "" : "；拼成一行（t1printf 在）=\(exists("t1printf"))；t1 现在在=\(exists("t1"))" + screenTail()))

    // 多行：插入，不执行；回车后两行都执行
    try paste("touch \(dir)/t2a\ntouch \(dir)/t2b", "src-term-2.txt")
    let ran2 = exists("t2a") || exists("t2b")
    try enter()
    record("\(T).2", "\(terminal.1) 多行粘贴：插入不执行、内容完整", !ran2 && exists("t2a") && exists("t2b") ? "PASS" : "FAIL",
           "按回车前就被执行了=\(ran2)；按回车后两行都执行=\(exists("t2a") && exists("t2b"))")

    // 前台是 Neovim：通过它自己的 RPC 接口粘贴，和真正的粘贴一样（README："pastes through Neovim's own RPC socket"）。
    // 普通模式里粘贴带括号、引号、缩进的两行，存盘退出，看文件内容；系统剪贴板上一直没有文字
    if let nvim = ["/opt/homebrew/bin/nvim", "/usr/local/bin/nvim"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
        let file = markers.appendingPathComponent("t9.txt")
        try? FileManager.default.removeItem(at: file)
        try gate(term)
        // Neovim 在前台时测试窗口照样算对；不管这一项怎么结束，都不让它留在测试 shell 里（后面的项目要回到提示符）
        testForegroundProgram = { $0 == "nvim" }
        defer {
            stopTestPrograms(on: opened.tty) { $0 == "nvim" }
            testForegroundProgram = { _ in false }
        }
        typeText("\(nvim) --clean -n \(dir)/t9.txt")
        pressReturn()
        sleepMS(2500)
        let text9 = "alpha (one)\n  beta \"two\""
        let (source9, _, _) = try copyFromTextEdit("src-term-9.txt", text9)
        openedWindows.append(source9)
        bringToFront(term)
        try gate(term)
        let watcher = TypeWatcher(.general) { $0.contains(NSPasteboard.PasteboardType.string.rawValue) }
        chord(keyV(), cmd)
        sleepMS(2500)
        let presence = watcher.stop().presence
        try gate(term)
        chord(CGKeyCode(kVK_Escape))
        sleepMS(300)
        typeText(":wq")
        pressReturn()
        sleepMS(1500)
        let content = try? String(contentsOf: file, encoding: .utf8)
        record("\(T).9", "\(terminal.1) 里前台是 Neovim：通过它自己的接口粘贴两行（不键入、不经过剪贴板），内容完整",
               content == text9 + "\n" && presence.first == nil ? "PASS" : "FAIL",
               "存盘后的文件=\(content.map { "\($0.utf16.count) 字符\($0 == text9 + "\n" ? "，一致" : "，不一致：\($0.debugDescription)")" } ?? "没有")；\(presence.summary("文字"))")
    } else {
        record("\(T).9", "\(terminal.1) 里前台是 Neovim", "SKIP", "没有安装 Neovim")
    }

    // 前台程序在按行读（Python 的 input()）：单行照常打进去，回车之前不执行（README："single lines are typed when the program is reading a whole line"）
    if FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") {
        try? FileManager.default.removeItem(at: markers.appendingPathComponent("t10"))
        try gate(term)
        // /usr/bin/python3 运行起来的进程名是 Python 或 python3.x
        let isPython: (String) -> Bool = { $0.lowercased().hasPrefix("python") }
        testForegroundProgram = isPython
        defer {
            stopTestPrograms(on: opened.tty, isPython)
            testForegroundProgram = { _ in false }
        }
        // 先读到这一行再建文件（写成 open(...).write(input()) 的话，文件在等输入之前就建好了）
        typeText("/usr/bin/python3 -c 's=input(); open(\"\(dir)/t10\", \"w\").write(s)'")
        pressReturn()
        sleepMS(3000)
        let line10 = "copi line (a) \"b\" $HOME"
        try paste(line10, "src-term-10.txt", wait: 3000)
        let early10 = exists("t10")
        try enter()
        sleepMS(500)
        let content10 = try? String(contentsOf: markers.appendingPathComponent("t10"), encoding: .utf8)
        record("\(T).10", "\(terminal.1) 里程序在等输入一行（Python 的 input()）：单行原样打进去，回车之前什么都不发生",
               !early10 && content10 == line10 ? "PASS" : "FAIL",
               "回车前就有结果=\(early10)；收到的=\(content10.map { $0 == line10 ? "一致" : $0.debugDescription } ?? "没有")")
        try clearLine()
    }

    // 在等单个按键（zsh 的 read -q）时粘贴 "yx"：一个字都不送。之后按回车回答它：回答是 n 说明什么都没送进去，
    // 是 y 说明粘贴的第一个字符回答了它（后面的 x 落到下一个提示符，回车执行它只会报找不到命令）
    try gate(term)
    typeText("read -q REPLY; print -r -- $REPLY > \(dir)/t8")
    pressReturn()
    sleepMS(1000)
    try paste("yx", "src-term-8.txt")
    try enter()
    let answer8 = (try? String(contentsOf: markers.appendingPathComponent("t8"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    record("\(T).8", "\(terminal.1) 在等单个按键（zsh 的 read -q）时粘贴：一个字都不送", answer8 == "n" ? "PASS" : "FAIL",
           "提示得到的回答=\(answer8 ?? "没有")（n：粘贴什么都没送，回车回答了它；y：粘贴的第一个字符回答了它）")
    try clearLine()

    // 打字中断：Copi 打字时按下的回车被拦下、打字停下。zsh 里单行是包成 bracketed paste 打的，漏进去的回车只是换行，测不出来：
    // 换成不认 bracketed paste 的 /bin/bash 3.2（不读配置、不存历史）。
    // （之前这里粘贴的一行有 4020 个字符，超过 Copi 键入的上限 4000：Copi 直接拒绝、一个字都没打，这一项其实什么都没测到）
    if terminal.0 == "com.apple.Terminal" {
        try gate(term)
        typeText("HISTFILE=/dev/null /bin/bash --norc --noprofile")
        pressReturn()
        sleepMS(1500)
        // 打到一半停下时打出来的是开头那一段：t3a 在开头，t3b 在最后
        let line = "touch \(dir)/t3a; : " + String(repeating: "x", count: 3800) + "; touch \(dir)/t3b"
        let (source, _, _) = try copyFromTextEdit("src-term-3.txt", line)
        openedWindows.append(source)
        bringToFront(term)
        let lengthBefore = terminalText(term).utf16.count
        try gate(term)
        chord(keyV(), cmd)
        // 看到开始打字（终端里的文字变长）再按回车，看不到就 1.5 秒后按
        var sawTyping = false
        for _ in 0..<30 where !sawTyping {
            sleepMS(50)
            sawTyping = terminalText(term).utf16.count > lengthBefore + 200
        }
        try gate(term)
        let typedAtReturn = terminalText(term).utf16.count - lengthBefore
        // 诊断：按回车时 Secure Input 开着没有（开着时 Copi 的按键拦截看不到回车）、Copi 的进度小窗口还显示着没有（还在打字）
        let secureAtReturn = IsSecureEventInputEnabled()
        let hudAtReturn = copiHUDVisible()
        let probe = ReturnProbe.start()
        let returnAt = Date()
        var returnHeld = ""
        chord(CGKeyCode(kVK_Return)) {
            returnHeld = heldStateDiag(CGKeyCode(kVK_Return))
        }
        let recordsAtReturn = inputRecordsDiag()
        let hudAfterReturn = copiHUDVisible()
        sleepMS(2500)
        let hudLater = copiHUDVisible()
        let passed = probe?.stop()
        let typedAfter = terminalText(term).utf16.count - lengthBefore
        let ranEarly = (exists("t3a"), exists("t3b"))
        // 再按一次回车：执行停下时打出来的那一段
        try gate(term)
        pressReturn()
        sleepMS(1500)
        let ranLater = (exists("t3a"), exists("t3b"))
        let status: String
        let note: String
        if ranEarly.0 || ranEarly.1 {
            status = ranEarly.1 ? "CHECK" : "FAIL"
            note = ranEarly.1 ? "按回车时整行已经打完了（这一项没测到）" : "打字时按下的回车把打了一半的命令执行了"
        } else if ranLater.0 && !ranLater.1 {
            status = "PASS"
            note = "回车被拦下、打字停在中间；再按一次回车执行的是打出来的前半段"
        } else {
            status = ranLater.1 ? "FAIL" : "CHECK"
            note = ranLater.1 ? "第一次回车之后打字没有停下，整行都打完了" : "两次回车之后都没有执行（回车可能按得太早，打字还没开始）"
        }
        record("\(T).3", "\(terminal.1) 里 Copi 打字时按回车（/bin/bash 3.2）：回车被拦下、打字停下", status,
               "\(note)；看到开始打字=\(sawTyping)；按回车时终端里多了 \(typedAtReturn) 个字符，2.5 秒后多了 \(typedAfter) 个（整行 \(line.utf16.count) 个）；第一次回车后 t3a=\(ranEarly.0) t3b=\(ranEarly.1)，第二次回车后 t3a=\(ranLater.0) t3b=\(ranLater.1)"
                   + "；（诊断）按回车时 Secure Input=\(secureAtReturn)\(secureAtReturn ? secureInputHolder() : "")，回车\(returnHeld)，刚按完\(recordsAtReturn)，Copi 的进度小窗口：按之前显示着=\(hudAtReturn)、刚按完=\(hudAfterReturn)、2.5 秒后=\(hudLater)"
                   + "；排在 Copi 后面的 tap：\(passed.map { $0.isEmpty ? (secureAtReturn ? "没看到回车（Secure Input 开着时 tap 什么键都看不到，说明不了 Copi 拦没拦下）" : "没看到回车（Copi 拦下了）") : "回车在 \($0.map { String(Int(($0.timeIntervalSince(returnAt) * 1000).rounded())) }.joined(separator: "、")) ms 后经过（Copi 没拦下）" } ?? "建不了")")
        try clearLine()

        // 打字时又按了一次 ⌘V：⌘ 一按下打字就停（和按别的键一样），这一次什么都不粘贴，不能成了"打了一半的那段 + 一整段"。
        // t3e 在开头，t3f 在最后；第一段在第二次 ⌘V 之前就打完了的话，两段首尾相接成 t3ftouch
        let doubleLine = "touch \(dir)/t3e; : " + String(repeating: "x", count: 3800) + "; touch \(dir)/t3f"
        let (doubleSource, _, _) = try copyFromTextEdit("src-term-3e.txt", doubleLine)
        openedWindows.append(doubleSource)
        bringToFront(term)
        let doubleBefore = terminalText(term).utf16.count
        try gate(term)
        chord(keyV(), cmd)
        var sawDoubleTyping = false
        for _ in 0..<30 where !sawDoubleTyping {
            sleepMS(50)
            sawDoubleTyping = terminalText(term).utf16.count > doubleBefore + 200
        }
        try gate(term)
        chord(keyV(), cmd)
        // 等打字停下：终端里的文字 1.2 秒不再变长（最多等 15 秒）
        var doubleLast = -1
        var doubleStableSince = Date()
        let doubleDeadline = Date().addingTimeInterval(15)
        while Date() < doubleDeadline {
            sleepMS(200)
            let now = terminalText(term).utf16.count
            if now != doubleLast {
                doubleLast = now
                doubleStableSince = Date()
            } else if Date().timeIntervalSince(doubleStableSince) > 1.2 {
                break
            }
        }
        let doubleTyped = max(0, doubleLast - doubleBefore)
        try enter()
        let (ranFirst, ranLast, joined) = (exists("t3e"), exists("t3f"), exists("t3ftouch"))
        let doubleStatus: String
        let doubleNote: String
        if ranFirst && !ranLast {
            doubleStatus = "PASS"
            doubleNote = "打字停在中间，第二次 ⌘V 没有再粘贴；回车执行的是打出来的前半段"
        } else if joined {
            doubleStatus = "CHECK"
            doubleNote = "第二次 ⌘V 之前整行已经打完了（这一项没测到）"
        } else if ranLast, sawDoubleTyping, doubleTyped > doubleLine.utf16.count + 100 {
            doubleStatus = "FAIL"
            doubleNote = "打字停下之后第二次 ⌘V 又打了一整行：成了半段加一整段"
        } else if ranLast, sawDoubleTyping {
            // 第二次 ⌘V 的 ⌘ 没有让打字停下（或者按下时已经打完、还没收尾），第二次被拒绝：没有混在一起，只是"⌘ 让打字停下"这一半没测到
            doubleStatus = "INFO"
            doubleNote = "第一次打完了整行，第二次 ⌘V 没有再粘贴（打字没有在 ⌘ 按下时停下）"
        } else {
            doubleStatus = "CHECK"
            doubleNote = ranLast ? "只打出了一整行（第二次 ⌘V 可能按得太早，第一次还没开始打字）" : "回车后什么都没执行"
        }
        record("\(T).3e", "\(terminal.1) 里 Copi 打字时又按 ⌘V（/bin/bash 3.2）：打字停下，这一次不粘贴", doubleStatus,
               "\(doubleNote)；看到开始打字=\(sawDoubleTyping)；终端里多出 \(doubleTyped) 个字符（整行 \(doubleLine.utf16.count) 个）；t3e=\(ranFirst) t3f=\(ranLast) t3ftouch=\(joined)")
        try clearLine()

        // 键入不限长度：4100 和 12000 个字符的一行都完整打出来（README："There is no length limit"）
        for (count, marker) in [(4100, "t3c"), (12000, "t3d")] {
            let tail = "; touch \(dir)/\(marker)"
            let text = ": " + String(repeating: "y", count: count - 2 - tail.utf16.count) + tail
            let (lengthSource, _, _) = try copyFromTextEdit("src-term-3-\(count).txt", text)
            openedWindows.append(lengthSource)
            bringToFront(term)
            try gate(term)
            chord(keyV(), cmd)
            // 等打完：终端里的文字 1.2 秒不再变长（最多等 60 秒）
            var last = -1
            var stableSince = Date()
            let deadline = Date().addingTimeInterval(60)
            while Date() < deadline {
                sleepMS(200)
                let now = terminalText(term).utf16.count
                if now != last {
                    last = now
                    stableSince = Date()
                } else if now > 0, Date().timeIntervalSince(stableSince) > 1.2 {
                    break
                }
            }
            try enter()
            let ran = exists(marker)
            record("\(T).3\(count > 5000 ? "d" : "c")", "\(terminal.1) 粘贴一行 \(count) 个字符：完整打出来", ran ? "PASS" : "FAIL",
                   "回车后执行了（标记文件在）=\(ran)；终端里约 \(last) 个字符")
            try clearLine()
        }

        // 退出 bash，回到测试用的 zsh
        try gate(term)
        typeText("exit")
        pressReturn()
        sleepMS(1000)
    }

    // 浏览器里复制的文字粘到终端：第一次只询问，8 秒内再按一次才粘贴
    if NSWorkspace.shared.urlForApplication(withBundleIdentifier: helperBrowser.0) != nil {
        let page = try openPage(helperBrowser, mode: "cmd")
        openedWindows.append(page)
        sleepMS(600)
        if let line = staticTextFrame(page.window, prefix: "touch ") {
            try gate(page)
            tripleClick(center(line))
            try gate(page)
            chord(keyC(), cmd)
            sleepMS(500)
            bringToFront(term)
            try gate(term)
            let secureBefore = IsSecureEventInputEnabled()
            let hudBefore = copiHUDVisible()
            var firstHeld = ""
            chord(keyV(), cmd) {
                firstHeld = heldStateDiag(keyV())
            }
            let firstRecords = inputRecordsDiag()
            // 和真人一样看到提醒再按回车、再按第二次 ⌘V：提醒在 Copi 处理完第一次之后才出现（机器慢时晚一些），
            // 还在处理时按下的回车会让 Copi 放弃这一次
            let firstHUD = waitForCopiHUD(upToMS: 2500)
            sleepMS(max(0, 2500 - (firstHUD?.ms ?? 2500)))
            try enter()
            let afterFirst = exists("t4")
            try gate(term)
            var secondHeld = ""
            chord(keyV(), cmd) {
                secondHeld = heldStateDiag(keyV())
            }
            let secondRecords = inputRecordsDiag()
            sleepMS(2500)
            let secondHUD = copiHUDText()
            try enter()
            let afterSecond = exists("t4")
            // 诊断：第二次没粘贴时再按第三次。这次粘贴了：第二次时 Copi 认的"同一次粘贴"变了（从头等确认）；还是没有：第二次没被当成确认
            var third = ""
            if !afterFirst, !afterSecond {
                try gate(term)
                chord(keyV(), cmd)
                sleepMS(2500)
                let thirdHUD = copiHUDText()
                try enter()
                third = "；（诊断）第三次 ⌘V 后粘贴了=\(exists("t4"))，那时 Copi 的小窗口：\(thirdHUD.map { "「\($0.prefix(80))」" } ?? "没显示")"
            }
            let diagnosis = "；（诊断）按之前 Secure Input=\(secureBefore)\(secureInputHolder())，Copi 的小窗口显示着=\(hudBefore)，第一次 ⌘V 后它\(describeHUD(firstHUD, within: 2500))，第二次后：\(secondHUD.map { "「\($0.prefix(80))」" } ?? "没显示")"
                + "；（诊断）第一次 ⌘V \(firstHeld)，刚按完\(firstRecords)；第二次 ⌘V \(secondHeld)，刚按完\(secondRecords)" + third
            // README：从 macOS 26.4 起 Terminal 粘贴浏览器里复制的内容前会警告，Copi 也就先问；更早的系统没有这道检查，第一次就粘贴
            if ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 26, minorVersion: 4, patchVersion: 0)) {
                record("\(T).4", "浏览器文字 → Terminal：先询问，再按一次才粘贴", !afterFirst && afterSecond ? "PASS" : "FAIL",
                       "第一次 ⌘V 后粘贴了（回车后执行了）=\(afterFirst)；第二次 ⌘V 后粘贴了=\(afterSecond)" + diagnosis)
            } else {
                record("\(T).4", "浏览器文字 → Terminal（macOS 26.4 以下：不询问，第一次就粘贴）", afterFirst ? "PASS" : "FAIL",
                       "第一次 ⌘V 后粘贴了（回车后执行了）=\(afterFirst)")
            }
        } else {
            record("\(T).4", "浏览器文字 → Terminal", "SKIP", "找不到网页上的命令那一行")
        }
    }

    // 拼音：打字时切到 ABC，之后切回（只有打字的终端才有这回事）
    let pinyinIDs = ["com.apple.inputmethod.SCIM.ITABC", "com.apple.inputmethod.SCIM.Shuangpin", "com.apple.inputmethod.TCIM.Pinyin"]
    // GitHub 的虚拟机上没有启用拼音：先启用系统自带的简体拼音（只在 CI 上，不动你自己的 Mac 的输入法设置）
    if onCI, terminal.0 == "com.apple.Terminal" {
        for id in ["com.apple.inputmethod.SCIM", "com.apple.inputmethod.SCIM.ITABC"] {
            enableInputSource(id)
        }
        sleepMS(800)
    }
    if terminal.0 != "com.apple.Terminal" {
        // 不适用
    } else if let pinyin = pinyinIDs.first(where: { selectInputSource($0) }) {
        sleepMS(400)
        let (source, _, _) = try copyFromTextEdit("src-term-py.txt", "touch \(dir)/t5")
        openedWindows.append(source)
        bringToFront(term)
        _ = selectInputSource(pinyin)
        sleepMS(400)
        try gate(term)
        chord(keyV(), cmd)
        sleepMS(3000)
        let restored = currentInputSourceID() == pinyin
        _ = ["com.apple.keylayout.ABC", "com.apple.keylayout.US"].first { selectInputSource($0) }
        sleepMS(300)
        try enter()
        record("\(T).5", "拼音输入法下打字粘贴", exists("t5") && restored ? "PASS" : "FAIL",
               "文字正确打出（回车后执行了）=\(exists("t5"))；之后输入法回到拼音=\(restored)")
    } else {
        record("\(T).5", "拼音输入法下打字粘贴", "SKIP", "没有启用拼音输入法")
    }

    // tmux
    let tmuxPath = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"].first { FileManager.default.isExecutableFile(atPath: $0) }
    if terminal.0 == "com.apple.Terminal", otherWindows > 0 {
        // README：Terminal 里只有当它是 Terminal 唯一的标签页时，Copi 才认得出焦点在 tmux 上；否则按设计拒绝
        record("\(T).6", "\(terminal.1) tmux 粘贴", "N/A", "Terminal 里还开着 \(otherWindows) 个别的窗口：按 README，Copi 只在它是 Terminal 唯一的标签页时才走 tmux，这里按设计拒绝（iTerm2 那一组会测 tmux）")
    } else if let tmuxPath {
        try gate(term)
        typeText("tmux new -s copiselftest")
        pressReturn()
        sleepMS(2500)
        try paste("touch \(dir)/t6", "src-term-tmux.txt")
        let messages = run(tmuxPath, ["show-messages"]).output
        let buffers = run(tmuxPath, ["list-buffers"]).output
        let ranEarly = exists("t6")
        try enter()
        let leaked = messages.contains("/t6") || buffers.contains("/t6")
        record("\(T).6", "tmux 粘贴：消息日志和缓冲区里没有文字", !ranEarly && exists("t6") && !leaked ? "PASS" : "FAIL",
               "按回车前就被执行了=\(ranEarly)；粘贴内容完整=\(exists("t6"))；show-messages 里有文字=\(messages.contains("/t6"))；list-buffers 里有文字=\(buffers.contains("/t6"))")
        _ = run(tmuxPath, ["kill-session", "-t", "copiselftest"])
        sleepMS(800)
    } else {
        record("\(T).6", "tmux", "SKIP", "没有安装 tmux")
    }

    // 收尾：退出测试 shell
    if (try? gate(term)) != nil {
        typeText("exit")
        pressReturn()
    }
}

// 打开 Copi 的菜单栏面板：点之前确认那个位置上确实是 Copi 的图标。返回 Copi 的 pid 和它的 AX 元素
func openCopiMenu() -> (pid: pid_t, app: AXUIElement)? {
    guard let pid = pids("com.gokoding.Copi").first else {
        return nil
    }
    let app = AXUIElementCreateApplication(pid)
    guard let extras = axElement(ax(app, "AXExtrasMenuBar")), let item = axChildren(extras).first, let itemFrame = frame(item) else {
        return nil
    }
    // 面板已经开着：再点一下图标会把它关上
    if copiPanelIsOpen(pid) {
        return (pid, app)
    }
    guard clickCopiStatusItem(pid: pid, itemFrame: itemFrame) else {
        return nil
    }
    for _ in 0..<15 where !copiPanelIsOpen(pid) {
        sleepMS(100)
    }
    sleepMS(400)
    return (pid, app)
}

// Copi 的面板现在在不在屏幕上：问窗口服务器（关上之后它的窗口还留在辅助功能的窗口列表里）。
// 菜单栏图标本身也是 Copi 的窗口，只算比它高的；屏幕下方显示进度、提醒的小窗口（宽 420 点）不算
func copiPanelIsOpen(_ pid: pid_t) -> Bool {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    return list.contains { info in
        guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
              let bounds = info[kCGWindowBounds as String] as? [String: Any], let height = (bounds["Height"] as? NSNumber)?.doubleValue,
              let width = (bounds["Width"] as? NSNumber)?.doubleValue else {
            return false
        }
        return height > 60 && Int(width.rounded()) != 420
    }
}

// 点 Copi 的菜单栏图标：点之前确认那个位置上确实是 Copi 的图标
func clickCopiStatusItem(pid: pid_t, itemFrame: CGRect) -> Bool {
    let point = center(itemFrame)
    var hit: AXUIElement?
    var hitPID: pid_t = 0
    guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit) == .success,
          let hit, AXUIElementGetPid(hit, &hitPID) == .success, hitPID == pid else {
        return false
    }
    click(point)
    return true
}

// 关掉 Copi 的面板：只在焦点确实在 Copi 上时按 Escape（否则 Escape 会落到别的 App 里）
func closeCopiMenu(_ pid: pid_t) {
    guard copiPanelIsOpen(pid) else {
        return
    }
    // 先只给 Copi 发一个 Escape（直接发给它的进程，不会落到别的 App 里）
    for down in [true, false] {
        CGEvent(keyboardEventSource: eventSource, virtualKey: CGKeyCode(kVK_Escape), keyDown: down)?.postToPid(pid)
        sleepMS(30)
    }
    for _ in 0..<10 where copiPanelIsOpen(pid) {
        sleepMS(100)
    }
    if copiPanelIsOpen(pid), let extras = axElement(ax(AXUIElementCreateApplication(pid), "AXExtrasMenuBar")),
       let item = axChildren(extras).first, let itemFrame = frame(item) {
        // 还开着：再点一下图标把它关上
        _ = clickCopiStatusItem(pid: pid, itemFrame: itemFrame)
        for _ in 0..<15 where copiPanelIsOpen(pid) {
            sleepMS(100)
        }
    }
}

// Copi 菜单顶部的状态提示：只认 Copi 自己的几句固定开头，只报出是哪一种（不带后面的内容）
var settingsWarningBeforeTests = false
func copiStatusTexts() -> [String] {
    guard let menu = openCopiMenu() else {
        return ["打不开 Copi 的菜单"]
    }
    let (pid, app) = (menu.pid, menu.app)
    let kinds: [(prefix: String, name: String)] = [
        ("Protection is paused: Copi needs Accessibility", "paused-accessibility"),
        ("Protection is paused: Copi couldn't intercept", "paused-intercept"),
        ("Copi is off:", "off"),
        ("macOS doesn't let Copi read what other apps put", "limited"),
        ("Another program changed Copi's settings:", "settingsChangeWarning"),
    ]
    var found: [String] = []
    _ = findAll(app, maxDepth: 30, limit: 6000) { element in
        if role(element) == kAXStaticTextRole, let text = axString(element, kAXValueAttribute),
           let kind = kinds.first(where: { text.hasPrefix($0.prefix) }), !found.contains(kind.name) {
            found.append(kind.name)
        }
        return false
    }
    closeCopiMenu(pid)
    return found
}

// Copi 菜单里"别的程序改了设置"的 Dismiss：只在警告里列出的全是测试自己造成的改动时才点
func dismissCopiWarning() -> Bool {
    guard let menu = openCopiMenu() else {
        return false
    }
    let (pid, app) = (menu.pid, menu.app)
    defer { closeCopiMenu(pid) }
    let prefix = "Another program changed Copi's settings:"
    guard let warning = findAll(app, maxDepth: 30, limit: 6000, { role($0) == kAXStaticTextRole && (axString($0, kAXValueAttribute) ?? "").hasPrefix(prefix) }).first,
          let text = axString(warning, kAXValueAttribute) else {
        return false
    }
    var rest = String(text.dropFirst(prefix.count)).replacingOccurrences(of: "Check them below and change them back if you didn't do this.", with: "")
    for ours in ["Copi was turned off", "Allow Clipboard Fallback was turned on", "Override ⌘C/⌘V was turned off", "Block Dragging Text was turned off"] {
        rest = rest.replacingOccurrences(of: ours, with: "")
    }
    rest = rest.replacingOccurrences(of: "“TextEdit” was added to Apps Using the Normal Clipboard", with: "")
    guard !rest.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) else {
        return false
    }
    guard let button = findAll(app, maxDepth: 30, limit: 6000, { element in
        role(element) == kAXButtonRole && [axString(element, kAXTitleAttribute), axString(element, kAXDescriptionAttribute)].contains("Dismiss")
    }).first else {
        return false
    }
    let pressed = AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
    sleepMS(500)
    return pressed
}

// CI 的虚拟机上：系统的询问框（UserNotificationCenter 显示的）说了什么、有哪些按钮，按它的取消（"不允许"）关掉。返回一句说明
func dismissSystemDialog(_ dialog: AXUIElement) -> String {
    var texts: [String] = []
    var buttons: [AXUIElement] = []
    var level = [dialog]
    for _ in 0..<6 where !level.isEmpty {
        var next: [AXUIElement] = []
        for element in level {
            if role(element) == kAXStaticTextRole, let value = axString(element, kAXValueAttribute), !value.isEmpty {
                texts.append(value)
            } else if role(element) == kAXButtonRole {
                buttons.append(element)
            }
            next.append(contentsOf: axChildren(element))
        }
        level = next
    }
    let titles = buttons.map { axString($0, kAXTitleAttribute) ?? "?" }
    let refusals: Set<String> = ["Don't Allow", "Don’t Allow", "Deny", "Cancel", "Not Now", "不允许", "拒绝", "取消", "以后"]
    let cancel = axElement(ax(dialog, kAXCancelButtonAttribute))
        ?? buttons.first { refusals.contains(axString($0, kAXTitleAttribute) ?? "") }
        ?? (buttons.count == 1 ? buttons.first : nil)
    var pressed = "没有可按的按钮"
    if let cancel {
        // 按之前读标题：按下去询问框就关了，按钮跟着没了，之后读不到
        let title = axString(cancel, kAXTitleAttribute) ?? "?"
        pressed = AXUIElementPerformAction(cancel, kAXPressAction as CFString) == .success ? "按了「\(title)」" : "按「\(title)」没成功"
    }
    return "「\(texts.joined(separator: " ").prefix(160))」按钮：\(titles.joined(separator: "、"))，\(pressed)"
}

// iTerm2 的界面读不到终端里的文字：用标记文件验证。粘贴 touch 命令 → 等一会儿文件不该出现（没被执行）→ 按回车 → 文件出现（内容完整）
func itermTests(_ openedWindows: inout [TestWindow]) throws {
    let iterm = ("com.googlecode.iterm2", "iTerm")
    guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: iterm.0) != nil else {
        record("I", "iTerm2", "SKIP", "没有安装")
        return
    }
    // 不打开 .command 脚本（iTerm2 会先弹对话框问要不要运行）：把 iTerm2 切到前台，⌘N 新开一个窗口，在里面切到测试用的 zsh。
    // CI 上 iTerm2 每次都是刚装的，第一次打开要好一阵：最多等 15 秒
    _ = run("/usr/bin/open", ["-a", iterm.1])
    var itermPIDs: [pid_t] = []
    // CI 上刚装的 iTerm2 第一次打开时，系统会先弹一个询问框（UserNotificationCenter 显示的）挡在前面：记下它说了什么，
    // 按"不允许"/取消关掉它（只在 CI 的虚拟机上），接着等 iTerm2 到前台
    var dismissed: [String] = []
    for _ in 0..<60 {
        sleepMS(250)
        itermPIDs = pids(iterm.0)
        if let focused = focusedApp(), itermPIDs.contains(focused.pid) {
            break
        }
        if onCI, dismissed.count < 3, let focused = focusedApp(), focused.bundleID == "com.apple.UserNotificationCenter",
           let dialog = windows(focused.pid).first(where: { axString($0, kAXSubroleAttribute) == "AXSystemDialog" }) {
            dismissed.append(dismissSystemDialog(dialog))
            sleepMS(500)
        }
    }
    if !dismissed.isEmpty {
        record("I.0", "CI：iTerm2 第一次打开时系统弹出的询问框（按不允许关掉）", "INFO", dismissed.joined(separator: " / "))
    }
    // CI 上看不出原因时，记下前台程序和窗口（标题、子角色）、iTerm2 自己的窗口：是系统的询问、iTerm2 的欢迎窗口还是别的挡住了
    func blocking() -> String {
        guard onCI else {
            return ""
        }
        func describe(_ list: [AXUIElement]) -> String {
            list.isEmpty ? "没有" : list.prefix(5).map { "「\(axString($0, kAXTitleAttribute) ?? "")」\(axString($0, kAXSubroleAttribute) ?? "?")" }.joined(separator: "、")
        }
        let front = focusedApp()
        return "；前台程序 \(front?.bundleID ?? "读不到")，它的窗口：\(front.map { describe(windows($0.pid)) } ?? "读不到")；iTerm2 的窗口：\(describe(pids(iterm.0).flatMap { windows($0) }))"
    }
    guard let focused = focusedApp(), itermPIDs.contains(focused.pid) else {
        record("I", "iTerm2", "SKIP", "iTerm2 没有到前台（等了 15 秒）" + blocking())
        return
    }
    let existing = itermPIDs.flatMap { windows($0) }
    let ttysBefore = Set(ttyProcesses().map(\.tty))
    chord(CGKeyCode(kVK_ANSI_N), cmd)
    var found: TestWindow?
    let deadline = Date().addingTimeInterval(10)
    while found == nil, Date() < deadline {
        for pid in pids(iterm.0) {
            if let window = windows(pid).first(where: { candidate in
                !existing.contains { CFEqual($0, candidate) } && axString(candidate, kAXSubroleAttribute) == kAXStandardWindowSubrole
            }) {
                found = TestWindow(bundleID: iterm.0, appName: iterm.1, pid: pid, window: window)
            }
        }
        sleepMS(200)
    }
    guard let term = found else {
        record("I", "iTerm2", "SKIP", "⌘N 之后没有出现新的 iTerm2 窗口" + blocking())
        return
    }
    bringToFront(term)
    sleepMS(1500)
    // 新窗口用的是你的默认 profile：它新开的终端设备上，前台程序必须只有 shell（不是 tmux、ssh、vim 之类），否则什么都不打
    let shells: Set<String> = ["zsh", "bash", "fish", "sh", "login"]
    var newTTYs: Set<String> = []
    var foreground: [String] = []
    for _ in 0..<24 {
        let now = ttyProcesses()
        newTTYs = Set(now.map(\.tty)).subtracting(ttysBefore)
        foreground = now.filter { newTTYs.contains($0.tty) && $0.stat.contains("+") }.map { $0.name.trimmingCharacters(in: CharacterSet(charactersIn: "-")) }
        if newTTYs.count == 1, !foreground.isEmpty, foreground.allSatisfy({ shells.contains($0) }) {
            break
        }
        sleepMS(250)
    }
    guard newTTYs.count == 1, !foreground.isEmpty, foreground.allSatisfy({ shells.contains($0) }) else {
        record("I", "iTerm2", "SKIP", "新窗口里前台不只是 shell（新终端设备 \(newTTYs.count) 个，前台程序 \(foreground.count) 个），什么都没有输入；新窗口留给你自己关")
        return
    }
    try gate(term)
    typeText("cd '\(fixtures.path)' && ZDOTDIR='\(fixtures.appendingPathComponent("zdot").path)' exec /bin/zsh -i")
    pressReturn()
    sleepMS(1500)
    bringToFront(term)
    sleepMS(1500)
    let markers = fixtures.appendingPathComponent("markers")
    try? FileManager.default.createDirectory(at: markers, withIntermediateDirectories: true)
    func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: markers.appendingPathComponent(name).path)
    }
    func paste(_ text: String, _ sourceName: String) throws {
        let (source, _, _) = try copyFromTextEdit(sourceName, text)
        openedWindows.append(source)
        bringToFront(term)
        try gate(term)
        chord(keyV(), cmd)
        // 没有允许 Copi 控制 iTerm2 时，Copi 一个个字打：等它打完
        sleepMS(min(12000, 2500 + 80 * text.utf16.count))
    }
    func check(_ id: String, _ name: String, files: [String]) throws {
        let ranEarly = files.contains(where: exists)
        // GitHub 的虚拟机上：别的终端设备上的前台程序（Copi 看不出焦点在 iTerm2 的哪个会话，要靠窗口标题挑出这一个）
        let context = onCI
            ? "；窗口标题=\(axString(term.window, kAXTitleAttribute) ?? "nil")；别的终端设备上的前台程序="
              + ttyProcesses().filter { !newTTYs.contains($0.tty) && $0.stat.contains("+") }.map(\.name).sorted().joined(separator: ",")
            : ""
        try gate(term)
        pressReturn()
        sleepMS(1500)
        let allThere = files.allSatisfy(exists)
        record(id, name, !ranEarly && allThere ? "PASS" : "FAIL",
               "按回车前就被执行了=\(ranEarly)；按回车后命令完整执行（标记文件都在）=\(allThere)" + context)
    }
    // 测试 shell 的当前目录就是 fixtures：用相对路径
    let dir = "markers"
    try paste("touch '\(dir)/i1'", "src-iterm-1.txt")
    try check("I.1", "iTerm2 单行粘贴：插入不执行、内容完整", files: ["i1"])
    // 没有允许 Copi 控制 iTerm2 时（GitHub 的虚拟机上就是这样），多行文字逐键打成 bracketed paste（ZeroExposure.swift 的
    // keystrokeBracketedPasteTerminalBundleIDs 里有 iTerm2）
    try paste("touch '\(dir)/i2a'\ntouch '\(dir)/i2b'", "src-iterm-2.txt")
    try check("I.2", "iTerm2 多行粘贴：插入不执行、内容完整" + (onCI ? "（没有允许 Copi 控制 iTerm2：逐键键入）" : ""), files: ["i2a", "i2b"])
    // tmux（Copi 要经 iTerm2 自己的接口认出是哪个标签页：GitHub 的虚拟机上没法允许 Copi 控制 iTerm2，不测）
    if onCI {
        record("I.3", "iTerm2 + tmux", "N/A", "GitHub 的虚拟机上没有允许 Copi 控制 iTerm2（Copi 菜单里的 Terminal Access），这一项只在本机测")
    } else if let tmuxPath = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
        _ = run(tmuxPath, ["kill-session", "-t", "copiselftest"])
        try gate(term)
        typeText("tmux new -s copiselftest")
        pressReturn()
        sleepMS(2500)
        try paste("touch '\(dir)/i3'", "src-iterm-3.txt")
        let messages = run(tmuxPath, ["show-messages"]).output
        let buffers = run(tmuxPath, ["list-buffers"]).output
        let ranEarly = exists("i3")
        try gate(term)
        pressReturn()
        sleepMS(1500)
        let leaked = messages.contains("/i3") || buffers.contains("/i3")
        record("I.3", "iTerm2 + tmux 粘贴：日志和缓冲区里没有文字", !ranEarly && exists("i3") && !leaked ? "PASS" : "FAIL",
               "按回车前就被执行了=\(ranEarly)；粘贴内容完整=\(exists("i3"))；show-messages 里有文字=\(messages.contains("/i3"))；list-buffers 里有文字=\(buffers.contains("/i3"))；剩下的 copi 缓冲区 \(buffers.components(separatedBy: "copi-").count - 1) 个")
        _ = run(tmuxPath, ["kill-session", "-t", "copiselftest"])
        sleepMS(800)
    } else {
        record("I.3", "iTerm2 + tmux", "SKIP", "没有安装 tmux")
    }
    if (try? gate(term)) != nil {
        typeText("exit")
        pressReturn()
    }
}

func copiStatusDescription() -> String {
    guard let pid = pids("com.gokoding.Copi").first else {
        return "Copi 不在运行"
    }
    let app = AXUIElementCreateApplication(pid)
    guard let extras = axElement(ax(app, "AXExtrasMenuBar")) else {
        return "读不到菜单栏图标"
    }
    let items = axChildren(extras)
    return items.map { item in
        [axString(item, kAXDescriptionAttribute), axString(item, kAXTitleAttribute), axString(item, kAXHelpAttribute)]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "/")
    }.joined(separator: ";")
}

func copiProcesses() -> (main: [pid_t], watchdog: [pid_t]) {
    let output = run("/usr/bin/pgrep", ["-lf", "Copi.app/Contents/MacOS/Copi"]).output
    var main: [pid_t] = []
    var watchdog: [pid_t] = []
    for line in output.split(separator: "\n") {
        let parts = line.split(separator: " ", maxSplits: 1)
        guard let pid = parts.first.flatMap({ pid_t($0) }) else {
            continue
        }
        if line.contains("--copi-watchdog") {
            watchdog.append(pid)
        } else {
            main.append(pid)
        }
    }
    return (main, watchdog)
}

func watchdogTests() {
    let before = copiProcesses()
    guard let mainPID = before.main.first else {
        record("10", "watchdog", "SKIP", "找不到 Copi 主进程")
        return
    }
    guard !before.watchdog.isEmpty else {
        record("10.1", "watchdog 进程存在", "FAIL", "只有主进程、没有 --copi-watchdog 进程（Debug build 不启动 watchdog；需要 Release build，并且「Restart Copi If It Stops Unexpectedly」开着）")
        return
    }
    kill(mainPID, SIGTERM)
    var restarted: pid_t?
    for _ in 0..<40 {
        sleepMS(250)
        if let pid = copiProcesses().main.first(where: { $0 != mainPID }) {
            restarted = pid
            break
        }
    }
    record("10.1", "只结束主进程：Copi 自动重新打开", restarted != nil ? "PASS" : "FAIL",
           restarted.map { "主进程 \(mainPID) 被结束后重新打开为 \($0)（「谁让它退出」的通知需要人看）" } ?? "10 秒内没有重新打开")
    guard let paused = restarted else {
        return
    }
    sleepMS(4000)
    kill(paused, SIGSTOP)
    var replaced: pid_t?
    for _ in 0..<70 {
        sleepMS(500)
        if let pid = copiProcesses().main.first(where: { $0 != paused }) {
            replaced = pid
            break
        }
    }
    if replaced == nil {
        kill(paused, SIGCONT)
    }
    record("10.2", "暂停主进程（SIGSTOP）：约 20 秒内被重启", replaced != nil ? "PASS" : "FAIL",
           replaced.map { "被暂停的 \(paused) 换成了 \($0)" } ?? "35 秒内没有被换掉（已发送 SIGCONT 恢复）")
}

// MARK: - 测完收拾

// 测试开始前这些 App 在不在运行、各开着哪些窗口；测完：测试启动的 App 整个退出（访达除外），原本就开着的只关测试期间新开的窗口，
// 浏览器里关掉测试页的标签页。你原来的窗口不碰（窗口标题不记、不写进报告）
final class WindowSnapshot {
    private let appIDs = [textEdit.0, "com.apple.Safari", brave.0, "com.google.Chrome", "com.apple.Terminal", "com.googlecode.iterm2",
                          "com.microsoft.VSCode", "com.apple.Preview", "com.apple.finder", "com.apple.ScreenSharing"]
    private var running: Set<String> = []
    private var windowsAtStart: [String: [AXUIElement]] = [:]

    init() {
        for id in appIDs {
            let found = pids(id)
            if !found.isEmpty {
                running.insert(id)
                windowsAtStart[id] = found.flatMap { windows($0) }
            }
        }
    }

    func restore() {
        for id in appIDs {
            let found = pids(id)
            guard !found.isEmpty else {
                continue
            }
            if !running.contains(id), id != "com.apple.finder" {
                for pid in found {
                    // TextEdit、预览里只有测试文档：直接结束（正常退出会弹"要不要保存"、卡在那里）。别的 App 正常退出
                    if [textEdit.0, "com.apple.Preview"].contains(id) {
                        NSRunningApplication(processIdentifier: pid)?.forceTerminate()
                    } else {
                        NSRunningApplication(processIdentifier: pid)?.terminate()
                    }
                }
                continue
            }
            let before = windowsAtStart[id] ?? []
            for pid in found {
                for window in windows(pid) {
                    let isNew = !before.contains { CFEqual($0, window) }
                    let isTestPage = (axString(window, kAXTitleAttribute) ?? "").contains("COPI|")
                    guard isNew || isTestPage else {
                        continue
                    }
                    let target = TestWindow(bundleID: id, appName: "", pid: pid, window: window)
                    if isTestPage, !isNew {
                        // 你原来的浏览器窗口里测试开的标签页：只关这个标签页
                        bringToFront(target)
                        closeTab(target)
                    } else if let close = axElement(ax(window, kAXCloseButtonAttribute)) {
                        AXUIElementPerformAction(close, kAXPressAction as CFString)
                        sleepMS(500)
                        // 测试开的文档窗口问要不要保存：不保存（只在这个窗口自己的对话框里点）
                        dismissSaveSheet(window)
                    }
                }
            }
        }
    }
}

// 窗口上"要不要保存"的对话框：点"不存储"（或"删除""还原更改"）。只看这个窗口自己的对话框
func dismissSaveSheet(_ window: AXUIElement) {
    let titles = ["Don't Save", "Delete", "Revert Changes", "不存储", "删除", "还原更改", "不儲存", "刪除"]
    for child in axChildren(window) where axString(child, kAXRoleAttribute) == "AXSheet" {
        if let button = findDescendant(child, maxDepth: 6, { axString($0, kAXRoleAttribute) == kAXButtonRole && titles.contains(axString($0, kAXTitleAttribute) ?? "") }) {
            AXUIElementPerformAction(button, kAXPressAction as CFString)
            sleepMS(300)
        }
    }
}

// MARK: - 入口

// 测试期间一直留着（见 applicationDidFinishLaunching）
var selfTestActivity: NSObjectProtocol?

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            record("0", "前置检查", "FAIL", "测试程序还没有辅助功能权限：系统设置 › 隐私与安全性 › 辅助功能 里打开 CopiSelfTest，然后再运行一次")
            writeReport(final: true, aborted: "缺少辅助功能权限")
            NSApp.terminate(nil)
            return
        }
        // 测试程序没有窗口，会被 App Nap 拉长计时器、降低优先级：每毫秒一次的取样、Copi 来要按需提供的数据时都要及时
        selfTestActivity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Copi self-test")
        Thread {
            var aborted: String?
            let leftAsFound = WindowSnapshot()
            defer { leftAsFound.restore() }
            do {
                try runTests()
            } catch let error as Abort {
                aborted = error.reason
                log("ABORT \(error.reason)")
            } catch {
                aborted = "\(error)"
            }
            writeReport(final: true, aborted: aborted)
            // Copi 的临时诊断日志（只有分支、错误码、长度）
            // 只要测试开始之后的
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            formatter.timeZone = .current
            // 只在 GitHub 的虚拟机上收集：你的电脑上的系统日志不读
            if onCI {
                let copiLog = run("/usr/bin/log", ["show", "--start", formatter.string(from: startTime), "--style", "compact",
                                                   "--predicate", "subsystem == \"com.gokoding.Copi\""], timeout: 60).output
                try? copiLog.write(to: baseDir.appendingPathComponent("copi.log"), atomically: true, encoding: .utf8)
            }
            log("DONE")
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }.start()
    }
}

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.setActivationPolicy(.prohibited)
NSApplication.shared.run()
