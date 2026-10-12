//
//  ZeroExposure.swift
//  Copi
//
//  0 暴露复制/粘贴：文字只在 Copi 和目标 App 之间传递，不经过系统剪贴板（也不经过任何其他进程不需要授权就能读到的剪贴板）。
//
//  各类 App 能走的路径不一样（依据是对 WebKit / Chromium / Gecko 源码和 KeePassXC、Espanso 等实现的调研）：
//   - 原生文本控件：直接读写 kAXSelectedText（SystemUtilities.swift 里已有）；
//   - Safari / WKWebView：粘贴用 WebKit 公开的 AXTextOperation（Grammarly 也是这么做的，Safari 18.2 起支持，
//     走真正的编辑命令，能撤销）；复制用 text marker 读选区；
//   - Chrome 系浏览器和 Electron：可编辑的 <input>/<textarea> 粘贴时整体改写 AXValue；复制用 text marker 并按段落重建换行；
//   - 密码框、单行输入框（以及以上都不行的原生输入框）、富文本编辑器：模拟键入（和密码管理器的自动填充一样），
//     换行用 ⇧↩（聊天框里单独的 ↩ 是发送）；当前是拼音等输入法时不键入；
//   - 认不出焦点控件、但焦点所在的 App 正开着 Secure Input（几乎一定是密码框）：同样模拟键入；
//   - 终端：只键入单行文字，并且避开 vim、less 这类把按键当命令的全屏程序（真正的粘贴有 bracketed paste 保护，键入没有）；
//   - VS Code 系编辑器、JetBrains、网页里的代码编辑器：它们逐字处理键入（自动补全括号引号、确认补全候选），
//     只键入不会触发这些的单行文字（API key、token 之类大多如此）；Google Docs 自动改大小写、引号，不键入。
//  找不到 0 暴露路径时，由调用方决定：默认拒绝并通知（Copi 的文字绝不放上系统剪贴板）；用户打开"允许剪贴板回退"后
//  退回加固过的剪贴板方式。用户放行的 App 照常使用系统剪贴板（见 ZeroExposurePolicy）。
//
//  能看到这些文字的，只有目标 App 本身和已经拿到辅助功能/输入监控/录屏权限的程序——后者本来就能直接读输入框、记录按键，
//  不在 Copi 的防护范围内。
//

import Foundation
import AppKit
import Carbon
import ApplicationServices
import IOKit
import Defaults
import KeyboardShortcuts
import UserNotifications

// MARK: - 策略

enum ZeroExposurePolicy {
    // 0 暴露（默认）：Copi 的文字绝不放上系统剪贴板，做不到就拒绝并通知。任意线程可用
    static var isStrict: Bool {
        !Defaults[.allowClipboardFallback]
    }

    // 用户放行、照常使用系统剪贴板的 App
    static func usesNormalClipboard(_ bundleID: String?) -> Bool {
        guard let bundleID, !bundleID.isEmpty else {
            return false
        }
        return Defaults[.normalClipboardApps].contains(bundleID)
    }

    // 密码管理器（和钥匙串访问这类保管密码的 App）：在它们里面复制的内容一律按机密处理（不显示、90 秒后清除）
    private static let passwordManagerBundleIDPrefixes = [
        "com.1password.", "com.agilebits.", "com.bitwarden.", "in.sinew.Enpass", "org.keepassxc.", "com.apple.Passwords",
        "com.dashlane.", "me.proton.pass", "com.lastpass.", "com.callpod.keeper", "com.nordpass.", "com.roboform.",
        "com.apple.keychainaccess", "com.markmcguill.strongbox", "com.hicknhacksoftware.MacPass", "com.outercorner.Secrets",
        "net.antelle.keeweb",
    ]

    static func isPasswordManager(_ bundleID: String?) -> Bool {
        guard let bundleID else {
            return false
        }
        return passwordManagerBundleIDPrefixes.contains { bundleID.hasPrefix($0) }
    }

    static func allowNormalClipboard(for bundleID: String) {
        var apps = Defaults[.normalClipboardApps]
        guard !bundleID.isEmpty, !apps.contains(bundleID) else {
            return
        }
        apps.append(bundleID)
        Defaults[.normalClipboardApps] = apps
    }
}

// MARK: - Secure Input 的归属

// 当前是哪个进程开着 Secure Event Input（浏览器、原生 App 在密码框获得焦点时开启，终端的"安全键盘输入"也会）。
// 系统把它记在 IORegistry 根节点的 IOConsoleUsers 里，不需要任何权限就能读。任意线程可用。
// 这个记录并不总是准的：后台进程、命令行工具开启时记的是当时的前台 App，开启者退出后也可能残留（锁屏时 loginwindow 还会泄漏）。
// 所以只把它当作旁证，用的时候还要有别的证据（见 revealPasswordField）。
enum SecureInputOwner {
    static var pid: pid_t? {
        guard IsSecureEventInputEnabled() else {
            return nil
        }
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != 0 else {
            return nil
        }
        defer { IOObjectRelease(root) }
        guard let property = IORegistryEntryCreateCFProperty(root, "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0),
              let sessions = property.takeRetainedValue() as? [[String: Any]] else {
            return nil
        }
        // 自己这个登录会话（快速切换用户时会有多个）；没有就用正在使用屏幕的那个
        let uid = getuid()
        let session = sessions.first { ($0["kCGSSessionUserIDKey"] as? NSNumber)?.uint32Value == uid }
            ?? sessions.first { ($0["kCGSSessionOnConsoleKey"] as? NSNumber)?.boolValue == true }
        // 没开启时这个 key 根本不存在
        guard let number = session?["kCGSSessionSecureInputPID"] as? NSNumber, number.int32Value > 0 else {
            return nil
        }
        return number.int32Value
    }
}

private let chromiumCacheLock = NSLock()
private var chromiumCache: [pid_t: Bool] = [:]

// Chrome 系浏览器和 Electron App：包里有 "<名字> Framework.framework"（Google Chrome Framework、Electron Framework……）。
// 它们的无障碍树按需构建，没建好时焦点只是整个窗口或网页，认不出密码框
func isChromiumApp(pid: pid_t) -> Bool {
    chromiumCacheLock.lock()
    let cached = chromiumCache[pid]
    chromiumCacheLock.unlock()
    if let cached {
        return cached
    }
    var isChromium = false
    if let frameworks = NSRunningApplication(processIdentifier: pid)?.bundleURL?.appendingPathComponent("Contents/Frameworks"),
       let names = try? FileManager.default.contentsOfDirectory(atPath: frameworks.path) {
        isChromium = names.contains { $0.hasSuffix(" Framework.framework") }
    }
    chromiumCacheLock.lock()
    chromiumCache[pid] = isChromium
    chromiumCacheLock.unlock()
    return isChromium
}

// 进程号会被复用：App 退出后把按进程号缓存的判断清掉
func forgetAppEngineCache(pid: pid_t) {
    chromiumCacheLock.lock()
    chromiumCache[pid] = nil
    chromiumCacheLock.unlock()
    typingChunkCacheLock.lock()
    typingChunkCache[pid] = nil
    typingChunkCacheLock.unlock()
    javaAppCacheLock.lock()
    javaAppCache[pid] = nil
    javaAppCacheLock.unlock()
    editorDataFolderCacheLock.lock()
    editorDataFolderCache[pid] = nil
    editorDataFolderCacheLock.unlock()
    geckoCacheLock.lock()
    geckoCache[pid] = nil
    geckoCacheLock.unlock()
}

// MARK: - 识别目标

enum WebEngine {
    case webKit
    case chromium
    case gecko
}

// 只有网页元素才有的属性（WebKit 和 Chromium 给每个网页元素都加了这些）
let webOnlyAttributeNames: Set<String> = ["AXDOMIdentifier", "AXDOMClassList", "ChromeAXNodeId"]

private let geckoBundleIDPrefixes = [
    "org.mozilla.", "net.waterfox.", "io.gitlab.librewolf", "app.zen-browser.", "org.torproject.", "net.mullvad.",
]
private let geckoCacheLock = NSLock()
private var geckoCache: [pid_t: Bool] = [:]

// Firefox 及其各种分支（Floorp、LibreWolf、Zen、Thunderbird……）：包里都有 Gecko 的 XUL 库
func isGeckoApp(pid: pid_t, bundleIdentifier: String?) -> Bool {
    if let bundleIdentifier, geckoBundleIDPrefixes.contains(where: { bundleIdentifier.hasPrefix($0) }) {
        return true
    }
    geckoCacheLock.lock()
    let cached = geckoCache[pid]
    geckoCacheLock.unlock()
    if let cached {
        return cached
    }
    let isGecko = NSRunningApplication(processIdentifier: pid)?.bundleURL
        .map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("Contents/MacOS/XUL").path) } ?? false
    geckoCacheLock.lock()
    geckoCache[pid] = isGecko
    geckoCacheLock.unlock()
    return isGecko
}

// 虚拟机、远程桌面：键盘输入会被转成客户机的扫描码，模拟键入的字符对不上；粘贴只能经过它们的剪贴板同步
private let remoteDesktopBundleIDPrefixes = [
    "com.parallels.", "com.vmware.fusion", "com.vmware.horizon", "com.omnissa.", "com.utmapp.", "org.virtualbox.",
    "com.microsoft.rdc", "com.apple.ScreenSharing", "com.citrix.", "com.realvnc.", "com.teamviewer.", "com.philandro.anydesk",
    "com.p5sys.jump", "com.apple.iphonesimulator", "com.apple.ScreenContinuity", "tv.parsec.www", "com.carriez.rustdesk",
    "com.moonlight-stream.", "codes.rambo.VirtualBuddy", "com.amazon.workspaces", "com.lemonmojo.RoyalTSX", "com.edovia.screens",
]

// 被远程控制的这台 Mac 上跑的服务端（菜单栏里的代理）
private let remoteHostAgentBundleIDPrefixes = ["com.realvnc.", "com.teamviewer.", "com.philandro.anydesk", "com.carriez.rustdesk", "com.p5sys.jump"]

// 虚拟机、远程桌面、模拟器
func isRemoteDesktopApp(_ bundleID: String?) -> Bool {
    guard let bundleID else {
        return false
    }
    return remoteDesktopBundleIDPrefixes.contains { bundleID.hasPrefix($0) }
}

// 正在运行、会把本机剪贴板同步出去（客户机、远程电脑、模拟器）的 App 的名字（包括粘贴目标自己）
func runningClipboardSyncers() -> [String] {
    var names: [String] = []
    for app in NSWorkspace.shared.runningApplications {
        // 用户开着的 App（虚拟机、远程桌面的窗口）都算；只在后台跑的代理里，被远程控制的这台 Mac 上的服务端（VNC、TeamViewer、
        // AnyDesk、RustDesk、Jump Desktop Connect）在有人连进来时会同步剪贴板，也算；Citrix 的帮手、Parallels Toolbox 这类不算
        guard let bundleID = app.bundleIdentifier, remoteDesktopBundleIDPrefixes.contains(where: { bundleID.hasPrefix($0) }),
              app.activationPolicy == .regular || remoteHostAgentBundleIDPrefixes.contains(where: { bundleID.hasPrefix($0) }) else {
            continue
        }
        let name = app.localizedName ?? bundleID
        if !names.contains(name) {
            names.append(name)
        }
    }
    return names
}

// 主线程：退回剪贴板方式之前（每个退回的地方都要）调用，这是唯一的一道检查。有会把本机剪贴板同步出去的 App 在运行时（粘贴目标
// 本身就是虚拟机、远程桌面也算），第一次只提醒（文字会被它们带到那台电脑的剪贴板、剪贴板历史里，粘贴完也一直留着），
// 8 秒内用户亲手再粘贴一次才退回剪贴板。keyTime：这一次按键按下的时刻（见 PasteConfirmation）
func remoteClipboardConfirmationBeforeFallback(_ text: String, targetPID: pid_t?, keyTime: Date) -> UnavailableReason? {
    let syncers = runningClipboardSyncers()
    // 会把本机剪贴板同步出去的 App 和提醒时不一样了（例如确认之后才打开的虚拟机、iPhone 镜像）：用户确认时不知道有它，要重新问
    //（同 CopyThroughAppConsent）。排好序：不能因为列出来的先后不同就每次都重新问，那样用户确认了也粘贴不了
    let key = "\(targetPID ?? -1)\u{0}\(syncers.sorted().joined(separator: "\u{0}"))\u{0}\(text)"
    guard !syncers.isEmpty, RemoteClipboardGuard.confirmation.needsConfirmation(key: key, keyTime: keyTime) else {
        return nil
    }
    return .remoteClipboard(syncers)
}

// ⇧↩ 在这些 App 里不是换行：电子表格是确认单元格并跳到别的格（后面的文字会覆盖别的格），Xcode playground、Mathematica 会执行代码
private let multiLineTypingDenyBundleIDPrefixes = [
    "com.microsoft.Excel", "com.apple.iWork.Numbers", "com.apple.dt.Xcode", "com.wolfram.Mathematica", "org.libreoffice",
]

private let typingChunkCacheLock = NSLock()
private var typingChunkCache: [pid_t: Int] = [:]

// App 包里带着的 Java：java 是 Java 运行时或 Java 程序（jpackage 的 runtime、appbundler 的 Java、PlugIns 里的 JDK/JRE），
// jetBrainsRuntime 是 JetBrains 自己的运行时（jbr）
private func bundledJava(contents: URL) -> (java: Bool, jetBrainsRuntime: Bool) {
    let fileManager = FileManager.default
    func exists(_ path: String) -> Bool {
        fileManager.fileExists(atPath: contents.appendingPathComponent(path).path)
    }
    let plugIns = (try? fileManager.contentsOfDirectory(atPath: contents.appendingPathComponent("PlugIns").path)) ?? []
    let java = exists("runtime") || exists("Java") || plugIns.contains { $0.lowercased().contains("jdk") || $0.lowercased().contains("jre") }
    return (java, exists("jbr"))
}

// 每个按键事件最多能带几个 UTF-16 单元：标准 OpenJDK 的 Swing 程序只取第一个字符（JetBrains 自带的运行时没有这个问题），
// 内嵌 QtWebEngine 的程序最多留 3 个。其余（Cocoa、Chromium、WebKit、终端）整串都收
private func typingChunkLimit(pid: pid_t) -> Int {
    typingChunkCacheLock.lock()
    let cached = typingChunkCache[pid]
    typingChunkCacheLock.unlock()
    if let cached {
        return cached
    }
    var limit = KeystrokeTyper.chunkLimit
    if let contents = NSRunningApplication(processIdentifier: pid)?.bundleURL?.appendingPathComponent("Contents") {
        let bundled = bundledJava(contents: contents)
        if bundled.java, !bundled.jetBrainsRuntime {
            limit = 1
        } else if FileManager.default.fileExists(atPath: contents.appendingPathComponent("Frameworks/QtWebEngineCore.framework").path) {
            limit = 1
        }
    }
    typingChunkCacheLock.lock()
    typingChunkCache[pid] = limit
    typingChunkCacheLock.unlock()
    return limit
}

private let javaAppCacheLock = NSLock()
private var javaAppCache: [pid_t: Bool] = [:]

// 界面是 Java（Swing、AWT）写的 App：包里带着 Java（包括 JetBrains 的运行时），或者进程本身就是 java 命令
// （java -jar 启动、没有自己的 App 包）
private func isJavaApp(pid: pid_t) -> Bool {
    javaAppCacheLock.lock()
    let cached = javaAppCache[pid]
    javaAppCacheLock.unlock()
    if let cached {
        return cached
    }
    var isJava = false
    if let app = NSRunningApplication(processIdentifier: pid) {
        if let contents = app.bundleURL?.appendingPathComponent("Contents") {
            let bundled = bundledJava(contents: contents)
            isJava = bundled.java || bundled.jetBrainsRuntime
        }
        if app.executableURL?.lastPathComponent == "java" {
            isJava = true
        }
    }
    javaAppCacheLock.lock()
    javaAppCache[pid] = isJava
    javaAppCacheLock.unlock()
    return isJava
}

let fileManagerBundleIDs: Set<String> = ["com.apple.finder", "com.binarynights.ForkLift", "com.cocoatech.PathFinder", "com.marta.Marta"]

// JetBrains 系 IDE：编辑器在 Java 事件线程上异步应用 Accessibility 写入，没法确认；逐字处理键入（自动补全括号引号），
// 只能键入不会触发自动补全的单行文字（见 isSafeForCodeEditor）
private let javaIDEBundleIDPrefixes = ["com.jetbrains.", "com.google.android.studio"]

private let intelliJAppCacheLock = NSLock()
private var intelliJAppCache: [pid_t: Bool] = [:]

// 基于 IntelliJ 平台的 IDE：JetBrains、Android Studio，以及别家用同一平台做的（华为 DevEco Studio 之类，bundle ID 不同）。
// 后者认法：包里带着 JetBrains 的运行时（Contents/jbr），Resources/product-info.json 里写着自己的配置目录名（dataDirectoryName）
func isIntelliJPlatformApp(pid: pid_t, bundleID: String?) -> Bool {
    if let bundleID, javaIDEBundleIDPrefixes.contains(where: { bundleID.hasPrefix($0) }) {
        return true
    }
    intelliJAppCacheLock.lock()
    let cached = intelliJAppCache[pid]
    intelliJAppCacheLock.unlock()
    if let cached {
        return cached
    }
    var result = false
    if let contents = NSRunningApplication(processIdentifier: pid)?.bundleURL?.appendingPathComponent("Contents"),
       FileManager.default.fileExists(atPath: contents.appendingPathComponent("jbr").path),
       let data = try? Data(contentsOf: contents.appendingPathComponent("Resources/product-info.json")),
       let info = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
       let directory = info["dataDirectoryName"] as? String, !directory.isEmpty {
        result = true
    }
    intelliJAppCacheLock.lock()
    intelliJAppCache[pid] = result
    intelliJAppCacheLock.unlock()
    return result
}

// VS Code 系编辑器（Electron）：编辑器本身是 Monaco（靠 AXDOMClassList 认出来，按代码编辑器处理），搜索框、命令面板这些普通输入框
// 照常走 Chromium 的路径。无障碍树还没建好、认不出是什么的时候不要乱写（编辑器的输入框是个代理节点，写进去没用）
private let electronCodeEditorBundleIDPrefixes = [
    "com.microsoft.VSCode", "com.vscodium", "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf",
]

// 网页里的代码编辑器：只渲染可见部分（读出来的选区会被截断），输入走隐藏的代理输入框（写进去没用，键入又会触发自动补全括号、缩进）
private let codeEditorClassNames: Set<String> = [
    "cm-content", "cm-editor", "CodeMirror", "monaco-editor", "native-edit-context", "inputarea", "ime-text-area",
    "ace_editor", "ace_text-input",
]

// 网页里的终端（VS Code 的集成终端、浏览器里的云端 Shell……）：看不到里面正在运行什么程序，不键入
private let webTerminalClassNames: Set<String> = ["xterm", "xterm-helper-textarea", "xterm-screen"]

// 开着 Vim 模式的 CodeMirror（Obsidian、LeetCode……）：普通模式下键入的字母是命令
private let vimModeClassNames: Set<String> = ["cm-vimMode", "cm-fat-cursor"]

// Google Docs：同样只渲染可见部分、输入走代理节点，而且默认开着自动大写、智能引号、自动替换——键入会改掉内容
private let wordProcessorClassNames: Set<String> = [
    "kix-appview-editor", "docs-texteventtarget-iframe", "kix-canvas-tile-content",
]

// Google Sheets 的单元格编辑框：可以键入，但单元格里换行要按 ⌘↩（↩、⇧↩ 会确认单元格并跳到别的格）
private let spreadsheetClassNames: Set<String> = ["cell-input"]

// Google Docs、Sheets、Slides 也按网址认（Firefox 不提供 AXDOMClassList）。只认编辑页（docs.google.com/<种类>/[u/N/]d/<id>/…）：
// 表单、发布出来的网页（/pub）、简化版（/mobilebasic）、只读的 htmlview 都是普通网页，照常复制粘贴
func isGoogleEditorPage(_ url: URL?) -> Bool {
    guard let url, url.host?.lowercased() == "docs.google.com" else {
        return false
    }
    let path = url.path
    guard path.range(of: #"^/(document|spreadsheets|presentation|drawings)/(u/\d+/)?d/[^/]+"#, options: .regularExpression) != nil else {
        return false
    }
    return path.range(of: #"/(pub|pubhtml|mobilebasic|htmlview|export)(/|$)"#, options: .regularExpression) == nil
}

// ⇧↩ 确定是换行（而不是发送、确认单元格、运行代码）的地方：只有这些 App、网页的富文本编辑器才用 ⇧↩ 键入多行文字。
// 普通的 <textarea> 里 ⇧↩ 也是换行（浏览器的默认行为）
private let softNewlineBundleIDPrefixes = [
    "com.tinyspeck.slackmacgap", "com.hnc.Discord", "com.microsoft.teams", "notion.id", "com.anthropic.claudefordesktop",
    "com.openai.chat", "org.whispersystems.signal-desktop", "com.linear", "im.riot.app", "Mattermost.Desktop", "com.facebook.archon",
    "com.tdesktop.Telegram",
]
private let softNewlineHosts: Set<String> = [
    "mail.google.com", "app.slack.com", "discord.com", "teams.microsoft.com", "teams.live.com", "www.notion.so", "notion.so",
    "claude.ai", "chatgpt.com", "chat.openai.com", "gemini.google.com", "web.whatsapp.com", "web.telegram.org",
    "outlook.office.com", "outlook.office365.com", "outlook.live.com", "teams.cloud.microsoft", "outlook.cloud.microsoft", "www.messenger.com", "app.element.io", "linear.app",
    "github.com", "gitlab.com",
]

// Firefox 里认不出代码编辑器（没有 AXDOMClassList），只对没有代码编辑器的纯聊天、邮件网站按富文本处理
private let geckoRichTextHosts: Set<String> = [
    "mail.google.com", "app.slack.com", "discord.com", "teams.microsoft.com", "teams.live.com", "web.whatsapp.com",
    "web.telegram.org", "outlook.office.com", "outlook.office365.com", "outlook.live.com", "teams.cloud.microsoft", "outlook.cloud.microsoft", "www.messenger.com", "app.element.io",
]

// JetBrains 终端工具窗口的名字（各种界面语言）
private let ideTerminalLabels = ["terminal", "终端", "終端", "ターミナル", "터미널", "терминал"]

private enum IDEFocusPlace {
    case editor
    case terminal
    // 中途读不到（超时、层级太深）
    case unknown
}

enum WebEditorKind {
    case code
    // 开着 Vim 模式的代码编辑器
    case vimCode
    case terminal
    case wordProcessor
    // Google Sheets 的单元格编辑框
    case spreadsheet
    // 认不出来：Firefox 不提供 AXDOMClassList，或者往上找的过程中途读不到了。可能是代码编辑器、电子表格，按最保守的方式处理
    case unknown
}

// 终端里正在运行的程序：只在 shell 提示符（或者 sudo 这类在等密码的程序）前键入。vim 普通模式、less、htop 会把按键当命令，
// tmux、ssh 里面运行着什么看不到——真正的粘贴有 bracketed paste 保护，模拟键入没有
let terminalPromptPrograms: Set<String> = [
    "zsh", "bash", "fish", "sh", "dash", "ksh", "tcsh", "csh", "nu", "pwsh", "xonsh", "elvish",
    "sudo", "su", "doas", "login", "passwd",
]
// 这两个终端的窗口标题总是显示当前标签页前台正在运行的程序
let jobTitleTerminalBundleIDs: Set<String> = ["com.apple.Terminal", "com.googlecode.iterm2"]

// 终端前台进程组里的一个进程
struct ForegroundProcess {
    let pid: pid_t
    let name: String
    // 它的控制终端（dev_t）
    let tty: Int32
}

// 提示符前的程序里真正的 shell（不算在等密码的 sudo 这类）
let terminalPasswordPrograms: Set<String> = ["sudo", "su", "doas", "login", "passwd"]

// 前台进程组里的这个进程停在提示符前：交互式的 shell；或者 sudo 这类程序、并且终端正处在读密码的状态（关了回显、开着 canonical 模式）。
// sudo 这类程序认证之后会运行别的命令：新版 sudo 默认（use_pty）把命令放在另一个伪终端上，这个终端的前台组里只剩 sudo，
// 它把终端设成 raw 模式转发按键——这时键入的文字会到达 sudo 运行的程序（例如 `sudo vim` 的普通模式，字母就是命令）
func isAtPrompt(_ process: ForegroundProcess) -> Bool {
    guard terminalPromptPrograms.contains(process.name) else {
        return false
    }
    if terminalPasswordPrograms.contains(process.name) {
        return passwordIsBeingRead(tty: process.tty)
    }
    return shellIsInteractive(process)
}

// 各个 shell 启动参数的写法。commandFlags、commandOptions：让 shell 运行参数里给的命令（-c），或者从标准输入读命令（-s：
// `curl … | bash -s` 里 curl 结束之后前台只剩 bash；不带 -s 的 `curl … | bash`、`bash < install.sh` 由 shellIsInteractive
// 看标准输入是不是终端来判断）；fish 的长选项认缩写。valueFlags、valueOptions：后面跟着一个值（不是脚本）
private struct ShellArgumentSyntax {
    var commandFlags: Set<Character> = ["c", "s"]
    var commandOptions: [String] = []
    var valueFlags: Set<Character> = []
    var valueOptions: Set<String> = []
}

private let shellArgumentSyntaxes: [String: ShellArgumentSyntax] = [
    "bash": ShellArgumentSyntax(valueFlags: ["o", "O"], valueOptions: ["--rcfile", "--init-file"]),
    "zsh": ShellArgumentSyntax(valueFlags: ["o"]),
    "sh": ShellArgumentSyntax(valueFlags: ["o"]),
    "dash": ShellArgumentSyntax(valueFlags: ["o"]),
    "ksh": ShellArgumentSyntax(valueFlags: ["o"]),
    // -t：读一行、执行完就退出
    "tcsh": ShellArgumentSyntax(commandFlags: ["c", "s", "t"]),
    "csh": ShellArgumentSyntax(commandFlags: ["c", "s", "t"]),
    "fish": ShellArgumentSyntax(commandFlags: ["c"], commandOptions: ["--command"], valueFlags: ["C", "d", "D", "f", "o", "p"],
                                valueOptions: ["--init-command", "--debug", "--debug-stack-frames", "--features", "--debug-output",
                                               "--profile", "--profile-startup"]),
]

// 从启动参数和标准输入看 shell 是不是交互式的（在提示符前读用户输入）。运行脚本文件（bash script.sh、开头是 #!/bin/bash 的脚本）、
// -c 给的命令的 shell 不是：脚本只用内建命令（read 之类）时前台组里只有它自己，看起来和停在提示符前一样，键入的文字会落到
// 脚本接下来读的地方。登录 shell（argv[0] 以 "-" 开头）、-i、-l、不带参数的都是；脚本、-c 和 -i 一起出现时按不是处理。
// 参数看起来是交互式的，标准输入（fd 0）也得是它的控制终端：`curl … | bash`、`bash < install.sh` 的参数和提示符前的 shell
// 一样，命令却从管道、文件读，curl 结束之后前台只剩 bash，键入的文字会落到脚本从终端读的地方（read … < /dev/tty）。
// 读不到参数（别的用户的进程，例如 su 打开的 root shell）或标准输入、标准输入是管道或普通文件时按不是处理；
// 没列出写法的 shell（nu、pwsh……）这两样都不看
private func shellIsInteractive(_ process: ForegroundProcess) -> Bool {
    guard let syntax = shellArgumentSyntaxes[process.name] else {
        return true
    }
    guard let arguments = processArguments(pid: process.pid), !arguments.isEmpty, standardInputIsTerminal(process) else {
        return false
    }
    var index = 1
    while index < arguments.count {
        let argument = arguments[index]
        index += 1
        // "--" 或单独的 "-"：选项到此为止，后面还有参数就是脚本
        if argument == "--" || argument == "-" {
            return index >= arguments.count
        }
        // 第一个不是选项的参数：脚本文件
        guard argument.count > 1, argument.hasPrefix("-") || argument.hasPrefix("+") else {
            return false
        }
        // 长选项（zsh 用 "+-" 关掉）
        if argument.hasPrefix("--") || argument.hasPrefix("+-") {
            let name = "--" + String(argument.dropFirst(2).prefix { $0 != "=" })
            if syntax.commandOptions.contains(where: { $0.hasPrefix(name) }) {
                return false
            }
            if syntax.valueOptions.contains(name), !argument.contains("=") {
                index += 1
            }
            continue
        }
        // 几个单字母选项写在一起（-il、-eo pipefail）。带值的选项在最后时值是下一个参数，不在最后时值紧跟在它后面（zsh、fish：-ovi）
        let flags = argument.dropFirst()
        if flags.contains(where: { syntax.commandFlags.contains($0) }) {
            return false
        }
        if let last = flags.last, syntax.valueFlags.contains(last) {
            index += 1
        }
    }
    return true
}

// 进程的标准输入（fd 0）是它的控制终端。读不到（别的用户的进程）、是管道或 socket（不是 vnode，读不到）、普通文件时为 false
private func standardInputIsTerminal(_ process: ForegroundProcess) -> Bool {
    var info = vnode_fdinfowithpath()
    let size = Int32(MemoryLayout<vnode_fdinfowithpath>.stride)
    guard proc_pidfdinfo(process.pid, 0, PROC_PIDFDVNODEPATHINFO, &info, size) == size else {
        return false
    }
    let status = info.pvip.vip_vi.vi_stat
    return (status.vst_mode & S_IFMT) == S_IFCHR && Int32(bitPattern: status.vst_rdev) == process.tty
}

// 读密码（readpassphrase、getpass）时终端关掉回显、保留 canonical 模式（整行读）。sudoers 设了 pwfeedback（输入时显示星号）时
// sudo 关掉 canonical 模式一个个字符读，但保留输出处理（OPOST）；转发按键给 use_pty 里的命令时设成 raw 模式，连 OPOST 也关掉
private func passwordIsBeingRead(tty: Int32) -> Bool {
    guard let path = terminalDevicePath(tty) else {
        return false
    }
    let fd = open(path, O_RDONLY | O_NOCTTY | O_NONBLOCK)
    guard fd >= 0 else {
        return false
    }
    defer { close(fd) }
    var modes = termios()
    guard tcgetattr(fd, &modes) == 0, modes.c_lflag & tcflag_t(ECHO) == 0 else {
        return false
    }
    return modes.c_lflag & tcflag_t(ICANON) != 0 || modes.c_oflag & tcflag_t(OPOST) != 0
}

// 前台进程组里不在提示符前的程序的名字（通知里用）：组里还有别的程序时，sudo 这类只是把它启动起来的那个，说别的程序的名字
func programName(in group: [ForegroundProcess]) -> String? {
    group.first { !isAtPrompt($0) && !terminalPasswordPrograms.contains($0.name) }?.name ?? group.first { !isAtPrompt($0) }?.name
}

private enum TerminalForeground {
    // 停在提示符前；shells：相关标签页里的 shell 进程（多行粘贴要看它们支不支持 bracketed paste、行编辑器是不是在读）。
    // 有标签页停在 sudo 的密码提示时为空。ttys：相关标签页的终端（单行放不放得下，见 canonicalLineRefusal）
    case prompt(shells: [ForegroundProcess], ttys: [Int32])
    // 别的程序（认不出时为 nil）
    case other(String?)
}

// 代码编辑器里能安全键入的字符：引号、括号会自动补全或包住选中内容，"." "(" ";" "," ":" 会确认自动补全的候选，
// "/**" 会补全成注释，"<" 会补全 HTML 标签，HTML 标签里键入 "=" 会自动补上引号（只允许末尾的 base64 填充 "=" / "=="）。
// 第一个字符还必须是字母或数字：有选中内容时第一个键入的字符如果是 "_" "*" 这类，Markdown 里会把选中内容包起来而不是替换掉
private let codeEditorSafeCharacters = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 -+/@~%#$^!?&_".unicodeScalars)

private func isSafeForCodeEditor(_ text: String) -> Bool {
    var body = text
    for _ in 0..<2 where body.hasSuffix("=") {
        body.removeLast()
    }
    guard let first = body.unicodeScalars.first, first.isASCII,
          first.properties.isAlphabetic || ("0"..."9").contains(first) else {
        return false
    }
    return body.unicodeScalars.allSatisfy { codeEditorSafeCharacters.contains($0) }
}

private let editorDataFolderCacheLock = NSLock()
private var editorDataFolderCache: [pid_t: String?] = [:]

// 基于 VS Code 的编辑器（VS Code、Cursor、Windsurf、VSCodium、Positron……）：包里的 product.json 写着它在用户目录下的数据文件夹
// （".vscode"、".cursor"……），插件装在那里的 extensions 目录。不是这类编辑器时为 nil
func vscodeDataFolderName(pid: pid_t) -> String? {
    editorDataFolderCacheLock.lock()
    if let cached = editorDataFolderCache[pid] {
        editorDataFolderCacheLock.unlock()
        return cached
    }
    editorDataFolderCacheLock.unlock()
    var name: String?
    if let url = NSRunningApplication(processIdentifier: pid)?.bundleURL?.appendingPathComponent("Contents/Resources/app/product.json"),
       let data = try? Data(contentsOf: url),
       let product = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
        name = product["dataFolderName"] as? String
    }
    editorDataFolderCacheLock.lock()
    editorDataFolderCache[pid] = .some(name)
    editorDataFolderCacheLock.unlock()
    return name
}

private let vimEmulationCacheLock = NSLock()
private var vimEmulationCache: [String: (checkedAt: Date, installed: Bool)] = [:]

private let screenReaderSupportLock = NSLock()
private var screenReaderSupportCache: [pid_t: (checkedAt: Date, enabled: Bool)] = [:]

