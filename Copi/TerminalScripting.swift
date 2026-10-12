//
//  TerminalScripting.swift
//  Copi
//
//  终端自己的接口：把要粘贴的文字直接交给终端进程——不经过剪贴板，也不经过键盘事件（能看到按键的程序看不到它，
//  拼音开着也不用临时切换），整段一次写进终端，没有逐个按键的时序问题（fish 也能多行粘贴）。
//   - iTerm2（Apple Event 的 write text）：原样写进终端。和键入一样，Copi 先确认终端停在 shell 提示符前，多行文字自己包上
//     bracketed paste 的标记。tmux 整合（tmux -CC）的会话里不送（write text 会变成 tmux 的命令）；
//   - Ghostty 1.3 起（Apple Event 的 input text）、WezTerm（它本地 socket 上的 SendPaste，和它自己的 ⌘V 走同一段代码）、
//     kitty（远程控制的 send-text）：和真正的粘贴一样由终端决定加不加标记，所以终端里运行着 Vim 时也能粘贴单行文字
//     （Vim 自己的终端窗口里运行着程序时除外）。
//  焦点所在的程序不在提示符前、而是在按行读（Python 的 input()、ssh 问密码）时，单行文字照模拟键入的规则键入（见 typeIntoLineReader）。
//  iTerm2、Ghostty 需要用户允许 Copi 控制它们（系统设置 › 隐私与安全性 › 自动化；在 Copi 的设置里点一下会弹出系统的询问），
//  没有允许时不弹询问，照旧模拟键入。WezTerm 什么都不用设置。kitty 默认关着远程控制，用户在 kitty.conf 里打开之后才能用
//  （见 README；Copi 不替用户改：打开之后同一用户的别的程序也能往 kitty 里送文字）。
//

import Foundation
import AppKit
import Carbon

enum TerminalScript {
    case iTerm2
    case ghostty
    case wezterm
    case kitty

    static let all: [TerminalScript] = [.iTerm2, .ghostty, .wezterm, .kitty]

    init?(bundleIdentifier: String?) {
        switch bundleIdentifier {
        case "com.googlecode.iterm2"?:
            self = .iTerm2
        case "com.mitchellh.ghostty"?:
            self = .ghostty
        case "com.github.wez.wezterm"?:
            self = .wezterm
        case "net.kovidgoyal.kitty"?:
            self = .kitty
        default:
            return nil
        }
    }

    var bundleIdentifier: String {
        switch self {
        case .iTerm2:
            return "com.googlecode.iterm2"
        case .ghostty:
            return "com.mitchellh.ghostty"
        case .wezterm:
            return "com.github.wez.wezterm"
        case .kitty:
            return "net.kovidgoyal.kitty"
        }
    }

    var displayName: String {
        switch self {
        case .iTerm2:
            return "iTerm2"
        case .ghostty:
            return "Ghostty"
        case .wezterm:
            return "WezTerm"
        case .kitty:
            return "kitty"
        }
    }

    // 通过 Apple Event（要用户在系统设置里允许）；否则通过终端自己的本地 socket
    var usesAppleEvents: Bool {
        self == .iTerm2 || self == .ghostty
    }

    enum Permission {
        case allowed
        // 还没问过用户（kitty：还没在 kitty.conf 里打开远程控制）
        case notDetermined
        case denied
        // 终端没在运行（系统只能对运行着的 App 询问）
        case notRunning
        // 这个版本用不了（kitty 0.32.2 以前不认 bracketed_paste）
        case unsupported
    }

    // 授权状态的缓存：系统查询要和终端进程来回通信，终端卡住时会一直等下去，所以只在后台线程上查，主线程只读缓存
    private static let cacheLock = NSLock()
    private static var cachedPermissions: [pid_t: Permission] = [:]
    // 正在后台查询的进程，以及查完要通知的回调
    private static var refreshing: [pid_t: [(Permission) -> Void]] = [:]

