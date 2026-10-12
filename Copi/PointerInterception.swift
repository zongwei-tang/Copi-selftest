//
//  PointerInterception.swift
//  Copi
//
//  用鼠标完成的复制粘贴：菜单栏"编辑"菜单、右键菜单里的"拷贝/剪切/粘贴"，以及拖动选中的文字。
//  它们不经过 ⌘C/⌘V，Copi 的按键拦截看不到，App 会直接把文字写进系统剪贴板（拖放时写进拖放剪贴板），任何程序都能读。
//  这里用一个鼠标 event tap 在它们生效之前接管：
//   - 菜单里点"拷贝/剪切/粘贴"：在松开鼠标（菜单项真正执行）之前认出这个菜单项，吞掉这次松开、关掉菜单，改由 Copi 像按了
//     ⌘C/⌘X/⌘V 一样处理（不经过剪贴板）；Copi 决定交给 App 自己处理时（例如 Finder 里复制文件），再替它按一次快捷键。
//     右键菜单的这几项作用于点中的东西：只有点中的就是键盘焦点所在的控件（或在它里面）时才接管，否则（例如右键一条消息气泡）
//     让菜单项照常执行，写进系统剪贴板的内容随后由轮询转移走；
//   - 拖动选中的文字：在 App 开始拖放（把文字写进拖放剪贴板）之前认出"按下的位置在选中的文字上"，不让这次拖动开始；
//     没认出来、App 已经写进拖放剪贴板的，立刻清掉（这次拖放就放不下了）。文件、图片、链接照常拖放。
//  另外记下 Firefox 里用 ⌘ 添过选区的地方（它不说选了几段），那里的 ⌘C/⌘X 拒绝（见 mayHaveSeveralGeckoRanges）。
//  菜单开着时用方向键（或打字）选中这几项、按回车，也在菜单项执行之前接管（见 MenuTracker）。
//  App 界面里的"复制"按钮不在此列（写进系统剪贴板后由轮询转移走）。
//

import Foundation
import AppKit
import Carbon
import Defaults

final class PointerInterceptor {
    static let shared = PointerInterceptor()

    private lazy var tap: KeyTap = KeyTap(events: [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .leftMouseDragged]) { event in
        PointerInterceptor.shared.handle(event)
    }

    // 打开右键菜单的那次按下：时间、位置、当时拿着键盘焦点的 App 和控件、点中的元素
    private struct ContextClick {
        let time: Date
        let location: CGPoint
        let focusedPID: pid_t?
        let focused: AXUIElement?
        let hit: AXUIElement?
    }

    // 以下状态在 tap 线程和 hitTestQueue 上读写，都经过 lock
    private let lock = NSLock()
    // 可能有菜单开着：右键、⌃点按、点了菜单栏、点了弹出菜单按钮或菜单项之后，直到发现松开的位置不在菜单上
    private var menuMayBeOpen = false
    // 这个菜单是右键菜单（nil：菜单栏或弹出按钮的菜单）
    private var contextClick: ContextClick?
    // 左键按下时在后台做的命中测试（轻点时松开紧跟着按下，最多等它一下）
    private var downHitTest: DispatchWorkItem?
    // 左键按下的位置，以及这次拖动是否要拦下（nil：还没判断）
    private var leftDownLocation: CGPoint?
    private var dragDecision: DragDecision?
    // 刚用回车选了菜单里的拷贝/剪切/粘贴：接下来一小会儿按住不放产生的自动重复也吞掉
    private var swallowRepeats: (keyCode: Int64, until: Date)?
    private let hitTestQueue = DispatchQueue(label: "Copi.PointerHitTest", qos: .userInteractive)

    // 各 App 菜单栏里"拷贝/剪切/粘贴"的本地化标题（按进程缓存）：右键菜单里的这几项通常不显示快捷键，靠标题认
    private let titleLock = NSLock()
    private var localizedTitles: [pid_t: [String: MenuAction]] = [:]
    // 菜单栏里快捷键是别的命令的菜单项标题
    private var otherTitles: [pid_t: Set<String>] = [:]
    private var titlesLoading = Set<pid_t>()
    // 上次没读出来（菜单栏读不到、App 正忙）的时间：过几秒再试，不能把空结果一直留着
    private var titlesFailedAt: [pid_t: Date] = [:]
    // 读标题要几百次 Accessibility 查询，不和按下时的命中测试排在同一个队列里
    private let titleQueue = DispatchQueue(label: "Copi.MenuTitles", qos: .userInitiated)

    // Firefox 系的 App 里 ⌘点按、⌘拖动会再添一段选区，它却不提供 AXSelectedTextRanges，看不出选了几段（Copi 只读得到第一段，
    // ⌘X 却会把每一段都删掉）。记下这样按过的地方：选区归谁（<input>/<textarea> 有自己的选区，别处是整个网页的），
    // 在那里不按修饰键点了文字（选区收拢成一段）、它没了（网页关掉、跳转走了）时才去掉。见 mayHaveSeveralGeckoRanges
    private struct RangeMark {
        let pid: pid_t
        // nil：认不出按在了哪里，这个 App 里都算
        let owner: AXUIElement?
    }
    private let rangeLock = NSLock()
    // 以下在 rangeLock 里读写；rangeMarks 只在 rangeQueue 上改
    private var rangeMarks: [RangeMark] = []
    // 排了队、还没查完的 ⌘按下
    private var pendingRangePresses = 0
    // 左键按下的编号；排了队的不按修饰键的按下（松开时再决定去不去掉记号），以及它查出来可以去掉的记号（之后又 ⌘按下过就作废）
    private var pressSerial = 0
    private var queuedPlainPress: Int?
    private var pendingClear: (serial: Int, mark: RangeMark)?
    // 往上找选区归谁要好几次 Accessibility 查询：不和按下时的命中测试排在同一个队列里（松开时要等它）
    private let rangeQueue = DispatchQueue(label: "Copi.SelectionRanges", qos: .userInteractive)

    private enum DragDecision {
        case allow
        case block
    }

    enum MenuAction: Equatable {
        case copy
        case cut
        case paste(shift: Bool, option: Bool)
    }

    // MARK: 启停（主线程，跟随 ⌘C/⌘V 接管的状态）

    func start() {
        tap.start()
        tap.ensureEnabled()
        MenuTracker.shared.start()
    }

    // 定期体检：tap 被系统停用或 mach port 作废时重建
    func ensureRunning() {
        tap.start()
        tap.ensureEnabled()
        if !tap.isActive {
            tap.stop()
            tap.start()
        }
    }

    func stop() {
        tap.stop()
        MenuTracker.shared.stop()
        lock.lock()
        menuMayBeOpen = false
        contextClick = nil
        downHitTest = nil
        leftDownLocation = nil
        dragDecision = nil
        lock.unlock()
    }

    // MARK: tap 线程

    // 返回 true 表示吞掉这个鼠标事件
    private func handle(_ event: CGEvent) -> Bool {
        let location = event.location
        switch event.type {
        case .rightMouseDown:
            noteContextClick(at: location)
            return false
        case .leftMouseDown:
            // 双击/三击（按词、按行选择）、⇧点按（扩展选区）之后的拖动是在选字；⌃点按是打开右键菜单，接下来的拖动是在菜单里选。
            // 这些都不会拖放选中的文字
            let clickState = event.getIntegerValueField(.mouseEventClickState)
            let cannotStartTextDrag = clickState > 1 || !event.flags.isDisjoint(with: [.maskShift, .maskControl])
            lock.lock()
            leftDownLocation = location
            dragDecision = cannotStartTextDrag ? .allow : nil
            lock.unlock()
            if event.flags.contains(.maskControl) {
                noteContextClick(at: location)
            } else if Self.isInMenuBar(location) {
                setMenu(open: true, context: nil)
            } else {
                // 点的是不是弹出菜单按钮、菜单（键盘打开的菜单里点菜单项）：不挡这次点击，在后台查
                let work = DispatchWorkItem { [self] in
                    if let role = Self.element(at: location).flatMap({ copyAXAttribute($0, kAXRoleAttribute) as? String }),
                       Self.menuRoles.contains(role) {
                        lock.lock()
                        let wasOpen = menuMayBeOpen
                        menuMayBeOpen = true
                        // 新打开的是弹出按钮的菜单，不是右键菜单；在已经开着的菜单里点，保留原来的记录
                        if !wasOpen || (role != kAXMenuItemRole && role != kAXMenuRole) {
                            contextClick = nil
                        }
                        lock.unlock()
                    }
                }
                lock.lock()
                downHitTest = work
                lock.unlock()
                hitTestQueue.async(execute: work)
            }
            noteRangePress(at: location, flags: event.flags)
            DispatchQueue.main.async {
                DragGuard.shared.mouseDown()
            }
            return false
        case .leftMouseDragged:
            return shouldBlockDrag(event)
        case .leftMouseUp, .rightMouseUp:
            // 这次松开是不是用户亲手按的鼠标（见 hardwareInput）：在等命中测试、查菜单项之前就看
            let deliberate = hardwareInput(event.type, at: Date())
            if event.type == .leftMouseUp {
                DispatchQueue.main.async {
                    DragGuard.shared.mouseUp()
                }
            }
            lock.lock()
            var mayBeOpen = menuMayBeOpen
            let context = contextClick
            let pendingHitTest = downHitTest
            downHitTest = nil
            let down = leftDownLocation
            leftDownLocation = nil
            let blocking = dragDecision == .block
            dragDecision = nil
            lock.unlock()
            if event.type == .leftMouseUp {
                let clicked = down.map { max(abs(location.x - $0.x), abs(location.y - $0.y)) < 4 } ?? false
                finishPlainPress(collapsed: clicked || blocking)
            }
            // 拦下了一次拖动（只是在选区里点了一下、手抖了几个像素的不算）
            if blocking, let down, max(abs(location.x - down.x), abs(location.y - down.y)) >= 4 {
                DispatchQueue.main.async {
                    // App 已经自己开始了拖放、DragGuard 清掉了文字并提示过：不再重复
                    guard !DragGuard.shared.clearedSinceMouseDown else {
                        return
                    }
                    notifyCopiNotice("Copi stopped dragging the selected text so it doesn't go through the drag pasteboard. Use ⌘X or ⌘C and then ⌘V to move it.")
                }
            }
            // 轻点：按下时的后台命中测试可能还没做完，最多等它 50 毫秒
            if !mayBeOpen, let pendingHitTest, pendingHitTest.wait(timeout: .now() + 0.05) == .success {
                lock.lock()
                mayBeOpen = menuMayBeOpen
                lock.unlock()
            }
            guard mayBeOpen else {
                return false
            }
            // 打开右键菜单的那次松开（按下后马上在原地松开）：macOS 不会选中菜单项，菜单也可能还没出现，什么都不做
            if let context, Date().timeIntervalSince(context.time) < 0.35,
               hypot(location.x - context.location.x, location.y - context.location.y) < 5 {
                return false
            }
            return interceptMenuItem(at: location, context: context, time: Date(), deliberate: deliberate)
        default:
            return false
        }
    }

