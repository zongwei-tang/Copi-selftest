//
//  SettingsView.swift
//  SecureYourClipboard
//
//  Created by lixindong on 2024/4/13.
//

import SwiftUI
import UniformTypeIdentifiers
import KeyboardShortcuts
import Defaults
import LaunchAtLogin
import AXSwift
import UserNotifications

struct SettingsView: View {

    @Default(.showQuickActions) var quickActions: Bool
    @Default(.isOn) var isOn: Bool
    @Default(.overrideShortcuts) var globalMode: Bool
    @Default(.notifyOnProtect) var notifyOnProtect: Bool
    @Default(.allowClipboardFallback) var allowClipboardFallback: Bool
    @Default(.enableWebAccessibility) var enableWebAccessibility: Bool
    @Default(.normalClipboardApps) var normalClipboardApps: [String]
    @Default(.clearOnLock) var clearOnLock: Bool
    @Default(.autoClearMinutes) var autoClearMinutes: Int
    @Default(.switchInputSourceForTyping) var switchInputSourceForTyping: Bool
    @Default(.typeIntoVirtualMachines) var typeIntoVirtualMachines: Bool
    @Default(.blockTextDragging) var blockTextDragging: Bool
    @Default(.instantClipboardDetection) var instantClipboardDetection: Bool
    @Default(.constantFastCheck) var constantFastCheck: Bool
    @Default(.restartAfterCrash) var restartAfterCrash: Bool
    @Default(.refuseTypingWhenWatched) var refuseTypingWhenWatched: Bool
    @Default(.typePrivately) var typePrivately: Bool
    @Default(.misjudgedNonTextContexts) var learnedCopyRefusals: [String]

    @State private var isAccessibilityPermitted = false
    @ObservedObject private var protectionStatus = ProtectionStatus.shared
    // Copi 的通知被关掉了：保护暂停时提醒不了
    @State private var notificationsBlocked = false

    @State private var systemClipboardContent: NSPasteboardItem? = nil
    @State private var systemClipboardConcealed = false
    @State private var systemClipboardRemote = false
    @State private var systemClipboardTypeSelection: String = ""
    @State private var copiClipboardText: String? = nil
    @State private var copiClipboardConcealed = false
    // Copi 里存着的不是文字的复制（"An image"、"3 files"）
    @State private var copiClipboardNonText: String? = nil
    // Copi 剪贴板的内容默认不显示：屏幕共享、录屏、旁边的人都能看到菜单栏面板（macOS 15 起窗口没法把自己排除在屏幕共享之外）
    @State private var revealCopiClipboard = false
    // 系统剪贴板上的内容（放行的 App 里的复制）也一样，点 Show 才显示
    @State private var revealSystemClipboard = false
    @State private var shownSystemChangeCount = 0
    // 表单的实际高度：面板按它定高，但不超过屏幕，内容更多时可以滚动（之前整个面板固定成内容的高度，超出屏幕的部分够不着）
    @State private var formHeight: CGFloat = 0
    // VS Code 系编辑器和桥接扩展的状态
    @State private var editors: [VSCodeFamilyEditor] = []
    @State private var installingEditor: String? = nil
    @State private var bridgeMessage: String? = nil
    // iTerm2、Ghostty：允许 Copi 用它们的脚本接口粘贴
    @State private var terminalPermissions: [TerminalScript: TerminalScript.Permission] = [:]
    @State private var requestingTerminal: TerminalScript? = nil
    @State private var terminalMessage: String? = nil
    // 现在能看到键盘输入的程序（系统的 event tap 清单）
    @State private var keystrokeObservers: [KeystrokeObserver] = []
    // macOS 自己会看剪贴板的功能（见 SystemClipboardFeatures）
    @State private var spotlightHistory: SystemClipboardFeatures.State? = nil
    @State private var handoff: SystemClipboardFeatures.State = .unknown
    @State private var pasteboardAccess: SystemClipboardFeatures.PasteboardAccess = .allowed
    