    // 上次查到的授权状态（任意线程）；还没查过时为 nil
    static func cachedPermission(pid: pid_t) -> Permission? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cachedPermissions[pid]
    }

    // 在后台重新查一次授权状态（同一个进程同时只查一次），查完在主线程回调
    static func refreshPermission(pid: pid_t, then done: ((Permission) -> Void)? = nil) {
        cacheLock.lock()
        let inFlight = refreshing[pid] != nil
        refreshing[pid, default: []] += done.map { [$0] } ?? []
        cacheLock.unlock()
        guard !inFlight else {
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let result = determinePermission(pid: pid, ask: false)
            cacheLock.lock()
            cachedPermissions[pid] = result
            let waiters = refreshing.removeValue(forKey: pid) ?? []
            cacheLock.unlock()
            if !waiters.isEmpty {
                DispatchQueue.main.async {
                    waiters.forEach { $0(result) }
                }
            }
        }
    }

    // 终端退出后忘掉它（进程号会被复用）
    static func forget(pid: pid_t) {
        cacheLock.lock()
        cachedPermissions[pid] = nil
        cacheLock.unlock()
    }

    // 弹出系统的询问并等用户回答：只在后台线程调用
    static func requestPermission(pid: pid_t) -> Permission {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let result = determinePermission(pid: pid, ask: true)
        cacheLock.lock()
        cachedPermissions[pid] = result
        cacheLock.unlock()
        return result
    }

    private static func determinePermission(pid: pid_t, ask: Bool) -> Permission {
        // WezTerm、kitty：看它在不在本地 socket 上听
        if let running = NSRunningApplication(processIdentifier: pid), let script = TerminalScript(bundleIdentifier: running.bundleIdentifier),
           !script.usesAppleEvents {
            if script == .kitty, !kittyIsSupported(bundleURL: running.bundleURL) {
                return .unsupported
            }
            return script.socketPath(pid: pid) != nil ? .allowed : .notDetermined
        }
        let target = NSAppleEventDescriptor(processIdentifier: pid)
        guard let address = target.aeDesc else {
            return .notRunning
        }
        let wildcard = fourCharCode("****")
        switch AEDeterminePermissionToAutomateTarget(address, wildcard, wildcard, ask) {
        case 0:
            return .allowed
        case -1744: // errAEEventWouldRequireUserConsent
            return .notDetermined
        case -600: // procNotFound
            return .notRunning
        default: // errAEEventNotPermitted 等
            return .denied
        }
    }

    // MARK: 粘贴

    private static let queue = DispatchQueue(label: "Copi.TerminalScript", qos: .userInitiated)

    // 主线程、strict 模式下的终端粘贴（焦点在终端画面上）。终端允许 Copi 用脚本接口时在后台送出并返回 true（结果用通知告诉用户）；
    // 否则返回 false，调用方照旧模拟键入。fallback：后台发现脚本接口用不了（还什么都没写进终端）时在主线程调用
    static func pasteIfPermitted(_ text: String, into target: FocusedTarget, keyTime: Date, fallback: @escaping () -> Void) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let script = TerminalScript(bundleIdentifier: target.bundleIdentifier) else {
            return false
        }
        guard script.usesAppleEvents else {
            return script.pasteThroughSocket(text, into: target, keyTime: keyTime, fallback: fallback)
        }
        refreshPermission(pid: target.pid)
        guard cachedPermission(pid: target.pid) == .allowed, script.isFocusedOnTerminal(target) else {
            return false
        }
        // 焦点所在窗口的标题：确认脚本接口说的"最前面的窗口"就是它
        guard let windowTitle = target.focusedWindowTitle else {
            return false
        }
        let app = RefusedApp(target: target)
        let pid = target.pid
        // 读不出焦点所在终端会话的 tty 时（Ghostty 1.3）只能看所有标签页
        let allGroups = script == .ghostty ? terminalForegroundGroups(of: target) : nil
        queue.async {
            // iTerm2 的 tmux 整合（tmux -CC）：整合开出来的会话没有本机的终端设备，write text 由 iTerm2 变成 tmux 的命令送过去
            // （tmux 把执行过的命令连同参数记进消息记录），运行 tmux -CC 的会话收到的文字本身就是 tmux 的命令。先问 iTerm2
            // 焦点所在的会话是不是；问不到时看进程树，开着整合就不送（看不出焦点在不在整合开出来的会话上）
            if script == .iTerm2, script.focusedSessionIsInTmuxIntegration(pid: pid) ?? iTermTmuxIntegrationIsRunning(pid: pid) {
                DispatchQueue.main.async {
                    refuseOrFallBack(.modalProgram("tmux"), text: text, target: target, keyTime: keyTime)
                }
                return
            }
            let terminal: (tty: String?, windowName: String?)
            do {
                terminal = try script.focusedTerminal(pid: pid)
            } catch {
                DispatchQueue.main.async { fallback() }
                return
            }
            let focusedGroup = terminal.tty.flatMap { foregroundGroup(ofTerminalDevice: $0) }
            guard terminal.windowName == windowTitle,
                  let group = focusedGroup ?? (terminal.tty == nil ? allGroups.map({ $0.flatMap { $0 } }) : nil) else {
                DispatchQueue.main.async { fallback() }
                return
            }
            // 前台是 tmux：交给 tmux 粘贴进它当前的 pane
            if let client = focusedGroup.flatMap({ TmuxPaste.isClient($0) ? $0.first : nil }) ?? (terminal.tty == nil ? TmuxPaste.soleClient(in: allGroups) : nil) {
                TmuxPaste.report(TmuxPaste.paste(text, client: client, keyTime: keyTime), text: text, target: target, keyTime: keyTime)
                return
            }
            let payload: String
            switch script.payload(for: text, foreground: group) {
            case .success(let value):
                payload = value
            case .failure(let reason):
                DispatchQueue.main.async {
                    refuse(reason, focusedGroup: focusedGroup, text: text, target: target, keyTime: keyTime)
                }
                return
            }
            // 用户在这期间接着打字、点了别处：不再粘贴
            guard !userActedSince(keyTime) else {
                DispatchQueue.main.async {
                    notifyCopiNotice("Copi didn't paste into \(app.name) because you kept typing or clicked elsewhere. Press ⌘V again.")
                }
                return
            }
            do {
                try script.send(payload, to: terminal.tty, windowName: terminal.windowName, pid: pid)
                DispatchQueue.main.async {
                    notifyProtected("Pasted safely")
                }
            } catch let error as ScriptError where error.mayHaveArrived {
                // 等回音超时：终端可能已经（或稍后）写进去了，不能再键入一遍
                DispatchQueue.main.async {
                    notifyCopiNotice("Copi isn't sure the paste reached \(app.name). Check the terminal before pasting again.")
                }
            } catch {
                if let error = error as? ScriptError, error.code == -1743 || error.code == -1744 {
                    refreshPermission(pid: pid)
                }
                DispatchQueue.main.async { fallback() }
            }
        }
        return true
    }

    // 主线程：要送进焦点所在终端会话的内容被拒绝了（reason）。拒绝是因为那里的程序不在提示符前时，它可能在按行读
    // （Python 的 input()、ssh 问密码）：照模拟键入的规则判断，能键入就键入单行文字（见 typeIntoLineReader；文字这时经过按键送进去），
    // 不能就按那里的规则拒绝。没有本机终端设备的 pane、tmux 整合不走这里：模拟键入看不到里面运行着什么。
    // focusedGroup：终端说了焦点在哪个会话时，那个会话的前台进程组（kitty、读不到终端设备的 Ghostty 为 nil）
    private static func refuse(_ reason: UnavailableReason, focusedGroup: [ForegroundProcess]?, text: String, target: FocusedTarget, keyTime: Date) {
        var reason = reason
        if case .modalProgram(let program) = reason {
            guard case .unavailable(let refusal) = typeIntoLineReader(text, program: program, target: target, keyTime: keyTime,
                                                                     focusedGroup: focusedGroup) else {
                return
            }
            reason = refusal
        }
        refuseOrFallBack(reason, text: text, target: target, keyTime: keyTime)
    }

    // 焦点确实在终端画面上，并且是脚本接口能指到的那个窗口：iTerm2 的终端画面是选中文字不可改写的文本区域；
    // Ghostty 的终端画面带着固定的说明文字，而且不在 Quick Terminal 里（它是浮动面板，脚本接口的"最前面的窗口"不包括它）
    private func isFocusedOnTerminal(_ target: FocusedTarget) -> Bool {
        guard target.role == kAXTextAreaRole, target.isTerminalSurface else {
            return false
        }
        switch self {
        case .iTerm2, .wezterm, .kitty:
            return true
        case .ghostty:
            let application = AXUIElementCreateApplication(target.pid)
            guard copyAXAttribute(target.element, kAXHelpAttribute) as? String == "Terminal content area",
                  let window = asAXElement(copyAXAttribute(application, kAXFocusedWindowAttribute)),
                  copyAXAttribute(window, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole,
                  copyAXAttribute(window, kAXIdentifierAttribute) as? String != "com.mitchellh.ghostty.quickTerminal",
                  let title = copyAXAttribute(window, kAXTitleAttribute) as? String else {
                return false
            }
            // "最前面的窗口"按屏幕上的层次排：置顶（Float on Top）的窗口排在拿着焦点的窗口前面。只有标题独一无二时，
            // 标题对得上才说明是同一个窗口
            let windows = (copyAXAttribute(application, kAXWindowsAttribute) as? [AnyObject]) ?? []
            let sameTitle = windows.compactMap(asAXElement).filter { copyAXAttribute($0, kAXTitleAttribute) as? String == title }
            return sameTitle.count == 1
        }
    }

    // 送进终端的内容
    private func payload(for text: String, foreground group: [ForegroundProcess]) -> Result<String, UnavailableReason> {
        guard self == .iTerm2 else {
            return Self.pasteLikePayload(for: text, foreground: group)
        }
        // write text 原样写进终端：和一次写进终端的其他路线一样处理
        let atPrompt = group.allSatisfy(isAtPrompt)
        guard atPrompt else {
            return .failure(.modalProgram(programName(in: group)))
        }
        let shells = group.filter { !terminalPasswordPrograms.contains($0.name) }
        // 停在 sudo 这类的密码提示
        return terminalPayload(for: text, shells: shells, atPasswordPrompt: shells.count < group.count, ttys: group.map(\.tty))
    }

    // 和真正的粘贴一样由终端决定加不加 bracketed paste 标记的写入（Ghostty 的 input text、WezTerm 的 SendPaste、kitty 的 send-text）。
    // group：前台进程（kitty 看不出焦点在哪个标签页，是所有标签页的）
    static func pasteLikePayload(for text: String, foreground group: [ForegroundProcess]) -> Result<String, UnavailableReason> {
        let atPrompt = group.allSatisfy(isAtPrompt)
        let shells = group.filter { !terminalPasswordPrograms.contains($0.name) }
        // 停在 sudo 这类的密码提示
        let atPasswordPrompt = shells.count < group.count
        let program = programName(in: group)
        var body = KeystrokeTyper.normalizedNewlines(text)
        while body.hasSuffix("\n") {
            body.removeLast()
        }
        guard !body.isEmpty else {
            return .failure(.noRoute)
        }
        let hasControls = body.unicodeScalars.contains { $0.properties.generalCategory == .control }
        guard atPrompt else {
            // 别的程序：只有一定会打开 bracketed paste 模式的 Vim 能收单行文字（否则字母就是按键）。
            // 停在提示符前的 shell（kitty 的其他标签页）开着 vi 键位、又不打开 bracketed paste 模式时，字母是命令
            let promptShells = group.filter { terminalPromptPrograms.contains($0.name) && !terminalPasswordPrograms.contains($0.name) }
            // 组里的 sudo 这类（没有 use_pty 时它和它启动的程序在同一组）只是在等那个程序结束，看那个程序
            let launched = group.contains { !terminalPasswordPrograms.contains($0.name) }
            guard !hasControls,
                  group.allSatisfy({ isAtPrompt($0) || bracketedPastePrograms.contains($0.name) || (launched && terminalPasswordPrograms.contains($0.name)) }),
                  !promptShells.contains(where: { shellMayUseViMode(pid: $0.pid) && !shellEnablesBracketedPasteMode(pid: $0.pid) }) else {
                return .failure(hasControls ? .multiLine : .modalProgram(program))
            }
            // Vim 在它自己的终端窗口（:terminal）里运行着程序：终端窗口拿着焦点时 Vim 把粘贴的文字转给那个程序（less、另一个 vim 里
            // 字母是命令）。看不出焦点在 Vim 的哪个窗口、是什么模式：有这样的程序就拒绝；读不出进程表时按看不出在运行什么处理
            for process in group where bracketedPastePrograms.contains(process.name) {
                guard let embedded = hasDescendantOnOtherTerminal(process) else {
                    return .failure(.modalProgram(nil))
                }
                if embedded {
                    return .failure(.modalProgram("a program in \(process.name)'s terminal"))
                }
            }
            if let reason = canonicalLineRefusal(body, ttys: group.map(\.tty), atPasswordPrompt: false) {
                return .failure(reason)
            }
            return .success(body)
        }
        // shell 的行编辑器正在读、会打开 bracketed paste 模式：终端会加上标记，shell 整段插入、不执行。
        // 换行、制表符以外的控制字符换成可见的符号（和 Copi 自己包标记时一样）：不是每条路线的终端都会去掉文字里夹着的 ESC[201~
        // （tmux 3.7 以前的 paste-buffer 原样送出），它会提前结束 bracketed paste，后面的内容被当成命令执行
        let bracketed = !atPasswordPrompt && !shells.isEmpty
            && shells.allSatisfy { shellEnablesBracketedPasteMode(pid: $0.pid) && lineEditorIsReading(tty: $0.tty) }
        if bracketed {
            guard let sanitized = sanitizedForBracketedPaste(body) else {
                return .failure(.noRoute)
            }
            return .success(sanitized)
        }
        // 在等单个按键（zsh 的 read -q、bash 的 read -n 1）：第一个字符就是回答。sudo 这类在等密码时不看（设了 pwfeedback 的 sudo
        // 也关掉 canonical 模式）
        guard atPasswordPrompt || !shells.contains(where: { waitsForSingleKey($0) }) else {
            return .failure(.singleKeyPrompt)
        }
        guard !hasControls else {
            return .failure(.multiLine)
        }
        // 密码提示、脚本里的 read 这类按行收输入的终端放不下太长的一行
        if let reason = canonicalLineRefusal(body, ttys: group.map(\.tty), atPasswordPrompt: atPasswordPrompt) {
            return .failure(reason)
        }
        guard !shells.contains(where: { shellMayUseViMode(pid: $0.pid) }) else {
            return .failure(.viMode)
        }
        return .success(body)
    }

    // MARK: Apple Event

    struct ScriptError: Error {
        let code: Int
        // 超时：事件可能已经送到、正在（或稍后）执行
        var mayHaveArrived: Bool {
            code == -1712 // errAETimeout
        }
    }

    // 焦点所在的终端会话：它的终端设备、所在窗口的标题。Ghostty 的 tty 属性要到 1.3 之后的版本才有：读不到时 tty 为 nil
    // （先读到窗口标题，说明脚本接口本身是好的）
    private func focusedTerminal(pid: pid_t) throws -> (tty: String?, windowName: String?) {
        let window: NSAppleEventDescriptor
        let terminal: NSAppleEventDescriptor
        let ttyProperty: String
        switch self {
        case .iTerm2:
            // current session of current window
            window = Self.property("Crwn", of: .null())
            terminal = Self.property("Wcsn", of: window)
            ttyProperty = "Stty"
        case .ghostty:
            // focused terminal of selected tab of front window
            window = Self.property("GFWn", of: .null())
            terminal = Self.property("GTfT", of: Self.property("GWsT", of: window))
            ttyProperty = "Gtty"
        case .wezterm, .kitty:
            throw ScriptError(code: -1708)
        }
        if self == .ghostty {
            let windowName = try Self.get(Self.property("pnam", of: window), pid: pid).stringValue
            let tty = (try? Self.get(Self.property(ttyProperty, of: terminal), pid: pid))?.stringValue
            return (tty, windowName)
        }
        guard let tty = try Self.get(Self.property(ttyProperty, of: terminal), pid: pid).stringValue else {
            throw ScriptError(code: -1728)
        }
        let windowName = try? Self.get(Self.property("pnam", of: window), pid: pid).stringValue
        return (tty, windowName)
    }

    // iTerm2：焦点所在的会话属于 tmux 整合（运行着 tmux -CC 的 gateway，或者整合开出来的 client）时为 true，不属于时为 false
    // （没开整合时 iTerm2 不设 tmuxRole 这个变量）；问不到（旧版 iTerm2 没有这个命令、出错、超时）时为 nil
    private func focusedSessionIsInTmuxIntegration(pid: pid_t) -> Bool? {
        guard self == .iTerm2 else {
            return false
        }
        // variable (current session of current window) named "tmuxRole"
        let event = Self.event("Itrm", "varb", pid: pid)
        event.setParam(Self.property("Wcsn", of: Self.property("Crwn", of: .null())), forKeyword: Self.directObject)
        event.setParam(NSAppleEventDescriptor(string: "tmuxRole"), forKeyword: fourCharCode("Namd"))
        guard let reply = try? Self.send(event, timeout: 0.5) else {
            return nil
        }
        // 没设的变量没有值（missing value）或者是空的；只认文字
        guard let value = reply.paramDescriptor(forKeyword: Self.directObject),
              [fourCharCode("utxt"), fourCharCode("utf8"), fourCharCode("TEXT")].contains(value.descriptorType),
              let role = value.stringValue else {
            return false
        }
        return !role.isEmpty && role != "none"
    }

    // 写进终端。tty：发之前再确认一次焦点还在这个终端会话上（读不到 tty 的 Ghostty 确认窗口标题没变）
    private func send(_ payload: String, to tty: String?, windowName: String?, pid: pid_t) throws {
        // 复查失败（包括超时）都还没写任何东西：按"没送出去"处理
        guard let now = try? focusedTerminal(pid: pid), now.tty == tty, tty != nil || now.windowName == windowName else {
            throw ScriptError(code: -1728)
        }
        let event: NSAppleEventDescriptor
        switch self {
        case .iTerm2:
            // write (current session of current window) text payload newline false
            event = Self.event("Itrm", "sntx", pid: pid)
            event.setParam(Self.property("Wcsn", of: Self.property("Crwn", of: .null())), forKeyword: Self.directObject)
            event.setParam(NSAppleEventDescriptor(string: payload), forKeyword: fourCharCode("Text"))
            event.setParam(NSAppleEventDescriptor(boolean: false), forKeyword: fourCharCode("Wtnl"))
        case .ghostty:
            // input text payload to (focused terminal of selected tab of front window)
            event = Self.event("Ghst", "InTx", pid: pid)
            event.setParam(NSAppleEventDescriptor(string: payload), forKeyword: Self.directObject)
            let terminal = Self.property("GTfT", of: Self.property("GWsT", of: Self.property("GFWn", of: .null())))
            event.setParam(terminal, forKeyword: fourCharCode("GItT"))
        case .wezterm, .kitty:
            throw ScriptError(code: -1708)
        }
        _ = try Self.send(event, timeout: 1.0)
    }

    private static let directObject = fourCharCode("----")

    private static func event(_ eventClass: String, _ eventID: String, pid: pid_t) -> NSAppleEventDescriptor {
        NSAppleEventDescriptor(eventClass: fourCharCode(eventClass), eventID: fourCharCode(eventID),
                               targetDescriptor: NSAppleEventDescriptor(processIdentifier: pid),
                               returnID: AEReturnID(-1), transactionID: AETransactionID(0))
    }

    // "<code> of <container>" 这样的属性引用
    private static func property(_ code: String, of container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        let specifier = NSAppleEventDescriptor.record().coerce(toDescriptorType: fourCharCode("obj ")) ?? NSAppleEventDescriptor.record()
        specifier.setDescriptor(NSAppleEventDescriptor(typeCode: fourCharCode("prop")), forKeyword: fourCharCode("want"))
        specifier.setDescriptor(NSAppleEventDescriptor(enumCode: fourCharCode("prop")), forKeyword: fourCharCode("form"))
        specifier.setDescriptor(NSAppleEventDescriptor(typeCode: fourCharCode(code)), forKeyword: fourCharCode("seld"))
        specifier.setDescriptor(container, forKeyword: fourCharCode("from"))
        return specifier
    }

    // get <specifier>
    private static func get(_ specifier: NSAppleEventDescriptor, pid: pid_t) throws -> NSAppleEventDescriptor {
        let event = Self.event("core", "getd", pid: pid)
        event.setParam(specifier, forKeyword: directObject)
        guard let result = try send(event, timeout: 0.5).paramDescriptor(forKeyword: directObject) else {
            throw ScriptError(code: -1728)
        }
        return result
    }

    private static func send(_ event: NSAppleEventDescriptor, timeout: TimeInterval) throws -> NSAppleEventDescriptor {
        let reply: NSAppleEventDescriptor
        do {
            // 不让对方弹任何界面；没授权时不弹系统询问，直接失败
            reply = try event.sendEvent(options: [.waitForReply, .neverInteract], timeout: timeout)
        } catch let error as NSError {
            throw ScriptError(code: error.code)
        }
        if let code = reply.paramDescriptor(forKeyword: fourCharCode("errn"))?.int32Value, code != 0 {
            throw ScriptError(code: Int(code))
        }
        return reply
    }
}

