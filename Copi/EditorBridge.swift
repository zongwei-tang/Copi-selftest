//
//  EditorBridge.swift
//  Copi
//
//  VS Code 系编辑器（VS Code、Cursor、Windsurf、VSCodium、Positron……）的桥接。
//  这些编辑器的输入框是个代理节点：Accessibility 写不进去，模拟键入又会被逐字处理（自动补全括号、自动缩进、确认补全候选），
//  选区也读不全。Copi 自带一个很小的编辑器扩展（见 EditorBridgeExtension），扩展启动后连到 Copi 的本地 socket：
//   - 先往编辑器里按一个私有快捷键：拿着焦点的那个窗口的扩展回应，并说出焦点在编辑器、小输入框还是终端里；
//   - 复制：扩展读出选中的文字，多光标、空选区复制整行都和编辑器自己的复制一样；剪切再用编辑器自己的 cut 删除；
//   - 粘贴：扩展调用编辑器自己的 paste 命令插入文字，效果和真正的粘贴一样；
//   - 终端：扩展把文字送进当前终端（由 Copi 先确认终端停在 shell 提示符前）。
//  全程不经过系统剪贴板。
//
//  只和编辑器自己的扩展进程说话：连进来的进程必须是某个 VS Code 系编辑器主进程直接启动的子进程、程序文件在它的 App 包里、
//  代码签名有效——编辑器终端里运行的程序（哪怕用的是编辑器自己的程序文件）冒充不了，也就拿不到要粘贴的内容。（扩展这一侧没法确认 socket 那头是不是 Copi；
//  但能在本机以同一用户运行代码的程序本来就能给编辑器装扩展，这一点不比现在更差。）
//

import Foundation
import AppKit
import Security
import Carbon