    var body: some View {
        ScrollView {
            Form {
                if !isAccessibilityPermitted {
                    permissions
                    Section {
                        Button("Quit Copi") {
                            NSApp.terminate(nil)
                        }
                    }
                } else {
                    Section {
                        if isOn {
                            toolbar
                            shortcuts
                            zeroExposure
                            editorBridge
                            terminalAccess
                            normalClipboard
                            keystrokeWatchers
                            systemFeatures
                            notifications
                        }
                        secureClipboard
                        systemClipboard
                    } header: {
                        header
                    } footer: {
                        others
                    }
                }
            }
            .formStyle(.grouped)
            .controlSize(.mini)
            .frame(width: 300)
            .animation(.default, value: isOn)
            .background(GeometryReader { proxy in
                Color.clear.preference(key: FormHeightKey.self, value: proxy.size.height)
            })
        }
        .frame(width: 300, height: panelHeight)
        .onPreferenceChange(FormHeightKey.self) { height in
            formHeight = height
        }
        .task {
            onStart()
        }
        // 屏幕共享、录屏截不到这个面板（点 Show 显示出来的文字；macOS 15 起 ScreenCaptureKit 不再遵守，只防旧系统和旧接口）
        .background(CaptureExcluded())
        .onReceive(NotificationCenter.default.publisher(for: .copiSystemPasteboardDidChange)) { _ in
            updateSystemPasteboardItem()
        }
        .onReceive(NotificationCenter.default.publisher(for: SecureClipboard.didChangeNotification)) { _ in
            updateSecurePasteboard()
        }
        // 还没量出高度时按内容的理想高度显示（和之前一样）
        .fixedSize(horizontal: true, vertical: panelHeight == nil)
    }

    private var panelHeight: CGFloat? {
        guard formHeight > 0 else {
            return nil
        }
        // 按最矮的那块屏幕算：菜单栏面板可能在任何一块屏幕上打开（NSScreen.main 是拿着键盘焦点的那块）
        let screenHeight = NSScreen.screens.map { $0.visibleFrame.height }.min() ?? 800
        return min(formHeight, screenHeight - 40)
    }
    