// MARK: - WezTerm、kitty：终端自己的本地 socket

extension TerminalScript {
    // WezTerm 的每个窗口进程都在 ~/.local/share/wezterm/gui-sock-<pid> 上听（不需要任何设置）；kitty 要用户在 kitty.conf 里设置
    // listen_on unix:kitty-copi（kitty 把它放在临时目录里、后面加上自己的进程号）。只认当前用户自己的 socket 文件：
    // 别人放在那里的假 socket 会收到要粘贴的文字
    fileprivate func socketPath(pid: pid_t) -> String? {
        let path: String
        switch self {
        case .wezterm:
            path = NSHomeDirectory() + "/.local/share/wezterm/gui-sock-\(pid)"
        case .kitty:
            path = (NSTemporaryDirectory() as NSString).appendingPathComponent("kitty-copi-\(pid)")
        case .iTerm2, .ghostty:
            return nil
        }
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFSOCK, info.st_uid == getuid() else {
            return nil
        }
        return path
    }

    // 主线程：焦点在 WezTerm、kitty 的终端画面上时，在后台把文字交给终端并返回 true（结果用通知告诉用户）；用不了时返回 false，
    // 调用方照旧模拟键入。fallback：后台发现用不了（还什么都没写进终端）时在主线程调用
    fileprivate func pasteThroughSocket(_ text: String, into target: FocusedTarget, keyTime: Date, fallback: @escaping () -> Void) -> Bool {
        guard target.isTerminalSurface, let path = socketPath(pid: target.pid),
              let bundleURL = NSRunningApplication(processIdentifier: target.pid)?.bundleURL else {
            return false
        }
        let app = RefusedApp(target: target)
        let pid = target.pid
        let script = self
        // kitty 看不出焦点在哪个标签页：所有标签页都按同样的规则判断（和模拟键入一样）
        let kittyGroups = self == .kitty ? terminalForegroundGroups(of: target) : nil
        if self == .kitty, kittyGroups == nil {
            return false
        }
        // kitty 0.32.2 起才认 bracketed_paste（更早的版本会忽略它：多行文字的换行成了回车，送给 Vim、vi 键位的 shell 的单行文字
        // 成了按键）。更早的版本不走这里
        if self == .kitty, !Self.kittyIsSupported(bundleURL: bundleURL) {
            return false
        }
        // WezTerm 的复制模式、搜索框开着时，它说拿着焦点的仍是下面的 pane，粘贴会落进 shell 而不是搜索框：照旧键入（键入的按键
        // 会到达搜索框）。只键入单行文字、不包 bracketed paste（开头的 ESC 会关掉它，见 typeIntoTerminalByKeys）
        if self == .wezterm, target.wezTermOverlayMayBeOpen {
            return false
        }
        Self.queue.async {
            let group: [ForegroundProcess]
            var wezTermPane: Int?
            switch script {
            case .wezterm:
                let pane: (id: Int, tty: String)
                switch Self.focusedWezTermPane(pid: pid, socket: path, bundleURL: bundleURL) {
                case .local(let id, let tty):
                    pane = (id, tty)
                case .noTerminalDevice:
                    // ssh、tmux 这类域里的 pane：里面运行着什么看不到，模拟键入也一样（本机的进程树里没有它）
                    DispatchQueue.main.async {
                        refuseOrFallBack(.modalProgram(nil), text: text, target: target, keyTime: keyTime)
                    }
                    return
                case .unknown:
                    DispatchQueue.main.async { fallback() }
                    return
                }
                guard let found = foregroundGroup(ofTerminalDevice: pane.tty) else {
                    DispatchQueue.main.async { fallback() }
                    return
                }
                group = found
                wezTermPane = pane.id
            default:
                // 只有一个标签页、前台是 tmux：交给 tmux（kitty 的 send-text 会把文字当成按键送给 tmux）
                if let client = TmuxPaste.soleClient(in: kittyGroups) {
                    TmuxPaste.report(TmuxPaste.paste(text, client: client, keyTime: keyTime), text: text, target: target, keyTime: keyTime)
                    return
                }
                group = kittyGroups?.flatMap { $0 } ?? []
            }
            // WezTerm 的 pane 里前台是 tmux：交给 tmux 粘贴进它当前的 pane
            if script == .wezterm, TmuxPaste.isClient(group), let client = group.first {
                TmuxPaste.report(TmuxPaste.paste(text, client: client, keyTime: keyTime), text: text, target: target, keyTime: keyTime)
                return
            }
            let payload: String
            switch Self.pasteLikePayload(for: text, foreground: group) {
            case .success(let value):
                payload = value
            case .failure(let reason):
                DispatchQueue.main.async {
                    Self.refuse(reason, focusedGroup: script == .wezterm ? group : nil, text: text, target: target, keyTime: keyTime)
                }
                return
            }
            let multiLine = payload.unicodeScalars.contains { $0.properties.generalCategory == .control }
            // 用户在这期间接着打字、点了别处：不再粘贴
            guard !userActedSince(keyTime) else {
                DispatchQueue.main.async {
                    notifyCopiNotice("Copi didn't paste into \(app.name) because you kept typing or clicked elsewhere. Press ⌘V again.")
                }
                return
            }
            let result: SocketSendResult
            if let pane = wezTermPane {
                result = Self.sendWezTermPaste(payload, pane: pane, socket: path, pid: pid)
            } else {
                result = Self.sendKittyText(payload, bracketed: multiLine, socket: path, pid: pid)
            }
            DispatchQueue.main.async {
                switch result {
                case .sent:
                    notifyProtected("Pasted safely")
                case .unsure:
                    notifyCopiNotice("Copi isn't sure the paste reached \(app.name). Check the terminal before pasting again.")
                case .notSent:
                    TerminalScript.refreshPermission(pid: pid)
                    fallback()
                }
            }
        }
        return true
    }