// JetBrains 系 IDE 开着"支持屏幕阅读器"：编辑器通过辅助功能给出的是折叠后看到的文字（折叠的代码换成 "..."），读出来的不是
// 真正的内容，按它删除会删掉没复制到的代码。看这个 IDE 自己的配置目录（App 包里 product-info.json 的 dataDirectoryName；
// 升级后旧版本的目录还留着，不能都算）；读不到时才看所有目录。按进程一分钟查一次
func jetBrainsScreenReaderSupportEnabled(pid: pid_t) -> Bool {
    screenReaderSupportLock.lock()
    if let cached = screenReaderSupportCache[pid], Date().timeIntervalSince(cached.checkedAt) < 60 {
        screenReaderSupportLock.unlock()
        return cached.enabled
    }
    screenReaderSupportLock.unlock()
    let fileManager = FileManager.default
    let support = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
    let app = NSRunningApplication(processIdentifier: pid)
    var folders: [URL] = []
    if let productInfo = app?.bundleURL?.appendingPathComponent("Contents/Resources/product-info.json"),
       let data = try? Data(contentsOf: productInfo),
       let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
       let dataDirectory = json["dataDirectoryName"] as? String, !dataDirectory.isEmpty {
        let vendor = app?.bundleIdentifier?.hasPrefix("com.jetbrains.") == true ? "JetBrains" : "Google"
        folders = [support.appendingPathComponent("\(vendor)/\(dataDirectory)")]
    } else {
        for vendor in ["JetBrains", "Google"] {
            let vendorFolder = support.appendingPathComponent(vendor)
            folders += ((try? fileManager.contentsOfDirectory(atPath: vendorFolder.path)) ?? []).map { vendorFolder.appendingPathComponent($0) }
        }
    }
    let enabled = folders.contains { folder in
        guard let contents = try? String(contentsOf: folder.appendingPathComponent("options/ide.general.xml"), encoding: .utf8) else {
            return false
        }
        return contents.range(of: #"name="supportScreenReaders"\s+value="true""#, options: .regularExpression) != nil
    }
    screenReaderSupportLock.lock()
    screenReaderSupportCache[pid] = (Date(), enabled)
    screenReaderSupportLock.unlock()
    return enabled
}

// 代码编辑器装了 Vim 模拟插件（VSCodeVim、VSCode Neovim、IdeaVim）：普通模式下键入的字母是命令。看不出当前是不是普通模式，
// 装了就不键入。插件目录一分钟查一次
private func hasVimEmulation(for target: FocusedTarget) -> Bool {
    guard let bundleID = target.bundleIdentifier else {
        return false
    }
    vimEmulationCacheLock.lock()
    if let cached = vimEmulationCache[bundleID], Date().timeIntervalSince(cached.checkedAt) < 60 {
        vimEmulationCacheLock.unlock()
        return cached.installed
    }
    vimEmulationCacheLock.unlock()
    let fileManager = FileManager.default
    let home = fileManager.homeDirectoryForCurrentUser
    func entries(_ path: String) -> [String] {
        (try? fileManager.contentsOfDirectory(atPath: home.appendingPathComponent(path).path)) ?? []
    }
    var installed = false
    if target.isJavaIDE {
        let vendor = bundleID.hasPrefix("com.jetbrains.") ? "Library/Application Support/JetBrains" : "Library/Application Support/Google"
        installed = entries(vendor).contains { product in
            entries("\(vendor)/\(product)/plugins").contains { $0.lowercased().hasPrefix("ideavim") }
        }
    } else if let dataFolder = vscodeDataFolderName(pid: target.pid) {
        installed = entries("\(dataFolder)/extensions").contains {
            $0.lowercased().hasPrefix("vscodevim.vim-") || $0.lowercased().hasPrefix("asvetliakov.vscode-neovim-")
        }
    }
    vimEmulationCacheLock.lock()
    vimEmulationCache[bundleID] = (Date(), installed)
    vimEmulationCacheLock.unlock()
    return installed
}

// 终端 App 里每个 tty 前台进程组里的全部程序名：同一组里的别的进程也算（`sudo vim` 里 vim 和 sudo 在同一组，
// 管道、脚本启动的 less 也是）。只看这个终端的子孙进程，iTerm2 还要看托管它会话的服务进程（不是它的子进程）。找不到时返回 nil
private func terminalForegroundGroups(pid terminalPID: pid_t, bundleID: String?) -> [[ForegroundProcess]]? {
    guard let processes = allProcesses() else {
        return nil
    }
    var childIndexes: [pid_t: [Int]] = [:]
    var membersByGroup: [pid_t: [Int]] = [:]
    for (index, process) in processes.enumerated() {
        childIndexes[process.kp_eproc.e_ppid, default: []].append(index)
        // 已经退出、只等父进程回收的僵尸进程不算前台在运行的程序
        if process.kp_proc.p_stat != CChar(SZOMB) {
            membersByGroup[process.kp_eproc.e_pgid, default: []].append(index)
        }
    }
    var roots = [terminalPID]
    if bundleID == "com.googlecode.iterm2" {
        let uid = getuid()
        roots += processes.filter { processName($0).hasPrefix("itermserver") && $0.kp_eproc.e_pcred.p_ruid == uid }.map { $0.kp_proc.p_pid }
    }
    // 每个有控制终端（e_tdev 不是 NODEV）的子孙进程：记下它的终端的前台进程组
    var foreground: [pid_t: Int32] = [:]
    var pending = roots
    var visited = Set<pid_t>()
    while let current = pending.popLast() {
        guard visited.insert(current).inserted else {
            continue
        }
        for index in childIndexes[current] ?? [] {
            let process = processes[index]
            if process.kp_eproc.e_tdev != -1, process.kp_eproc.e_tpgid > 0 {
                foreground[process.kp_eproc.e_tpgid] = process.kp_eproc.e_tdev
            }
            pending.append(process.kp_proc.p_pid)
        }
    }
    guard !foreground.isEmpty else {
        return nil
    }
    // 组里一个进程都找不到（刚退出）时是空数组，调用方按认不出处理
    return foreground.map { group, tty in
        (membersByGroup[group] ?? []).filter { processes[$0].kp_eproc.e_tdev == tty }
            .map { ForegroundProcess(pid: processes[$0].kp_proc.p_pid, name: processName(processes[$0]), tty: tty) }
    }
}

// 终端所有标签页的前台进程组（看不出焦点在哪个标签页时用：kitty、还没有 tty 属性的 Ghostty、终端里的 tmux）；
// 读不到、有的组认不出时为 nil
func terminalForegroundGroups(of target: FocusedTarget) -> [[ForegroundProcess]]? {
    guard let groups = terminalForegroundGroups(pid: target.pid, bundleID: target.bundleIdentifier), !groups.isEmpty,
          !groups.contains(where: { $0.isEmpty }) else {
        return nil
    }
    return groups
}

// iTerm2 里开着 tmux 整合（tmux -CC）：某个标签页的前台是控制模式的 tmux 客户端（见 TmuxPaste.isControlModeClient）。整合开出来的
// 标签页不是本机的终端，进程树里没有它们，从进程看不出焦点在不在其中一个上。读不到进程时为 false（调用方照常按认不出处理）
func iTermTmuxIntegrationIsRunning(pid: pid_t) -> Bool {
    let groups = terminalForegroundGroups(pid: pid, bundleID: TerminalScript.iTerm2.bundleIdentifier) ?? []
    return groups.contains { $0.contains(where: TmuxPaste.isControlModeClient) }
}

// 本机全部进程；读不到时为 nil
func allProcesses() -> [kinfo_proc]? {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
    var size = 0
    guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else {
        return nil
    }
    // 两次调用之间可能多出几个进程，多留些空间
    size += size / 8
    var processes = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
    guard sysctl(&mib, UInt32(mib.count), &processes, &size, nil, 0) == 0 else {
        return nil
    }
    return Array(processes.prefix(size / MemoryLayout<kinfo_proc>.stride))
}

// 文字怎么到达终端
enum TerminalDelivery {
    // 整段一次写进终端（编辑器扩展、终端自己的脚本接口）
    case singleWrite
    // 逐个按键键入：ESC 和后面的字符分几次到达 shell
    case keystrokes
}

// 一次写进终端的内容（编辑器扩展的 sendText、iTerm2 的 write text）。shells：前台进程组里的 shell；atPasswordPrompt：组里还有
// sudo 这类在等密码的程序；ttys：这个组所在的终端。
//  - shell 的行编辑器正在读、认得 bracketed paste：和真正的粘贴一样包上 ESC[200~ … ESC[201~（shell 整段插入编辑缓冲区、不执行）。
//    单行文字也包上：vi 模式的命令模式里，原样送进去的字母是命令；
//  - 否则（密码提示、脚本里的 read、还在启动的 shell、不认得这个标记的 shell）只原样送不含控制字符的单行文字（去掉末尾的换行——
//    真正的粘贴也不会因为它执行命令），并且 shell 不能开着 vi 模式、不能在等单个按键，终端按行收输入时这一行还要放得下
//    （见 canonicalLineRefusal）
func terminalPayload(for text: String, shells: [ForegroundProcess], atPasswordPrompt: Bool, ttys: [Int32]) -> Result<String, UnavailableReason> {
    var body = KeystrokeTyper.normalizedNewlines(text)
    while body.hasSuffix("\n") {
        body.removeLast()
    }
    guard !body.isEmpty else {
        return .failure(.noRoute)
    }
    let hasControls = body.unicodeScalars.contains { $0.properties.generalCategory == .control }
    // 密码提示：标记会成为密码的一部分
    if atPasswordPrompt || shells.isEmpty {
        guard !hasControls else {
            return .failure(.multiLine)
        }
        if let reason = canonicalLineRefusal(body, ttys: ttys, atPasswordPrompt: true) {
            return .failure(reason)
        }
        return .success(body)
    }
    if shells.allSatisfy({ shellAcceptsBracketedPaste(pid: $0.pid, delivery: .singleWrite) && lineEditorIsReading(tty: $0.tty) }) {
        guard let sanitized = sanitizedForBracketedPaste(body) else {
            return .failure(.noRoute)
        }
        return .success("\u{1b}[200~" + sanitized + "\u{1b}[201~")
    }
    guard !shells.contains(where: { waitsForSingleKey($0) }) else {
        return .failure(.singleKeyPrompt)
    }
    guard !hasControls else {
        return .failure(.multiLine)
    }
    if let reason = canonicalLineRefusal(body, ttys: ttys, atPasswordPrompt: false) {
        return .failure(reason)
    }
    guard !shells.contains(where: { shellMayUseViMode(pid: $0.pid) }) else {
        return .failure(.viMode)
    }
    return .success(body)
}

// 终端设备的路径（"/dev/ttys003"）
func terminalDevicePath(_ tty: Int32) -> String? {
    guard tty != -1, let name = devname(dev_t(tty), mode_t(S_IFCHR)) else {
        return nil
    }
    let device = String(cString: name)
    return device.isEmpty || device.hasPrefix("?") ? nil : "/dev/" + device
}

// shell 的行编辑器（zsh 的 ZLE、bash 的 readline、fish）正在读这个终端：它们读一行命令时都会关掉终端的 canonical 模式和回显，
// 并且改掉回车、换行的转换（ZLE 同时打开 ICRNL 和 INLCR，readline、fish 两个都关掉）。脚本里的 read、还在执行配置文件的 shell
// （例如 oh-my-zsh 启动时的更新提示）、sudo 的密码提示要么开着 canonical 模式或回显，要么（`read -s -n 1` 这类按任意键继续）
// 保留默认的只有 ICRNL——这时 shell 不认 bracketed paste，多行文字里的换行会被当成回车
func lineEditorIsReading(tty: Int32) -> Bool {
    guard let path = terminalDevicePath(tty) else {
        return false
    }
    let fd = open(path, O_RDONLY | O_NOCTTY | O_NONBLOCK)
    guard fd >= 0 else {
        return false
    }
    defer { close(fd) }
    var modes = termios()
    guard tcgetattr(fd, &modes) == 0, modes.c_lflag & tcflag_t(ICANON | ECHO) == 0 else {
        return false
    }
    return modes.c_iflag & tcflag_t(ICRNL | INLCR) != tcflag_t(ICRNL)
}

// 终端按行收输入（canonical 模式）时一行最多原样送进去多少字节。行编辑器读的时候关掉了 canonical 模式，不受影响；
// sudo 的密码提示、脚本里的 read、没有行编辑器的 sh 读的时候，输入先攒在终端驱动的行缓冲区里，按回车才交给程序。
// macOS 的行缓冲区只有 MAX_INPUT（1024）字节，放满之后再来的字符连同回车都被直接丢掉，程序和用户都不知道；分几次粘贴也一样，
// 它们攒在同一行里。行里已经有的字符看不到（FIONREAD 只数按过回车的行），所以只数要送的这一行，留出余量
let canonicalLineByteLimit = 1000

// 要原样送进这些终端（ttys）的一行文字放不下时，返回拒绝的原因。atPasswordPrompt：停在 sudo 这类的密码提示，不看终端设置一律
// 按这个上限（开着 pwfeedback 的 sudo 关掉 canonical 模式自己一个个字符读，读进的也是它自己有限的缓冲区）。
// 读不到终端设置、不知道是哪些终端时，按会截断处理。
// 要排在返回允许剪贴板回退的原因（canType 不通过、vi 模式等）之前查：退回剪贴板的真正粘贴一样会被截断
func canonicalLineRefusal(_ line: String, ttys: [Int32], atPasswordPrompt: Bool) -> UnavailableReason? {
    guard line.utf8.count > canonicalLineByteLimit,
          atPasswordPrompt || ttys.isEmpty || ttys.contains(where: { terminalReadsWholeLines(tty: $0) }) else {
        return nil
    }
    return .lineTooLong(canonicalLineByteLimit)
}

// 终端开着 canonical 模式（整行读）；读不到时也算
private func terminalReadsWholeLines(tty: Int32) -> Bool {
    guard let path = terminalDevicePath(tty) else {
        return true
    }
    let fd = open(path, O_RDONLY | O_NOCTTY | O_NONBLOCK)
    guard fd >= 0 else {
        return true
    }
    defer { close(fd) }
    var modes = termios()
    guard tcgetattr(fd, &modes) == 0 else {
        return true
    }
    return modes.c_lflag & tcflag_t(ICANON) != 0
}

// 终端上在等单个按键：zsh 的 read -q、read -k（oh-my-zsh 启动时问要不要更新就是这样），bash 的 read -n 1。它们关掉 canonical 模式
// 一个个字符读，读的却不是 shell 的行编辑器（见 lineEditorIsReading）：原样送进去的第一个字符就是回答，后面的字符落到之后运行的
// 东西里。读不到终端设置时也按在等处理。
// 只看 zsh、bash、sh（macOS 上的 sh 是 bash、zsh 或 dash）：只看终端设置分不出别的 shell 的行编辑器在读——elvish 的行编辑器在
// 提示符前关掉 canonical 模式和回显、只打开 ICRNL，和 zsh 的 read -q 一模一样，按在等单个按键处理会拒绝它提示符前的每一次粘贴
func waitsForSingleKey(_ shell: ForegroundProcess) -> Bool {
    readsSingleKey(shell) ?? true
}

// waitsForSingleKey 的判断；读不到终端设置时为 nil
private func readsSingleKey(_ shell: ForegroundProcess) -> Bool? {
    guard ["zsh", "bash", "sh"].contains(shell.name) else {
        return false
    }
    // 只读一次终端设置：分两次读的话，行编辑器正好在两次之间开始读时会被当成在等单个按键
    guard let path = terminalDevicePath(shell.tty) else {
        return nil
    }
    let fd = open(path, O_RDONLY | O_NOCTTY | O_NONBLOCK)
    guard fd >= 0 else {
        return nil
    }
    defer { close(fd) }
    var modes = termios()
    guard tcgetattr(fd, &modes) == 0 else {
        return nil
    }
    // 行编辑器在读（见 lineEditorIsReading）
    if modes.c_lflag & tcflag_t(ICANON | ECHO) == 0, modes.c_iflag & tcflag_t(ICRNL | INLCR) != tcflag_t(ICRNL) {
        return false
    }
    return modes.c_lflag & tcflag_t(ICANON) == 0
}

// 括号里的内容：换行用 \r（终端自己粘贴时也这样），Tab 保留；别的 C0 控制字符和 DEL 换成 Unicode 里对应的图形符号（ESC 变成 ␛），
// 免得提前结束粘贴或者被当成按键。含 C1 控制字符时返回 nil
func sanitizedForBracketedPaste(_ body: String) -> String? {
    var result = String.UnicodeScalarView()
    for scalar in body.unicodeScalars {
        switch scalar.value {
        case 0x0A:
            result.append("\r")
        case 0x09:
            result.append(scalar)
        case 0x00...0x1F:
            result.append(Unicode.Scalar(0x2400 + scalar.value)!)
        case 0x7F:
            result.append("\u{2421}")
        case 0x80...0x9F:
            return nil
        default:
            result.append(scalar)
        }
    }
    return String(result)
}

// 读 shell 的配置文件：任何一个里面出现任何一个关键字
private func configFilesMention(_ paths: [String], _ needles: [String]) -> Bool {
    paths.contains { path in
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            return false
        }
        return needles.contains { contents.contains($0) }
    }
}

// zsh 的配置文件。exec 时的 ZDOTDIR 往往不是用户真正的配置目录：XDG 风格的配置在 ~/.zshenv 里才设 ZDOTDIR；VS Code、Ghostty、kitty
// 的 shell integration 把 ZDOTDIR 换成自己的目录，原来的放在 USER_ZDOTDIR、GHOSTTY_ZSH_ZDOTDIR、KITTY_ORIG_ZDOTDIR 里。
// 这些目录都读（多读只会让判断更保守）；~/.zshenv 里的 ZDOTDIR 认不出指向哪里时返回 nil
private func zshConfigFiles(environment: [String: String]) -> [String]? {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    func expand(_ value: String) -> String? {
        var path = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        let xdg = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.config"
        for (pattern, replacement) in [("${XDG_CONFIG_HOME:-$HOME/.config}", xdg), ("${XDG_CONFIG_HOME}", xdg), ("$XDG_CONFIG_HOME", xdg),
                                       ("${HOME}", home), ("$HOME", home)] {
            path = path.replacingOccurrences(of: pattern, with: replacement)
        }
        if path.hasPrefix("~") {
            path = home + path.dropFirst()
        }
        return path.hasPrefix("/") && !path.contains("$") ? path : nil
    }
    var directories = [home]
    for key in ["ZDOTDIR", "USER_ZDOTDIR", "GHOSTTY_ZSH_ZDOTDIR", "KITTY_ORIG_ZDOTDIR"] {
        if let value = environment[key], !value.isEmpty, let path = expand(value) {
            directories.append(path)
        }
    }
    for file in [home + "/.zshenv", "/etc/zshenv"] {
        guard let contents = try? String(contentsOfFile: file, encoding: .utf8) else {
            continue
        }
        for line in contents.components(separatedBy: .newlines) {
            guard let range = line.range(of: #"ZDOTDIR=\S+"#, options: .regularExpression) else {
                continue
            }
            guard let path = expand(String(line[range].dropFirst("ZDOTDIR=".count))) else {
                return nil
            }
            directories.append(path)
        }
    }
    var seen = Set<String>()
    let unique = directories.filter { seen.insert($0).inserted }
    return unique.flatMap { directory in [".zshenv", ".zprofile", ".zshrc", ".zlogin"].map { directory + "/" + $0 } }
        + ["/etc/zshenv", "/etc/zprofile", "/etc/zshrc", "/etc/zlogin"]
}

// bash（readline）的配置文件
private func bashConfigFiles(environment: [String: String]) -> [String] {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    var files = [home + "/.inputrc", "/etc/inputrc", home + "/.bashrc", home + "/.bash_profile", home + "/.bash_login", home + "/.profile"]
    if let inputrc = environment["INPUTRC"], !inputrc.isEmpty {
        files.append(inputrc)
    }
    return files
}

// shell 在提示符前收到 ESC[200~ … ESC[201~ 时会整段插入编辑缓冲区、不执行（键位表里绑着 bracketed paste）：
//  - zsh 5.1 起三个默认键位表里都绑着。zle_bracketed_paste 只管通知终端打开这个模式，不影响绑定；
//    逐键送时 ESC 后面的字符要在 KEYTIMEOUT 之内到达，改过 KEYTIMEOUT 的（zsh-vi-mode 插件改成 10 毫秒）不冒险；
//  - bash 4.4 起（readline 7）绑着；vi 模式的命令模式里没有，用 vi 模式的不冒险。macOS 自带的 /bin/bash 是 3.2，没有；
//  - fish 3、4 都认得，但 fish 4 让终端用 kitty 键盘协议，逐键送的 ESC 到不了 shell：只接受一次写入。
// 配置文件里改过这个绑定（出现 "200~"）的都不冒险
func shellAcceptsBracketedPaste(pid: pid_t, delivery: TerminalDelivery) -> Bool {
    guard let executable = processExecutablePath(pid: pid) else {
        return false
    }
    let resolved = URL(fileURLWithPath: executable).resolvingSymlinksInPath().path
    let environment = processEnvironment(pid: pid) ?? [:]
    switch URL(fileURLWithPath: resolved).lastPathComponent {
    case "zsh":
        guard let files = zshConfigFiles(environment: environment), !configFilesMention(files, ["200~"]) else {
            return false
        }
        return delivery == .singleWrite || !configFilesMention(files, ["KEYTIMEOUT", "zsh-vi-mode"])
    case "bash":
        guard let version = bashVersion(executable: resolved), version.major > 4 || (version.major == 4 && version.minor >= 4) else {
            return false
        }
        return !configFilesMention(bashConfigFiles(environment: environment), ["200~", "editing-mode vi", "set -o vi"])
    case "fish":
        return delivery == .singleWrite
    default:
        return false
    }
}

// shell 在提示符前会打开终端的 bracketed paste 模式（终端自己的粘贴据此给内容加上标记）：zsh 5.1 起（没改过 zle_bracketed_paste）、
// bash 5.1 起（没关掉 enable-bracketed-paste）、fish。Ghostty 的 input text 和真正的粘贴一样由终端决定加不加标记，要看这个
func shellEnablesBracketedPasteMode(pid: pid_t) -> Bool {
    guard let executable = processExecutablePath(pid: pid) else {
        return false
    }
    let resolved = URL(fileURLWithPath: executable).resolvingSymlinksInPath().path
    let environment = processEnvironment(pid: pid) ?? [:]
    switch URL(fileURLWithPath: resolved).lastPathComponent {
    case "zsh":
        guard let files = zshConfigFiles(environment: environment) else {
            return false
        }
        return !configFilesMention(files, ["zle_bracketed_paste", "200~"])
    case "bash":
        guard let version = bashVersion(executable: resolved), version.major > 5 || (version.major == 5 && version.minor >= 1) else {
            return false
        }
        return !configFilesMention(bashConfigFiles(environment: environment), ["enable-bracketed-paste", "200~", "editing-mode vi", "set -o vi"])
    case "fish":
        return true
    default:
        return false
    }
}

// shell 可能开着 vi 键位（命令模式里键入的字母是命令）：配置里写了 vi 模式；zsh 还会在 $EDITOR / $VISUAL 含 "vi" 时默认用 vi 键位，
// 除非配置里（或 oh-my-zsh）明确改成 emacs 键位。认不出时按可能处理
func shellMayUseViMode(pid: pid_t) -> Bool {
    guard let executable = processExecutablePath(pid: pid) else {
        return true
    }
    let resolved = URL(fileURLWithPath: executable).resolvingSymlinksInPath().path
    let environment = processEnvironment(pid: pid) ?? [:]
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    switch URL(fileURLWithPath: resolved).lastPathComponent {
    case "zsh":
        guard let files = zshConfigFiles(environment: environment) else {
            return true
        }
        if configFilesMention(files, ["bindkey -v", "bindkey -A viins", "zsh-vi-mode", "vi-mode"]) {
            return true
        }
        let editorIsVi = [environment["VISUAL"], environment["EDITOR"]].contains { $0?.contains("vi") == true }
            || configFilesMatch(files, #"(EDITOR|VISUAL)=\S*vi"#)
        return editorIsVi && !configFilesMention(files, ["bindkey -e", "oh-my-zsh.sh"])
    case "bash":
        return configFilesMention(bashConfigFiles(environment: environment), ["set -o vi", "editing-mode vi"])
    case "fish":
        let config = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.config"
        var files = [config + "/fish/config.fish", config + "/fish/fish_variables", config + "/fish/functions/fish_user_key_bindings.fish"]
        files += ((try? FileManager.default.contentsOfDirectory(atPath: config + "/fish/conf.d")) ?? []).map { config + "/fish/conf.d/" + $0 }
        return configFilesMention(files, ["fish_vi_key_bindings", "fish_hybrid_key_bindings"])
    default:
        return false
    }
}

// fish 不认键入的 bracketed paste 时（见 shellAcceptsBracketedPaste）Copi 原样键入，键入的空格、; | & < > ) 会把前面的缩写（abbr）
// 展开成别的命令；真正的粘贴原样插入。配置里提到 abbr（config.fish、conf.d、functions、旧版存在 fish_variables 里的）、
// 这一行里又有会触发展开的字符时返回 true。读不到可执行文件时按是处理
func fishMayExpandAbbreviation(pid: pid_t, line: String) -> Bool {
    guard line.contains(where: { " ;|&<>)".contains($0) }) else {
        return false
    }
    guard let executable = processExecutablePath(pid: pid) else {
        return true
    }
    guard URL(fileURLWithPath: executable).resolvingSymlinksInPath().lastPathComponent == "fish" else {
        return false
    }
    let environment = processEnvironment(pid: pid) ?? [:]
    let config = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? FileManager.default.homeDirectoryForCurrentUser.path + "/.config"
    var files = [config + "/fish/config.fish", config + "/fish/fish_variables"]
    for directory in ["/fish/conf.d", "/fish/functions"] {
        files += ((try? FileManager.default.contentsOfDirectory(atPath: config + directory)) ?? []).map { config + directory + "/" + $0 }
    }
    return configFilesMention(files, ["abbr"])
}

// 配置文件里有一行匹配这个正则
private func configFilesMatch(_ paths: [String], _ pattern: String) -> Bool {
    paths.contains { path in
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            return false
        }
        return contents.range(of: pattern, options: .regularExpression) != nil
    }
}

private let bashVersionLock = NSLock()
private var bashVersionCache: [String: (major: Int, minor: Int)?] = [:]

// bash 的版本：macOS 自带的是 3.2；Homebrew、Nix 装的路径里带着版本号；别的问它自己（--version，结果按路径缓存）
func bashVersion(executable path: String) -> (major: Int, minor: Int)? {
    if path == "/bin/bash" || path == "/bin/sh" {
        return (3, 2)
    }
    bashVersionLock.lock()
    let cached = bashVersionCache[path]
    bashVersionLock.unlock()
    if let cached {
        return cached
    }
    func parse(_ text: String, _ pattern: String) -> (major: Int, minor: Int)? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), match.numberOfRanges == 3,
              let majorRange = Range(match.range(at: 1), in: text), let minorRange = Range(match.range(at: 2), in: text),
              let major = Int(text[majorRange]), let minor = Int(text[minorRange]) else {
            return nil
        }
        return (major, minor)
    }
    var version = parse(path, #"bash[-/](?:interactive-)?(\d+)\.(\d+)"#)
    if version == nil {
        // 不运行它（程序文件由别的程序决定，不能带着 Copi 的权限运行）：bash 的程序文件里有 "@(#)Bash version 5.2.37(1) release" 这样的字样
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped), data.count < 64 * 1024 * 1024,
           let range = data.range(of: Data("Bash version ".utf8)) {
            let tail = String(decoding: data[range.upperBound..<min(range.upperBound + 16, data.count)], as: UTF8.self)
            version = parse("version " + tail, #"version (\d+)\.(\d+)"#)
        }
    }
    bashVersionLock.lock()
    bashVersionCache[path] = version
    bashVersionLock.unlock()
    return version
}

// 进程的环境变量（只能读同一用户的进程）；读不到时为 nil
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

// 进程的程序文件路径
func processExecutablePath(pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else {
        return nil
    }
    return String(cString: buffer)
}

// 某个进程（通常是终端里的 shell）所在终端的前台进程组里的全部进程；读不到时为 nil
func foregroundGroup(ofProcess pid: pid_t) -> [ForegroundProcess]? {
    guard let processes = allProcesses(),
          let shell = processes.first(where: { $0.kp_proc.p_pid == pid }),
          shell.kp_eproc.e_tdev != -1, shell.kp_eproc.e_tpgid > 0 else {
        return nil
    }
    let tty = shell.kp_eproc.e_tdev
    let group = shell.kp_eproc.e_tpgid
    return processes
        .filter { $0.kp_eproc.e_pgid == group && $0.kp_eproc.e_tdev == tty && $0.kp_proc.p_stat != CChar(SZOMB) }
        .map { ForegroundProcess(pid: $0.kp_proc.p_pid, name: processName($0), tty: tty) }
}

// 某个终端设备（"/dev/ttys003"）前台进程组里的全部进程；读不到、组里没有进程时为 nil
func foregroundGroup(ofTerminalDevice path: String) -> [ForegroundProcess]? {
    var info = stat()
    guard path.hasPrefix("/dev/"), stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFCHR, let processes = allProcesses() else {
        return nil
    }
    let tty = Int32(bitPattern: UInt32(truncatingIfNeeded: info.st_rdev))
    guard let group = processes.first(where: { $0.kp_eproc.e_tdev == tty && $0.kp_eproc.e_tpgid > 0 })?.kp_eproc.e_tpgid else {
        return nil
    }
    let members = processes
        .filter { $0.kp_eproc.e_pgid == group && $0.kp_eproc.e_tdev == tty && $0.kp_proc.p_stat != CChar(SZOMB) }
        .map { ForegroundProcess(pid: $0.kp_proc.p_pid, name: processName($0), tty: tty) }
    return members.isEmpty ? nil : members
}

// 进程的子孙里有没有控制终端是另一个终端设备的：Vim 的 :terminal、Neovim 的终端窗口在自己开的伪终端上运行程序（Neovim 0.10 起
// 是它的 --embed 子进程开的），那个伪终端就是程序的控制终端。没有控制终端的子孙（插件、语言服务器经管道运行的）不算，已经退出的不算。
// 读不到进程表、这个进程已经不在时为 nil
func hasDescendantOnOtherTerminal(_ process: ForegroundProcess) -> Bool? {
    guard let processes = allProcesses(),
          processes.contains(where: { $0.kp_proc.p_pid == process.pid && $0.kp_eproc.e_tdev == process.tty }) else {
        return nil
    }
    var childIndexes: [pid_t: [Int]] = [:]
    for (index, entry) in processes.enumerated() {
        childIndexes[entry.kp_eproc.e_ppid, default: []].append(index)
    }
    var pending = [process.pid]
    var visited = Set<pid_t>()
    while let current = pending.popLast() {
        guard visited.insert(current).inserted else {
            continue
        }
        for index in childIndexes[current] ?? [] {
            let child = processes[index]
            if child.kp_proc.p_stat != CChar(SZOMB), child.kp_eproc.e_tdev != -1, child.kp_eproc.e_tdev != process.tty {
                return true
            }
            pending.append(child.kp_proc.p_pid)
        }
    }
    return false
}

func processName(_ process: kinfo_proc) -> String {
    var command = process.kp_proc.p_comm
    return withUnsafeBytes(of: &command) { raw in
        String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
    }.lowercased()
}

extension FocusedTarget {
    var attributeNames: [String] {
        guard !axBudgetExhausted else {
            return []
        }
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(element, &names) == .success, let names = names as? [String] else {
            return []
        }
        return names
    }

    var parameterizedAttributeNames: [String] {
        guard !axBudgetExhausted else {
            return []
        }
        var names: CFArray?
        guard AXUIElementCopyParameterizedAttributeNames(element, &names) == .success, let names = names as? [String] else {
            return []
        }
        return names
    }

    func webEngine(attributeNames names: [String]) -> WebEngine? {
        if names.contains("ChromeAXNodeId") {
            return .chromium
        }
        if isGeckoApp(pid: pid, bundleIdentifier: bundleIdentifier) {
            return .gecko
        }
        if names.contains("AXDOMIdentifier") || names.contains("AXDOMClassList") {
            return .webKit
        }
        return nil
    }

    var value: String? {
        copyAXAttribute(element, kAXValueAttribute) as? String
    }

    var childCount: Int? {
        guard !axBudgetExhausted else {
            return nil
        }
        var count: CFIndex = 0
        guard AXUIElementGetAttributeValueCount(element, kAXChildrenAttribute as CFString, &count) == .success else {
            return nil
        }
        return count
    }

    func isSettable(_ attribute: String) -> Bool {
        guard !axBudgetExhausted else {
            return false
        }
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success && settable.boolValue
    }

    var applicationName: String {
        NSRunningApplication(processIdentifier: pid)?.localizedName ?? "this app"
    }

    // 单行、没有子节点的原子输入框（网页里的 <input>；原生的 NSTextField）
    var isAtomicSingleLineField: Bool {
        guard let role, role == kAXTextFieldRole || role == kAXComboBoxRole else {
            return false
        }
        return childCount == 0
    }

    // 往上几层有没有网页代码编辑器、网页终端、Google Docs（见 codeEditorClassNames 等）。Firefox 不提供 AXDOMClassList，
    // 中途读不到父节点（超时）时也没法判断：都返回 .unknown，由调用方按最保守的方式处理
    func webEditorKind(engine: WebEngine) -> WebEditorKind? {
        if engine == .gecko {
            // Firefox：按 aria 标签认出 xterm.js 终端（"Terminal input"）和 Monaco（aria-roledescription "editor"），
            // 按网址认出 Google Docs 和没有代码编辑器的聊天、邮件网站，其余认不出
            for attribute in [kAXDescriptionAttribute, kAXTitleAttribute, kAXRoleDescriptionAttribute] {
                guard let label = copyAXAttribute(element, attribute) as? String else {
                    continue
                }
                // VS Code 网页版等把 "Terminal input" 译成界面语言（"终端输入"、"ターミナル入力"……）
                let lowered = label.lowercased()
                if label.localizedCaseInsensitiveContains("terminal") || ideTerminalLabels.contains(where: { lowered.contains($0) }) {
                    return .terminal
                }
                if label.caseInsensitiveCompare("editor") == .orderedSame || label.hasPrefix("Editor content") {
                    return .code
                }
            }
            if let url = webPageURL, let host = url.host?.lowercased() {
                // Firefox 认不出 Google Sheets 的单元格编辑框（没有 class），Docs、Sheets、Slides 的编辑页都按文字处理器拒绝
                if isGoogleEditorPage(url) {
                    return .wordProcessor
                }
                if geckoRichTextHosts.contains(host) {
                    return nil
                }
            }
            return .unknown
        }
        var node: AXUIElement? = element
        for _ in 0..<8 {
            guard let current = node else {
                // 还没走到网页根节点就读不到父节点了
                return .unknown
            }
            if axBudgetExhausted {
                return .unknown
            }
            if let classes = copyAXAttribute(current, "AXDOMClassList") as? [String] {
                if classes.contains(where: { vimModeClassNames.contains($0) }) {
                    return .vimCode
                }
                if classes.contains(where: { webTerminalClassNames.contains($0) }) {
                    return .terminal
                }
                if classes.contains(where: { codeEditorClassNames.contains($0) }) {
                    // Vim 模式的 class 可能在编辑器根节点（更上一层）上；Ace 的 Vim 模式是 "normal-mode"
                    return classes.contains("normal-mode") || ancestorsHaveVimMode(from: current) ? .vimCode : .code
                }
                if classes.contains(where: { wordProcessorClassNames.contains($0) }) {
                    return .wordProcessor
                }
                if classes.contains(where: { spreadsheetClassNames.contains($0) }) {
                    return .spreadsheet
                }
            }
            if (copyAXAttribute(current, kAXRoleAttribute) as? String) == "AXWebArea" {
                break
            }
            node = asAXElement(copyAXAttribute(current, kAXParentAttribute))
        }
        // Google Docs 的键盘输入在一个 about:blank 的 iframe 里，那里够不着外面的 class：再按网址认一遍
        // 只有真的找到了单元格编辑框才算电子表格（评论框、查找框、对话框里的 ⌘↩ 是提交）
        guard isGoogleEditorPage(webPageURL) else {
            return nil
        }
        return .wordProcessor
    }

    private func ancestorsHaveVimMode(from start: AXUIElement) -> Bool {
        var node = asAXElement(copyAXAttribute(start, kAXParentAttribute))
        for _ in 0..<3 {
            guard let current = node else {
                return false
            }
            if let classes = copyAXAttribute(current, "AXDOMClassList") as? [String],
               classes.contains(where: { vimModeClassNames.contains($0) || $0 == "normal-mode" }) {
                return true
            }
            node = asAXElement(copyAXAttribute(current, kAXParentAttribute))
        }
        return false
    }

    // 所在网页的网址（往上找到网页根节点读它的 AXURL；about:blank 这类脚本创建的 iframe 没有主机名，继续往外找）；找不到时为 nil
    var webPageURL: URL? {
        var node: AXUIElement? = element
        for _ in 0..<60 {
            guard let current = node, !axBudgetExhausted else {
                return nil
            }
            if (copyAXAttribute(current, kAXRoleAttribute) as? String) == "AXWebArea",
               let url = copyAXAttribute(current, kAXURLAttribute) as? URL, let host = url.host, !host.isEmpty {
                return url
            }
            node = asAXElement(copyAXAttribute(current, kAXParentAttribute))
        }
        return nil
    }

    var webPageHost: String? {
        webPageURL?.host?.lowercased()
    }

