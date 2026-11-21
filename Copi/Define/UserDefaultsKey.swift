//
//  UserDefaultsKey.swift
//  SecureYourClipboard
//
//  Created by lixindong on 2024/4/13.
//

import Foundation
import Defaults

extension Defaults.Keys {

    static let showQuickActions = Key<Bool>("showQuickActions", default: true)
    // 接管 ⌘C/⌘X/⌘V：默认打开（关着时普通的 ⌘C/⌘V 照常经过系统剪贴板，只有 Copi 自己的快捷键和 Action Bar 受保护）
    static let overrideShortcuts = Key<Bool>("overrideShortcuts", default: true)
    static let isOn = Key<Bool>("isOn", default: true)
    static let notifyOnProtect = Key<Bool>("notifyOnProtect", default: true)
    // 0 暴露是默认：找不到不经过系统剪贴板的办法时拒绝并通知。打开这个开关后改为退回加固过的剪贴板方式（文字会短暂出现在系统剪贴板上）。
    // 换了新的 key：旧的 "strictZeroExposure" 默认是关的，沿用它会让已经装过的用户留在会暴露的模式里
    static let allowClipboardFallback = Key<Bool>("allowClipboardFallback", default: false)
    // 用户放行的 App（bundle ID）：在这些 App 里 ⌘C/⌘V 照常使用系统剪贴板（例如需要保留自己粘贴处理的代码编辑器）
    static let normalClipboardApps = Key<[String]>("normalClipboardApps", default: [])
    // 拼音等输入法开着时，模拟键入前临时切到英文键盘布局，打完切回去
    static let switchInputSourceForTyping = Key<Bool>("switchInputSourceForTyping", default: true)
    // 虚拟机、远程桌面的画面里按真实的按键输入单行文字。Copi 看不到客户机里在运行什么（vim 的普通模式、less 里字母是命令），
    // 所以要用户自己打开
    static let typeIntoVirtualMachines = Key<Bool>("typeIntoVirtualMachines", default: false)
    // 拖动选中的文字时不让它进拖放剪贴板（不让这次拖动开始）。关掉后照常拖放，放下半秒后清掉
    static let blockTextDragging = Key<Bool>("blockTextDragging", default: true)
    // 别的程序一写系统剪贴板就知道，不用等下一次轮询：收听 macOS 内部的剪贴板变化通知（Chrome 也这样做），收不到时占住系统剪贴板
    // （一个别人认不出的占位项）。默认开：App 自己写进来的复制（复制按钮、密码管理器）停留的时间更短
    static let instantClipboardDetection = Key<Bool>("instantClipboardDetection", default: true)
    // 一直每 3 毫秒检查一次系统剪贴板（平时每 20 毫秒，点击、组合键之后半秒内每 4 毫秒）：别的程序自己写进来的复制
    // 停留的时间更短，代价是更费电（默认关）
    static let constantFastCheck = Key<Bool>("constantFastCheck", default: false)
    // 模拟键入时把按键直接发给目标 App（CGEventPostToPid），全系统的键盘 tap 看不到（实验功能，默认关：有的 App 可能不认这样的按键）
    static let typePrivately = Key<Bool>("typePrivately", default: false)
    // 有第三方程序装着能看到按键的 event tap 时，不用模拟键入的方式粘贴（键入的文字它们都看得到），改为拒绝
    static let refuseTypingWhenWatched = Key<Bool>("refuseTypingWhenWatched", default: false)
    // 锁屏、睡眠、切换用户时清空 Copi 剪贴板
    static let clearOnLock = Key<Bool>("clearOnLock", default: true)
    // 复制进 Copi 的内容过多少分钟自动清掉（0：不自动清除）。密码管理器的复制另有 90 秒的期限
    static let autoClearMinutes = Key<Int>("autoClearMinutes", default: 0)
    // Copi 崩溃、被强制退出后自动重新打开（见 CrashWatchdog）
    static let restartAfterCrash = Key<Bool>("restartAfterCrash", default: true)
    // 当作"不是在复制文字"放行了原生 ⌘C、结果复制出来的却是文字的地方（"bundleID|AX 角色"），以后在这里拒绝
    static let misjudgedNonTextContexts = Key<[String]>("misjudgedNonTextContexts", default: [])
    // 在 Chrome / Electron / Firefox 被激活时打开它们的无障碍树（网页里 0 暴露复制粘贴的前提）
    static let enableWebAccessibility = Key<Bool>("enableWebAccessibility", default: true)
}