    fileprivate enum SocketSendResult {
        case sent
        // 送出去了但没等到回音：可能已经（或稍后）写进终端
        case unsure
        // 肯定没写进去（连不上、终端拒绝）
        case notSent
    }

    // kitty 0.32.2 起才认 send-text 的 bracketed_paste
    fileprivate static func kittyIsSupported(bundleURL: URL?) -> Bool {
        bundleURL.flatMap { Bundle(url: $0) }.flatMap { $0.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String }
            .map { version($0, isAtLeast: [0, 32, 2]) } ?? false
    }

    // "0.49.2" 这样的版本号不低于 minimum
    private static func version(_ string: String, isAtLeast minimum: [Int]) -> Bool {
        let parts = string.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        for (index, required) in minimum.enumerated() {
            let part = index < parts.count ? parts[index] : 0
            if part != required {
                return part > required
            }
        }
        return true
    }

    // MARK: WezTerm

    // 拿着焦点的 pane 和它的终端设备：问 WezTerm 自带的命令行工具（list-clients 里窗口进程那一条的 focused_pane_id，
    // list 里这个 pane 的 tty_name）。这两条命令不带要粘贴的文字
    private enum WezTermPane {
        // 本机的 pane 和它的终端设备
        case local(id: Int, tty: String)
        // pane 在列表里却没有本机的终端设备：ssh、tmux 这类域里的 pane
        case noTerminalDevice
        // 问不到（命令行工具运行不了、列表里没有这个 pane）
        case unknown
    }