    // 在这里 ⇧↩ 是不是换行（见 softNewlineBundleIDPrefixes）：原生的多行文本视图、已知的聊天和邮件 App、网页。
    // 别的网页里认不出：网页电子表格的编辑框、搜索框（Google 的搜索框就是 <textarea>）里 ⇧↩ 会确认、提交
    func shiftReturnIsSoftNewline(engine: WebEngine?) -> Bool {
        // Java（Swing）的文本区：⇧↩ 什么都不插入，多行文字会被连成一行。它的选中文字也可以直接改写，下面的办法认不出来。
        // 这里多行文字只通过 Accessibility 写入，写不进去就拒绝，不键入
        if isJavaApp(pid: pid) {
            return false
        }
        if let bundleID = bundleIdentifier, softNewlineBundleIDPrefixes.contains(where: { bundleID.hasPrefix($0) }) {
            return true
        }
        guard engine != nil else {
            // 原生的多行文本视图（AppKit 的 NSTextView）：⇧↩ 和 ↩ 一样插入换行。认得出它的办法是选中的文字可以直接改写
            // （AXSelectedText 可写）：Qt、Tk 这些界面库只让改整段值，它们的 ⇧↩ 可能是别的意思（Jupyter QtConsole、Spyder
            // 的 ⇧↩ 是运行代码）；Java 在上面单独排除。认不出引擎的网页节点也不算
            return !hasWebAreaAncestor && isSettable(kAXSelectedTextAttribute)
        }
        return webPageHost.map { softNewlineHosts.contains($0) } ?? false
    }

    var isJavaIDE: Bool {
        isIntelliJPlatformApp(pid: pid, bundleID: bundleIdentifier)
    }

    var isElectronCodeEditorApp: Bool {
        if let bundleID = bundleIdentifier, electronCodeEditorBundleIDPrefixes.contains(where: { bundleID.hasPrefix($0) }) {
            return true
        }
        return vscodeDataFolderName(pid: pid) != nil
    }

    var isTerminalApp: Bool {
        bundleIdentifier.map { knownTerminalBundleIDs.contains($0) } ?? false
    }

    // 终端 App 里焦点在终端画面上，而不是同一窗口里的输入框（查找框、iTerm2 的 Composer、Ghostty 的命令面板）。终端画面的
    // 选中文字不能改写（iTerm2 的 AXValue 却是可写的，不能拿它判断）；没有辅助功能信息的终端（Alacritty 等）也算终端画面
    var isTerminalSurface: Bool {
        switch role {
        case kAXTextFieldRole?, "AXSearchField"?, kAXComboBoxRole?:
            return false
        case kAXTextAreaRole?:
            return !isSettable(kAXSelectedTextAttribute)
        default:
            return true
        }
    }

    // JetBrains 的文件编辑器（不是终端、控制台、单行输入框）：只有文件编辑器的名字是"Editor for <文件名>"，并且这个文件名也出现在
    // 窗口标题里（IDE 的窗口标题默认带着当前文件名）；还要是可编辑的，并且焦点不在对话框里（对话框开着时 IDE 会把写入推迟到它关掉）
    var isJetBrainsFileEditor: Bool {
        guard role == kAXTextAreaRole, isSettable(kAXValueAttribute),
              let description = copyAXAttribute(element, kAXDescriptionAttribute) as? String else {
            return false
        }
        let application = AXUIElementCreateApplication(pid)
        guard let focusedWindow = asAXElement(copyAXAttribute(application, kAXFocusedWindowAttribute)),
              let mainWindow = asAXElement(copyAXAttribute(application, kAXMainWindowAttribute)), CFEqual(focusedWindow, mainWindow),
              let title = copyAXAttribute(focusedWindow, kAXTitleAttribute) as? String else {
            return false
        }
        let fileNames = description.split(whereSeparator: { $0 == " " || $0 == ":" || $0 == "\"" }).map(String.init)
            .filter { $0.contains(".") && $0.count > 2 }
        return fileNames.contains { title.contains($0) }
    }

    // JetBrains：焦点在编辑器里还是在终端工具窗口里。从父节点开始往上找到窗口为止，途中有容器的名字就是"终端"（各种语言，
    // 或者 "Terminal: Local" 这样的工具窗口标题）就是终端；不看焦点控件自己（编辑器的名字是 "Editor for terminal.py" 这样带文件名的）。
    // 中途读不到（超时、层级太深）时不确定
    fileprivate var ideFocusPlace: IDEFocusPlace {
        var node = asAXElement(copyAXAttribute(element, kAXParentAttribute))
        for _ in 0..<30 {
            guard let current = node, !axBudgetExhausted else {
                return .unknown
            }
            let role = copyAXAttribute(current, kAXRoleAttribute) as? String
            if role == kAXWindowRole {
                return .editor
            }
            if role != kAXTextAreaRole {
                for attribute in [kAXTitleAttribute, kAXDescriptionAttribute] {
                    guard let label = (copyAXAttribute(current, attribute) as? String)?.lowercased() else {
                        continue
                    }
                    if ideTerminalLabels.contains(where: { label == $0 || label.hasPrefix($0 + ":") || label.hasPrefix($0 + " tool window") }) {
                        return .terminal
                    }
                }
            }
            node = asAXElement(copyAXAttribute(current, kAXParentAttribute))
        }
        return .unknown
    }

    // 可编辑的文字控件（⌘X 删除选中内容、模拟键入的前提）：只读的文本视图、Emacs/Vim 这类模态编辑器里键入的字符会被当成命令。
    // 终端 App 只排除终端画面（Emacs/Vim 可能在里面），它自己的输入框（iTerm2 的 Composer、查找框）照常算
    var isEditableTextControl: Bool {
        guard !isSecureTextField, let role, axWritableRoles.contains(role), !(isTerminalApp && isTerminalSurface) else {
            return false
        }
        return isSettable(kAXSelectedTextAttribute) || isSettable(kAXValueAttribute)
    }

    // 宽不到 40 点或高不到 8 点的多行输入框：网页里接收按键的隐藏输入框（xterm.js 的在屏幕外、0×0，Monaco 约 1 点宽，
    // 跟着光标走的也只有一个字符宽），不是用户看得见的输入框。读不到大小时不算
    var isTinyHiddenInput: Bool {
        guard role == kAXTextAreaRole, let raw = copyAXAttribute(element, kAXSizeAttribute), CFGetTypeID(raw) == AXValueGetTypeID() else {
            return false
        }
        var size = CGSize.zero
        guard AXValueGetValue(raw as! AXValue, .cgSize, &size) else {
            return false
        }
        return size.width < 40 || size.height < 8
    }

    // Firefox 的 <input>/<textarea>（不是 contenteditable）：单行输入框，或者没有子节点、只有一个文字节点的多行输入区。
    // contenteditable 的子节点是段落、分组
    var isGeckoTextControl: Bool {
        guard let role else {
            return false
        }
        if role == kAXTextFieldRole || role == kAXComboBoxRole {
            return true
        }
        guard role == kAXTextAreaRole, let children = copyAXAttribute(element, kAXChildrenAttribute) as? [AnyObject] else {
            return false
        }
        return children.count <= 1 && children.allSatisfy { child in
            asAXElement(child).flatMap { copyAXAttribute($0, kAXRoleAttribute) as? String } == kAXStaticTextRole
        }
    }

    // 输入法正在组字（有未上屏的拼音）。AppKit、WebKit 提供 AXTextInputMarkedRange，Chromium 没有（这时当作没有）
    var hasMarkedText: Bool {
        guard let value = copyAXAttribute(element, "AXTextInputMarkedRange"), CFGetTypeID(value) == AXValueGetTypeID() else {
            return false
        }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else {
            return false
        }
        guard range.length > 0 else {
            return false
        }
        // 光标后面的灰色"预测"文字（macOS 14 起）不算
        let caret = selectedRange.map { $0.location + $0.length } ?? Int.max
        return range.location < caret
    }

    // 选中了不止一段（⌘-拖选出的多段、多光标）：选中文字只给第一段，按一次退格却会把每一段都删掉
    var hasMultipleSelections: Bool {
        (copyAXAttribute(element, "AXSelectedTextRanges") as? [Any]).map { $0.count > 1 } ?? false
    }

    // Firefox 系的 App 不提供 AXSelectedTextRanges，看不出选了几段：用 ⌘ 添过选区、之后没在那里点过文字的地方算作选了多段
    // （见 PointerInterceptor.mayHaveSeveralGeckoRanges）
    var mayHaveUnlistedSelections: Bool {
        isGeckoApp(pid: pid, bundleIdentifier: bundleIdentifier) && PointerInterceptor.shared.mayHaveSeveralGeckoRanges(focus: element, pid: pid)
    }

    // 选了多段时按位置顺序读出每一段（和原生文本视图自己的"拷贝"一样连起来）；有一段读不出来就返回 nil
    var multipleSelectionText: String? {
        guard let values = copyAXAttribute(element, "AXSelectedTextRanges") as? [AnyObject], values.count > 1 else {
            return nil
        }
        var ranges: [CFRange] = []
        for value in values {
            guard CFGetTypeID(value) == AXValueGetTypeID() else {
                return nil
            }
            var range = CFRange()
            guard AXValueGetValue(value as! AXValue, .cfRange, &range) else {
                return nil
            }
            ranges.append(range)
        }
        var pieces: [String] = []
        for var range in ranges.sorted(by: { $0.location < $1.location }) where range.length > 0 {
            guard let rangeValue = AXValueCreate(.cfRange, &range),
                  let piece = copyAXParameterizedAttribute(element, "AXStringForRange", rangeValue) as? String else {
                return nil
            }
            pieces.append(piece)
        }
        guard !pieces.isEmpty else {
            return nil
        }
        // 和文本视图自己的"拷贝"一样：各段之间补一个段落分隔，已经以换行结尾的段不补
        var result = ""
        for (index, piece) in pieces.enumerated() {
            result += piece
            if index < pieces.count - 1, !(piece.hasSuffix("\n") || piece.hasSuffix("\r") || piece.hasSuffix("\u{2029}")) {
                result += "\n"
            }
        }
        return result
    }

    // 焦点所在窗口的标题（终端用它判断正在运行的程序）；读不到为 nil
    var focusedWindowTitle: String? {
        guard let window = asAXElement(copyAXAttribute(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute)) else {
            return nil
        }
        return copyAXAttribute(window, kAXTitleAttribute) as? String
    }

    // 终端前台正在运行什么：以进程树为准（每个标签页的前台进程组里只有 shell，或者只有在等密码的 sudo 这类程序，才算在提示符前）。
    // 窗口标题只在别的标签页运行着程序时，用来确认当前标签页（Terminal、iTerm2 的标题显示它的前台程序）在提示符前。
    // 读不到、认不出都按"别的程序"处理
    fileprivate var terminalForeground: TerminalForeground {
        guard let groups = terminalForegroundGroups(pid: pid, bundleID: bundleIdentifier), !groups.isEmpty else {
            return .other(nil)
        }
        func isPrompt(_ group: [ForegroundProcess]) -> Bool {
            !group.isEmpty && group.allSatisfy(isAtPrompt)
        }
        // 这些组里的 shell；有一组只是在等密码（sudo）时返回空：那个标签页不能多行粘贴，而且不知道焦点在不在它上面
        func shells(in groups: [[ForegroundProcess]]) -> [ForegroundProcess] {
            var shells: [ForegroundProcess] = []
            for group in groups {
                let groupShells = group.filter { !terminalPasswordPrograms.contains($0.name) }
                guard groupShells.count == group.count else {
                    return []
                }
                shells += groupShells
            }
            return shells
        }
        let promptGroups = groups.filter(isPrompt)
        // 标题里单独成段的当前程序名正好是某些停在提示符前的标签页里的 shell：当前标签页就是其中之一。
        // Terminal 在提示符前显示的是登录 shell 的 "-zsh"（"目录 — -zsh — 80×24"），要求带上这个 "-"，免得把叫 zsh 的目录名当成程序；
        // iTerm2 显示 "zsh" 或 "Default (zsh)"
        let titleMatching = { () -> [[ForegroundProcess]] in
            guard let title = self.focusedWindowTitle, let bundleID = self.bundleIdentifier, jobTitleTerminalBundleIDs.contains(bundleID) else {
                return []
            }
            let components = title.components(separatedBy: CharacterSet(charactersIn: "—()"))
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            let requiresLoginDash = bundleID == "com.apple.Terminal"
            let named = Set(components.compactMap { component -> String? in
                if component.hasPrefix("-") {
                    return String(component.dropFirst())
                }
                return requiresLoginDash ? nil : component
            })
            // 标题里的名字也是没停在提示符前的标签页里的程序：分不出当前是哪个标签页，不收窄。iTerm2 对运行脚本的 zsh
            // （zsh ./setup.zsh）和提示符前的 zsh 都显示 "zsh"；Terminal 只有登录 shell 显示 "-zsh"。这个 "-" 来自启动参数：
            // 别的用户的 shell（su、sudo -s 打开的 root shell）的启动参数 Terminal 和 Copi 一样读不出，不会这样显示
            let ambiguous = groups.contains { group in
                !isPrompt(group) && group.contains { process in
                    named.contains(process.name) && (!requiresLoginDash || processArguments(pid: process.pid)?.first?.hasPrefix("-") == true)
                }
            }
            if ambiguous {
                return []
            }
            return promptGroups.filter { group in group.contains { named.contains($0.name) } }
        }
        if promptGroups.count == groups.count {
            // 都在提示符前：标题指明了当前标签页的 shell 时只看那几个标签页（别的标签页里不认 bracketed paste 的老 shell、
            // 在等密码的 sudo 不该挡住这一个）
            let matching = groups.count > 1 ? titleMatching() : []
            let chosen = matching.isEmpty ? groups : matching
            return .prompt(shells: shells(in: chosen), ttys: chosen.compactMap { $0.first?.tty })
        }
        // 别的标签页在运行程序：标题指明了当前标签页的 shell，才算当前标签页在提示符前
        let matching = titleMatching()
        if !matching.isEmpty {
            return .prompt(shells: shells(in: matching), ttys: matching.compactMap { $0.first?.tty })
        }
        let other = groups.first { !isPrompt($0) }.flatMap(programName)
        return .other(other)
    }

    // 终端里拿着焦点的标签页正在运行 tmux 的旁证（见 typeIntoTerminalByKeys）：Terminal、iTerm2 看窗口标题里有没有单独的 "tmux"；
    // 别的终端看不出标签页，只在 App 只开着一个窗口时才算
    var focusedSurfaceShowsTmux: Bool {
        if let bundleID = bundleIdentifier, jobTitleTerminalBundleIDs.contains(bundleID) {
            guard let title = focusedWindowTitle else {
                return false
            }
            return title.components(separatedBy: CharacterSet(charactersIn: "—()"))
                .contains { $0.trimmingCharacters(in: .whitespaces).lowercased().split(separator: " ").first == "tmux" }
        }
        let windows = (copyAXAttribute(AXUIElementCreateApplication(pid), kAXWindowsAttribute) as? [AnyObject]) ?? []
        return windows.count == 1
    }

    // 确定不是在复制文字：文件管理器里的文件列表、没有选中文字的图片。只对这些放行原生 ⌘C/⌘X——其余情况（列表、大纲里复制出来的
    // 往往也是文字，文件管理器里的文本预览、内置终端，图片上的实况文本，Accessibility 读不出来、判断不了的）一律当作可能是文字
    // 放行之后复制出来的却是文字的地方（见 GlobalMode.noteNonTextPassThrough）记在 misjudgedNonTextContexts 里，以后不再放行
    var isKnownNonTextContext: Bool {
        guard let role else {
            return false
        }
        if let bundleID = bundleIdentifier, Defaults[.misjudgedNonTextContexts].contains(Self.contextKey(bundleID: bundleID, role: role)) {
            return false
        }
        if let bundleID = bundleIdentifier, fileManagerBundleIDs.contains(bundleID) {
            if [kAXOutlineRole, kAXListRole, kAXBrowserRole, kAXTableRole, kAXRowRole].contains(role) {
                return true
            }
            // 分组、滚动区域：可能是图标视图，也可能是 Quick Look、预览栏里的文本预览（底下有文本区域、网页内容或选中的文字）。
            // 看不全（Accessibility 出错、时间用完）就当作可能是文字
            return (role == kAXGroupRole || role == kAXScrollAreaRole) && axSubtreeHasText(element, depth: 3, selectedOnly: false) == false
        }
        // 图片上的实况文本：选中的文字在它的子元素上
        return role == kAXImageRole && hasSelection != true && axSubtreeHasText(element, depth: 2, selectedOnly: true) == false
    }

    static func contextKey(bundleID: String, role: String) -> String {
        "\(bundleID)|\(role)"
    }

    // 有没有选中内容：true 有、false 确定没有、nil 判断不了
    var hasSelection: Bool? {
        if let range = selectedRange {
            return range.length > 0
        }
        if let markerRange = copyAXAttribute(element, "AXSelectedTextMarkerRange"),
           let length = copyAXParameterizedAttribute(element, "AXLengthForTextMarkerRange", markerRange) as? NSNumber {
            return length.intValue > 0
        }
        return nil
    }

    // 焦点是否仍在这个控件上（同一个进程里的同一个元素）
    var isStillFocused: Bool {
        guard let current = focusedTarget() else {
            return false
        }
        return current.pid == pid && CFEqual(current.element, element)
    }
}

func copyAXParameterizedAttribute(_ element: AXUIElement, _ attribute: String, _ parameter: CFTypeRef) -> CFTypeRef? {
    guard !axBudgetExhausted else {
        return nil
    }
    var value: CFTypeRef?
    let result = AXUIElementCopyParameterizedAttributeValue(element, attribute as CFString, parameter, &value)
    PasteboardQuarantine.shared.checkpoint()
    guard result == .success else {
        return nil
    }
    return value
}

// 同上，读不到时说清是"没有"还是"不知道"（出错、App 没响应、时间用完，或者根本不支持这项查询）
func readAXParameterizedAttribute(_ element: AXUIElement, _ attribute: String, _ parameter: CFTypeRef) -> AXAttributeRead {
    guard !axBudgetExhausted else {
        return .failed
    }
    var value: CFTypeRef?
    let result = AXUIElementCopyParameterizedAttributeValue(element, attribute as CFString, parameter, &value)
    PasteboardQuarantine.shared.checkpoint()
    switch result {
    case .success:
        return value.map { .value($0) } ?? .none
    case .noValue:
        return .none
    default:
        return .failed
    }
}

// 单行输入框粘贴时浏览器会把换行变成空格，这里照做（模拟键入、改写 AXValue 时用）
func normalizedForSingleLine(_ text: String) -> String {
    var result = text
    while let last = result.unicodeScalars.last, last == "\n" || last == "\r" {
        result.unicodeScalars.removeLast()
    }
    return result
        .replacingOccurrences(of: "\r\n", with: " ")
        .replacingOccurrences(of: "\r", with: " ")
        .replacingOccurrences(of: "\n", with: " ")
}

// 4–8 位纯数字（验证码）：分格的验证码输入框是按逐字键入设计的（每输一位跳到下一格），整体写入只会塞进第一格
private func looksLikeOneTimeCode(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return (4...8).contains(trimmed.count) && trimmed.allSatisfy { $0.isASCII && $0.isNumber }
}

// MARK: - 0 暴露粘贴

enum ZeroExposurePasteResult {
    // 已经写进去了（或者写入请求已经发出、结果不确定——这时也不能再走别的路，免得粘贴两遍）
    case inserted
    // 安排了模拟键入，稍后（用户松开修饰键后）完成
    case typing
    // 这里没有 0 暴露的办法（或者用了会改变粘贴的效果）
    case unavailable(UnavailableReason)
}

// 没有 0 暴露办法的原因，用来告诉用户怎么办
enum UnavailableReason: Error {
    case noRoute
    // 终端里按行收输入的地方（sudo 的密码提示、脚本里的 read）一行放不下这么多字节（见 canonicalLineRefusal）：分几次粘贴也不行
    case lineTooLong(Int)
    // 只能一行一行地键入（终端、代码编辑器、认不出 ⇧↩ 是不是换行的编辑器）
    case multiLine
    // 当前是拼音等输入法，键入的字符会被拿去组字
    case inputMethod
    // 正运行着（或开着）把按键当命令的程序：终端里的 vim、less，编辑器的 Vim 模式；nil 表示看不出终端里在运行什么
    case modalProgram(String?)
    // 编辑器、shell 会改掉其中的某些字符（自动补全括号引号、历史展开）
    case unsafeCharacters
    // 富文本编辑器会把键入的某些写法变成格式（行首的 "- " 变成列表、":smile:" 变成表情）
    case formattingTriggers
    // 虚拟机、远程桌面：有的字符没法用一个键（加 ⇧）直接打出来
    case untypeableCharacters
    // 大写锁定开着：虚拟机里打出来的大小写会反
    case capsLock
    // shell 可能开着 vi 键位，命令模式里粘贴进去的字母是命令
    case viMode
    // fish 定义了缩写（abbr）：键入的空格、; | & 会把前面的词展开成别的命令，真正的粘贴不会
    case shellAbbreviations
    // 终端在等单个按键（zsh 的 read -q、bash 的 read -n 1 这类）：粘贴的第一个字符就是回答
    case singleKeyPrompt
    // 打开了 "Don't Type When Keystrokes Are Watched"，而这些程序看得到按键（键入的文字它们都看得到）
    case keystrokesWatched([String])
    // 从网页浏览器复制的文字要粘贴进"终端"：等用户再按一次 ⌘V 确认（见 BrowserToTerminalGuard）
    case needsConfirmation(source: String)
    // 要退回剪贴板方式，而这些 App（虚拟机、远程桌面、模拟器）会把剪贴板同步到另一台电脑上、留在那里：等用户再粘贴一次确认
    // （见 RemoteClipboardGuard）
    case remoteClipboard([String])
    // tmux 设了在粘贴缓冲区时运行的钩子（见 TmuxPaste）
    case tmuxHooks([String])
    // 机密内容要粘贴进地址栏、搜索框：等用户再粘贴一次确认（见 ConcealedDestinationGuard）
    case concealedIntoSearch
    // Copi 还在往这里键入上一次粘贴，或者上一次粘贴刚刚在这里打到一半停下（见 KeystrokeTyper.isTypingOrJustStopped）
    case stillTyping

    // 允许剪贴板回退时可不可以退回剪贴板：用户为了不让别的程序看到才拒绝键入的，剪贴板上它们（和所有 App）一样看得到；
    // 还在键入上一次粘贴时，原生粘贴进去的文字一样会和打了一半的那段混在一起；一行太长时经过剪贴板的粘贴也一样会被终端丢掉后半截
    var allowsClipboardFallback: Bool {
        switch self {
        case .keystrokesWatched, .needsConfirmation, .remoteClipboard, .concealedIntoSearch, .stillTyping, .lineTooLong:
            return false
        // 在等单个按键时 shell 没打开 bracketed paste 模式：真正的粘贴一样会被第一个字符回答，退回剪贴板只多一次暴露
        case .singleKeyPrompt:
            return false
        default:
            return true
        }
    }
}

// 用户打开了 "Don't Type When Keystrokes Are Watched"、并且现在有第三方程序看得到 Copi 要往 pid 键入的按键时，返回它们的名字。
// location：键入的事件发在哪一层（文字键入发在"已标注"层，虚拟机里按真实的键发在会话层）。
// Secure Input 开着时（密码框）系统不把按键交给任何 event tap，不算
// fresh：不用缓存的 tap 清单（键入途中逐块复查时，最多 20 毫秒前的）
func keystrokeWatchersBlockingTyping(into pid: pid_t, postedAt location: CGEventTapLocation = .cgAnnotatedSessionEventTap,
                                     fresh: Bool = false) -> [String]? {
    guard Defaults[.refuseTypingWhenWatched], !IsSecureEventInputEnabled() else {
        return nil
    }
    // 打开 "Type Privately" 时文字直接发给目标 App：只有专门盯着它的 tap 看得到
    let direct = Defaults[.typePrivately] && location == .cgAnnotatedSessionEventTap
    let watchers = KeystrokeObservers.thirdPartyWatchers(postedAt: location, targetPID: pid, directToTarget: direct, maxAge: fresh ? 0.02 : 1)
    return watchers.isEmpty ? nil : watchers
}

// 在主线程、withAXBudget 之内调用。target 为 nil 表示拿不到焦点控件的信息（例如还没开启无障碍树的 Electron App）：
// 这时不知道焦点是不是输入框，不能贸然模拟键入（在 Finder、图片编辑器、游戏里打字会触发各种快捷操作）。
// keyTime：用户按下粘贴快捷键（或点 Action Bar）的时刻，用来判断之后用户有没有接着操作（见 KeystrokeTyper）。
// concealed：这段文字是不是机密（密码管理器的复制）；nil 时看安全剪贴板
func zeroExposurePaste(_ text: String, into target: FocusedTarget?, keyTime: Date, concealed: Bool? = nil) -> ZeroExposurePasteResult {
    dispatchPrecondition(condition: .onQueue(.main))
    // 允许剪贴板回退时也先走不经过剪贴板的路线：只有这里一条路都没有（返回 .unavailable）时，调用方才退回剪贴板
    guard let target else {
        // 读不到焦点控件：只看是哪个 App
        if let pid = focusedApplication()?.processIdentifier,
           KeystrokeTyper.shared.isTypingOrJustStopped(into: pid, element: nil, keyTime: keyTime) {
            return .unavailable(.stillTyping)
        }
        guard let passwordField = revealPasswordField(around: nil) else {
            // （读不到焦点控件的虚拟机、远程桌面：退回剪贴板之前由 remoteClipboardConfirmationBeforeFallback 先提醒）
            return .unavailable(.noRoute)
        }
        return typePassword(text, into: passwordField, keyTime: keyTime)
    }
    // 上一次粘贴还在往这里键入，或者刚刚在这里打到一半停下：这次什么都不粘贴——不论写入、键入还是退回剪贴板，
    // 都会和打了一半的那段混在一起。先于各种"再粘贴一次确认"的提醒：这次按键不去提醒（也就不会开始等确认）
    if KeystrokeTyper.shared.isTypingOrJustStopped(into: target.pid, element: target.element, keyTime: keyTime) {
        return .unavailable(.stillTyping)
    }
    // 机密内容要粘贴进地址栏、搜索框：先提醒
    if ConcealedDestinationGuard.needsConfirmation(text, concealed: concealed ?? (SecureClipboard.shared.text == text && SecureClipboard.shared.isConcealed),
                                                   into: target, keyTime: keyTime) {
        return .unavailable(.concealedIntoSearch)
    }
    let bundleID = target.bundleIdentifier ?? ""
    // 虚拟机、远程桌面的画面（不是它们自己界面上的输入框）：只认键位，按真实的按键逐个输入。它们自己的列表、按钮这类界面
    // （虚拟机列表、连接列表）、读不出焦点是什么的时候不键入
    if remoteDesktopBundleIDPrefixes.contains(where: { bundleID.hasPrefix($0) }), !(target.role.map(axWritableRoles.contains) ?? false) {
        var result = ZeroExposurePasteResult.unavailable(.noRoute)
        if Defaults[.typeIntoVirtualMachines], let role = target.role, !remoteDesktopHostUIRoles.contains(role) {
            result = typeIntoRemoteDesktop(text, target: target, keyTime: keyTime)
        }
        // 要退回剪贴板方式时：文字会经过它们的剪贴板共享进到那台电脑的剪贴板上（还可能进它的剪贴板历史，例如 Windows 的 Win+V），
        // 粘贴完也一直留在那里，Copi 撤不下来。退回之前由 remoteClipboardConfirmationBeforeFallback 先提醒
        return result
    }
    // 密码框：模拟键入。浏览器在密码框里会强制使用 ASCII 输入源，Secure Input 期间系统也不把键盘事件交给任何监听者，
    // 这反而是最不会被看到的情形
    if target.isSecureTextField {
        return typePassword(text, into: target, keyTime: keyTime)
    }
    // VS Code 系编辑器装了 Copi Bridge：先问清是哪个窗口、焦点在它的什么地方。编辑器、小输入框里用编辑器自己的 paste 命令；
    // 终端里由扩展把文字送进去；别的地方（快速打开、查找框……）照常往下走
    if target.isElectronCodeEditorApp, EditorBridge.shared.isConnected(appPID: target.pid),
       let focus = EditorBridge.shared.locateFocus(appPID: target.pid, timeout: min(0.3, axBudgetRemaining ?? 0.3)) {
        switch focus.place {
        case .editor, .simpleEditor:
            return pasteThroughEditorBridge(text, focus: focus, target: target)
        case .terminal:
            return pasteIntoEditorTerminal(text, focus: focus, target: target, keyTime: keyTime)
        case .other:
            break
        }
    }
    // 终端、JetBrains：只键入不会改变效果的文字（终端在 shell 提示符前，多行用 bracketed paste；JetBrains 文件编辑器直接写入）
    if target.isTerminalApp {
        return typeIntoTerminal(text, target: target, keyTime: keyTime)
    }
    if target.isJavaIDE {
        // 文件编辑器：Accessibility 写入（IDE 把它当作一次可撤销的编辑执行），什么文字都能原样插入
        if target.isJetBrainsFileEditor {
            return jetBrainsWrite(text, into: target,
                                  aboveCurrentLine: SecureClipboard.shared.text == text && SecureClipboard.shared.metadata?.pasteOnNewLine == true)
        }
        switch target.ideFocusPlace {
        case .editor:
            return typeIntoCodeEditor(text, target: target, keyTime: keyTime)
        case .terminal:
            return typeIntoIDETerminal(text, target: target, keyTime: keyTime)
        case .unknown:
            return .unavailable(.noRoute)
        }
    }
    let role = target.role
    let names = target.attributeNames
    let engine = target.webEngine(attributeNames: names)
    // 焦点是整个网页、一个分组这类说不清的节点、并且认不出网页引擎（Chrome 的无障碍树还没建好时就是这样），而这个 App 正开着
    // Secure Input：焦点多半在它的密码框里，请它建好无障碍树再确认
    if engine == nil, role == nil || role == "AXWebArea" || role == kAXGroupRole || role == kAXWindowRole,
       let passwordField = revealPasswordField(around: target) {
        return typePassword(text, into: passwordField, keyTime: keyTime)
    }
    guard let engine else {
        if target.isElectronCodeEditorApp {
            return .unavailable(.noRoute)
        }
        // 读不到属性名（目标 App 卡住、超时）而其实是网页：认不出是什么编辑器，按代码编辑器的规则只键入安全的单行文字
        if target.hasWebAreaAncestor {
            return typeIntoCodeEditor(text, target: target, keyTime: keyTime)
        }
        // 原生控件
        switch writeSelectedText(text, to: target) {
        case .inserted, .uncertain:
            return .inserted
        case .notApplicable:
            return typeIfPossible(text, into: target, newlines: newlinePolicy(for: target, role: role, engine: nil), keyTime: keyTime)
        }
    }
    let editorKind = target.webEditorKind(engine: engine)
    switch editorKind {
    case .code?:
        return typeIntoCodeEditor(text, target: target, keyTime: keyTime)
    case .vimCode?:
        return .unavailable(.modalProgram("Vim"))
    case .terminal?:
        return .unavailable(.modalProgram(nil))
    case .wordProcessor?:
        return .unavailable(.noRoute)
    case .spreadsheet?:
        // 单元格里键入（只有找到了单元格编辑框的 class 才会到这里）；换行用 ⌘↩（单元格进入编辑状态之后才行，所以开头的换行去掉）
        var cellText = KeystrokeTyper.normalizedNewlines(text)
        while cellText.hasPrefix("\n") {
            cellText.removeFirst()
        }
        while cellText.hasSuffix("\n") {
            cellText.removeLast()
        }
        return typeIfPossible(cellText, into: target, newlines: .commandReturn, keyTime: keyTime)
    case .unknown?, nil:
        break
    }
    let isAtomic = target.isAtomicSingleLineField || (role == kAXTextAreaRole && target.childCount == 0)
    if looksLikeOneTimeCode(text), target.isAtomicSingleLineField {
        // 逐位键入（每位一个按键，分格验证码组件会自动跳到下一格）
        let digits = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return typeIfPossible(digits, into: target, newlines: .joinWithSpaces, keyTime: keyTime, perCharacter: true)
    }
    switch engine {
    case .webKit:
        switch webKitTextOperation(text, into: target) {
        case .inserted, .uncertain:
            return .inserted
        case .notApplicable:
            break
        }
    case .chromium:
        if isAtomic {
            switch spliceValue(text, into: target, keyTime: keyTime) {
            case .inserted, .uncertain:
                return .inserted
            case .notApplicable:
                break
            }
        } else if target.parameterizedAttributeNames.contains("AXTextOperation") {
            // Chromium 自己也实现了 AXTextOperation，但目前默认关闭；哪天打开了就自动用上（富文本编辑器也能 0 暴露粘贴）
            switch webKitTextOperation(text, into: target) {
            case .inserted, .uncertain:
                return .inserted
            case .notApplicable:
                break
            }
        }
    case .gecko:
        // 认不出的、几乎看不见的 <textarea>：网页终端（xterm.js）、代码编辑器（CodeMirror 5、Ace、界面语言不是英文的 Monaco）
        // 接收按键用的隐藏输入框。整体改写值会被页面当成键入的文字转给终端（换行就是回车），键入也一样：都不做，
        // 第二次按下经过剪贴板、由页面自己的粘贴处理（xterm 会包上 bracketed paste）
        if case .unknown? = editorKind, target.isTinyHiddenInput {
            return .unavailable(.noRoute)
        }
        // Firefox 的 <input>/<textarea>：整体改写值（异步生效，写完确认）。富文本编辑区不行，只能键入
        if target.isGeckoTextControl {
            switch spliceValue(text, into: target, keyTime: keyTime, byteLimit: geckoValueByteLimit) {
            case .inserted, .uncertain:
                return .inserted
            case .notApplicable:
                break
            }
        }
    }
    if target.isAtomicSingleLineField {
        return typeIfPossible(text, into: target, newlines: .joinWithSpaces, keyTime: keyTime)
    }
    // 认不出是什么编辑器（Firefox、读不到 class）：可能是代码编辑器或电子表格。可编辑的文档区域（contenteditable，代码编辑器多半是这种）
    // 不键入；单独的 <textarea> 按代码编辑器的规则只键入安全的单行文字
    if case .unknown? = editorKind {
        guard target.childCount == 0 else {
            return .unavailable(.noRoute)
        }
        return typeIntoCodeEditor(text, target: target, keyTime: keyTime)
    }
    // 富文本编辑器（Slack、Notion、Gmail……）、多行输入框：用键入（只在 ⇧↩ 确定是换行的地方键入多行文字）。
    // 富文本编辑区（有子元素，不是单独的 <textarea>）会把键入的 Markdown 写法、表情代码变成格式，真正的粘贴不会：这样的文字不键入
    if role == kAXTextAreaRole || target.isSettable(kAXValueAttribute) {
        if target.childCount != 0, containsFormattingTriggers(text) {
            return .unavailable(.formattingTriggers)
        }
        return typeIfPossible(text, into: target, newlines: newlinePolicy(for: target, role: role, engine: engine), keyTime: keyTime)
    }
    return .unavailable(.noRoute)
}