    // MARK: - Views
    var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Copi is")
                Spacer()
                Toggle(isOn ? "On" : "Off", isOn: guarded(.isOn, $isOn))
                    .toggleStyle(.button)
                    .controlSize(.regular)
            }
            .font(.headline)
            switch protectionStatus.state {
            case .paused(let needsAccessibility):
                HStack {
                    Text(needsAccessibility
                         ? "Protection is paused: Copi needs Accessibility permission again. Until then, copies go to the system clipboard."
                         : "Protection is paused: Copi couldn't intercept ⌘C/⌘V. Until it can, copies go to the system clipboard.")
                        .font(.caption)
                        .foregroundStyle(.red)
                    Button("Retry") {
                        GlobalMode.shared.updateOverrideState()
                    }
                }
            case .off:
                Text("Copi is off: ⌘C and ⌘V use the system clipboard, where other apps can read what you copy.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            case .limited:
                HStack {
                    Text("macOS doesn't let Copi read what other apps put on the clipboard, so copies they make (a Copy button, pbcopy) can't be moved off it. ⌘C and ⌘V are still protected.")
                        .font(.caption)
                        .foregroundStyle(.red)
                    Button("Settings…") {
                        openSettings(SystemClipboardFeatures.pasteboardPrivacySettingsURL)
                    }
                }
            case .protecting, .manual:
                EmptyView()
            }
            if let change = protectionStatus.unexplainedChange {
                HStack {
                    Text("Another program changed Copi's settings: \(change) Check them below and change them back if you didn't do this.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button("Dismiss") {
                        protectionStatus.dismissUnexplainedChange()
                    }
                }
            }
        }
    }
    
    var toolbar: some View {
        Section("Action Bar") {
            Toggle("Show Action Bar on Selection", isOn: $quickActions)
                .disabled(!isOn)
        }
    }
    
    var permissions: some View {
        Section("Permission Granted Needed") {
            if !isAccessibilityPermitted {
                Section {
                    Label("Use accessibility permission to get the selection text", systemImage: "checkmark.circle.fill")
                    HStack {
                        Button {
                            AXSwift.checkIsProcessTrusted(prompt: true)
                        } label: {
                            Text("Open Accessibility Settings")
                        }
                        .controlSize(.regular)
                        
                        Button {
                            isAccessibilityPermitted = AXSwift.checkIsProcessTrusted()
                            GlobalMode.shared.updateOverrideState()
                        } label: {
                            Text("Validate")
                                .foregroundStyle(Color.accentColor)
                        }
                        .controlSize(.large)
                        .buttonStyle(.plain)
                    }
                    .frame(maxWidth: .infinity)
                } header: {
                    // 复制/粘贴已经直接通过 Accessibility 完成，不再需要用户去系统设置里启用 Services，
                    // 之前的"2/2: Services"这一步会在点"Done"之前把整个主界面（包括开关）都藏起来
                    Text("Accessibility")
                }
            }
        }
    }
    
    var shortcuts: some View {
        Section("Shortcuts") {
            Toggle("Override ⌘C/⌘V", isOn: guarded(.overrideShortcuts, $globalMode))
            if !globalMode {
                Text("⌘C and ⌘V use the system clipboard as usual while this is off. Only the shortcuts below and the Action Bar keep text off it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            KeyboardShortcuts.Recorder("Safe Copy", name: .safeCopy, onConflict: { _, _ in
            })
            .disabled(!isOn || globalMode)
            KeyboardShortcuts.Recorder("Safe Paste", name: .safePaste, onConflict: { _, _ in
            })
            .disabled(!isOn || globalMode)
            if globalMode {
                Text("Turn off Override ⌘C/⌘V to use these shortcuts instead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    var zeroExposure: some View {
        Section("Zero Exposure") {
            Text("Copi never puts your text on the system clipboard, so other apps, clipboard managers and your other devices can't see it. Where an app has no way to copy or paste without the clipboard, Copi refuses and tells you. Copies Copi can't intercept (an app's own Copy button, copy-on-select, another program writing to the clipboard) pass through the system clipboard for a few milliseconds; Copi moves them and tells you.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !learnedCopyRefusals.isEmpty {
                HStack {
                    Text("⌘C is refused in \(learnedCopyRefusals.count) place\(learnedCopyRefusals.count == 1 ? "" : "s") where it once copied text Copi expected to be a file or picture.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Reset") {
                        learnedCopyRefusals = []
                    }
                }
            }
            Toggle("Allow Clipboard Fallback (Less Secure)", isOn: guarded(.allowClipboardFallback, $allowClipboardFallback))
            Text("Where nothing else works, Copi asks you to press ⌘V or ⌘C again before it uses the system clipboard. With this on it doesn't ask: it briefly puts the text there right away (marked private and kept on this Mac). Other apps can read it during that moment.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Switch to ABC While Typing", isOn: $switchInputSourceForTyping)
            Text("Where Copi pastes by typing, it briefly switches an input method such as Pinyin to ABC and back, so the input method doesn't change the text.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Instant Clipboard Detection", isOn: guarded(.instantClipboardDetection, $instantClipboardDetection))
            Text("Copi learns the moment another app copies (a password manager's Copy button, a website's copy button) instead of noticing on its next check. It listens for the same internal macOS notice Chrome uses; where that isn't available, it keeps an invisible placeholder on the clipboard. Turn it off if another app behaves oddly with the clipboard.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Constant Fast Check", isOn: guarded(.constantFastCheck, $constantFastCheck))
            Text("Copi normally checks the clipboard every 20 ms, and every 4 ms right after clicks and shortcuts. With this on it checks every 3 ms all the time, so text another app puts there (a password manager's Copy button, `pbcopy`) is gone sooner. Uses more energy.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Block Dragging Text", isOn: guarded(.blockTextDragging, $blockTextDragging))
            Text("Dragging selected text would put it on the drag pasteboard, where any app can read it. Copi stops the drag; use ⌘X or ⌘C and then ⌘V instead. Files and images still drag as usual.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Type Privately (Beta)", isOn: guarded(.typePrivately, $typePrivately))
            Text("Where Copi pastes by typing, it sends the keys straight to the app instead of through the system-wide keyboard stream, so programs watching all keystrokes don't see them (not in virtual machines and remote desktops, which only take keys from that stream). Turn it off if typing stops working in an app.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Don't Type When Keystrokes Are Watched", isOn: guarded(.refuseTypingWhenWatched, $refuseTypingWhenWatched))
            Text("Where Copi can only paste by typing, refuse instead while a program that would see the typed keys is running (paused ones included), and stop typing if one starts watching partway. Programs that only see the keyboard hardware don't count, nothing is checked while Secure Input is on, and apps that watch keys through Accessibility can't be detected.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Type Into Virtual Machines", isOn: guarded(.typeIntoVirtualMachines, $typeIntoVirtualMachines))
            Text("In virtual machines and remote desktops, paste single lines by pressing the keys. Copi can't see what is running there (in vim or less, letters are commands), so paste only where you would type. The guest must use the same keyboard layout as this Mac, or other characters may be typed.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Clear Copi Clipboard When Mac Locks", isOn: guarded(.clearOnLock, $clearOnLock))
            Picker("Clear Copi Clipboard After", selection: guarded(.autoClearMinutes, $autoClearMinutes)) {
                Text("Never").tag(0)
                Text("1 Minute").tag(1)
                Text("5 Minutes").tag(5)
                Text("15 Minutes").tag(15)
                Text("1 Hour").tag(60)
            }
            Toggle("Accessibility for Chrome & Electron Apps", isOn: $enableWebAccessibility)
            Text("Lets Copi copy and paste in Chrome-based browsers and Electron apps (and Firefox text fields) without the clipboard. These apps use some extra CPU and memory once it is on (until they restart).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // VS Code、Cursor、Windsurf 等编辑器：装上 Copi Bridge 扩展后不经过剪贴板复制粘贴
    @ViewBuilder
    var editorBridge: some View {
        if !editors.isEmpty {
            Section {
                ForEach(editors, id: \.bundleURL) { editor in
                    HStack {
                        Text(editor.name)
                        Spacer()
                        Text(bridgeStatus(editor))
                            .foregroundStyle(.secondary)
                        if installingEditor == editor.bundleURL.path {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Button(editor.isBridgeInstalled ? "Reinstall" : "Install") {
                                installBridge(into: editor)
                            }
                            .disabled(installingEditor != nil || editor.commandLineTool == nil)
                        }
                    }
                }
                Text(bridgeMessage ?? "A small extension that lets Copi copy and paste in these editors (editor and terminal) without the system clipboard. Restart the editor after installing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Editor Bridge")
            }
        }
    }

    // iTerm2、Ghostty：允许 Copi 控制它们后，粘贴直接交给终端（不经过剪贴板、不用切换输入法，多行、fish 也行）
    @ViewBuilder
    var terminalAccess: some View {
        let terminals = TerminalScript.all.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleIdentifier) != nil }
        if !terminals.isEmpty {
            Section {
                ForEach(terminals, id: \.self) { terminal in
                    HStack {
                        Text(terminal.displayName)
                        Spacer()
                        Text(terminalStatus(terminal))
                            .foregroundStyle(.secondary)
                        if requestingTerminal == terminal {
                            ProgressView()
                                .controlSize(.small)
                        } else if terminal.usesAppleEvents, terminalPermissions[terminal] != .allowed {
                            Button("Allow") {
                                requestTerminalPermission(terminal)
                            }
                            .disabled(requestingTerminal != nil)
                        } else if terminal == .kitty, terminalPermissions[terminal] == .notDetermined {
                            Button("Set Up…") {
                                terminalMessage = KittyRemoteControl.prepare()
                            }
                        }
                    }
                }
                Text(terminalMessage ?? "Lets Copi paste straight into these terminals through their own interfaces: no clipboard, no keystrokes for other apps to see, no input-method switching, and multi-line pastes work in more shells. WezTerm needs no setup.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } header: {
                Text("Terminal Access")
            }
        }
    }

    // 用户放行的 App：⌘C/⌘V 照常使用系统剪贴板
    var normalClipboard: some View {
        Section {
            ForEach(normalClipboardApps, id: \.self) { bundleID in
                HStack {
                    Text(appDisplayName(bundleID))
                    Spacer()
                    Button {
                        normalClipboardApps.removeAll { $0 == bundleID }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                }
            }
            Button("Add App…") {
                addNormalClipboardApps()
            }
            Text("Text copied in these apps stays on the system clipboard as usual, where other apps can read it. Text copied elsewhere is still pasted into them without the clipboard.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Apps Using the Normal Clipboard")
        }
    }

    // 能看到按键的程序：Copi 用模拟键入粘贴时，它们看得到打出来的文字
    var keystrokeWatchers: some View {
        Section {
            if keystrokeObservers.isEmpty {
                Text("None found")
                    .foregroundStyle(.secondary)
            }
            ForEach(keystrokeObservers) { observer in
                HStack {
                    Text(observer.name)
                    Spacer()
                    Text(keystrokeObserverDetail(observer))
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Refresh") {
                    refreshKeystrokeObservers()
                }
                Button("Input Monitoring…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            Text("These programs can see the keys you press, including text Copi types for you where it can't paste directly. Programs that read the keyboard directly aren't listed here; System Settings › Privacy & Security › Input Monitoring and Accessibility show every app allowed to.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Programs That Can See Keystrokes")
        }
    }

    func keystrokeObserverDetail(_ observer: KeystrokeObserver) -> String {
        var parts: [String] = []
        if !observer.targets.isEmpty {
            parts.append("only in " + observer.targets.joined(separator: ", "))
        }
        parts.append(observer.canModify ? "can change keys" : "watches")
        if !observer.enabled {
            parts.append("paused")
        }
        return parts.joined(separator: " · ")
    }

    func refreshKeystrokeObservers() {
        DispatchQueue.global(qos: .userInitiated).async {
            let observers = KeystrokeObservers.current()
            DispatchQueue.main.async {
                keystrokeObservers = observers
            }
        }
    }

    // macOS 自己会看剪贴板的功能：别的 App 自己写进剪贴板的内容在 Copi 转走之前，它们也可能读到
    var systemFeatures: some View {
        Section {
            if pasteboardAccess != .allowed {
                HStack {
                    Text("Paste from Other Apps")
                    Spacer()
                    Text(pasteboardAccess == .ask ? "Asks every time" : "Denied")
                        .foregroundStyle(.red)
                    Button("Settings…") {
                        openSettings(SystemClipboardFeatures.pasteboardPrivacySettingsURL)
                    }
                }
                Text("macOS doesn't let Copi read text other apps put on the clipboard without asking, so Copi can't move those copies off it. Set Copi to Allow under Privacy & Security › Paste from Other Apps.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if let spotlightHistory {
                HStack {
                    Text("Spotlight Clipboard History")
                    Spacer()
                    Text(featureStateText(spotlightHistory, retention: SystemClipboardFeatures.spotlightHistoryRetention))
                        .foregroundStyle(spotlightHistory == .off ? Color.secondary : Color.orange)
                    Button("Settings…") {
                        openSettings(SystemClipboardFeatures.spotlightSettingsURL)
                    }
                }
            }
            HStack {
                Text("Handoff (Universal Clipboard)")
                Spacer()
                Text(featureStateText(handoff))
                    .foregroundStyle(.secondary)
                Button("Settings…") {
                    openSettings(SystemClipboardFeatures.handoffSettingsURL)
                }
            }
            Text("Text Copi keeps never reaches these. But copies that apps make by themselves (a Copy button, pbcopy) sit on the clipboard for a few milliseconds before Copi moves them, and Spotlight's clipboard history can record them for hours. Turn off Results from Clipboard in Spotlight settings and clear its history if you don't use it. Handoff only tells your nearby devices that something was copied; they fetch it when you paste there.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("macOS Features That See the Clipboard")
        }
    }

    func featureStateText(_ state: SystemClipboardFeatures.State, retention: TimeInterval? = nil) -> String {
        switch state {
        case .on:
            if let retention, retention > 0 {
                let hours = retention / 3600
                return hours >= 1 ? "On (\(Int(hours.rounded())) h)" : "On (\(Int((retention / 60).rounded())) min)"
            }
            return "On"
        case .off:
            return "Off"
        case .unknown:
            return "Probably on"
        }
    }

    func refreshSystemFeatures() {
        spotlightHistory = SystemClipboardFeatures.spotlightHistory
        handoff = SystemClipboardFeatures.handoff
        pasteboardAccess = SystemClipboardFeatures.pasteboardAccess
    }

    func openSettings(_ url: URL?) {
        if let url {
            NSWorkspace.shared.open(url)
        }
    }

    var notifications: some View {
        Section("Notifications") {
            Toggle("Notify When Protected", isOn: $notifyOnProtect)
            if notificationsBlocked {
                HStack {
                    Text("Notifications from Copi are turned off, so it can't tell you if protection stops or a paste is refused.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button("Settings…") {
                        openSettings(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier ?? "com.gokoding.Copi")"))
                    }
                }
            }
        }
    }

    func refreshNotificationSettings() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let blocked = settings.authorizationStatus == .denied || settings.alertSetting == .disabled
            DispatchQueue.main.async {
                notificationsBlocked = blocked
            }
        }
    }

    var secureClipboard: some View {
        Section {
            Text(copiClipboardDisplayText)
                .lineLimit(5)
        } header: {
            HStack {
                Text("Copi Clipboard (Safe)")
                Button {
                    revealCopiClipboard.toggle()
                } label: {
                    Text(revealCopiClipboard ? "Hide" : "Show")
                }
                .disabled(copiClipboardText == nil || copiClipboardConcealed)
                Button {
                    SecureClipboard.shared.setText(nil)
                    // 退回剪贴板方式时可能还挂着一份
                    TransientPaste.shared.finish()
                } label: {
                    Text("Clear")
                }
                // 让附近的设备（iPhone、iPad、另一台 Mac）通过通用剪贴板粘贴这段文字：放上剪贴板一分钟
                Button {
                    guard let text = SecureClipboard.shared.text else {
                        return
                    }
                    TransientPaste.shared.shareWithNearbyDevices(text)
                    notifyCopiNotice("For the next minute, your iPhone, iPad or other Mac can paste this text with Universal Clipboard (Handoff must be on). Apps on this Mac can read it during that minute too.")
                } label: {
                    Text("Nearby Devices")
                }
                .disabled(copiClipboardText == nil)
                .help("Let your other Apple devices paste Copi's text for one minute")
            }
        }
        .onDisappear {
            revealCopiClipboard = false
            revealSystemClipboard = false
        }
        // 显示出来的文字 30 秒后自动重新隐藏（用户走开时不一直摆在屏幕上）。再点一次 Show 重新计时
        .task(id: revealCopiClipboard) {
            guard revealCopiClipboard, (try? await Task.sleep(nanoseconds: 30_000_000_000)) != nil else {
                return
            }
            revealCopiClipboard = false
        }
        .task(id: revealSystemClipboard) {
            guard revealSystemClipboard, (try? await Task.sleep(nanoseconds: 30_000_000_000)) != nil else {
                return
            }
            revealSystemClipboard = false
        }
    }

    private var copiClipboardDisplayText: String {
        guard let text = copiClipboardText else {
            // 不是文字的复制：只说是什么，粘贴时才放上系统剪贴板
            return copiClipboardNonText.map { "\($0) (put on the clipboard only while you paste)" } ?? "Empty"
        }
        // 密码管理器的复制永远不显示
        if copiClipboardConcealed {
            return "•••••••• (Concealed)"
        }
        guard revealCopiClipboard else {
            return "Hidden"
        }
        // 只截取开头一段来显示：复制了很长的文本时整段排版会卡住界面
        return String(text.prefix(500))
    }
    
    // 系统剪贴板内容
    var systemClipboard: some View {
        Section {
            if systemClipboardConcealed {
                // 密码管理器的复制、Copi 自己正临时挂着的粘贴内容：不读取也不显示
                Text("Concealed")
            } else if systemClipboardRemote {
                // 通用剪贴板从其他设备同步过来的内容：一读就会触发传输，不读
                Text("From another device")
            } else if systemClipboardContent != nil, !revealSystemClipboard {
                Text("Hidden")
            } else if let item = systemClipboardContent {
                VStack(alignment: .leading) {
                    ScrollView(.horizontal) {
                        Picker("", selection: $systemClipboardTypeSelection) {
                            ForEach(item.types, id: \.rawValue) { type in
                                Text(type.rawValue.prefix(12))
                                    .tag(type.rawValue)
                            }
                        }.pickerStyle(.segmented)
                            .fixedSize()
                    }
                    .scrollIndicators(.never)
                    let selection = systemClipboardTypeSelection
                    if !selection.isEmpty {
                        if selection == NSPasteboard.PasteboardType.string.rawValue {
                            Text(item.string(forType: .string) ?? "")
                                .lineLimit(5)
                        } else {
                            Text("\(item.data(forType: .init(selection))?.count ?? 0) Bytes")
                                .lineLimit(5)
                        }
                    }
                }
            } else {
                Text("Empty")
            }
        } header: {
            HStack {
                Text("System Clipboard (Unsafe)")
                Button {
                    revealSystemClipboard.toggle()
                } label: {
                    Text(revealSystemClipboard ? "Hide" : "Show")
                }
                .disabled(systemClipboardContent == nil)
                Button {
                    NSPasteboard.general.markSeen(NSPasteboard.general.copiClear())
                    updateSystemPasteboardItem()
                } label: {
                    Text("Clear")
                }
            }
        }
    }
    
    // other settings
    var others: some View {
        VStack(alignment: .leading) {
            LaunchAtLogin.Toggle()
            Toggle("Restart Copi If It Stops Unexpectedly", isOn: guarded(.restartAfterCrash, $restartAfterCrash))
            Text("If Copi crashes or is force quit, it opens again within a couple of seconds. Use Quit Copi below to stop it.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Quit Copi") {
                NSApp.terminate(nil)
            }
        }
        .controlSize(.regular)
    }
    
    // MARK: - Methods
    // 面板每次出现都会调用；变化通过上面的 onReceive 订阅（之前每次出现都往剪贴板上追加一组钩子，越积越多）
    func onStart() {
        isAccessibilityPermitted = AXSwift.checkIsProcessTrusted()
        editors = VSCodeFamilyEditor.installed()
        refreshTerminalPermissions()
        refreshKeystrokeObservers()
        refreshSystemFeatures()
        refreshNotificationSettings()
        updateSystemPasteboardItem()
        updateSecurePasteboard()
    }
    
    func updateSystemPasteboardItem() {
        let items = NSPasteboard.general.pasteboardItems ?? []
        // Copi 占住剪贴板的占位项当作空
        let item = PasteboardOwnership.isPlaceholder(items) ? nil : items.first
        let concealedTypes: Set<NSPasteboard.PasteboardType> = [.nspasteboardConcealed, .nspasteboardTransient]
        let types = item?.types ?? []
        systemClipboardConcealed = TransientPaste.shared.isActive || !Set(types).isDisjoint(with: concealedTypes) || types.contains(where: { $0.isCopiStaged })
        systemClipboardRemote = types.contains(.universalClipboardRemote)
        let newContent = systemClipboardConcealed || systemClipboardRemote ? nil : item
        if newContent?.types != systemClipboardContent?.types || NSPasteboard.general.changeCount != shownSystemChangeCount {
            // 换了内容就重新隐藏
            revealSystemClipboard = false
        }
        shownSystemChangeCount = NSPasteboard.general.changeCount
        systemClipboardContent = newContent
        systemClipboardTypeSelection = systemClipboardContent?.types.first?.rawValue ?? ""
    }
    
    func updateSecurePasteboard() {
        let text = SecureClipboard.shared.text
        if text != copiClipboardText {
            // 换了内容就重新隐藏
            revealCopiClipboard = false
        }
        copiClipboardText = text
        copiClipboardConcealed = SecureClipboard.shared.isConcealed
        copiClipboardNonText = NonTextClipboard.shared.summary
    }

    func bridgeStatus(_ editor: VSCodeFamilyEditor) -> String {
        let running = NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.standardizedFileURL == editor.bundleURL.standardizedFileURL }
        if running.contains(where: { EditorBridge.shared.isConnected(appPID: $0.processIdentifier) }) {
            return "Connected"
        }
        if running.contains(where: { EditorBridge.shared.hasOutdatedConnection(appPID: $0.processIdentifier) }) {
            return "Outdated"
        }
        // 装着的是旧版本：编辑器可能根本没加载它，要重新安装
        if editor.isBridgeInstalled, !editor.isBridgeCurrent {
            return "Outdated"
        }
        return editor.isBridgeInstalled ? "Installed" : "Not installed"
    }

    func terminalStatus(_ terminal: TerminalScript) -> String {
        switch terminalPermissions[terminal] {
        case .allowed?:
            return terminal.usesAppleEvents ? "Allowed" : "Ready"
        case .denied?:
            return "Not allowed"
        case .notDetermined?:
            return terminal == .wezterm ? "Not available" : "Not set up"
        case .notRunning?:
            return "Not running"
        case .unsupported?:
            return "Needs kitty 0.32.2+"
        case nil:
            return "Checking…"
        }
    }

    // 先显示缓存里的状态，再在后台重新查（系统查询要和终端进程通信，终端卡住时会一直等）
    func refreshTerminalPermissions() {
        for terminal in TerminalScript.all {
            guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: terminal.bundleIdentifier).first else {
                terminalPermissions[terminal] = .notRunning
                continue
            }
            let pid = running.processIdentifier
            terminalPermissions[terminal] = TerminalScript.cachedPermission(pid: pid)
            TerminalScript.refreshPermission(pid: pid) { result in
                terminalPermissions[terminal] = result
            }
        }
    }

    // 系统只能对运行着的 App 询问；拒绝过的只能到系统设置里打开
    func requestTerminalPermission(_ terminal: TerminalScript) {
        terminalMessage = nil
        guard terminal.usesAppleEvents else {
            return
        }
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: terminal.bundleIdentifier).first else {
            terminalMessage = "Open \(terminal.displayName) first, then click Allow."
            return
        }
        if terminalPermissions[terminal] == .denied {
            terminalMessage = "Turn on \(terminal.displayName) under Copi in System Settings › Privacy & Security › Automation."
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        requestingTerminal = terminal
        let pid = running.processIdentifier
        DispatchQueue.global(qos: .userInitiated).async {
            let result = TerminalScript.requestPermission(pid: pid)
            DispatchQueue.main.async {
                requestingTerminal = nil
                refreshTerminalPermissions()
                if result == .notRunning {
                    terminalMessage = "Open \(terminal.displayName) first, then click Allow."
                }
            }
        }
    }

    func installBridge(into editor: VSCodeFamilyEditor) {
        installingEditor = editor.bundleURL.path
        bridgeMessage = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let failure = editor.installBridge()
            DispatchQueue.main.async {
                installingEditor = nil
                bridgeMessage = failure ?? "Installed in \(editor.name). Restart \(editor.name) (or run Developer: Reload Window) to connect."
                editors = VSCodeFamilyEditor.installed()
            }
        }
    }

    func appDisplayName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return bundleID
        }
        return FileManager.default.displayName(atPath: url.path)
    }

    func addNormalClipboardApps() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Use Normal Clipboard"
        // 菜单栏 App 平时不激活，不激活的话面板会被别的窗口挡住
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else {
            return
        }
        for url in panel.urls {
            if let bundleID = Bundle(url: url)?.bundleIdentifier {
                // 告诉 SettingsGuard 这是用户自己加的
                SettingsGuard.userWillAllowNormalClipboard(bundleID)
                ZeroExposurePolicy.allowNormalClipboard(for: bundleID)
            }
        }
    }
}

// 用户在菜单里改设置：先告诉 SettingsGuard 这一项是用户自己改的，再写
private func guarded<Value>(_ key: Defaults.Key<Value>, _ binding: Binding<Value>) -> Binding<Value> {
    Binding(get: { binding.wrappedValue }, set: { newValue in
        SettingsGuard.userWillSet(key)
        binding.wrappedValue = newValue
    })
}

// 所在窗口不出现在屏幕共享、录屏里
private struct CaptureExcluded: NSViewRepresentable {
    final class Marker: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.sharingType = .none
        }
    }

    func makeNSView(context: Context) -> NSView {
        Marker()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private struct FormHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

#Preview {
    SettingsView()
}
