//
//  TmuxPaste.swift
//  Copi
//
//  终端里前台是 tmux 时：把文字交给 tmux，用它自己的 paste-buffer 粘贴进当前的 pane。tmux 直接写进 pane 的终端
//  （不经过剪贴板、不产生按键事件，能看到按键的程序看不到），并且和真正的粘贴一样：pane 里的程序打开了 bracketed paste 模式
//  才加标记（tmux 自己就是这个程序的终端，知道得最准），换行变成回车。
//   - 用 tmux 客户端自己的程序文件和它连着的 socket（从它的启动参数 -S / -L、环境变量 TMUX_TMPDIR 推出来），版本对得上；
//   - 先问 tmux 这个客户端当前的 pane 和它的终端设备（list-clients），再按 pane 里的前台程序决定能不能粘贴、送什么，
//     和别的终端一样（shell 提示符前、Vim 里单行……）；
//   - 文字只经过管道：load-buffer - 从标准输入读进一个随机名字的缓冲区，紧接着 paste-buffer -d 粘贴并删掉它。文字不出现在任何
//     进程的启动参数里，也不出现在 tmux 记录的命令里（show-messages）。设了会在这期间运行的钩子时不用这条路。
//  需要 tmux 3.1 以上（source-file 从标准输入读）。ssh 到别的机器上的 tmux 看不到，照旧拒绝。
//

import Foundation

enum TmuxPaste {
    enum Outcome {
        case sent
        // 肯定没粘贴（tmux 不对劲、连不上……）
        case failed
        // 交给 tmux 之后没等到它回话：可能已经（或稍后）粘贴了
        case unsure
        // 按规则不能粘贴（pane 里运行着把字母当命令的程序……）
        case refused(UnavailableReason)
        // 用户在这期间接着操作了
        case stale
    }

    // 前台进程组是不是一个 tmux 客户端
    static func isClient(_ group: [ForegroundProcess]) -> Bool {
        !group.isEmpty && group.allSatisfy { $0.name == "tmux" }
    }

    // 控制模式的 tmux 客户端（-C；iTerm2 的 tmux 整合用 -CC）：它从终端读进来的是 tmux 的命令，不是给 pane 的输入；iTerm2 的整合
    // 把粘贴、键入变成 send-keys 之类的命令送给 tmux（tmux 把执行过的命令连同参数记进消息记录）。读不到启动参数时也算（看不出来）
    static func isControlModeClient(_ process: ForegroundProcess) -> Bool {
        guard process.name == "tmux" else {
            return false
        }
        guard let arguments = processArguments(pid: process.pid) else {
            return true
        }
        return globalOptions(arguments).flags.contains("C")
    }

    // Terminal、iTerm2 开着好几个标签页时：只有一个标签页前台是 tmux 客户端，窗口标题里写着 tmux、又没写别的标签页前台的程序，
    // 焦点就在它那里（和认 Neovim 的规则一样，见 NvimPaste.candidates）
    static func focusedClient(for target: FocusedTarget, groups: [[ForegroundProcess]]?) -> ForegroundProcess? {
        guard let groups, let bundleID = target.bundleIdentifier, jobTitleTerminalBundleIDs.contains(bundleID),
              let title = target.focusedWindowTitle else {
            return nil
        }
        let clients = groups.filter(isClient)
        guard clients.count == 1 else {
            return nil
        }
        let words = titleProgramWords(title, bundleID: bundleID)
        let others = Set(groups.filter { !isClient($0) }.flatMap { $0.map(\.name) })
        guard words.contains("tmux"), !words.contains(where: others.contains) else {
            return nil
        }
        return clients[0].first
    }

    // 看不出焦点在终端的哪个标签页时：所有标签页的前台进程组只有一个、并且是 tmux 客户端，才知道粘贴给谁
    static func soleClient(in groups: [[ForegroundProcess]]?) -> ForegroundProcess? {
        guard let groups, groups.count == 1, isClient(groups[0]) else {
            return nil
        }
        return groups[0].first
    }

    // 主线程：在后台交给 tmux，结果用通知告诉用户
    static func pasteInBackground(_ text: String, client: ForegroundProcess, target: FocusedTarget, keyTime: Date) {
        DispatchQueue.global(qos: .userInitiated).async {
            report(paste(text, client: client, keyTime: keyTime), text: text, target: target, keyTime: keyTime)
        }
    }

