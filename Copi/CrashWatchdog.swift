//
//  CrashWatchdog.swift
//  Copi
//
//  Copi 崩溃、被强制退出、被别的程序杀掉之后自动重新打开：Copi 启动时用自己的可执行文件起一个很小的看门进程（不显示界面、
//  只用 Foundation），两者之间连一根管道。Copi 正常退出（菜单里的退出、注销、关机、更新）前往管道里写一个 "q"；
//  管道的另一头关了却没收到 "q"——Copi 是异常结束的——看门进程就重新打开 Copi，然后自己退出（新的 Copi 会再起一个）。
//  2 分钟内最多重开 3 次，免得一启动就崩溃时没完没了。Copi 还每 2 秒往管道里写一个心跳字节：卡住、被暂停（SIGSTOP）时
//  看门进程也能发现，结束它再重新打开。
//  没有用 launchd 的 KeepAlive：那要把 Copi 本身注册成登录项代理，从访达打开时要处理两个副本的交接、每次更新后要重新注册，
//  这些在没有真机测试的情况下风险太大（出错时可能一个 Copi 都不运行）。开机启动仍然用 LaunchAtLogin。
//

import Foundation
import Defaults

enum CrashWatchdog {
    static let argument = "--copi-watchdog"
    // 看门进程重新打开 Copi 时带上最近几次重开的时间（秒，逗号分隔），新的 Copi 再交给它的看门进程：2 分钟内重开过 3 次就不再重开。
    // 放在启动参数里而不是偏好设置里：偏好设置别的程序能改（写进几个时间，看门进程就不再重开 Copi）
    static let relaunchesArgument = "--copi-relaunches"
    // 看门进程留给下一次启动的 Copi 的话：它结束了卡住（或被暂停）的 Copi；它因为重开太多次放弃了
    static let killedHungKey = "watchdogKilledHungCopi"
    static let gaveUpKey = "watchdogGaveUp"

    // 主线程：通往看门进程的管道的写入端
    private static var pipe: FileHandle?
    private static var process: Process?
    // 主线程：每 2 秒往管道里写一个心跳字节，看门进程据此发现 Copi 卡住了
    private static var heartbeat: Timer?
    // 主线程：最近一次收到看门进程的心跳（开机以来的秒数）。它被暂停（SIGSTOP）时收不到，换掉它
    private static var lastHelperBeat = ProcessInfo.processInfo.systemUptime
    private static var helperReader: DispatchSourceRead?
    // 主线程：心跳计时器上次跑的时间。Copi 自己的主线程卡了一阵（例如等用户回答系统的询问）之后，先读到积压的心跳再判断
    private static var lastTimerFire = ProcessInfo.processInfo.systemUptime
    // 主线程：pauseHangCheck 的嵌套层数
    private static var pauseDepth = 0
    // 最近重新起看门进程的时间（它一起来就没了的话不要没完没了地起）
    private static var restarts: [Date] = []

    // 主线程：按设置启动或停掉看门进程
    static func update() {
        if Defaults[.restartAfterCrash] {
            start()
        } else {
            stop()
        }
    }

    // 主线程：看门进程在不在（被别的程序退出时，要靠它重新打开 Copi）。不在就马上重新起一个
    static func ensureRunning() {
        guard Defaults[.restartAfterCrash] else {
            return
        }
        if let process, process.isRunning {
            return
        }
        try? pipe?.close()
        pipe = nil
        process = nil
        heartbeat?.invalidate()
        heartbeat = nil
        start()
    }