// 富文本编辑器在键入时会变成格式的写法：行首（前面可以有空格）的标题、列表、引用、代码块、待办、分隔线，以及表情代码（:smile:）。
// 冒号隔开的一串里、两头都紧贴着字母、数字、下划线或冒号的 :name:（ARN 的 arn:aws:s3:::bucket、IPv6、MAC 地址、std::io::Write、
// Tailwind 的 hover:bg-red-500）不算表情代码；只要有一头不贴着就算。编辑器在打下结尾的冒号时就转换，开头贴着词的
// great job:tada:、结尾后面还跟着字的 :smile::tada:、:thumbsup::skin-tone-2:、:smile:foo 照样会变
func containsFormattingTriggers(_ text: String) -> Bool {
    let lineStart = #"(?m)^[ \t]*(#{1,6} |[-*+] |> |\d{1,9}[.)] |```|~~~|\[[ xX]?\] |---|\*\*\*|___)"#
    let emoji = #"(?<![A-Za-z0-9_:]):[A-Za-z_][A-Za-z0-9_+\-]*:|:[A-Za-z_][A-Za-z0-9_+\-]*:(?![A-Za-z0-9_:])"#
    return text.range(of: lineStart, options: .regularExpression) != nil || text.range(of: emoji, options: .regularExpression) != nil
}

private func newlinePolicy(for target: FocusedTarget, role: String?, engine: WebEngine?) -> NewlinePolicy {
    switch role {
    case kAXTextAreaRole?:
        return target.shiftReturnIsSoftNewline(engine: engine) ? .shiftReturn : .refuse
    case kAXTextFieldRole?, kAXComboBoxRole?, "AXSearchField"?:
        return .joinWithSpaces
    default:
        return .refuse
    }
}

// 通过桥接扩展用编辑器自己的 paste 命令粘贴。文字是从这个编辑器复制来的话，把整行复制、多光标各段的信息一起交回去
private func pasteThroughEditorBridge(_ text: String, focus: EditorBridge.Focus, target: FocusedTarget) -> ZeroExposurePasteResult {
    var payload: [String: Any] = ["cmd": "paste", "text": text, "target": focus.place.rawValue]
    // 编辑器附带的复制信息只属于安全剪贴板里的那段文字（粘贴的可能是刚撤下来的临时文字）
    if SecureClipboard.shared.text == text, let metadata = SecureClipboard.shared.metadata {
        payload["isFromEmptySelection"] = metadata.pasteOnNewLine
        if let pieces = metadata.multicursorText {
            payload["multicursorText"] = pieces
        }
    }
    // 等回音也算在这次处理的时间预算里：剩下的时间太少就不发（还什么都没发，拒绝或退回别的办法都不会粘贴两遍）
    let wait = min(0.5, axBudgetRemaining ?? 0.5)
    guard wait >= 0.05 else {
        return .unavailable(.noRoute)
    }
    switch EditorBridge.shared.request(payload, to: focus, timeout: wait) {
    case .response(let response):
        guard response["ok"] as? Bool == true else {
            // 扩展没有执行（来晚了、出错了）
            return .unavailable(.noRoute)
        }
        // 只读的编辑器：编辑器自己的粘贴这时也什么都不做
        if response["result"] as? String != "unchanged" {
            notifyProtected("Pasted safely")
        }
        return .inserted
    case .timedOut:
        // 请求已经发出去了：可能稍后才执行，不能再走别的路，免得粘贴两遍
        notifyPasteUncertain(into: target)
        return .inserted
    case .notSent:
        return .unavailable(.noRoute)
    }
}

// VS Code 系编辑器的集成终端：由扩展问出终端里 shell 的进程（必须是这台 Mac 上、这个编辑器启动的进程），确认它停在提示符前，
// 再让扩展把文字一次送进终端
private func pasteIntoEditorTerminal(_ text: String, focus: EditorBridge.Focus, target: FocusedTarget, keyTime: Date) -> ZeroExposurePasteResult {
    // 远程窗口的终端跑在别的机器上，看不到里面在运行什么
    guard !focus.isRemote else {
        return .unavailable(.modalProgram(nil))
    }
    guard min(0.3, axBudgetRemaining ?? 0.3) >= 0.05,
          case .response(let info) = EditorBridge.shared.request(["cmd": "terminalProcess"], to: focus, timeout: min(0.3, axBudgetRemaining ?? 0.3)),
          info["ok"] as? Bool == true, info["remote"] == nil || info["remote"] is NSNull,
          let shellPID = (info["pid"] as? NSNumber)?.int32Value, isDescendant(shellPID, of: target.pid) else {
        return .unavailable(.modalProgram(nil))
    }
    // 看前台进程组里真正在运行的 shell（用户可能在终端里又开了一个 bash、sh）
    let group = foregroundGroup(ofProcess: shellPID)
    guard let group, !group.isEmpty, group.allSatisfy(isAtPrompt) else {
        // 脚本在等单个按键（read -n 1）：第一个字符就是回答，第二次按下也不经过剪贴板（和别的终端一样）
        if let group, groupWaitsForSingleKey(group) {
            return .unavailable(.singleKeyPrompt)
        }
        return .unavailable(.modalProgram(group.flatMap(programName)))
    }
    let shells = group.filter { !terminalPasswordPrograms.contains($0.name) }
    // 停在 sudo 这类的密码提示：直接往终端的输入框里键入单行文字，不经过扩展进程（同一进程里的其他扩展看不到密码）
    if shells.count < group.count {
        guard let line = singleLineWithoutTrailingNewline(text) else {
            return .unavailable(.multiLine)
        }
        if let reason = canonicalLineRefusal(line, ttys: group.map(\.tty), atPasswordPrompt: true) {
            return .unavailable(reason)
        }
        guard !line.isEmpty, let role = target.role, axWritableRoles.contains(role),
              KeystrokeTyper.canType(line, maxUnitsPerCharacter: typingChunkLimit(pid: target.pid)) else {
            return .unavailable(.noRoute)
        }
        guard InputSourceState.canTypeNow else {
            return .unavailable(.inputMethod)
        }
        if let watchers = keystrokeWatchersBlockingTyping(into: target.pid) {
            return .unavailable(.keystrokesWatched(watchers))
        }
        KeystrokeTyper.shared.type(line, into: target, keyTime: keyTime)
        return .typing
    }
    let payload: String
    switch terminalPayload(for: text, shells: shells, atPasswordPrompt: false, ttys: group.map(\.tty)) {
    case .success(let value):
        payload = value
    case .failure(let reason):
        return .unavailable(reason)
    }
    let sendWait = min(0.4, axBudgetRemaining ?? 0.4)
    guard sendWait >= 0.05 else {
        return .unavailable(.noRoute)
    }
    // 用户在这期间接着打字、点了别处（可能切到了别的终端）：不再粘贴
    guard !userActedSince(keyTime) else {
        notifyCopiNotice("Copi didn't paste into \(target.applicationName) because you kept typing or clicked elsewhere. Press ⌘V again.")
        return .inserted
    }
    // 扩展只往刚才问过的那个终端里送（pid 也要对得上）：两次请求之间拿着焦点的终端换了时，它不送
    switch EditorBridge.shared.request(["cmd": "terminalSend", "text": payload, "pid": NSNumber(value: shellPID)], to: focus, timeout: sendWait) {
    case .response(let response) where response["ok"] as? Bool == true:
        notifyProtected("Pasted safely")
        return .inserted
    case .response(let response) where response["error"] as? String == "changed":
        notifyCopiNotice("Copi didn't paste into \(target.applicationName) because a different terminal became active. Press ⌘V again.")
        return .inserted
    case .timedOut:
        notifyPasteUncertain(into: target)
        return .inserted
    default:
        return .unavailable(.noRoute)
    }
}

// JetBrains 的文件编辑器：写 kAXSelectedText。IDE 在自己的事件线程上把它作为一次可撤销的编辑执行，所以写入请求返回时还没生效，
// 稍后确认（字符数对上、插入处的文字对上），确认后再把光标移到插入的文字后面（IDE 会把光标留在前面）。
// 文字里不能有 \r（IDE 会报错、什么都不插入）
// aboveCurrentLine：这是一次整行复制（没有选中内容时复制的光标所在行），和 IDE 自己一样插到当前行的上面，光标留在原来的位置
// （跟着下移一行）
private func jetBrainsWrite(_ text: String, into target: FocusedTarget, aboveCurrentLine: Bool = false) -> ZeroExposurePasteResult {
    guard let lengthBefore = target.numberOfCharacters, let selection = target.selectedRange,
          selection.location >= 0, selection.length >= 0 else {
        return .unavailable(.noRoute)
    }
    let insert = KeystrokeTyper.normalizedNewlines(text)
    guard !insert.isEmpty else {
        return .unavailable(.noRoute)
    }
    let insertedLength = (insert as NSString).length
    var location = selection.location
    var caretAfter = selection.location + insertedLength
    // 先把光标移到当前行的开头（和接下来的写入一样在 IDE 的事件线程上按顺序执行）；读不到行的范围就照常插在光标处
    if aboveCurrentLine, selection.length == 0, insert.hasSuffix("\n"),
       let line = (copyAXAttribute(target.element, kAXInsertionPointLineNumberAttribute) as? NSNumber)?.intValue,
       let value = copyAXParameterizedAttribute(target.element, "AXRangeForLine", NSNumber(value: line)),
       CFGetTypeID(value) == AXValueGetTypeID() {
        var lineRange = CFRange()
        var lineStart = CFRange()
        if AXValueGetValue(value as! AXValue, .cfRange, &lineRange), lineRange.location >= 0, lineRange.location <= selection.location {
            lineStart = CFRange(location: lineRange.location, length: 0)
            if let start = AXValueCreate(.cfRange, &lineStart),
               AXUIElementSetAttributeValue(target.element, kAXSelectedTextRangeAttribute as CFString, start) == .success {
                location = lineRange.location
                caretAfter = selection.location + insertedLength
            }
        }
    }
    // 超时（IDE 一时卡住）：写入请求还在 IDE 的队列里，稍后可能照样生效——不能再退回别的办法，否则会粘贴两遍
    let written = AXUIElementSetAttributeValue(target.element, kAXSelectedTextAttribute as CFString, insert as CFTypeRef)
    guard written == .success || written == .cannotComplete else {
        return .unavailable(.noRoute)
    }
    confirmJetBrainsWrite(target, insert: insert, at: location, caretAfter: caretAfter,
                          expectedLength: lengthBefore - (location == selection.location ? selection.length : 0) + insertedLength,
                          writtenAt: Date(), deadline: Date().addingTimeInterval(written == .success ? 1.5 : 3))
    return .inserted
}

private func confirmJetBrainsWrite(_ target: FocusedTarget, insert: String, at location: Int, caretAfter: Int, expectedLength: Int,
                                   writtenAt: Date, deadline: Date) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
        var range = CFRange(location: location, length: (insert as NSString).length)
        let landed = target.numberOfCharacters == expectedLength
            && AXValueCreate(.cfRange, &range).flatMap { copyAXParameterizedAttribute(target.element, "AXStringForRange", $0) as? String } == insert
        guard landed else {
            if Date() < deadline {
                confirmJetBrainsWrite(target, insert: insert, at: location, caretAfter: caretAfter, expectedLength: expectedLength,
                                      writtenAt: writtenAt, deadline: deadline)
            } else {
                notifyPasteUncertain(into: target)
            }
            return
        }
        var caret = CFRange(location: caretAfter, length: 0)
        // 写入之后用户又打字、移动了光标的话不动它
        if InputActivity.lastInput < writtenAt, let caretValue = AXValueCreate(.cfRange, &caret) {
            AXUIElementSetAttributeValue(target.element, kAXSelectedTextRangeAttribute as CFString, caretValue)
        }
        notifyProtected("Pasted safely")
    }
}

// JetBrains 的文件编辑器里剪切：选中的内容已经存进安全剪贴板，再把它写成空（IDE 把它当作一次可撤销的删除）。
// 先确认选区和其中的文字都没变；写入是异步生效的，稍后确认字符数少了这么多
func jetBrainsCut(_ target: FocusedTarget, range: CFRange, text: String) {
    var expectedRange = range
    guard let lengthBefore = target.numberOfCharacters, let selection = target.selectedRange,
          selection.location == range.location, selection.length == range.length,
          AXValueCreate(.cfRange, &expectedRange).flatMap({ copyAXParameterizedAttribute(target.element, "AXStringForRange", $0) as? String }) == text,
          AXUIElementSetAttributeValue(target.element, kAXSelectedTextAttribute as CFString, "" as CFTypeRef) == .success else {
        notifyCopiNotice("Copi copied the selection but couldn't delete it in \(target.applicationName). Delete it yourself if you meant to cut it.")
        return
    }
    let deadline = Date().addingTimeInterval(1.5)
    func confirm() {
        if target.numberOfCharacters == lengthBefore - range.length {
            notifyProtected("Cut safely")
            return
        }
        guard Date() < deadline else {
            notifyCopiNotice("Copi copied the selection, but isn't sure it was deleted from \(target.applicationName). Check before cutting again.")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: confirm)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: confirm)
}

// 虚拟机、远程桌面 App 自己的界面（不是客户机的画面）
private let remoteDesktopHostUIRoles: Set<String> = [
    kAXListRole, kAXTableRole, kAXOutlineRole, kAXRowRole, kAXCellRole, kAXButtonRole, kAXPopUpButtonRole, kAXCheckBoxRole,
    kAXMenuButtonRole, kAXRadioButtonRole, kAXTabGroupRole, kAXToolbarRole, kAXMenuItemRole, kAXMenuBarItemRole,
]

// 拿着焦点的是虚拟机、远程桌面的客户机画面（不是它们自己界面上的输入框、列表、按钮）。读不出焦点是什么时也算：
// 客户机画面往往没有 Accessibility 信息
func isRemoteDesktopGuestDisplay(_ target: FocusedTarget?, bundleID: String?) -> Bool {
    guard isRemoteDesktopApp(bundleID) else {
        return false
    }
    guard let role = target?.role else {
        return true
    }
    return !axWritableRoles.contains(role) && !remoteDesktopHostUIRoles.contains(role)
}

// 虚拟机、远程桌面：它们把按键事件的键位换成客户机的扫描码，不认事件里带的字符。按当前（英文）键盘布局把每个字符换成键位和 ⇧，
// 像真的按键一样逐个按下。只用单行文字（客户机里的 ↩ 会执行、提交）。每个键要几十毫秒，长的打得久，屏幕上显示进度、按 Esc 停下
private func typeIntoRemoteDesktop(_ text: String, target: FocusedTarget, keyTime: Date) -> ZeroExposurePasteResult {
    guard let line = singleLineWithoutTrailingNewline(text) else {
        return .unavailable(.multiLine)
    }
    guard !line.isEmpty else {
        return .unavailable(.noRoute)
    }
    guard !CGEventSource.flagsState(.hidSystemState).contains(.maskAlphaShift) else {
        return .unavailable(.capsLock)
    }
    guard let strokes = KeyPressMap.strokes(for: line) else {
        return .unavailable(.untypeableCharacters)
    }
    guard InputSourceState.canTypeNow else {
        return .unavailable(.inputMethod)
    }
    if let watchers = keystrokeWatchersBlockingTyping(into: target.pid, postedAt: .cgSessionEventTap) {
        return .unavailable(.keystrokesWatched(watchers))
    }
    KeystrokeTyper.shared.pressKeys(strokes, into: target, keyTime: keyTime)
    return .typing
}

// 一次真实的按键：键位、要不要按着 ⇧
struct KeyStroke {
    let keyCode: CGKeyCode
    let shift: Bool
    let character: String
}

// 字符 → 当前键盘布局上的键位（只用不带修饰键和带 ⇧ 两种；⌥ 在客户机里是 Alt/AltGr，死键要组合，都不用）
enum KeyPressMap {
    // 主线程（TIS）。有字符打不出来时返回 nil
    static func strokes(for text: String) -> [KeyStroke]? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
                ?? TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let dataPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        var layoutID = ""
        if let idPointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) {
            layoutID = Unmanaged<CFString>.fromOpaque(idPointer).takeUnretainedValue() as String
        }
        // 客户机的键盘布局看不到：只有 Mac 用的是美式布局时才放心打标点，别的布局只打字母、数字（键位在各种布局里一样）
        let usLayout = layoutID == "com.apple.keylayout.US" || layoutID == "com.apple.keylayout.ABC"
        let layoutData = Unmanaged<CFData>.fromOpaque(dataPointer).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(layoutData) else {
            return nil
        }
        let map = bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
            buildMap(layout)
        }
        var strokes: [KeyStroke] = []
        for character in text {
            if character == " " {
                strokes.append(KeyStroke(keyCode: CGKeyCode(kVK_Space), shift: false, character: " "))
                continue
            }
            let isPlainAlphanumeric = character.isASCII && (character.isLetter || character.isNumber)
            guard let key = map[character], usLayout || isPlainAlphanumeric else {
                return nil
            }
            strokes.append(KeyStroke(keyCode: key.keyCode, shift: key.shift, character: String(character)))
        }
        return strokes
    }

    private static func buildMap(_ layout: UnsafePointer<UCKeyboardLayout>) -> [Character: (keyCode: CGKeyCode, shift: Bool)] {
        let keyboardType = UInt32(LMGetKbdType())
        let shiftState = UInt32((shiftKey >> 8) & 0xFF)
        // 主键区（字母、数字、标点）；↩、⇥、空格、删除、esc、数字小键盘除外
        let excluded: Set<Int> = [kVK_Return, kVK_Tab, kVK_Space, kVK_Delete, kVK_Escape]
        var map: [Character: (keyCode: CGKeyCode, shift: Bool)] = [:]
        for modifierState in [UInt32(0), shiftState] {
            for keyCode in 0...0x32 where !excluded.contains(keyCode) {
                var deadKeyState: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDown), modifierState, keyboardType,
                                            OptionBits(0), &deadKeyState, 4, &length, &chars)
                // 死键（要和下一个键组合）不用
                guard status == noErr, deadKeyState == 0, length == 1, chars[0] >= 0x20, chars[0] != 0x7F,
                      let scalar = Unicode.Scalar(chars[0]) else {
                    continue
                }
                let character = Character(scalar)
                if map[character] == nil {
                    map[character] = (CGKeyCode(keyCode), modifierState != 0)
                }
            }
        }
        return map
    }
}

// 换行怎么处理
enum NewlinePolicy {
    // 单行输入框：像浏览器粘贴时那样把换行变成空格（不能发送 ↩/⇧↩：网页 <input> 里不管带不带 ⇧ 都会提交表单）
    case joinWithSpaces
    // 多行输入框、富文本编辑器：换行用 ⇧↩
    case shiftReturn
    // Google Sheets 的单元格：换行用 ⌘↩
    case commandReturn
    // 不知道 ⇧↩ 在这里是不是换行：有换行就不键入
    case refuse
}

// 只在焦点确实是输入框时模拟键入；当前是拼音等输入法时不键入（字符会被输入法当成拼音组字，
// 而 Copi 在后台切换输入法又不可靠：切回中日韩输入法时菜单栏变了、实际输入却没变）
// 还要求控件可编辑：只读的文本视图、Emacs/Vim 这类模态编辑器里，键入的字符会被当成命令执行。
// 多行文字只在默认（不回退剪贴板）时用 ⇧↩ 键入。
private func typeIfPossible(_ text: String, into target: FocusedTarget, newlines: NewlinePolicy, keyTime: Date, perCharacter: Bool = false) -> ZeroExposurePasteResult {
    guard target.isSecureTextField || target.isEditableTextControl else {
        return .unavailable(.noRoute)
    }
    var policy = newlines
    if case .shiftReturn = policy, multiLineTypingDenyBundleIDPrefixes.contains(where: { (target.bundleIdentifier ?? "").hasPrefix($0) }) {
        policy = .refuse
    }
    let typed: String
    let allowNewlines: Bool
    switch policy {
    case .joinWithSpaces:
        typed = normalizedForSingleLine(text)
        allowNewlines = false
    case .shiftReturn, .commandReturn:
        typed = KeystrokeTyper.normalizedNewlines(text)
        allowNewlines = true
    case .refuse:
        typed = KeystrokeTyper.normalizedNewlines(text)
        allowNewlines = false
    }
    if !allowNewlines, typed.unicodeScalars.contains("\n") {
        return .unavailable(.multiLine)
    }
    guard KeystrokeTyper.canType(typed, allowNewlines: allowNewlines, maxUnitsPerCharacter: typingChunkLimit(pid: target.pid)) else {
        return .unavailable(.noRoute)
    }
    // 密码框：浏览器、系统在焦点进入密码框之后才（异步地）强制切到英文输入源，留给键入前的检查去等
    guard target.isSecureTextField || InputSourceState.canTypeNow else {
        return .unavailable(.inputMethod)
    }
    if let watchers = keystrokeWatchersBlockingTyping(into: target.pid) {
        return .unavailable(.keystrokesWatched(watchers))
    }
    let newlineKey: KeystrokeTyper.NewlineKey
    if case .commandReturn = policy {
        newlineKey = .commandReturn
    } else {
        newlineKey = .shiftReturn
    }
    KeystrokeTyper.shared.type(typed, into: target, keyTime: keyTime, perCharacter: perCharacter, newlineKey: newlineKey)
    return .typing
}

// 密码框：键入单行文字；看起来是验证码时逐位键入（分格的验证码框也可能是密码框，每格只收一位）
private func typePassword(_ text: String, into target: FocusedTarget, keyTime: Date) -> ZeroExposurePasteResult {
    if looksLikeOneTimeCode(text) {
        let digits = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return typeIfPossible(digits, into: target, newlines: .joinWithSpaces, keyTime: keyTime, perCharacter: true)
    }
    return typeIfPossible(text, into: target, newlines: .joinWithSpaces, keyTime: keyTime)
}

// 去掉末尾的换行（终端里真正的粘贴也不会因为末尾的换行而执行命令，键入时去掉它才等价）；中间还有换行就返回 nil
private func singleLineWithoutTrailingNewline(_ text: String) -> String? {
    var line = text
    while let last = line.unicodeScalars.last, last == "\n" || last == "\r" {
        line.unicodeScalars.removeLast()
    }
    return line.unicodeScalars.contains { $0 == "\n" || $0 == "\r" } ? nil : line
}

// 终端：焦点在终端画面上时，iTerm2、Ghostty 允许 Copi 用它们的脚本接口、WezTerm、kitty（打开了远程控制）的话，把文字一次交给终端
// （见 TerminalScript）；否则模拟键入。
// 焦点在同一窗口里的输入框（查找框、iTerm2 的 Composer、Ghostty 的命令面板）时，只往那个输入框里键入单行文字
// 终端 App 自己窗口里的原生控件（设置窗口的表格、勾选框，提示框的按钮）：不是终端画面，也不是输入框
private let terminalAppControlRoles: Set<String> = [
    kAXButtonRole, kAXCheckBoxRole, kAXRadioButtonRole, kAXPopUpButtonRole, kAXMenuButtonRole, kAXTableRole, kAXOutlineRole,
    kAXListRole, kAXRowRole, kAXCellRole, kAXSliderRole, kAXTabGroupRole, kAXDisclosureTriangleRole, "AXRadioGroup", "AXIncrementor", "AXLink",
]

private func typeIntoTerminal(_ text: String, target: FocusedTarget, keyTime: Date) -> ZeroExposurePasteResult {
    // 焦点在这种控件上时按键会选行、切换勾选框，和别的 App 里一样没有不经过剪贴板的办法
    if let role = target.role, terminalAppControlRoles.contains(role) {
        return .unavailable(.noRoute)
    }
    if let source = BrowserToTerminalGuard.unconfirmedSource(of: text, into: target, keyTime: keyTime) {
        return .unavailable(.needsConfirmation(source: source))
    }
    guard target.isTerminalSurface else {
        guard let line = singleLineWithoutTrailingNewline(text) else {
            // 多行文字：iTerm2 的 Composer 这种原生多行编辑框，直接写进选区（不按键、不经过剪贴板，换行只是文字，按 Return 才发送）
            if target.role == kAXTextAreaRole, target.bundleIdentifier == TerminalScript.iTerm2.bundleIdentifier {
                switch writeSelectedText(text, to: target, terminalInputField: true) {
                case .inserted, .uncertain:
                    return .inserted
                case .notApplicable:
                    break
                }
            }
            return .unavailable(.multiLine)
        }
        guard !target.isSecureTextField, KeystrokeTyper.canType(line, maxUnitsPerCharacter: typingChunkLimit(pid: target.pid)) else {
            return .unavailable(.noRoute)
        }
        guard InputSourceState.canTypeNow else {
            return .unavailable(.inputMethod)
        }
        if let watchers = keystrokeWatchersBlockingTyping(into: target.pid) {
            return .unavailable(.keystrokesWatched(watchers))
        }
        KeystrokeTyper.shared.type(line, into: target, keyTime: keyTime)
        return .typing
    }
    // 前台是 Neovim：通过它自己的 RPC 接口粘贴，和真正的粘贴一样（见 NvimPaste）
    if let candidates = NvimPaste.candidates(for: target) {
        NvimPaste.pasteInBackground(text, candidates: candidates, target: target, keyTime: keyTime)
        return .typing
    }
    let pasted = TerminalScript.pasteIfPermitted(text, into: target, keyTime: keyTime) {
        // 脚本接口没能送出去（终端版本太旧、关掉了脚本、权限被收回）：照旧模拟键入
        if case .unavailable(let reason) = typeIntoTerminalByKeys(text, target: target, keyTime: keyTime) {
            refuseOrFallBack(reason, text: text, target: target, keyTime: keyTime)
        }
    }
    return pasted ? .typing : typeIntoTerminalByKeys(text, target: target, keyTime: keyTime)
}

// 逐键键入 bracketed paste 时，按键（ESC、文字、↩）原样变成对应字节送给 shell 的终端。Warp 的输入框不是 shell，
// Hyper、Tabby 这类网页终端会拦下 ESC
private let keystrokeBracketedPasteTerminalBundleIDs: Set<String> = [
    "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "net.kovidgoyal.kitty", "com.github.wez.wezterm", "org.alacritty",
]

// 终端里模拟键入：只在 shell 提示符前键入。单行文字直接键入（去掉末尾的换行；终端按行收输入时要放得下，见 canonicalLineRefusal）；
// shell 可能开着 vi 键位时也包上 bracketed paste 的标记
// （命令模式里原样键入的字母是命令）。多行文字只在 shell 的行编辑器正在读、并且认得 bracketed paste 时，包成和真正粘贴一样的
// ESC[200~ … ESC[201~ 键入——shell 收到后整段插入编辑缓冲区、不执行（单独键入换行等于按回车执行命令）
private func typeIntoTerminalByKeys(_ text: String, target: FocusedTarget, keyTime: Date) -> ZeroExposurePasteResult {
    // iTerm2 的 tmux 整合（tmux -CC）开着：整合开出来的标签页里，键入的按键由 iTerm2 变成 tmux 的命令送过去（tmux 把命令连同文字
    // 记进消息记录），运行 tmux -CC 的标签页收到的文字本身就是 tmux 的命令。这里分不出焦点在哪个标签页（Copi 能用 iTerm2 的
    // 脚本接口时由 TerminalScript 问 iTerm2），一律不键入
    if target.bundleIdentifier == TerminalScript.iTerm2.bundleIdentifier, iTermTmuxIntegrationIsRunning(pid: target.pid) {
        return .unavailable(.modalProgram("tmux"))
    }
    // WezTerm 的复制模式开着（读得到标题、以 "Copy mode: " 开头）：没在编辑搜索词时字母是命令（y 把选区复制到剪贴板并关掉它，
    // 剩下的按键落进 shell）。标题看不出是不是在编辑搜索词：不键入，第二次按下经剪贴板时由 WezTerm 自己粘贴进它的搜索词
    if target.focusedWindowTitle != nil, target.wezTermOverlayMayBeOpen {
        return .unavailable(.modalProgram("copy mode"))
    }
    let shells: [ForegroundProcess]
    let ttys: [Int32]
    switch target.terminalForeground {
    case .prompt(let found, let foundTTYs):
        shells = found
        ttys = foundTTYs
    case .other(let program):
        // 前台是 tmux（终端里所有窗口合计只有这一个标签页、没有分屏时才认得出是它）：交给 tmux 粘贴进它当前的 pane（见 TmuxPaste）。
        // WezTerm 走到这里时是它自己的接口特意没接（复制模式、搜索框、启动器开着，粘贴应该落在那里），不能绕过去交给 tmux；
        // Alacritty 的搜索、提示模式也画在终端画面里，看不出来开着
        // 只有一个 tmux 也不能说明焦点就在它那里（焦点所在的标签页可能已经结束、没有前台进程了）：Terminal、iTerm2 的窗口标题
        // 显示当前标签页的程序，要在标题里看到 tmux；别的终端要求只开着一个窗口
        if program == "tmux", ![TerminalScript.wezterm.bundleIdentifier, "org.alacritty"].contains(target.bundleIdentifier ?? ""),
           target.focusedSurfaceShowsTmux,
           let groups = terminalForegroundGroups(of: target),
           let client = TmuxPaste.soleClient(in: groups) ?? TmuxPaste.focusedClient(for: target, groups: groups) {
            TmuxPaste.pasteInBackground(text, client: client, target: target, keyTime: keyTime)
            return .typing
        }
        return typeIntoLineReader(text, program: program, target: target, keyTime: keyTime)
    }
    let limit = typingChunkLimit(pid: target.pid)
    let canBracket = { () -> Bool in
        // WezTerm 的复制模式、搜索框可能开着（见 wezTermOverlayMayBeOpen）：bracketed paste 开头的 ESC 会关掉它，后面的按键落进
        // shell，换行就是回车，一行行执行。不包：单行文字按普通按键键入（到达搜索框），多行文字不键入
        if target.wezTermOverlayMayBeOpen {
            return false
        }
        guard let bundleID = target.bundleIdentifier, keystrokeBracketedPasteTerminalBundleIDs.contains(bundleID), !shells.isEmpty else {
            return false
        }
        return shells.allSatisfy { shellAcceptsBracketedPaste(pid: $0.pid, delivery: .keystrokes) && lineEditorIsReading(tty: $0.tty) }
    }
    // 在等单个按键（zsh 的 read -q、bash 的 read -n 1）：键入的第一个字符就是回答。（有标签页停在 sudo 的密码提示时 shells 为空，
    // 不看：设了 pwfeedback 的 sudo 读密码时也关掉 canonical 模式）
    if shells.contains(where: { waitsForSingleKey($0) }) {
        return .unavailable(.singleKeyPrompt)
    }
    if let line = singleLineWithoutTrailingNewline(text) {
        // shells 为空：有标签页停在 sudo 这类的密码提示
        if let reason = canonicalLineRefusal(line, ttys: ttys, atPasswordPrompt: shells.isEmpty) {
            return .unavailable(reason)
        }
        // 包不包 bracketed paste 只判断一次：包上时 Tab 按 ⇥ 键入，shell 原样插入；不包时 ⇥ 会触发补全，含 Tab 的文字照旧拒绝。
        // 再判断一次可能得出不同的结果，Tab 就会在标记外面键入
        let bracketed = canBracket()
        guard KeystrokeTyper.canType(line, allowTabs: bracketed, maxUnitsPerCharacter: limit) else {
            return .unavailable(.noRoute)
        }
        let viMode = shells.contains { shellMayUseViMode(pid: $0.pid) }
        if viMode, !bracketed {
            return .unavailable(.viMode)
        }
        if !bracketed, shells.contains(where: { fishMayExpandAbbreviation(pid: $0.pid, line: line) }) {
            return .unavailable(.shellAbbreviations)
        }
        guard InputSourceState.canTypeNow else {
            return .unavailable(.inputMethod)
        }
        if let watchers = keystrokeWatchersBlockingTyping(into: target.pid) {
            return .unavailable(.keystrokesWatched(watchers))
        }
        // 能包成 bracketed paste 就包上（和真正的粘贴一样）：键入的途中漏进来的回车（Secure Keyboard Entry 开着时 Copi 拦不到）
        // 只会变成一个换行，不会执行打了一半的命令
        KeystrokeTyper.shared.type(line, into: target, keyTime: keyTime, bracketedPaste: bracketed)
        return .typing
    }
    var body = KeystrokeTyper.normalizedNewlines(text)
    while body.hasSuffix("\n") {
        body.removeLast()
    }
    guard canBracket() else {
        return .unavailable(.multiLine)
    }
    guard KeystrokeTyper.canType(body, allowNewlines: true, allowTabs: true, maxUnitsPerCharacter: limit) else {
        return .unavailable(.noRoute)
    }
    guard InputSourceState.canTypeNow else {
        return .unavailable(.inputMethod)
    }
    if let watchers = keystrokeWatchersBlockingTyping(into: target.pid) {
        return .unavailable(.keystrokesWatched(watchers))
    }
    KeystrokeTyper.shared.type(body, into: target, keyTime: keyTime, bracketedPaste: true)
    return .typing
}

// 主线程：终端前台有没停在 shell 提示符前的程序（program；tmux 另外处理）。模拟键入时，以及终端自己的接口（见 TerminalScript）
// 看到焦点所在的程序不在提示符前时，都由这里决定
// 终端自己的接口说了焦点在哪个会话时（focusedGroup：iTerm2、读得到终端设备的 Ghostty、WezTerm），下面几条都只看那个会话：
// 按键只会到达那里，别的标签页在等单个按键、开着全屏程序、用 vi 键位都不挡住往这里键入。否则看所有标签页（看不出焦点在哪个）
//  - 有标签页的前台只有 shell、它在等单个按键（zsh 的 read -q、bash 的 read -n 1，停在提示符前的和运行脚本的都算）：看不出焦点
//    在不在它那里，和都停在提示符前时一样拒绝。排在允许剪贴板回退的拒绝之前，第二次按下也不经过剪贴板（第一个字符就是回答）。
//    不在提示符前的 shell 要读得到终端设置、确实在等才算：别的用户的 shell 读不到（`sudo -s` 打开的 root shell 在 sudo 新开的、
//    属于 root 的伪终端上），没有证据说它在等，下面按行读的判断也不会往它那里键入，照 program 拒绝；
//  - 前台程序在按行读（脚本里的 read、Python 的 input()、ssh、gpg 问密码……）：这一行由终端驱动编辑，键入的字母不会被当成命令，
//    回车之前什么都不会发生，和用户自己打一样。要看的标签页都是这样或者停在 shell 提示符前；
//  - 否则按 program 拒绝
// 这一组前台进程只有 shell、它在等单个按键（提示符前的 zsh 的 read -q，脚本里的 read -n 1）
func groupWaitsForSingleKey(_ group: [ForegroundProcess]) -> Bool {
    guard !group.isEmpty, group.allSatisfy({ ["zsh", "bash", "sh"].contains($0.name) }) else {
        return false
    }
    return group.allSatisfy(isAtPrompt) ? group.contains(where: waitsForSingleKey) : group.contains { readsSingleKey($0) == true }
}

func typeIntoLineReader(_ text: String, program: String?, target: FocusedTarget, keyTime: Date,
                        focusedGroup: [ForegroundProcess]? = nil) -> ZeroExposurePasteResult {
    let waitsForKey = groupWaitsForSingleKey
    // 两项判断用同一份进程表
    guard let groups = focusedGroup.map({ [$0] }) ?? terminalForegroundGroups(of: target) else {
        return .unavailable(.modalProgram(program))
    }
    if groups.contains(where: waitsForKey) {
        return .unavailable(.singleKeyPrompt)
    }
    if let line = singleLineWithoutTrailingNewline(text), let readers = lineReadersAndPromptShells(in: groups) {
        return typeLineIntoLineReader(line, target: target, keyTime: keyTime, readers: readers)
    }
    return .unavailable(.modalProgram(program))
}

