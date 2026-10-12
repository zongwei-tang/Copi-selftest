//
//  HelperProcess.swift
//  Copi
//
//  运行外部的命令行程序（WezTerm 的 wezterm cli、tmux、VS Code 系编辑器的命令行工具）。它们的程序文件由别的程序决定
//  （正在运行的终端、tmux 客户端、编辑器的安装位置），可能被换掉。用 Foundation 的 Process 启动时，macOS 会把子进程的权限
//  归属算在 Copi 头上：它（以及它再启动的进程）就有了 Copi 的辅助功能、自动化权限，可以读任何 App 的输入框。
//  所以改用 posix_spawn，并声明子进程自己负责（responsibility_spawnattrs_setdisclaim，Chromium、iTerm2 也这样做），
//  子进程只有它自己的权限。这个接口找不到时不运行。子进程只继承标准输入、输出（其他文件描述符一律关掉），标准错误丢弃
//

import Foundation

enum HelperProcess {
    enum Result {
        // 正常退出（退出码 0），标准输出的内容
        case output(Data)
        // 没能运行、或者退出码不是 0
        case failed
        // 超时，结束了它
        case timedOut
    }

    // 任意线程（会等子进程结束，不要在主线程上用）
    static func run(_ executable: String, _ arguments: [String], environment: [String: String], input: Data? = nil,
                    timeout: TimeInterval) -> Result {
        guard let disclaim = disclaimFunction else {
            return .failed
        }
        var attributes: posix_spawnattr_t? = nil
        guard posix_spawnattr_init(&attributes) == 0 else {
            return .failed
        }
        defer { posix_spawnattr_destroy(&attributes) }
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        var defaultSignals = sigset_t()
        sigfillset(&defaultSignals)
        // 子进程自成一个进程组：超时时连它启动的进程一起结束
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
                                                          | POSIX_SPAWN_SETPGROUP)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0,
              posix_spawnattr_setsigmask(&attributes, &noSignals) == 0,
              posix_spawnattr_setsigdefault(&attributes, &defaultSignals) == 0,
              disclaim(&attributes, 1) == 0 else {
            return .failed
        }

        var outputPipe: [Int32] = [-1, -1]
        var inputPipe: [Int32] = [-1, -1]
        guard pipe(&outputPipe) == 0 else {
            return .failed
        }
        if input != nil, pipe(&inputPipe) != 0 {
            close(outputPipe[0])
            close(outputPipe[1])
            return .failed
        }
        // 别的线程同时启动的进程不能继承这几个管道（拿着写入端的进程不退出，这边就读不到结尾）。子进程的标准输入、输出是 dup2 出来的新描述符，不受影响
        for fd in outputPipe + inputPipe where fd >= 0 {
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        }
        var actions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        if input != nil {
            posix_spawn_file_actions_adddup2(&actions, inputPipe[0], STDIN_FILENO)
        } else {
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        }
        posix_spawn_file_actions_adddup2(&actions, outputPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)

        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        // 父进程这边不用的那一头
        close(outputPipe[1])
        if input != nil {
            close(inputPipe[0])
        }
        guard spawned == 0 else {
            close(outputPipe[0])
            if input != nil {
                close(inputPipe[1])
            }
            return .failed
        }