    private static func start() {
        #if DEBUG
        // 在 Xcode 里停止调试也是"被杀掉"，不要重新打开
        return
        #else
        guard pipe == nil, let executable = Bundle.main.executableURL, Bundle.main.bundlePath.hasSuffix(".app") else {
            return
        }
        // 这个 Copi 是看门进程重新打开的：带着之前的重开记录
        let arguments = CommandLine.arguments
        let history = arguments.firstIndex(of: relaunchesArgument).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil } ?? ""
        let channel = Pipe()
        // 看门进程往回写心跳
        let backChannel = Pipe()
        let watchdog = Process()
        watchdog.executableURL = executable
        watchdog.arguments = [argument, Bundle.main.bundlePath, history]
        watchdog.standardInput = channel
        watchdog.standardOutput = backChannel
        watchdog.standardError = FileHandle.nullDevice
        // 看门进程自己没了（被杀掉）：过两秒再起一个（Copi 正常退出、关掉设置时 stop() 已经清掉了记录，不再起）
        watchdog.terminationHandler = { finished in
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                guard process === finished else {
                    return
                }
                try? pipe?.close()
                pipe = nil
                process = nil
                heartbeat?.invalidate()
                heartbeat = nil
                restarts = restarts.filter { Date().timeIntervalSince($0) < 60 } + [Date()]
                if restarts.count <= 3 {
                    update()
                } else {
                    notifyCopiNotice("Copi's crash-restart helper keeps stopping, so Copi won't reopen by itself if it stops now. Quit and reopen Copi to try again.")
                }
            }
        }
        guard (try? watchdog.run()) != nil else {
            return
        }
        try? backChannel.fileHandleForWriting.close()
        let readFD = backChannel.fileHandleForReading.fileDescriptor
        _ = fcntl(readFD, F_SETFL, fcntl(readFD, F_GETFL) | O_NONBLOCK)
        lastHelperBeat = ProcessInfo.processInfo.systemUptime
        let reader = DispatchSource.makeReadSource(fileDescriptor: readFD, queue: .main)
        reader.setEventHandler {
            var buffer = [UInt8](repeating: 0, count: 64)
            let count = buffer.withUnsafeMutableBytes { read(readFD, $0.baseAddress!, $0.count) }
            if count > 0 {
                lastHelperBeat = ProcessInfo.processInfo.systemUptime
            } else if count == 0 {
                // 看门进程没了：terminationHandler 会处理
                reader.cancel()
            }
        }
        reader.setCancelHandler {
            try? backChannel.fileHandleForReading.close()
        }
        helperReader?.cancel()
        helperReader = reader
        reader.resume()
        let writer = channel.fileHandleForWriting
        // 看门进程先没了时写 "q" 不能让 Copi 收到 SIGPIPE 被杀掉；它被暂停、不读管道时，写满了也不能把主线程卡住
        _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
        _ = fcntl(writer.fileDescriptor, F_SETFL, fcntl(writer.fileDescriptor, F_GETFL) | O_NONBLOCK)
        pipe = writer
        process = watchdog
        let timer = Timer(timeInterval: 2, repeats: true) { _ in
            guard let pipe else {
                return
            }
            _ = send(UInt8(ascii: "h"), to: pipe)
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastTimerFire > 5 {
                lastHelperBeat = now
            }
            lastTimerFire = now
            // 看门进程 15 秒（不算睡眠）没回心跳：它被暂停了或者卡住了，结束它，terminationHandler 会再起一个
            if now - lastHelperBeat > 15, let process, process.isRunning {
                lastHelperBeat = ProcessInfo.processInfo.systemUptime
                kill(process.processIdentifier, SIGKILL)
            }
        }
        timer.tolerance = 0.5
        // 加到 common modes：菜单、面板、模态窗口开着时也照常跳
        RunLoop.main.add(timer, forMode: .common)
        heartbeat = timer
        #endif
    }

    // 主线程：正常退出前、关掉这个设置时调用：告诉看门进程不要重新打开 Copi
    static func stop() {
        heartbeat?.invalidate()
        heartbeat = nil
        helperReader?.cancel()
        helperReader = nil
        guard let pipe else {
            return
        }
        // 写不进去（看门进程先没了，或者被暂停、管道满了）也不等：最坏是它之后把 Copi 多打开一次
        _ = send(UInt8(ascii: "q"), to: pipe)
        try? pipe.close()
        self.pipe = nil
        process = nil
    }

    // 主线程：接下来主线程可能长时间等着用户（读别的 App 的剪贴板内容时系统弹出的询问）：这不是卡死，看门进程暂停判断，
    // 直到 resumeHangCheck。可以嵌套
    static func pauseHangCheck() {
        pauseDepth += 1
        if pauseDepth == 1, let pipe {
            _ = send(UInt8(ascii: "p"), to: pipe)
        }
    }

    static func resumeHangCheck() {
        guard pauseDepth > 0 else {
            return
        }
        pauseDepth -= 1
        if pauseDepth == 0, let pipe {
            _ = send(UInt8(ascii: "r"), to: pipe)
        }
    }

    // 往管道里写一个字节（不阻塞）。FileHandle.write 写不进去时会抛 Objective-C 异常，用 write(2)
    private static func send(_ byte: UInt8, to pipe: FileHandle) -> Bool {
        var value = byte
        return write(pipe.fileDescriptor, &value, 1) == 1
    }

    // 看门进程的入口（还没有启动任何界面）：一直读到管道关上。收到过 "q" 就是正常退出，否则过一秒重新打开 Copi。
    // 20 秒（不算睡眠）收不到心跳：Copi 卡住了或者被暂停了（SIGSTOP），这时它还在、却什么都不做——结束它，照样重新打开。
    // history：之前几次重开的时间
    static func run(bundlePath: String, history: String) -> Never {
        // 父进程就是 Copi；它没了之后看门进程会被过继给别的进程，这时不能再按这个进程号去结束谁
        let copi = getppid()
        var clean = false
        var killedHung = false
        // Copi 在等用户回答系统的询问（见 pauseHangCheck），从什么时候开始：最多等 2 分钟
        var pausedAt: TimeInterval?
        // 往回写心跳（Copi 据此发现看门进程被暂停了）；写不进去（Copi 卡住了、没在读）也不等
        _ = fcntl(STDOUT_FILENO, F_SETFL, fcntl(STDOUT_FILENO, F_GETFL) | O_NONBLOCK)
        signal(SIGPIPE, SIG_IGN)
        var lastBeatSent: TimeInterval = 0
        var lastBeat = ProcessInfo.processInfo.systemUptime
        var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        while true {
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastBeatSent >= 2 {
                var beat = UInt8(ascii: "b")
                _ = write(STDOUT_FILENO, &beat, 1)
                lastBeatSent = now
            }
            let ready = poll(&descriptor, 1, 2000)
            if ready < 0 {
                if errno == EINTR {
                    continue
                }
                break
            }
            if ready == 0 {
                let uptime = ProcessInfo.processInfo.systemUptime
                let paused = pausedAt.map { uptime - $0 < 120 } ?? false
                if !clean, !killedHung, !paused, uptime - max(lastBeat, pausedAt ?? 0) > 20, getppid() == copi {
                    killedHung = true
                    kill(copi, SIGKILL)
                }
                continue
            }
            var byte: UInt8 = 0
            let count = read(STDIN_FILENO, &byte, 1)
            if count == 1 {
                lastBeat = ProcessInfo.processInfo.systemUptime
                clean = clean || byte == UInt8(ascii: "q")
                if byte == UInt8(ascii: "p") {
                    pausedAt = lastBeat
                } else if byte == UInt8(ascii: "r") {
                    pausedAt = nil
                }
                continue
            }
            if count < 0, errno == EINTR {
                continue
            }
            break
        }
        guard !clean else {
            exit(0)
        }
        let defaults = UserDefaults.standard
        // 2 分钟内重开过 3 次就不再重开（一启动就崩溃的情形）：告诉用户
        let now = Date().timeIntervalSince1970
        let recent = history.split(separator: ",").compactMap { Double($0) }.filter { now - $0 >= 0 && now - $0 < 120 }
        guard recent.count < 3 else {
            defaults.set(true, forKey: gaveUpKey)
            defaults.synchronize()
            let notice = Process()
            notice.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            notice.arguments = ["-e", "display notification \"Copi stopped several times in a row, so it didn't reopen by itself. Until you open it again, ⌘C and ⌘V use the system clipboard.\" with title \"Copi\""]
            if (try? notice.run()) != nil {
                notice.waitUntilExit()
            }
            exit(0)
        }
        if killedHung {
            defaults.set(true, forKey: killedHungKey)
            defaults.synchronize()
        }
        Thread.sleep(forTimeInterval: 1)
        let opener = Process()
        opener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        // -g：在后台打开，不抢走用户正在用的 App 的焦点
        let updated = (recent + [now]).map { String(Int($0)) }.joined(separator: ",")
        opener.arguments = ["-g", bundlePath, "--args", relaunchesArgument, updated]
        if (try? opener.run()) != nil {
            opener.waitUntilExit()
        }
        exit(0)
    }
}
