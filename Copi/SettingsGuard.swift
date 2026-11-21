//
//  SettingsGuard.swift
//  Copi
//
//  Copi 的设置存在普通的偏好设置里，以同一用户身份运行的任何程序都能改（defaults write）。别的程序悄悄关掉保护
//  （关掉 Copi、不接管 ⌘C/⌘V、允许剪贴板回退、把浏览器加进"照常使用系统剪贴板"……）时，用户的复制就会留在系统剪贴板上，
//  却什么都不知道。所以看到保护被调低、而这一项不是用户刚在 Copi 的菜单里自己改的，就发通知告诉用户。
//  只放过用户刚改的那一项（不是"菜单开着时的所有改动"：菜单开没开着，别的程序不用任何权限就看得出来）。不自动改回：可能是用户用
//  别的方式改的，而且对方可以再改一次
//

import Foundation
import AppKit
import Defaults

enum SettingsGuard {
    // 主线程：用户刚在菜单里改的设置项（key 的名字）和期限
    private static var intended: [String: Date] = [:]
    // 主线程：用户刚加进"照常使用系统剪贴板"的 App 和期限
    private static var intendedApps: [String: Date] = [:]
    private static var snapshot: Snapshot?
    private static var observation: Any?

    // Safe Copy、Safe Paste 快捷键（KeyboardShortcuts 存在偏好设置里的 JSON：{"carbonKeyCode":…,"carbonModifiers":…}）
    private static let safeCopyShortcut = Defaults.Key<String?>("KeyboardShortcuts_safeCopy", default: nil)
    private static let safePasteShortcut = Defaults.Key<String?>("KeyboardShortcuts_safePaste", default: nil)

    private struct Snapshot: Codable {
        var isOn: Bool
        var overrideShortcuts: Bool
        var allowClipboardFallback: Bool
        var normalClipboardApps: Set<String>
        var restartAfterCrash: Bool
        var blockTextDragging: Bool
        var clearOnLock: Bool
        var refuseTypingWhenWatched: Bool
        var instantClipboardDetection: Bool
        var constantFastCheck: Bool
        var autoClearMinutes: Int
        var typePrivately: Bool
        var typeIntoVirtualMachines: Bool?
        // Safe Copy 或 Safe Paste 的快捷键没有 ⌘、⌥、⌃（单独的 ↩、字母……）：每按一次这个键就会复制、粘贴
        var unmodifiedShortcut: Bool?

        static var current: Snapshot {
            Snapshot(isOn: Defaults[.isOn], overrideShortcuts: Defaults[.overrideShortcuts],
                     allowClipboardFallback: Defaults[.allowClipboardFallback], normalClipboardApps: Set(Defaults[.normalClipboardApps]),
                     restartAfterCrash: Defaults[.restartAfterCrash], blockTextDragging: Defaults[.blockTextDragging],
                     clearOnLock: Defaults[.clearOnLock], refuseTypingWhenWatched: Defaults[.refuseTypingWhenWatched],
                     instantClipboardDetection: Defaults[.instantClipboardDetection], constantFastCheck: Defaults[.constantFastCheck],
                     autoClearMinutes: Defaults[.autoClearMinutes], typePrivately: Defaults[.typePrivately],
                     typeIntoVirtualMachines: Defaults[.typeIntoVirtualMachines],
                     unmodifiedShortcut: isUnmodified(Defaults[safeCopyShortcut]) || isUnmodified(Defaults[safePasteShortcut]))
        }