    private static func focusedWezTermPane(pid: pid_t, socket: String, bundleURL: URL) -> WezTermPane {
        guard let clients = runWezTermCLI(["list-clients", "--format", "json"], socket: socket, bundleURL: bundleURL) as? [[String: Any]],
              let client = clients.first(where: { ($0["pid"] as? NSNumber)?.int32Value == pid }),
              let paneID = (client["focused_pane_id"] as? NSNumber)?.intValue,
              let panes = runWezTermCLI(["list", "--format", "json"], socket: socket, bundleURL: bundleURL) as? [[String: Any]],
              let pane = panes.first(where: { ($0["pane_id"] as? NSNumber)?.intValue == paneID }) else {
            return .unknown
        }
        switch pane["tty_name"] {
        case let tty as String where tty.hasPrefix("/dev/"):
            return .local(id: paneID, tty: tty)
        default:
            // 没有本机的终端设备（ssh、tmux 这类域的 pane），或者 20230408 以前的 WezTerm 不输出这一项（分不出来是不是这种 pane）
            return .noTerminalDevice
        }
    }

    // 运行 WezTerm.app 里的 wezterm cli（和正在运行的窗口进程同一个版本），返回解析好的 JSON。环境变量只给它要的，
    // 不带 WEZTERM_PANE 之类（Copi 从 WezTerm 里启动时会继承到，会让它找错 pane）；--no-auto-start：连不上时不去启动服务进程
    private static func runWezTermCLI(_ arguments: [String], socket: String, bundleURL: URL) -> Any? {
        // -n：不加载用户的 wezterm.lua（它可以运行任何代码）。HelperProcess：程序文件可能被换掉，它不能带着 Copi 的权限运行
        let result = HelperProcess.run(bundleURL.appendingPathComponent("Contents/MacOS/wezterm").path, ["-n", "cli", "--no-auto-start"] + arguments,
                                       environment: ["HOME": NSHomeDirectory(), "WEZTERM_UNIX_SOCKET": socket, "PATH": "/usr/bin:/bin"],
                                       timeout: 1.5)
        guard case .output(let data) = result else {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: data)
    }