    // 任意线程：在主线程上告诉用户结果；没能粘贴时照常拒绝（或者允许剪贴板回退时退回剪贴板）
    static func report(_ outcome: Outcome, text: String, target: FocusedTarget, keyTime: Date) {
        DispatchQueue.main.async {
            switch outcome {
            case .sent:
                notifyProtected("Pasted safely")
            case .stale:
                notifyCopiNotice("Copi didn't paste into \(RefusedApp(target: target).name) because you kept typing or clicked elsewhere. Press ⌘V again.")
            case .refused(let reason):
                refuseOrFallBack(reason, text: text, target: target, keyTime: keyTime)
            case .failed:
                refuseOrFallBack(.modalProgram("tmux"), text: text, target: target, keyTime: keyTime)
            case .unsure:
                // 可能已经粘贴了：不能再退回别的方式粘贴一遍
                notifyCopiNotice("Copi isn't sure the paste reached \(RefusedApp(target: target).name). Check the terminal before pasting again.")
            }
        }
    }

    // 后台线程：client 是终端里拿着焦点的那个标签页前台的 tmux 客户端
    static func paste(_ text: String, client: ForegroundProcess, keyTime: Date) -> Outcome {
        // 控制模式的客户端（iTerm2 的 tmux 整合、tmux -C）：终端里显示的不是它"当前的 pane"，不往那里粘贴
        guard !isControlModeClient(client) else {
            return .refused(.modalProgram("tmux"))
        }
        guard let binary = processExecutablePath(pid: client.pid), let socket = socketPath(ofClient: client.pid),
              let version = version(of: binary), !version.lexicographicallyPrecedes([3, 1]) else {
            return .failed
        }
        // 这个客户端当前的 pane：编号、终端设备、是不是在复制模式里（这时粘贴会落到程序里，不是用户以为的地方）、是不是关了输入；
        // 客户端是不是只读的（attach -r：它自己的粘贴到不了 pane）；pane 里的程序有没有打开 bracketed paste 模式（tmux 3.7 起才有，
        // 更早的版本是空的）
        guard case .output(let output) = run(binary, ["-S", socket, "list-clients", "-F",
                                                       "#{client_pid}\t#{pane_id}\t#{pane_tty}\t#{pane_in_mode}\t#{pane_input_off}\t#{client_readonly}\t#{bracket_paste_flag}"]),
              let row = output.split(separator: "\n").map({ $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) })
                .first(where: { $0.count == 7 && $0[0] == String(client.pid) }),
              row[1].hasPrefix("%"), row[2].hasPrefix("/dev/") else {
            return .failed
        }
        guard row[3] == "0", row[4] == "0", row[5] != "1", let group = foregroundGroup(ofTerminalDevice: row[2]) else {
            return .refused(.modalProgram("tmux"))
        }
        // 套着的 tmux（pane 里又开了一个）：不往里送
        if isClient(group) {
            return .refused(.modalProgram("tmux"))
        }
        // pane 里前台是 Neovim：通过它自己的 RPC 接口粘贴（见 NvimPaste），不经过 tmux 的缓冲区。找不到唯一的 server socket 时
        // 照旧按下面的规则经过 tmux 的缓冲区
        if group.contains(where: { $0.name == "nvim" }), group.allSatisfy({ $0.name == "nvim" || isAtPrompt($0) }) {
            let roots = group.filter { $0.name == "nvim" }.map(\.pid)
            let candidates = roots + NvimPaste.descendants(of: roots)
            if NvimPaste.server(in: candidates) != nil {
                return NvimPaste.paste(text, candidates: candidates, keyTime: keyTime)
            }
        }
        let bracketFlag = row[6]
        // pane 里运行的不是 shell（Vim 之类）：只有 tmux 确认它打开了 bracketed paste 模式时才送。在 tmux 里 Vim 不一定会打开
        // （TERM 是 tmux/screen，macOS 自带的 terminfo 里没有相应的能力），没打开时粘贴的字母就是命令
        if !group.allSatisfy(isAtPrompt), bracketFlag != "1" {
            return .refused(.modalProgram(programName(in: group)))
        }
        let body: String
        switch TerminalScript.pasteLikePayload(for: text, foreground: group) {
        case .success(let value):
            body = value
        case .failure(let reason):
            return .refused(reason)
        }
        // tmux 确定没打开 bracketed paste 模式时，多行文字的换行就是回车
        if bracketFlag == "0", body.unicodeScalars.contains(where: { $0 == "\n" || $0 == "\r" }) {
            return .refused(.multiLine)
        }
        // （tmux 3.7 以前的 paste-buffer 原样送出缓冲区：文字里夹着的 ESC[201~ 会提前结束 bracketed paste。pasteLikePayload 已经把
        // 换行、制表符以外的控制字符换成了可见的符号）
        let payload = body
        guard !payload.utf8.contains(0) else {
            return .refused(.noRoute)
        }
        // tmux 的钩子在存缓冲区、粘贴的命令之后当场运行（在删掉缓冲区之前），可以把缓冲区存到文件里、交给别的程序。
        // 设了这些钩子（多半是用户自己的配置，但也可能是别的程序加的）就不经过缓冲区
        let hooks = bufferHooks(binary: binary, socket: socket)
        guard let hooks else {
            return .failed
        }
        guard hooks.isEmpty else {
            return .refused(.tmuxHooks(hooks))
        }
        guard !userActedSince(keyTime) else {
            return .stale
        }
        let buffer = "copi-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        // 文字从标准输入读进缓冲区（load-buffer -），不放在命令里：tmux 3.2 起把执行过的每条命令连同参数记进服务器的消息记录，
        // 任何能连上它的程序都能用 show-messages 读出来，一直留到被后面的 1000 条命令挤掉。粘贴之后 -d 马上删掉缓冲区
        switch run(binary, ["-S", socket, "load-buffer", "-b", buffer, "-", ";", "paste-buffer", "-p", "-d", "-b", buffer, "-t", row[1]],
                   input: Data(payload.utf8)) {
        case .output:
            return .sent
        case .failed:
            // 读进来了却没粘贴成功时缓冲区还在：删掉（不存在时报错，不管它）
            _ = run(binary, ["-S", socket, "delete-buffer", "-b", buffer])
            return .failed
        case .timedOut:
            _ = run(binary, ["-S", socket, "delete-buffer", "-b", buffer])
            return .unsure
        }
    }

    // 会在 Copi 的缓冲区还在的时候运行的钩子：设了的名字；问不到时为 nil。这几个钩子都是会话一级的（-w、-p 设的也存在会话上），
    // load-buffer 不带目标，它的钩子在"最近活动的会话"上找，不一定是 pane 所在的那个：全局的和每个会话的都要看
    private static func bufferHooks(binary: String, socket: String) -> [String]? {
        let watched: Set<String> = ["after-load-buffer", "after-paste-buffer", "after-delete-buffer", "after-set-buffer", "command-error"]
        guard case .output(let sessions) = run(binary, ["-S", socket, "list-sessions", "-F", "#{session_id}"]) else {
            return nil
        }
        var arguments = ["-S", socket, "show-hooks", "-g"]
        for session in sessions.split(separator: "\n") where session.hasPrefix("$") {
            arguments += [";", "show-hooks", "-t", String(session)]
        }
        guard case .output(let output) = run(binary, arguments) else {
            return nil
        }
        // 每行 "名字[序号] 命令"；没设的只有名字
        var found: Set<String> = []
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, !parts[1].trimmingCharacters(in: .whitespaces).isEmpty else {
                continue
            }
            let name = String(parts[0].prefix { $0 != "[" })
            if watched.contains(name) {
                found.insert(name)
            }
        }
        return found.sorted()
    }

    // 客户端连着的 socket：启动参数里的 -S 路径，或者 -L 名字（默认 "default"）放在 TMUX_TMPDIR（默认 /tmp）下的 tmux-<uid> 里。
    // 只认当前用户自己的 socket
    private static func socketPath(ofClient pid: pid_t) -> String? {
        guard let arguments = processArguments(pid: pid) else {
            return nil
        }
        let options = globalOptions(arguments).values
        let label = options["L"] ?? "default"
        let path: String
        if let explicitPath = options["S"] {
            path = explicitPath
        } else {
            let base = processEnvironment(pid: pid)?["TMUX_TMPDIR"].flatMap { $0.isEmpty ? nil : $0 } ?? "/tmp"
            let resolved = URL(fileURLWithPath: base).resolvingSymlinksInPath().path
            path = "\(resolved)/tmux-\(getuid())/\(label)"
        }
        var info = stat()
        guard path.hasPrefix("/"), lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFSOCK, info.st_uid == getuid() else {
            return nil
        }
        return path
    }

    // tmux 客户端的全局选项（argv，在命令之前）：不带参数的选项字母（-CC 记两次），带参数的 -c -f -L -S -T 的值（取最后一次）
    private static func globalOptions(_ arguments: [String]) -> (flags: [Character], values: [Character: String]) {
        var flags: [Character] = []
        var values: [Character: String] = [:]
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            guard argument.hasPrefix("-"), argument.count > 1, argument != "--" else {
                break
            }
            let letters = Array(argument.dropFirst())
            var consumedNext = false
            for (position, letter) in letters.enumerated() {
                guard "cfLST".contains(letter) else {
                    flags.append(letter)
                    continue
                }
                // 带参数的选项：值是同一段里后面的字符，没有时是下一个参数
                let attached = String(letters[(position + 1)...])
                let value = attached.isEmpty ? (index + 1 < arguments.count ? arguments[index + 1] : nil) : attached
                consumedNext = attached.isEmpty
                values[letter] = value ?? values[letter]
                break
            }
            index += consumedNext ? 2 : 1
        }
        return (flags, values)
    }

    // "tmux 3.4"、"tmux 3.3a"、"tmux next-3.6" → [3, 4]
    private static func version(of binary: String) -> [Int]? {
        guard case .output(let output) = run(binary, ["-V"]),
              let range = output.range(of: #"(\d+)\.(\d+)"#, options: .regularExpression) else {
            return nil
        }
        return output[range].split(separator: ".").compactMap { Int($0) }
    }

    private enum RunResult {
        case output(String)
        case failed
        // 1.5 秒还没完，结束了它（tmux 被结束时退出码也是 0，要单独认出来）
        case timedOut
    }

    // 运行 tmux（干净的环境，不继承 TMUX 之类）。程序文件来自 tmux 客户端进程，可能被换掉：用 HelperProcess，不带着 Copi 的权限运行
    private static func run(_ binary: String, _ arguments: [String], input: Data? = nil) -> RunResult {
        switch HelperProcess.run(binary, arguments, environment: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "LANG": "en_US.UTF-8"],
                                 input: input, timeout: 1.5) {
        case .output(let data):
            return .output(String(decoding: data, as: UTF8.self))
        case .failed:
            return .failed
        case .timedOut:
            return .timedOut
        }
    }
}