    // 右键（或 ⌃点按）按下：通常是打开右键菜单。菜单已经开着、又在菜单上按下，是在用右键选菜单项：保留原来那次打开的记录
    private func noteContextClick(at location: CGPoint) {
        let hit = Self.element(at: location)
        let hitRole = hit.flatMap { copyAXAttribute($0, kAXRoleAttribute) as? String }
        lock.lock()
        let open = menuMayBeOpen
        lock.unlock()
        if open, hitRole == kAXMenuItemRole || hitRole == kAXMenuRole {
            return
        }
        // App 还没收到这次按下：这时的焦点就是右键之前的焦点
        let (pid, application) = Self.focusedApplication()
        let focused = application.flatMap { asAXElement(copyAXAttribute($0, kAXFocusedUIElementAttribute)) }
        setMenu(open: true, context: ContextClick(time: Date(), location: location, focusedPID: pid, focused: focused, hit: hit))
        if let pid {
            loadLocalizedTitles(pid: pid)
        }
    }

    private func setMenu(open: Bool, context: ContextClick?) {
        lock.lock()
        menuMayBeOpen = open
        contextClick = open ? context : nil
        lock.unlock()
    }

    // 松开的位置是一个"拷贝/剪切/粘贴"菜单项：吞掉这次松开（菜单项就不会执行），交给主线程处理。
    // deliberate：这次松开是用户亲手按的鼠标（见 perform）
    private func interceptMenuItem(at location: CGPoint, context: ContextClick?, time: Date, deliberate: Bool) -> Bool {
        guard let element = Self.element(at: location) else {
            return false
        }
        let role = copyAXAttribute(element, kAXRoleAttribute) as? String
        guard role == kAXMenuItemRole else {
            // 松开在菜单以外：菜单关掉了
            if !(role.map(Self.menuRoles.contains) ?? false) {
                setMenu(open: false, context: nil)
            }
            return false
        }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid != getpid(), Defaults[.isOn], GlobalMode.shared.isProtectingNow else {
            return false
        }
        guard let action = menuAction(of: element, pid: pid, allowTitles: context != nil) else {
            return interceptClipboardReadingItem(element, pid: pid, time: time, deliberate: deliberate)
        }
        // 拷贝/剪切要求菜单项可用；"粘贴"灰掉多半正是因为 Copi 让系统剪贴板保持为空（NSTextView、Chrome 这时会禁用它）
        if action == .copy || action == .cut, (copyAXAttribute(element, kAXEnabledAttribute) as? Bool) == false {
            return false
        }
        if let context {
            // 右键菜单：必须是拿着键盘焦点的 App 的菜单（右键后台窗口不会激活它），并且菜单项作用的正是 Copi 要读写的地方
            guard context.focusedPID == pid, Self.contextMenuTargetsFocus(context, action: action, pid: pid) else {
                return false
            }
        } else if Self.focusedApplication().pid != pid {
            // 菜单栏里别的 App（状态栏菜单）的菜单
            return false
        }
        let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        // 放行的 App 自己的复制照常进系统剪贴板（记下来：接下来的复制是它自己的）；粘贴时没有要由 Copi 粘贴的内容就交给 App
        if ZeroExposurePolicy.usesNormalClipboard(bundleID), action == .copy || action == .cut {
            DispatchQueue.main.async {
                GlobalMode.shared.noteUserCommand(in: bundleID)
            }
            return false
        }
        if case .paste = action, !GlobalMode.shared.hasSomethingToPaste {
            return false
        }
        let menu = asAXElement(copyAXAttribute(element, kAXParentAttribute))
        setMenu(open: false, context: nil)
        DispatchQueue.main.async {
            MouseEventCatcher.shared.pressConsumed()
            PointerInterceptor.perform(action, closing: menu, pid: pid, time: time, deliberate: deliberate)
        }
        return true
    }

    // 自己去读剪贴板的菜单项（预览的"从剪贴板新建"、图片编辑器的"从剪贴板新建文稿"……）：Copi 里存着图片、文件（剪贴板是空的）时，
    // 吞掉这次松开，先把它们放回剪贴板（和粘贴时一样短暂、带标记），再替用户按下这一项（剪贴板空着时它可能是灰的，放回之后就能用了，
    // 所以不看它可不可用）。不要求是拿着键盘焦点的 App 的菜单：放回去的是给这一项所属的 App 读的，Copi 不读写焦点所在的地方；
    // 状态栏菜单（上传工具的"上传剪贴板里的图片"）、后台窗口的右键菜单里的这种项也要能用。有会把剪贴板同步出去的 App 在运行时，
    // 不管是哪个菜单都先问（见 stageNonTextForApp）
    private func interceptClipboardReadingItem(_ element: AXUIElement, pid: pid_t, time: Date, deliberate: Bool) -> Bool {
        guard NonTextClipboard.shared.hasContent, !SecureClipboard.shared.hasText, Self.readsClipboardItself(element, pid: pid) else {
            return false
        }
        let menu = asAXElement(copyAXAttribute(element, kAXParentAttribute))
        setMenu(open: false, context: nil)
        DispatchQueue.main.async {
            MouseEventCatcher.shared.pressConsumed()
            if GlobalMode.shared.stageNonTextForApp(pid: pid, time: time, deliberate: deliberate) {
                AXUIElementPerformAction(element, kAXPressAction as CFString)
            } else {
                // 只提醒、没有放回去：不按（它会去读空着的剪贴板），关掉菜单
                Self.closeMenu(menu, pid: pid)
            }
        }
        return true
    }

    // 标题里有"剪贴板"的菜单项，以及文件管理器里快捷键是 ⌥⌘V 的那一项（访达按住 ⌥ 时的"移动到这里"，标题里没有"剪贴板"）。
    // 往剪贴板里写、清空剪贴板的项（"Copy Link to Clipboard""Capture Area to Clipboard""Clear Clipboard"）不读剪贴板：
    // 不放回 Copi 存着的图片、文件，也不问（会把剪贴板同步出去的 App 在运行时，问了就不按，用户要的复制、截图就没做成），
    // 照常交给 App，它写进来的内容随后照常转移走
    private static func readsClipboardItself(_ element: AXUIElement, pid: pid_t) -> Bool {
        if let title = (copyAXAttribute(element, kAXTitleAttribute) as? String)?.lowercased(),
           clipboardWords.contains(where: { title.contains($0) }), !clipboardWritingWords.contains(where: { title.contains($0) }) {
            return true
        }
        let character = (copyAXAttribute(element, kAXMenuItemCmdCharAttribute) as? String)?.uppercased()
        // 修饰键：2 是 ⌥⌘（见 menuAction）
        let modifiers = (copyAXAttribute(element, kAXMenuItemCmdModifiersAttribute) as? NSNumber)?.intValue ?? 0
        guard character == "V", modifiers == 2, let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else {
            return false
        }
        return fileManagerBundleIDs.contains(bundleID)
    }

    // 各种语言里的"剪贴板"
    private static let clipboardWords = [
        "clipboard", "剪贴板", "剪貼簿", "クリップボード", "클립보드", "zwischenablage", "presse-papiers", "portapapeles", "appunti",
        "klembord", "área de transferência", "буфер обмена", "schowek", "urklipp", "udklipsholder", "utklippstavle", "leikepöytä",
    ]

