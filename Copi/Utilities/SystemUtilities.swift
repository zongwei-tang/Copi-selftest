//
//  SystemUtilities.swift
//  SecureYourClipboard
//
//  Created by lixindong on 2024/4/2.
//

import Foundation
import AppKit
import Carbon
import ApplicationServices
import Defaults
import UserNotifications

func requestNotificationAuthorization() {
    CopiNotificationAction.register()
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
}

private let notificationLock = NSLock()
private var lastNotificationDates: [String: Date] = [:]

// 每次 Copi 真正保护了一次复制/粘贴（不管走的是纯 Accessibility 还是瞬时剪贴板回退）
// 就提醒一下，纯粹作为"确实生效了"的感知反馈；不包含任何剪贴板实际内容。
// 同一句话 2 秒内只发一次，并且新通知替换旧的（长按 ⌘V 时不会刷出一屏通知）。
func notifyProtected(_ body: String) {
    guard Defaults[.notifyOnProtect] else { return }
    let now = Date()
    notificationLock.lock()
    if let last = lastNotificationDates[body], now.timeIntervalSince(last) < 2 {
        notificationLock.unlock()
        return
    }
    lastNotificationDates[body] = now
    notificationLock.unlock()
    let content = UNMutableNotificationContent()
    content.title = "Copi"
    content.body = body
    let request = UNNotificationRequest(identifier: "copi.\(body)", content: content, trigger: nil)
    UNUserNotificationCenter.current().add(request)
}

// MARK: - 合成按键

// Copi 自己合成、会经过 ⌘C/⌘V 拦截器的事件打上这个标记（eventSourceUserData），拦截器看到就直接放行。
// 每次启动随机生成，别的程序没法照抄一个已知的值让拦截器放行它合成的 ⌘C/⌘V。模拟键入的文字事件发在拦截器之后的层级，不需要它。
// 注意：合成的按键本来就能凭来源进程（系统给每个合成事件记下发送者的 pid）认出来，带不带标记都一样
let copiSyntheticEventMarker: Int64 = Int64.random(in: 0x1_0000...Int64.max)

// 左 ⌘ 的设备位（NX_DEVICELCMDKEYMASK）：部分 App（Java/JetBrains、虚拟机、远程桌面客户端）按设备位识别修饰键
private let deviceLeftCommandFlag = CGEventFlags(rawValue: 0x8)

func postKeystroke(keyCode: CGKeyCode, flags: CGEventFlags = .maskCommand, tap: CGEventTapLocation = .cgAnnotatedSessionEventTap) {
    let source = CGEventSource(stateID: .privateState)
    var eventFlags = flags
    if flags.contains(.maskCommand) {
        eventFlags.insert(deviceLeftCommandFlag)
    }
    for keyDown in [true, false] {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown) else {
            continue
        }
        event.flags = eventFlags
        event.setIntegerValueField(.eventSourceUserData, value: copiSyntheticEventMarker)
        event.post(tap: tap)
    }
    InputActivity.noteInput()
}

// 直接发给某个进程的按键（不经过别的 App，也不会被 Copi 的拦截器处理）
func postKeystroke(keyCode: CGKeyCode, flags: CGEventFlags, to pid: pid_t) {
    let source = CGEventSource(stateID: .privateState)
    var eventFlags = flags
    if flags.contains(.maskCommand) {
        eventFlags.insert(deviceLeftCommandFlag)
    }
    for keyDown in [true, false] {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown) else {
            continue
        }
        event.flags = eventFlags
        event.setIntegerValueField(.eventSourceUserData, value: copiSyntheticEventMarker)
        event.postToPid(pid)
    }
    InputActivity.noteInput()
}

// 原样补发一次之前被吞掉的按键（保留原来的键码、修饰键，键盘布局也就对得上），再补一个松开
func repostKeystroke(_ keyDown: CGEvent) {
    keyDown.setIntegerValueField(.eventSourceUserData, value: copiSyntheticEventMarker)
    keyDown.post(tap: .cgAnnotatedSessionEventTap)
    if let keyUp = keyDown.copy() {
        keyUp.type = .keyUp
        keyUp.post(tap: .cgAnnotatedSessionEventTap)
    }
    InputActivity.noteInput()
}

// 模拟 ⌘V / ⌘C（按当前键盘布局找到对应的键，只能在主线程调用）
func postPasteKeystroke() {
    postKeystroke(keyCode: KeyboardLayout.commandKeyCode(for: "v") ?? CGKeyCode(kVK_ANSI_V))
}

func postCopyKeystroke() {
    postKeystroke(keyCode: KeyboardLayout.commandKeyCode(for: "c") ?? CGKeyCode(kVK_ANSI_C))
}

// 切换输入法/键盘布局的系统通知。必须要求立即送达：默认的送达方式会在 App 不处于激活状态时把通知挂起，
// 而 Copi 作为菜单栏 App 几乎从不激活
private final class KeyboardLayoutObserver: NSObject {
    @objc func inputSourceDidChange(_ notification: Notification) {
        DispatchQueue.main.async {
            InputSourceState.noteChange()
            KeyboardLayout.refreshCache()
            NotificationCenter.default.post(name: KeyboardLayout.didChangeNotification, object: nil)
        }
    }
}

enum KeyboardLayout {
    private static let cacheLock = NSLock()
    private static var cachedKeyCodes: [Character: CGKeyCode] = [:]
    private static var observer: KeyboardLayoutObserver?

    // 在主线程算好 V、C 的键码给 event tap 线程用（TIS 接口只能在主线程调用），切换输入法/键盘布局时刷新
    static func startCaching() {
        dispatchPrecondition(condition: .onQueue(.main))
        refreshCache()
        guard observer == nil else {
            return
        }
        let observer = KeyboardLayoutObserver()
        DistributedNotificationCenter.default().addObserver(observer,
                                                            selector: #selector(KeyboardLayoutObserver.inputSourceDidChange(_:)),
                                                            name: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
                                                            object: nil,
                                                            suspensionBehavior: .deliverImmediately)
        self.observer = observer
    }