// 进程的启动参数（argv，只能读同一用户的进程）；读不到时为 nil
func processArguments(pid: pid_t) -> [String]? {
    var argumentLimit: Int32 = 0
    var limitSize = MemoryLayout<Int32>.size
    var limitMIB: [Int32] = [CTL_KERN, KERN_ARGMAX]
    guard sysctl(&limitMIB, 2, &argumentLimit, &limitSize, nil, 0) == 0, argumentLimit > 0 else {
        return nil
    }
    var size = Int(argumentLimit)
    var buffer = [UInt8](repeating: 0, count: size)
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
        return nil
    }
    // 布局：argc、程序路径、补齐用的 0、各个参数（都以 0 结尾）、环境变量
    var argumentCount = 0
    for (offset, byte) in buffer.prefix(MemoryLayout<Int32>.size).enumerated() {
        argumentCount |= Int(byte) << (8 * offset)
    }
    var index = MemoryLayout<Int32>.size
    while index < size, buffer[index] != 0 {
        index += 1
    }
    while index < size, buffer[index] == 0 {
        index += 1
    }
    var arguments: [String] = []
    while arguments.count < argumentCount, index < size {
        let start = index
        while index < size, buffer[index] != 0 {
            index += 1
        }
        arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
        index += 1
    }
    return arguments.count == argumentCount ? arguments : nil
}