// groups 里的前台进程组都只是停在 shell 提示符前，或者前台程序在按行读（终端开着 canonical 模式）：按行读的那些终端设备，以及提示符前的 shell。
// 有别的（全屏程序、关掉了 canonical 模式的程序）时为 nil
private func lineReadersAndPromptShells(in groups: [[ForegroundProcess]]) -> (ttys: [Int32], shells: [ForegroundProcess])? {
    var ttys: [Int32] = []
    var shells: [ForegroundProcess] = []
    for group in groups {
        if group.allSatisfy(isAtPrompt) {
            shells += group
            continue
        }
        guard let tty = group.first?.tty, terminalReadsWholeLines(tty: tty) else {
            return nil
        }
        // 终端开着 canonical 模式只说明它按行收输入，看不出前台程序是不是在读（macOS 看不到进程卡在哪个调用上）。运行脚本的 shell
        // 在等它启动的程序（组里有它的子进程：bash install.sh 正在下载、安装），或者从管道、文件读脚本（curl … | bash、
        // bash < install.sh：它的 read 读的不是终端）时，这一行多半留在终端里，等脚本之后读终端的地方读走（read -n 1 时第一个字符
        // 就是回答）。shell 自己在读终端（脚本里的 read）时组里没有它的子进程。读不到父进程、标准输入时按是处理。
        // 脚本启动的另一个脚本（install.sh 运行 ./configure.sh）exec 了自己的脚本，启动参数和启动它的 shell 不同：它不算"启动的程序"，
        // 停在自己的 read 时和单层的脚本一样。脚本 fork 出来的子 shell（$(…)、( … )、管道里的函数，还没 exec 的）启动参数和父进程
        // 一样，照旧算；读不到启动参数时也算。
        // 终端关着回显、按行收输入（见 passwordIsBeingRead）时不看这两样：这是有程序正在读密码（脚本启动的 sudo、ssh），
        // 它从终端读（curl … | bash 里的 sudo 也是），这一行就是给它的
        let scriptShells = group.filter { terminalPromptPrograms.contains($0.name) && !terminalPasswordPrograms.contains($0.name) }
        let scriptShellIDs = Set(scriptShells.map(\.pid))
        let runsOwnScript = { (member: ForegroundProcess, parent: pid_t) -> Bool in
            guard scriptShellIDs.contains(member.pid), let arguments = processArguments(pid: member.pid),
                  let parentArguments = processArguments(pid: parent) else {
                return false
            }
            return arguments != parentArguments
        }
        let waitsForLaunchedProgram = !scriptShellIDs.isEmpty && group.contains { member in
            guard let parent = parentProcessID(of: member.pid) else {
                return true
            }
            return scriptShellIDs.contains(parent) && !runsOwnScript(member, parent)
        }
        if scriptShells.contains(where: { !standardInputIsTerminal($0) }) || waitsForLaunchedProgram, !passwordIsBeingRead(tty: tty) {
            return nil
        }
        ttys.append(tty)
    }
    return ttys.isEmpty ? nil : (ttys, shells)
}

// 往按行读的程序里键入一行：不加 bracketed paste 的标记（程序不认，标记会成为这一行的一部分）。看的标签页里有提示符前的 shell
// 用 vi 键位时不键入（看不出焦点是不是在它那里，命令模式里字母是命令；只看焦点所在的会话时这里没有提示符前的 shell）；
// 这一行要放得下（见 canonicalLineRefusal）
private func typeLineIntoLineReader(_ line: String, target: FocusedTarget, keyTime: Date,
                                    readers: (ttys: [Int32], shells: [ForegroundProcess])) -> ZeroExposurePasteResult {
    if let reason = canonicalLineRefusal(line, ttys: readers.ttys, atPasswordPrompt: false) {
        return .unavailable(reason)
    }
    guard !readers.shells.contains(where: { shellMayUseViMode(pid: $0.pid) }) else {
        return .unavailable(.viMode)
    }
    if readers.shells.contains(where: { fishMayExpandAbbreviation(pid: $0.pid, line: line) }) {
        return .unavailable(.shellAbbreviations)
    }
    guard KeystrokeTyper.canType(line, maxUnitsPerCharacter: typingChunkLimit(pid: target.pid)) else {
        return .unavailable(.noRoute)
    }
    guard InputSourceState.canTypeNow else {
        return .unavailable(.inputMethod)
    }
    if let watchers = keystrokeWatchersBlockingTyping(into: target.pid) {
        return .unavailable(.keystrokesWatched(watchers))
    }
    KeystrokeTyper.shared.type(line, into: target, keyTime: keyTime)
    return .typing
}

// JetBrains 的终端工具窗口：看不出焦点在哪个终端标签页，所以 IDE 里所有终端都停在 shell 提示符前时才键入，并且只键入单行文字
// （多行文字要靠 bracketed paste，IDE 的终端怎么处理按出来的 ESC 没法确认）
private func typeIntoIDETerminal(_ text: String, target: FocusedTarget, keyTime: Date) -> ZeroExposurePasteResult {
    let shells: [ForegroundProcess]
    let ttys: [Int32]
    switch target.terminalForeground {
    case .prompt(let found, let foundTTYs):
        shells = found
        ttys = foundTTYs
    case .other(let program):
        // 看不出焦点在哪个终端：有终端里的脚本在等单个按键时，第二次按下也不经过剪贴板
        if let groups = terminalForegroundGroups(of: target), groups.contains(where: groupWaitsForSingleKey) {
            return .unavailable(.singleKeyPrompt)
        }
        return .unavailable(.modalProgram(program))
    }
    // 有终端在等单个按键（zsh 的 read -q、bash 的 read -n 1）：键入的第一个字符就是回答
    if shells.contains(where: { waitsForSingleKey($0) }) {
        return .unavailable(.singleKeyPrompt)
    }
    guard let line = singleLineWithoutTrailingNewline(text) else {
        return .unavailable(.multiLine)
    }
    if let reason = canonicalLineRefusal(line, ttys: ttys, atPasswordPrompt: shells.isEmpty) {
        return .unavailable(reason)
    }
    // vi 键位的命令模式里原样键入的字母是命令；IDE 的终端怎么处理按出来的 ESC 没法确认，不能像别的终端那样包上 bracketed paste
    guard !shells.contains(where: { shellMayUseViMode(pid: $0.pid) }) else {
        return .unavailable(.viMode)
    }
    if shells.contains(where: { fishMayExpandAbbreviation(pid: $0.pid, line: line) }) {
        return .unavailable(.shellAbbreviations)
    }
    guard let role = target.role, axWritableRoles.contains(role),
          KeystrokeTyper.canType(line, maxUnitsPerCharacter: typingChunkLimit(pid: target.pid)) else {
        return .unavailable(.noRoute)
    }
    guard InputSourceState.canTypeNow else {
        return .unavailable(.inputMethod)
    }
    if let watchers = keystrokeWatchersBlockingTyping(into: target.pid) {
        return .unavailable(.keystrokesWatched(watchers))
    }
    KeystrokeTyper.shared.type(line, into: target, keyTime: keyTime)
    return .typing
}

// 代码编辑器（VS Code、JetBrains、网页里的 Monaco/CodeMirror）：只键入不会触发自动补全的单行文字
private func typeIntoCodeEditor(_ text: String, target: FocusedTarget, keyTime: Date) -> ZeroExposurePasteResult {
    guard let line = singleLineWithoutTrailingNewline(text) else {
        return .unavailable(.multiLine)
    }
    if hasVimEmulation(for: target) {
        return .unavailable(.modalProgram("Vim"))
    }
    guard isSafeForCodeEditor(line) else {
        return .unavailable(.unsafeCharacters)
    }
    // 编辑器的输入节点（隐藏的 textarea、EditContext、Java 的文本区域）
    guard let role = target.role, axWritableRoles.contains(role),
          KeystrokeTyper.canType(line, maxUnitsPerCharacter: typingChunkLimit(pid: target.pid)) else {
        return .unavailable(.noRoute)
    }
    guard InputSourceState.canTypeNow else {
        return .unavailable(.inputMethod)
    }
    if let watchers = keystrokeWatchersBlockingTyping(into: target.pid) {
        return .unavailable(.keystrokesWatched(watchers))
    }
    KeystrokeTyper.shared.type(line, into: target, keyTime: keyTime)
    return .typing
}

// Chrome 系浏览器、Electron App 的无障碍树没建好时认不出密码框。焦点所在的 App 正开着 Secure Input（多半是焦点在它的密码框里）时，
// 请它建好无障碍树再看焦点是不是真的在密码框里——只凭 Secure Input 的归属记录就打字不可靠（记录可能张冠李戴、残留，
// 见 SecureInputOwner），网页、App 里的单键快捷键会被触发
private func revealPasswordField(around target: FocusedTarget?) -> FocusedTarget? {
    guard let pid = target?.pid ?? NSWorkspace.shared.frontmostApplication?.processIdentifier, pid != getpid(),
          SecureInputOwner.pid == pid, isChromiumApp(pid: pid) else {
        return nil
    }
    let application = AXUIElementCreateApplication(pid)
    requestWebAccessibility(application)
    let deadline = Date().addingTimeInterval(min(0.25, max(0, (axBudgetRemaining ?? 0.35) - 0.1)))
    while true {
        if let element = asAXElement(copyAXAttribute(application, kAXFocusedUIElementAttribute)) {
            let candidate = FocusedTarget(element: element, pid: pid)
            if candidate.isSecureTextField {
                return candidate
            }
        }
        guard Date() < deadline, !axBudgetExhausted else {
            return nil
        }
        sleepAttentively(0.03)
    }
}

// 请 Chrome 系浏览器、Electron App 建好网页部分的无障碍树：问一下 App、焦点窗口和窗口里各个视图（网页视图）的角色就够了。
// 不写 AXManualAccessibility / AXEnhancedUserInterface：Chrome 不认前者；Electron App（VS Code 等）收到它们会进入"屏幕阅读器模式"，
// 一直慢下去（VS Code 还会关掉折叠、小地图）；后者还会干扰窗口动画、和窗口管理工具冲突
func requestWebAccessibility(_ application: AXUIElement) {
    // 主线程上受 Accessibility 时间预算限制（目标 App 卡住时不会拖住 ⌘V）
    _ = copyAXAttribute(application, kAXRoleAttribute)
    guard let window = asAXElement(copyAXAttribute(application, kAXFocusedWindowAttribute)) else {
        return
    }
    _ = copyAXAttribute(window, kAXRoleAttribute)
    guard let children = copyAXAttribute(window, kAXChildrenAttribute) as? [AnyObject] else {
        return
    }
    for child in children.prefix(8) {
        if let element = asAXElement(child) {
            _ = copyAXAttribute(element, kAXRoleAttribute)
        }
    }
}

// element 底下 depth 层以内有没有选中的文字（selectedOnly 为 false 时，有文本区域、网页内容也算）。最多看 60 个元素。
// 看不全时（读不到 element 自己的子元素、Accessibility 的时间预算用完）返回 nil
private func axSubtreeHasText(_ element: AXUIElement, depth: Int, selectedOnly: Bool) -> Bool? {
    var level = [element]
    var visited = 0
    for currentDepth in 0..<depth {
        var next: [AXUIElement] = []
        for parent in level {
            let children: [AnyObject]
            switch readAXAttribute(parent, kAXChildrenAttribute) {
            case .value(let value):
                children = value as? [AnyObject] ?? []
            case .none:
                children = []
            case .failed:
                // 读不到：要紧的是最上面那一层（下面的元素读不到就跳过）
                if currentDepth == 0 || axBudgetExhausted {
                    return nil
                }
                continue
            }
            for child in children {
                guard let child = asAXElement(child) else {
                    continue
                }
                visited += 1
                guard visited <= 60 else {
                    // 没看全：找选中的文字（图片上的实况文本）时当作不知道；文件管理器的图标视图本来就有很多项，当作没有文字
                    return selectedOnly ? nil : false
                }
                if let selected = copyAXAttribute(child, kAXSelectedTextAttribute) as? String, !selected.isEmpty {
                    return true
                }
                if !selectedOnly, let role = copyAXAttribute(child, kAXRoleAttribute) as? String,
                   role == kAXTextAreaRole || role == "AXWebArea" {
                    return true
                }
                next.append(child)
            }
        }
        level = next
    }
    return axBudgetExhausted ? nil : false
}

// 键入进行中（event tap 线程读）：这时用户按下的键都先不给 App，键入停下（见 GlobalMode 的 tap、KeystrokeTyper.post）。
// 回车会把聊天里打了一半的消息发出去、让 shell 和虚拟机执行打了一半的命令；别的键会夹进打到一半的文字里；Esc 是用户要它停下。
// ⌘X 之后只按一下退格删掉选中的文字：只扣下回车（会在删掉之前把消息发出去），别的键照常给 App（删除之前按下的，删除就不做了）。
// 删除从排上队起（还在等 ⌘ 松开、等前一次键入打完）就扣下回车，见 holdReturnForCut
enum TypingInterrupt {
    private static let lock = NSLock()
    private static var active = false
    // 回车以外的键也扣下
    private static var holdsAllKeys = true
    private static var returnPressed = false
    private static var escapePressed = false
    private static var otherKeyPressed = false
    // 吞掉的那个键可能还按着：之后它的自动重复也吞掉，直到用户松开它
    private static var heldKey: Int64?
    // ⌘C/⌘V 拦截器没在跑时（手动模式、拦截器没起来）键入期间临时起的、只管按键的 tap
    private static var keyTap: KeyTap?
    // 每次开始键入加一：之前安排的"过一会儿停掉临时 tap"据此知道 tap 又有人在用了
    private static var generation = 0
    // 排上队、还没开始（begin）的 ⌘X 删除：编号 → 这期间扣下过回车没有
    private static var pendingCuts: [Int: Bool] = [:]
    private static var lastCut = 0

    // 任意线程（键入队列）。holdsAllKeys 为 false 时只扣下回车（⌘X 的删除）。cut：这次删除排队时拿到的编号（见 holdReturnForCut），
    // 从这里接着扣下回车，排队期间扣下过的回车算在这次里
    static func begin(holdsAllKeys: Bool, cut: Int? = nil) {
        lock.lock()
        active = true
        self.holdsAllKeys = holdsAllKeys
        returnPressed = cut.flatMap { pendingCuts.removeValue(forKey: $0) } ?? false
        escapePressed = false
        otherKeyPressed = false
        heldKey = nil
        generation += 1
        lock.unlock()
        startKeyTapIfNeeded()
    }

    // 主线程：⌘X 的删除排上队之前调用，返回它的编号。从这时起回车（带着修饰键的也算）先不给 App：删除排着队时（等 ⌘ 松开、
    // 等前一次键入打完）按下的回车会在删掉之前把聊天里的消息连同要剪掉的文字发出去。回车照样记在硬件层的输入里，删除因此不做
    // （见 KeystrokeTyper.run 里的 userActedSince）。删除开始时由 begin 接手，没开始就放弃时要调用 releaseCutHold
    static func holdReturnForCut() -> Int {
        lock.lock()
        lastCut += 1
        let cut = lastCut
        pendingCuts[cut] = false
        lock.unlock()
        startKeyTapIfNeeded()
        return cut
    }

    // 任意线程：编号为 cut 的删除没开始就结束了（调用几次都行，begin 接手之后什么都不做）。返回排队期间扣下过回车没有
    @discardableResult
    static func releaseCutHold(_ cut: Int) -> Bool {
        lock.lock()
        let returnHeld = pendingCuts.removeValue(forKey: cut) ?? false
        let stopsTap = pendingCuts.isEmpty && !active && keyTap != nil
        let scheduled = generation
        lock.unlock()
        if stopsTap {
            stopTapLater(generation: scheduled, deadline: Date().addingTimeInterval(30))
        }
        return returnHeld
    }

    // 拦截器没在跑时起一个临时 tap；沿用之前的临时 tap：它可能已经被系统作废了，start() 会重建
    private static func startKeyTapIfNeeded() {
        let intercepting = GlobalMode.shared.isInterceptingKeys
        lock.lock()
        let existing = keyTap
        lock.unlock()
        if let existing {
            existing.start()
            return
        }
        guard !intercepting else {
            return
        }
        let tap = KeyTap(events: [.keyDown]) { event in
            event.getIntegerValueField(.eventSourceUserData) != copiSyntheticEventMarker
                && swallowKey(event.getIntegerValueField(.keyboardEventKeycode), isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
        }
        guard tap.start() else {
            return
        }
        // 主线程（holdReturnForCut）和键入队列（begin）可能同时起了一个：只留先记下的那个
        lock.lock()
        let duplicate = keyTap != nil
        if !duplicate {
            keyTap = tap
        }
        lock.unlock()
        if duplicate {
            tap.stop()
        }
    }

    static func end() {
        lock.lock()
        active = false
        let scheduled = generation
        let hasTap = keyTap != nil
        lock.unlock()
        // 临时的 tap 再留一会儿：吞掉还按着的键的自动重复，松开了再停
        if hasTap {
            stopTapLater(generation: scheduled, deadline: Date().addingTimeInterval(30))
        }
    }

    private static func stopTapLater(generation scheduled: Int, deadline: Date) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
            lock.lock()
            let held = heldKey
            lock.unlock()
            let keyHeld = held.map { CGEventSource.keyState(.hidSystemState, key: CGKeyCode($0)) } ?? false
            lock.lock()
            // 又开始键入了、有删除排着队：tap 还要用（之后的 end、releaseCutHold 会再安排）
            guard generation == scheduled, !active, pendingCuts.isEmpty else {
                lock.unlock()
                return
            }
            if keyHeld, Date() < deadline {
                lock.unlock()
                stopTapLater(generation: scheduled, deadline: deadline)
                return
            }
            heldKey = nil
            let tap = keyTap
            keyTap = nil
            lock.unlock()
            tap?.stop()
        }
    }

    // tap 线程：键入进行中时记下按了什么并返回 true（吞掉这个键），⌘X 的删除排着队时吞掉回车；之后还按着的这个键的自动重复也吞掉
    static func swallowKey(_ keyCode: Int64, isRepeat: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let isReturn = [Int64(kVK_Return), Int64(kVK_ANSI_KeypadEnter)].contains(keyCode)
        // 有 ⌘X 的删除排着队（见 holdReturnForCut）：回车不管带不带修饰键都先不给 App，记在排着的每个删除上
        let holdsForCut = isReturn && !pendingCuts.isEmpty
        if holdsForCut {
            pendingCuts = pendingCuts.mapValues { _ in true }
        }
        if active {
            if !holdsAllKeys, !isReturn {
                return false
            }
            if isReturn {
                returnPressed = true
            } else if keyCode == Int64(kVK_Escape) {
                escapePressed = true
            } else {
                otherKeyPressed = true
            }
            heldKey = keyCode
            return true
        }
        if holdsForCut {
            heldKey = keyCode
            return true
        }
        if let held = heldKey {
            if isRepeat, held == keyCode {
                return true
            }
            heldKey = nil
        }
        return false
    }

    static var returnWasPressed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return returnPressed
    }

    static var escapeWasPressed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return escapePressed
    }

    // 回车、Esc 以外的键
    static var otherKeyWasPressed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return otherKeyPressed
    }
}

// 从 time 到现在，用户有没有按过（或松开）修饰键（硬件层的记录，不含 Copi 合成的事件）。time 要在修饰键都松开之后
func modifierPressedSince(_ time: Date) -> Bool {
    CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .flagsChanged) < Date().timeIntervalSince(time)
}

// 从 keyTime（用户按下快捷键的时刻）到现在，用户有没有再按过别的键或点过鼠标。读的是硬件层的输入记录（不含 Copi 合成的事件），
// 不受 App 切换时机影响：⌘Tab 要等松开 ⌘ 才真正切换，光看焦点会来不及发现。
func userActedSince(_ keyTime: Date) -> Bool {
    let keyAge = Date().timeIntervalSince(keyTime)
    // 不算鼠标移动（那会让"用户没有操作"几乎永远不成立）；右键、其他键也算（右键菜单里的"拷贝"）
    let sinceLastAction = [CGEventType.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        .map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }
        .min() ?? .infinity
    return sinceLastAction < keyAge - 0.03
}

// 硬件层在 time（按下按键、松开鼠标的时刻）之前不到 0.25 秒（或者之后）记下过一次 type 这种输入：多半是用户亲手按的，可以算作
// "再按一次"的确认。只是推测：别的程序紧跟在用户自己的按键、点击之后发来的，以及经硬件层（HID）发来的点击、按键（键位重映射
// 工具、宏工具、Copi 自己的自测程序都这样发），也会被当成亲手按的
func hardwareInput(_ type: CGEventType, at time: Date) -> Bool {
    CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: type) < Date().timeIntervalSince(time) + 0.25
}

// Safari / WKWebView：WebKit 的 AXTextOperation。同步执行，走真正的编辑命令（派发 beforeinput/input，能 ⌘Z 撤销），
// 对 input、textarea、contenteditable 都有效；密码框的 text marker 被屏蔽，用不了。
// 必须用 TextOperationReplacePreserveCase：旧的 TextOperationReplace 会改动大小写。Safari 18.2 以前不认识这个类型，
// 会当成"选中"处理、原样返回选中的文字，据此判断不支持。
// 选区起点所在的元素或它往上几层（到网页根节点为止）可编辑
private func webSelectionIsEditable(_ markerRange: CFTypeRef, in element: AXUIElement) -> Bool {
    guard let start = copyAXParameterizedAttribute(element, "AXStartTextMarkerForTextMarkerRange", markerRange),
          let ownerRaw = copyAXParameterizedAttribute(element, "AXUIElementForTextMarker", start),
          CFGetTypeID(ownerRaw) == AXUIElementGetTypeID() else {
        return false
    }
    var node: AXUIElement? = (ownerRaw as! AXUIElement)
    for _ in 0..<8 {
        guard let current = node, !axBudgetExhausted else {
            return false
        }
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(current, kAXValueAttribute as CFString, &settable) == .success, settable.boolValue {
            return true
        }
        if (copyAXAttribute(current, kAXRoleAttribute) as? String) == "AXWebArea" {
            return false
        }
        node = asAXElement(copyAXAttribute(current, kAXParentAttribute))
    }
    return false
}

private func webKitTextOperation(_ text: String, into target: FocusedTarget) -> AXWriteResult {
    // WebKit 自己最多等 250ms：等不完它就不发，免得请求已经送达、Copi 却当作没写进去又补一次
    let timeout = min(0.4, axBudgetRemaining ?? 0.4)
    guard timeout >= 0.3, let markerRange = copyAXAttribute(target.element, "AXSelectedTextMarkerRange") else {
        return .notApplicable
    }
    // 选区要在可编辑的地方：焦点在列表行、卡片这类不能编辑的元素上时，WebKit 照样回报"替换了"，其实什么都没插进去，
    // Copi 却会说粘贴好了、吞掉 ⌘V。焦点控件可写就行；否则看选区起点所在的元素和它往上几层（焦点被工具栏按钮拿走、
    // 光标还在编辑器里时照样能用）
    guard target.isSettable(kAXValueAttribute) || webSelectionIsEditable(markerRange, in: target.element) else {
        return .notApplicable
    }
    let insert = target.role == kAXTextFieldRole ? normalizedForSingleLine(text) : text
    guard !insert.isEmpty else {
        return .notApplicable
    }
    let selectionBefore = target.selectedRange
    let parameters: NSDictionary = [
        "AXTextOperationMarkerRanges": [markerRange],
        "AXTextOperationType": "TextOperationReplacePreserveCase",
        "AXTextOperationReplacementString": insert,
        "AXTextOperationSmartReplace": false,
    ]
    AXUIElementSetMessagingTimeout(target.element, Float(timeout))
    let startedAt = DispatchTime.now()
    var result: CFTypeRef?
    let error = AXUIElementCopyParameterizedAttributeValue(target.element, "AXTextOperation" as CFString, parameters, &result)
    let elapsed = TimeInterval(DispatchTime.now().uptimeNanoseconds - startedAt.uptimeNanoseconds) / 1_000_000_000
    AXUIElementSetMessagingTimeout(target.element, 0.05)
    guard error == .success, let replaced = result as? [String], !replaced.isEmpty else {
        // 请求已经送达、只是迟迟没有结果（WebKit 自己 250ms 超时后返回空，操作稍后照样执行）：不能再走别的路
        if elapsed >= 0.2 || (error == .cannotComplete && elapsed >= timeout * 0.8) {
            notifyPasteUncertain(into: target)
            return .uncertain
        }
        return .notApplicable
    }
    guard replaced == [insert] else {
        return .notApplicable
    }
    // 替换了选中内容时，插入的文字会保持选中状态：把光标移到插入的文字末尾。位置用已知的值算——
    // 这时去读选区，读到的多半还是替换前的
    if let selectionBefore, selectionBefore.length > 0 {
        var caret = CFRange(location: selectionBefore.location + (insert as NSString).length, length: 0)
        if let caretValue = AXValueCreate(.cfRange, &caret) {
            AXUIElementSetAttributeValue(target.element, kAXSelectedTextRangeAttribute as CFString, caretValue)
        }
    }
    notifyProtected("Pasted safely")
    return .inserted
}

// 上一次改写 AXValue 还没确认生效时，不再拼接新的值（拼接用的旧值已经过时）
private var pendingChromiumWrite = false
// 上一次没能确认生效的写入：同一个输入框里再粘贴时，据此判断页面到底接不接受这种写入
private var unconfirmedChromiumWrite: (element: AXUIElement, oldValue: String, at: Date)?
// 确认不接受 AX 写入的输入框（例如代码编辑器的代理输入框）：之后直接走别的方式
private var chromiumWriteIgnored: (element: AXUIElement, at: Date)?
// Chromium 通过无障碍接口给出的字符串（包括值）最多 10000 字节（kMaxStringAttributeLength），更长的读到的是截断的，
// 拼接写回会删掉后面的内容；复制也只会复制到前面一截。截断时退到 UTF-8 字符的边界上，最多再少 3 个字节（截在一个 4 字节的字符中间）：
// 读到的值不到 9997 字节就一定是完整的，9997 字节及以上可能截断过，不可信
private let chromiumValueByteLimit = 9_997

// Firefox 的值没有长度上限（读到的不会被截断）
private let geckoValueByteLimit = 4_000_000

// Chrome 系浏览器、Electron、Firefox 里的 <input>/<textarea>：整体改写 AXValue。Chromium 会走页面自己的 SetValue，Firefox 走编辑器的
// "插入文字"（一次可撤销的编辑），都会派发 input 事件，React 等框架都能拿到新值。两者的写入都是异步生效的。
// 只能整值替换，所以先在选区处拼好新值，写完再把光标放回去。
// 不能用于 contenteditable（会变成 setInnerText、或者丢掉富文本格式），也不能用于代码编辑器的代理输入框。
// （Firefox 的 kAXSelectedText 写入有 bug：删除的范围不对，光标处插入会插到开头，所以不用它。）
private func spliceValue(_ text: String, into target: FocusedTarget, keyTime: Date, byteLimit: Int = chromiumValueByteLimit) -> AXWriteResult {
    if let ignored = chromiumWriteIgnored, CFEqual(ignored.element, target.element), Date().timeIntervalSince(ignored.at) < 600 {
        return .notApplicable
    }
    // 刚打过字、点过：时间预算够的话等浏览器的无障碍树跟上（等的时候新按键排在 Copi 后面到不了页面；点击照样会到，等完再查一次）。
    // 不等的话多行文字就只能第二次按下经过剪贴板
    let settle = 0.3 - InputActivity.secondsSinceLastInput
    if !pendingChromiumWrite, settle > 0, (axBudgetRemaining ?? 0) - settle >= 0.12 {
        sleepAttentively(settle + 0.01)
        if userActedSince(keyTime) {
            return .notApplicable
        }
    }
    // 浏览器的无障碍树要过一会儿才跟上页面：刚打过字、改过选区时读到的值和选区可能是旧的，拼出来会抹掉刚打的字
    guard !pendingChromiumWrite, InputActivity.secondsSinceLastInput >= 0.3,
          let role = target.role, target.isSettable(kAXValueAttribute),
          let selection = target.selectedRange, let length = target.numberOfCharacters,
          let oldValue = target.value, oldValue.utf8.count < byteLimit else {
        return .notApplicable
    }
    // 上次在这个输入框里写入后一直没看到变化，这次值还是原样：页面不接受这种写入
    if let last = unconfirmedChromiumWrite, CFEqual(last.element, target.element), Date().timeIntervalSince(last.at) < 10 {
        unconfirmedChromiumWrite = nil
        if oldValue == last.oldValue {
            chromiumWriteIgnored = (target.element, Date())
            return .notApplicable
        }
    }
    let old = oldValue as NSString
    guard old.length == length, selection.location >= 0, selection.length >= 0,
          selection.location + selection.length <= old.length else {
        return .notApplicable
    }
    // 隔一小会儿再读一次，两次一致才写（不一致说明页面还在变）
    sleepAttentively(0.03)
    guard target.value == oldValue, let selectionAgain = target.selectedRange,
          selectionAgain.location == selection.location, selectionAgain.length == selection.length else {
        return .notApplicable
    }
    // 已知限制：值里有落单的代理项（半个 emoji）时，Chromium 按严格 UTF-8 转换值失败，干脆不给值，AXValue 读出来是空的；
    // AXStringForRange 也取自这个值，没有别的信号能和真正的空输入框区分开。字符数不是 0 时，上面字符数对不上的检查会拦下；
    // 字符数也是 0、光标在开头、没有选中文字时，照样拼接会把整个输入框的内容换掉。不把读到的空值一律当作不可信：
    // 那样所有空输入框都只能键入（按键看得见，太长的文字和多行文字还会被拒绝）
    let insert = role == kAXTextAreaRole
        ? text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        : normalizedForSingleLine(text)
    let newValue = old.replacingCharacters(in: NSRange(location: selection.location, length: selection.length), with: insert)
    // 选中的内容和要粘贴的一样：什么都不用做
    if newValue == oldValue {
        return .inserted
    }
    let timeout = min(0.3, axBudgetRemaining ?? 0.3)
    guard timeout > 0.05 else {
        return .notApplicable
    }
    AXUIElementSetMessagingTimeout(target.element, Float(timeout))
    let startedAt = DispatchTime.now()
    let result = AXUIElementSetAttributeValue(target.element, kAXValueAttribute as CFString, newValue as CFTypeRef)
    let elapsed = TimeInterval(DispatchTime.now().uptimeNanoseconds - startedAt.uptimeNanoseconds) / 1_000_000_000
    AXUIElementSetMessagingTimeout(target.element, 0.05)
    switch result {
    case .success:
        break
    case .cannotComplete where elapsed >= timeout * 0.8:
        // 等到了超时：请求可能稍后才执行，照样确认
        break
    default:
        return .notApplicable
    }
    // 写入是异步生效的：稍后确认、把光标放回插入处。写入一旦发出就不再用别的方式补粘贴——
    // 页面只是慢的话，两种方式都会生效，变成粘贴两遍
    pendingChromiumWrite = true
    let caret = selection.location + (insert as NSString).length
    confirmChromiumValue(target, oldValue: oldValue, newValue: newValue, caret: caret, writtenAt: Date(), deadline: Date().addingTimeInterval(1.5))
    return .inserted
}

private func confirmChromiumValue(_ target: FocusedTarget, oldValue: String, newValue: String, caret: Int, writtenAt: Date, deadline: Date) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
        guard let current = target.value, current != oldValue else {
            if Date() < deadline {
                confirmChromiumValue(target, oldValue: oldValue, newValue: newValue, caret: caret, writtenAt: writtenAt, deadline: deadline)
                return
            }
            pendingChromiumWrite = false
            unconfirmedChromiumWrite = (target.element, oldValue, Date())
            notifyPasteUncertain(into: target)
            return
        }
        pendingChromiumWrite = false
        // SetValue 会把光标放到末尾。只在必要时（插入点不在末尾）、值正是我们写的、写入后用户没有再输入、焦点也还在时才移回去——
        // 设置选区会让 Chrome 把焦点拉回这个输入框，用户已经 Tab 到别处（例如密码框）时会把后面的输入抢过来
        if caret != (current as NSString).length, current == newValue,
           InputActivity.lastInput < writtenAt, target.isStillFocused {
            var range = CFRange(location: caret, length: 0)
            if let rangeValue = AXValueCreate(.cfRange, &range) {
                AXUIElementSetAttributeValue(target.element, kAXSelectedTextRangeAttribute as CFString, rangeValue)
            }
        }
        notifyProtected("Pasted safely")
    }
}

func notifyPasteUncertain(into target: FocusedTarget) {
    notifyCopiNotice("Copi couldn't confirm the paste into \(target.applicationName). Check whether the text arrived before pasting again.")
}

// MARK: - 0 暴露复制

// 在主线程、withAXBudget 之内调用。读不到时返回 nil。
// 读出的选中文字。droppedAttachments：选区里夹着图片等附件（辅助功能给的是占位符 U+FFFC），只保管了其中的文字——
// 附件不经过系统剪贴板就带不走
struct CopiedSelection {
    let text: String
    let droppedAttachments: Bool
}

func zeroExposureCopy(from target: FocusedTarget) -> String? {
    zeroExposureCopySelection(from: target)?.text
}

func zeroExposureCopySelection(from target: FocusedTarget) -> CopiedSelection? {
    guard !target.isSecureTextField else {
        return nil
    }
    let names = target.attributeNames
    let text: String?
    if let engine = target.webEngine(attributeNames: names) {
        text = readWebSelection(target, engine: engine)
    } else {
        // 原生控件（也包括终端）：直接读选中文字；万一是没带网页属性的网页节点，按网页处理
        guard let selected = target.selectedText else {
            return nil
        }
        text = target.hasWebAreaAncestor ? nil : selected
    }
    guard let text else {
        return nil
    }
    return copiedSelection(fromRaw: text)
}

// 选区里有图片等附件时，AX 拿到的只是占位符 U+FFFC：去掉占位符，只要还剩下文字就保管文字
func copiedSelection(fromRaw text: String) -> CopiedSelection? {
    guard !text.isEmpty else {
        return nil
    }
    guard text.contains("\u{FFFC}") else {
        return CopiedSelection(text: text, droppedAttachments: false)
    }
    let plain = text.replacingOccurrences(of: "\u{FFFC}", with: "")
    guard !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return nil
    }
    return CopiedSelection(text: plain, droppedAttachments: true)
}

private func readWebSelection(_ target: FocusedTarget, engine: WebEngine) -> String? {
    // 刚刚改过选区（拖选、⇧ 方向键、⌘A）时，浏览器的无障碍树要过一会儿才同步，太快去读会读到上一次的选区
    InputActivity.waitForSettledInput()
    // 代码编辑器、网页终端、Google Docs 只渲染可见部分，读出来的选区会被截断；认不出是什么的多行编辑区（Firefox）同理
    switch target.webEditorKind(engine: engine) {
    case .code?, .vimCode?, .terminal?, .wordProcessor?, .spreadsheet?:
        return nil
    case .unknown?:
        if target.role == kAXTextAreaRole {
            return nil
        }
    case nil:
        break
    }
    // 原子输入框里的选区：直接读选中文字（contenteditable 有子节点，不走这里——Chromium 会把它的段落粘成一行）
    if let role = target.role, axWritableRoles.contains(role), target.childCount == 0 {
        // Chromium 读出来的值最多 10000 字节，太长时不可信（见 chromiumValueByteLimit）
        if engine == .chromium, let value = target.value, value.utf8.count >= chromiumValueByteLimit {
            return nil
        }
        return target.selectedText
    }
    guard let markerRange = copyAXAttribute(target.element, "AXSelectedTextMarkerRange") else {
        return nil
    }
    switch engine {
    case .webKit:
        // WebKit 按复制时同样的方式遍历文字，段落之间的换行都在
        return copyAXParameterizedAttribute(target.element, "AXStringForTextMarkerRange", markerRange) as? String
    case .chromium:
        return paragraphPreservingString(target.element, markerRange: markerRange)
    case .gecko:
        return geckoSelectionString(target.element, markerRange: markerRange)
    }
}

// 逐段读网页选区（Chromium、Firefox）时最多走多少段：只防万一原地打转。真正的上限是调用方的 Accessibility 时间预算——
// 用完之后每一步都读不出来，照样返回 nil。之前固定是 200 段：一篇长文章、⌘A 全选的网页往往有几百段，预算还剩很多时就被拒绝复制了
private let maxSelectionParagraphs = 20_000

