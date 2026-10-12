//
//  MouseEventCatcher.swift
//  SecureYourClipboard
//
//  Created by lixindong on 2024/4/2.
//

import Foundation
import AppKit

class MouseEventCatcher {
    
    static let shared = MouseEventCatcher()
    
    typealias OnSelectEvent = (NSEvent) -> Void
    typealias OnUnSelectEvent = (NSEvent) -> Void
    
    var onSelectEventHooks: [OnSelectEvent] = []
    var onUnSelectEventHooks: [OnUnSelectEvent] = []

    var eventMonitor: Any? = nil
    var downMonitor: Any? = nil
    var dragMonitor: Any? = nil
    var scrollWheelMonitor: Any? = nil
    var keyboardMonitor: Any? = nil
    var otherButtonsMonitor: Any? = nil
    // 取消长按计时（PointerInterceptor 吞掉了这次左键松开，这里收不到）
    private var consumePress: (() -> Void)?
    
    init() {
        // 拖拽判断
        var downLocation: NSPoint = .zero
        // 长按判断
        var downTimer: Timer? = nil
        // 双击判断
        var lastDownTime: Date? = nil
        var lastDownLocation: NSPoint? = nil
        var doubleClicked = false
        // 是否已经处理过
        var handled = false
        // 滑动取消
        var totalScrollDistance = 0.0

        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp], handler: { [self] event in
            // 鼠标松开可能刚改了选区：复制网页内容时据此稍等浏览器同步
            InputActivity.noteInput()
            // 点了菜单或 App 里的"复制"按钮：App 写进系统剪贴板后尽快转移走（Copi 拦不住这类复制，只能缩短停留时间）
            if GlobalMode.shared.isProtecting {
                NSPasteboard.general.checkFrequently(for: 0.5)
            }
            // 拖放结束：清掉留在拖放剪贴板上的文字
            DragPasteboardScrubber.shared.mouseUp()
            // 事件里带着松开时指针下面的窗口（主线程处理时指针可能已经移开、菜单已经关了）
            GlobalMode.shared.noteMouseUp(windowNumber: event.cgEvent.map { Int($0.getIntegerValueField(.mouseEventWindowUnderMousePointer)) })
            if !handled {
                downTimer?.invalidate()
                downTimer = nil
                if event.locationInWindow.distance(downLocation) > 10 || doubleClicked {
                    notifyAllSelectHooks(event: event)
                } else {
                    notifyAllUnSelectHooks(event: event)
                }
            }
        })
        dragMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged], handler: { event in
            if event.locationInWindow.distance(downLocation) > 10 {
                downTimer?.invalidate()
                downTimer = nil
                self.notifyAllUnSelectHooks(event: event)
                handled = false
            }
        })
        scrollWheelMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel], handler: { event in
            totalScrollDistance += NSPoint(x: event.scrollingDeltaX, y: event.scrollingDeltaY).distance(.zero)
            if totalScrollDistance > 100 {
                self.notifyAllUnSelectHooks(event: event)
            }
        })
        downMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { event in
            handled = false
            downLocation = event.locationInWindow
            totalScrollDistance = 0
            
            let current = Date.now
            if let lastDownTime, let lastDownLocation {
                if current.timeIntervalSince(lastDownTime) < 0.38 && event.locationInWindow.distance(lastDownLocation) <= 5 {
                    downTimer?.invalidate()
                    downTimer = nil
                    doubleClicked = true
                    return
                }
            }
            doubleClicked = false
            lastDownTime = current
            lastDownLocation = event.locationInWindow
            
            downTimer = Timer.scheduledTimer(withTimeInterval: 0.38, repeats: false) { timer in
                handled = true
                if event.locationInWindow.distance(downLocation) <= 10 {
                    self.notifyAllSelectHooks(event: event)
                }
                downTimer = nil
            }
        })
        // 右键菜单（或其他按键）里选了"拷贝"：同样尽快把 App 写进系统剪贴板的内容转移走
        otherButtonsMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.rightMouseUp, .otherMouseUp], handler: { event in
            GlobalMode.shared.noteMouseUp(windowNumber: event.cgEvent.map { Int($0.getIntegerValueField(.mouseEventWindowUnderMousePointer)) })
            if GlobalMode.shared.isProtecting {
                NSPasteboard.general.checkFrequently(for: 0.5)
            }
        })
        keyboardMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .flagsChanged], handler: { event in
            // 打字、按下 ⌘（⌘Tab 切走、快捷键）：收起快捷操作栏
            if event.type == .flagsChanged ? event.modifierFlags.contains(.command) : event.characters?.isEmpty == false {
                self.notifyAllUnSelectHooks(event: event)
            }
        })
        consumePress = {
            downTimer?.invalidate()
            downTimer = nil
            handled = true
        }
    }

    // 主线程：这次左键松开被吞掉了（菜单里的拷贝/剪切/粘贴由 Copi 处理），不要把它当成长按弹出快捷操作栏
    func pressConsumed() {
        consumePress?()
    }
    
    deinit {
        guard let eventMonitor else { return }
        NSEvent.removeMonitor(eventMonitor)
    }
    
    func onSelectEventHooks(_ hook: @escaping OnSelectEvent) {
        onSelectEventHooks.append(hook)
    }
    
    func onUnSelectEventHooks(_ hook: @escaping OnUnSelectEvent) {
        onUnSelectEventHooks.append(hook)
    }
    
    func notifyAllSelectHooks(event: NSEvent) {
        onSelectEventHooks.forEach { hook in
            hook(event)
        }
    }
    
    func notifyAllUnSelectHooks(event: NSEvent) {
        onUnSelectEventHooks.forEach { hook in
            hook(event)
        }
    }
}

extension NSPoint {
    func distance(_ point: NSPoint) -> Double {
        let deltaX = point.x - x
        let deltaY = point.y - y
        return sqrt(deltaX * deltaX + deltaY * deltaY)
    }
}