// MARK: - Neovim

// 终端里前台是 Neovim 时：通过它自己的 RPC 接口（每个 Neovim 都开着的 server socket）调用 nvim_paste。这和终端里真正的粘贴走同一个
// 处理（vim.paste）：插入模式里插入，普通模式里像 P 一样放在光标前，命令行模式里进命令行。文字只经过这个 socket（Copi 确认过对面就是
// 这个 Neovim 进程），不经过剪贴板、不产生按键，也不出现在任何进程的启动参数里。
// 只在认得准焦点所在的就是这个 Neovim 时用：Terminal、iTerm2 的窗口标题显示着正在运行的是 nvim（不是目录名）、并且所有标签页里
// 只有一个标签页在运行 Neovim；
// 别的终端要只开着一个标签页。Neovim 在等一个按键（hit-enter、getchar）、或者焦点在它自己的终端窗口（:terminal）里时不粘贴
enum NvimPaste {
    // 主线程：焦点所在标签页里的 Neovim 进程（界面进程和它启动的 server 进程）。认不准时为 nil
    static func candidates(for target: FocusedTarget) -> [pid_t]? {
        // WezTerm 的复制模式、搜索框可能开着：粘贴应该落在那里，不能绕过去交给下面的 Neovim
        guard !target.wezTermOverlayMayBeOpen, let groups = terminalForegroundGroups(of: target) else {
            return nil
        }
        let nvimGroups = groups.filter { group in group.contains { $0.name == "nvim" } }
        guard nvimGroups.count == 1 else {
            return nil
        }
        if let bundleID = target.bundleIdentifier, jobTitleTerminalBundleIDs.contains(bundleID) {
            guard let title = target.focusedWindowTitle else {
                return nil
            }
            let words = titleProgramWords(title, bundleID: bundleID)
            // 标题里还写着别的标签页前台的程序：认不准焦点在哪个标签页（目录名凑巧是 nvim、标题里的设置和默认的不一样……）
            let others = Set(groups.filter { group in !group.contains { $0.name == "nvim" } }.flatMap { $0.map(\.name) })
            guard words.contains("nvim"), !words.contains(where: others.contains) else {
                return nil
            }
        } else if groups.count != 1 {
            return nil
        }
        let roots = nvimGroups[0].filter { $0.name == "nvim" }.map(\.pid)
        let found = roots + descendants(of: roots)
        // 找不到唯一的 server socket（配置里又 serverstart 了一个、读不到 sudo 运行的 Neovim……）：不走这条路，照旧用终端的接口、键入
        return server(in: found) == nil ? nil : found
    }