// Firefox：选区文字不带段落分隔（"<p>A</p><p>B</p>" 读出来是 "AB"），只有 <br> 是换行。它没有 AXNextParagraphEnd…，
// 用 AXParagraphTextMarkerRangeForTextMarker 一段一段往后走，再用换行拼起来。逐段读出的文字拼在一起必须正好等于整段读出的文字，
// 对不上（或者哪一段读不出来）就不猜，返回 nil——宁可这次复制不了，也不能把段落粘在一起的文字当成复制结果。
// Firefox 给出的选区是最近一次选区变化事件里记下的，所以要在用户选择之前就打开它的无障碍树（见 WebAccessibilityWarmer）。
private func geckoSelectionString(_ element: AXUIElement, markerRange rawRange: CFTypeRef) -> String? {
    guard CFGetTypeID(rawRange) == AXTextMarkerRangeGetTypeID() else {
        return nil
    }
    let selection = rawRange as! AXTextMarkerRange
    var whole = copyAXParameterizedAttribute(element, "AXStringForTextMarkerRange", selection) as? String
    if whole?.isEmpty ?? true, (textLength(element, selection) ?? 0) > 0, (axBudgetRemaining ?? 0) > 0.15 {
        // 第一次读文字时 Firefox 可能还在异步准备文字缓存，稍等再读一次
        sleepAttentively(0.08)
        whole = copyAXParameterizedAttribute(element, "AXStringForTextMarkerRange", selection) as? String
    }
    guard let whole, !whole.isEmpty else {
        return nil
    }
    let end = AXTextMarkerRangeCopyEndMarker(selection)
    var cursor = AXTextMarkerRangeCopyStartMarker(selection)
    guard let endIndex = markerIndex(element, end), var cursorIndex = markerIndex(element, cursor), cursorIndex < endIndex else {
        return nil
    }
    var paragraphs: [String] = []
    for _ in 0..<maxSelectionParagraphs {
        guard let paragraphRaw = copyAXParameterizedAttribute(element, "AXParagraphTextMarkerRangeForTextMarker", cursor),
              CFGetTypeID(paragraphRaw) == AXTextMarkerRangeGetTypeID() else {
            return nil
        }
        let paragraphEnd = AXTextMarkerRangeCopyEndMarker(paragraphRaw as! AXTextMarkerRange)
        guard let paragraphEndIndex = markerIndex(element, paragraphEnd) else {
            return nil
        }
        let reachedEnd = paragraphEndIndex >= endIndex
        // 每一步都必须往后走，免得在段落边界上原地打转
        guard reachedEnd || paragraphEndIndex > cursorIndex,
              let part = copyAXParameterizedAttribute(element, "AXStringForTextMarkerRange",
                                                      AXTextMarkerRangeCreate(kCFAllocatorDefault, cursor, reachedEnd ? end : paragraphEnd)) as? String else {
            return nil
        }
        paragraphs.append(part)
        if reachedEnd {
            guard paragraphs.joined() == whole else {
                return nil
            }
            let nonEmpty = paragraphs.filter { !$0.isEmpty }
            var result = ""
            for (index, paragraph) in nonEmpty.enumerated() {
                result += paragraph
                // 段落末尾已经是 <br> 带来的换行时不再补
                if index < nonEmpty.count - 1, !paragraph.hasSuffix("\n") {
                    result += "\n"
                }
            }
            return result
        }
        cursor = paragraphEnd
        cursorIndex = paragraphEndIndex
    }
    // 段落太多
    return nil
}

private func markerIndex(_ element: AXUIElement, _ marker: AXTextMarker) -> Int? {
    (copyAXParameterizedAttribute(element, "AXIndexForTextMarker", marker) as? NSNumber)?.intValue
}

// Chromium 整段读出的选区文字不带段落分隔（AXRange::GetText 默认 kWithoutParagraphBreaks："A\nB" 读出来是 "AB"），
// 这里一段一段读出来再用换行拼起来。下一段从上一段的结尾直接开始读：之前从段落结尾往后再挪一个字符
// （AXNextTextMarkerForTextMarker）当作跳过段落之间的换行，可整段文字里并没有换行，挪过去的是下一段的第一个字——每段丢一个字；
// 选区末尾是图标、按钮这类嵌入对象时还会挪到一个无效的位置上，整次复制被拒绝。
// 网页脚本设的选区起点落在元素边界上（例如紧挨表单控件、可编辑区）时，从起点找段落结尾原地不动：只在这时把起点换成紧跟着的第一个字的开头再走（见循环末尾）。
// 逐段读出的文字连在一起必须正好等于整段读出的文字，对不上就不猜，返回 nil
private func paragraphPreservingString(_ element: AXUIElement, markerRange rawRange: CFTypeRef) -> String? {
    guard CFGetTypeID(rawRange) == AXTextMarkerRangeGetTypeID() else {
        return nil
    }
    let selection = rawRange as! AXTextMarkerRange
    // Chromium 的选区是"起点到焦点"，从后往前选时顺序是反的，先整理成正序
    let unordered = [AXTextMarkerRangeCopyStartMarker(selection), AXTextMarkerRangeCopyEndMarker(selection)] as CFArray
    guard let orderedRaw = copyAXParameterizedAttribute(element, "AXTextMarkerRangeForUnorderedTextMarkers", unordered),
          CFGetTypeID(orderedRaw) == AXTextMarkerRangeGetTypeID() else {
        return nil
    }
    let ordered = orderedRaw as! AXTextMarkerRange
    let first = AXTextMarkerRangeCopyStartMarker(ordered)
    let last = AXTextMarkerRangeCopyEndMarker(ordered)
    guard let total = textLength(element, ordered), total > 0 else {
        return nil
    }
    var paragraphs: [String] = []
    // 每一段的结尾（落在这一段自己的文字里），用来认出它在表格的哪一格
    var paragraphEnds: [AXTextMarker] = []
    var cursor = first
    var consumed = 0
    var reachedEnd = false
    // 选区起点换过一次（见循环末尾）
    var reanchored = false
    for _ in 0..<maxSelectionParagraphs {
        // 下一个段落结尾。确定没有了（已经是网页里最后一段）时，剩下的部分就是最后一段；出错、超时就不猜
        var paragraphEnd: AXTextMarker?
        switch readAXParameterizedAttribute(element, "AXNextParagraphEndTextMarkerForTextMarker", cursor) {
        case .value(let value) where CFGetTypeID(value) == AXTextMarkerGetTypeID():
            paragraphEnd = (value as! AXTextMarker)
        case .none:
            paragraphEnd = nil
        default:
            return nil
        }
        // 只量这一段的长度（不从选区开头重新量），累计起来判断有没有到选区末尾
        var paragraphLength: Int?
        if let end = paragraphEnd {
            guard let length = textLength(element, AXTextMarkerRangeCreate(kCFAllocatorDefault, cursor, end)) else {
                return nil
            }
            paragraphLength = length
            // 一个字都没走过：可能是 Chromium 走到网页末尾时给的空位置（问它什么都问不出来），这也是没有下一个段落结尾
            if length == 0 {
                switch readAXParameterizedAttribute(element, "AXIndexForTextMarker", end) {
                case .value:
                    break
                case .none:
                    paragraphEnd = nil
                    paragraphLength = nil
                case .failed:
                    return nil
                }
            }
        }
        // 换了起点之后第一次找就说"后面没有段落结尾"：不信，否则整个选区会被当成一段，段落粘在一起
        if reanchored, consumed == 0, paragraphLength == nil {
            return nil
        }
        reachedEnd = paragraphLength.map { consumed + $0 >= total } ?? true
        let stop = reachedEnd ? last : paragraphEnd!
        guard let paragraph = copyAXParameterizedAttribute(element, "AXStringForTextMarkerRange",
                                                           AXTextMarkerRangeCreate(kCFAllocatorDefault, cursor, stop)) as? String else {
            return nil
        }
        paragraphs.append(paragraph)
        paragraphEnds.append(stop)
        if reachedEnd {
            break
        }
        guard let paragraphLength, let paragraphEnd else {
            return nil
        }
        // 没有往前走：网页脚本设的选区起点落在元素边界上时会这样，Chromium 从这个起点找段落结尾原地不动。
        // 只在选区起点、只换一次，而且这一段读出来确实是空的（不然拼的时候会在它后面多出一个换行）：换成紧跟着的第一个字的开头，
        // 两处之间一个字都没有才换；换了还是不动就不猜，不原地打转。换了起点也不会多读、少读字：逐段读出的文字仍然必须正好等于从原来的起点整段读出的文字
        if paragraphLength == 0 {
            guard consumed == 0, !reanchored, paragraph.isEmpty,
                  let start = nextCharacterStart(element, cursor) ?? childStart(element, cursor, last: last, total: total) else {
                return nil
            }
            reanchored = true
            cursor = start
            continue
        }
        consumed += paragraphLength
        cursor = paragraphEnd
    }
    // 走了这么多段还没到选区末尾，或者逐段读出的文字和整段的对不上：交给回退路径
    guard reachedEnd,
          let whole = copyAXParameterizedAttribute(element, "AXStringForTextMarkerRange", ordered) as? String,
          paragraphs.joined() == whole else {
        return nil
    }
    // 段落末尾（或开头）已经是 <br> 带来的换行时不再补；空段落不留空行
    let kept = zip(paragraphs, paragraphEnds).filter { !$0.0.isEmpty }
    let nonEmpty = kept.map(\.0)
    // 表格里同一行相邻的两格之间用 Tab（和浏览器自己复制的一样，粘贴进电子表格还是一行一行的）。要么每一段都认完，要么都不认
    let cells = tableCells(element, kept.map(\.1))
    var result = ""
    for (index, paragraph) in nonEmpty.enumerated() {
        result += paragraph
        if index < nonEmpty.count - 1, !paragraph.hasSuffix("\n"), !nonEmpty[index + 1].hasPrefix("\n") {
            if let cells, let this = cells[index], let next = cells[index + 1], !CFEqual(this.cell, next.cell), CFEqual(this.row, next.row) {
                result += "\t"
            } else {
                result += "\n"
            }
        }
    }
    return result
}

// 每个位置所在的表格单元格和它所在的行（不在表格里为 nil）。Accessibility 的时间预算快用完、读不出来时整个返回 nil
private func tableCells(_ element: AXUIElement, _ markers: [AXTextMarker]) -> [(cell: AXUIElement, row: AXUIElement)?]? {
    // 很长的选区（整页全选）不认：每段要多问好几次，复制会变慢
    guard markers.count <= 300 else {
        return nil
    }
    var cells: [(cell: AXUIElement, row: AXUIElement)?] = []
    for marker in markers {
        guard (axBudgetRemaining ?? 1) > 0.15,
              let ownerRaw = copyAXParameterizedAttribute(element, "AXUIElementForTextMarker", marker),
              CFGetTypeID(ownerRaw) == AXUIElementGetTypeID() else {
            return nil
        }
        var node: AXUIElement? = (ownerRaw as! AXUIElement)
        var found: (cell: AXUIElement, row: AXUIElement)?
        for _ in 0..<4 {
            guard let current = node else {
                break
            }
            let role = copyAXAttribute(current, kAXRoleAttribute) as? String
            if role == kAXCellRole {
                if let row = asAXElement(copyAXAttribute(current, kAXParentAttribute)) {
                    found = (current, row)
                }
                break
            }
            if role == kAXRowRole || role == kAXTableRole || role == "AXWebArea" {
                break
            }
            node = asAXElement(copyAXAttribute(current, kAXParentAttribute))
        }
        cells.append(found)
    }
    return cells
}

// marker 后面紧跟着的第一个字的开头：往后挪一个字，再往前挪一个字。marker 和它之间一个字都没有时才返回，否则不猜
private func nextCharacterStart(_ element: AXUIElement, _ marker: AXTextMarker) -> AXTextMarker? {
    guard let nextRaw = copyAXParameterizedAttribute(element, "AXNextTextMarkerForTextMarker", marker),
          CFGetTypeID(nextRaw) == AXTextMarkerGetTypeID(),
          let startRaw = copyAXParameterizedAttribute(element, "AXPreviousTextMarkerForTextMarker", nextRaw),
          CFGetTypeID(startRaw) == AXTextMarkerGetTypeID() else {
        return nil
    }
    let start = startRaw as! AXTextMarker
    guard textLength(element, AXTextMarkerRangeCreate(kCFAllocatorDefault, marker, start)) == 0 else {
        return nil
    }
    return start
}

// 选区起点是"某个元素的第几个子元素之前"（网页脚本用 selectNodeContents、setBaseAndExtent(元素, 0, …) 设的选区）时，Chromium 从它
// 往后挪一个字原地不动，再往前挪却跑到网页开头（nextCharacterStart 因此不换）。改用起点所在元素的子元素：从子元素的开头到选区
// 末尾的文字，子元素越靠后越少，第一个正好等于整个选区的那个，它的开头就是选区里第一个字的位置（前面的子元素没有字也一样）。
// 对不上就不猜；换了起点之后逐段读出的文字仍然必须正好等于从原来的起点整段读出的文字（见 paragraphPreservingString）
private func childStart(_ element: AXUIElement, _ marker: AXTextMarker, last: AXTextMarker, total: Int) -> AXTextMarker? {
    guard let ownerRaw = copyAXParameterizedAttribute(element, "AXUIElementForTextMarker", marker),
          CFGetTypeID(ownerRaw) == AXUIElementGetTypeID(),
          let children = copyAXAttribute(ownerRaw as! AXUIElement, kAXChildrenAttribute) as? [AnyObject] else {
        return nil
    }
    // 起点在很靠后的子元素前面时要一个个量过去：最多看 64 个
    for child in children.prefix(64) {
        guard CFGetTypeID(child) == AXUIElementGetTypeID(),
              let rangeRaw = copyAXParameterizedAttribute(element, "AXTextMarkerRangeForUIElement", child),
              CFGetTypeID(rangeRaw) == AXTextMarkerRangeGetTypeID() else {
            return nil
        }
        let start = AXTextMarkerRangeCopyStartMarker(rangeRaw as! AXTextMarkerRange)
        guard let remaining = textLength(element, AXTextMarkerRangeCreate(kCFAllocatorDefault, start, last)) else {
            return nil
        }
        if remaining == total {
            return start
        }
        if remaining < total {
            return nil
        }
    }
    return nil
}

private func textLength(_ element: AXUIElement, _ range: AXTextMarkerRange) -> Int? {
    (copyAXParameterizedAttribute(element, "AXLengthForTextMarkerRange", range) as? NSNumber)?.intValue
}

// 最近一次键盘输入、可能改变选区的操作（鼠标松开、⇧ 方向键、⌘A……）的时间：浏览器的无障碍树要过一会儿才跟上
enum InputActivity {
    private static let lock = NSLock()
    private static var lastInputAt = Date.distantPast

    // 任意线程可用
    static func noteInput() {
        lock.lock()
        lastInputAt = Date()
        lock.unlock()
    }

    static var secondsSinceLastInput: TimeInterval {
        Date().timeIntervalSince(lastInput)
    }

    static var lastInput: Date {
        lock.lock()
        defer { lock.unlock() }
        return lastInputAt
    }

    // 主线程：距离上次输入不到 0.15 秒时等一等
    static func waitForSettledInput() {
        let settle: TimeInterval = 0.15
        let elapsed = secondsSinceLastInput
        if elapsed < settle {
            sleepAttentively(min(settle - elapsed, axBudgetRemaining ?? settle))
        }
    }
}

// MARK: - 模拟键入

// 把文字"打"进当前焦点：每个按键事件带上要输入的字符（和密码管理器的自动填充一样），全程不碰剪贴板。
// 绑定到用户按下粘贴快捷键时的那个输入框：开始前和每打一块之前都确认焦点还在那里、用户也没有再按别的键或点鼠标，
// 否则就停下——免得把内容（往往是密码）打进别的 App 或别的输入框。
final class KeystrokeTyper {
    static let shared = KeystrokeTyper()

    // 每个事件最多带 20 个 UTF-16 单元，多了会被系统悄悄截掉
    static let chunkLimit = 20

    // 换行按哪个键
    enum NewlineKey {
        // 多行输入框、聊天框（单独的 ↩ 往往是发送）
        case shiftReturn
        // Google Sheets 的单元格
        case commandReturn
        // 终端（bracketed paste 里面）
        case plainReturn
    }

    private enum Action {
        case type(String, NewlineKey)
        // 终端里的多行粘贴：ESC[200~ + 文字（换行按 ↩、Tab 按 ⇥）+ ESC[201~
        case typeBracketedPaste(String)
        // 虚拟机、远程桌面：真实的按键（键位 + ⇧）
        case pressKeys([KeyStroke])
        // ⌘X：选中的文字已经存进安全剪贴板，再按一次退格把它删掉
        case deleteSelection
    }

    private struct Job {
        let action: Action
        let target: FocusedTarget
        let keyTime: Date
        // 逐字符发送（分格验证码：每输一位，焦点会自动跳到同一进程里的下一个输入框）
        let perCharacter: Bool
        // 每个按键事件最多带几个 UTF-16 单元（见 typingChunkLimit）
        let maxUnitsPerEvent: Int
        // ⌘X 的删除：排队时扣下回车拿到的编号（见 TypingInterrupt.holdReturnForCut）
        var cutHold: Int? = nil
        // ⌘X 的删除（Chromium、Electron）：复制时选区的样子（见 selectionFingerprint）。删除前选区变了就不删
        var cutSelection: String? = nil

        var isCut: Bool {
            if case .deleteSelection = action {
                return true
            }
            return false
        }
    }

    private enum Chunk {
        case text(units: [UniChar], characterCount: Int)
        // 换行用 ⇧↩：聊天框里单独的 ↩ 是发送，⇧↩ 在各种编辑器、多行输入框里都是换行
        case newline
        // Google Sheets 单元格里的换行 ⌘↩
        case commandReturn
        // 终端 bracketed paste 里用的 ↩、⇥、esc
        case plainReturn
        case tab
        case escape
        case deleteBackward

        var characterCount: Int {
            switch self {
            case .text(_, let count):
                return count
            case .newline, .commandReturn, .plainReturn, .tab:
                return 1
            case .escape, .deleteBackward:
                return 0
            }
        }
    }

    // 一次键入打在哪里
    private struct TypingSpot {
        let pid: pid_t
        let element: AXUIElement
        // 分格验证码：焦点会自己跳到同一进程里的下一格，只看进程
        let anyFieldInApp: Bool

        // element 为 nil（读不到焦点控件）时只看进程
        func covers(pid: pid_t, element: AXUIElement?) -> Bool {
            guard self.pid == pid else {
                return false
            }
            guard let element, !anyFieldInApp else {
                return true
            }
            return CFEqual(self.element, element)
        }
    }

    private let queue = DispatchQueue(label: "Copi.KeystrokeTyper", qos: .userInteractive)
    // 只在 queue 上用：这次键入因为途中有程序开始看按键而停下时，那些程序的名字
    private var watchersStoppedTyping: [String]?
    // 只在 queue 上用：这次键入开始的时刻（修饰键已经都松开了）
    private var typingStartedAt = Date.distantPast
    private var pending: [Job] = []
    private var isTyping = false
    // 只在主线程用：正在往哪里发按键（开始发之前设上，发完或停下时清掉；⌘X 的删除不算）
    private var typingSpot: TypingSpot?
    // 只在主线程用：最近一次打到一半就停下的粘贴打在哪里、什么时候停的
    private var stoppedPartway: (spot: TypingSpot, at: Date)?

    // 统一换行：\r\n、\r 都当作一个换行
    static func normalizedNewlines(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    // 能用键入完成的文字：不含制表符等控制字符（Tab 会切换焦点），换行只在 allowNewlines 时可以有；
    // 也不含单个字符就超过一个按键事件能带的 UTF-16 单元数的组合（会被截断，见 typingChunkLimit）。不限长度：
    // 长的打得久一些，键入时屏幕上显示进度（见 CopiHUD），按 Esc 停下
    static func canType(_ text: String, allowNewlines: Bool = false, allowTabs: Bool = false, maxUnitsPerCharacter: Int = chunkLimit) -> Bool {
        guard !text.isEmpty else {
            return false
        }
        if text.unicodeScalars.contains(where: {
            $0.properties.generalCategory == .control && !(allowNewlines && $0 == "\n") && !(allowTabs && $0 == "\t")
        }) {
            return false
        }
        return !text.contains { $0.utf16.count > maxUnitsPerCharacter }
    }

    // 主线程调用。先等用户松开修饰键（刚按下的 ⌘V 的 ⌘ 往往还按着，会把字符变成快捷键）。
    func type(_ text: String, into target: FocusedTarget, keyTime: Date, perCharacter: Bool = false, bracketedPaste: Bool = false,
              newlineKey: NewlineKey = .shiftReturn) {
        enqueue(Job(action: bracketedPaste ? .typeBracketedPaste(text) : .type(text, newlineKey), target: target, keyTime: keyTime,
                    perCharacter: perCharacter, maxUnitsPerEvent: typingChunkLimit(pid: target.pid)))
    }

    // 主线程调用：在虚拟机、远程桌面里逐个按键
    func pressKeys(_ strokes: [KeyStroke], into target: FocusedTarget, keyTime: Date) {
        enqueue(Job(action: .pressKeys(strokes), target: target, keyTime: keyTime, perCharacter: false, maxUnitsPerEvent: Self.chunkLimit))
    }

    // 主线程调用：删除焦点控件里选中的内容（⌘X）。从排上队起就扣下回车（见 TypingInterrupt.holdReturnForCut）：这时 ⌘X 还在
    // event tap 那里等着处理完，排在它后面的回车也拦得到
    func deleteSelection(in target: FocusedTarget, keyTime: Date) {
        enqueue(Job(action: .deleteSelection, target: target, keyTime: keyTime, perCharacter: false, maxUnitsPerEvent: Self.chunkLimit,
                    cutHold: TypingInterrupt.holdReturnForCut(),
                    cutSelection: isChromiumApp(pid: target.pid) ? Self.selectionFingerprint(target) : nil))
    }

    // 主线程：选区的样子（输入框里是起点和长度，可编辑区里是选中的字数）。Chromium 的无障碍树是异步更新的：⌘X 时读出、存进 Copi 的
    // 可能是还没跟上的旧选区，按出的退格删的却是真正的选区，多出来的那部分就丢了。删除前再读一次，不一样就不删
    static func selectionFingerprint(_ target: FocusedTarget) -> String? {
        if target.childCount == 0, let range = target.selectedRange {
            return "\(range.location):\(range.length)"
        }
        guard let markerRange = copyAXAttribute(target.element, "AXSelectedTextMarkerRange"),
              let length = copyAXParameterizedAttribute(target.element, "AXLengthForTextMarkerRange", markerRange) as? NSNumber else {
            return nil
        }
        return "m:\(length.intValue)"
    }

    // 主线程：要粘贴进 pid 的 element（nil：读不到焦点控件，只看 App）时，Copi 是不是还在往那里键入上一次粘贴，或者上一次粘贴
    // 刚刚（keyTime 之前 2 秒内）在那里打到一半停下了。键入途中再按 ⌘V：⌘ 一按下键入就停了（和按别的键一样，见 post），
    // 这时再粘贴一遍，那里就成了半段加一整段。还在等修饰键松开、还没开始发按键的不算：新的这次按键会让它自己放弃（见 run），
    // 这次照常粘贴
    func isTypingOrJustStopped(into pid: pid_t, element: AXUIElement?, keyTime: Date) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        if let spot = typingSpot, spot.covers(pid: pid, element: element) {
            return true
        }
        if let stopped = stoppedPartway, keyTime.timeIntervalSince(stopped.at) < 2, stopped.spot.covers(pid: pid, element: element) {
            return true
        }
        return false
    }

    private func enqueue(_ job: Job) {
        dispatchPrecondition(condition: .onQueue(.main))
        pending.append(job)
        // 放到下一轮再开始：调用方可能还在 Accessibility 的时间预算里，焦点检查不该受它限制
        DispatchQueue.main.async { [self] in
            startNextIfIdle()
        }
    }