    // 各种语言里"（拷贝、截图……）到剪贴板""清空剪贴板"的说法。只认写往剪贴板的说法，不单独认"拷贝""剪切"这些动词
    // （"Copy Clipboard Image to…"读剪贴板；丹麦语的剪贴板 udklipsholder 里就有剪切 klip）；"保存剪贴板""显示剪贴板"读剪贴板，不算。
    // 日语、韩语只认带着"拷贝"的说法："クリップボードに""클립보드에"也出现在"剪贴板里的图片""从剪贴板"里
    private static let clipboardWritingWords = [
        "to clipboard", "to the clipboard", "into clipboard", "into the clipboard", "clear",
        "到剪贴板", "至剪贴板", "到剪貼簿", "至剪貼簿", "清空", "清除",
        "クリップボードにコピー", "クリップボードへコピー", "クリップボードをクリア", "클립보드에 복사", "클립보드로 복사",
        "in die zwischenablage", "in zwischenablage", "zwischenablage leeren", "dans le presse-papiers", "vers le presse-papiers",
        "vider le presse-papiers", "al portapapeles", "negli appunti", "naar klembord", "naar het klembord", "в буфер обмена",
        "till urklipp", "til udklipsholder", "til utklippstavle", "para a área de transferência", "para área de transferência",
        // 别的语言里的"清空"（标题里先要有"剪贴板"才看到这里，这些动词不会误伤别的菜单项）
        "消去", "löschen", "effacer", "vaciar", "borrar", "svuota", "limpar", "wissen", "leegmaken", "очистить", "rensa", "töm",
        "ryd", "tøm", "tyhjennä", "wyczyść", "지우기", "비우기",
    ]