    // 这几个进程里正在监听的 Unix socket：只有一个时是它（Copi 自己确认是谁的，不靠环境变量、不猜路径）；没有、不止一个时为 nil
    static func server(in candidates: [pid_t]) -> (pid: pid_t, path: String)? {
        var servers: [(pid: pid_t, path: String)] = []
        for pid in candidates {
            for path in listeningSockets(pid: pid) {
                servers.append((pid, path))
            }
        }
        return servers.count == 1 ? servers.first : nil
    }

    // 这些进程的子孙里的 nvim（0.9 起界面和 server 是两个进程，server 是界面进程启动的）
    static func descendants(of roots: [pid_t]) -> [pid_t] {
        guard let processes = allProcesses() else {
            return []
        }
        var children: [pid_t: [kinfo_proc]] = [:]
        for process in processes {
            children[process.kp_eproc.e_ppid, default: []].append(process)
        }
        var found: [pid_t] = []
        var pending = roots
        var visited = Set<pid_t>()
        while let current = pending.popLast() {
            guard visited.insert(current).inserted else {
                continue
            }
            for child in children[current] ?? [] where processName(child) == "nvim" {
                found.append(child.kp_proc.p_pid)
                pending.append(child.kp_proc.p_pid)
            }
        }
        return found
    }