    private func startNextIfIdle() {
        guard !isTyping, !pending.isEmpty else {
            return
        }
        isTyping = true
        let job = pending.removeFirst()
        waitForModifiersReleased(deadline: Date().addingTimeInterval(0.8)) { [self] released in
            guard released else {
                let appName = job.target.applicationName
                // ⌘X 的删除排着队时扣下过回车：那个回车也没给 App
                let returnHeld = job.cutHold.map(TypingInterrupt.releaseCutHold) ?? false
                notifyCopiNotice(job.isCut
                    ? "Copi copied the text but didn't delete it from \(appName) because keys were still held down"
                        + (returnHeld ? ", and didn't send the Return you pressed. Check the field before sending." : ".")
                    : "Copi didn't type the paste into \(appName) because keys were still held down. Press ⌘V again.")
                finishJob(job)
                return
            }
            // 稍等一下再检查：⌘Tab 这类操作在松开 ⌘ 的那一刻才生效。输入源刚切换过（包括焦点进入密码框时系统强制切到英文）
            // 要等它在目标 App 里生效
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [self] in
                // 拼音等输入法开着（密码框除外，系统会自己切到英文）：临时切到英文键盘布局再打，打完切回去。
                // 拼音正在组字（有未上屏的拼音）时不切：切走会留下一个关不掉的候选窗、输入框也会卡住
                // 终端的"安全键盘输入"不限定输入源（只有密码框会被系统强制切到英文），照常切换
                if !job.isCut, !job.target.isSecureTextField, SecureInputOwner.pid != job.target.pid || job.target.isTerminalApp,
                   !InputSourceState.isASCIIKeyboardLayoutActive, InputSourceSwitcher.shared.isEnabled {
                    if job.target.hasMarkedText {
                        notifyCopiNotice("Finish or cancel what you're typing with the input method in \(job.target.applicationName), then press ⌘V again.")
                        finishJob(job)
                        return
                    }
                    InputSourceSwitcher.shared.switchToASCII { [self] switched in
                        guard let switched else {
                            run(job, inputSourceReady: false)
                            return
                        }
                        run(job, inputSourceReady: true, switched: switched)
                    }
                    return
                }
                waitForASCIIInputSource(unless: job.isCut, deadline: Date().addingTimeInterval(0.5)) { [self] ready in
                    run(job, inputSourceReady: ready)
                }
            }
        }
    }

    // 主线程：最后确认一遍，然后在后台队列上发出按键。switched：为这次键入临时切换了输入源，打完（或放弃时）要切回去
    private func run(_ job: Job, inputSourceReady: Bool, switched: InputSourceSwitcher.Switch? = nil) {
        let appName = job.target.applicationName
        // 打字前的字符数：切回输入法之前据此确认目标 App 已经处理完打进去的字
        let lengthBefore = switched == nil ? nil : job.target.numberOfCharacters
        let finish = { [self] (typedChunks: Int) in
            guard let switched else {
                finishJob(job)
                return
            }
            // 等目标 App 处理完排队的按键再切回去，否则最后几个字会被输入法拿去组字。虚拟机、远程桌面直接选回去：它们捕获键盘时
            // 系统快捷键不起作用，模拟的 ⌃空格 会被转发进客户机；它们也不经过这台 Mac 的输入法
            let pressesKeys: Bool = {
                if case .pressKeys = job.action {
                    return true
                }
                return false
            }()
            InputSourceSwitcher.shared.restore(switched, directly: pressesKeys, consumed: { done in
                Self.waitUntilConsumed(job.target, lengthBefore: lengthBefore, typedChunks: typedChunks, then: done)
            }) { [self] in
                finishJob(job)
            }
        }
        guard inputSourceReady else {
            notifyCopiNotice("Copi didn't type the paste into \(appName) because it couldn't switch away from the current input method. Switch to ABC or U.S. and press ⌘V again.")
            finish(0)
            return
        }
        let selectionChanged = job.cutSelection.map { $0 != Self.selectionFingerprint(job.target) } ?? false
        guard !userActedSince(job.keyTime), !selectionChanged, Self.focusMatches(job) else {
            if !job.isCut {
                notifyCopiNotice("Copi didn't type the paste into \(appName) because the focus or your input changed. Press ⌘V again.")
            } else if job.cutHold.map(TypingInterrupt.releaseCutHold) == true {
                // 删除排着队时扣下过回车：那个回车也没给 App
                notifyCopiNotice("Copi copied the text but didn't delete it from \(appName) because you pressed Return before it could, and didn't send that Return. Check the field before sending.")
            } else {
                notifyCopiNotice("Copi copied the text but didn't delete it from \(appName) because the focus or your input changed.")
            }
            finish(0)
            return
        }
        let chunks: [Chunk]
        switch job.action {
        case .type(let text, let newlineKey):
            chunks = job.perCharacter
                ? text.map { .text(units: Array(String($0).utf16), characterCount: 1) }
                : Self.chunks(of: text, limit: job.maxUnitsPerEvent, newlineKey: newlineKey)
        case .typeBracketedPaste(let text):
            chunks = [.escape] + Self.chunks(of: "[200~", limit: job.maxUnitsPerEvent)
                + Self.chunks(of: text, limit: job.maxUnitsPerEvent, newlineKey: .plainReturn)
                + Self.bracketedPasteEnd(limit: job.maxUnitsPerEvent)
        case .deleteSelection:
            chunks = [.deleteBackward]
        case .pressKeys(let strokes):
            chunks = strokes.map { .text(units: Array($0.character.utf16), characterCount: 1) }
        }
        // 临时切到英文之后、开始打字之前（等它稳定的那一小会儿）用户又切回了输入法：这时的切换通知已经处理过，
        // 下面的检查发现不了，所以在这里再确认一次
        if switched != nil, !InputSourceState.isASCIIKeyboardLayoutActive, !job.isCut {
            notifyCopiNotice("Copi didn't type the paste into \(appName) because the input method changed. Press ⌘V again.")
            finish(0)
            return
        }
        let inputSourceGeneration = InputSourceState.changeGeneration
        // 记下正在往哪里键入：打完之前又要粘贴进这里的，不粘贴（见 isTypingOrJustStopped）
        let spot = TypingSpot(pid: job.target.pid, element: job.target.element, anyFieldInApp: job.perCharacter)
        if !job.isCut {
            typingSpot = spot
        }
        // 要打一阵子的：屏幕上显示进度和"按 Esc 停下"
        let progressGeneration = !job.isCut && Self.expectedDuration(of: job, chunks: chunks.count) > 1.5
            ? CopiHUD.shared.showProgress(appName: appName, total: chunks.count) : nil
        let progress: ((Int) -> Void)? = progressGeneration.map { generation in
            { done in
                DispatchQueue.main.async {
                    CopiHUD.shared.update(done, generation: generation)
                }
            }
        }
        // ⌘X 的删除前的字符数（原生控件）：Backspace 按出去不等于删掉了（Xcode 的 Vim 模式里它只是左移光标），删完确认字数少了
        // 才说剪切好了。网页（Chromium、Electron）的字符数更新得晚、有上限，不确认
        let cutLengthBefore = job.isCut && !job.target.isWebContent ? job.target.numberOfCharacters : nil
        queue.async { [self] in
            var unclosedBracket = false
            var openBracketLeft = false
            let completed: Int
            // ⌘X 的删除：由这里接着扣下排队时就扣下的回车
            TypingInterrupt.begin(holdsAllKeys: !job.isCut, cut: job.cutHold)
            defer { TypingInterrupt.end() }
            typingStartedAt = Date()
            if case .pressKeys(let strokes) = job.action {
                completed = pressKeys(strokes, for: job, progress: progress)
            } else if case .typeBracketedPaste = job.action {
                completed = post(chunks, for: job, inputSourceGeneration: inputSourceGeneration,
                                 closing: Self.bracketedPasteEnd(limit: job.maxUnitsPerEvent).count, unclosed: &unclosedBracket,
                                 leftOpen: &openBracketLeft, progress: progress)
            } else {
                completed = post(chunks, for: job, inputSourceGeneration: inputSourceGeneration, progress: progress)
            }
            let needsClosing = unclosedBracket
            // 停在 bracketed paste 中间、焦点已经离开，没能补发结束标记（见 post）：shell 会一直把之后的按键当成粘贴的内容
            let stuck = openBracketLeft ? " If the shell in \(appName) stops responding, press Control-C." : ""
            // 没打完：是不是因为途中有程序开始看按键（见 post）、用户按了回车、Esc 或者别的键
            let watchers = completed < chunks.count ? watchersStoppedTyping : nil
            watchersStoppedTyping = nil
            let returnPressed = TypingInterrupt.returnWasPressed
            let escapePressed = TypingInterrupt.escapeWasPressed
            let otherKeyPressed = TypingInterrupt.otherKeyWasPressed
            DispatchQueue.main.async {
                if let progressGeneration {
                    CopiHUD.shared.hide(generation: progressGeneration)
                }
                if !job.isCut {
                    self.typingSpot = nil
                    // 打到一半停下了：紧接着又要粘贴进这里的也不粘贴，免得接在打出来的半段后面
                    if completed > 0, completed < chunks.count {
                        self.stoppedPartway = (spot, Date())
                    }
                }
                if returnPressed, completed < chunks.count, job.isCut {
                    notifyCopiNotice("Copi copied the text but didn't delete it from \(appName) because you pressed Return before it could, and didn't send that Return. Check the field before sending.")
                } else if returnPressed, completed < chunks.count {
                    notifyCopiNotice("Copi stopped typing into \(appName) because you pressed Return before it finished, and didn't send that Return. Check the field before sending." + stuck)
                } else if returnPressed, !job.isCut {
                    notifyCopiNotice("Copi held back a Return you pressed while it was finishing typing into \(appName). Press Return again if you meant to send it.")
                } else if escapePressed, completed < chunks.count {
                    notifyCopiNotice((completed == 0
                        ? "You stopped Copi with Esc before it typed anything into \(appName)."
                        : "You stopped Copi with Esc, so it typed only part of the paste into \(appName). Check the field before pasting again.") + stuck)
                } else if otherKeyPressed, completed < chunks.count {
                    notifyCopiNotice((completed == 0
                        ? "Copi didn't type the paste into \(appName) because you pressed a key, and kept that key from reaching \(appName). Press ⌘V again."
                        : "Copi stopped typing into \(appName) because you pressed a key, and kept that key from reaching \(appName) so it didn't land in the middle of the paste. Check the field before pasting again.") + stuck)
                } else if (escapePressed || otherKeyPressed), !job.isCut {
                    notifyCopiNotice("Copi held back a key you pressed while it was finishing typing into \(appName), so it didn't land in the paste. Press it again if you need it.")
                } else if let watchers {
                    let names = ListFormatter.localizedString(byJoining: Array(watchers.prefix(3)))
                    notifyCopiNotice((completed == 0
                        ? "Copi didn't type the paste into \(appName) because \(names) can now see keystrokes."
                        : "Copi stopped typing the paste into \(appName) because \(names) started watching keystrokes. Check the field before pasting again.") + stuck)
                } else if job.isCut {
                    if completed == chunks.count, let cutLengthBefore {
                        Self.confirmCut(job.target, lengthBefore: cutLengthBefore, deletedAt: Date())
                    } else if completed == chunks.count {
                        notifyProtected("Cut safely")
                    } else {
                        notifyCopiNotice("Copi copied the text but didn't delete it from \(appName) because the focus or your input changed.")
                    }
                } else if completed == chunks.count {
                    notifyProtected("Pasted safely")
                } else if completed == 0 {
                    notifyCopiNotice("Copi didn't type the paste into \(appName) because the focus moved or you kept typing. Press ⌘V again.")
                } else {
                    // 不说打了几个字：通知会留在通知中心里，密码的长度也不该透露
                    notifyCopiNotice("Copi typed only part of the paste into \(appName) before the focus or input method changed. Check the field before pasting again." + stuck)
                }
                if needsClosing {
                    self.closeBracketedPaste(job) {
                        finish(completed)
                    }
                } else {
                    finish(completed)
                }
            }
        }
    }

    // 主线程：bracketed paste 键入到一半时用户切换了输入法。先临时切到英文，再补发结束标记（否则 shell 一直停在粘贴状态，
    // 之后的按键都当成粘贴的内容），然后切回用户刚选的输入法
    private func closeBracketedPaste(_ job: Job, then done: @escaping () -> Void) {
        let appName = job.target.applicationName
        // 用户关掉了临时切换输入源（或者没有英文键盘布局）：不切，只提示
        guard InputSourceSwitcher.shared.isEnabled else {
            notifyCopiNotice("The input method changed while Copi was typing into \(appName). If the shell stops responding, press Control-C.")
            done()
            return
        }
        InputSourceSwitcher.shared.switchToASCII { [self] switched in
            guard let switched else {
                notifyCopiNotice("The input method changed while Copi was typing into \(appName). If the shell stops responding, press Control-C.")
                done()
                return
            }
            queue.async { [self] in
                let focused = Self.focusMatches(job)
                if focused {
                    let source = CGEventSource(stateID: .privateState)
                    for chunk in Self.bracketedPasteEnd(limit: job.maxUnitsPerEvent) {
                        emit(chunk, source: source, to: job.target.pid)
                        usleep(2_000)
                    }
                }
                DispatchQueue.main.async {
                    // 焦点已经离开终端：没能补发
                    if !focused {
                        notifyCopiNotice("The input method changed while Copi was typing into \(appName). If the shell stops responding, press Control-C.")
                    }
                    InputSourceSwitcher.shared.restore(switched, consumed: { finished in
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            finished(())
                        }
                    }, then: done)
                }
            }
        }
    }

    // 主线程：等目标 App 处理完打进去的字——字符数变了并且稳定 50 毫秒；读不到字符数（终端、密码框）时按发出的按键数估一个时间
    private static func waitUntilConsumed(_ target: FocusedTarget, lengthBefore: Int?, typedChunks: Int, then done: @escaping (()) -> Void) {
        // 打得多的，目标 App 要处理一阵子：最多等 10 秒
        let fallback = typedChunks == 0 ? 0 : min(10, max(0.3, 0.15 + Double(typedChunks) * 0.004))
        guard typedChunks > 0, let lengthBefore else {
            DispatchQueue.main.asyncAfter(deadline: .now() + fallback) {
                done(())
            }
            return
        }
        let deadline = Date().addingTimeInterval(fallback)
        var lastLength = lengthBefore
        var stableSince = Date()
        func poll() {
            let length = target.numberOfCharacters ?? lengthBefore
            if length != lastLength {
                lastLength = length
                stableSince = Date()
            }
            if (length != lengthBefore && Date().timeIntervalSince(stableSince) >= 0.05) || Date() >= deadline {
                done(())
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.015, execute: poll)
        }
        poll()
    }

    // 主线程：等当前输入源变成英文键盘布局，到期还不是就放弃（skip 为 true 时不用等，例如 ⌘X 只按退格）
    private func waitForASCIIInputSource(unless skip: Bool, deadline: Date, then action: @escaping (Bool) -> Void) {
        if skip || InputSourceState.isSettledASCIIKeyboardLayout {
            action(true)
            return
        }
        if Date() >= deadline {
            action(false)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [self] in
            waitForASCIIInputSource(unless: skip, deadline: deadline, then: action)
        }
    }

    // job 做完或放弃了。⌘X 的删除没开始就放弃时，放开排队时扣下的回车（开始过的已经由 begin 接手，这里什么都不做）
    private func finishJob(_ job: Job) {
        if let cut = job.cutHold {
            TypingInterrupt.releaseCutHold(cut)
        }
        isTyping = false
        startNextIfIdle()
    }

    // 等修饰键全部松开；到期还按着就放弃（用户多半在按别的组合键，例如 ⌘Tab 切换器还开着）
    private func waitForModifiersReleased(deadline: Date, then action: @escaping (Bool) -> Void) {
        let held = CGEventSource.flagsState(.combinedSessionState).intersection([.maskCommand, .maskShift, .maskControl, .maskAlternate])
        if held.isEmpty {
            action(true)
            return
        }
        if Date() >= deadline {
            action(false)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [self] in
            waitForModifiersReleased(deadline: deadline, then: action)
        }
    }

    // 大概要打多久（秒）：一般每块两三毫秒加上焦点检查，逐字符的每个 20 毫秒，虚拟机里的真实按键每个几十毫秒
    private static func expectedDuration(of job: Job, chunks: Int) -> TimeInterval {
        if case .pressKeys = job.action {
            return Double(chunks) * 0.045
        }
        return Double(chunks) * (job.perCharacter ? 0.022 : 0.004)
    }

    // bracketed paste 的结束标记：ESC 用真正的 esc 键（文字事件里的 ESC 会被有的终端改写或丢掉）
    private static func bracketedPasteEnd(limit: Int) -> [Chunk] {
        [.escape] + chunks(of: "[201~", limit: limit)
    }

    // 按字符（不拆开 emoji、组合字符）切成每块不超过 limit 个 UTF-16 单元（一个字符本身超过时单独成块），换行单独成块
    // newlineKey：换行按哪个键。终端里（bracketed paste 里面）换行按 ↩、Tab 按 ⇥，shell 把它们原样插入
    private static func chunks(of text: String, limit: Int, newlineKey: NewlineKey = .shiftReturn) -> [Chunk] {
        let terminal = newlineKey == .plainReturn
        var chunks: [Chunk] = []
        var current: [UniChar] = []
        var characters = 0
        func flush() {
            if !current.isEmpty {
                chunks.append(.text(units: current, characterCount: characters))
                current = []
                characters = 0
            }
        }
        for character in text {
            if character == "\n" {
                flush()
                switch newlineKey {
                case .shiftReturn:
                    chunks.append(.newline)
                case .commandReturn:
                    chunks.append(.commandReturn)
                case .plainReturn:
                    chunks.append(.plainReturn)
                }
                continue
            }
            if terminal, character == "\t" {
                flush()
                chunks.append(.tab)
                continue
            }
            let units = Array(String(character).utf16)
            if current.count + units.count > limit {
                flush()
            }
            current.append(contentsOf: units)
            characters += 1
        }
        flush()
        return chunks
    }

    // 在后台队列上依次发出按键事件，块与块之间稍作停顿，免得目标 App 的事件队列来不及处理而丢字。
    // 每块之前都确认焦点还在目标上、用户没有接着操作；返回实际发出去的块数。
    // closing：结尾的这几块（bracketed paste 的 ESC[201~）。中途放弃时如果焦点还在终端上，照样补发它们结束粘贴——
    // 否则 shell 会一直把之后的按键当成粘贴的内容。输入源已经不是英文时不能直接补发（文字会进输入法），
    // 把 unclosed 设为 true，由调用方先切到英文再补发。焦点已经不在终端上时补发的按键会到达别处，不补发，
    // 把 leftOpen 设为 true，由调用方告诉用户
    // progress：每发出一些块报一次已经发出的块数（显示进度用）
    private func post(_ chunks: [Chunk], for job: Job, inputSourceGeneration: Int, closing: Int = 0, progress: ((Int) -> Void)? = nil) -> Int {
        var unclosed = false
        var leftOpen = false
        return post(chunks, for: job, inputSourceGeneration: inputSourceGeneration, closing: closing, unclosed: &unclosed, leftOpen: &leftOpen,
                    progress: progress)
    }

    private func post(_ chunks: [Chunk], for job: Job, inputSourceGeneration: Int, closing: Int, unclosed: inout Bool, leftOpen: inout Bool,
                      progress: ((Int) -> Void)? = nil) -> Int {
        let source = CGEventSource(stateID: .privateState)
        var completed = 0
        var reportedAt = Date()
        // 上一块是 ESC：bracketed paste 的标记（ESC[200~、ESC[201~）要紧接着发完，中间不做检查也不停顿——隔得久了，shell、vim 会把
        // ESC 当成单独按了一下 Esc（zsh 的 KEYTIMEOUT、vim 的 ttimeoutlen 可能只有几十毫秒）
        var followsEscape = false
        for (index, chunk) in chunks.enumerated() {
            if followsEscape {
                followsEscape = false
                emit(chunk, source: source, to: job.target.pid)
                completed += 1
                usleep(2_000)
                continue
            }
            if let progress, Date().timeIntervalSince(reportedAt) >= 0.1 {
                progress(completed)
                reportedAt = Date()
            }
            // 中途切换了输入法（快捷键、工具切换、焦点进出密码框）：接下来的字符可能被输入法拿去。
            // 打开了 "Don't Type When Keystrokes Are Watched"、途中有程序装上了能看到按键的 tap：停下（tap 清单缓存 1 秒）
            let watchers = job.isCut ? nil : keystrokeWatchersBlockingTyping(into: job.target.pid, fresh: true)
            if watchers != nil {
                watchersStoppedTyping = watchers
            }
            // 用户接着操作了（包括只按修饰键：连按两下 ⌥ 呼出的输入框、⌘ 切换器）、按了回车。焦点检查要和目标 App 来回通信、
            // 可能要好一阵：发出去之前最后再看一眼
            let interrupted = { userActedSince(job.keyTime) || modifierPressedSince(self.typingStartedAt) || TypingInterrupt.returnWasPressed }
            if interrupted() || !Self.focusMatches(job) || InputSourceState.changeGeneration != inputSourceGeneration
                || watchers != nil || sessionIsLockedNow() || interrupted() {
                if closing > 0, index > 0, index < chunks.count {
                    if Self.focusMatches(job) {
                        let ascii = InputSourceState.changeGeneration == inputSourceGeneration
                            || DispatchQueue.main.sync { InputSourceState.isASCIIKeyboardLayoutActive }
                        if ascii {
                            for tail in chunks[max(index, chunks.count - closing)...] {
                                emit(tail, source: source, to: job.target.pid)
                                usleep(2_000)
                            }
                        } else {
                            unclosed = true
                        }
                    } else {
                        leftOpen = true
                    }
                }
                return completed
            }
            emit(chunk, source: source, to: job.target.pid)
            completed += 1
            InputActivity.noteInput()
            if case .escape = chunk {
                followsEscape = true
                continue
            }
            usleep(job.perCharacter ? 20_000 : 2_000)
        }
        return completed
    }

    // pid：键入的目标 App。打开 "Type Privately" 时直接发给它（CGEventPostToPid：只经过专门盯着这个 App 的 tap，全系统的键盘 tap
    // 看不到）；否则发在带注解的会话层（之后的 tap 都看得到）
    private func emit(_ chunk: Chunk, source: CGEventSource?, to pid: pid_t) {
        for keyDown in [true, false] {
            let keyCode: CGKeyCode
            switch chunk {
            case .text:
                keyCode = 0
            case .newline, .commandReturn, .plainReturn:
                keyCode = CGKeyCode(kVK_Return)
            case .tab:
                keyCode = CGKeyCode(kVK_Tab)
            case .escape:
                keyCode = CGKeyCode(kVK_Escape)
            case .deleteBackward:
                keyCode = CGKeyCode(kVK_Delete)
            }
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown) else {
                continue
            }
            switch chunk {
            case .text(let units, _):
                // 清掉所有修饰键：残留的 ⇧/⌘ 会让字符变样或变成快捷键
                event.flags = []
                units.withUnsafeBufferPointer { buffer in
                    event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
                }
            case .newline:
                event.flags = .maskShift
            case .commandReturn:
                event.flags = .maskCommand
            case .plainReturn, .tab, .escape, .deleteBackward:
                event.flags = []
            }
            // 不打标记：发在带注解的会话层或者直接发给目标 App，Copi 的按键拦截器（会话层）都看不到它，用不着
            if Defaults[.typePrivately] {
                event.postToPid(pid)
            } else {
                event.post(tap: .cgAnnotatedSessionEventTap)
            }
        }
    }

    // 后台队列：在虚拟机、远程桌面里逐个按键。它们按 flagsChanged 事件判断 ⇧ 有没有按着（只在按键事件上带 ⇧ 标记不够），
    // 所以真的按下、松开 ⇧ 键，并且 ⇧ 前后、按键之间稍作停顿（太快会丢键或者被当成按住不放、自动重复）。返回按下的键数
    private func pressKeys(_ strokes: [KeyStroke], for job: Job, progress: ((Int) -> Void)? = nil) -> Int {
        let source = CGEventSource(stateID: .privateState)
        // 左 ⇧ 的设备位（NX_DEVICELSHIFTKEYMASK）：有的客户端按它判断是按下还是松开
        let shiftFlags = CGEventFlags(rawValue: CGEventFlags.maskShift.rawValue | 0x2)
        func emit(_ event: CGEvent?) {
            guard let event else {
                return
            }
            event.setIntegerValueField(.eventSourceUserData, value: copiSyntheticEventMarker)
            // 发到会话层（不是带注解的那一层）：虚拟机可能在会话层截取键盘
            event.post(tap: .cgSessionEventTap)
        }
        var shiftDown = false
        func setShift(_ down: Bool) {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Shift), keyDown: down)
            event?.type = .flagsChanged
            event?.flags = down ? shiftFlags : []
            emit(event)
            shiftDown = down
        }
        // 不管怎么结束都要松开 ⇧，否则客户机里 ⇧ 会一直按着
        defer {
            if shiftDown {
                usleep(30_000)
                setShift(false)
            }
        }
        var completed = 0
        var reportedAt = Date()
        for stroke in strokes {
            if let progress, Date().timeIntervalSince(reportedAt) >= 0.1 {
                progress(completed)
                reportedAt = Date()
            }
            let watchers = keystrokeWatchersBlockingTyping(into: job.target.pid, postedAt: .cgSessionEventTap, fresh: true)
            if watchers != nil {
                watchersStoppedTyping = watchers
            }
            if userActedSince(job.keyTime) || modifierPressedSince(typingStartedAt) || !Self.focusMatches(job) || watchers != nil
                || TypingInterrupt.returnWasPressed || sessionIsLockedNow() {
                return completed
            }
            if stroke.shift != shiftDown {
                usleep(50_000)
                setShift(stroke.shift)
                usleep(50_000)
                // 按 ⇧ 前后各等了 50 毫秒：这期间用户可能点到了别处
                if userActedSince(job.keyTime) || modifierPressedSince(typingStartedAt) || TypingInterrupt.returnWasPressed
                    || !Self.focusMatches(job) {
                    return completed
                }
            }
            for keyDown in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: stroke.keyCode, keyDown: keyDown)
                event?.flags = shiftDown ? shiftFlags : []
                // 同时带上字符：用 Unicode 方式转发键盘的客户端（Windows App 的 Unicode 模式等）认这个
                var units = Array(stroke.character.utf16)
                event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
                emit(event)
                usleep(keyDown ? 12_000 : 30_000)
            }
            completed += 1
            InputActivity.noteInput()
        }
        return completed
    }

    // 系统报告的键盘焦点是否仍是这个输入框（任意线程可用）。不用 NSWorkspace：Spotlight 这类浮动面板拿着焦点时，
    // 前台 App 是下面那个。只在有明确证据（换了进程、换了元素）时才算不是；读不到时稍后重试一次。
    // 主线程：⌘X 按出 Backspace 之后确认字符数少了。用户之后又打了字就不下结论
    private static func confirmCut(_ target: FocusedTarget, lengthBefore: Int, deletedAt: Date, deadline: Date = Date().addingTimeInterval(1.2)) {
        if let length = target.numberOfCharacters, length < lengthBefore {
            notifyProtected("Cut safely")
            return
        }
        if InputActivity.lastInput > deletedAt {
            notifyCopiNotice("Copi copied the text, but isn't sure it was deleted from \(target.applicationName). Check before cutting again.")
            return
        }
        guard Date() < deadline else {
            notifyCopiNotice("Copi copied the text but couldn't delete it in \(target.applicationName). Delete it yourself if you meant to cut it.")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            confirmCut(target, lengthBefore: lengthBefore, deletedAt: deletedAt, deadline: deadline)
        }
    }

    private static func focusMatches(_ job: Job) -> Bool {
        for attempt in 0..<2 {
            if attempt > 0 {
                usleep(30_000)
            }
            var value: CFTypeRef?
            let focused: AXUIElement
            if AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &value) == .success,
               let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
                focused = value as! AXUIElement
            } else {
                // 系统查不到焦点（Brave 在最前面时会报 kAXErrorNoValue）：和 focusedTarget() 一样退回激活的 App，但只认目标 App 自己、
                // 只认它报出的焦点正是目标控件。密码框还要系统记下的 Secure Input 正是它开的（排除系统的认证窗口拿着键盘）
                guard NSWorkspace.shared.runningApplications.first(where: { $0.isActive })?.processIdentifier == job.target.pid else {
                    return false
                }
                if job.target.isSecureTextField, SecureInputOwner.pid != job.target.pid {
                    continue
                }
                var appValue: CFTypeRef?
                guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(job.target.pid), kAXFocusedUIElementAttribute as CFString, &appValue) == .success,
                      let appValue, CFGetTypeID(appValue) == AXUIElementGetTypeID() else {
                    continue
                }
                focused = appValue as! AXUIElement
            }
            var focusedPID: pid_t = 0
            guard AXUIElementGetPid(focused, &focusedPID) == .success, focusedPID == job.target.pid else {
                return false
            }
            if CFEqual(focused, job.target.element) {
                return true
            }
            // 分格验证码：焦点自动跳到了同一进程里的下一个单行输入框
            if job.perCharacter {
                var role: CFTypeRef?
                return AXUIElementCopyAttributeValue(focused, kAXRoleAttribute as CFString, &role) == .success
                    && (role as? String) == kAXTextFieldRole
            }
            return false
        }
        return false
    }

}

// Copi 在屏幕下方显示的小窗口：要打一阵子的键入显示打到哪里了、按 Esc 停下；要用户再按一次确认的提醒也显示在这里——系统通知可能被
// 关掉、被勿扰模式挡住，这里一定看得到。不激活 Copi、拿不到焦点（按键要一直打在原来的输入框里），鼠标点不到（点击会让键入停下），
// 也不出现在屏幕共享和录屏里。不显示复制的文字
final class CopiHUD {
    static let shared = CopiHUD()

    private let width: CGFloat = 420
    private var panel: NSPanel?
    private let label = NSTextField(wrappingLabelWithString: "")
    private let bar = NSProgressIndicator()
    // 每次显示加一：晚到的更新、隐藏不影响后来的那一次
    private var generation = 0

    // 主线程：显示键入的进度。返回这一次的编号
    func showProgress(appName: String, total: Int) -> Int {
        dispatchPrecondition(condition: .onQueue(.main))
        bar.minValue = 0
        bar.maxValue = Double(max(total, 1))
        bar.doubleValue = 0
        return present("Copi is typing into \(appName). Press Esc to stop.", showsBar: true)
    }

    // 显示一段说明，seconds 秒后自己消失（任意线程：不在主线程时排到主线程上）
    func showMessage(_ text: String, seconds: TimeInterval) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [self] in
                showMessage(text, seconds: seconds)
            }
            return
        }
        let shown = present(text, showsBar: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.hide(generation: shown)
        }
    }

    func update(_ done: Int, generation: Int) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard generation == self.generation else {
            return
        }
        bar.doubleValue = Double(done)
    }

    func hide(generation: Int) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard generation == self.generation else {
            return
        }
        panel?.orderOut(nil)
    }

    private func present(_ text: String, showsBar: Bool) -> Int {
        generation += 1
        let panel = self.panel ?? makePanel()
        self.panel = panel
        label.stringValue = text
        bar.isHidden = !showsBar
        panel.contentView?.layoutSubtreeIfNeeded()
        let height = max(44, (panel.contentView?.fittingSize.height ?? 62))
        panel.setContentSize(NSSize(width: width, height: height))
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens.first
        if let visible = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: visible.midX - width / 2, y: visible.minY + 80))
        }
        panel.orderFrontRegardless()
        return generation
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 62), styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.sharingType = .none
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
        // 深色的 HUD 底：浅色外观下文字也要是浅色的
        panel.appearance = NSAppearance(named: .darkAqua)
        let background = NSVisualEffectView(frame: panel.contentLayoutRect)
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true
        background.autoresizingMask = [.width, .height]
        label.font = .systemFont(ofSize: 13)
        label.preferredMaxLayoutWidth = width - 32
        bar.style = .bar
        bar.isIndeterminate = false
        let stack = NSStackView(views: [label, bar])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.detachesHiddenViews = true
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            bar.widthAnchor.constraint(equalToConstant: width - 32),
            label.widthAnchor.constraint(equalToConstant: width - 32),
        ])
        panel.contentView = background
        return panel
    }
}

// 当前输入源是不是 ASCII 键盘布局（ABC、U.S. 等）。是拼音、日文这类输入法时，模拟键入的字符会被输入法拿去组字，
// 而且会先经过输入法进程——这本身就是一种暴露。不在后台临时切换输入法：切回中日韩输入法时菜单栏变了、App 实际的输入却常常没变，
// 切过去也要过一会儿才在目标 App 里生效，期间键入的字符照样进了输入法。
// TIS 接口只能在主线程调用。
enum InputSourceState {
    // 最近一次切换输入源的时间：刚切换时系统记录的输入源已经变了，目标 App 却可能还在用原来的
    private static var lastChangeAt = Date.distantPast
    private static let generationLock = NSLock()
    private static var generation = 0

    static func noteChange() {
        dispatchPrecondition(condition: .onQueue(.main))
        lastChangeAt = Date()
        generationLock.lock()
        generation += 1
        generationLock.unlock()
    }

    // 每切换一次输入源加一（任意线程可读）：键入途中据此发现输入源变了
    static var changeGeneration: Int {
        generationLock.lock()
        defer { generationLock.unlock() }
        return generation
    }

    // 刚切换完、还没在目标 App 里生效的也算（键入前由 isSettledASCIIKeyboardLayout 再等一等）
    static var isASCIIKeyboardLayoutActive: Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let typePointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceType),
              let asciiPointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsASCIICapable) else {
            return false
        }
        let type = Unmanaged<CFString>.fromOpaque(typePointer).takeUnretainedValue() as String
        let isASCIICapable = CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(asciiPointer).takeUnretainedValue())
        return type == (kTISTypeKeyboardLayout as String) && isASCIICapable
    }

    // 现在能不能键入：是英文键盘布局，或者可以临时切过去（见 InputSourceSwitcher）
    static var canTypeNow: Bool {
        isASCIIKeyboardLayoutActive || InputSourceSwitcher.shared.isEnabled
    }

    // 是英文键盘布局，并且已经切换过来一会儿了
    static var isSettledASCIIKeyboardLayout: Bool {
        Date().timeIntervalSince(lastChangeAt) > 0.25 && isASCIIKeyboardLayoutActive
    }

    // 当前输入源的名字（例如"简体拼音"），用在提示里
    static var currentName: String? {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let namePointer = TISGetInputSourceProperty(source, kTISPropertyLocalizedName) else {
            return nil
        }
        return Unmanaged<CFString>.fromOpaque(namePointer).takeUnretainedValue() as String
    }
}

// MARK: - 临时切换到英文输入源

// 拼音等输入法开着时，模拟键入的字符会被输入法拿去组字（也会先经过输入法进程）。键入前临时切到英文键盘布局（ABC 等），打完切回去：
//  - 切过去：从后台程序选中英文布局一向可靠，但要过一会儿才在目标 App 里生效——等系统报告切换完成后再稍等一下才打字；
//  - 切回来：从后台程序直接选中中日韩输入法有个老问题（菜单栏变了、App 实际的输入却没变，直到切换焦点）。所以优先模拟系统的
//    "选择上一个输入源"快捷键（默认 ⌃空格），和用户自己按快捷键走同一条路；它关掉了就按"下一个输入源"快捷键轮过去，
//    两个都关掉了才直接选中（并提示用户）。每一步都确认结果。
// TIS 接口只能在主线程调用。
final class InputSourceSwitcher {
    static let shared = InputSourceSwitcher()

    struct Switch {
        let original: TISInputSource
        let originalID: String
        let targetID: String
        // 原来的是中日韩这类输入法（不是键盘布局）：只能用快捷键切回去
        let originalIsInputMethod: Bool
    }

    // 系统报告切换完成并稳定之后，再等这么久才开始打字
    private let settleDelay: TimeInterval = 0.2
    // 发快捷键用的后台队列（按键之间要停顿，不能卡主线程）
    private let hotKeyQueue = DispatchQueue(label: "Copi.InputSourceHotKey", qos: .userInteractive)

    // 主线程：开着这个功能，并且有可以切过去的英文键盘布局。切回中日韩输入法优先用系统的输入源快捷键，都关掉了也能切（见 restore）
    var isEnabled: Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        return Defaults[.switchInputSourceForTyping] && asciiTarget() != nil
    }

    // 为什么不能切（给提示用）；能切时为 nil
    var unavailableReason: String? {
        dispatchPrecondition(condition: .onQueue(.main))
        guard Defaults[.switchInputSourceForTyping] else {
            return "Switch to ABC or U.S. and press ⌘V again, or turn on \"Switch to ABC While Typing\" in Copi."
        }
        guard asciiTarget() != nil else {
            return "Add the ABC or U.S. keyboard in System Settings › Keyboard › Input Sources so Copi can switch to it."
        }
        return nil
    }

    // 主线程：切到英文键盘布局，等它生效后回调；切不过去时回调 nil
    func switchToASCII(then completion: @escaping (Switch?) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        let isInputMethod = Self.currentIsInputMethod
        guard let original = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(), let originalID = Self.sourceID(of: original),
              let target = asciiTarget(), let targetID = Self.sourceID(of: target) else {
            completion(nil)
            return
        }
        let generationBefore = InputSourceState.changeGeneration
        guard TISSelectInputSource(target) == noErr else {
            completion(nil)
            return
        }
        let switched = Switch(original: original, originalID: originalID, targetID: targetID, originalIsInputMethod: isInputMethod)
        // 等系统报告的输入源变成目标、并稳定 30 毫秒，也等 Copi 自己收到切换通知（不然键入途中才到的通知会被当成又切换了）
        let deadline = Date().addingTimeInterval(0.3)
        var stableSince: Date?
        func poll() {
            if Self.currentSourceID() == targetID {
                stableSince = stableSince ?? Date()
            } else {
                stableSince = nil
            }
            let stable = stableSince.map { Date().timeIntervalSince($0) >= 0.03 } ?? false
            if stable, InputSourceState.changeGeneration != generationBefore {
                DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay) {
                    completion(switched)
                }
                return
            }
            guard Date() < deadline else {
                // 系统报告已经切过去了、只是没收到通知：照样可以打
                if stable {
                    DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay) {
                        completion(switched)
                    }
                } else {
                    restore(switched, consumed: { $0(()) }) {
                        completion(nil)
                    }
                }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01, execute: poll)
        }
        poll()
    }

    // 主线程：等目标 App 处理完打进去的字（consumed 回调 done 的时候），再切回原来的输入源
    func restore(_ switched: Switch, directly: Bool = false, consumed: @escaping (@escaping (()) -> Void) -> Void,
                 then completion: @escaping () -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        consumed { [self] _ in
            // 用户这期间自己换了输入源：不动
            guard Self.currentSourceID() == switched.targetID else {
                completion()
                return
            }
            guard switched.originalIsInputMethod, !directly else {
                // 原来是别的键盘布局（俄文等）：直接选回去就行
                TISSelectInputSource(switched.original)
                completion()
                return
            }
            restoreWithHotKey(switched, attempt: 0, completion: completion)
        }
    }

    // 模拟"选择上一个输入源"快捷键切回去，确认系统报告的输入源变回原来的并稳定 80 毫秒；没变就再按一次；
    // 变成了别的输入源（"上一个"不是它）就先选回原来的、再选英文、再按快捷键；最后才直接选中（App 里可能还是英文）。
    // 这个快捷键关掉了（常和编辑器的 ⌃空格 冲突）就用"下一个输入源"快捷键一个个切过去
    private func restoreWithHotKey(_ switched: Switch, attempt: Int, completion: @escaping () -> Void) {
        // 用户还按着修饰键（粘贴后紧接着按 ⌘S、⇧↩……）：等松开再按快捷键，否则组合出来的是别的快捷键
        let hadToWait = Self.modifiersHeld
        waitForModifiersReleased(deadline: Date().addingTimeInterval(2)) { [self] released in
            // 等的时候用户自己换了输入源（⌃空格 本身就要按着 ⌃）：不再动
            if hadToWait, Self.currentSourceID() != switched.targetID {
                completion()
                return
            }
            guard released else {
                selectDirectly(switched, completion: completion)
                return
            }
            pressPreviousSourceHotKey(switched, attempt: attempt, completion: completion)
        }
    }

    private func pressPreviousSourceHotKey(_ switched: Switch, attempt: Int, completion: @escaping () -> Void) {
        guard let hotKey = previousSourceHotKey() else {
            if let next = nextSourceHotKey() {
                restoreByCycling(switched, hotKey: next, pressesLeft: min(8, Self.selectableSourceCount()), completion: completion)
            } else {
                selectDirectly(switched, completion: completion)
            }
            return
        }
        hotKeyQueue.async { [self] in
            postHotKey(hotKey)
            DispatchQueue.main.async { [self] in
                waitForSource(switched.originalID, stableFor: 0.08, timeout: 0.36) { [self] restored in
                    if restored {
                        completion()
                        return
                    }
                    let current = Self.currentSourceID()
                    if attempt == 0, current == switched.targetID {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            self.restoreWithHotKey(switched, attempt: 1, completion: completion)
                        }
                    } else if attempt <= 1, current != switched.targetID, let target = asciiTarget() {
                        TISSelectInputSource(switched.original)
                        TISSelectInputSource(target)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            self.restoreWithHotKey(switched, attempt: 2, completion: completion)
                        }
                    } else {
                        TISSelectInputSource(switched.original)
                        notifyCopiNotice("Copi couldn't switch your input method back after typing. If typing stays in English, press your input-source shortcut.")
                        completion()
                    }
                }
            }
        }
    }

    // 按"下一个输入源"快捷键，每按一次确认输入源变了并稳定下来，直到回到原来的那个（最多把菜单里的输入源轮一遍）
    private func restoreByCycling(_ switched: Switch, hotKey: (keyCode: CGKeyCode, flags: CGEventFlags), pressesLeft: Int,
                                  completion: @escaping () -> Void) {
        guard pressesLeft > 0 else {
            selectDirectly(switched, completion: completion)
            return
        }
        guard !Self.modifiersHeld else {
            let expected = Self.currentSourceID()
            waitForModifiersReleased(deadline: Date().addingTimeInterval(2)) { [self] released in
                // 等的时候用户自己换了输入源：不再动
                if Self.currentSourceID() != expected {
                    completion()
                    return
                }
                if released {
                    restoreByCycling(switched, hotKey: hotKey, pressesLeft: pressesLeft, completion: completion)
                } else {
                    selectDirectly(switched, completion: completion)
                }
            }
            return
        }
        let before = Self.currentSourceID()
        hotKeyQueue.async { [self] in
            postHotKey(hotKey)
            DispatchQueue.main.async { [self] in
                waitForChange(from: before, stableFor: 0.08, timeout: 0.36) { [self] in
                    if Self.currentSourceID() == switched.originalID {
                        completion()
                    } else {
                        restoreByCycling(switched, hotKey: hotKey, pressesLeft: pressesLeft - 1, completion: completion)
                    }
                }
            }
        }
    }

    // 快捷键用不了（都关掉了、修饰键一直按着、轮了一圈也没回到原来的）：直接选中原来的输入法。系统菜单栏会变回去，
    // 但这个窗口里可能还是英文，直到焦点变化——告诉用户
    private func selectDirectly(_ switched: Switch, completion: @escaping () -> Void) {
        TISSelectInputSource(switched.original)
        if previousSourceHotKey() == nil, nextSourceHotKey() == nil {
            notifyCopiNotice("Copi switched your input method back after typing, but macOS may keep typing English in this window until you click elsewhere. Turn on \"Select the previous input source\" in System Settings › Keyboard › Keyboard Shortcuts › Input Sources to avoid this.")
        } else {
            notifyCopiNotice("Copi couldn't switch your input method back after typing. If typing stays in English, press your input-source shortcut.")
        }
        completion()
    }

    // 主线程：等修饰键全部松开；到期还按着时回调 false
    private func waitForModifiersReleased(deadline: Date, then action: @escaping (Bool) -> Void) {
        if !Self.modifiersHeld {
            action(true)
            return
        }
        guard Date() < deadline else {
            action(false)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [self] in
            waitForModifiersReleased(deadline: deadline, then: action)
        }
    }

    // 等系统报告的输入源变成别的并稳定下来（或者超时）
    private func waitForChange(from id: String?, stableFor: TimeInterval, timeout: TimeInterval, then completion: @escaping () -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        var stableSince: Date?
        var last = id
        func poll() {
            let current = Self.currentSourceID()
            if current != id, current == last {
                stableSince = stableSince ?? Date()
                if Date().timeIntervalSince(stableSince!) >= stableFor {
                    completion()
                    return
                }
            } else {
                stableSince = nil
            }
            last = current
            guard Date() < deadline else {
                completion()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01, execute: poll)
        }
        poll()
    }

    // 输入法菜单里能选的输入源有几个（"下一个输入源"最多按这么多次就转一圈）
    private static func selectableSourceCount() -> Int {
        let filter: [CFString: Any] = [
            kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource as Any,
            kTISPropertyInputSourceIsEnabled: true,
            kTISPropertyInputSourceIsSelectCapable: true,
        ]
        let list = TISCreateInputSourceList(filter as CFDictionary, false)?.takeRetainedValue() as? [TISInputSource]
        return max(2, list?.count ?? 2)
    }

    private func waitForSource(_ id: String, stableFor: TimeInterval, timeout: TimeInterval, then completion: @escaping (Bool) -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        var stableSince: Date?
        func poll() {
            if Self.currentSourceID() == id {
                stableSince = stableSince ?? Date()
                if Date().timeIntervalSince(stableSince!) >= stableFor {
                    completion(true)
                    return
                }
            } else {
                stableSince = nil
            }
            guard Date() < deadline else {
                completion(false)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01, execute: poll)
        }
        poll()
    }

    // 可以选中的英文键盘布局：优先系统记住的那个英文布局（大写锁定键切换的也是它），其次 ABC、U.S.
    private func asciiTarget() -> TISInputSource? {
        let filter: [CFString: Any] = [
            kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource as Any,
            kTISPropertyInputSourceType: kTISTypeKeyboardLayout as Any,
            kTISPropertyInputSourceIsASCIICapable: true,
            kTISPropertyInputSourceIsEnabled: true,
            kTISPropertyInputSourceIsSelectCapable: true,
        ]
        guard let list = TISCreateInputSourceList(filter as CFDictionary, false)?.takeRetainedValue() as? [TISInputSource],
              !list.isEmpty else {
            return nil
        }
        var preferredIDs = ["com.apple.keylayout.ABC", "com.apple.keylayout.US"]
        if let remembered = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(), let id = Self.sourceID(of: remembered) {
            preferredIDs.insert(id, at: 0)
        }
        for id in preferredIDs {
            if let match = list.first(where: { Self.sourceID(of: $0) == id }) {
                return match
            }
        }
        return list.first
    }

    private static func sourceID(of source: TISInputSource) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
            return nil
        }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    private static func currentSourceID() -> String? {
        TISCopyCurrentKeyboardInputSource().map { sourceID(of: $0.takeRetainedValue()) } ?? nil
    }

    // 当前是输入法（拼音、日文……），不是键盘布局
    private static var currentIsInputMethod: Bool {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let typePointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceType) else {
            return false
        }
        let type = Unmanaged<CFString>.fromOpaque(typePointer).takeUnretainedValue() as String
        return type != (kTISTypeKeyboardLayout as String)
    }

    private static var modifiersHeld: Bool {
        !CGEventSource.flagsState(.hidSystemState).intersection([.maskShift, .maskControl, .maskAlternate, .maskCommand, .maskSecondaryFn]).isEmpty
    }

    // 系统设置里"选择上一个输入源"快捷键（AppleSymbolicHotKeys 里的 60 号）
    private func previousSourceHotKey() -> (keyCode: CGKeyCode, flags: CGEventFlags)? {
        inputSourceHotKey("60")
    }

    // "选择输入法菜单中的下一个输入源"（61 号）
    private func nextSourceHotKey() -> (keyCode: CGKeyCode, flags: CGEventFlags)? {
        inputSourceHotKey("61")
    }

    // 关掉了、没有设置过、带着不认识的修饰键时为 nil
    private func inputSourceHotKey(_ id: String) -> (keyCode: CGKeyCode, flags: CGEventFlags)? {
        guard let hotKeys = UserDefaults.standard.persistentDomain(forName: "com.apple.symbolichotkeys")?["AppleSymbolicHotKeys"] as? [String: Any],
              let entry = hotKeys[id] as? [String: Any], (entry["enabled"] as? NSNumber)?.boolValue == true,
              let value = entry["value"] as? [String: Any], let parameters = value["parameters"] as? [NSNumber], parameters.count >= 3 else {
            return nil
        }
        // parameters：[字符, 键码, 修饰键]，修饰键的各位和 CGEventFlags 一样（⇧ 0x20000、⌃ 0x40000、⌥ 0x80000、⌘ 0x100000、fn 0x800000）
        let keyCode = parameters[1].intValue
        let rawModifiers = parameters[2].uint64Value
        let known: UInt64 = 0x20000 | 0x40000 | 0x80000 | 0x100000 | 0x800000
        let flags = CGEventFlags(rawValue: rawModifiers)
        guard keyCode >= 0, keyCode < 128, rawModifiers & ~known == 0,
              !flags.intersection([.maskControl, .maskAlternate, .maskCommand]).isEmpty else {
            return nil
        }
        return (CGKeyCode(keyCode), flags)
    }

    // 像用户按下快捷键一样，在硬件层发出：逐个按下修饰键（flagsChanged），按下、松开主键，再倒序松开修饰键；按键之间稍作停顿。
    // 只发系统快捷键能匹配上的层级（HID），发到更上层的话 ⌃空格 会直接交给 App（VS Code 的补全、终端里的 ^@）
    private func postHotKey(_ hotKey: (keyCode: CGKeyCode, flags: CGEventFlags)) {
        let source = CGEventSource(stateID: .hidSystemState)
        let modifierKeys: [(CGEventFlags, CGKeyCode)] = [
            (.maskControl, CGKeyCode(kVK_Control)), (.maskAlternate, CGKeyCode(kVK_Option)), (.maskShift, CGKeyCode(kVK_Shift)),
            (.maskCommand, CGKeyCode(kVK_Command)), (.maskSecondaryFn, CGKeyCode(kVK_Function)),
        ].filter { hotKey.flags.contains($0.0) }
        func post(_ event: CGEvent?) {
            guard let event else {
                return
            }
            event.setIntegerValueField(.eventSourceUserData, value: copiSyntheticEventMarker)
            event.post(tap: .cghidEventTap)
        }
        var flags = CGEventFlags()
        for (flag, keyCode) in modifierKeys {
            flags.insert(flag)
            let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
            event?.type = .flagsChanged
            event?.flags = flags
            post(event)
            usleep(8_000)
        }
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: hotKey.keyCode, keyDown: keyDown)
            event?.flags = flags
            post(event)
            usleep(keyDown ? 15_000 : 8_000)
        }
        for (flag, keyCode) in modifierKeys.reversed() {
            flags.remove(flag)
            let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
            event?.type = .flagsChanged
            event?.flags = flags
            post(event)
            usleep(5_000)
        }
    }
}