    // 直接在 WezTerm 的 socket 上发一个 SendPaste 请求：一帧是 leb128 的长度、序号、类型（13），后面是 pane 号和文字（都按
    // varbincode：整数 leb128、字符串是 leb128 长度加 UTF-8）。之后一帧一帧读，跳过它主动推送的屏幕更新（序号 0），
    // 读到自己这个序号的回应：类型 10 成功，0 出错
    private static func sendWezTermPaste(_ text: String, pane: Int, socket: String, pid: pid_t) -> SocketSendResult {
        guard let fd = connectUnixSocket(socket, expectedPeer: pid) else {
            return .notSent
        }
        defer { close(fd) }
        let serial: UInt64 = 1
        let body = Array(text.utf8)
        var data = leb128(UInt64(pane)) + leb128(UInt64(body.count)) + body
        let header = leb128(serial) + leb128(13)
        data = leb128(UInt64(header.count + data.count)) + header + data
        guard writeAll(fd, data, timeout: 1) else {
            return .notSent
        }
        let deadline = DispatchTime.now() + 1.5
        var reader = SocketReader(fd: fd, deadline: deadline)
        while true {
            // 长度的最高位标记这一帧压缩过（只有它推送的帧会压缩；内容反正跳过）
            guard let length = reader.leb128(), let frameSerial = reader.leb128(), let ident = reader.leb128() else {
                return .unsure
            }
            let payloadLength = Int(length & ~(UInt64(1) << 63)) - leb128(frameSerial).count - leb128(ident).count
            guard payloadLength >= 0, reader.skip(payloadLength) else {
                return .unsure
            }
            guard frameSerial == serial else {
                continue
            }
            return ident == 10 ? .sent : .notSent
        }
    }