    static let didChangeNotification = Notification.Name("CopiKeyboardLayoutDidChange")

    // 只能在主线程调用
    static func refreshCache() {
        var keyCodes: [Character: CGKeyCode] = [:]
        for character: Character in ["v", "c", "x"] {
            if let keyCode = commandKeyCode(for: character) {
                keyCodes[character] = keyCode
            }
        }
        cacheLock.lock()
        cachedKeyCodes = keyCodes
        cacheLock.unlock()
    }

    // 任意线程可用；没有缓存（还没算过，或者当前布局里找不到）时返回 nil
    static func cachedCommandKeyCode(for character: Character) -> CGKeyCode? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cachedKeyCodes[character]
    }

    // 当前键盘布局下按住 ⌘ 时能打出 character 的虚拟键码。Dvorak 等布局的 V/C 不在 ANSI 键位上，
    // 写死 kVK_ANSI_V 合成出来的其实是 ⌘K 之类。找不到时（俄文等非拉丁布局）返回 nil，
    // 由调用方回退到 ANSI 键位——macOS 在这类布局下解析 ⌘ 快捷键也是这么做的。
    // TIS 接口只能在主线程调用。
    static func commandKeyCode(for character: Character) -> CGKeyCode? {
        if let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
           let keyCode = keyCode(producing: character, in: source) {
            return keyCode
        }
        if let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
           let keyCode = keyCode(producing: character, in: source) {
            return keyCode
        }
        return nil
    }

    private static func keyCode(producing character: Character, in source: TISInputSource) -> CGKeyCode? {
        guard let rawLayoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let layoutData = Unmanaged<CFData>.fromOpaque(rawLayoutData).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(layoutData) else {
            return nil
        }
        let target = String(character).lowercased()
        let commandModifierState = UInt32((cmdKey >> 8) & 0xFF)
        return bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout -> CGKeyCode? in
            for keyCode in 0..<128 {
                var deadKeyState: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(layout,
                                            UInt16(keyCode),
                                            UInt16(kUCKeyActionDown),
                                            commandModifierState,
                                            UInt32(LMGetKbdType()),
                                            OptionBits(kUCKeyTranslateNoDeadKeysMask),
                                            &deadKeyState,
                                            4,
                                            &length,
                                            &chars)
                if status == noErr, length > 0, String(utf16CodeUnits: chars, count: length).lowercased() == target {
                    return CGKeyCode(keyCode)
                }
            }
            return nil
        }
    }
}

extension CGEvent {
    // 这个按键是不是字母 letter（修饰键由调用方判断）。Dvorak 等布局的 V/C 不在 ANSI 键位上：
    // 不带 ⌥ 时优先看事件携带的字符；带 ⌥ 时字符已经变了样（例如 ⌥⇧V 是 ◊），或者字符不是 ASCII 字母
    // （俄文等非拉丁布局）、取不到时，改用当前布局下这个字母的键码，最后才按 macOS 的惯例回退到 ANSI 键位。
    func isLetter(_ letter: Character, ansiKeyCode: Int) -> Bool {
        if !flags.contains(.maskAlternate) {
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &chars)
            if length == 1, let scalar = Unicode.Scalar(chars[0]), scalar.isASCII, scalar.properties.isAlphabetic {
                return String(Character(scalar)).lowercased() == String(letter)
            }
        }
        let keyCode = KeyboardLayout.cachedCommandKeyCode(for: letter).map { Int64($0) } ?? Int64(ansiKeyCode)
        return getIntegerValueField(.keyboardEventKeycode) == keyCode
    }
}

extension CGEventFlags {
    private var modifiers: CGEventFlags {
        self.intersection([.maskCommand, .maskShift, .maskControl, .maskAlternate])
    }

    // 按下的修饰键恰好是 flag（不多不少）
    func check(is flag: CGEventFlags) -> Bool {
        modifiers.symmetricDifference(flag).isEmpty
    }
}

// MARK: - Accessibility 文本读写

// 直接通过 Accessibility 读写"当前聚焦控件的选中文字"，完全不经过 Services 菜单或系统剪贴板。

// 主线程上一次 ⌘C/⌘V 处理的 Accessibility 总耗时预算（见 withAXBudget）
private var mainThreadAXDeadline: DispatchTime?

// 在时间预算内执行 body：预算用完后所有 Accessibility 查询立即判为失败，调用方随之改走 ⌘C/⌘V 回退。
// 单次查询有 0.2 秒的超时，但一次处理要查十几次，目标 App 只是慢（而不是完全卡死）时累计起来会超过
// event tap 线程愿意等待的时间。
func withAXBudget<T>(_ seconds: TimeInterval, _ body: () -> T) -> T {
    dispatchPrecondition(condition: .onQueue(.main))
    mainThreadAXDeadline = .now() + seconds
    defer { mainThreadAXDeadline = nil }
    return body()
}

// 剩余预算（秒）；没有设置预算时为 nil
var axBudgetRemaining: TimeInterval? {
    guard Thread.isMainThread, let deadline = mainThreadAXDeadline else {
        return nil
    }
    let now = DispatchTime.now()
    guard now < deadline else {
        return 0
    }
    return TimeInterval(deadline.uptimeNanoseconds - now.uptimeNanoseconds) / 1_000_000_000
}

var axBudgetExhausted: Bool {
    axBudgetRemaining == 0
}

func copyAXAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    guard !axBudgetExhausted else {
        return nil
    }
    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
    // 主线程上一连串的查询可能要好一阵：间隙里照顾一下系统剪贴板
    PasteboardQuarantine.shared.checkpoint()
    guard result == .success else {
        return nil
    }
    return value
}

