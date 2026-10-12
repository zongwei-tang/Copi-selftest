//
//  SecureYourClipboardApp.swift
//  SecureYourClipboard
//
//  Created by lixindong on 2024/3/25.
//

import SwiftUI
import KeyboardShortcuts
import Defaults
import AXSwift
import ApplicationServices
import UserNotifications

@main
enum CopiLauncher {
    @MainActor
    static func main() {
        // 看门进程（见 CrashWatchdog）：不启动界面，只等 Copi 退出
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: CrashWatchdog.argument), index + 1 < arguments.count {
            CrashWatchdog.run(bundlePath: arguments[index + 1], history: index + 2 < arguments.count ? arguments[index + 2] : "")
        }
        CopiApp.main()
    }
}

struct CopiApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self)
    var appDelegate

    @StateObject var switchListVM: SwitchListVM = SwitchListVM()
    @ObservedObject private var protectionStatus = ProtectionStatus.shared

    var body: some Scene {
        WindowGroup {
            EmptyView()
                .frame(width: 0, height: 0)
                .onAppear(perform: {
                    NSApp.setActivationPolicy(.accessory)
                })
        }
        .windowResizability(.contentSize)

        MenuBarExtra {
            SettingsView()
        } label: {
            // 没在保护时（关着、暂停了）菜单栏图标换成警告：不用打开面板也看得到
            switch protectionStatus.state {
            case .protecting, .manual:
                // 别的程序调低了保护、用户还没看过：也显示警告
                Image(systemName: protectionStatus.unexplainedChange == nil ? "square.stack.3d.down.forward" : "exclamationmark.triangle")
            case .off, .paused, .limited:
                Image(systemName: "exclamationmark.triangle")
            }
        }
        .menuBarExtraStyle(.window)
        .windowResizability(.contentSize)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {

    func applicationWillFinishLaunching(_ notification: Notification) {
        // 必须在启动完成前设置，才能收到通知按钮（"这个 App 照常使用系统剪贴板"）的点击
        UNUserNotificationCenter.current().delegate = self
        // 看门进程尽早起来：启动过程中就崩溃的话也能重新打开
        CrashWatchdog.update()
        // 退出时一定要走 applicationWillTerminate（撤下剪贴板上的临时内容、告诉看门进程这是正常退出）：
        // 不让系统在注销、内存紧张时不打招呼直接结束 Copi
        ProcessInfo.processInfo.disableSuddenTermination()
        ProcessInfo.processInfo.disableAutomaticTermination("Copi protects the clipboard")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 本进程所有 Accessibility 调用的超时（系统默认约 6 秒）。目标 App 卡住或正在构建无障碍树时，
        // 宁可很快判定失败、改走 ⌘C/⌘V 回退，也不要长时间卡住复制/粘贴。
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.2)
        // 旧版本把安全剪贴板放在命名剪贴板 "safeCopy"（以及 "selected"）里，任何进程都能读，而且退出后仍留在
        // 系统剪贴板服务里直到注销。升级后把残留的内容清掉。
        for name in ["safeCopy", "selected"] {
            let legacy = NSPasteboard(name: NSPasteboard.Name(name))
            legacy.clearContents()
            legacy.releaseGlobally()
        }
        NSPasteboard.general.startListening()
        requestNotificationAuthorization()
        noteLaunchAndReportUnexpectedExit()

        GlobalMode.shared.initialize()
        SettingsGuard.start()
        ManualMode.shared.initialize()
        WhiteListMode.shared.initialize()
        WebAccessibilityWarmer.shared.start()
        // VS Code 系编辑器里的 Copi Bridge 扩展连到这里
        EditorBridge.shared.start()
        // 崩溃、被强制退出后自动重新打开（看门进程在 applicationWillFinishLaunching 里已经起来了）
        watchdogObservation = Defaults.observe(keys: .restartAfterCrash) {
            DispatchQueue.main.async {
                CrashWatchdog.update()
            }
        }
    }

    private var watchdogObservation: Any?

    // 菜单栏面板开着时 Copi 是前台 App，不实现这个的话通知不会显示
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        // 虚拟机、远程桌面不放行（它们会把系统剪贴板同步到客户机上、留在那里）：更新之前发出、还留在通知中心里的通知可能还带着按钮
        if response.actionIdentifier == CopiNotificationAction.useNormalClipboard,
           let bundleID = userInfo[CopiNotificationAction.bundleIDKey] as? String, !isRemoteDesktopApp(bundleID) {
            let appName = userInfo[CopiNotificationAction.appNameKey] as? String ?? bundleID
            DispatchQueue.main.async {
                SettingsGuard.userWillAllowNormalClipboard(bundleID)
                ZeroExposurePolicy.allowNormalClipboard(for: bundleID)
                notifyCopiNotice("Text you copy in \(appName) now stays on the system clipboard as usual. Text copied in other apps is still pasted there without it. You can change this in Copi's menu.")
            }
        }
        completionHandler()
    }

    // 上次是不是没有正常退出（崩溃、被强制退出）：那段时间里 ⌘C/⌘V 用的是系统剪贴板，告诉用户。
    // 启动时记下"正在运行"，正常退出时清掉；启动时发现还记着，就说明上次没走到正常退出
    private let runningMarkerKey = "copiRunning"

    private func noteLaunchAndReportUnexpectedExit() {
        let defaults = UserDefaults.standard
        // 看门进程留下的话（见 CrashWatchdog.run）
        let killedHung = defaults.bool(forKey: CrashWatchdog.killedHungKey)
        let quitBy = defaults.string(forKey: quitByOtherKey)
        defaults.removeObject(forKey: quitByOtherKey)
        let gaveUp = defaults.bool(forKey: CrashWatchdog.gaveUpKey)
        defaults.removeObject(forKey: CrashWatchdog.killedHungKey)
        defaults.removeObject(forKey: CrashWatchdog.gaveUpKey)
        if gaveUp {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                notifyCopiNotice("Copi stopped several times in a row and didn't reopen by itself. While it wasn't running, ⌘C and ⌘V used the system clipboard, so text copied then may have been visible to other apps.")
            }
        } else if killedHung {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                notifyCopiNotice("Copi stopped responding (it was stuck or paused), so it was restarted. Meanwhile copies other apps made stayed on the system clipboard.")
            }
        } else if let quitBy {
            // 存的是 "名字|bundleID"：名字别的程序能随便写，清理之后再显示
            // 按最后一个 "|" 分开（bundle ID 里没有 "|"，名字里可能有）
            let separator = quitBy.lastIndex(of: "|")
            let name = separator.map { String(quitBy[..<$0]) } ?? quitBy
            let bundleID = separator.map { String(quitBy[quitBy.index(after: $0)...]) }
            let quitter = noticeSafeAppName(name.isEmpty ? nil : name, bundleID: bundleID?.isEmpty == false ? bundleID : nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                notifyCopiNotice("\(quitter) quit Copi, so Copi started again. While it wasn't running, ⌘C and ⌘V used the system clipboard. To quit Copi yourself, use Quit Copi in its menu.")
            }
        } else if defaults.bool(forKey: runningMarkerKey) {
            // 稍等一下再发：刚启动时通知权限的申请可能还没完成
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                notifyCopiNotice("Copi stopped unexpectedly and has started again. While it wasn't running, ⌘C and ⌘V used the system clipboard, so text copied then may have been visible to other apps.")
            }
        }
        defaults.set(true, forKey: runningMarkerKey)
    }

    // 别的程序（以同一用户身份运行的任何程序都可以）发来的"退出"请求：照常退出，但不当作用户自己退出——看门进程会把 Copi
    // 重新打开，下次启动时告诉用户是谁让它退出的。Copi 自己的"退出"按钮（没有 Apple Event）、注销、关机、重启（由 loginwindow 发来）
    // 不算。按发送者判断，不看事件里的退出原因：那是发送者自己填的，谁都可以带上
    private let quitByOtherKey = "copiQuitByOtherProgram"
    private var quitByOtherProgram: String?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        quitByOtherProgram = nil
        if let event = NSAppleEventManager.shared().currentAppleEvent,
           event.eventClass == fourCharCode("aevt"), event.eventID == fourCharCode("quit") {
            // 发送者的进程号由系统填写
            let pid = event.attributeDescriptor(forKeyword: fourCharCode("spid"))?.int32Value ?? 0
            let sender = pid > 0 && pid != getpid() ? NSRunningApplication(processIdentifier: pid) : nil
            if sender?.bundleIdentifier != "com.apple.loginwindow" {
                quitByOtherProgram = (sender?.localizedName ?? "") + "|" + (sender?.bundleIdentifier ?? "")
            }
        }
        return .terminateNow
    }

    private func fourCharCode(_ code: String) -> UInt32 {
        code.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let quitter = quitByOtherProgram, Defaults[.restartAfterCrash] {
            // 不写"正常退出"：看门进程会重新打开 Copi（它刚好不在的话先起一个）
            CrashWatchdog.ensureRunning()
            UserDefaults.standard.set(quitter, forKey: quitByOtherKey)
        } else {
            UserDefaults.standard.set(false, forKey: runningMarkerKey)
            // 正常退出：看门进程不要重新打开 Copi
            CrashWatchdog.stop()
        }
        UserDefaults.standard.synchronize()
        // 撤下还挂在系统剪贴板上的临时粘贴内容：退出后它就没人提供了，AppKit 退出时还会尝试兑现这个承诺
        TransientPaste.shared.finish()
        // 占位项退出后也没人提供了：撤掉，剪贴板回到真正的空
        PasteboardOwnership.shared.release(NSPasteboard.general)
    }
}