    // 键盘 tap 线程（GlobalMode）：菜单开着时按回车（或小键盘的 Enter）执行高亮的那一项。高亮的是"拷贝/剪切/粘贴"时吞掉这次按键，
    // 和点击一样关掉菜单、交给 Copi 处理。按住回车的自动重复也吞掉（菜单已经关了，否则会落进文本框里）。
    // 空格不管：在菜单里打字跳转时，空格可能是名字的一部分（"Paste and…"）
    func interceptMenuKey(_ event: CGEvent) -> Bool {
        guard event.type == .keyDown else {
            return false
        }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keyCode == Int64(kVK_Return) || keyCode == Int64(kVK_ANSI_KeypadEnter) else {
            return false
        }
        if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
            lock.lock()
            defer { lock.unlock() }
            return swallowRepeats.map { $0.keyCode == keyCode && Date() < $0.until } ?? false
        }
        // 这次回车是不是用户亲手按的（见 hardwareInput）：在查菜单之前就看
        let deliberate = hardwareInput(.keyDown, at: Date())
        lock.lock()
        // 新的一次按下：上一次按住已经松开了，它的自动重复不用再吞
        swallowRepeats = nil
        let mouseOpened = menuMayBeOpen
        let recordedContext = contextClick
        lock.unlock()
        // AXObserver 没注册上时跟踪不到用键盘打开的菜单（⌃F2、帮助菜单的搜索）：也去看一眼（先问窗口服务器，没有菜单很快就返回）
        guard mouseOpened || MenuTracker.shared.mayHaveOpenMenu || !MenuTracker.shared.isLive, Defaults[.isOn],
              GlobalMode.shared.isProtectingNow else {
            return false
        }
        let highlighted: MenuTracker.Highlighted
        switch MenuTracker.shared.highlightedItem() {
        case .item(let found):
            highlighted = found
        case .noMenu:
            // 屏幕上根本没有开着的菜单：点菜单留下的记录过时了（菜单是用 esc、别的方式关掉的），清掉，之后的回车不再查
            setMenu(open: false, context: nil)
            return false
        case .unknown:
            return false
        }
        // 右键的记录只算打开了这个菜单的那一次（右键之后一秒内打开的）：之前右键过、菜单用 esc 关掉了，记录还留着
        let context = recordedContext.flatMap { click -> ContextClick? in
            guard highlighted.isContextMenu, let openedAt = highlighted.rootOpenedAt else {
                return nil
            }
            let delay = openedAt.timeIntervalSince(click.time)
            return delay > -0.1 && delay < 1 ? click : nil
        }
        guard let action = menuAction(of: highlighted.item, pid: highlighted.pid, allowTitles: context != nil) else {
            return false
        }
        let pid = highlighted.pid
        if action == .copy || action == .cut, (copyAXAttribute(highlighted.item, kAXEnabledAttribute) as? Bool) == false {
            return false
        }
        if highlighted.isContextMenu {
            // 和点击一样：拿着键盘焦点的 App 的右键菜单，并且作用的正是 Copi 要读写的地方。不知道是右键了什么打开的（没有记录）
            // 就不接管：它作用于点中的东西，不一定是焦点所在的地方
            guard let context, context.focusedPID == pid, Self.contextMenuTargetsFocus(context, action: action, pid: pid) else {
                return false
            }
        } else if Self.focusedApplication().pid != pid {
            return false
        }
        let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        if ZeroExposurePolicy.usesNormalClipboard(bundleID), action == .copy || action == .cut {
            DispatchQueue.main.async {
                GlobalMode.shared.noteUserCommand(in: bundleID)
            }
            return false
        }
        if case .paste = action, !GlobalMode.shared.hasSomethingToPaste {
            return false
        }
        setMenu(open: false, context: nil)
        lock.lock()
        swallowRepeats = (keyCode, Date().addingTimeInterval(2))
        lock.unlock()
        let time = Date()
        DispatchQueue.main.async {
            PointerInterceptor.perform(action, closing: highlighted.rootMenu, pid: pid, time: time, deliberate: deliberate)
        }
        return true
    }

    // 拖动开始时（第一个拖动事件，App 还没开始拖放）：按下的位置在选中的文字上，就把这次拖动的事件都吞掉
    private func shouldBlockDrag(_ event: CGEvent) -> Bool {
        lock.lock()
        let decided = dragDecision
        let downLocation = leftDownLocation
        lock.unlock()
        if let decided {
            if decided == .allow {
                DispatchQueue.main.async {
                    DragGuard.shared.dragMoved()
                }
            }
            return decided == .block
        }
        guard let downLocation, Defaults[.isOn], Defaults[.blockTextDragging], GlobalMode.shared.isProtectingNow else {
            lock.lock()
            dragDecision = .allow
            lock.unlock()
            return false
        }
        let block = Self.isOnSelectedText(downLocation)
        lock.lock()
        dragDecision = block ? .block : .allow
        lock.unlock()
        if !block {
            DispatchQueue.main.async {
                DragGuard.shared.dragMoved()
            }
        }
        return block
    }

    // MARK: Firefox 的多段选区

    // tap 线程：左键按下。⌘按下（可能添了一段选区）都去查按在了哪里；不按修饰键的按下只在有记号时才查（⇧点按只扩展一段，
    // 别的几段还在）。都在 rangeQueue 上查，这里不做 Accessibility 查询
    private func noteRangePress(at location: CGPoint, flags: CGEventFlags) {
        let adds = flags.contains(.maskCommand)
        let option = flags.contains(.maskAlternate)
        rangeLock.lock()
        pressSerial += 1
        let serial = pressSerial
        let plain = flags.isDisjoint(with: [.maskCommand, .maskShift, .maskControl, .maskAlternate]) && !rangeMarks.isEmpty
        queuedPlainPress = plain ? serial : nil
        if adds {
            pendingRangePresses += 1
        }
        rangeLock.unlock()
        guard adds || plain else {
            return
        }
        rangeQueue.async { [self] in
            guard adds else {
                findClearableMark(at: location, serial: serial)
                return
            }
            let mark = rangeMark(at: location, option: option)
            rangeLock.lock()
            if let mark {
                rangeMarks.removeAll { existing in
                    existing.pid == mark.pid && Self.sameOwner(existing.owner, mark.owner)
                }
                rangeMarks.append(mark)
                if rangeMarks.count > 32 {
                    // 挤出去的地方可能还选着几段，不能直接丢：改记成整个 App 的（之后在那个 App 里点一下文字才去掉）
                    let dropped = rangeMarks.prefix(rangeMarks.count - 32)
                    rangeMarks.removeFirst(rangeMarks.count - 32)
                    for pid in Set(dropped.map(\.pid)) where !rangeMarks.contains(where: { $0.pid == pid && $0.owner == nil }) {
                        rangeMarks.append(RangeMark(pid: pid, owner: nil))
                    }
                }
            }
            // 之前那次不按修饰键的按下查出来的记号不再去掉：它松开后要先绕主线程一趟才回到 rangeQueue，主线程慢了一拍时会排在
            // 这次添加之后，把刚添的记号删掉（不管这次记没记下来都作废，至多多拒绝几次）
            pendingClear = nil
            pendingRangePresses -= 1
            rangeLock.unlock()
            if mark != nil {
                pruneRangeMarks()
            }
        }
    }

    // rangeQueue：⌘按下添了选区时要记下的地方。在链接、图片上按下（没按着 ⌥）时 Firefox 是准备拖放，不动选区；
    // 按在浏览器自己的界面（标签栏、工具栏）上的不管
    private func rangeMark(at location: CGPoint, option: Bool) -> RangeMark? {
        let hit = Self.element(at: location)
        var hitPID: pid_t = 0
        // 点中的读不出来：按拿着键盘焦点的 App 算
        guard let pid = hit.flatMap({ AXUIElementGetPid($0, &hitPID) == .success ? hitPID : nil }) ?? Self.focusedApplication().pid,
              isGeckoApp(pid: pid, bundleIdentifier: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier) else {
            return nil
        }
        guard let hit else {
            return RangeMark(pid: pid, owner: Self.focusedOwner(pid: pid))
        }
        AXUIElementSetMessagingTimeout(hit, 0.1)
        let lookup = Self.selectionOwner(of: hit, pid: pid, deadline: .now() + .milliseconds(250))
        if lookup.failed {
            return RangeMark(pid: pid, owner: Self.focusedOwner(pid: pid))
        }
        guard let owner = lookup.owner, !lookup.draggable || option else {
            return nil
        }
        return RangeMark(pid: pid, owner: owner)
    }

    // rangeQueue：不按修饰键的按下。按在有记号的地方的文字上（或者输入框本身），选区就收拢成一段了：先记下，松开时再决定
    // （见 finishPlainPress）。按在网页空白处、滚动条、链接、图片、按钮上不一定动选区，不算
    private func findClearableMark(at location: CGPoint, serial: Int) {
        var found: RangeMark?
        defer {
            rangeLock.lock()
            pendingClear = found.map { (serial: serial, mark: $0) }
            rangeLock.unlock()
        }
        var pid: pid_t = 0
        guard let hit = Self.element(at: location), AXUIElementGetPid(hit, &pid) == .success else {
            return
        }
        rangeLock.lock()
        let marked = rangeMarks.contains { $0.pid == pid }
        rangeLock.unlock()
        guard marked else {
            return
        }
        AXUIElementSetMessagingTimeout(hit, 0.1)
        let lookup = Self.selectionOwner(of: hit, pid: pid, deadline: .now() + .milliseconds(250))
        guard !lookup.failed, let owner = lookup.owner, !lookup.draggable, !lookup.inControl,
              lookup.hitRole == kAXStaticTextRole || (lookup.hitRole != "AXWebArea" && CFEqual(hit, owner)) else {
            return
        }
        found = RangeMark(pid: pid, owner: owner)
    }

    // tap 线程：左键松开。按下时排了队的不按修饰键的按下：没拖动（或者拖动被 Copi 拦下，Firefox 只收到按下和松开）时选区已经收拢；
    // 拖动了的可能是在拖放选中的文字（选区不变），拖放剪贴板没变过（是在拖选）才算收拢。紧接着 DragGuard.mouseUp 在主线程上看
    // （赶在下一次按下重设基准之前），再回到 rangeQueue 上去掉这次按下查出来的记号（已经换成下一次按下的、之后又 ⌘按下过的就不动）
    private func finishPlainPress(collapsed: Bool) {
        rangeLock.lock()
        let serial = queuedPlainPress
        queuedPlainPress = nil
        rangeLock.unlock()
        guard let serial else {
            return
        }
        DispatchQueue.main.async { [self] in
            let collapsedNow = collapsed || !DragGuard.shared.dragPasteboardChangedSinceMouseDown
            rangeQueue.async { [self] in
                rangeLock.lock()
                let clear = pendingClear?.serial == serial ? pendingClear?.mark : nil
                if clear != nil {
                    pendingClear = nil
                }
                rangeLock.unlock()
                if collapsedNow, let clear {
                    removeRangeMarks(like: clear)
                }
            }
        }
    }

    // rangeQueue：去掉这个地方的记号，以及这个 App 里认不出地方的记号
    private func removeRangeMarks(like clear: RangeMark) {
        rangeLock.lock()
        rangeMarks.removeAll { mark in
            mark.pid == clear.pid && (mark.owner == nil || Self.sameOwner(mark.owner, clear.owner))
        }
        rangeLock.unlock()
    }

    // rangeQueue：去掉已经没了的地方（网页关掉、跳转走了，App 退出了）的记号
    private func pruneRangeMarks() {
        rangeLock.lock()
        let marks = rangeMarks
        rangeLock.unlock()
        let alive = marks.filter { mark in
            guard NSRunningApplication(processIdentifier: mark.pid) != nil else {
                return false
            }
            guard let owner = mark.owner else {
                return true
            }
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(owner, kAXRoleAttribute as CFString, &value) != .invalidUIElement
        }
        guard alive.count < marks.count else {
            return
        }
        rangeLock.lock()
        rangeMarks = alive
        rangeLock.unlock()
    }

    // 主线程：App 退出了（进程号以后会给别的进程）：去掉它的记号
    func forgetRangeMarks(pid: pid_t) {
        rangeQueue.async { [self] in
            rangeLock.lock()
            rangeMarks.removeAll { $0.pid == pid }
            rangeLock.unlock()
        }
    }

    // 主线程（⌘C/⌘X、安全复制的处理里）：Firefox 系的 App（pid）里，焦点所在地方的选区可能不止一段
    func mayHaveSeveralGeckoRanges(focus element: AXUIElement, pid: pid_t) -> Bool {
        // 刚 ⌘按下、还没查完按在了哪里：最多等 150 毫秒，还没查完就当作选了多段
        for _ in 0..<15 {
            rangeLock.lock()
            let pending = pendingRangePresses
            rangeLock.unlock()
            guard pending > 0 else {
                break
            }
            usleep(10_000)
        }
        rangeLock.lock()
        let pending = pendingRangePresses
        let marks = rangeMarks.filter { $0.pid == pid }
        rangeLock.unlock()
        if pending > 0 || marks.contains(where: { $0.owner == nil }) {
            return true
        }
        guard !marks.isEmpty else {
            return false
        }
        let lookup = Self.selectionOwner(of: element, pid: pid, deadline: .now() + .milliseconds(150))
        // 读不出焦点在哪里：当作就在有记号的地方
        if lookup.failed {
            return true
        }
        guard let owner = lookup.owner else {
            return false
        }
        return marks.contains { Self.sameOwner($0.owner, owner) }
    }

    private struct OwnerLookup {
        // 选区归谁：<input>/<textarea>（各有自己的选区），或者网页（AXWebArea；contenteditable 用的也是网页的选区）。
        // nil：不在网页里（标签栏、工具栏这类浏览器自己的界面；地址栏是输入框，选区归它自己）
        var owner: AXUIElement?
        // 往上找的途中读不出来（超时、读不到上一层）
        var failed = false
        // 在链接、图片里，并且不在可编辑的地方（Firefox 在可以拖动的东西上按下是准备拖放，不动选区）
        var draggable = false
        // 在按钮这类控件里（点它们不一定动选区）
        var inControl = false
        // 起点元素的角色
        var hitRole: String?
    }

    private static let selectionControlRoles: Set<String> = [
        kAXButtonRole, kAXPopUpButtonRole, kAXMenuButtonRole, kAXCheckBoxRole, kAXRadioButtonRole, kAXSliderRole, kAXDisclosureTriangleRole,
    ]

    // 从 element（可以就是网页根节点或输入框）往上找选区归谁，最多找到 deadline
    // rangeQueue：点中的地方查不出来时，按拿着键盘焦点的地方记（⌘点按网页内容之后焦点通常就在那个网页或输入框里）：只在那里点一下
    // 文字才去掉这个记号。也查不出来时为 nil（整个 App 都算，在这个 App 里点一下文字就去掉）
    private static func focusedOwner(pid: pid_t) -> AXUIElement? {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.1)
        guard let focused = asAXElement(copyAXAttribute(application, kAXFocusedUIElementAttribute)) else {
            return nil
        }
        AXUIElementSetMessagingTimeout(focused, 0.1)
        let lookup = selectionOwner(of: focused, pid: pid, deadline: .now() + .milliseconds(150))
        return lookup.failed ? nil : lookup.owner
    }

    private static func selectionOwner(of element: AXUIElement, pid: pid_t, deadline: DispatchTime) -> OwnerLookup {
        var lookup = OwnerLookup()
        var node = element
        for depth in 0..<64 {
            guard DispatchTime.now() < deadline, let role = copyAXAttribute(node, kAXRoleAttribute) as? String else {
                lookup.failed = true
                return lookup
            }
            if depth == 0 {
                lookup.hitRole = role
            }
            if role == "AXWebArea" {
                lookup.owner = node
                return lookup
            }
            if role == kAXTextFieldRole || role == kAXComboBoxRole || role == kAXTextAreaRole {
                if FocusedTarget(element: node, pid: pid).isGeckoTextControl {
                    lookup.owner = node
                    return lookup
                }
                // 可编辑的地方（contenteditable）里的链接、图片照常可以选
                lookup.draggable = false
            }
            if role == kAXWindowRole || role == kAXApplicationRole {
                return lookup
            }
            if role == "AXLink" || role == kAXImageRole {
                lookup.draggable = true
            }
            if selectionControlRoles.contains(role) {
                lookup.inControl = true
            }
            guard let parent = asAXElement(copyAXAttribute(node, kAXParentAttribute)) else {
                lookup.failed = true
                return lookup
            }
            AXUIElementSetMessagingTimeout(parent, 0.1)
            node = parent
        }
        lookup.failed = true
        return lookup
    }

    private static func sameOwner(_ first: AXUIElement?, _ second: AXUIElement?) -> Bool {
        guard let first, let second else {
            return first == nil && second == nil
        }
        return CFEqual(first, second)
    }

    // MARK: 主线程

    // 关掉菜单（菜单还在等这次松开）
    private static func closeMenu(_ menu: AXUIElement?, pid: pid_t) {
        var closed = false
        if let menu {
            closed = AXUIElementPerformAction(menu, kAXCancelAction as CFString) == .success
        }
        if !closed {
            // 菜单还在跟踪鼠标：esc 只会关掉菜单
            postKeystroke(keyCode: CGKeyCode(kVK_Escape), flags: [], to: pid)
        }
    }

    // 关掉菜单，等焦点回到原来的控件上，再像按了快捷键一样处理。
    // deliberate：用户亲手点的、按的回车才算"再复制/粘贴一次"的确认（硬件层刚才没记下点击、按键时别的程序合成的不算，见 hardwareInput）
    private static func perform(_ action: MenuAction, closing menu: AXUIElement?, pid: pid_t, time: Date, deliberate: Bool) {
        closeMenu(menu, pid: pid)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            switch action {
            case .copy, .cut:
                // Copi 不接管时（例如 Finder 里复制文件）替 App 按一次快捷键，和菜单项的效果一样
                if deliberate {
                    CopyPress.noteDeliberate(at: time)
                }
                if !GlobalMode.shared.handleCopy(cut: action == .cut, keyTime: time) {
                    let letter: Character = action == .cut ? "x" : "c"
                    let keyCode = KeyboardLayout.commandKeyCode(for: letter) ?? CGKeyCode(action == .cut ? kVK_ANSI_X : kVK_ANSI_C)
                    postKeystroke(keyCode: keyCode, flags: .maskCommand, to: pid)
                }
            case .paste(let shift, let option):
                if !GlobalMode.shared.handleMenuPaste(shift: shift, option: option, keyTime: time, deliberate: deliberate) {
                    var flags: CGEventFlags = .maskCommand
                    if shift {
                        flags.insert(.maskShift)
                    }
                    if option {
                        flags.insert(.maskAlternate)
                    }
                    postKeystroke(keyCode: KeyboardLayout.commandKeyCode(for: "v") ?? CGKeyCode(kVK_ANSI_V), flags: flags, to: pid)
                }
            }
        }
    }

    // MARK: 认菜单项

    private static let menuRoles: Set<String> = [kAXMenuItemRole, kAXMenuRole, kAXMenuBarItemRole, kAXMenuBarRole, kAXPopUpButtonRole, kAXMenuButtonRole]

    // 菜单项是不是"拷贝/剪切/粘贴"：看它的快捷键（⌘C、⌘X、⌘V；⇧⌘V / ⌥⇧⌘V 是"粘贴并匹配样式"，和按键拦截认的一样），
    // 没有快捷键时看标题（这个 App 菜单栏里的本地化写法，以及常见语言）
    // allowTitles：只有右键菜单才按标题认（菜单栏里的这几项都有快捷键；弹出按钮、网页 <select> 的选项可能正好叫 "Paste"）
    private func menuAction(of item: AXUIElement, pid: pid_t, allowTitles: Bool) -> MenuAction? {
        let character = (copyAXAttribute(item, kAXMenuItemCmdCharAttribute) as? String)?.uppercased()
        // 修饰键：0 是只有 ⌘；1 ⇧、2 ⌥、4 ⌃、8 没有 ⌘
        let modifiers = (copyAXAttribute(item, kAXMenuItemCmdModifiersAttribute) as? NSNumber)?.intValue ?? 0
        if let character, !character.isEmpty {
            return Self.action(forCommand: character, modifiers: modifiers)
        }
        guard allowTitles, let title = (copyAXAttribute(item, kAXTitleAttribute) as? String).map(Self.normalizedTitle), !title.isEmpty else {
            return nil
        }
        // 带子菜单的项（开发者工具的 "Copy ▸"）点了只会展开子菜单
        if let children = copyAXAttribute(item, kAXChildrenAttribute) as? [AnyObject], !children.isEmpty {
            return nil
        }
        waitForTitles(pid: pid)
        titleLock.lock()
        let appTitles = localizedTitles[pid]
        let appOtherTitles = otherTitles[pid]
        titleLock.unlock()
        if let action = appTitles?[title] {
            return action
        }
        // 这个 App 把这个标题用在了别的命令上（例如中文、日文的"复制""複製"是"复制一份"，⌘D）
        if appOtherTitles?.contains(title) == true {
            return nil
        }
        if Self.copyTitles.contains(title) {
            return .copy
        }
        if Self.cutTitles.contains(title) {
            return .cut
        }
        if Self.pasteTitles.contains(title) {
            return .paste(shift: false, option: false)
        }
        if Self.pasteMatchingStyleTitles.contains(title) {
            return .paste(shift: true, option: true)
        }
        return nil
    }

    private static func action(forCommand character: String, modifiers: Int) -> MenuAction? {
        switch (character, modifiers) {
        case ("C", 0):
            return .copy
        case ("X", 0):
            return .cut
        case ("V", 0):
            return .paste(shift: false, option: false)
        case ("V", 1):
            return .paste(shift: true, option: false)
        case ("V", 3):
            return .paste(shift: true, option: true)
        default:
            // ⌥⌘V 是"粘贴样式"（TextEdit、Pages），也是 Finder 的"移动到这里"（它自己读剪贴板上的文件，见 readsClipboardItself）
            return nil
        }
    }

    private static func normalizedTitle(_ title: String) -> String {
        title.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "…."))).lowercased()
    }

    // 后台读这个 App 菜单栏里快捷键是 ⌘C/⌘X/⌘V 的菜单项的标题（就是它自己的本地化写法），右键菜单里同名的项照此认
    // 任意线程。App 到了前台时就先读（MenuTracker），右键时还没读好的再读一次
    func loadLocalizedTitles(pid: pid_t) {
        titleLock.lock()
        let recentlyFailed = titlesFailedAt[pid].map { Date().timeIntervalSince($0) < 3 } ?? false
        let needed = localizedTitles[pid] == nil && !recentlyFailed && titlesLoading.insert(pid).inserted
        titleLock.unlock()
        guard needed else {
            return
        }
        titleQueue.async { [self] in
            var titles: [String: MenuAction] = [:]
            var others = Set<String>()
            let application = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(application, 0.1)
            if let menuBar = asAXElement(copyAXAttribute(application, kAXMenuBarAttribute)) {
                let barItems = (copyAXAttribute(menuBar, kAXChildrenAttribute) as? [AnyObject]) ?? []
                for barItem in barItems.prefix(12).compactMap(asAXElement) {
                    let menus = (copyAXAttribute(barItem, kAXChildrenAttribute) as? [AnyObject]) ?? []
                    for menu in menus.prefix(1).compactMap(asAXElement) {
                        let items = (copyAXAttribute(menu, kAXChildrenAttribute) as? [AnyObject]) ?? []
                        // 没有快捷键的项可能是子菜单（JetBrains 的"选择性粘贴"里有 ⌥⇧⌘V 纯文本粘贴）：这个菜单里有粘贴项时再往下看一层
                        var submenuItems: [AXUIElement] = []
                        var hasPaste = false
                        for item in items.prefix(60).compactMap(asAXElement) {
                            guard let character = (copyAXAttribute(item, kAXMenuItemCmdCharAttribute) as? String)?.uppercased(), !character.isEmpty,
                                  let title = (copyAXAttribute(item, kAXTitleAttribute) as? String).map(Self.normalizedTitle), !title.isEmpty else {
                                submenuItems.append(item)
                                continue
                            }
                            let modifiers = (copyAXAttribute(item, kAXMenuItemCmdModifiersAttribute) as? NSNumber)?.intValue ?? 0
                            if let action = Self.action(forCommand: character, modifiers: modifiers) {
                                titles[title] = action
                                if case .paste = action {
                                    hasPaste = true
                                }
                            } else {
                                others.insert(title)
                            }
                        }
                        guard hasPaste else {
                            continue
                        }
                        for item in submenuItems.prefix(12) {
                            guard let submenu = ((copyAXAttribute(item, kAXChildrenAttribute) as? [AnyObject]) ?? []).first.flatMap(asAXElement) else {
                                continue
                            }
                            let subitems = (copyAXAttribute(submenu, kAXChildrenAttribute) as? [AnyObject]) ?? []
                            for subitem in subitems.prefix(30).compactMap(asAXElement) {
                                guard let character = (copyAXAttribute(subitem, kAXMenuItemCmdCharAttribute) as? String)?.uppercased(), !character.isEmpty,
                                      let title = (copyAXAttribute(subitem, kAXTitleAttribute) as? String).map(Self.normalizedTitle), !title.isEmpty else {
                                    continue
                                }
                                let modifiers = (copyAXAttribute(subitem, kAXMenuItemCmdModifiersAttribute) as? NSNumber)?.intValue ?? 0
                                if let action = Self.action(forCommand: character, modifiers: modifiers) {
                                    titles[title] = action
                                } else {
                                    others.insert(title)
                                }
                            }
                        }
                    }
                }
            }
            titleLock.lock()
            // 一个"拷贝/剪切/粘贴"都没找到（菜单栏没读出来）：不记，过几秒再试
            if titles.isEmpty {
                titlesFailedAt[pid] = Date()
            } else {
                localizedTitles[pid] = titles
                otherTitles[pid] = others.subtracting(titles.keys)
                titlesFailedAt[pid] = nil
            }
            titlesLoading.remove(pid)
            titleLock.unlock()
        }
    }

    // 任意线程：这个 App 的菜单栏里 ⇧⌘V（option 为 true 时 ⌥⇧⌘V）是不是一种"粘贴"（粘贴并匹配样式、粘贴为纯文本）。
    // 还没读到它的菜单栏时为 nil
    func menuBindsShiftPaste(pid: pid_t, option: Bool) -> Bool? {
        titleLock.lock()
        defer { titleLock.unlock() }
        guard let titles = localizedTitles[pid] else {
            return nil
        }
        return titles.values.contains { action in
            if case .paste(let shift, let withOption) = action {
                return shift && withOption == option
            }
            return false
        }
    }

    // 主线程：App 退出了：进程号以后会给别的进程，清掉它的缓存
    func forgetTitles(pid: pid_t) {
        titleLock.lock()
        localizedTitles[pid] = nil
        otherTitles[pid] = nil
        titlesFailedAt[pid] = nil
        titleLock.unlock()
    }

    // 任意线程（tap 线程、主线程）：这个 App 的标题正在读：最多等 80 毫秒
    func waitForTitles(pid: pid_t) {
        for _ in 0..<8 {
            titleLock.lock()
            let loading = titlesLoading.contains(pid)
            titleLock.unlock()
            guard loading else {
                return
            }
            usleep(10_000)
        }
    }

    // 右键菜单里通常不显示快捷键：按常见语言的标题认（只认完全一样的，"拷贝链接""复制图像"这类不算）
    private static let copyTitles: Set<String> = [
        // 苹果的中文、日文里"复制""複製"是"复制一份"（⌘D）：不放在这里，用这些说法表示拷贝的 App（Chrome、微信……）靠它菜单栏里的标题认
        "copy", "拷贝", "拷貝", "コピー", "복사", "복사하기", "kopieren", "copier", "copiar", "copia", "копировать",
        "скопировать", "копіювати", "скопіювати", "kopiëren", "kopieer", "kopiera", "kopier", "kopioi", "kopiuj", "kopyala", "kopírovat",
        "másolás", "copiază", "αντιγραφή", "sao chép", "salin", "salin teks",
    ]
    private static let cutTitles: Set<String> = [
        "cut", "剪切", "剪下", "カット", "切り取り", "잘라내기", "오려두기", "ausschneiden", "couper", "cortar", "recortar", "taglia",
        "вырезать", "вирізати", "knippen", "knip", "klipp ut", "klip", "leikkaa", "wytnij", "kes", "vyjmout", "kivágás", "decupează",
        "αποκοπή", "cắt", "potong",
    ]
    private static let pasteTitles: Set<String> = [
        "paste", "粘贴", "粘帖", "贴上", "貼上", "ペースト", "貼り付け", "붙여넣기", "einsetzen", "einfügen", "coller", "pegar", "colar",
        "incolla", "вставить", "вставити", "plakken", "plak", "klistra in", "sæt ind", "lim inn", "liitä", "sijoita", "wklej", "yapıştır",
        "vložit", "beillesztés", "lipește", "επικόλληση", "dán", "tempel",
    ]
    private static let pasteMatchingStyleTitles: Set<String> = [
        "paste and match style", "paste as plain text", "粘贴并匹配样式", "粘贴为纯文本", "貼上並符合樣式", "ペーストしてスタイルを合わせる",
    ]

    // 右键菜单的拷贝/剪切/粘贴作用于点中的东西，Copi 读写的是键盘焦点所在的控件：两者是同一个时才接管。
    //  - 点中的在焦点控件里面（右键选中的文字）：是；
    //  - 粘贴：浏览器在右键按下时已经把焦点给了点中的输入框，看现在的焦点；
    //  - VS Code 系编辑器：看得见的文字对辅助功能隐藏，点中的是包着焦点（隐藏的输入框）的编辑器容器；
    //  - 文件管理器、列表/表格里右键没选中的那一行：菜单项作用于点中的那一行，不是选中的，交给菜单项自己执行；
    //  - 右键消息气泡这类不在焦点控件里的东西：交给菜单项自己执行（写进系统剪贴板的内容随后转移走）
    private static func contextMenuTargetsFocus(_ context: ContextClick, action: MenuAction, pid: pid_t) -> Bool {
        guard let focused = context.focused else {
            return false
        }
        if let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier, fileManagerBundleIDs.contains(bundleID) {
            return false
        }
        if isSelfOrDescendant(context.hit, of: focused) {
            if let hit = context.hit, !CFEqual(hit, focused),
               let role = copyAXAttribute(focused, kAXRoleAttribute) as? String,
               [kAXOutlineRole, kAXTableRole, kAXListRole, kAXBrowserRole, kAXGridRole].contains(role) {
                return false
            }
            return true
        }
        if case .paste = action,
           let now = asAXElement(copyAXAttribute(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute)),
           !((copyAXAttribute(now, kAXRoleAttribute) as? String).map(menuRoles.contains) ?? false),
           isSelfOrDescendant(context.hit, of: now) {
            return true
        }
        if let hit = context.hit, vscodeDataFolderName(pid: pid) != nil, isSelfOrDescendant(focused, of: hit) {
            return true
        }
        return false
    }

    // MARK: 辅助

    // 拿着键盘焦点的 App（可能是不激活自身的浮动面板）。系统查不到时（例如 Brave 在最前面时有时报 kAXErrorNoValue）
    // 和 focusedTarget() 一样退回前台 App：否则它自己菜单栏、右键菜单里的"拷贝"会被当成别的 App 的菜单，照常执行、经过系统剪贴板。
    // 在 tap 线程上调用：用 runningApplications（可以在后台线程读），不用 frontmostApplication
    private static func focusedApplication() -> (pid: pid_t?, element: AXUIElement?) {
        if let application = asAXElement(copyAXAttribute(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute)) {
            var pid: pid_t = 0
            return (AXUIElementGetPid(application, &pid) == .success ? pid : nil, application)
        }
        guard let pid = NSWorkspace.shared.runningApplications.first(where: { $0.isActive })?.processIdentifier else {
            return (nil, nil)
        }
        return (pid, AXUIElementCreateApplication(pid))
    }

    // 网页里的文字可能在很深的层级里：往上找到窗口为止（最多 64 层）
    // maxDepth：最多往上找几层
    static func isSelfOrDescendant(_ element: AXUIElement?, of ancestor: AXUIElement, maxDepth: Int = 64) -> Bool {
        var node = element
        for _ in 0..<maxDepth {
            guard let current = node else {
                return false
            }
            if CFEqual(current, ancestor) {
                return true
            }
            let role = copyAXAttribute(current, kAXRoleAttribute) as? String
            if role == kAXWindowRole || role == kAXApplicationRole {
                return false
            }
            node = asAXElement(copyAXAttribute(current, kAXParentAttribute))
        }
        return false
    }

    // 屏幕坐标（左上角为原点）处的辅助功能元素
    static func element(at location: CGPoint) -> AXUIElement? {
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(location.x), Float(location.y), &element) == .success else {
            return nil
        }
        return element
    }

    // 在某块屏幕顶上的菜单栏里（按 40 点算，包括刘海屏较高的菜单栏）
    private static func isInMenuBar(_ location: CGPoint) -> Bool {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            return false
        }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else {
            return false
        }
        return displays.prefix(Int(count)).contains { display in
            let bounds = CGDisplayBounds(display)
            return location.x >= bounds.minX && location.x < bounds.maxX && location.y >= bounds.minY && location.y < bounds.minY + 40
        }
    }

    // 按下的位置是不是在选中的文字上（在那里拖动就是拖放这段文字）。原生文本控件看字符位置是否落在选区里；
    // 网页用 text marker 判断。认不出来、或者超过 60 毫秒还没问完时返回 false（交给 DragGuard 在拖放开始后清掉）
    private static func isOnSelectedText(_ location: CGPoint) -> Bool {
        let deadline = DispatchTime.now() + .milliseconds(60)
        guard let hit = element(at: location) else {
            return false
        }
        var node: AXUIElement? = hit
        for _ in 0..<6 {
            guard let current = node, DispatchTime.now() < deadline else {
                return false
            }
            AXUIElementSetMessagingTimeout(current, 0.03)
            let role = copyAXAttribute(current, kAXRoleAttribute) as? String
            if role == "AXWebArea" {
                return webSelection(of: current, contains: location, deadline: deadline)
            }
            if let value = copyAXAttribute(current, kAXSelectedTextRangeAttribute), CFGetTypeID(value) == AXValueGetTypeID() {
                var selection = CFRange()
                guard AXValueGetValue(value as! AXValue, .cfRange, &selection), selection.length > 0, DispatchTime.now() < deadline else {
                    return false
                }
                var point = location
                guard let pointValue = AXValueCreate(.cgPoint, &point),
                      let rangeValue = copyAXParameterizedAttribute(current, "AXRangeForPosition", pointValue),
                      CFGetTypeID(rangeValue) == AXValueGetTypeID() else {
                    return false
                }
                var hitRange = CFRange()
                guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &hitRange) else {
                    return false
                }
                return hitRange.location >= selection.location && hitRange.location < selection.location + selection.length
            }
            node = asAXElement(copyAXAttribute(current, kAXParentAttribute))
        }
        return false
    }

    // 网页：按下位置的 text marker 是否落在选区里——选区起点到它、它到选区终点这两段的长度加起来正好等于选区长度
    private static func webSelection(of webArea: AXUIElement, contains location: CGPoint, deadline: DispatchTime) -> Bool {
        func get(_ attribute: String, _ parameter: CFTypeRef) -> CFTypeRef? {
            DispatchTime.now() < deadline ? copyAXParameterizedAttribute(webArea, attribute, parameter) : nil
        }
        AXUIElementSetMessagingTimeout(webArea, 0.03)
        guard let selection = copyAXAttribute(webArea, "AXSelectedTextMarkerRange"),
              let total = (get("AXLengthForTextMarkerRange", selection) as? NSNumber)?.intValue, total > 0,
              let start = get("AXStartTextMarkerForTextMarkerRange", selection),
              let end = get("AXEndTextMarkerForTextMarkerRange", selection) else {
            return false
        }
        var point = location
        guard let pointValue = AXValueCreate(.cgPoint, &point),
              let marker = get("AXTextMarkerForPosition", pointValue),
              let before = get("AXTextMarkerRangeForUnorderedTextMarkers", [start, marker] as CFArray),
              let after = get("AXTextMarkerRangeForUnorderedTextMarkers", [marker, end] as CFArray),
              let first = (get("AXLengthForTextMarkerRange", before) as? NSNumber)?.intValue,
              let second = (get("AXLengthForTextMarkerRange", after) as? NSNumber)?.intValue else {
            return false
        }
        return first + second == total && second > 0
    }
}