// 同上，读不到时说清是"没有这一项"还是"出错了（App 没响应、时间用完）"
enum AXAttributeRead {
    case value(CFTypeRef)
    // 这个元素没有这一项（或者是空的）
    case none
    // 出错、超时、预算用完：不知道
    case failed
}

func readAXAttribute(_ element: AXUIElement, _ attribute: String) -> AXAttributeRead {
    guard !axBudgetExhausted else {
        return .failed
    }
    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
    PasteboardQuarantine.shared.checkpoint()
    switch result {
    case .success:
        return value.map { .value($0) } ?? .none
    case .noValue, .attributeUnsupported:
        return .none
    default:
        return .failed
    }
}

// 主线程上的等待：切成几毫秒一段，间隙里照顾一下系统剪贴板（见 PasteboardQuarantine）。别的线程照常等
func waitAttentively(_ semaphore: DispatchSemaphore, timeout: TimeInterval) -> DispatchTimeoutResult {
    guard Thread.isMainThread else {
        return semaphore.wait(timeout: .now() + timeout)
    }
    let deadline = DispatchTime.now() + timeout
    while true {
        PasteboardQuarantine.shared.checkpoint()
        let now = DispatchTime.now()
        guard now < deadline else {
            return semaphore.wait(timeout: .now())
        }
        if semaphore.wait(timeout: min(deadline, now + .milliseconds(3))) == .success {
            return .success
        }
    }
}

func sleepAttentively(_ seconds: TimeInterval) {
    guard Thread.isMainThread else {
        Thread.sleep(forTimeInterval: seconds)
        return
    }
    let deadline = Date().addingTimeInterval(seconds)
    while true {
        PasteboardQuarantine.shared.checkpoint()
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else {
            return
        }
        Thread.sleep(forTimeInterval: min(remaining, 0.003))
    }
}

func asAXElement(_ value: CFTypeRef?) -> AXUIElement? {
    guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
        return nil
    }
    return (value as! AXUIElement)
}

func pid(of element: AXUIElement) -> pid_t? {
    var pid: pid_t = 0
    guard AXUIElementGetPid(element, &pid) == .success else {
        return nil
    }
    return pid
}

struct FocusedTarget {
    let element: AXUIElement
    let pid: pid_t

    var bundleIdentifier: String? {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }

    var role: String? {
        copyAXAttribute(element, kAXRoleAttribute) as? String
    }

    var isSecureTextField: Bool {
        (copyAXAttribute(element, kAXSubroleAttribute) as? String) == kAXSecureTextFieldSubrole
    }

    var selectedText: String? {
        guard let text = copyAXAttribute(element, kAXSelectedTextAttribute) as? String, !text.isEmpty else {
            return nil
        }
        return text
    }

    var numberOfCharacters: Int? {
        (copyAXAttribute(element, kAXNumberOfCharactersAttribute) as? NSNumber)?.intValue
    }

    var selectedRange: CFRange? {
        guard let value = copyAXAttribute(element, kAXSelectedTextRangeAttribute),
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else {
            return nil
        }
        return range
    }

    // 网页内容：Safari/WKWebView、Chrome 系浏览器、Electron App 里的输入框和正文。
    //  - 写 kAXSelectedText：WebKit 里是个空实现，Chromium 会直接丢弃，但两者都照样返回 success——
    //    之前在网页里按 ⌘V 什么都没贴上却报"成功"，也不会走回退；
    //  - 读 kAXSelectedText：拿到的是无障碍树里的文字，虚拟滚动的编辑器会截断、密码框是圆点，还绕过了网站自己的复制处理。
    // 所以网页内容一律走真正的 ⌘C / ⌘V。
    var isWebContent: Bool {
        hasWebOnlyAttributes || hasWebAreaAncestor
    }

    // 不重复查询属性名时用（调用方已经确认过 hasWebOnlyAttributes 为 false）

    // WebKit 和 Chromium 给每个网页元素都加了这些属性（一次查询就能认出来）
    var hasWebOnlyAttributes: Bool {
        guard !axBudgetExhausted else {
            return true
        }
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(element, &names) == .success, let names = names as? [String] else {
            return false
        }
        return names.contains { $0 == "AXDOMIdentifier" || $0 == "AXDOMClassList" || $0 == "ChromeAXNodeId" }
    }

    // 兜底：往上找有没有网页根节点。预算用完时按"是网页"处理，调用方会走更保守的 ⌘C/⌘V 回退。
    var hasWebAreaAncestor: Bool {
        var node: AXUIElement? = element
        for _ in 0..<10 {
            guard let current = node else {
                return false
            }
            if axBudgetExhausted {
                return true
            }
            if (copyAXAttribute(current, kAXRoleAttribute) as? String) == "AXWebArea" {
                return true
            }
            node = asAXElement(copyAXAttribute(current, kAXParentAttribute))
        }
        return false
    }
}

// 当前真正拿着键盘焦点的控件。以系统报告的"焦点所在 App"为准：Spotlight、Alfred、Raycast、1Password
// 快速访问这类不激活自身的浮动面板拿到键盘焦点时，frontmostApplication 仍然是下面那个 App，按它去找
// 焦点控件会把粘贴写进被挡住的 App。只有系统查不到焦点 App 时才退回 frontmostApplication。
// 找不到时返回 nil，调用方会改走真正的 ⌘C/⌘V，按键自然会送到真正拿着焦点的地方。
func focusedTarget() -> FocusedTarget? {
    guard AXIsProcessTrusted() else {
        return nil
    }
    let application: AXUIElement
    if let focusedApplication = asAXElement(copyAXAttribute(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute)) {
        application = focusedApplication
    } else if let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier {
        application = AXUIElementCreateApplication(frontmost)
    } else {
        return nil
    }
    // 焦点在 Copi 自己身上（菜单栏面板开着）时不要查询：自己的 Accessibility 请求要靠自己的主线程来回答，
    // 而调用方往往就在主线程上等着
    guard let applicationPID = pid(of: application), applicationPID != getpid(),
          let element = asAXElement(copyAXAttribute(application, kAXFocusedUIElementAttribute)) else {
        return nil
    }
    return FocusedTarget(element: element, pid: applicationPID)
}

