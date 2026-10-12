//
//  SystemClipboardFeatures.swift
//  Copi
//
//  macOS 自己会看系统剪贴板的功能。别的 App 自己写进剪贴板的内容（复制按钮、pbcopy）在 Copi 转走之前停留的几毫秒里，
//  它们也可能读到，Copi 管不了，只能告诉用户、给出关掉的地方：
//   - Spotlight 的剪贴板历史（macOS 26 起）：把剪贴板上的文字记进 Spotlight 的索引（默认保留 8 小时），没有接口能删；
//   - 接力（Handoff）里的通用剪贴板：向附近的设备广播"刚复制了东西"，别的设备粘贴时再来取（Copi 自己写的内容不会被同步）；
//   - "从其他 App 粘贴"的隐私控制（macOS 15.4 起有接口，目前的系统还没有真正启用）：一旦生效并且没有允许 Copi，Copi 读别的 App
//     写进来的文字时系统会弹窗或者拒绝，这些文字就转不走了。
//  只读设置值，不改它们。
//

import Foundation
import AppKit

enum SystemClipboardFeatures {
    enum State: Equatable {
        case on
        case off
        // 读不到设置（新装的系统上可能还没有这个值，按可能开着处理）
        case unknown
    }

    // Spotlight 的剪贴板历史；macOS 26 以前没有这个功能
    static var spotlightHistory: State? {
        guard ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)) else {
            return nil
        }
        let domain = "com.apple.Spotlight" as CFString
        CFPreferencesAppSynchronize(domain)
        guard let value = CFPreferencesCopyAppValue("PasteboardHistoryEnabled" as CFString, domain) as? Bool else {
            return .unknown
        }
        return value ? .on : .off
    }

    // Spotlight 剪贴板历史保留多久（秒）；读不到时为 nil
    static var spotlightHistoryRetention: TimeInterval? {
        (CFPreferencesCopyAppValue("PasteboardHistoryTimeout" as CFString, "com.apple.Spotlight" as CFString) as? NSNumber)?.doubleValue
    }

    // 接力（通用剪贴板随它一起开关）：没有这个值时是开着的
    static var handoff: State {
        let domain = "com.apple.coreservices.useractivityd" as CFString
        let advertising = CFPreferencesCopyValue("ActivityAdvertisingAllowed" as CFString, domain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost) as? Bool
        return advertising == false ? .off : .on
    }

    enum PasteboardAccess {
        // 系统没有限制（或者用户允许了 Copi）
        case allowed
        // 每次读别的 App 写进来的内容都要问
        case ask
        // 读不到别的 App 写进来的内容
        case denied
    }

    // NSPasteboard.accessBehavior（macOS 15.4 起）：用 Key-Value Coding 读，旧的 SDK 编译、旧的系统运行都没问题。
    // 0 default（从没弹过窗：系统还没启用这项控制，或者还没轮到 Copi）、1 ask、2 alwaysAllow、3 alwaysDeny；没有这项时为 nil
    private static var accessBehavior: Int? {
        let pasteboard = NSPasteboard.general
        guard pasteboard.responds(to: NSSelectorFromString("accessBehavior")) else {
            return nil
        }
        return (pasteboard.value(forKey: "accessBehavior") as? NSNumber)?.intValue
    }

    static var pasteboardAccess: PasteboardAccess {
        guard let raw = accessBehavior else {
            return .allowed
        }
        switch raw {
        case 1:
            return .ask
        case 3:
            return .denied
        default:
            return .allowed
        }
    }

    // 主线程：上次查到的"从其他 App 粘贴"的状态（每秒的体检里更新，见 refresh）。受限时（ask、denied）Copi 在主线程忙的间隙里
    // 不去读别的 App 写进来的内容：系统会弹出模态的询问，把正在处理的 ⌘C/⌘V 卡住
    private(set) static var cachedPasteboardAccess: PasteboardAccess = .allowed
    // 主线程：读别的 App 写进来的内容时系统可能弹出询问（default：还没问过、第一次读就会问；ask）。这期间请看门进程别把 Copi 当成卡死
    private(set) static var cachedMayPrompt = false
    private static let spotlightNoticeKey = "spotlightHistoryNoticeShown"

    // 主线程：每秒的体检里调用。"从其他 App 粘贴"变成受限时提醒一次
    // 主线程：读过一次、状态还是 default（没有弹窗）：这个系统上还没启用这项控制，default 不再当作"可能会问"
    private static var defaultNeverPrompted = false

    // 主线程：Copi 刚读完别的 App 写进来的内容
    static func noteReadCompleted() {
        if accessBehavior == 0 {
            defaultNeverPrompted = true
            cachedMayPrompt = false
        }
    }

    static func refresh() {
        cachedMayPrompt = accessBehavior.map { $0 == 1 || ($0 == 0 && !defaultNeverPrompted) } ?? false
        let access = pasteboardAccess
        guard access != cachedPasteboardAccess else {
            return
        }
        cachedPasteboardAccess = access
        // 菜单栏图标、面板顶上的状态跟着变（受限时显示警告）
        GlobalMode.shared.updateOverrideState()
        if access != .allowed {
            notifyCopiNotice("macOS now asks before Copi reads text other apps put on the clipboard, so Copi may not be able to move those copies off it. Set Copi to Allow under System Settings › Privacy & Security › Paste from Other Apps.")
        }
    }

    // 主线程：启动后调用一次。Spotlight 的剪贴板历史开着时提醒一次（只提醒这一次）
    static func noticeSpotlightHistoryOnce() {
        guard spotlightHistory == .on, !UserDefaults.standard.bool(forKey: spotlightNoticeKey) else {
            return
        }
        UserDefaults.standard.set(true, forKey: spotlightNoticeKey)
        notifyCopiNotice("Spotlight is keeping a clipboard history. Copies apps make by themselves (a Copy button, pbcopy) can be recorded there before Copi moves them off the clipboard. You can turn off Results from Clipboard in System Settings › Spotlight.")
    }

    // 系统设置里对应的地方
    static let spotlightSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Spotlight-Settings.extension")
    static let handoffSettingsURL = URL(string: "x-apple.systempreferences:com.apple.AirDrop-Handoff-Settings.extension")
    static var pasteboardPrivacySettingsURL: URL? {
        if ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)) {
            return URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Pasteboard")
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard")
    }
}