// 认不出"按在选中的文字上"、App 已经开始拖放文字时：一发现拖放剪贴板变了、里面是文字（不是文件、图片、链接），立刻清掉
final class DragGuard {
    static let shared = DragGuard()

    private var changeCountAtMouseDown: Int?
    private var lastCheck = Date.distantPast
    private var handledChangeCount: Int?
    // 主线程：按住鼠标期间的定时检查（见 mouseDown）
    private var pollTimer: Timer?
    // 主线程：这次按下以来是不是已经清掉过拖放剪贴板里的文字（这时 Copi 拦下拖动的提示不再另外发）
    private(set) var clearedSinceMouseDown = false

    // 不清的拖放：文件、文件承诺、图片、链接（网址、书签；浏览器拖放选中的文字时不写这些类型）。放下半秒后由
    // DragPasteboardScrubber 清掉其中的文字
    private let keepTypes: Set<NSPasteboard.PasteboardType> = [
        .fileURL, .tiff, .png, .pdf, .URL,
        NSPasteboard.PasteboardType("public.jpeg"),
        NSPasteboard.PasteboardType("public.url-name"),
        NSPasteboard.PasteboardType("WebURLsWithTitlesPboardType"),
        NSPasteboard.PasteboardType("NSFilenamesPboardType"),
        NSPasteboard.PasteboardType("NSPromiseContentsPboardType"),
        NSPasteboard.PasteboardType("com.apple.NSFilePromiseItemMetaData"),
        NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url"),
        NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-content-type"),
    ]
    private let textTypes: Set<NSPasteboard.PasteboardType> = [
        .string, .rtf, .rtfd, .html,
        NSPasteboard.PasteboardType("public.utf16-plain-text"),
        NSPasteboard.PasteboardType("com.apple.flat-rtfd"),
        NSPasteboard.PasteboardType("com.apple.webarchive"),
        NSPasteboard.PasteboardType("Apple Web Archive pasteboard type"),
    ]