final class EditorBridge {
    static let shared = EditorBridge()

    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Copi", isDirectory: true)
    }

    static var socketPath: String {
        directory.appendingPathComponent("bridge.sock").path
    }

    // 焦点在编辑器的什么地方：扩展按快捷键的 when 条件告诉 Copi
    enum FocusPlace: String {
        // 文件编辑器（包括 diff、notebook 单元格、peek 里的编辑器）
        case editor
        // 小输入框里的编辑器：提交信息框、聊天输入框、设置搜索框
        case simpleEditor
        case terminal
        // 别的地方：快速打开、查找框、网页视图、Vim 的命令行……
        case other
    }

    // 回应了私有快捷键的那个窗口（的扩展连接），以及焦点在它的什么地方
    struct Focus {
        fileprivate let connectionID: Int
        // 回应的是哪一个快捷键：之后的请求都带上它，扩展只接受刚刚回应过的快捷键发起的请求
        fileprivate let chord: Int
        let place: FocusPlace
        // 远程窗口（SSH、容器、WSL）：终端里的进程不在这台 Mac 上
        let isRemote: Bool
    }

    private final class Connection {
        // 每个连接一个编号（文件描述符会被复用）
        let id: Int
        let fd: Int32
        // 编辑器主进程（扩展进程的父进程）
        let appPID: pid_t
        // 连进来的扩展进程（编辑器每个窗口一个）
        let peerPID: pid_t
        // 扩展在 hello 里报的协议版本：和 Copi 的不一致时不用（装的是旧版本扩展）
        var protocolVersion = 0
        var buffer = Data()
        var source: DispatchSourceRead?

        init(id: Int, fd: Int32, appPID: pid_t, peerPID: pid_t) {
            self.id = id
            self.fd = fd
            self.appPID = appPID
            self.peerPID = peerPID
        }
    }

    private final class PendingReply {
        // 请求发给了哪条连接：只认这条连接上的回复
        let connectionID: Int
        let semaphore = DispatchSemaphore(value: 0)
        var response: [String: Any]?

        init(connectionID: Int) {
            self.connectionID = connectionID
        }
    }

    private final class PendingDispatch {
        let appPID: pid_t
        // 这次按的是哪一个私有快捷键（见 dispatchKeys）
        let chord: Int
        let semaphore = DispatchSemaphore(value: 0)
        var answer: Focus?

        init(appPID: pid_t, chord: Int) {
            self.appPID = appPID
            self.chord = chord
        }
    }

    // 私有快捷键：⌃⌥⇧⌘ 加 F16–F19 之一，每次随机挑一个。扩展的回应带着按键的编号，对不上的（来晚了的、乱猜的）不认。
    // 编辑器里的扩展都跑在同一个进程里、彼此没有隔离，存心冒充的扩展拦不住，这些只是提高门槛
    static let dispatchKeys: [Int] = [kVK_F16, kVK_F17, kVK_F18, kVK_F19]

    // 以下状态只在 queue 上读写
    private let queue = DispatchQueue(label: "Copi.EditorBridge")
    private var listenSource: DispatchSourceRead?
    private var connections: [Int: Connection] = [:]
    private var nextConnectionID = 1
    private var pending: [Int: PendingReply] = [:]
    private var nextID = 1
    private var pendingDispatch: PendingDispatch?
    // 没等到回应的快捷键（编辑器 → 编号 → 过期时间）：它们的回应可能稍后才到，到了就丢掉；过期之前也不再用这个编号
    private var unansweredChords: [pid_t: [Int: DispatchTime]] = [:]
    // 同一个扩展进程连进来不止一条连接：除了 Copi Bridge，同一进程里还有别的扩展在冒充它。这个进程不再使用
    private var compromisedPeers = Set<pid_t>()

    // MARK: 启动

    func start() {
        queue.async { [self] in
            guard listenSource == nil else {
                return
            }
            // 建不起来（目录不可写等）就不提供桥接：VS Code 系编辑器里照旧按不能 0 暴露处理
            guard let fd = Self.makeListeningSocket() else {
                return
            }
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in
                self?.acceptConnections(on: fd)
            }
            source.setCancelHandler {
                close(fd)
            }
            listenSource = source
            source.resume()
        }
    }

    private static func makeListeningSocket() -> Int32? {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } catch {
            return nil
        }
        let path = socketPath
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            return nil
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < capacity else {
            close(fd)
            return nil
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 8) == 0 else {
            close(fd)
            return nil
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        return fd
    }

    private func acceptConnections(on listenFD: Int32) {
        while true {
            let fd = accept(listenFD, nil, nil)
            guard fd >= 0 else {
                return
            }
            var noSigPipe: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            // 写入最多等 0.5 秒：对方不读的话不能把 Copi 卡住
            var timeout = timeval(tv_sec: 0, tv_usec: 500_000)
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var peerPID: pid_t = 0
            var peerLength = socklen_t(MemoryLayout<pid_t>.size)
            guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &peerPID, &peerLength) == 0, !compromisedPeers.contains(peerPID),
                  let appPID = Self.verifiedEditorApp(forPeerOf: fd) else {
                close(fd)
                continue
            }
            // 同一个扩展进程里已经有一条还活着的连接：Copi Bridge 只会连一条，另一条是同一进程里别的扩展在冒充。
            // 都断开，这个窗口不再使用桥接（重新加载窗口后扩展进程换了，才会再用）
            for other in connections.values where other.peerPID == peerPID && !isAlive(other) {
                drop(other)
            }
            if connections.values.contains(where: { $0.peerPID == peerPID }) {
                close(fd)
                compromisedPeers.insert(peerPID)
                for suspect in connections.values where suspect.peerPID == peerPID {
                    drop(suspect)
                }
                let appName = NSRunningApplication(processIdentifier: appPID)?.localizedName ?? "the editor"
                DispatchQueue.main.async {
                    notifyCopiNotice("Something else in \(appName) tried to connect to Copi Bridge, so Copi stopped using the bridge in that window. Check your extensions, then reload the window.")
                }
                continue
            }
            let connection = Connection(id: nextConnectionID, fd: fd, appPID: appPID, peerPID: peerPID)
            nextConnectionID += 1
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self, weak connection] in
                guard let self, let connection else {
                    return
                }
                self.read(from: connection)
            }
            source.setCancelHandler {
                close(fd)
            }
            connection.source = source
            connections[connection.id] = connection
            source.resume()
        }
    }

    // MARK: 确认对方是编辑器自己的扩展进程

    // 返回编辑器主进程的 pid；不是的话返回 nil
    private static func verifiedEditorApp(forPeerOf fd: Int32) -> pid_t? {
        var peerPID: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &peerPID, &length) == 0, peerPID > 0 else {
            return nil
        }
        // 扩展进程由编辑器主进程直接启动；集成终端、任务里的进程都挂在终端服务进程下面，冒充不了
        guard let parent = parentProcessID(of: peerPID), parent > 1,
              let editor = NSRunningApplication(processIdentifier: parent), isVSCodeFamilyApp(pid: parent),
              let bundlePath = editor.bundleURL?.standardizedFileURL.path else {
            return nil
        }
        // 程序文件在编辑器的 App 包里，并且代码签名有效（App 包被改过的话签名就失效了）
        guard let executable = executablePath(of: peerPID), executable.hasPrefix(bundlePath + "/"),
              hasValidCodeSignature(pid: peerPID) else {
            return nil
        }
        return editor.processIdentifier
    }

    private static func executablePath(of pid: pid_t) -> String? {
        processExecutablePath(pid: pid).map { URL(fileURLWithPath: $0).standardizedFileURL.path }
    }

    private static func hasValidCodeSignature(pid: pid_t) -> Bool {
        var code: SecCode?
        let attributes = [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, SecCSFlags(), &code) == errSecSuccess, let code else {
            return false
        }
        return SecCodeCheckValidity(code, SecCSFlags(), nil) == errSecSuccess
    }

    // MARK: 收发

    private func read(from connection: Connection) {
        var chunk = [UInt8](repeating: 0, count: 65_536)
        let count = Darwin.read(connection.fd, &chunk, chunk.count)
        guard count > 0 else {
            drop(connection)
            return
        }
        connection.buffer.append(contentsOf: chunk[0..<count])
        // 一行一个 JSON。太长的行（不正常）直接断开
        guard connection.buffer.count < 64 * 1024 * 1024 else {
            drop(connection)
            return
        }
        while let newline = connection.buffer.firstIndex(of: 0x0A) {
            let line = connection.buffer[connection.buffer.startIndex..<newline]
            connection.buffer.removeSubrange(connection.buffer.startIndex...newline)
            guard let message = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else {
                continue
            }
            // 处理到一半被断开了（例如被认定为冒充）：剩下的行不再处理
            guard connections[connection.id] != nil else {
                return
            }
            handle(message, from: connection)
        }
    }

    private func handle(_ message: [String: Any], from connection: Connection) {
        if let id = (message["id"] as? NSNumber)?.intValue {
            if let reply = pending[id], reply.connectionID == connection.id {
                reply.response = message
                reply.semaphore.signal()
            }
            return
        }
        switch message["type"] as? String {
        case "hello":
            connection.protocolVersion = (message["protocol"] as? NSNumber)?.intValue ?? 0
        case "dispatch":
            let chord = (message["chord"] as? NSNumber)?.intValue ?? -1
            // 之前没等到的快捷键的回应：丢掉
            if unansweredChords[connection.appPID]?[chord] != nil {
                unansweredChords[connection.appPID]?[chord] = nil
                return
            }
            // 只认正在等的那一次（同一个编辑器、协议版本对得上、按的正是这个快捷键）
            guard let waiting = pendingDispatch, waiting.answer == nil, waiting.appPID == connection.appPID, waiting.chord == chord,
                  connection.protocolVersion == EditorBridgeExtension.protocolVersion else {
                return
            }
            let place = FocusPlace(rawValue: message["target"] as? String ?? "") ?? .other
            waiting.answer = Focus(connectionID: connection.id, chord: chord, place: place, isRemote: message["remote"] is String)
            waiting.semaphore.signal()
        default:
            break
        }
    }

    // 连接的另一头还在（没有关闭）
    private func isAlive(_ connection: Connection) -> Bool {
        var descriptor = pollfd(fd: connection.fd, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, 0) > 0 else {
            return true
        }
        if descriptor.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 {
            return false
        }
        var byte: UInt8 = 0
        return recv(connection.fd, &byte, 1, Int32(MSG_PEEK)) != 0
    }

    private func drop(_ connection: Connection) {
        connection.source?.cancel()
        connection.source = nil
        connections[connection.id] = nil
    }

    // 连接是非阻塞的（继承自监听 socket）：缓冲区满了就等它腾出空间，最多等 0.5 秒。写出半行之后失败的话，这条连接就没法再分帧了，
    // 直接断开（扩展会清空缓冲区重新连上），那半行永远不会被执行
    private func write(_ message: [String: Any], to connection: Connection) -> Bool {
        guard var data = try? JSONSerialization.data(withJSONObject: message) else {
            return false
        }
        data.append(0x0A)
        let deadline = DispatchTime.now() + 0.5
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { raw in
                Darwin.write(connection.fd, raw.baseAddress!.advanced(by: offset), data.count - offset)
            }
            if written > 0 {
                offset += written
                continue
            }
            if written < 0, errno == EAGAIN || errno == EINTR {
                let now = DispatchTime.now().uptimeNanoseconds
                let end = deadline.uptimeNanoseconds
                var descriptor = pollfd(fd: connection.fd, events: Int16(POLLOUT), revents: 0)
                if end > now, poll(&descriptor, 1, Int32(max(1, (end - now) / 1_000_000))) > 0 {
                    continue
                }
            }
            if offset > 0 {
                drop(connection)
            }
            return false
        }
        return true
    }

    // MARK: 给 ⌘C/⌘V 用（主线程）

    // 这个编辑器（主进程 appPID）有没有连上来、版本对得上的扩展
    func isConnected(appPID: pid_t) -> Bool {
        queue.sync {
            connections.values.contains { $0.appPID == appPID && $0.protocolVersion == EditorBridgeExtension.protocolVersion }
        }
    }

    // 这个编辑器连上来的扩展是旧版本（要在设置里重新安装）
    func hasOutdatedConnection(appPID: pid_t) -> Bool {
        queue.sync {
            connections.values.contains { $0.appPID == appPID && $0.protocolVersion != EditorBridgeExtension.protocolVersion }
        }
    }

    // 往编辑器里按一下私有快捷键（⌃⌥⇧⌘F19），看哪个窗口的扩展回应、焦点在它的什么地方。
    // 编辑器的每个窗口各有一个扩展进程，只有拿着键盘焦点的那个窗口收得到这个按键——这样就不会把内容交给别的窗口。
    // 这个按键在编辑器里没有别的作用（没有回应时什么都不会发生）。没装扩展、没回应时返回 nil
    func locateFocus(appPID: pid_t, timeout: TimeInterval) -> Focus? {
        dispatchPrecondition(condition: .onQueue(.main))
        let waiting: PendingDispatch? = queue.sync {
            guard connections.values.contains(where: { $0.appPID == appPID && $0.protocolVersion == EditorBridgeExtension.protocolVersion }) else {
                return nil
            }
            // 过期的记录清掉；挑一个最近没有在等回应的快捷键
            let now = DispatchTime.now()
            unansweredChords[appPID] = unansweredChords[appPID]?.filter { now < $0.value }
            let busy = Set(unansweredChords[appPID]?.keys.map { $0 } ?? [])
            guard let chord = Array(Self.dispatchKeys.indices).filter({ !busy.contains($0) }).randomElement() else {
                return nil
            }
            let waiting = PendingDispatch(appPID: appPID, chord: chord)
            pendingDispatch = waiting
            return waiting
        }
        guard let waiting else {
            return nil
        }
        Self.postDispatchChord(Self.dispatchKeys[waiting.chord], to: appPID)
        _ = waitAttentively(waiting.semaphore, timeout: max(0.05, timeout))
        return queue.sync {
            if pendingDispatch === waiting {
                pendingDispatch = nil
            }
            // 刚好在等待结束时到达的回应也算（它一定是这一次快捷键的回应）
            if let answer = waiting.answer {
                return answer
            }
            unansweredChords[appPID, default: [:]][waiting.chord] = .now() + 5
            return nil
        }
    }

    // 直接发给编辑器进程（不经过别的 App、不经过输入法）。带着 Copi 的标记，⌘C/⌘V 拦截器不会处理它
    private static func postDispatchChord(_ key: Int, to pid: pid_t) {
        let source = CGEventSource(stateID: .privateState)
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: keyDown) else {
                continue
            }
            event.flags = [.maskControl, .maskAlternate, .maskShift, .maskCommand, .maskSecondaryFn]
            event.setIntegerValueField(.eventSourceUserData, value: copiSyntheticEventMarker)
            event.postToPid(pid)
        }
    }

    enum Reply {
        case response([String: Any])
        // 没连上，或者发不出去：请求肯定没有执行
        case notSent
        // 发出去了但没等到回音：请求可能已经（或稍后）执行
        case timedOut
    }

    // 向回应了快捷键的那个窗口的扩展发一个请求，最多等 timeout。请求带着截止时间，扩展晚于它收到时不执行
    func request(_ payload: [String: Any], to focus: Focus, timeout: TimeInterval) -> Reply {
        let prepared: (Int, PendingReply)? = queue.sync {
            guard let connection = connections[focus.connectionID] else {
                return nil
            }
            let id = nextID
            nextID += 1
            var message = payload
            message["id"] = id
            message["chord"] = focus.chord
            message["deadline"] = (Date().timeIntervalSince1970 + timeout) * 1000
            let reply = PendingReply(connectionID: connection.id)
            pending[id] = reply
            guard write(message, to: connection) else {
                pending[id] = nil
                return nil
            }
            return (id, reply)
        }
        guard let (id, reply) = prepared else {
            return .notSent
        }
        let result = waitAttentively(reply.semaphore, timeout: timeout)
        return queue.sync {
            pending[id] = nil
            if result == .success, let response = reply.response {
                return .response(response)
            }
            return .timedOut
        }
    }
}

