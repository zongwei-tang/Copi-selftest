//
//  PopupWindowController.swift
//  SecureYourClipboard
//
//  Created by lixindong on 2024/4/2.
//

import Foundation
import SwiftUI
import ApplicationServices

class PopupWindowController: NSWindowController, NSWindowDelegate {
    static let shared = PopupWindowController()
    
    var contentView: PopupView!
    var isVisible: Bool {
        window?.isVisible ?? false
    }
    var viewModel = PopupViewModel()
    
    convenience init() {
        self.init(windowNibName: "PopupWindow")
        contentView = PopupView()
    }
    
    override func loadWindow() {
        window = PopupWindow(contentRect: .zero, styleMask: [.nonactivatingPanel], backing: .buffered, defer: true)
        window?.level = .mainMenu
        window?.center()
        window?.contentView = NSHostingView(rootView: contentView.environmentObject(viewModel))
        window?.delegate = self
        window?.hasShadow = true
        window?.backgroundColor = .clear
    }
    
    // pasteTarget：Action Bar 出现时拿着焦点的输入框（Paste 只粘贴进它）；nil 时不提供 Paste
    func showWindowAt(_ mouseLocation: NSPoint, canCopy: Bool, pasteTarget: AXUIElement?) {
        guard let window = window else { return }
        window.makeKeyAndOrderFront(nil)

        let location = NSPoint(x: mouseLocation.x - window.frame.width / 2, y: mouseLocation.y + window.frame.height / 2)
        window.setFrameOrigin(location)
        viewModel.canCopy = canCopy
        viewModel.canPaste = pasteTarget != nil
        viewModel.pasteTarget = pasteTarget
        showWindow(nil)
        // 别的 App 到了前台（焦点不在原来的地方了）、过了 8 秒还没点：收起来
        if activationObserver == nil {
            activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                                                   object: nil, queue: .main) { _ in
                PopupWindowController.shared.closeWindow()
            }
        }
        autoClose?.cancel()
        let work = DispatchWorkItem {
            PopupWindowController.shared.closeWindow()
        }
        autoClose = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
    }

    private var activationObserver: Any?
    private var autoClose: DispatchWorkItem?

    func closeWindow() {
        autoClose?.cancel()
        autoClose = nil
        viewModel.pasteTarget = nil
        close()
        window?.close()
    }
    
    func windowDidResignKey(_ notification: Notification) {
        closeWindow()
    }
}

class PopupWindow: NSPanel {
    override var canBecomeKey: Bool { false }
}

class PopupViewModel: ObservableObject {
    @Published var canCopy = false
    @Published var canPaste = false
    // Action Bar 出现时拿着焦点的输入框
    var pasteTarget: AXUIElement?
}

struct PopupView: View {
    @EnvironmentObject var vm: PopupViewModel
    @State var hovered = false
    @State var selections: Set<Int> = []

    var body: some View {
        HStack(spacing: 0) {
            if vm.canCopy {
                PopupItemView(title: "Copy", icon: "lock.shield")
                    .stag(0)
                    .onTapGesture {
                        safeCopySelection()
                        PopupWindowController.shared.closeWindow()
                    }
                    .onHover { hover in
                        if hover {
                            selections = [0]
                        }
                    }
            }
            if vm.canPaste {
                PopupItemView(title: "Paste", icon: "lock.shield")
                    .onTapGesture {
                        // 松开鼠标时调用：那时刚松开过鼠标才算用户亲手点的。从这次松开本身的时刻量：主线程忙时这里会晚到，从现在量
                        // 会把亲手点的也当成别的程序发来的。正在处理的不是这次松开、或者它已经是 1 秒以前的，就从现在量
                        let mouseUpAt = NSApp.currentEvent.flatMap { event -> Date? in
                            let age = ProcessInfo.processInfo.systemUptime - event.timestamp
                            return event.type == .leftMouseUp && age >= 0 && age <= 1 ? Date(timeIntervalSinceNow: -age) : nil
                        }
                        let deliberate = hardwareInput(.leftMouseUp, at: mouseUpAt ?? Date())
                        let target = vm.pasteTarget
                        PopupWindowController.shared.closeWindow()
                        safePaste(expecting: target, deliberate: deliberate)
                    }
                    .stag(1)
                    .onHover { hover in
                        if hover {
                            selections = [1]
                        }
                    }
            }
        }
        .fixedSize()
        .background(.white.opacity(0.9))
        .cornerRadius(4)
        .selection(selections: selections)
        .onHover { hover in
            selections = []
        }
    }
}

struct PopupItemView: View {
    let title: String
    let icon: String

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            Image(systemName: icon)
            Text(title)
        }
        .padding(6)
    }
}