    // 主线程：在后台粘贴，结果用通知告诉用户
    static func pasteInBackground(_ text: String, candidates: [pid_t], target: FocusedTarget, keyTime: Date) {
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = paste(text, candidates: candidates, keyTime: keyTime)
            DispatchQueue.main.async {
                switch outcome {
                case .sent:
                    notifyProtected("Pasted safely")
                case .stale:
                    notifyCopiNotice("Copi didn't paste into \(RefusedApp(target: target).name) because you kept typing or clicked elsewhere. Press ⌘V again.")
                case .refused(let reason):
                    refuseOrFallBack(reason, text: text, target: target, keyTime: keyTime)
                case .failed:
                    refuseOrFallBack(.modalProgram("nvim"), text: text, target: target, keyTime: keyTime)
                case .unsure:
                    notifyCopiNotice("Copi isn't sure the paste reached Neovim in \(RefusedApp(target: target).name). Check before pasting again.")
                }
            }
        }
    }

    // 后台线程
    static func paste(_ text: String, candidates: [pid_t], keyTime: Date) -> TmuxPaste.Outcome {
        // 调用方选这条路之前看过只有一个 server socket；这期间变了就不粘贴
        guard let server = server(in: candidates),
              let fd = TerminalScript.connectUnixSocket(server.path, expectedPeer: server.pid) else {
            return .failed
        }
        defer {
            close(fd)
        }
        var connection = MsgpackRPC(fd: fd)
        guard let mode = connection.call("nvim_get_mode", [], timeout: 1),
              case .map(let entries) = mode else {
            return .failed
        }
        func entry(_ key: String) -> MsgpackValue? {
            entries.first { if case .string(key) = $0.0 { return true } else { return false } }?.1
        }
        // 在等一个按键：粘贴的第一个字符就是回答
        if case .bool(true)? = entry("blocking") {
            return .refused(.singleKeyPrompt)
        }
        // 焦点在 Neovim 自己的终端窗口里：粘贴会转给里面运行的程序。终端模式（"t"）和按 <C-\><C-N> 回到的普通模式（"nt"、"ntT"）
        // 都是：vim.paste 在这几种模式里把文字交给终端
        if case .string(let current)? = entry("mode"), current.hasPrefix("t") || current.hasPrefix("nt") {
            return .refused(.modalProgram("a program in nvim's terminal"))
        }
        // 终端窗口里的其他模式（按了操作符在等动作……）、换掉了 vim.paste 的配置：放到终端窗口上的文字同样转给程序。
        // 只有命令行里的粘贴进命令行。问不到时不粘贴
        guard case .int(let inTerminal)? = connection.call("nvim_eval", [.string("&buftype ==# 'terminal' && getcmdtype() ==# ''")], timeout: 1) else {
            return .failed
        }
        if inTerminal != 0 {
            return .refused(.modalProgram("a program in nvim's terminal"))
        }
        guard !userActedSince(keyTime), !sessionIsLockedNow() else {
            return .stale
        }
        let timeout = min(15, 2 + Double(text.utf8.count) / 1_000_000)
        switch connection.callResult("nvim_paste", [.string(text), .bool(true), .int(-1)], timeout: timeout) {
        case .result(.bool(true)):
            return .sent
        case .result, .error:
            // 粘贴的处理（vim.paste）取消了、出错了（例如缓冲区不能修改）：什么都没粘贴
            return .failed
        case .noAnswer:
            return .unsure
        }
    }

    // 这个进程正在监听的 Unix socket（属于当前用户的）
    private static func listeningSockets(pid: pid_t) -> [String] {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else {
            return []
        }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.stride + 8)
        let filled = fds.withUnsafeMutableBytes { raw in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, raw.baseAddress, Int32(raw.count))
        }
        guard filled > 0 else {
            return []
        }
        var paths: [String] = []
        for descriptor in fds.prefix(Int(filled) / MemoryLayout<proc_fdinfo>.stride) where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let infoSize = Int32(MemoryLayout<socket_fdinfo>.stride)
            guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &info, infoSize) == infoSize else {
                continue
            }
            let socketInfo = info.psi
            guard socketInfo.soi_family == AF_UNIX, Int(socketInfo.soi_kind) == Int(SOCKINFO_UN),
                  Int32(socketInfo.soi_options) & SO_ACCEPTCONN != 0 else {
                continue
            }
            var address = socketInfo.soi_proto.pri_un.unsi_addr.ua_sun
            let path = withUnsafeBytes(of: &address.sun_path) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            var status = stat()
            guard path.hasPrefix("/"), lstat(path, &status) == 0, (status.st_mode & S_IFMT) == S_IFSOCK, status.st_uid == getuid() else {
                continue
            }
            paths.append(path)
        }
        return paths
    }
}

