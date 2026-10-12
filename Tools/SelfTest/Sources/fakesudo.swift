// 测试用的假 sudo：进程名叫 sudo，像真 sudo 读密码一样关掉回显、保留整行读，读一行，
// 把这一行的长度和 djb2 哈希写进参数指定的文件（不写内容本身），然后退出。不做任何认证。
// 60 秒内没读到一行、或者被结束时，恢复终端设置后退出（不写结果文件）。
import Darwin

var ttyFD: Int32 = -1
var savedModes = termios()

func restoreAndExit(_ signal: Int32) {
    var modes = savedModes
    tcsetattr(ttyFD, TCSAFLUSH, &modes)
    _exit(1)
}

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/dev/null"
ttyFD = open("/dev/tty", O_RDWR)
guard ttyFD >= 0 else {
    exit(1)
}
var attributes = termios()
tcgetattr(ttyFD, &attributes)
savedModes = attributes
for sig in [SIGALRM, SIGHUP, SIGTERM, SIGINT] {
    signal(sig, restoreAndExit)
}
alarm(60)
attributes.c_lflag &= ~tcflag_t(ECHO | ECHONL)
attributes.c_lflag |= tcflag_t(ICANON)
tcsetattr(ttyFD, TCSAFLUSH, &attributes)
// 一眼看得出是假的（Copi 认 sudo 靠进程名和终端模式，不看提示文字）
let prompt = "[Copi selftest fake sudo - do not type your password] Password:"
_ = prompt.withCString { write(ttyFD, $0, strlen($0)) }
var bytes: [UInt8] = []
var byte: UInt8 = 0
while read(ttyFD, &byte, 1) == 1 {
    if byte == 10 {
        break
    }
    bytes.append(byte)
}
alarm(0)
var restore = savedModes
tcsetattr(ttyFD, TCSAFLUSH, &restore)
let line = String(decoding: bytes, as: UTF8.self)
var hash: UInt32 = 5381
for unit in line.utf16 {
    hash = (hash &* 33) ^ UInt32(unit)
}
let result = "len=\(line.utf16.count)|h=\(String(hash, radix: 16))\n"
if let file = fopen(output, "w") {
    fputs(result, file)
    fclose(file)
}
_ = "\nfakesudo done\n".withCString { write(ttyFD, $0, strlen($0)) }