    // MARK: kitty

    // 远程控制的 send-text：ESC P @kitty-cmd <JSON> ESC \，送给拿着焦点的窗口。文字用 base64（不用转义）；多行文字只在 shell 认得
    // bracketed paste 时才会送到这里，这时要求 kitty 一定包上标记（enable），免得它当时没开这个模式、换行被当成回车。
    // kitty 一条命令最多 64 KB，太长的不走这里
    private static func sendKittyText(_ text: String, bracketed: Bool, socket: String, pid: pid_t) -> SocketSendResult {
        let encoded = Data(text.utf8).base64EncodedString()
        // 版本写 0.32：更早的 kitty（还不认 bracketed_paste）会拒绝这条命令，而不是把多行文字原样送出去
        let command: [String: Any] = [
            "cmd": "send-text",
            "version": [0, 32, 0],
            "payload": [
                "data": "base64:" + encoded,
                "bracketed_paste": bracketed ? "enable" : "auto",
                "match": "state:focused",
            ] as [String: Any],
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: command), json.count < 60_000,
              let fd = connectUnixSocket(socket, expectedPeer: pid) else {
            return .notSent
        }
        defer { close(fd) }
        let frame = Array("\u{1b}P@kitty-cmd".utf8) + Array(json) + Array("\u{1b}\\".utf8)
        guard writeAll(fd, frame, timeout: 1) else {
            return .notSent
        }
        var reader = SocketReader(fd: fd, deadline: .now() + 1.5)
        let terminator = Array("\u{1b}\\".utf8)
        guard let reply = reader.until(terminator, limit: 64 * 1024) else {
            return .unsure
        }
        // 回应是 ESC P @kitty-cmd <JSON> ESC \：去掉结尾的 ESC \ 再解析
        let body = reply.dropLast(terminator.count)
        guard let start = body.firstIndex(of: UInt8(ascii: "{")),
              let response = try? JSONSerialization.jsonObject(with: Data(body[start...])) as? [String: Any] else {
            return .unsure
        }
        return response["ok"] as? Bool == true ? .sent : .notSent
    }

    // MARK: socket

    // 连上之后确认对面正是这个终端进程（socket 文件是谁都能在自己的目录里放的，只看文件属主不够）
    static func connectUnixSocket(_ path: String, expectedPeer pid: pid_t) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            return nil
        }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < capacity else {
            close(fd)
            return nil
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        var peer: pid_t = 0
        var peerLength = socklen_t(MemoryLayout<pid_t>.size)
        guard connected == 0, getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &peer, &peerLength) == 0, peer == pid else {
            close(fd)
            return nil
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        return fd
    }

    // 写完全部字节（非阻塞，缓冲区满了就等，最多等 timeout）
    static func writeAll(_ fd: Int32, _ bytes: [UInt8], timeout: TimeInterval) -> Bool {
        let deadline = DispatchTime.now() + timeout
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { raw in
                Darwin.write(fd, raw.baseAddress!.advanced(by: offset), bytes.count - offset)
            }
            if written > 0 {
                offset += written
                continue
            }
            guard written < 0, errno == EAGAIN || errno == EINTR else {
                return false
            }
            let now = DispatchTime.now().uptimeNanoseconds
            var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard deadline.uptimeNanoseconds > now,
                  poll(&descriptor, 1, Int32(max(1, (deadline.uptimeNanoseconds - now) / 1_000_000))) > 0 else {
                return false
            }
        }
        return true
    }

    private static func leb128(_ value: UInt64) -> [UInt8] {
        var value = value
        var bytes: [UInt8] = []
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 {
                byte |= 0x80
            }
            bytes.append(byte)
        } while value != 0
        return bytes
    }

    // 带截止时间的读取（非阻塞 socket）
    private struct SocketReader {
        let fd: Int32
        let deadline: DispatchTime
        private var buffer: [UInt8] = []

        init(fd: Int32, deadline: DispatchTime) {
            self.fd = fd
            self.deadline = deadline
        }

        // 再读进一些；到了截止时间、对方关闭、出错时返回 false
        private mutating func fill() -> Bool {
            while true {
                var chunk = [UInt8](repeating: 0, count: 4096)
                let count = chunk.withUnsafeMutableBytes { raw in
                    Darwin.read(fd, raw.baseAddress!, raw.count)
                }
                if count > 0 {
                    buffer += chunk.prefix(count)
                    return true
                }
                guard count < 0, errno == EAGAIN || errno == EINTR else {
                    return false
                }
                let now = DispatchTime.now().uptimeNanoseconds
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                guard deadline.uptimeNanoseconds > now,
                      poll(&descriptor, 1, Int32(max(1, (deadline.uptimeNanoseconds - now) / 1_000_000))) > 0 else {
                    return false
                }
            }
        }

        mutating func byte() -> UInt8? {
            if buffer.isEmpty, !fill() {
                return nil
            }
            return buffer.removeFirst()
        }

        mutating func leb128() -> UInt64? {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while shift < 64 {
                guard let byte = byte() else {
                    return nil
                }
                value |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 {
                    return value
                }
                shift += 7
            }
            return nil
        }

        mutating func skip(_ count: Int) -> Bool {
            var remaining = count
            while remaining > 0 {
                if buffer.isEmpty, !fill() {
                    return false
                }
                let taken = min(remaining, buffer.count)
                buffer.removeFirst(taken)
                remaining -= taken
            }
            return true
        }

        // 读到 terminator 为止（含），最多 limit 字节
        mutating func until(_ terminator: [UInt8], limit: Int) -> [UInt8]? {
            var result: [UInt8] = []
            while result.count < limit {
                guard let byte = byte() else {
                    return nil
                }
                result.append(byte)
                if result.count >= terminator.count, Array(result.suffix(terminator.count)) == terminator {
                    return result
                }
            }
            return nil
        }
    }
}