// 真正拿着键盘焦点的 App（Spotlight、Alfred、Raycast、1Password 快速访问这类浮动面板拿着焦点时，前台 App 是下面那个）。
// 系统查不到时退回前台 App。只问系统，不问目标 App 本身
func focusedApplication() -> NSRunningApplication? {
    if AXIsProcessTrusted(),
       let application = asAXElement(copyAXAttribute(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute)),
       let applicationPID = pid(of: application),
       let running = NSRunningApplication(processIdentifier: applicationPID) {
        return running
    }
    return NSWorkspace.shared.frontmostApplication
}

// Action Bar 用来判断要不要显示"复制"按钮：只要有选中文字就算（包括网页内容，复制时会改走 ⌘C）
func hasSelectedTextViaAX() -> Bool {
    guard let target = focusedTarget(), !target.isSecureTextField else {
        return false
    }
    if target.selectedText != nil {
        return true
    }
    // Safari 网页正文里的选区只能通过 text marker 读到
    guard let markerRange = copyAXAttribute(target.element, "AXSelectedTextMarkerRange"),
          let text = copyAXParameterizedAttribute(target.element, "AXStringForTextMarkerRange", markerRange) as? String else {
        return false
    }
    return !text.isEmpty
}

enum AXWriteResult {
    // 已确认写入
    case inserted
    // 写入请求超时，App 可能稍后才真正执行；不要再走剪贴板回退，免得粘贴两遍
    case uncertain
    // 这里不适合（或没能）用 Accessibility 写入，改走真正的 ⌘V
    case notApplicable
}

// 终端类 App 对写入 kAXSelectedText 普遍只接了个假成功的桩：返回 .success，但命令行里什么都没插入
// （它本质是自绘的滚动缓冲区，不是标准可编辑文本控件）。已经实测确认 iTerm2 会这样。
let knownTerminalBundleIDs: Set<String> = [
    "com.apple.Terminal",
    "com.googlecode.iterm2",
    "dev.warp.Warp-Stable",
    "dev.warp.Warp-Preview",
    "net.kovidgoyal.kitty",
    "com.github.wez.wezterm",
    "com.mitchellh.ghostty",
    "org.alacritty",
    "co.zeit.hyper",
    "org.tabby",
    "com.raphaelamorim.rio",
]

// JetBrains 系 IDE 的编辑器在 Java 事件线程上异步应用 Accessibility 写入，写完立刻校验会读到旧长度，
// 误判失败后再走 ⌘V 回退就会粘贴两遍；直接走真正的 ⌘V，也保留 IDE 自己的粘贴处理（缩进、自动导入等）
let axWriteUnreliableBundleIDPrefixes = ["com.jetbrains.", "com.google.android.studio"]

// 只对原生文本控件尝试 Accessibility 写入
let axWritableRoles: Set<String> = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole]