    // 主线程
    func mouseDown() {
        changeCountAtMouseDown = NSPasteboard(name: .drag).changeCount
        clearedSinceMouseDown = false
        // 按住选中的文字不动一会儿，NSTextView 这类控件就自己开始拖放了（不等鼠标移动，没有拖动事件；Copi 吞掉拖动事件也拦不住），
        // 所以按住期间一直每 5 毫秒查一次，不只在拖动事件里查。最多查 60 秒
        pollTimer?.invalidate()
        let pressedAt = Date()
        let timer = Timer(timeInterval: 0.005, repeats: true) { timer in
            guard Date().timeIntervalSince(pressedAt) < 60 else {
                timer.invalidate()
                return
            }
            DragGuard.shared.dragMoved()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    // 主线程
    func mouseUp() {
        pollTimer?.invalidate()
        pollTimer = nil
        dragMoved()
    }

    // 主线程：这次按下以来拖放剪贴板变过（App 开始了拖放，包括 Copi 清掉过的）。不知道按下时的情况也算变过
    var dragPasteboardChangedSinceMouseDown: Bool {
        guard let before = changeCountAtMouseDown else {
            return true
        }
        return NSPasteboard(name: .drag).changeCount != before
    }

    // 主线程：拖动中、按住鼠标期间（最多每 5 毫秒查一次）
    func dragMoved() {
        guard Defaults[.isOn], Defaults[.blockTextDragging], GlobalMode.shared.isProtecting,
              let before = changeCountAtMouseDown, Date().timeIntervalSince(lastCheck) > 0.004 else {
            return
        }
        lastCheck = Date()
        let pasteboard = NSPasteboard(name: .drag)
        let changeCount = pasteboard.changeCount
        guard changeCount != before, changeCount != handledChangeCount else {
            return
        }
        let types = Set(pasteboard.types ?? [])
        // 刚清空、还没写进类型：下一次再看
        guard !types.isEmpty else {
            return
        }
        handledChangeCount = changeCount
        guard !types.isDisjoint(with: textTypes), types.isDisjoint(with: keepTypes) else {
            return
        }
        handledChangeCount = pasteboard.clearContents()
        clearedSinceMouseDown = true
        notifyCopiNotice("Copi stopped dragging the text so it doesn't stay on the drag pasteboard. Use ⌘X or ⌘C and then ⌘V to move it.")
    }
}

// MARK: - 键盘操作菜单：跟踪开着的菜单

// 前台 App 里开着哪些菜单（菜单栏的、右键的、弹出按钮的，含子菜单）：在 App 上注册 AXMenuOpened / AXMenuClosed，回调里的元素就是
// 那个菜单。跑在单独的线程上（主线程忙的时候也照常更新）。AXMenuClosed 偶尔会丢：用的时候再确认菜单还在、还有高亮的项
final class MenuTracker {
    static let shared = MenuTracker()

    enum Lookup {
        case item(Highlighted)
        // 屏幕上没有开着的菜单
        case noMenu
        // 有菜单开着，但高亮的不是能执行的项，或者读不出来
        case unknown
    }

    struct Highlighted {
        let item: AXUIElement
        let pid: pid_t
        // 整串菜单最底下的那一个（关菜单用：只关子菜单的话上一层还开着）
        let rootMenu: AXUIElement?
        // 右键菜单（不在菜单栏里，也不是弹出按钮、组合框的菜单）
        let isContextMenu: Bool
        // 这串菜单最底下那个打开的时间（跟踪到了 AXMenuOpened 时）
        let rootOpenedAt: Date?
    }

    private let lock = NSLock()
    // 以下在 lock 里读写
    // 打开的先后顺序，最后的是最深一层
    private var openMenus: [AXUIElement] = []
    // 各个菜单打开的时间（和 openMenus 一一对应）
    private var openedAt: [Date] = []
    private var runLoop: CFRunLoop?
    // AXObserver 确实注册上了的 App（注册不上时为 nil：这时靠菜单栏找开着的菜单，并在下次按回车时再试）
    private var liveObservedPID: pid_t?
    // 以下只在跟踪线程上用
    private var observer: AXObserver?
    private var observedPID: pid_t?
    // 这个 App 注册失败后已经重试了几次
    private var retries = 0
    // 主线程
    private var activationObserver: NSObjectProtocol?
    private var terminationObserver: NSObjectProtocol?

    // 主线程：跟着 ⌘C/⌘V 的接管一起开关
    func start() {
        guard activationObserver == nil else {
            return
        }
        startThreadIfNeeded()
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MenuTracker.shared.observe(pid: app?.processIdentifier)
            // 先把它菜单栏里"拷贝/剪切/粘贴"的本地化标题读好：第一次右键时就认得出"复制"
            if let pid = app?.processIdentifier {
                PointerInterceptor.shared.loadLocalizedTitles(pid: pid)
            }
        }
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { notification in
            if let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier {
                PointerInterceptor.shared.forgetTitles(pid: pid)
                PointerInterceptor.shared.forgetRangeMarks(pid: pid)
            }
        }
        observe(pid: NSWorkspace.shared.frontmostApplication?.processIdentifier)
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            PointerInterceptor.shared.loadLocalizedTitles(pid: pid)
        }
    }