extension FocusedTarget {
    // 焦点在 WezTerm 上，它的复制模式或搜索框可能开着（这时它说拿着焦点的仍是下面的 pane）。它的窗口标题这时以 "Copy mode: " 开头
    // （前面可能有 [Z]、[1/2] 这样的标记）；读不到标题时按开着处理
    var wezTermOverlayMayBeOpen: Bool {
        bundleIdentifier == TerminalScript.wezterm.bundleIdentifier
            && (focusedWindowTitle.map { $0.range(of: #"^(\[[^\]]*\] )*Copy mode: "#, options: .regularExpression) != nil } ?? true)
    }
}

// MARK: - kitty 的远程控制设置

// kitty 默认关着远程控制。Copi 不改用户的 kitty.conf，只在 kitty 的配置目录里放一个检查脚本：不带密码的请求只接受本机 socket 上的
// send-text、只送给拿着焦点的窗口（不接受 kitty 窗口里的程序自己写出来的不带密码的命令——那样 ssh 到的远程主机也能往本地的
// 窗口里送文字；也不接受读取屏幕内容之类的命令），再告诉用户要往 kitty.conf 里加哪几行。
// 带着 kitty 不认识的密码的请求（kitty 窗口里的程序、本机的别的程序都可以这样发）这个脚本管不到：kitty 会弹窗问用户要不要允许。
// Copi 从不带密码
enum KittyRemoteControl {
    static let scriptName = "copi_rc_auth.py"

    private static let script = """
    # Written by Copi: for requests without a password, allows only sending text to the focused
    # kitty window through the remote-control socket. No reading, no other commands, and no
    # password-less requests from programs running inside kitty (including over ssh). Requests
    # that carry an unknown password are not checked here; kitty asks you about those.
    def is_cmd_allowed(pcmd, window, from_socket, extra_data):
        if not from_socket:
            return False
        if pcmd.get('cmd') != 'send-text':
            return False
        p = pcmd.get('payload') or {}
        if p.get('all') or p.get('match_tab') or p.get('session_id') or p.get('exclude_active'):
            return False
        return p.get('match') in (None, '', 'state:focused')

    """

    // kitty 的配置目录：环境变量指定的，或者 ~/.config/kitty（只有 ~/Library/Preferences/kitty 里有 kitty.conf 时用那里）
    private static var configDirectory: URL {
        let environment = ProcessInfo.processInfo.environment
        if let custom = environment["KITTY_CONFIG_DIRECTORY"], !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let xdg = environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".config")
        let standard = xdg.appendingPathComponent("kitty")
        let library = home.appendingPathComponent("Library/Preferences/kitty")
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: standard.appendingPathComponent("kitty.conf").path),
           fileManager.fileExists(atPath: library.appendingPathComponent("kitty.conf").path) {
            return library
        }
        return standard
    }

    // 放好检查脚本（已经有一个不一样的同名文件时不动它），返回给用户看的说明
    static func prepare() -> String {
        let directory = configDirectory
        let file = directory.appendingPathComponent(scriptName)
        let fileManager = FileManager.default
        if let existing = try? String(contentsOf: file, encoding: .utf8), existing != script {
            return "\(file.path) already exists and isn't Copi's. Rename it, then click Set Up again."
        }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try script.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            return "Copi couldn't write \(file.path): \(error.localizedDescription)"
        }
        return "Copi put \(scriptName) in \(directory.path). Add these lines to kitty.conf there and restart kitty:\n\nallow_remote_control password\nremote_control_password \"\" \(scriptName)\nlisten_on unix:kitty-copi\n\nWithout a password, apps on this Mac can then only send text to the focused kitty window, and nothing can read from kitty this way. Other apps you run can still send text to it. If kitty ever asks whether to allow remote control, say no unless you started it."
    }
}

// 一定会打开 bracketed paste 模式的程序（Ghostty 里粘贴给它们的单行文字是插入，不是按键；它们的终端窗口里运行着程序时除外）。
// Emacs 不在里面：`emacs -nw` 的 vterm、term 同样会把文字转给里面的程序，按别的程序拒绝
private let bracketedPastePrograms: Set<String> = ["vim", "nvim", "vi", "view", "vimdiff"]

private func fourCharCode(_ code: String) -> FourCharCode {
    code.utf8.reduce(0) { ($0 << 8) | FourCharCode($1) }
}