// 把 text 直接写入焦点控件的选区（替换选中内容/在光标处插入），全程不经过系统剪贴板。
// terminalInputField：焦点在终端 App 里的原生输入框（iTerm2 的 Composer），不在终端画面上。终端画面会假装写成功，所以终端 App
// 默认不写；输入框照常写，写完照样确认真的写进去了
func writeSelectedText(_ text: String, to target: FocusedTarget, terminalInputField: Bool = false) -> AXWriteResult {
    if let bundleID = target.bundleIdentifier,
       (!terminalInputField && knownTerminalBundleIDs.contains(bundleID)) || axWriteUnreliableBundleIDPrefixes.contains(where: { bundleID.hasPrefix($0) }) {
        return .notApplicable
    }
    // 别家用 IntelliJ 平台做的 IDE（bundle ID 不是上面那些）：一样异步应用写入
    if target.isJavaIDE {
        return .notApplicable
    }
    guard let role = target.role, axWritableRoles.contains(role), !target.isSecureTextField, !target.isWebContent else {
        return .notApplicable
    }
    var settable: DarwinBoolean = false
    guard !axBudgetExhausted,
          AXUIElementIsAttributeSettable(target.element, kAXSelectedTextAttribute as CFString, &settable) == .success,
          settable.boolValue else {
        return .notApplicable
    }
    // 写完要能校验确实写进去了才写：读不到长度和选区的控件，没法和"假成功"的空实现区分开
    guard let lengthBefore = target.numberOfCharacters, let selectionBefore = target.selectedRange else {
        return .notApplicable
    }

    // 写入本身给宽一点的超时，正常的原生控件都是毫秒级完成；剩余预算里给写完之后的校验留出余量
    let verificationReserve: TimeInterval = 0.08
    let writeTimeout = min(0.35, (axBudgetRemaining ?? 0.43) - verificationReserve)
    guard writeTimeout > 0.05 else {
        return .notApplicable
    }
    AXUIElementSetMessagingTimeout(target.element, Float(writeTimeout))
    let startedAt = DispatchTime.now()
    let result = AXUIElementSetAttributeValue(target.element, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
    let elapsed = TimeInterval(DispatchTime.now().uptimeNanoseconds - startedAt.uptimeNanoseconds) / 1_000_000_000
    // 校验用的读取要快速失败
    AXUIElementSetMessagingTimeout(target.element, 0.05)
    switch result {
    case .success:
        // 长度、光标和选中内容都纹丝不动，说明是个假成功的空实现；稍等一下再看，给晚一步落地的控件留余地。
        // 全都读不到时没法判断：吞掉按键但不报"成功"，免得写入其实生效了、再走 ⌘V 回退又粘贴一遍。
        var sawState = false
        var lengthAfter: Int?
        for attempt in 0..<3 {
            if attempt > 0 {
                sleepAttentively(0.015)
            }
            lengthAfter = target.numberOfCharacters
            let caretAfter = target.selectedRange?.location
            if lengthAfter != nil || caretAfter != nil {
                sawState = true
            }
            if let lengthAfter, lengthAfter != lengthBefore {
                break
            }
            if let caretAfter, caretAfter != selectionBefore.location {
                break
            }
            if target.selectedText == text {
                break
            }
            if attempt == 2 {
                return sawState ? .notApplicable : .uncertain
            }
        }
        // 写进去了。有的 App 插入时会改写文字（Xcode 的自动缩进、智能引号……），只看长度会当成原样粘贴：读回插入处的文字核对一遍。
        // 不一样时文字照样留着（不撤销、不重写，免得粘贴两遍），只提醒用户检查；读不回来时照旧
        if insertedTextWasRewritten(text, in: target, selectionBefore: selectionBefore, lengthBefore: lengthBefore, lengthAfter: lengthAfter) {
            notifyCopiNotice("\(target.applicationName) changed the pasted text as it was inserted (for example auto-indent or smart quotes). Check it.")
        } else {
            notifyProtected("Pasted safely")
        }
        return .inserted
    case .cannotComplete where elapsed >= writeTimeout * 0.8:
        // 真的等到了超时：App 可能稍后才执行这次写入，不要再走 ⌘V 回退，免得粘贴两遍
        return .uncertain
    default:
        // 包括很快就返回的 cannotComplete（消息根本没送到），这时肯定没写进去
        return .notApplicable
    }
}

// writeSelectedText 写入之后，插入处的文字和写进去的不一样（App 插入时改写了）。插入了多长按字符数的实际变化算：
// 没改写时就是预期的范围；改写时长度也可能跟着变（自动缩进），控件把 \r\n 存成 \n 时也会变短，所以换行统一成 \n 再比。
// 读不到字符数、插入处的文字时没法判断，返回 false
private func insertedTextWasRewritten(_ text: String, in target: FocusedTarget, selectionBefore: CFRange,
                                      lengthBefore: Int, lengthAfter: Int?) -> Bool {
    // 字符数和选区都来自目标 App：没有选区时 AppKit 报的 location 是 NSNotFound（Int.max）。
    // 先确认选区落在原文里、字符数不是负数，下面的加减才不会溢出（溢出会直接崩溃）；不在范围内时没法判断
    guard let lengthAfter, lengthAfter >= 0, !text.isEmpty, selectionBefore.location >= 0, selectionBefore.length >= 0,
          selectionBefore.location <= lengthBefore, selectionBefore.length <= lengthBefore - selectionBefore.location else {
        return false
    }
    let insertedLength = lengthAfter - (lengthBefore - selectionBefore.length)
    guard insertedLength > 0, insertedLength <= lengthAfter - selectionBefore.location else {
        return false
    }
    var range = CFRange(location: selectionBefore.location, length: insertedLength)
    // 有的控件不支持这项查询时回一个空字符串
    guard let readBack = AXValueCreate(.cfRange, &range).flatMap({ copyAXParameterizedAttribute(target.element, "AXStringForRange", $0) as? String }),
          !readBack.isEmpty else {
        return false
    }
    return KeystrokeTyper.normalizedNewlines(readBack) != KeystrokeTyper.normalizedNewlines(text)
}

// MARK: - 手动模式（快捷键、Action Bar）的安全复制/粘贴

// 安全复制：不经过系统剪贴板读选区（原生控件、网页、终端……），存进安全剪贴板；
// 读不到时（Electron App 没开无障碍等）默认拒绝；允许剪贴板回退时模拟一次 ⌘C、拿到文本后立刻恢复原来的系统剪贴板。
func safeCopySelection() {
    // 锁屏时什么都不做
    guard !sessionIsLockedNow() else {
        return
    }
    let strict = ZeroExposurePolicy.isStrict
    // 用户放行的 App：照常借助系统剪贴板复制
    if ZeroExposurePolicy.usesNormalClipboard(focusedApplication()?.bundleIdentifier) {
        let source = focusedApplication()?.bundleIdentifier
        ClipboardCapture.shared.captureCopy { text, concealed in
            didSafeCopy(text, concealed: concealed, source: source, through: .normalClipboardApp)
        }
        return
    }
    // 上一次粘贴挂上去的内容还没被读走时，不去打扰目标 App（它可能正等着我们的主线程提供数据）
    guard !TransientPaste.shared.awaitingRead else {
        if strict {
            notifyCopiNotice("Copi is still finishing a paste. Try copying again in a moment.")
        } else {
            let source = focusedApplication()?.bundleIdentifier
            ClipboardCapture.shared.captureCopy { text, concealed in
                didSafeCopy(text, concealed: concealed, source: source, through: .fallback)
            }
        }
        return
    }
    // 读不到时顺便判断：是不是密码框、文件列表这类本来就复制不了文字的地方（这时不提示、也不清掉安全剪贴板）；选了多段时只读得到第一段。
    // Firefox 看不出选了几段（用 ⌘ 添过选区的地方）：允许剪贴板回退时也拒绝。⌘按下只在开着 Override ⌘C/⌘V 时记得下来
    // （PointerInterceptor 的 tap 只在那时运行），手动模式下这里通常查不到
    let (text, target, nothingToCopy, multipleSelections, unlistedSelections): (String?, FocusedTarget?, Bool, Bool, Bool) = withAXBudget(0.5) {
        let target = focusedTarget()
        if let target, target.hasMultipleSelections {
            // 原生文本视图里一段一段读出来（里面的附件占位符由 didSafeCopy 去掉）；读不全就拒绝
            if let text = target.multipleSelectionText, target.webEngine(attributeNames: target.attributeNames) == nil {
                return (text, target, false, false, false)
            }
            return (nil, target, false, true, false)
        }
        if let target, target.mayHaveUnlistedSelections {
            return (nil, target, false, true, true)
        }
        if let copied = target.flatMap({ zeroExposureCopySelection(from: $0) }) {
            // 去掉了附件时补回一个占位符，交给 didSafeCopy 识别、提示
            return (copied.droppedAttachments ? copied.text + "\u{FFFC}" : copied.text, target, false, false, false)
        }
        let nothingToCopy = target.map { $0.isSecureTextField || $0.isKnownNonTextContext } ?? false
        return (nil, target, nothingToCopy, false, false)
    }
    if let text {
        didSafeCopy(text, concealed: false, source: target?.bundleIdentifier)
        return
    }
    // 默认不借助系统剪贴板复制，拒绝（安全剪贴板里更早的内容一并作废）
    if strict || unlistedSelections {
        if multipleSelections {
            GlobalMode.shared.refuseCopy(app: RefusedApp(target: target), cut: false, reason: .multipleSelections)
        } else if !nothingToCopy {
            GlobalMode.shared.refuseCopy(app: RefusedApp(target: target), cut: false)
        }
        return
    }
    let source = target?.bundleIdentifier ?? focusedApplication()?.bundleIdentifier
    ClipboardCapture.shared.captureCopy { text, concealed in
        didSafeCopy(text, concealed: concealed, source: source, through: .fallback)
    }
}

// 安全复制是不是借助系统剪贴板做的（App 把文字写进了系统剪贴板，停留到 Copi 取走为止）
private enum CopyChannel {
    case direct
    // 允许剪贴板回退时
    case fallback
    // 在照常使用系统剪贴板的 App 里
    case normalClipboardApp
}

// text 里的附件占位符（U+FFFC）去掉，只保管文字，并告诉用户图片没带上。source：在哪个 App 里复制的（密码管理器里的按机密处理）。
// through：借助系统剪贴板复制的不说"安全"
private func didSafeCopy(_ text: String, concealed: Bool, source: String?, through channel: CopyChannel = .direct) {
    let droppedAttachments = text.contains("\u{FFFC}")
    let plainText = text.replacingOccurrences(of: "\u{FFFC}", with: "")
    // 只复制到了附件占位符（例如选中的是一张图片）：没有可保管的文本，什么都不动
    guard !plainText.isEmpty, !(droppedAttachments && plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) else {
        return
    }
    SecureClipboard.shared.setText(plainText, concealed: concealed || ZeroExposurePolicy.isPasswordManager(source), source: source)
    let pasteboard = NSPasteboard.general
    // Override 模式下 ⌘V 只在系统剪贴板为空时才粘贴安全剪贴板，这里清掉之前留在上面的内容
    if GlobalMode.shared.isOverrideActive {
        TransientPaste.shared.finish()
        pasteboard.markSeen(pasteboard.copiClear())
    }
    GlobalMode.shared.noteSafeCopy()
    if droppedAttachments {
        notifyCopiNotice("Copi copied only the text. Images and attachments in the selection can't be copied without the system clipboard.")
    } else if channel == .fallback {
        notifyProtected("Copied through the system clipboard (Allow Clipboard Fallback is on), so other apps could read it for a moment")
    } else if channel == .normalClipboardApp {
        notifyProtected("Copied through the system clipboard (this app uses the normal clipboard), so other apps could read it for a moment")
    } else {
        notifyProtected("Copied safely")
    }
}

// 安全粘贴：不经过系统剪贴板，直接写进焦点控件或模拟键入；没有这样的办法时默认拒绝；允许剪贴板回退时（以及用户放行的 App 里）
// 把内容临时挂到系统剪贴板上、模拟一次 ⌘V，App 读走后恢复原来的剪贴板内容。
// 现在是不是锁着屏（任意线程，直接问系统，不靠可能被伪造、可能丢失的通知）
func screenIsLockedNow() -> Bool {
    (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool == true
}

// 锁着屏、或者这个用户的会话被切到了后台（快速切换用户），或者焦点在登录窗口上：这时不复制、不粘贴、不键入
func sessionIsLockedNow() -> Bool {
    screenIsLockedNow() || SessionActivity.switchedAway
        || (Thread.isMainThread && NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.loginwindow")
}

// 快速切换用户：这个用户的会话被切到了后台（任意线程读）
enum SessionActivity {
    private static let lock = NSLock()
    private static var away = false

    static func setSwitchedAway(_ value: Bool) {
        lock.lock()
        away = value
        lock.unlock()
    }

    static var switchedAway: Bool {
        lock.lock()
        defer { lock.unlock() }
        return away
    }
}

// expected：Action Bar 出现时拿着焦点的输入框。点 Paste 时焦点必须还在它上面，否则不粘贴（Action Bar 开着的时候焦点可能被别的
// App、网页换走了，粘贴就会落进用户没想到的地方）
// deliberate：是用户亲手按的快捷键、点的按钮（见 hardwareInput）。只有这样才算"再粘贴一次"的确认
func safePaste(expecting expected: AXUIElement? = nil, deliberate: Bool) {
    let keyTime = Date()
    if deliberate {
        PastePress.noteDeliberate(at: keyTime)
    }
    guard let text = SecureClipboard.shared.text, !sessionIsLockedNow() else {
        // 没有文字：Copi 里可能存着关掉 Override 之前收进来的图片、文件（Action Bar 只粘贴文字）
        if expected == nil, !sessionIsLockedNow() {
            GlobalMode.shared.safePasteNonText(keyTime: keyTime)
        }
        return
    }
    let strict = ZeroExposurePolicy.isStrict
    let focused = focusedApplication()
    // 上一次退回剪贴板方式挂上去的这段文字还在：续期。续期也是退回剪贴板，有会把本机剪贴板同步出去的 App 在运行时一样先提醒
    if expected == nil, TransientPaste.shared.isOnPasteboard, TransientPaste.shared.isStaged(text, for: focused?.processIdentifier), !strict {
        // Copi 还在往这个 App 里键入上一次粘贴（或者刚打到一半停下）：续期粘贴进去的文字也会和打了一半的那段混在一起
        if let pid = focused?.processIdentifier, KeystrokeTyper.shared.isTypingOrJustStopped(into: pid, element: nil, keyTime: keyTime) {
            notifyPasteRefused(.stillTyping, app: RefusedApp(target: nil))
            return
        }
        if let reason = remoteClipboardConfirmationBeforeFallback(text, targetPID: focused?.processIdentifier, keyTime: keyTime) {
            TransientPaste.shared.finish()
            notifyPasteRefused(reason, app: RefusedApp(target: nil))
            return
        }
        TransientPaste.shared.stage(text, restorePrevious: true, for: focused?.processIdentifier)
        GlobalMode.shared.postFallbackPaste()
        return
    }
    // 粘贴进放行的 App 时也不经过系统剪贴板：安全剪贴板里的文字是从别的 App 复制来的
    let (outcome, app, element) = withAXBudget(0.5) { () -> (ZeroExposurePasteResult?, RefusedApp, AXUIElement?) in
        let target = focusedTarget()
        if let expected, !(target.map { CFEqual($0.element, expected) } ?? false) {
            return (nil, RefusedApp(target: target), nil)
        }
        return (zeroExposurePaste(text, into: target, keyTime: keyTime), RefusedApp(target: target), target?.element)
    }
    guard let result = outcome else {
        notifyCopiNotice("The focus moved after the Action Bar appeared, so Copi pasted nothing. Click in the field you want to paste into and paste again.")
        return
    }
    switch result {
    case .inserted, .typing:
        return
    case .unavailable(let reason):
        let note = ZeroExposurePolicy.usesNormalClipboard(focused?.bundleIdentifier) ? normalClipboardPasteNote : ""
        if !reason.allowsClipboardFallback {
            notifyPasteRefused(reason, app: app, suffix: note)
            return
        }
        // 默认（不允许剪贴板回退）：第一次说明为什么，8 秒内用户亲手再粘贴一次才经过剪贴板粘贴
        if strict, ClipboardPasteConsent.needsConfirmation(text, targetPID: focused?.processIdentifier, element: element, keyTime: keyTime) {
            notifyPasteRefused(reason, app: app, suffix: note + ClipboardPasteConsent.offer(appName: app.name), prompts: true)
            return
        }
    }
    // 有会把本机剪贴板同步出去的 App 在运行：先提醒
    if let reason = remoteClipboardConfirmationBeforeFallback(text, targetPID: focused?.processIdentifier, keyTime: keyTime) {
        notifyPasteRefused(reason, app: app)
        return
    }
    TransientPaste.shared.stage(text, restorePrevious: true, for: focused?.processIdentifier)
    GlobalMode.shared.postFallbackPaste()
}

// MARK: - 键盘拦截

// 运行在独立后台线程上的主动过滤型 event tap：系统里每一次按键都要等回调返回才能继续派发。
// 之前它挂在主线程的 run loop 上，主线程只要被一次 Accessibility 调用、SwiftUI 渲染之类的事情卡住，
// 全系统打字都会跟着卡；超过阈值系统还会直接停用 tap，期间按下的 ⌘V 会绕过 Copi 原样到达 App。
final class KeyTap {
    // 返回 true 表示吞掉这个按键
    typealias Handler = (CGEvent) -> Bool

    fileprivate let handler: Handler
    private let eventMask: CGEventMask
    private let lock = NSLock()
    private var port: CFMachPort?
    private var runLoop: CFRunLoop?

    init(events: [CGEventType], handler: @escaping Handler) {
        self.eventMask = events.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
        self.handler = handler
    }

    private var currentPort: CFMachPort? {
        lock.lock()
        defer { lock.unlock() }
        return port
    }

    // tap 已创建、mach port 仍然有效，并且处于启用状态
    var isActive: Bool {
        guard let port = currentPort, CFMachPortIsValid(port) else {
            return false
        }
        return CGEvent.tapIsEnabled(tap: port)
    }

    // 创建并启动（已经创建过则什么都不做）。没有辅助功能权限时创建会失败，返回 false。
    @discardableResult
    func start() -> Bool {
        if currentPort != nil {
            return true
        }
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            // 排在会话层已有的 tap 后面：改键工具（BetterTouchTool、Hammerspoon、Keyboard Maestro）把 ⌃C、鼠标侧键改成 ⌘C 时，
            // Copi 看到的是改过之后、App 真正会收到的按键。插在最前面的话，谁先启动谁在前，Copi 重建 tap 之后就会排到它们前面，
            // 看到的是改之前的按键，改出来的 ⌘C 绕过 Copi 直接到达 App
            guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                               place: .tailAppendEventTap,
                                               options: .defaultTap,
                                               eventsOfInterest: eventMask,
                                               callback: keyTapCallback,
                                               userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
                ready.signal()
                return
            }
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
            let currentRunLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(currentRunLoop, source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            lock.lock()
            self.port = port
            self.runLoop = currentRunLoop
            lock.unlock()
            ready.signal()
            CFRunLoopRun()
            // run loop 结束：stop() 主动停止，或者 mach port 被系统作废。后一种情况把记录清掉，下次 start() 才会重建
            lock.lock()
            if self.port === port {
                self.port = nil
                self.runLoop = nil
            }
            lock.unlock()
        }
        thread.name = "Copi.KeyTap"
        thread.qualityOfService = .userInteractive
        thread.start()
        _ = ready.wait(timeout: .now() + 2)
        return currentPort != nil
    }

    func stop() {
        lock.lock()
        let port = self.port
        let runLoop = self.runLoop
        self.port = nil
        self.runLoop = nil
        lock.unlock()
        guard let port else {
            return
        }
        CGEvent.tapEnable(tap: port, enable: false)
        // 让 mach port 及其 run loop source 失效（之前只是停用，切换一次开关就泄漏一个 tap）
        CFMachPortInvalidate(port)
        if let runLoop {
            CFRunLoopStop(runLoop)
        }
    }

    // 被系统停用（回调超时等）后重新启用
    func ensureEnabled() {
        guard let port = currentPort, CFMachPortIsValid(port), !CGEvent.tapIsEnabled(tap: port) else {
            return
        }
        CGEvent.tapEnable(tap: port, enable: true)
    }
}

private func keyTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    // 原样放行时必须用 passUnretained：事件归系统所有，passRetained 会让每一次按键都泄漏一个 CGEvent
    guard let userInfo else {
        return Unmanaged.passUnretained(event)
    }
    let tap = Unmanaged<KeyTap>.fromOpaque(userInfo).takeUnretainedValue()
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        tap.ensureEnabled()
        return Unmanaged.passUnretained(event)
    case .keyDown, .flagsChanged, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .leftMouseDragged:
        if event.getIntegerValueField(.eventSourceUserData) == copiSyntheticEventMarker {
            return Unmanaged.passUnretained(event)
        }
        return tap.handler(event) ? nil : Unmanaged.passUnretained(event)
    default:
        return Unmanaged.passUnretained(event)
    }
}