// MessagePack 的值（只认 Neovim 的回复里会出现的几种；扩展类型、浮点数读过去不用）
indirect enum MsgpackValue {
    case none
    case bool(Bool)
    case int(Int64)
    case string(String)
    case binary([UInt8])
    case array([MsgpackValue])
    case map([(MsgpackValue, MsgpackValue)])
    case other

    func encode(into out: inout [UInt8]) {
        func bigEndian<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.bigEndian) { out.append(contentsOf: $0) }
        }
        switch self {
        case .none, .other:
            out.append(0xc0)
        case .bool(let value):
            out.append(value ? 0xc3 : 0xc2)
        case .int(let value):
            if value >= 0, value < 128 {
                out.append(UInt8(value))
            } else if value < 0, value >= -32 {
                out.append(UInt8(bitPattern: Int8(value)))
            } else {
                out.append(0xd3)
                bigEndian(value)
            }
        case .string(let value):
            let bytes = Array(value.utf8)
            if bytes.count < 32 {
                out.append(0xa0 | UInt8(bytes.count))
            } else if bytes.count < 256 {
                out.append(0xd9)
                out.append(UInt8(bytes.count))
            } else if bytes.count < 65536 {
                out.append(0xda)
                bigEndian(UInt16(bytes.count))
            } else {
                out.append(0xdb)
                bigEndian(UInt32(bytes.count))
            }
            out.append(contentsOf: bytes)
        case .binary(let bytes):
            out.append(0xc6)
            bigEndian(UInt32(bytes.count))
            out.append(contentsOf: bytes)
        case .array(let items):
            if items.count < 16 {
                out.append(0x90 | UInt8(items.count))
            } else {
                out.append(0xdd)
                bigEndian(UInt32(items.count))
            }
            items.forEach { $0.encode(into: &out) }
        case .map(let pairs):
            if pairs.count < 16 {
                out.append(0x80 | UInt8(pairs.count))
            } else {
                out.append(0xdf)
                bigEndian(UInt32(pairs.count))
            }
            for (key, value) in pairs {
                key.encode(into: &out)
                value.encode(into: &out)
            }
        }
    }

    enum Decoded {
        case value(MsgpackValue)
        // 还没收全
        case incomplete
        case malformed
    }

    // 从 bytes 的 index 处读一个值，读完把 index 移到它后面
    static func decode(_ bytes: [UInt8], _ index: inout Int) -> Decoded {
        func take(_ count: Int) -> ArraySlice<UInt8>? {
            guard count >= 0, bytes.count - index >= count else {
                return nil
            }
            defer { index += count }
            return bytes[index..<index + count]
        }
        func unsigned(_ count: Int) -> UInt64? {
            take(count).map { $0.reduce(UInt64(0)) { $0 << 8 | UInt64($1) } }
        }
        func string(_ length: UInt64?) -> Decoded {
            guard let length, let slice = take(Int(length)) else {
                return .incomplete
            }
            return .value(.string(String(decoding: slice, as: UTF8.self)))
        }
        func array(_ count: UInt64?) -> Decoded {
            guard let count else {
                return .incomplete
            }
            var items: [MsgpackValue] = []
            for _ in 0..<count {
                switch decode(bytes, &index) {
                case .value(let item):
                    items.append(item)
                case let other:
                    return other
                }
            }
            return .value(.array(items))
        }
        func map(_ count: UInt64?) -> Decoded {
            guard let count else {
                return .incomplete
            }
            var pairs: [(MsgpackValue, MsgpackValue)] = []
            for _ in 0..<count {
                guard case .value(let key) = decode(bytes, &index) else {
                    return .incomplete
                }
                switch decode(bytes, &index) {
                case .value(let value):
                    pairs.append((key, value))
                case let other:
                    return other
                }
            }
            return .value(.map(pairs))
        }
        func skip(_ count: Int?) -> Decoded {
            guard let count, take(count) != nil else {
                return .incomplete
            }
            return .value(.other)
        }
        guard let first = take(1)?.first else {
            return .incomplete
        }
        switch first {
        case 0x00...0x7f:
            return .value(.int(Int64(first)))
        case 0x80...0x8f:
            return map(UInt64(first & 0x0f))
        case 0x90...0x9f:
            return array(UInt64(first & 0x0f))
        case 0xa0...0xbf:
            return string(UInt64(first & 0x1f))
        case 0xc0:
            return .value(.none)
        case 0xc2:
            return .value(.bool(false))
        case 0xc3:
            return .value(.bool(true))
        case 0xc4, 0xc5, 0xc6:
            guard let length = unsigned(first == 0xc4 ? 1 : (first == 0xc5 ? 2 : 4)), let slice = take(Int(length)) else {
                return .incomplete
            }
            return .value(.binary(Array(slice)))
        case 0xc7, 0xc8, 0xc9:
            return skip(unsigned(first == 0xc7 ? 1 : (first == 0xc8 ? 2 : 4)).map { Int($0) + 1 })
        case 0xca:
            return skip(4)
        case 0xcb:
            return skip(8)
        case 0xcc, 0xcd, 0xce, 0xcf:
            guard let value = unsigned(1 << Int(first - 0xcc)) else {
                return .incomplete
            }
            return .value(.int(Int64(truncatingIfNeeded: value)))
        case 0xd0, 0xd1, 0xd2, 0xd3:
            let width = 1 << Int(first - 0xd0)
            guard let value = unsigned(width) else {
                return .incomplete
            }
            let shift = UInt64(64 - width * 8)
            return .value(.int(Int64(bitPattern: value << shift) >> Int64(shift)))
        case 0xd4, 0xd5, 0xd6, 0xd7, 0xd8:
            return skip((1 << Int(first - 0xd4)) + 1)
        case 0xd9, 0xda, 0xdb:
            return string(unsigned(first == 0xd9 ? 1 : (first == 0xda ? 2 : 4)))
        case 0xdc, 0xdd:
            return array(unsigned(first == 0xdc ? 2 : 4))
        case 0xde, 0xdf:
            return map(unsigned(first == 0xde ? 2 : 4))
        case 0xe0...0xff:
            return .value(.int(Int64(Int8(bitPattern: first))))
        default:
            return .malformed
        }
    }
}

