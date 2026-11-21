//
//  ManualMode.swift
//  SecureYourClipboard
//
//  Created by lixindong on 2024/4/19.
//

import Foundation
import KeyboardShortcuts
import AppKit
import Defaults
import AXSwift

class ManualMode {
    static let shared = ManualMode()

    private var observation: Any? = nil
    // 粘贴快捷键按下的时刻（主线程）：松开时据此判断是不是用户亲手按的
    private var safePastePressedAt: Date?

    func initialize() {
        KeyboardShortcuts.onKeyUp(for: .safeCopy) {
            guard Defaults[.isOn], !Defaults[.overrideShortcuts] else {
                return
            }
            safeCopySelection()
            PopupWindowController.shared.closeWindow()
        }
        KeyboardShortcuts.onKeyDown(for: .safePaste) {
            guard Defaults[.isOn], !Defaults[.overrideShortcuts] else {
                return
            }
            let now = Date()
            ManualMode.shared.safePastePressedAt = now
            // Secure Input 开着时按键不进硬件层的按键记录：记下这一下，和它这时在键盘上是不是按着（见 hardwareInput）
            if let shortcut = KeyboardShortcuts.getShortcut(for: .safePaste) {
                let flags = CGEventFlags(rawValue: UInt64(shortcut.modifiers.rawValue))
                    .intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl])
                let held = CGEventSource.keyState(.hidSystemState, key: CGKeyCode(shortcut.carbonKeyCode))
                    || (!flags.isEmpty && (CGEventSource.flagsState(.hidSystemState).isSuperset(of: flags)
                        || SecureInputKeys.tapModifiersHeld(flags, at: now)))
                SecureInputKeys.noteHotKeyPress(at: now, held: held)
            }
        }
        KeyboardShortcuts.onKeyUp(for: .safePaste) {
            guard Defaults[.isOn], !Defaults[.overrideShortcuts] else {
                return
            }
            // 热键松开时调用。KeyboardShortcuts 不给按下、松开的时刻，只能从运行时量：按下时记下的时刻（不久之前的才用）之后
            // 键盘上按过键才算用户亲手按的；没记下的话看刚才有没有松开过键（主线程忙过 0.25 秒时，亲手按的也不算确认，要再按一次）
            let pressedAt = ManualMode.shared.safePastePressedAt.flatMap { Date().timeIntervalSince($0) < 2 ? $0 : nil }
            ManualMode.shared.safePastePressedAt = nil
            safePaste(deliberate: pressedAt.map { hardwareInput(.keyDown, at: $0) } ?? hardwareInput(.keyUp, at: Date()))
            PopupWindowController.shared.closeWindow()
        }
        // 全局热键一旦注册就会把按键吞掉：Copi 关闭或处于 Override 模式时上面的处理什么也不做，
        // 却仍然让用户打不出 ⌥C、⌥V 对应的字符（ç、√ 等），所以只在手动模式真正生效时才注册。
        updateShortcutsState()
        observation = Defaults.observe(keys: .isOn, .overrideShortcuts) {
            if Thread.isMainThread {
                ManualMode.shared.updateShortcutsState()
            } else {
                DispatchQueue.main.async { ManualMode.shared.updateShortcutsState() }
            }
        }

        MouseEventCatcher.shared.onSelectEventHooks { event in
            guard AXSwift.checkIsProcessTrusted(), Defaults[.isOn], Defaults[.showQuickActions] else {
                return
            }

            let location = event.locationInWindow
            // 粘贴只在按下的地方就是拿着焦点的输入框时提供（拖窗口、长按标签、空白处不提供），并记下这个输入框
            let pasteTarget = SecureClipboard.shared.hasText ? ManualMode.actionBarPasteTarget(at: location) : nil
            Task {
                let canCopy = hasSelectedTextViaAX()

                if canCopy || pasteTarget != nil {
                    await PopupWindowController.shared.showWindowAt(location, canCopy: canCopy, pasteTarget: pasteTarget)
                } else {
                    await PopupWindowController.shared.closeWindow()
                }
            }
        }
        MouseEventCatcher.shared.onUnSelectEventHooks { event in
            PopupWindowController.shared.closeWindow()
        }
        // 之前注册的 Services（Safe Copy / Safe Paste / Process Selected Text）已经移除：任何 App 不需要任何权限就能
        // 用 NSPerformService 调用它们，读出或改写安全剪贴板里的内容。刷新一次，让系统撤掉旧的注册。
        NSUpdateDynamicServices()
    }

    // 主线程：location（屏幕坐标，左下角为原点）处是拿着焦点、Copi 能粘贴进去的地方（输入框、终端、虚拟机的画面，或者它的一部分、
    // 紧紧包着它的编辑器）时返回它
    private static func actionBarPasteTarget(at location: NSPoint) -> AXUIElement? {
        withAXBudget(0.2) {
            guard let target = focusedTarget(),
                  target.isEditableTextControl || target.isSecureTextField || target.isTerminalApp || isRemoteDesktopApp(target.bundleIdentifier) else {
                return nil
            }
            // 辅助功能用的坐标以主屏幕左上角为原点
            let top = NSScreen.screens.first?.frame.maxY ?? 0
            let point = CGPoint(x: location.x, y: top - location.y)
            let hit = PointerInterceptor.element(at: point)
            // 焦点就是整个窗口（Alacritty 这类终端、虚拟机的画面不提供更细的元素）：点在窗口本身上、并且不在标题栏和工具栏
            //（窗口最上面 60 点）里才算
            if (copyAXAttribute(target.element, kAXRoleAttribute) as? String) == kAXWindowRole {
                guard let hit, CFEqual(hit, target.element), let frameTop = axWindowTop(target.element), point.y > frameTop + 60 else {
                    return nil
                }
                return target.element
            }
            if PointerInterceptor.isSelfOrDescendant(hit, of: target.element) {
                return target.element
            }
            // 点在包着它的编辑器上（VS Code、网页里的代码编辑器把焦点放在一个看不见的输入框里）：只认紧挨着的几层，
            // 窗口、工具栏、分栏这类大容器不算（拖窗口、点空白处）
            guard let hit, !((copyAXAttribute(hit, kAXRoleAttribute) as? String).map(actionBarContainerRoles.contains) ?? true),
                  PointerInterceptor.isSelfOrDescendant(target.element, of: hit, maxDepth: 4) else {
                return nil
            }
            return target.element
        }
    }

    // 窗口上边缘的 y（辅助功能坐标）
    private static func axWindowTop(_ window: AXUIElement) -> CGFloat? {
        guard let value = copyAXAttribute(window, kAXPositionAttribute), CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        var origin = CGPoint.zero
        guard AXValueGetValue(value as! AXValue, .cgPoint, &origin) else {
            return nil
        }
        return origin.y
    }

    private static let actionBarContainerRoles: Set<String> = [
        kAXWindowRole, kAXToolbarRole, kAXSheetRole, kAXDrawerRole, kAXSplitGroupRole, kAXTabGroupRole, kAXApplicationRole, kAXMenuBarRole,
        "AXWebArea",
    ]

    private func updateShortcutsState() {
        if Defaults[.isOn], !Defaults[.overrideShortcuts] {
            KeyboardShortcuts.enable(.safeCopy, .safePaste)
        } else {
            KeyboardShortcuts.disable(.safeCopy, .safePaste)
        }
    }
}