    func stop() {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = nil
        if let terminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(terminationObserver)
        }
        terminationObserver = nil
        observe(pid: nil)
    }

    // 任意线程：前台 App 的 AXObserver 注册上了
    var isLive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return liveObservedPID != nil
    }

    // 任意线程：可能有菜单开着（只是线索，以 highlightedItem 实时读到的为准）
    var mayHaveOpenMenu: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !openMenus.isEmpty
    }

    private func startThreadIfNeeded() {
        lock.lock()
        let running = runLoop != nil
        lock.unlock()
        guard !running else {
            return
        }
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            lock.lock()
            runLoop = CFRunLoopGetCurrent()
            lock.unlock()
            // 没有输入源时 run loop 会立刻返回：挂一个永远用不上的端口
            RunLoop.current.add(NSMachPort(), forMode: .default)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "Copi.MenuTracker"
        thread.qualityOfService = .userInteractive
        thread.start()
        _ = ready.wait(timeout: .now() + 2)
    }

    // 换成跟踪这个 App 的菜单（nil：不跟踪）。在跟踪线程上做
    private func observe(pid: pid_t?) {
        lock.lock()
        let loop = runLoop
        lock.unlock()
        guard let loop else {
            return
        }
        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) {
            MenuTracker.shared.switchObserver(to: pid)
        }
        CFRunLoopWakeUp(loop)
    }

    // 注册失败后重试：期间换了前台 App 就不试了
    private func retryObserving(pid: pid_t) {
        lock.lock()
        let loop = runLoop
        lock.unlock()
        guard let loop else {
            return
        }
        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) {
            let tracker = MenuTracker.shared
            guard tracker.observedPID == pid, tracker.observer == nil else {
                return
            }
            tracker.switchObserver(to: pid)
        }
        CFRunLoopWakeUp(loop)
    }

    private func switchObserver(to pid: pid_t?) {
        // 已经注册上了就不用再来（注册失败时 observer 是 nil，同一个 App 也再试一次）
        guard pid != observedPID || observer == nil else {
            return
        }
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        if pid != observedPID {
            retries = 0
        }
        observer = nil
        observedPID = pid
        lock.lock()
        openMenus.removeAll()
        openedAt.removeAll()
        liveObservedPID = nil
        lock.unlock()
        guard let pid, pid != getpid() else {
            return
        }
        var created: AXObserver?
        guard AXObserverCreate(pid, menuTrackerCallback, &created) == .success, let created else {
            return
        }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.5)
        // 刚启动、还没准备好的 App 会拒绝注册：不挂上去，过一会儿再试（0.5、2、5 秒，换了前台 App 就不试了）
        let results = [kAXMenuOpenedNotification, kAXMenuClosedNotification].map {
            AXObserverAddNotification(created, application, $0 as CFString, nil)
        }
        guard results.allSatisfy({ $0 == .success || $0 == .notificationAlreadyRegistered }) else {
            if retries < 3, !results.contains(.notificationUnsupported), !results.contains(.apiDisabled) {
                let delay = [0.5, 2, 5][retries]
                retries += 1
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) {
                    MenuTracker.shared.retryObserving(pid: pid)
                }
            }
            return
        }
        retries = 0
        CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(created), .defaultMode)
        observer = created
        lock.lock()
        liveObservedPID = pid
        lock.unlock()
    }

    // 跟踪线程
    // 菜单里的"拷贝"不一定是点出来、按回车选的（空格、VoiceOver、语音控制、切换控制、脚本）：Copi 拦不住，但菜单开着时就加密检查
    // 剪贴板，菜单关上（菜单项正在执行）之后再查一会儿，App 写进来的内容尽快转走
    fileprivate func handle(_ notification: String, element: AXUIElement) {
        lock.lock()
        var allClosed = false
        if notification == kAXMenuOpenedNotification {
            if !openMenus.contains(where: { CFEqual($0, element) }) {
                openMenus.append(element)
                openedAt.append(Date())
            }
        } else if let index = openMenus.firstIndex(where: { CFEqual($0, element) }) {
            openMenus.remove(at: index)
            openedAt.remove(at: index)
            allClosed = openMenus.isEmpty
        }
        lock.unlock()
        let opened = notification == kAXMenuOpenedNotification
        guard opened || allClosed else {
            return
        }
        DispatchQueue.main.async {
            guard GlobalMode.shared.isProtecting else {
                return
            }
            if opened {
                MenuTracker.shared.keepCheckingWhileOpen(since: Date())
            } else {
                // 菜单关上了：菜单项正在执行，再查半秒就够了
                NSPasteboard.general.limitFrequentCheck(to: 0.5)
                NSPasteboard.general.checkFrequently(for: 0.5)
            }
        }
    }

    // 主线程：菜单开着（屏幕上确实有菜单窗口）就一直加密检查（每秒续一次，最多 2 分钟）。同一时间只有一串
    private var checkingSince: Date?

    fileprivate func keepCheckingWhileOpen(since start: Date) {
        if let checkingSince, checkingSince != start {
            return
        }
        guard GlobalMode.shared.isProtecting, mayHaveOpenMenu, Self.menuWindowIsOnScreen(), Date().timeIntervalSince(start) < 120 else {
            checkingSince = nil
            return
        }
        checkingSince = start
        NSPasteboard.general.checkFrequently(for: 1.2)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            MenuTracker.shared.keepCheckingWhileOpen(since: start)
        }
    }

    // 任意线程（键盘 tap 线程）：现在高亮的菜单项。先问窗口服务器屏幕上有没有菜单窗口（不用和目标 App 来回通信，没有就清掉
    // 跟踪记录）；再从最深一层开着的菜单往回找。没有跟踪到菜单、AXObserver 又没注册上时看前台 App 的菜单栏。
    // 最多查 120 毫秒；读不到、高亮的是带子菜单的项（回车只会展开它）时返回 unknown
    func highlightedItem() -> Lookup {
        let deadline = DispatchTime.now() + .milliseconds(120)
        guard Self.menuWindowIsOnScreen() else {
            lock.lock()
            openMenus.removeAll()
            openedAt.removeAll()
            lock.unlock()
            return .noMenu
        }
        lock.lock()
        var menus = openMenus
        let openTimes = Array(zip(openMenus, openedAt))
        let live = liveObservedPID
        lock.unlock()
        if menus.isEmpty {
            // AXObserver 没注册上（App 刚启动时会这样）：下次再试，这次看菜单栏
            if live == nil, let application = asAXElement(copyAXAttribute(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute)) {
                var pid: pid_t = 0
                if AXUIElementGetPid(application, &pid) == .success {
                    observe(pid: pid)
                }
            }
            guard live == nil, let menu = openMenuBarMenu(deadline: deadline) else {
                return .unknown
            }
            menus = [menu]
        }
        var closed: [AXUIElement] = []
        defer {
            if !closed.isEmpty {
                lock.lock()
                for index in openMenus.indices.reversed() where closed.contains(where: { CFEqual($0, openMenus[index]) }) {
                    openMenus.remove(at: index)
                    openedAt.remove(at: index)
                }
                lock.unlock()
            }
        }
        for menu in menus.reversed() {
            guard DispatchTime.now() < deadline else {
                return .unknown
            }
            AXUIElementSetMessagingTimeout(menu, 0.05)
            guard copyAXAttribute(menu, kAXRoleAttribute) as? String == kAXMenuRole else {
                closed.append(menu)
                continue
            }
            guard let item = highlightedChild(of: menu, deadline: deadline) else {
                // 菜单栏里的菜单关掉之后元素还在：它的菜单栏项不再选中，就是关了
                if let parent = asAXElement(copyAXAttribute(menu, kAXParentAttribute)),
                   copyAXAttribute(parent, kAXRoleAttribute) as? String == kAXMenuBarItemRole,
                   copyAXAttribute(parent, kAXSelectedAttribute) as? Bool == false {
                    closed.append(menu)
                }
                continue
            }
            if let children = copyAXAttribute(item, kAXChildrenAttribute) as? [AnyObject], !children.isEmpty {
                return .unknown
            }
            var pid: pid_t = 0
            guard AXUIElementGetPid(item, &pid) == .success, pid != getpid() else {
                return .unknown
            }
            let (root, isContextMenu) = chainRoot(of: menu, deadline: deadline)
            let rootOpenedAt = openTimes.first(where: { CFEqual($0.0, root) })?.1
            return .item(Highlighted(item: item, pid: pid, rootMenu: root, isContextMenu: isContextMenu, rootOpenedAt: rootOpenedAt))
        }
        return .unknown
    }

    // 屏幕上有没有菜单窗口（菜单栏的、右键的、弹出按钮的菜单都在这一层）。只读窗口的层级和所属进程，不需要屏幕录制权限
    private static func menuWindowIsOnScreen() -> Bool {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            // 读不到时不能断定没有菜单
            return true
        }
        let menuLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
        let ownPID = Int(getpid())
        return windows.contains { window in
            (window[kCGWindowLayer as String] as? Int) == menuLevel && (window[kCGWindowOwnerPID as String] as? Int) != ownPID
        }
    }

    // 高亮的子项：AXSelectedChildren，读不到就找 AXSelected 的那个
    private func highlightedChild(of menu: AXUIElement, deadline: DispatchTime) -> AXUIElement? {
        if let selected = copyAXAttribute(menu, kAXSelectedChildrenAttribute) as? [AnyObject], let first = selected.first {
            return asAXElement(first)
        }
        let children = (copyAXAttribute(menu, kAXChildrenAttribute) as? [AnyObject]) ?? []
        for child in children.prefix(80).compactMap(asAXElement) {
            guard DispatchTime.now() < deadline else {
                return nil
            }
            if copyAXAttribute(child, kAXSelectedAttribute) as? Bool == true {
                return child
            }
        }
        return nil
    }

    // 往上找到这串菜单最底下的那个：上一层是菜单项（子菜单）就继续往上；是菜单栏项就是菜单栏里的菜单；别的是右键菜单、弹出按钮的菜单
    private func chainRoot(of menu: AXUIElement, deadline: DispatchTime) -> (root: AXUIElement, isContextMenu: Bool) {
        var current = menu
        for _ in 0..<8 {
            guard DispatchTime.now() < deadline, let parent = asAXElement(copyAXAttribute(current, kAXParentAttribute)) else {
                break
            }
            switch copyAXAttribute(parent, kAXRoleAttribute) as? String {
            case kAXMenuItemRole?:
                guard let parentMenu = asAXElement(copyAXAttribute(parent, kAXParentAttribute)) else {
                    return (current, true)
                }
                current = parentMenu
            case kAXMenuBarItemRole?:
                return (current, false)
            // 弹出按钮、组合框（网页的 <select>）的菜单：选项可能正好叫 "Paste"，不按右键菜单处理
            case kAXPopUpButtonRole?, kAXMenuButtonRole?, kAXComboBoxRole?:
                return (current, false)
            default:
                return (current, true)
            }
        }
        return (current, true)
    }

    // 没有跟踪到开着的菜单时（AXObserver 没注册上）：前台 App 菜单栏里选中的那一项下面的菜单
    private func openMenuBarMenu(deadline: DispatchTime) -> AXUIElement? {
        guard let application = asAXElement(copyAXAttribute(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute)) else {
            return nil
        }
        AXUIElementSetMessagingTimeout(application, 0.05)
        guard let menuBar = asAXElement(copyAXAttribute(application, kAXMenuBarAttribute)) else {
            return nil
        }
        for barItem in ((copyAXAttribute(menuBar, kAXChildrenAttribute) as? [AnyObject]) ?? []).prefix(20).compactMap(asAXElement) {
            guard DispatchTime.now() < deadline else {
                return nil
            }
            if copyAXAttribute(barItem, kAXSelectedAttribute) as? Bool == true {
                return ((copyAXAttribute(barItem, kAXChildrenAttribute) as? [AnyObject]) ?? []).first.flatMap(asAXElement)
            }
        }
        return nil
    }
}

private func menuTrackerCallback(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    MenuTracker.shared.handle(notification as String, element: element)
}