        // 和 old 比，哪些保护被调低了：(key 的名字, 用户能看懂的说法)
        func loweredSince(_ old: Snapshot) -> [(key: String, text: String)] {
            var lowered: [(key: String, text: String)] = []
            func check(_ condition: Bool, _ key: String, _ text: String) {
                if condition {
                    lowered.append((key, text))
                }
            }
            check(old.isOn && !isOn, Defaults.Keys.isOn.name, "Copi was turned off")
            check(old.overrideShortcuts && !overrideShortcuts, Defaults.Keys.overrideShortcuts.name, "Override ⌘C/⌘V was turned off")
            check(!old.allowClipboardFallback && allowClipboardFallback, Defaults.Keys.allowClipboardFallback.name,
                  "Allow Clipboard Fallback was turned on")
            for app in normalClipboardApps.subtracting(old.normalClipboardApps).sorted() {
                lowered.append(("normalClipboardApps:" + app, "\(noticeSafeAppName(bundleID: app)) was added to Apps Using the Normal Clipboard"))
            }
            check(old.restartAfterCrash && !restartAfterCrash, Defaults.Keys.restartAfterCrash.name,
                  "Restart Copi If It Stops Unexpectedly was turned off")
            check(old.blockTextDragging && !blockTextDragging, Defaults.Keys.blockTextDragging.name, "Block Dragging Text was turned off")
            check(old.clearOnLock && !clearOnLock, Defaults.Keys.clearOnLock.name, "Clear Copi Clipboard When Mac Locks was turned off")
            check(old.refuseTypingWhenWatched && !refuseTypingWhenWatched, Defaults.Keys.refuseTypingWhenWatched.name,
                  "Don't Type When Keystrokes Are Watched was turned off")
            check(old.instantClipboardDetection && !instantClipboardDetection, Defaults.Keys.instantClipboardDetection.name,
                  "Instant Clipboard Detection was turned off")
            check(old.constantFastCheck && !constantFastCheck, Defaults.Keys.constantFastCheck.name, "Constant Fast Check was turned off")
            check(old.typePrivately && !typePrivately, Defaults.Keys.typePrivately.name, "Type Privately was turned off")
            check(old.autoClearMinutes > 0 && (autoClearMinutes <= 0 || autoClearMinutes > old.autoClearMinutes), Defaults.Keys.autoClearMinutes.name,
                  "Clear Copi Clipboard After was lengthened")
            check(old.typeIntoVirtualMachines == false && typeIntoVirtualMachines == true, Defaults.Keys.typeIntoVirtualMachines.name,
                  "Type Into Virtual Machines was turned on")
            check(old.unmodifiedShortcut != true && unmodifiedShortcut == true, "shortcuts",
                  "Safe Copy or Safe Paste was set to a key without ⌘, ⌥ or ⌃")
            return lowered
        }
    }

    private static func isUnmodified(_ json: String?) -> Bool {
        guard let data = json?.data(using: .utf8),
              let shortcut = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let modifiers = (shortcut["carbonModifiers"] as? NSNumber)?.intValue else {
            return false
        }
        // 只有 ⇧ 也算（Carbon 的 cmdKey 256、optionKey 2048、controlKey 4096）
        return modifiers & (256 | 2048 | 4096) == 0
    }

    // 上一次运行时最后的设置（偏好设置里）：Copi 不在运行时被改低的（例如它被结束、还没重新打开的那一会儿），下次启动时也能发现。
    // 一个专门针对 Copi 的程序可以连这个一起改，这只防随手改设置的程序和脚本
    private static let savedKey = "settingsGuardSnapshot"