// 父进程号；读不到时为 nil
func parentProcessID(of pid: pid_t) -> pid_t? {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else {
        return nil
    }
    return info.kp_eproc.e_ppid
}

// pid 是不是 ancestor 的子孙进程
func isDescendant(_ pid: pid_t, of ancestor: pid_t) -> Bool {
    var current = pid
    for _ in 0..<16 {
        guard let parent = parentProcessID(of: current), parent > 0 else {
            return false
        }
        if parent == ancestor {
            return true
        }
        if parent == 1 {
            return false
        }
        current = parent
    }
    return false
}

// VS Code 系编辑器：包里有 Contents/Resources/app/product.json，写着它在用户目录下的数据文件夹
func isVSCodeFamilyApp(pid: pid_t) -> Bool {
    vscodeDataFolderName(pid: pid) != nil
}

// MARK: - 安装扩展

struct VSCodeFamilyEditor {
    let name: String
    let bundleURL: URL
    // 用户目录下的数据文件夹（".vscode"、".cursor"……），扩展装在它的 extensions 里
    let dataFolderName: String
    // App 包里自带的命令行工具（code、cursor、windsurf……），用来安装扩展
    let commandLineTool: URL?

    var isBridgeInstalled: Bool {
        bridgeFolders.contains { $0.hasPrefix("\(EditorBridgeExtension.publisher).\(EditorBridgeExtension.name)-") }
    }