// Neovim 的 msgpack-RPC：一问一答（[0, id, 方法, 参数] → [1, id, 错误, 结果]），中间收到的通知跳过
struct MsgpackRPC {
    let fd: Int32
    private var nextID: Int64 = 1
    private var buffer: [UInt8] = []

    init(fd: Int32) {
        self.fd = fd
    }

    enum Reply {
        case result(MsgpackValue)
        case error(MsgpackValue)
        // 没有回音（超时、连接断了、看不懂）：不知道对面做了没有
        case noAnswer
    }

    mutating func call(_ method: String, _ parameters: [MsgpackValue], timeout: TimeInterval) -> MsgpackValue? {
        if case .result(let value) = callResult(method, parameters, timeout: timeout) {
            return value
        }
        return nil
    }

    mutating func callResult(_ method: String, _ parameters: [MsgpackValue], timeout: TimeInterval) -> Reply {
        let id = nextID
        nextID += 1
        var request: [UInt8] = []
        MsgpackValue.array([.int(0), .int(id), .string(method), .array(parameters)]).encode(into: &request)
        guard TerminalScript.writeAll(fd, request, timeout: timeout) else {
            return .noAnswer
        }
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            var index = 0
            switch MsgpackValue.decode(buffer, &index) {
            case .value(let message):
                buffer.removeFirst(index)
                guard case .array(let parts) = message, parts.count == 4, case .int(1) = parts[0], case .int(id) = parts[1] else {
                    continue
                }
                if case .none = parts[2] {
                    return .result(parts[3])
                }
                return .error(parts[2])
            case .malformed:
                return .noAnswer
            case .incomplete:
                break
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                return .noAnswer
            }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, Int32(max(1, remaining * 1000))) > 0 else {
                return .noAnswer
            }
            var chunk = [UInt8](repeating: 0, count: 65536)
            let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                buffer.append(contentsOf: chunk.prefix(count))
            } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
                return .noAnswer
            }
        }
    }
}

// Terminal、iTerm2 窗口标题里每一段的第一个词（去掉登录 shell 的 "-"），当作程序名。Terminal 的标题是"目录 — 程序 — 80×24"：
// 第一段是当前目录（停在 ~/.config/nvim 里的 shell 也显示 "nvim"），不算
func titleProgramWords(_ title: String, bundleID: String) -> [String] {
    var words = title.components(separatedBy: CharacterSet(charactersIn: "—()")).map { component in
        component.trimmingCharacters(in: .whitespaces).lowercased().split(separator: " ").first.map { String($0.drop(while: { $0 == "-" })) } ?? ""
    }
    if bundleID == "com.apple.Terminal", words.count >= 3 {
        words.removeFirst()
    }
    return words
}