// 主线程正在执行的拦截决定是从什么时候开始的（event tap 线程据此判断主线程是不是正忙）
private let mainDecisionLock = NSLock()
private var mainDecisionStartedAt: DispatchTime?

// 在主线程上做拦截决定，event tap 线程同步等结果——这样被放行的原始按键一定晚于主线程上的准备工作
// （例如把要粘贴的内容挂上剪贴板）到达 App，后续按键也不会抢到它前面。
// 但最多只等 timeout，不能让整个键盘跟着主线程卡住；主线程正忙于上一个决定时干脆不等。等不到时：
//  - swallowOnTimeout 为 false：放行原始按键，这个决定如果还没开始执行就作废；
//  - swallowOnTimeout 为 true：先吞掉原始按键，决定照常执行，如果它的结论是"放行"，就原样补发一次
//    （⌘V 用这种方式：不然按键先到 App、要粘贴的内容后挂上去，就又成了"要按两次"）。
// decide 的参数 isStale：被吞掉的按键是否已经拖得太久（见下面的说明），在真正粘贴之前检查。
// onDropped：被吞掉的按键因为拖得太久而放弃时调用（主线程），用来告诉用户。
func decideOnMainThread(_ event: CGEvent, timeout: TimeInterval, swallowOnTimeout: Bool, onDropped: (() -> Void)? = nil,
                        _ decide: @escaping (_ isStale: () -> Bool) -> Bool) -> Bool {
    dispatchPrecondition(condition: .notOnQueue(.main))
    final class State {
        let lock = NSLock()
        var timedOut = false
        var swallowedOnTimeout = false
        var result: Bool?
    }
    let state = State()
    let done = DispatchSemaphore(value: 0)
    let replay = swallowOnTimeout ? event.copy() : nil
    let issuedAt = DispatchTime.now()
    let issuedDate = Date()
    DispatchQueue.main.async {
        state.lock.lock()
        let timedOut = state.timedOut
        let swallowed = state.swallowedOnTimeout
        state.lock.unlock()
        // 原始按键已经放行，这个决定作废
        guard !(timedOut && !swallowed) else {
            return
        }
        // 吞掉的按键拖得太久（主线程卡了超过 1 秒）：用户多半已经接着打字、甚至换了地方，这时再粘贴只会落错位置，
        // 宁可这次不粘贴，让用户重按
        let isStale = { () -> Bool in
            state.lock.lock()
            let swallowedOnTimeout = state.timedOut && state.swallowedOnTimeout
            state.lock.unlock()
            // 拖得太久，或者按键之后用户已经接着按了别的键、点了鼠标（可能已经换了地方）
            return swallowedOnTimeout
                && (DispatchTime.now().uptimeNanoseconds - issuedAt.uptimeNanoseconds > 1_000_000_000 || userActedSince(issuedDate))
        }
        if isStale() {
            onDropped?()
            return
        }
        mainDecisionLock.lock()
        mainDecisionStartedAt = .now()
        mainDecisionLock.unlock()
        let result = decide(isStale)
        mainDecisionLock.lock()
        mainDecisionStartedAt = nil
        mainDecisionLock.unlock()

        state.lock.lock()
        state.result = result
        let needsReplay = state.timedOut && state.swallowedOnTimeout && !result
        state.lock.unlock()
        done.signal()
        guard needsReplay, let replay else {
            return
        }
        if isStale() {
            // 决定做完时已经太晚：不再补发，刚挂上去的内容也撤下
            TransientPaste.shared.finish()
            onDropped?()
            return
        }
        repostKeystroke(replay)
    }

    mainDecisionLock.lock()
    let busySince = mainDecisionStartedAt
    mainDecisionLock.unlock()
    var wait = timeout
    if let busySince, DispatchTime.now().uptimeNanoseconds - busySince.uptimeNanoseconds > 50_000_000 {
        wait = 0
    }
    _ = done.wait(timeout: .now() + wait)

    state.lock.lock()
    defer { state.lock.unlock() }
    if let result = state.result {
        return result
    }
    state.timedOut = true
    state.swallowedOnTimeout = swallowOnTimeout
    return swallowOnTimeout
}