    // 装着的是这个版本的 Copi 自带的扩展（更早的版本可能根本没被编辑器加载，例如 1.2.0 的 engines 写成了 "*"）
    var isBridgeCurrent: Bool {
        bridgeFolders.contains("\(EditorBridgeExtension.publisher).\(EditorBridgeExtension.name)-\(EditorBridgeExtension.version)")
    }

    private var bridgeFolders: [String] {
        let extensions = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("\(dataFolderName)/extensions")
        return ((try? FileManager.default.contentsOfDirectory(atPath: extensions.path)) ?? []).map { $0.lowercased() }
    }

    // /Applications 和 ~/Applications 里的 VS Code 系编辑器
    static func installed() -> [VSCodeFamilyEditor] {
        let fileManager = FileManager.default
        let folders = [URL(fileURLWithPath: "/Applications"), fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        var editors: [VSCodeFamilyEditor] = []
        for folder in folders {
            for name in (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasSuffix(".app") {
                let bundle = folder.appendingPathComponent(name)
                guard let editor = VSCodeFamilyEditor(bundleURL: bundle) else {
                    continue
                }
                editors.append(editor)
            }
        }
        return editors.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    init?(bundleURL: URL) {
        let product = bundleURL.appendingPathComponent("Contents/Resources/app/product.json")
        guard let data = try? Data(contentsOf: product),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let dataFolderName = json["dataFolderName"] as? String, !dataFolderName.isEmpty else {
            return nil
        }
        self.bundleURL = bundleURL
        self.dataFolderName = dataFolderName
        name = (json["nameLong"] as? String) ?? bundleURL.deletingPathExtension().lastPathComponent
        let bin = bundleURL.appendingPathComponent("Contents/Resources/app/bin")
        let preferred = (json["applicationName"] as? String).map { [$0] } ?? []
        let candidates = preferred + ["code", "cursor", "windsurf", "codium", "positron", "code-insiders"]
        commandLineTool = candidates.lazy.map { bin.appendingPathComponent($0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    // 后台线程调用：打包扩展、用编辑器自带的命令行工具安装。返回失败原因（成功为 nil）
    func installBridge() -> String? {
        guard let commandLineTool else {
            return "\(name) has no command-line tool to install extensions with."
        }
        guard let vsix = EditorBridgeExtension.buildPackage() else {
            return "Copi couldn't package the extension."
        }
        defer { try? FileManager.default.removeItem(at: vsix.deletingLastPathComponent()) }
        // Copi 是从编辑器的终端里启动的话，环境里会带着这些变量，命令行工具会转而去找那个编辑器窗口或者当成 Node 运行
        var environment = ProcessInfo.processInfo.environment
        for name in ["VSCODE_IPC_HOOK_CLI", "ELECTRON_RUN_AS_NODE", "NODE_OPTIONS", "VSCODE_CWD", "VSCODE_PID"] {
            environment[name] = nil
        }
        // 不让设置同步把它带到别的电脑上（那里没有 Copi）。HelperProcess：命令行工具不带着 Copi 的权限运行
        let result = HelperProcess.run(commandLineTool.path, ["--install-extension", vsix.path, "--force", "--do-not-sync"],
                                       environment: environment, timeout: 120)
        switch result {
        case .output:
            return nil
        case .timedOut:
            return "\(commandLineTool.lastPathComponent) took too long."
        case .failed:
            return "\(commandLineTool.lastPathComponent) couldn't install the extension."
        }
    }
}

// MARK: - 扩展本身

// Copi 自带的编辑器扩展：纯 JavaScript，不需要构建。安装时在临时目录里打包成 .vsix（一个 zip），交给编辑器自带的命令行工具安装
enum EditorBridgeExtension {
    static let publisher = "copi"
    static let name = "copi-bridge"
    static let version = "1.2.1"
    // 和扩展之间的协议版本（扩展连上来时在 hello 里报）
    static let protocolVersion = 4

    static let packageJSON = #"""
    {
      "name": "copi-bridge",
      "displayName": "Copi Bridge",
      "description": "Lets Copi copy and paste in this editor without the system clipboard.",
      "version": "1.2.1",
      "publisher": "copi",
      "license": "MIT",
      "engines": { "vscode": "^1.47.0" },
      "categories": ["Other"],
      "main": "./extension.js",
      "activationEvents": ["onStartupFinished"],
      "extensionKind": ["ui"],
      "capabilities": {
        "untrustedWorkspaces": { "supported": true },
        "virtualWorkspaces": true
      },
      "contributes": {
        "commands": [{ "command": "copi.bridge.dispatch", "title": "Copi Bridge: Dispatch" }],
        "menus": { "commandPalette": [{ "command": "copi.bridge.dispatch", "when": "false" }] },
        "keybindings": [
          {"key": "ctrl+alt+shift+cmd+f16", "command": "copi.bridge.dispatch", "args": {"target": "other", "chord": 0}},
          {"key": "ctrl+alt+shift+cmd+f16", "command": "copi.bridge.dispatch", "args": {"target": "simpleEditor", "chord": 0}, "when": "textInputFocus && editorSimpleInput"},
          {"key": "ctrl+alt+shift+cmd+f16", "command": "copi.bridge.dispatch", "args": {"target": "editor", "chord": 0}, "when": "editorTextFocus && !editorSimpleInput"},
          {"key": "ctrl+alt+shift+cmd+f16", "command": "copi.bridge.dispatch", "args": {"target": "other", "chord": 0}, "when": "editorTextFocus && vim.active && vim.mode == 'CommandlineInProgress'"},
          {"key": "ctrl+alt+shift+cmd+f16", "command": "copi.bridge.dispatch", "args": {"target": "other", "chord": 0}, "when": "editorTextFocus && vim.active && vim.mode == 'SearchInProgressMode'"},
          {"key": "ctrl+alt+shift+cmd+f16", "command": "copi.bridge.dispatch", "args": {"target": "terminal", "chord": 0}, "when": "terminalFocus"},
          {"key": "ctrl+alt+shift+cmd+f17", "command": "copi.bridge.dispatch", "args": {"target": "other", "chord": 1}},
          {"key": "ctrl+alt+shift+cmd+f17", "command": "copi.bridge.dispatch", "args": {"target": "simpleEditor", "chord": 1}, "when": "textInputFocus && editorSimpleInput"},
          {"key": "ctrl+alt+shift+cmd+f17", "command": "copi.bridge.dispatch", "args": {"target": "editor", "chord": 1}, "when": "editorTextFocus && !editorSimpleInput"},
          {"key": "ctrl+alt+shift+cmd+f17", "command": "copi.bridge.dispatch", "args": {"target": "other", "chord": 1}, "when": "editorTextFocus && vim.active && vim.mode == 'CommandlineInProgress'"},
          {"key": "ctrl+alt+shift+cmd+f17", "command": "copi.bridge.dispatch", "args": {"target": "other", "chord": 1}, "when": "editorTextFocus && vim.active && vim.mode == 'SearchInProgressMode'"},
          {"key": "ctrl+alt+shift+cmd+f17", "command": "copi.bridge.dispatch", "args": {"target": "terminal", "chord": 1}, "when": "terminalFocus"},
          {"key": "ctrl+alt+shift+cmd+f18", "command": "copi.bridge.dispatch", "args": {"target": "other", "chord": 2}},
          {"key": "ctrl+alt+shift+cmd+f18", "command": "copi.bridge.dispatch", "args": {"target": "simpleEditor", "chord": 2}, "when": "textInputFocus && editorSimpleInput"},
          {"key": "ctrl+alt+shift+cmd+f18", "command": "copi.bridge.dispatch", "args": {"target": "editor", "chord": 2}, "when": "editorTextFocus && !editorSimpleInput"},
          {"key": "ctrl+alt+shift+cmd+f18", "command": "copi.bridge.dispatch", "args": {"target": "other", "chord": 2}, "when": "editorTextFocus && vim.active && vim.mode == 'CommandlineInProgress'"},
          {"key": "ctrl+alt+shift+cmd+f18", "command": "copi.bridge.dispatch", "args": {"target": "other", "chord": 2}, "when": "editorTextFocus && vim.active && vim.mode == 'SearchInProgressMode'"},
          {"key": "ctrl+alt+shift+cmd+f18", "command": "copi.bridge.dispatch", "args": {"target": "terminal", "chord": 2}, "when": "terminalFocus"},
          {"key": "ctrl+alt+shift+cmd+f19", "command": "copi.bridge.dispatch", "args": {"target": "other", "chord": 3}},
          {"key": "ctrl+alt+shift+cmd+f19", "command": "copi.bridge.dispatch", "args": {"target": "simpleEditor", "chord": 3}, "when": "textInputFocus && editorSimpleInput"},
          {"key": "ctrl+alt+shift+cmd+f19", "command": "copi.bridge.dispatch", "args": {"target": "editor", "chord": 3}, "when": "editorTextFocus && !editorSimpleInput"},
          {"key": "ctrl+alt+shift+cmd+f19", "command": "copi.bridge.dispatch", "args": {"target": "other", "chord": 3}, "when": "editorTextFocus && vim.active && vim.mode == 'CommandlineInProgress'"},
          {"key": "ctrl+alt+shift+cmd+f19", "command": "copi.bridge.dispatch", "args": {"target": "other", "chord": 3}, "when": "editorTextFocus && vim.active && vim.mode == 'SearchInProgressMode'"},
          {"key": "ctrl+alt+shift+cmd+f19", "command": "copi.bridge.dispatch", "args": {"target": "terminal", "chord": 3}, "when": "terminalFocus"}
        ]
      }
    }
    """#

    static let extensionJS = #"""
    'use strict';
    // Copi Bridge: lets Copi (a macOS clipboard-privacy app) copy and paste in this editor without the system
    // clipboard. It only talks to Copi's local socket; Copi checks that the connecting process is this editor.
    // When Copi intercepts Cmd+C/X/V here it presses one of four private chords (Ctrl+Alt+Shift+Cmd+F16...F19). The keybindings in
    // package.json turn that into 'copi.bridge.dispatch' with the place that has focus (editor, simple input such
    // as the commit message box, terminal or something else), so Copi talks to the window that got the key.
    const vscode = require('vscode');
    const net = require('net');
    const fs = require('fs');
    const os = require('os');
    const path = require('path');

    const PROTOCOL = __COPI_PROTOCOL__;
    const SOCKET_DIR = path.join(os.homedir(), 'Library', 'Application Support', 'Copi');
    const SOCKET_PATH = path.join(SOCKET_DIR, 'bridge.sock');
    let socket = null;
    let buffer = '';
    let retryTimer = null;
    let retryDelay = 250;
    let stableTimer = null;
    let disposed = false;
    let watcher = null;
    // The key press Copi made that this window answered. Requests are only served right after it, for that key:
    // something else listening on Copi's socket path can't make this window answer, so it can't read or write here.
    let lastDispatch = { chord: -1, at: 0 };

    function activate(context) {
      if (process.platform !== 'darwin') {
        return;
      }
      context.subscriptions.push(vscode.commands.registerCommand('copi.bridge.dispatch', args => {
        // Only the window that has keyboard focus can be where Copi pressed its key
        if (!vscode.window.state.focused) {
          return;
        }
        const target = args && typeof args.target === 'string' ? args.target : 'other';
        const chord = args && typeof args.chord === 'number' ? args.chord : -1;
        lastDispatch = { chord, at: Date.now() };
        send({ type: 'dispatch', target, chord, remote: vscode.env.remoteName || null });
      }));
      try {
        watcher = fs.watch(SOCKET_DIR, (event, file) => {
          if (file === 'bridge.sock' && !socket) {
            reconnectSoon(0);
          }
        });
      } catch (error) {
        watcher = null;
      }
      connect();
      context.subscriptions.push({
        dispose() {
          disposed = true;
          clearTimeout(retryTimer);
          if (watcher) {
            watcher.close();
          }
          if (socket) {
            socket.destroy();
          }
        }
      });
    }

    function deactivate() {}

    function reconnectSoon(delay) {
      clearTimeout(retryTimer);
      if (!disposed) {
        retryTimer = setTimeout(connect, delay);
      }
    }

    function connect() {
      if (disposed || socket) {
        return;
      }
      const current = net.createConnection({ path: SOCKET_PATH });
      socket = current;
      current.setEncoding('utf8');
      current.on('connect', () => {
        // Back off again only after the connection has stayed open for a while (Copi may be refusing it)
        clearTimeout(stableTimer);
        stableTimer = setTimeout(() => { retryDelay = 250; }, 2000);
        send({ type: 'hello', protocol: PROTOCOL, appName: vscode.env.appName, version: vscode.version, remote: vscode.env.remoteName || null });
      });
      current.on('data', chunk => {
        buffer += chunk;
        let index;
        while ((index = buffer.indexOf('\n')) >= 0) {
          const line = buffer.slice(0, index);
          buffer = buffer.slice(index + 1);
          if (line) {
            handle(line);
          }
        }
      });
      current.on('error', () => {});
      current.on('close', () => {
        if (socket === current) {
          socket = null;
          buffer = '';
        }
        clearTimeout(stableTimer);
        reconnectSoon(retryDelay);
        retryDelay = Math.min(retryDelay * 2, 5000);
      });
    }

    function send(message) {
      if (socket && !socket.destroyed && socket.writable) {
        socket.write(JSON.stringify(message) + '\n');
      }
    }

    async function handle(line) {
      let message;
      try {
        message = JSON.parse(line);
      } catch (error) {
        return;
      }
      const reply = body => send(Object.assign({ id: message.id }, body));
      // Ignore requests that arrive too late (Copi has given up waiting by then)
      if (typeof message.deadline === 'number' && Date.now() > message.deadline) {
        reply({ ok: false, error: 'late' });
        return;
      }
      if (message.chord !== lastDispatch.chord || Date.now() - lastDispatch.at > 2000) {
        reply({ ok: false, error: 'not requested' });
        return;
      }
      try {
        switch (message.cmd) {
          case 'copy':
            reply(copy());
            break;
          case 'cut':
            reply(await cut(message.token));
            break;
          case 'paste':
            reply(await paste(message));
            break;
          case 'terminalProcess':
            reply(await terminalProcess(message));
            break;
          case 'terminalSelection':
            reply(terminalSelection());
            break;
          case 'terminalSend':
            reply(terminalSend(message));
            break;
          default:
            reply({ ok: false, error: 'unknown command' });
        }
      } catch (error) {
        reply({ ok: false, error: String((error && error.message) || error) });
      }
    }

    // The same text, multi-cursor pieces and "whole line" flag the editor's own Copy produces
    // (viewModel.getPlainTextToCopy + clipboardUtils.getDataToCopy).
    function copyData(editor) {
      const document = editor.document;
      const emptySelectionClipboard = vscode.workspace.getConfiguration('editor', document).get('emptySelectionClipboard', true);
      if (editor.selection.isEmpty && !emptySelectionClipboard) {
        return null;
      }
      const eol = document.eol === vscode.EndOfLine.CRLF ? '\r\n' : '\n';
      const ranges = editor.selections.map(selection => new vscode.Range(selection.start, selection.end))
        .sort((a, b) => a.start.compareTo(b.start) || a.end.compareTo(b.end));
      const hasEmpty = ranges.some(range => range.isEmpty);
      const hasNonEmpty = ranges.some(range => !range.isEmpty);
      if (!hasNonEmpty && !emptySelectionClipboard) {
        return null;
      }
      const pieces = [];
      if (hasEmpty && emptySelectionClipboard) {
        let previousLine = -1;
        for (const range of ranges) {
          const line = range.start.line;
          if (range.isEmpty) {
            if (line !== previousLine) {
              pieces.push(document.lineAt(line).text + eol);
            }
          } else {
            pieces.push(document.getText(range));
          }
          previousLine = line;
        }
      } else {
        for (const range of ranges) {
          if (!range.isEmpty) {
            pieces.push(document.getText(range));
          }
        }
      }
      return {
        text: pieces.length === 1 ? pieces[0] : pieces.join(eol),
        multicursorText: pieces.length > 1 ? pieces : null,
        isFromEmptySelection: emptySelectionClipboard && editor.selections.length === 1 && editor.selections[0].isEmpty
      };
    }

    // The last copy, so a following cut deletes exactly what was copied (and nothing if the editor changed since)
    let lastCopy = null;

    function selectionsKey(editor) {
      return editor.selections.map(s => [s.anchor.line, s.anchor.character, s.active.line, s.active.character].join(',')).join(';');
    }

    function copy() {
      if (!vscode.window.state.focused) {
        return { ok: false, error: 'unfocused' };
      }
      const editor = vscode.window.activeTextEditor;
      if (!editor) {
        return { ok: false, error: 'no editor' };
      }
      const data = copyData(editor);
      if (!data) {
        lastCopy = null;
        return { ok: true, text: '' };
      }
      const token = String(Date.now()) + ':' + Math.random().toString(36).slice(2);
      lastCopy = { token, uri: editor.document.uri.toString(), version: editor.document.version, selections: selectionsKey(editor) };
      return Object.assign({ ok: true, token }, data);
    }

    // The editor's own cut deletes exactly what its copy took (whole lines for an empty selection); its clipboard
    // write happens in the browser's cut event, which this command doesn't trigger
    async function cut(token) {
      if (!vscode.window.state.focused) {
        lastCopy = null;
        return { ok: false, error: 'unfocused' };
      }
      const editor = vscode.window.activeTextEditor;
      const copied = lastCopy;
      lastCopy = null;
      if (!editor || !copied || copied.token !== token || editor.document.uri.toString() !== copied.uri
          || editor.document.version !== copied.version || selectionsKey(editor) !== copied.selections) {
        return { ok: false, error: 'changed' };
      }
      const version = editor.document.version;
      await vscode.commands.executeCommand('cut');
      return { ok: true, cut: editor.document.version !== version };
    }

    // The editor's own paste handler (the same one Cmd+V uses), fed with Copi's text instead of the clipboard:
    // no auto-closing brackets or auto-indent per keystroke, multi-cursor distribution as usual.
    async function paste(message) {
      // Only the window that answered Copi's key press, while it still has focus
      if (!vscode.window.state.focused) {
        return { ok: false, error: 'unfocused' };
      }
      const editor = vscode.window.activeTextEditor;
      const emptySelectionClipboard = editor
        ? vscode.workspace.getConfiguration('editor', editor.document).get('emptySelectionClipboard', true)
        : true;
      // Any document changing means the paste landed (the focused editor may be a peek or diff editor rather than the
      // active one). Model changes reach the extension host before the command's result does.
      let changed = false;
      const listener = vscode.workspace.onDidChangeTextDocument(event => {
        if (event.contentChanges.length > 0) {
          changed = true;
        }
      });
      try {
        await vscode.commands.executeCommand('paste', {
          text: String(message.text),
          pasteOnNewLine: emptySelectionClipboard && message.isFromEmptySelection === true,
          multicursorText: Array.isArray(message.multicursorText) ? message.multicursorText : null,
          mode: null
        });
      } finally {
        listener.dispose();
      }
      if (message.target === 'editor') {
        // Unchanged: a read-only editor, where the editor's own paste does nothing either
        return { ok: true, result: changed ? 'inserted' : 'unchanged' };
      }
      // Simple inputs (commit message box, chat input) aren't visible to the API: the paste was dispatched
      return { ok: true, result: 'dispatched' };
    }

    // The terminal Copi checked (terminalProcess): terminalSend only writes to that one, in case another terminal became
    // active in between (a click, a task revealing its terminal, another extension)
    let pinnedTerminal = null;

    async function terminalProcess(message) {
      pinnedTerminal = null;
      const terminal = vscode.window.activeTerminal;
      if (!terminal) {
        return { ok: false, error: 'no terminal' };
      }
      const pid = await terminal.processId;
      if (!pid) {
        return { ok: false, error: 'no process' };
      }
      pinnedTerminal = { terminal, pid, chord: message.chord };
      return { ok: true, pid, remote: vscode.env.remoteName || null };
    }

    // Not a stable API yet: present on the Terminal object since VS Code 1.81
    function terminalSelection() {
      if (!vscode.window.state.focused) {
        return { ok: false, error: 'unfocused' };
      }
      const terminal = vscode.window.activeTerminal;
      if (!terminal || !('selection' in terminal)) {
        return { ok: false, error: 'unsupported' };
      }
      const selection = terminal.selection;
      return typeof selection === 'string' ? { ok: true, text: selection } : { ok: true, text: '' };
    }

    function terminalSend(message) {
      const pinned = pinnedTerminal;
      pinnedTerminal = null;
      if (!vscode.window.state.focused) {
        return { ok: false, error: 'unfocused' };
      }
      if (!pinned || pinned.chord !== message.chord || vscode.window.activeTerminal !== pinned.terminal || pinned.pid !== message.pid) {
        return { ok: false, error: 'changed' };
      }
      pinned.terminal.sendText(String(message.text), false);
      return { ok: true };
    }

    module.exports = { activate, deactivate };
    """#

    static let manifest = #"""
    <?xml version="1.0" encoding="utf-8"?>
    <PackageManifest Version="2.0.0" xmlns="http://schemas.microsoft.com/developer/vsx-schema/2011" xmlns:d="http://schemas.microsoft.com/developer/vsx-schema-design/2011">
      <Metadata>
        <Identity Language="en-US" Id="copi-bridge" Version="1.2.1" Publisher="copi" />
        <DisplayName>Copi Bridge</DisplayName>
        <Description xml:space="preserve">Lets Copi copy and paste in this editor without the system clipboard.</Description>
        <Categories>Other</Categories>
        <Properties>
          <Property Id="Microsoft.VisualStudio.Code.Engine" Value="^1.47.0" />
          <Property Id="Microsoft.VisualStudio.Code.ExtensionKind" Value="ui" />
        </Properties>
      </Metadata>
      <Installation>
        <InstallationTarget Id="Microsoft.VisualStudio.Code" />
      </Installation>
      <Dependencies />
      <Assets>
        <Asset Type="Microsoft.VisualStudio.Code.Manifest" Path="extension/package.json" Addressable="true" />
      </Assets>
    </PackageManifest>
    """#

    static let contentTypes = #"""
    <?xml version="1.0" encoding="utf-8"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
      <Default Extension=".json" ContentType="application/json" />
      <Default Extension=".js" ContentType="application/javascript" />
      <Default Extension=".vsixmanifest" ContentType="text/xml" />
    </Types>
    """#

    // 在临时目录里打包成 .vsix（就是一个 zip），返回它的路径；用完由调用方删掉整个目录
    static func buildPackage() -> URL? {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("copi-bridge-\(UUID().uuidString)", isDirectory: true)
        let extensionFolder = root.appendingPathComponent("extension", isDirectory: true)
        do {
            try fileManager.createDirectory(at: extensionFolder, withIntermediateDirectories: true)
            try contentTypes.write(to: root.appendingPathComponent("[Content_Types].xml"), atomically: true, encoding: .utf8)
            try manifest.write(to: root.appendingPathComponent("extension.vsixmanifest"), atomically: true, encoding: .utf8)
            try packageJSON.write(to: extensionFolder.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
            try extensionJS.replacingOccurrences(of: "__COPI_PROTOCOL__", with: String(protocolVersion))
                .write(to: extensionFolder.appendingPathComponent("extension.js"), atomically: true, encoding: .utf8)
        } catch {
            try? fileManager.removeItem(at: root)
            return nil
        }
        let vsix = root.appendingPathComponent("copi-bridge.vsix")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = root
        zip.arguments = ["-q", "-X", "-r", vsix.path, "[Content_Types].xml", "extension.vsixmanifest", "extension"]
        zip.standardOutput = FileHandle.nullDevice
        zip.standardError = FileHandle.nullDevice
        do {
            try zip.run()
        } catch {
            try? fileManager.removeItem(at: root)
            return nil
        }
        zip.waitUntilExit()
        guard zip.terminationStatus == 0 else {
            try? fileManager.removeItem(at: root)
            return nil
        }
        return vsix
    }
}