    // 主线程：启动时调用一次
    static func start() {
        guard observation == nil else {
            return
        }
        let current = Snapshot.current
        if let data = UserDefaults.standard.data(forKey: savedKey), let saved = try? JSONDecoder().decode(Snapshot.self, from: data) {
            let lowered = current.loweredSince(saved)
            if !lowered.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    notifyCopiNotice("While Copi wasn't running, its settings were changed: \(describe(lowered)). If you didn't do this, open Copi's menu and change it back.")
                }
                ProtectionStatus.shared.noteUnexplainedChange("While Copi wasn't running: " + describe(lowered) + ".")
            }
        }
        snapshot = current
        save(current)
        // 注册时会立即回调一次：和刚记下的一样，不会提醒
        observation = Defaults.observe(keys: .isOn, .overrideShortcuts, .allowClipboardFallback, .normalClipboardApps, .restartAfterCrash,
                                       .blockTextDragging, .clearOnLock, .refuseTypingWhenWatched, .instantClipboardDetection,
                                       .constantFastCheck, .autoClearMinutes, .typePrivately, .typeIntoVirtualMachines,
                                       safeCopyShortcut, safePasteShortcut) {
            DispatchQueue.main.async {
                check()
            }
        }
    }

    // 主线程：用户马上要在 Copi 的菜单里改这一项
    // （快捷键由菜单里的录制控件自己写，看不到是不是用户录的：设成没有修饰键的总是提醒，用户自己设的也提醒一下无妨）
    static func userWillSet(_ key: Defaults._AnyKey) {
        intended[key.name] = Date().addingTimeInterval(1.5)
    }

    // 主线程：用户马上要把这个 App 加进"照常使用系统剪贴板"（通知上的按钮、Add App…）
    static func userWillAllowNormalClipboard(_ bundleID: String) {
        intendedApps[bundleID] = Date().addingTimeInterval(2)
    }

    private static func save(_ snapshot: Snapshot) {
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: savedKey)
        }
    }

    private static func check() {
        let now = Snapshot.current
        defer {
            snapshot = now
            save(now)
        }
        guard let old = snapshot else {
            return
        }
        let date = Date()
        let lowered = now.loweredSince(old).filter { item in
            if item.key.hasPrefix("normalClipboardApps:") {
                return (intendedApps[String(item.key.dropFirst("normalClipboardApps:".count))] ?? .distantPast) < date
            }
            return (intended[item.key] ?? .distantPast) < date
        }
        guard !lowered.isEmpty else {
            return
        }
        notifyCopiNotice("Another program changed Copi's settings: \(describe(lowered)). If you didn't do this, open Copi's menu and change it back.")
        // 关掉了通知的用户也要看得到（快捷键可能是用户自己在菜单里录的，看不出来，只发通知）
        let others = lowered.filter { $0.key != "shortcuts" }
        if !others.isEmpty {
            ProtectionStatus.shared.noteUnexplainedChange(describe(others) + ".")
        }
    }

    private static func describe(_ lowered: [(key: String, text: String)]) -> String {
        var texts = lowered.prefix(4).map(\.text)
        if lowered.count > 4 {
            texts.append("and \(lowered.count - 4) more")
        }
        return texts.joined(separator: "; ")
    }
}

// 通知里显示的 App 名字：偏好设置、Apple Event 里的名字别的程序能随便写（换行、很长的话、伪装成 Copi 的说明），
// 去掉控制字符、截短，加上引号。bundleID 认得出来的话用 App 自己的名字
func noticeSafeAppName(_ name: String? = nil, bundleID: String? = nil) -> String {
    let validBundleID = bundleID.flatMap { $0.range(of: #"^[A-Za-z0-9.-]{1,155}$"#, options: .regularExpression) != nil ? $0 : nil }
    if let validBundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: validBundleID) {
        return "“" + noticeSafeText(FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")) + "”"
    }
    if let name, !noticeSafeText(name).isEmpty {
        return "“" + noticeSafeText(name) + "”"
    }
    return validBundleID ?? "Another program"
}

// 一句说明（别的程序可能写进偏好设置里的）：去掉控制字符、合并空白，最多 600 个字符（Copi 自己写的最长的说明也放得下）
func noticeSafeSentence(_ text: String) -> String {
    noticeSafeText(text, limit: 600)
}

private func noticeSafeText(_ text: String, limit: Int = 32) -> String {
    var cleaned = String.UnicodeScalarView()
    for scalar in text.unicodeScalars {
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator:
            continue
        default:
            cleaned.append(scalar)
        }
    }
    let collapsed = String(cleaned).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return collapsed.count > limit ? String(collapsed.prefix(limit)) + "…" : collapsed
}