// MARK: - 打开 Chrome / Electron / Firefox 的无障碍树

// Chromium 和 Firefox 只在有辅助程序问起时才构建网页的无障碍树（读一次 App 的角色就会开启，之后整个进程都保持开启），
// 而且是异步构建的——等用户按 ⌘C/⌘V 时才问就来不及了。所以在 App 被激活时就提前问一次。
// 只读角色，不写 AXEnhancedUserInterface / AXManualAccessibility：那两个会让 VS Code 之类进入"屏幕阅读器模式"、拖慢窗口动画。
final class WebAccessibilityWarmer {
    static let shared = WebAccessibilityWarmer()

    private let queue = DispatchQueue(label: "Copi.AccessibilityWarmer", qos: .utility)
    private var warmedPIDs = Set<pid_t>()
    private var observer: NSObjectProtocol?
    private var terminationObserver: NSObjectProtocol?

    func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard observer == nil else {
            return
        }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { notification in
            if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                WebAccessibilityWarmer.shared.warm(app)
                // iTerm2、Ghostty：提前在后台查好 Copi 能不能用它们的脚本接口（粘贴时只读缓存）
                if TerminalScript(bundleIdentifier: app.bundleIdentifier) != nil {
                    TerminalScript.refreshPermission(pid: app.processIdentifier)
                }
            }
        }
        // 进程号会被复用：App 退出后把它的记录清掉
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { notification in
            if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                WebAccessibilityWarmer.shared.warmedPIDs.remove(app.processIdentifier)
                forgetAppEngineCache(pid: app.processIdentifier)
                TerminalScript.forget(pid: app.processIdentifier)
            }
        }
        if let frontmost = NSWorkspace.shared.frontmostApplication {
            warm(frontmost)
        }
    }

    private func warm(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard Defaults[.isOn], Defaults[.enableWebAccessibility], AXIsProcessTrusted(), pid != getpid(), !warmedPIDs.contains(pid) else {
            return
        }
        warmedPIDs.insert(pid)
        queue.async {
            let application = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(application, 0.1)
            // 有的 Chrome 版本只在网页视图自己被问起角色时才打开网页部分的无障碍树
            requestWebAccessibility(application)
            var role: CFTypeRef?
            var focused: CFTypeRef?
            if AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
               let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() {
                let focusedElement = focused as! AXUIElement
                AXUIElementSetMessagingTimeout(focusedElement, 0.1)
                AXUIElementCopyAttributeValue(focusedElement, kAXRoleAttribute as CFString, &role)
            }
        }
    }
}

// MARK: - 通知

private let noticeLock = NSLock()
private var lastNoticeDates: [String: Date] = [:]

// 拒绝复制/粘贴的通知上带一个按钮："这个 App 照常使用系统剪贴板"（见 AppDelegate 里的处理）
enum CopiNotificationAction {
    static let refusedCategory = "copi.refused"
    static let useNormalClipboard = "copi.useNormalClipboard"
    static let bundleIDKey = "bundleID"
    static let appNameKey = "appName"

    static func register() {
        let action = UNNotificationAction(identifier: useNormalClipboard, title: "Use Normal Clipboard in This App", options: [])
        let category = UNNotificationCategory(identifier: refusedCategory, actions: [action], intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }
}

// 被拒绝的那个 App
struct RefusedApp {
    let bundleID: String?
    let name: String
    let pid: pid_t?
    // 焦点在终端画面上（终端的脚本接口只用在这里）
    let onTerminalSurface: Bool

    // 焦点所在的 App（拿不到焦点控件时退回系统报告的焦点 App）
    init(target: FocusedTarget?) {
        if let target {
            bundleID = target.bundleIdentifier
            name = target.applicationName
            pid = target.pid
            onTerminalSurface = target.isTerminalApp && target.role == kAXTextAreaRole && target.isTerminalSurface
        } else {
            let focused = focusedApplication()
            bundleID = focused?.bundleIdentifier
            name = focused?.localizedName ?? "this app"
            pid = focused?.processIdentifier
            onTerminalSurface = false
        }
    }

    // 怎样才能在这里不经过剪贴板复制粘贴：VS Code 系编辑器还没装（或还没连上、装的是旧版本）Copi 的桥接扩展时，提示去装；
    // iTerm2、Ghostty 还没允许 Copi 用脚本接口、而允许之后这次粘贴就能成功时，提示去允许（只对粘贴；复制用不上它）
    func hint(forPasteRefusal reason: UnavailableReason?) -> String {
        guard let pid else {
            return ""
        }
        if let bundleID, remoteDesktopBundleIDPrefixes.contains(where: { bundleID.hasPrefix($0) }) {
            switch reason {
            case .noRoute?, .remoteClipboard?:
                return Defaults[.typeIntoVirtualMachines] ? "" : " Turn on Type Into Virtual Machines in Copi's menu to paste single lines there by pressing keys."
            default:
                return ""
            }
        }
        if let terminal = TerminalScript(bundleIdentifier: bundleID) {
            guard let reason, onTerminalSurface,
                  TerminalScript.cachedPermission(pid: pid).map({ $0 != .allowed && $0 != .unsupported }) == true else {
                return ""
            }
            switch reason {
            case .inputMethod, .multiLine, .noRoute:
                if terminal == .kitty {
                    return " Turn on kitty's remote control for Copi (see Terminal Access in Copi's menu) to paste there directly, including multiple lines."
                }
                return terminal.usesAppleEvents
                    ? " Allow \(terminal.displayName) under Terminal Access in Copi's menu to paste there directly, including multiple lines."
                    : ""
            default:
                return ""
            }
        }
        guard isVSCodeFamilyApp(pid: pid), !EditorBridge.shared.isConnected(appPID: pid) else {
            return ""
        }
        if EditorBridge.shared.hasOutdatedConnection(appPID: pid) {
            return " Reinstall Copi Bridge for \(name) in Copi's menu to update it."
        }
        return " Install Copi Bridge for \(name) in Copi's menu to copy and paste there without the clipboard."
    }
}

func notifyCopiNotice(_ body: String, offering app: RefusedApp? = nil) {
    let now = Date()
    noticeLock.lock()
    if let last = lastNoticeDates[body], now.timeIntervalSince(last) < 3 {
        noticeLock.unlock()
        return
    }
    lastNoticeDates[body] = now
    noticeLock.unlock()
    let content = UNMutableNotificationContent()
    content.title = "Copi"
    content.body = body
    if let app, let bundleID = app.bundleID, !bundleID.isEmpty {
        content.categoryIdentifier = CopiNotificationAction.refusedCategory
        content.userInfo = [CopiNotificationAction.bundleIDKey: bundleID, CopiNotificationAction.appNameKey: app.name]
    }
    UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "copi.notice.\(body.hashValue)", content: content, trigger: nil))
}

// 主线程：异步的路线（终端的脚本接口）最后没能粘贴。焦点还在那里、用户也没有接着操作时，退回剪贴板方式（默认不允许剪贴板回退时，
// 先问用户：8 秒内再粘贴一次才退回，见 ClipboardPasteConsent）；否则拒绝
func refuseOrFallBack(_ reason: UnavailableReason, text: String, target: FocusedTarget, keyTime: Date) {
    dispatchPrecondition(condition: .onQueue(.main))
    if reason.allowsClipboardFallback, !userActedSince(keyTime), focusedApplication()?.processIdentifier == target.pid {
        if ZeroExposurePolicy.isStrict, ClipboardPasteConsent.needsConfirmation(text, targetPID: target.pid, element: target.element, keyTime: keyTime) {
            let app = RefusedApp(target: target)
            notifyPasteRefused(reason, app: app, suffix: ClipboardPasteConsent.offer(appName: app.name), prompts: true)
            return
        }
        // 有会把本机剪贴板同步出去的 App 在运行：先提醒
        if let syncReason = remoteClipboardConfirmationBeforeFallback(text, targetPID: target.pid, keyTime: keyTime) {
            notifyPasteRefused(syncReason, app: RefusedApp(target: target))
            return
        }
        TransientPaste.shared.stage(text, restorePrevious: false, for: target.pid)
        GlobalMode.shared.postFallbackPaste()
        return
    }
    notifyPasteRefused(reason, app: RefusedApp(target: target))
}

// macOS 26.4 起，"终端"在粘贴从网页浏览器复制来的内容时会先警告（防止网页骗用户粘贴、运行恶意命令）。它看的是系统剪贴板上内容的
// 写入者；Copi 不经过剪贴板粘贴，这道检查就被绕过了。所以在同样的场合由 Copi 拦一下：第一次 ⌘V 只提醒，8 秒内再按一次才粘贴
// 网页浏览器
let browserBundleIDPrefixes = [
    "com.apple.Safari", "com.google.Chrome", "org.chromium.", "org.mozilla.", "com.microsoft.edgemac", "com.brave.Browser",
    "company.thebrowser.", "com.operasoftware.", "com.vivaldi.", "com.kagi.kagimacOS", "com.duckduckgo.", "app.zen-browser.",
    "net.waterfox.", "io.gitlab.librewolf", "org.torproject.", "net.mullvad.", "one.ablaze.floorp", "ru.yandex.desktop.yandex-browser",
    "com.openai.atlas", "ai.perplexity.comet", "com.pushplaylabs.sidekick", "com.wavebox.",
]

// 从密码管理器复制的机密内容（密码、恢复码）要粘贴进地址栏、Spotlight、搜索框：这些地方边输入边把文字发给搜索服务（搜索建议），
// 粘贴下去就已经发出去了。多半是焦点没在用户以为的地方（例如还在地址栏里）：第一次只提醒，8 秒内再粘贴一次才粘贴
enum ConcealedDestinationGuard {
    // 主线程
    static var confirmation = PasteConfirmation()
    private static let launcherBundleIDs: Set<String> = ["com.apple.Spotlight", "com.raycast.macos", "com.runningwithcrayons.Alfred"]

    // 主线程：要提醒时返回 true（这一次不粘贴）。keyTime：这一次按键按下的时刻（见 PasteConfirmation）
    static func needsConfirmation(_ text: String, concealed: Bool, into target: FocusedTarget, keyTime: Date) -> Bool {
        guard concealed, !target.isSecureTextField, !ZeroExposurePolicy.isPasswordManager(target.bundleIdentifier) else {
            return false
        }
        // 网址（密码管理器里复制的网站地址）照常粘贴
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil {
            return false
        }
        let bundleID = target.bundleIdentifier ?? ""
        let role = target.role
        // 列出来的浏览器；没列出来、但用 Chromium、Gecko 内核的也可能是浏览器（新出的、改名的），只是 Electron App、Thunderbird
        // 这类不是：它们的输入框都在网页内容里，看不出层级时会被当成地址栏
        let isThunderbird = bundleID.hasPrefix("org.mozilla.thunderbird")
        let listed = !isThunderbird && browserBundleIDPrefixes.contains(where: { bundleID.hasPrefix($0) })
        let byEngine = !listed && !isThunderbird
            && ((isChromiumApp(pid: target.pid) && !isElectronApp(pid: target.pid)) || isGeckoApp(pid: target.pid, bundleIdentifier: target.bundleIdentifier))
        let fieldRole = role == kAXTextFieldRole || role == kAXComboBoxRole
        // 地址栏：浏览器自己界面上的输入框（不在网页内容里）。只按内核认出来的浏览器要一直找到窗口都没有网页内容才算
        // 网页里嵌套很深的输入框（网页根节点在 hasWebAreaAncestor 找的 10 层之外）：往上一直找得到 http(s) 网页就不是地址栏。
        // 浏览器自己画成网页的界面（Vivaldi 的 chrome-extension://、vivaldi://）、读不到时照样当作地址栏
        let inContentPage = { target.webPageURL.map { ["http", "https"].contains($0.scheme?.lowercased() ?? "") } ?? false }
        let isAddressBar = fieldRole && ((listed && !target.hasWebAreaAncestor && !inContentPage())
                                         || (byEngine && reachesWindowOutsideWebArea(target.element)))
        let isSearchField = copyAXAttribute(target.element, kAXSubroleAttribute) as? String == "AXSearchField"
        guard isAddressBar || isSearchField || launcherBundleIDs.contains(bundleID) else {
            return false
        }
        return confirmation.needsConfirmation(key: "\(target.pid)\u{0}\(text)", keyTime: keyTime)
    }
}

// 从 element 往上一直找到窗口，路上没有网页内容（找不到窗口、读不到上一层都不算）
private func reachesWindowOutsideWebArea(_ element: AXUIElement) -> Bool {
    var node: AXUIElement? = element
    for _ in 0..<64 {
        guard let current = node, let role = copyAXAttribute(current, kAXRoleAttribute) as? String else {
            return false
        }
        if role == "AXWebArea" {
            return false
        }
        if role == kAXWindowRole {
            return true
        }
        node = asAXElement(copyAXAttribute(current, kAXParentAttribute))
    }
    return false
}

// Electron App（带 Electron Framework）
private func isElectronApp(pid: pid_t) -> Bool {
    guard let url = NSRunningApplication(processIdentifier: pid)?.bundleURL else {
        return false
    }
    return FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path)
}

enum BrowserToTerminalGuard {
    // 主线程
    static var confirmation = PasteConfirmation()

    // 主线程：要提醒时返回来源 App 的名字（这一次不粘贴）；用户已经确认过、或者不需要提醒时返回 nil。keyTime：这一次按键按下的时刻
    static func unconfirmedSource(of text: String, into target: FocusedTarget, keyTime: Date) -> String? {
        guard target.bundleIdentifier == "com.apple.Terminal",
              ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 26, minorVersion: 4, patchVersion: 0)),
              SecureClipboard.shared.text == text, let source = SecureClipboard.shared.source,
              browserBundleIDPrefixes.contains(where: { source.hasPrefix($0) }),
              confirmation.needsConfirmation(key: text, keyTime: keyTime) else {
            return nil
        }
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: source)
        return url.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? "a web browser"
    }
}

// 用户亲手发起的粘贴（⌘V 按下的那一下、菜单里的粘贴、Copi 的粘贴快捷键、Action Bar）最近几次按下的时刻（就是一路传给粘贴处理的
// 那个 keyTime，确认时据此认出是哪一次按键）。按住 ⌘V 不放产生的自动重复不算：它不能当作"再粘贴一次"的确认。
// event tap 线程和主线程都会写
enum PastePress {
    private static let lock = NSLock()
    private static var recent: [Date] = []

    static func noteDeliberate(at time: Date) {
        lock.lock()
        recent.append(time)
        if recent.count > 8 {
            recent.removeFirst()
        }
        lock.unlock()
    }

    // keyTime 这一次按键是不是用户亲手按的
    static func wasDeliberate(_ keyTime: Date) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return recent.contains(keyTime)
    }
}

// 提醒出现之后，再按一次要隔这么久才算确认（秒）
let confirmationDelay: TimeInterval = 0.6

// "8 秒内再粘贴一次确认"的提醒（主线程）。提醒之后用户亲手再粘贴一次才算确认：看的是这一次按键本身，在别处亲手按过的不算。
// 确认之后一直有效，用户每亲手粘贴一次再延长 8 秒——同一次粘贴可能还要过另一道提醒，不能因为那一道这次没过，这一道就又要从头来
//（异步的路线晚一点才回来，也一样）；这期间每一次也都要是用户亲手按的，不是亲手按的不算、也不延长
struct PasteConfirmation {
    private var pending: (key: String, armedAt: Date, until: Date)?

    // keyTime：这一次按键按下的时刻。返回 true 表示这一次只提醒、不粘贴
    mutating func needsConfirmation(key: String, keyTime: Date) -> Bool {
        let now = Date()
        // 窗口看的是按下的时刻：8 秒内按下、走异步的路线（终端的脚本接口、tmux、Neovim）晚一点才回来的，也算在窗口内
        if let current = pending, current.key == key, keyTime < current.until {
            // 提醒出现之后至少过了一小会儿、用户亲手按下的才算：手快连按两下、按住不放、硬件层刚才没记下按键时别的程序发来的按键都不是
            // 看过提醒之后的确认（是不是亲手按的只能推测，见 hardwareInput）
            guard keyTime > current.armedAt.addingTimeInterval(confirmationDelay), PastePress.wasDeliberate(keyTime) else {
                // 窗口这时已经过了：和以前一样从头再来，这次显示的提醒才对得上一个有效的窗口
                if now >= current.until {
                    pending = (key, now, now.addingTimeInterval(8))
                }
                return true
            }
            // 确认过了：再保持 8 秒（另一道提醒这次没过时，用户读完它再粘贴，这一道不能已经过期又要从头来）
            pending = (key, current.armedAt, max(current.until, now.addingTimeInterval(8)))
            return false
        }
        pending = (key, now, now.addingTimeInterval(8))
        return true
    }
}

// 会把本机剪贴板同步出去的 App 在运行时，退回剪贴板方式之前的提醒（见 remoteClipboardConfirmationBeforeFallback）
enum RemoteClipboardGuard {
    // 主线程
    static var confirmation = PasteConfirmation()
}

// 默认（不允许剪贴板回退）时，没有不经过剪贴板的办法的粘贴：第一次说明为什么、要经过剪贴板，8 秒内用户亲手再粘贴一次才经过
// 剪贴板粘贴（和打开 Allow Clipboard Fallback 时一样：按需提供、带不记录的标记、只留在本机、读走就撤下，最多 3 秒）
enum ClipboardPasteConsent {
    // 主线程
    static var confirmation = PasteConfirmation()

    // 主线程：要先问用户时返回 true（这一次不粘贴）。有会把本机剪贴板同步出去的 App 在运行时不在这里问：接下来那道提醒
    // （remoteClipboardConfirmationBeforeFallback）一样要用户再粘贴一次，说得也更清楚，不必连问两次
    // element：要粘贴进的控件（读不到时为 nil）。换了控件要重新问：在一个输入框里确认过，不等于在另一个里也同意
    // keyTime：这一次按键按下的时刻（见 PasteConfirmation）
    static func needsConfirmation(_ text: String, targetPID: pid_t?, element: AXUIElement?, keyTime: Date) -> Bool {
        guard runningClipboardSyncers().isEmpty else {
            return false
        }
        return confirmation.needsConfirmation(key: "\(targetPID ?? -1)\u{0}\(element.map { CFHash($0) } ?? 0)\u{0}\(text)", keyTime: keyTime)
    }

    // 拒绝通知后面接的这一句
    static func offer(appName: String) -> String {
        " \(pasteAgain) within 8 seconds to paste it through the clipboard instead: it stays there only until \(appName) reads it (3 seconds at most), marked so clipboard managers don't record it, though other apps could read it in that time."
    }

    // 怎样"再粘贴一次"。Override 模式之外 ⌘V 不归 Copi 处理：照着按 ⌘V，App 会原生粘贴系统剪贴板上更早的内容，这次也确认不了，
    // 要再按 Safe Paste 的快捷键、再点 Action Bar 的 Paste（用户把快捷键清掉、关掉 Action Bar 时不提它）
    private static var pasteAgain: String {
        if GlobalMode.shared.isInterceptingKeys {
            return "Press ⌘V again"
        }
        // Override 开着、拦截器却没起来（菜单栏显示暂停）：⌘V 同样不归 Copi 处理，Safe Paste 的快捷键这时也是关着的
        if GlobalMode.shared.isOverrideActive {
            return Defaults[.showQuickActions] ? "Click Paste in the Action Bar again" : "Paste again"
        }
        switch (KeyboardShortcuts.getShortcut(for: .safePaste), Defaults[.showQuickActions]) {
        case let (shortcut?, true):
            return "Press \(shortcut) (Safe Paste) again or click Paste in the Action Bar again"
        case let (shortcut?, false):
            return "Press \(shortcut) (Safe Paste) again"
        case (nil, true):
            return "Click Paste in the Action Bar again"
        case (nil, false):
            return "Paste again with Safe Paste"
        }
    }
}

// 用户亲手按下的复制（⌘C/⌘X 按下的那一下、菜单里的拷贝/剪切、Copi 的复制快捷键）最近几次按下的时刻（见 PastePress）。
// 按住不放的自动重复不算
enum CopyPress {
    private static let lock = NSLock()
    private static var recent: [Date] = []

    static func noteDeliberate(at time: Date) {
        lock.lock()
        recent.append(time)
        if recent.count > 8 {
            recent.removeFirst()
        }
        lock.unlock()
    }

    // keyTime 这一次按键是不是用户亲手按的
    static func wasDeliberate(_ keyTime: Date) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return recent.contains(keyTime)
    }
}

// Copi 读不出选中的内容时：第一次说明为什么，8 秒内用户在同一个地方亲手再复制一次，才交给 App 自己复制（文字会出现在系统剪贴板上，
// Copi 在几毫秒内把它转进来；macOS 读之前要先问时，要等用户回答之后，见 offer）。有会把本机剪贴板同步出去的 App 在运行时，
// 说明里一并告诉用户（和粘贴时 remoteClipboardConfirmationBeforeFallback 一样，确认的这一次就是在知道这一点之后）。主线程
enum CopyThroughAppConsent {
    private static var pending: (key: String, armedAt: Date, until: Date)?

    // keyTime：这一次按键按下的时刻。返回 true 表示这一次只提醒、不复制
    static func needsConfirmation(pid: pid_t?, element: AXUIElement?, cut: Bool, keyTime: Date) -> Bool {
        // 会把本机剪贴板同步出去的 App 和提醒时不一样了（例如提醒之后才打开的虚拟机）：用户确认时不知道有它，要重新问
        let syncers = runningClipboardSyncers().joined(separator: "\u{0}")
        let key = "\(pid ?? -1)\u{0}\(cut)\u{0}\(element.map { CFHash($0) } ?? 0)\u{0}\(syncers)"
        let now = Date()
        // 窗口看的是按下的时刻（见 PasteConfirmation）
        if let current = pending, current.key == key, keyTime < current.until {
            // 提醒出现之后至少过了一小会儿、用户亲手按下的这一次才算（见 PasteConfirmation）
            guard keyTime > current.armedAt.addingTimeInterval(confirmationDelay), CopyPress.wasDeliberate(keyTime) else {
                if now >= current.until {
                    pending = (key, now, now.addingTimeInterval(8))
                }
                return true
            }
            pending = nil
            return false
        }
        pending = (key, now, now.addingTimeInterval(8))
        return true
    }

    // 交给 App 自己复制之后 Copi 要能读到它写进来的文字：macOS 不让 Copi 读时不提供；设成读之前要先问时，剪切也不提供——
    // 文字会在系统剪贴板上等用户回答，用户拒绝的话这次复制就没了，剪切的原文却已经删掉了
    static func isAvailable(cut: Bool) -> Bool {
        switch SystemClipboardFeatures.cachedPasteboardAccess {
        case .denied:
            return false
        case .ask:
            return !cut
        case .allowed:
            return !cut || !SystemClipboardFeatures.cachedMayPrompt
        }
    }

    static func offer(appName: String, cut: Bool) -> String {
        let syncers = runningClipboardSyncers()
        let synced = syncers.isEmpty ? "" : ", and \(ListFormatter.localizedString(byJoining: Array(syncers.prefix(3)))) can copy it to another computer's clipboard (and its clipboard history), where it stays"
        // macOS 读之前可能先问（设成询问，或者还没问过）：Copi 要等用户回答才读得到，文字这期间一直不带标记地留在系统剪贴板上
        //（这时只提供复制，见 isAvailable）。用户不允许时，默认设置下 Copi 把它清掉；允许剪贴板回退时它照旧留着
        guard SystemClipboardFeatures.cachedPasteboardAccess == .ask || SystemClipboardFeatures.cachedMayPrompt else {
            return " Press \(cut ? "⌘X" : "⌘C") again within 8 seconds to let \(appName) \(cut ? "cut" : "copy") it itself: the text then sits on the system clipboard, where other apps could read it, for the few milliseconds until Copi moves it in\(synced)."
        }
        let denied = ZeroExposurePolicy.isStrict ? "Copi removes the text and nothing is copied" : "the text stays on the clipboard"
        return " Press \(cut ? "⌘X" : "⌘C") again within 8 seconds to let \(appName) \(cut ? "cut" : "copy") it itself: the text then sits on the system clipboard, unmarked, where other apps could read it, until Copi moves it in, and if macOS asks whether Copi may read it, until you answer\(synced). If macOS asks and you don't allow it, \(denied)."
    }
}

// 粘贴进放行的 App 被拒绝时补一句（放行只让那个 App 自己复制的文字留在系统剪贴板上）
let normalClipboardPasteNote = " Text copied in other apps stays off the clipboard, even in apps that use the normal clipboard."

// suffix：追加在说明后面的话。粘贴被拒绝时不提供"这个 App 照常使用系统剪贴板"的按钮：放行只影响在那个 App 里的复制，帮不了这次粘贴。
// prompts：要用户再粘贴一次确认（说明同时显示在屏幕下方，见 CopiHUD）
func notifyPasteRefused(_ reason: UnavailableReason, app: RefusedApp, suffix: String = "", prompts: Bool = false) {
    let name = app.name
    let body: String
    switch reason {
    case .noRoute:
        body = "\(name) has no way to paste without the system clipboard, so Copi pasted nothing."
    case .lineTooLong(let limit):
        body = "The prompt in \(name), such as a password prompt or a script asking for input, takes only about \(limit) bytes on one line and silently drops the rest, even when pasted in parts, so Copi pasted nothing. Characters outside ASCII (accented letters, curly quotes, Chinese, emoji) take 2 to 4 bytes each."
    case .multiLine:
        body = "Copi can only paste single lines into \(name) without the system clipboard, so it pasted nothing."
    case .inputMethod:
        // 只有当前确实是输入法时才说出它的名字（刚切到 ABC 的那一瞬间不会走到这里）
        let inputMethod = InputSourceState.currentName.map { "\($0) is" } ?? "An input method is"
        let advice = InputSourceSwitcher.shared.unavailableReason ?? "Switch to ABC or U.S. and press ⌘V again."
        body = "Copi pastes into \(name) by typing, and \(inputMethod) active, which would change the text. " + advice
    case .modalProgram(let program?):
        body = "\(name) is running \(program), which could treat pasted text as commands, so Copi pasted nothing."
    case .modalProgram(nil):
        body = "Copi can't tell what is running in \(name), which could treat pasted text as commands, so it pasted nothing. Copi types into terminals only at a shell prompt."
    case .formattingTriggers:
        body = "\(name) turns some typed text into formatting (a line starting with \"- \", \"# \", \"> \" or \"1. \" becomes a list, heading or quote; :name: becomes an emoji), which would change this text, so Copi pasted nothing."
    case .unsafeCharacters:
        body = "\(name) would auto-complete brackets, quotes or punctuation in this text, so Copi pasted nothing. Without the clipboard Copi can only paste letters, digits and simple symbols there."
    case .untypeableCharacters:
        body = "Copi pastes into \(name) by pressing keys, and some characters in this text have no single key on your keyboard layout, so it pasted nothing."
    case .capsLock:
        body = "Turn off Caps Lock and press ⌘V again: Copi pastes into \(name) by pressing keys, and Caps Lock would change the letters."
    case .viMode:
        body = "The shell in \(name) may be using vi key bindings, where pasted letters could act as commands, so Copi pasted nothing."
    case .shellAbbreviations:
        body = "fish in \(name) has abbreviations, which typed spaces or ; | & would expand into other commands, so Copi pasted nothing."
    case .singleKeyPrompt:
        body = "\(name) is waiting for a single key (such as a y/n answer), which the first character of the paste would answer, so Copi pasted nothing."
    case .concealedIntoSearch:
        body = "This looks like a password or secret from a password manager, and the focus in \(name) is in an address bar or search field, which can send what you paste to a search service right away. Paste again within 8 seconds to paste it there anyway."
    case .tmuxHooks(let hooks):
        body = "tmux has hooks that run when text is pasted (\(hooks.joined(separator: ", "))), which could save or send the text elsewhere, so Copi pasted nothing. Check `tmux show-hooks -g` and `tmux show-hooks -t <session>` if you didn't set them up."
    case .remoteClipboard(let apps):
        let names = ListFormatter.localizedString(byJoining: Array(apps.prefix(3)))
        body = "Copi would paste into \(name) through the clipboard, and \(names) can copy it to another computer's clipboard (and its clipboard history), where it stays after the paste. Paste again within 8 seconds to paste anyway."
    case .needsConfirmation(let source):
        body = "This text was copied from \(source). Commands copied from websites can harm your Mac, so check it first: paste again within 8 seconds to paste it into \(name)."
    case .keystrokesWatched(let watchers):
        let names = ListFormatter.localizedString(byJoining: Array(watchers.prefix(3)))
        body = "Copi would paste into \(name) by typing, and \(names) can see keystrokes, so it pasted nothing. Turn off Don't Type When Keystrokes Are Watched in Copi's menu to type anyway."
    case .stillTyping:
        // 不是这里没法粘贴：不补充怎样才能在这里粘贴的说明
        notifyCopiNotice("Copi was still typing the previous paste into \(name) when you pasted again, so it pasted nothing this time. The previous paste may have stopped part way: check the field, then paste again.")
        return
    }
    let message = body + suffix + app.hint(forPasteRefusal: reason)
    notifyCopiNotice(message)
    switch reason {
    case .concealedIntoSearch, .remoteClipboard, .needsConfirmation:
        CopiHUD.shared.showMessage(message, seconds: 8)
    default:
        if prompts {
            CopiHUD.shared.showMessage(message, seconds: 8)
        }
    }
}

// 为什么拒绝了一次复制
enum CopyRefusal {
    // 选中了内容，但不借助系统剪贴板读不出来
    case unreadable
    // Copi 正忙（主线程卡住、上一次粘贴还没完成），这次按键作废了
    case busy
    // 没看到选中的文字（有的 App 这时会复制别的东西）
    case emptySelection
    // 选了不止一段，读得到的只有第一段
    case multipleSelections
}

// offerApp：再复制一次就交给 App 自己复制（见 CopyThroughAppConsent）
func notifyCopyRefused(app: RefusedApp, cut: Bool, reason: CopyRefusal, offerApp: Bool = false) {
    let verb = cut ? "cut" : "copied"
    let body: String
    switch reason {
    case .unreadable:
        body = "Copi can't read a selection in \(app.name) without the system clipboard, so nothing was \(verb)."
    case .busy:
        body = "Copi was busy and skipped this \(cut ? "⌘X" : "⌘C"), so nothing was \(verb). Try again in a moment."
    case .emptySelection:
        body = "Copi didn't see any selected text in \(app.name), so nothing was \(verb)."
    case .multipleSelections:
        body = "Copi can't \(cut ? "cut" : "copy") several selections at once without the system clipboard, so nothing was \(verb). Do them one at a time."
    }
    let suffix = " Copi also cleared its clipboard so a paste won't insert something older."
        + (offerApp ? CopyThroughAppConsent.offer(appName: app.name, cut: cut) : "")
    if offerApp {
        CopiHUD.shared.showMessage(body + CopyThroughAppConsent.offer(appName: app.name, cut: cut), seconds: 8)
    }
    // "照常使用系统剪贴板"的按钮只在放行确实有用、又不会让文字流到别处时提供。Copi 太忙（或编辑器没及时回应）：问题不在这个 App
    // 用不用系统剪贴板。虚拟机、远程桌面：系统剪贴板会被它们同步到客户机（远程电脑）上、留在那里，Copi 撤不下来；
    // 改为告诉用户在客户机里复制用的是客户机的剪贴板
    if case .busy = reason {
        notifyCopiNotice(body + suffix)
    } else if isRemoteDesktopApp(app.bundleID) {
        notifyCopiNotice(body + suffix + " Copying inside the guest (for example with Ctrl+C in Windows) uses the guest's clipboard, which \(app.name) can share with this Mac.")
    } else {
        notifyCopiNotice(body + suffix + app.hint(forPasteRefusal: nil), offering: app)
    }
}