        // 超时就结束它（先 SIGTERM，0.2 秒后还在就 SIGKILL，连同它的进程组）。结束之前确认它还没退出：退出之后、被回收之前
        // 进程号不会给别的进程，所以下面先等它退出（不回收）、记下来，再回收
        let state = State()
        let childPID = pid
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
            state.terminate(childPID, SIGTERM)
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout + 0.2) {
            state.terminate(childPID, SIGKILL)
        }

        // 读写都不阻塞，到期限就不再等：子进程不理会信号、或者它启动的进程还拿着管道时，run() 照样按时返回。
        // 用开机以来的时间（和上面的计时器一样，睡眠时不走），不受改系统时间、睡眠的影响
        func uptime() -> TimeInterval {
            ProcessInfo.processInfo.systemUptime
        }
        let deadline = uptime() + timeout + 0.5
        var inputFD: Int32 = input != nil ? inputPipe[1] : -1
        var outputFD = outputPipe[0]
        if inputFD >= 0 {
            // 子进程出错提前退出时写不进去：不能收到 SIGPIPE
            _ = fcntl(inputFD, F_SETNOSIGPIPE, 1)
            _ = fcntl(inputFD, F_SETFL, fcntl(inputFD, F_GETFL) | O_NONBLOCK)
        }
        _ = fcntl(outputFD, F_SETFL, fcntl(outputFD, F_GETFL) | O_NONBLOCK)
        let bytes = [UInt8](input ?? Data())
        var offset = 0
        var output = Data()
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        if bytes.isEmpty, inputFD >= 0 {
            close(inputFD)
            inputFD = -1
        }
        // 子进程已经退出、它启动的进程却还拿着管道时，最多再读 0.1 秒
        var exitedAt: TimeInterval?
        while outputFD >= 0 || inputFD >= 0 {
            if exitedAt == nil {
                var probe = siginfo_t()
                if waitid(P_PID, id_t(pid), &probe, WEXITED | WNOWAIT | WNOHANG) == 0, probe.si_signo == SIGCHLD {
                    state.lock.lock()
                    state.exited = true
                    state.lock.unlock()
                    exitedAt = uptime()
                }
            }
            let remaining = min(deadline - uptime(), exitedAt.map { 0.1 - (uptime() - $0) } ?? .infinity)
            guard remaining > 0 else {
                break
            }
            var descriptors: [pollfd] = []
            if outputFD >= 0 {
                descriptors.append(pollfd(fd: outputFD, events: Int16(POLLIN), revents: 0))
            }
            if inputFD >= 0 {
                descriptors.append(pollfd(fd: inputFD, events: Int16(POLLOUT), revents: 0))
            }
            // 最多等 50 毫秒就回头看一眼子进程退出了没有
            let ready = poll(&descriptors, nfds_t(descriptors.count), Int32(min(remaining, 0.05) * 1000) + 1)
            if ready < 0 {
                if errno == EINTR {
                    continue
                }
                break
            }
            for descriptor in descriptors where descriptor.revents != 0 {
                if descriptor.fd == outputFD {
                    let count = chunk.withUnsafeMutableBytes { raw in
                        Darwin.read(outputFD, raw.baseAddress!, raw.count)
                    }
                    if count > 0 {
                        output.append(contentsOf: chunk.prefix(count))
                    } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
                        close(outputFD)
                        outputFD = -1
                    }
                } else if descriptor.fd == inputFD {
                    let written = bytes.withUnsafeBytes { raw in
                        Darwin.write(inputFD, raw.baseAddress!.advanced(by: offset), bytes.count - offset)
                    }
                    if written > 0 {
                        offset += written
                    }
                    if offset >= bytes.count || (written < 0 && errno != EAGAIN && errno != EINTR) {
                        close(inputFD)
                        inputFD = -1
                    }
                }
            }
        }
        if inputFD >= 0 {
            close(inputFD)
        }
        if outputFD >= 0 {
            // 管道里已经有的先读完（不等新的）
            while true {
                let count = chunk.withUnsafeMutableBytes { raw in
                    Darwin.read(outputFD, raw.baseAddress!, raw.count)
                }
                guard count > 0 else {
                    break
                }
                output.append(contentsOf: chunk.prefix(count))
            }
            close(outputFD)
        }

        // 等它退出（不回收）→ 记下 → 回收。到这里还没退出的（超过期限）已经收到 SIGKILL；最多再等 1 秒（卡在不可中断的等待里时
        // SIGKILL 也要等它出来才生效），还没退出就当作超时，留给后台去回收
        var exited = false
        while !exited {
            var info = siginfo_t()
            if waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT | WNOHANG) == 0, info.si_signo == SIGCHLD {
                exited = true
            } else if uptime() > deadline + 1 {
                break
            } else {
                usleep(10_000)
            }
        }
        guard exited else {
            state.lock.lock()
            state.timedOut = true
            state.lock.unlock()
            DispatchQueue.global(qos: .utility).async {
                var status: Int32 = 0
                while waitpid(childPID, &status, 0) < 0, errno == EINTR {}
            }
            return .timedOut
        }
        state.lock.lock()
        state.exited = true
        let timedOut = state.timedOut
        state.lock.unlock()
        var status: Int32 = 0
        var reaped: pid_t
        repeat {
            reaped = waitpid(pid, &status, 0)
        } while reaped < 0 && errno == EINTR
        guard reaped == pid, !timedOut else {
            return timedOut ? .timedOut : .failed
        }
        // WIFEXITED && WEXITSTATUS == 0
        guard status & 0x7f == 0, (status >> 8) & 0xff == 0 else {
            return .failed
        }
        return .output(output)
    }

    private final class State {
        let lock = NSLock()
        var exited = false
        var timedOut = false

        // 还没退出就结束它和它的进程组（它可能把自己挪到了别的进程组里：两个都发）
        func terminate(_ pid: pid_t, _ signal: Int32) {
            lock.lock()
            if !exited {
                timedOut = true
                kill(pid, signal)
                killpg(pid, signal)
            }
            lock.unlock()
        }
    }

    private typealias Disclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32

    // libsystem 的私有接口（macOS 10.14 起）：子进程的权限归属不算在 Copi 头上
    private static let disclaimFunction: Disclaim? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim") else {
            return nil
        }
        return unsafeBitCast(symbol, to: Disclaim.self)
    }()
}
