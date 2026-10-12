//
//  Clipboards.swift
//  SecureYourClipboard
//
//  Created by lixindong on 2024/4/24.
//

import Foundation
import AppKit
import Defaults

// Copi 自己的安全剪贴板，只存在于本进程内存里。
// 之前它是 NSPasteboard(name: "safeCopy") 这样的命名剪贴板：命名剪贴板由系统剪贴板服务托管，
// 任何进程只要知道名字就能读写，Copi 退出后内容也还留在服务里——和"第三方 App 读不到"的前提相矛盾。
final class SecureClipboard {
    static let shared = SecureClipboard()
    static let didChangeNotification = Notification.Name("CopiSecureClipboardDidChange")

    // 机密内容（密码管理器的复制）在 Copi 里保留多久（和 1Password 等的默认自动清除时间一致）
    static let concealedLifetime: TimeInterval = 90

    // event tap 线程和 Action Bar 的后台 Task 也会读取，所以加锁
    private let lock = NSLock()
    private var storage: String?
    private var concealed = false
    private var editorMetadata: EditorPasteMetadata?
    // 在哪个 App 里复制的（bundle ID；不知道时为 nil）
    private var sourceBundleID: String?
    private var generation = 0
    // 当前内容是什么时候存进来的（自动清除从这时算起）
    private var storedAt: Date?
    // 每次重新安排到期清除都加一：改了设置之后，之前按旧设置安排的清除作废
    private var expiryToken = 0

    var text: String? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var hasText: Bool { text != nil }

    // 每次 setText 都会变（到期清除不算）：判断"那之后有没有新的复制"
    var version: Int {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    // 当前内容来自密码管理器（带 nspasteboard.org Concealed 标记），界面上不要明文显示
    var isConcealed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage != nil && concealed
    }

    // 当前内容是在哪个 App 里复制的
    var source: String? {
        lock.lock()
        defer { lock.unlock() }
        return storage != nil ? sourceBundleID : nil
    }

    // 从 VS Code 系编辑器复制时它附带的信息（整行复制、多光标各段），粘贴回编辑器时原样交给它
    var metadata: EditorPasteMetadata? {
        lock.lock()
        defer { lock.unlock() }
        return storage != nil ? editorMetadata : nil
    }

    // concealed：密码管理器的复制。它们会在几十秒后自动清掉系统剪贴板上的密码，转移进来之后也要保持同样的语义，
    // 到期自动清除，不能让密码一直留在 Copi 里随处可贴。
    func setText(_ newValue: String?, concealed isConcealed: Bool = false, metadata: EditorPasteMetadata? = nil, source: String? = nil) {
        // 有了新的文字（或者清空）：更早的不是文字的复制也作废，两样之中只有一样是最新的
        NonTextClipboard.shared.clear()
        lock.lock()
        storage = (newValue?.isEmpty ?? true) ? nil : newValue
        concealed = isConcealed
        editorMetadata = metadata
        sourceBundleID = source
        generation += 1
        storedAt = storage != nil ? Date() : nil
        lock.unlock()
        scheduleExpiry()
        postDidChange()
    }

    // 按当前内容存进来的时间安排到期清除：机密内容 90 秒，其余按用户设置的分钟数（改了设置时重新调用）。
    // 用挂钟时间：Mac 睡眠期间单调时钟不走，睡醒之后应该马上清掉已经过期的内容
    func scheduleExpiry() {
        lock.lock()
        expiryToken += 1
        let token = expiryToken
        let storedAt = self.storedAt
        let isConcealed = concealed
        lock.unlock()
        guard let storedAt else {
            return
        }
        let minutes = Defaults[.autoClearMinutes]
        var lifetimes = minutes > 0 ? [TimeInterval(minutes) * 60] : []
        if isConcealed {
            lifetimes.append(SecureClipboard.concealedLifetime)
        }
        guard let lifetime = lifetimes.min() else {
            return
        }
        let remaining = max(0, storedAt.addingTimeInterval(lifetime).timeIntervalSinceNow)
        DispatchQueue.main.asyncAfter(wallDeadline: .now() + remaining) { [weak self] in
            self?.expire(token: token)
        }
    }

    private func expire(token expectedToken: Int) {
        lock.lock()
        guard expiryToken == expectedToken, storage != nil else {
            lock.unlock()
            return
        }
        storage = nil
        concealed = false
        editorMetadata = nil
        sourceBundleID = nil
        storedAt = nil
        // 不改 generation：到期清除不是一次新的复制（文本扩展工具的临时文字据此判断有没有被新的复制取代）
        lock.unlock()
        postDidChange()
    }

    private func postDidChange() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: SecureClipboard.didChangeNotification, object: nil)
        }
    }
}

// VS Code 复制时附带的信息：空选区复制的是整行（粘贴时插到当前行上面），多光标复制时每个光标各一段
struct EditorPasteMetadata {
    let pasteOnNewLine: Bool
    let multicursorText: [String]?
}

// 不是文字的复制（图片、文件、App 自己格式的对象）：Copi 从系统剪贴板上整个取下来，存在本进程内存里，粘贴时才短暂放上去
// （见 TransientPaste.stageItems），不再一直摆在系统剪贴板上让所有 App 读。和 SecureClipboard 里的文字两样之中只有一样是最新的：
// 存进文字（或者清空）时它也清掉
final class NonTextClipboard {
    static let shared = NonTextClipboard()

    // 一项里的每种类型和数据，按原来的顺序
    typealias Item = [(type: NSPasteboard.PasteboardType, data: Data)]

    private let lock = NSLock()
    private var storage: [Item]?
    private var storedSummary: String?
    private var generation = 0

    var items: [Item]? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var hasContent: Bool {
        items != nil
    }

    // 菜单里显示的说明（"An image"、"3 files"）
    var summary: String? {
        lock.lock()
        defer { lock.unlock() }
        return storage != nil ? storedSummary : nil
    }

    // 每存一次、清一次都加一（区分"同一份"）
    var version: Int {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    // 主线程
    func store(_ items: [Item], summary: String) {
        SecureClipboard.shared.setText(nil)
        lock.lock()
        storage = items
        storedSummary = summary
        generation += 1
        let token = generation
        lock.unlock()
        // 和文字一样按用户设置的分钟数到期清除
        let minutes = Defaults[.autoClearMinutes]
        if minutes > 0 {
            DispatchQueue.main.asyncAfter(wallDeadline: .now() + TimeInterval(minutes) * 60) { [weak self] in
                self?.clear(ifVersion: token)
            }
        }
        postDidChange()
    }

    // 任意线程
    func clear() {
        clear(ifVersion: nil)
    }

    private func clear(ifVersion token: Int?) {
        lock.lock()
        guard storage != nil, token == nil || token == generation else {
            lock.unlock()
            return
        }
        storage = nil
        storedSummary = nil
        generation += 1
        lock.unlock()
        postDidChange()
    }

    private func postDidChange() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: SecureClipboard.didChangeNotification, object: nil)
        }
    }
}

// nspasteboard.org 约定的标记类型，主流剪贴板管理工具（Maccy、Paste、Alfred、Raycast……）都会据此不记录内容
extension NSPasteboard.PasteboardType {
    // 机密内容（密码管理器的复制会带上它）
    static let nspasteboardConcealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    // 只会短暂停留、马上就会被恢复/替换的内容
    static let nspasteboardTransient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    // 程序生成、并非用户主动复制的内容
    static let nspasteboardAutoGenerated = NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType")
    // 通过"通用剪贴板"从用户的其他 Apple 设备同步过来的内容
    static let universalClipboardRemote = NSPasteboard.PasteboardType("com.apple.is-remote-clipboard")
    // Copi 临时挂到系统剪贴板上的粘贴内容带一个"com.gokoding.Copi.staged.<随机 token>"类型，用来认出是不是我们自己那一份。
    // token 放在类型名里而不是数据里：只看类型就能判断，不用读剪贴板数据（将来 macOS 默认开启剪贴板隐私保护后，读数据会弹窗）
    static let copiStagedPrefix = "com.gokoding.Copi.staged"

    static func copiStaged(token: String) -> NSPasteboard.PasteboardType {
        NSPasteboard.PasteboardType("\(copiStagedPrefix).\(token)")
    }

    var isCopiStaged: Bool {
        rawValue.hasPrefix(NSPasteboard.PasteboardType.copiStagedPrefix)
    }

    // 富文本里附件（图片等）的表示形式。纯文本里出现附件占位符 U+FFFC 并且带着这些类型时，说明复制的是图文混合内容
    static let copiAttachmentTypes: Set<NSPasteboard.PasteboardType> = [
        .rtfd, .tiff, .png,
        NSPasteboard.PasteboardType("com.apple.flat-rtfd"),
        NSPasteboard.PasteboardType("NeXT RTFD pasteboard type"),
        NSPasteboard.PasteboardType("public.jpeg"),
        NSPasteboard.PasteboardType("com.apple.webarchive"),
    ]
}

extension NSPasteboard {
    func string() -> String? {
        self.string(forType: .string)
    }

    // 深拷贝当前内容（每个 item 的每种类型的数据），用于事后原样放回。
    // 读取每种类型都会让源 App 当场生成数据（大图、PDF、Office 的各种格式可能很大、很慢，而且是在主线程上等）：
    // 跳过旧式的别名类型（系统会自动从对应的标准类型转换），已有 PNG/JPEG 时跳过同一张图的 TIFF 表示；
    // 总量超过上限后不再读取后面的类型（已经读到的照样放回）。
    func copiSnapshot() -> [NSPasteboardItem] {
        let legacyAliases: Set<String> = [
            "NSStringPboardType", "NeXT TIFF v4.0 pasteboard type", "Apple PNG pasteboard type", "NSPDFPboardType",
            "Apple PDF pasteboard type", "NeXT Rich Text Format v1.0 pasteboard type", "NeXT RTFD pasteboard type",
            "Apple HTML pasteboard type", "NSFilenamesPboardType", "Apple URL pasteboard type", "com.apple.pict",
        ]
        let sizeLimit = 32 * 1024 * 1024
        var totalSize = 0
        var snapshot: [NSPasteboardItem] = []
        let items = pasteboardItems ?? []
        // 通用剪贴板从其他设备同步过来的内容：一读数据就会触发从那台设备传输（可能卡住好几秒），不保存（那台设备上还有）
        if items.contains(where: { $0.types.contains(.universalClipboardRemote) }) {
            return []
        }
        for item in items where !item.types.contains(PasteboardOwnership.placeholderType) {
            let copy = NSPasteboardItem()
            let types = item.types
            let hasCompactImage = types.contains(.png) || types.contains(NSPasteboard.PasteboardType("public.jpeg"))
            for type in types where !legacyAliases.contains(type.rawValue) && !(hasCompactImage && type == .tiff) {
                guard totalSize <= sizeLimit, let data = item.data(forType: type) else {
                    continue
                }
                totalSize += data.count
                copy.setData(data, forType: type)
            }
            snapshot.append(copy)
        }
        return snapshot
    }

    // 不是文字的复制整个取下来（每一项的每一种类型的数据），存进 Copi（见 NonTextClipboard）。读不全就返回 nil——某种类型读不出来、
    // 太大、要源 App 事后兑现的文件承诺、从别的设备同步来的、Copi 自己挂上去的：宁可照旧留在系统剪贴板上，也不存一份粘贴出来缺东西的。
    // 跳过旧式的别名类型（系统会从对应的标准类型自动转换）。总共超过 64 MB 的不存
    func copiNonTextSnapshot(_ items: [NSPasteboardItem]) -> [NonTextClipboard.Item]? {
        let legacyAliases: Set<String> = [
            "NSStringPboardType", "NeXT TIFF v4.0 pasteboard type", "Apple PNG pasteboard type", "NSPDFPboardType",
            "Apple PDF pasteboard type", "NeXT Rich Text Format v1.0 pasteboard type", "NeXT RTFD pasteboard type",
            "Apple HTML pasteboard type", "NSFilenamesPboardType", "Apple URL pasteboard type", "com.apple.pict",
        ]
        let promiseTypes: Set<String> = [
            "com.apple.pasteboard.promised-file-url", "com.apple.NSFilePromiseItemMetaData", "NSPromiseContentsPboardType",
            "com.apple.pasteboard.promised-file-content-type", "com.apple.pasteboard.promised-file-name",
        ]
        let sizeLimit = 64 * 1024 * 1024
        var totalSize = 0
        var snapshot: [NonTextClipboard.Item] = []
        for item in items {
            let types = item.types
            if types.contains(where: { promiseTypes.contains($0.rawValue) || $0 == .universalClipboardRemote || $0.isCopiStaged
                || $0 == PasteboardOwnership.placeholderType }) {
                return nil
            }
            // 同一张图已经有 PNG/JPEG：TIFF 表示不读（往往是源 App 当场生成的、很大，在主线程上读会卡住）
            let hasCompactImage = types.contains(.png) || types.contains(NSPasteboard.PasteboardType("public.jpeg"))
            var entries: NonTextClipboard.Item = []
            for type in types where !legacyAliases.contains(type.rawValue) && !(hasCompactImage && type == .tiff) {
                guard let data = item.data(forType: type) else {
                    return nil
                }
                totalSize += data.count
                guard totalSize <= sizeLimit else {
                    return nil
                }
                entries.append((type, data))
            }
            guard !entries.isEmpty else {
                return nil
            }
            snapshot.append(entries)
        }
        return snapshot.isEmpty ? nil : snapshot
    }

    // 系统剪贴板服务的私有接口（WebKit、Chromium 也在用）：到期后由服务自己清空这次的内容；macOS 26 起还能让它不进 Spotlight 的
    // 剪贴板历史。必须紧接着 clearContents / prepareForNewContents 调用。接口不存在时什么都不做。
    func copiSetPrivateLifetime(until expiration: Date) {
        let expirationSelector = NSSelectorFromString("_setExpirationDate:")
        if responds(to: expirationSelector), let method = method(for: expirationSelector) {
            typealias SetExpiration = @convention(c) (AnyObject, Selector, NSDate) -> Bool
            _ = unsafeBitCast(method, to: SetExpiration.self)(self, expirationSelector, expiration as NSDate)
        }
        copiExcludeFromHistory()
    }

    // 同上，只是不进 Spotlight 的剪贴板历史（macOS 26 起），不设到期时间：Copi 写进系统剪贴板的每一样东西（占位项、放回去的内容）
    // 都这样标上。也必须紧接着 clearContents / prepareForNewContents 调用
    func copiExcludeFromHistory() {
        let excludeSelector = NSSelectorFromString("_setShouldExcludeFromHistory:")
        if responds(to: excludeSelector), let method = method(for: excludeSelector) {
            typealias SetExclude = @convention(c) (AnyObject, Selector, Bool) -> Bool
            _ = unsafeBitCast(method, to: SetExclude.self)(self, excludeSelector, true)
        }
    }

    // 放回之前保存的内容。只留在本机（不经"通用剪贴板"同步到其他设备）；
    // 带 Concealed 标记的内容（密码管理器的复制）不再放回，它本来就会被密码管理器定时清除。
    func copiRestore(_ archive: [NSPasteboardItem]?) {
        let archive = archive ?? []
        let isConcealed = archive.contains { $0.types.contains(.nspasteboardConcealed) }
        if archive.isEmpty || isConcealed {
            markSeen(copiClear())
        } else {
            let changeCount = prepareForNewContents(with: .currentHostOnly)
            // 放回去的内容不要以"新复制"的身份再进一次 Spotlight 的剪贴板历史
            copiExcludeFromHistory()
            writeObjects(archive)
            markSeen(changeCount)
        }
    }
}

// 没有纯文本、只有富文本、网页内容或者链接的复制（有的 App 只写 RTF 或 HTML，"拷贝链接"有时只写 URL）：取出其中的文字。
// 不取的话 Copi 认不出它是文字，会把它当作图片之类的内容原样留在系统剪贴板上。
// 只在整个复制里除了文字的各种表示、标记之外没有别的东西时才取（带着图片、文件、App 自己格式的对象数据的，是那样东西的复制：
// 取了文字再清掉剪贴板，图片、对象就没了）。RTFD 例外：它的附件取出来是 U+FFFC，调用方据此告诉用户图片没带上。
// HTML 不交给 NSAttributedString 解析（它会启动 WebKit、可能去加载网页里引用的资源）：一遍扫过去去掉标签、还原字符实体。
// 太大的不取（主线程上解析）。取不出文字时返回 nil
func copiTextFromRichContent(_ items: [NSPasteboardItem]) -> String? {
    let allTypes = Set(items.flatMap { $0.types })
    guard !allTypes.isEmpty, allTypes.allSatisfy(copiIsTextRepresentation) else {
        return nil
    }
    let sizeLimit = 8 * 1024 * 1024
    let flatRTFD = NSPasteboard.PasteboardType("com.apple.flat-rtfd")
    for item in items {
        let types = Set(item.types)
        if types.contains(.rtf), let data = item.data(forType: .rtf), data.count <= sizeLimit,
           let text = NSAttributedString(rtf: data, documentAttributes: nil)?.string {
            return text
        }
        for type in [NSPasteboard.PasteboardType.rtfd, flatRTFD] where types.contains(type) {
            if let data = item.data(forType: type), data.count <= sizeLimit,
               let text = NSAttributedString(rtfd: data, documentAttributes: nil)?.string {
                return text
            }
        }
        if types.contains(.html), let html = item.string(forType: .html), html.utf8.count <= 2 * 1024 * 1024 {
            return copiPlainText(fromHTML: html)
        }
        if types.contains(.URL), let url = item.string(forType: .URL) {
            return url
        }
    }
    return nil
}

// 文字的各种表示，以及不带内容的标记、来源信息
private let copiTextRepresentationTypes: Set<String> = [
    NSPasteboard.PasteboardType.string.rawValue, "public.utf16-plain-text", "public.utf16-external-plain-text", "NSStringPboardType",
    NSPasteboard.PasteboardType.rtf.rawValue, "NeXT Rich Text Format v1.0 pasteboard type",
    NSPasteboard.PasteboardType.rtfd.rawValue, "com.apple.flat-rtfd", "NeXT RTFD pasteboard type",
    NSPasteboard.PasteboardType.html.rawValue, "Apple HTML pasteboard type",
    NSPasteboard.PasteboardType.URL.rawValue, "public.url-name", "Apple URL pasteboard type", "WebURLsWithTitlesPboardType",
    "CorePasteboardFlavorType 0x75726C20", "CorePasteboardFlavorType 0x75726C6E",
]

// 浏览器给网页的复制附带的来源信息（网址、所在的页面）和网页自己的数据、nspasteboard.org 的标记
func copiIsTextRepresentation(_ type: NSPasteboard.PasteboardType) -> Bool {
    copiTextRepresentationTypes.contains(type.rawValue)
        || ["org.nspasteboard.", "org.chromium.", "com.apple.WebKit.custom-pasteboard-data"].contains { type.rawValue.hasPrefix($0) }
}

// HTML 转成纯文字：只扫一遍，每个标签、注释、<script> 这类块的结尾都只往后找一次（找不到就丢掉后面的全部），
// 所以再长、再畸形的输入也是线性时间。规则和浏览器的"纯文字"大致一样：空白折叠成一个空格，块级元素、<br> 换行，
// <pre> 里原样保留换行和缩进，表格单元格之间用制表符；不间断空格变成普通空格；控制字符去掉
func copiPlainText(fromHTML html: String) -> String {
    let input = Array(html.unicodeScalars)
    let count = input.count
    var output = String.UnicodeScalarView()
    var preDepth = 0
    // 紧跟在 <pre> 开始标签后面的第一个换行不算（浏览器也这样）
    var skipNewline = false
    var index = 0
    let commentOpen = Array("<!--".unicodeScalars)

    func isLetter(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value >= 0x41 && scalar.value <= 0x5A) || (scalar.value >= 0x61 && scalar.value <= 0x7A)
    }
    func isDigit(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= 0x30 && scalar.value <= 0x39
    }
    func lowered(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        scalar.value >= 0x41 && scalar.value <= 0x5A ? Unicode.Scalar(scalar.value + 0x20)! : scalar
    }
    // literal 是小写 ASCII
    func matches(_ literal: [Unicode.Scalar], at position: Int) -> Bool {
        guard position + literal.count <= count else {
            return false
        }
        for (offset, scalar) in literal.enumerated() where lowered(input[position + offset]) != scalar {
            return false
        }
        return true
    }
    func find(_ literal: String, from position: Int) -> Int? {
        let needle = Array(literal.unicodeScalars)
        var cursor = position
        while cursor + needle.count <= count {
            if matches(needle, at: cursor) {
                return cursor
            }
            cursor += 1
        }
        return nil
    }
    func trimTrailingBlanks() {
        while let last = output.last, last == " " || last == "\t" {
            output.removeLast()
        }
    }
    func lineBreak() {
        trimTrailingBlanks()
        if let last = output.last, last != "\n" {
            output.append("\n")
        }
    }
    func append(_ scalar: Unicode.Scalar) {
        // <pre> 里换行、制表符、空格原样保留
        if preDepth > 0 {
            let isNewline = scalar == "\n" || scalar == "\r"
            if skipNewline {
                skipNewline = false
                if isNewline {
                    return
                }
            }
            if isNewline || scalar == "\t" || scalar == " " {
                output.append(isNewline ? "\n" : scalar)
                return
            }
        }
        switch scalar.value {
        case 0x20, 0x09, 0x0A, 0x0C, 0x0D:
            if let last = output.last, last != " ", last != "\n", last != "\t" {
                output.append(" ")
            }
        case 0xA0:
            output.append(" ")
        case 0x00...0x1F, 0x7F...0x9F, 0xAD:
            // 控制字符、软连字符：看不见的，不要
            break
        default:
            output.append(scalar)
        }
    }

    while index < count {
        let scalar = input[index]
        if scalar == "&" {
            let (decoded, length) = decodeHTMLEntity(input, at: index)
            if let decoded {
                append(decoded)
                index += length
            } else {
                append(scalar)
                index += 1
            }
            continue
        }
        guard scalar == "<" else {
            // \r\n 当作一个换行
            if scalar == "\r", index + 1 < count, input[index + 1] == "\n" {
                index += 1
                continue
            }
            append(scalar)
            index += 1
            continue
        }
        if matches(commentOpen, at: index) {
            index = find("-->", from: index + 4).map { $0 + 3 } ?? count
            continue
        }
        let next = index + 1 < count ? input[index + 1] : " "
        let closing = next == "/"
        let nameStart = closing ? index + 2 : index + 1
        guard nameStart < count, isLetter(input[nameStart]) || (!closing && (next == "!" || next == "?")) else {
            // 不是标签的 "<"（例如 "a < b"）
            append(scalar)
            index += 1
            continue
        }
        var nameEnd = nameStart
        while nameEnd < count, isLetter(input[nameEnd]) || isDigit(input[nameEnd]) || input[nameEnd] == "-" {
            nameEnd += 1
        }
        let name = String(String.UnicodeScalarView(input[nameStart..<nameEnd].map(lowered)))
        // 标签的结尾：加了引号的属性值里的 ">" 不算（只有紧跟在 "=" 后面的引号才是属性值的引号，"it's" 这样的不算）
        var cursor = nameEnd
        var quote: Unicode.Scalar?
        var afterEquals = false
        while cursor < count {
            let current = input[cursor]
            if let open = quote {
                if current == open {
                    quote = nil
                }
            } else if afterEquals, current == "\"" || current == "'" {
                quote = current
            } else if current == ">" {
                break
            }
            if current == "=" {
                afterEquals = quote == nil
            } else if !(current == " " || current == "\t" || current == "\n" || current == "\r") {
                afterEquals = false
            }
            cursor += 1
        }
        guard cursor < count else {
            break
        }
        index = cursor + 1
        if !closing, htmlHiddenElements.contains(name) {
            // 不显示的内容：跳到它的结束标签之后
            if let end = find("</" + name, from: index) {
                index = find(">", from: end).map { $0 + 1 } ?? count
            } else {
                index = count
            }
            continue
        }
        if htmlPreformattedElements.contains(name) {
            lineBreak()
            if closing {
                preDepth = max(0, preDepth - 1)
            } else {
                preDepth += 1
                skipNewline = true
            }
        } else if name == "br" {
            trimTrailingBlanks()
            if !output.isEmpty {
                output.append("\n")
            }
        } else if closing, name == "td" || name == "th" {
            trimTrailingBlanks()
            output.append("\t")
        } else if htmlBlockElements.contains(name) {
            lineBreak()
        }
    }
    while let last = output.last, last == " " || last == "\t" || last == "\n" {
        output.removeLast()
    }
    return String(output)
}

// （<head> 本身不算：它的结束标签可以省略，里面看不见的 <title>、<style>、<script> 已经各自去掉了）
private let htmlHiddenElements: Set<String> = ["script", "style", "template", "title", "noscript"]
private let htmlPreformattedElements: Set<String> = ["pre", "listing", "textarea", "xmp", "plaintext"]
private let htmlBlockElements: Set<String> = [
    "address", "article", "aside", "blockquote", "caption", "center", "dd", "details", "dialog", "div", "dl", "dt", "fieldset",
    "figcaption", "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr", "li", "main", "nav", "ol", "p",
    "section", "summary", "table", "tbody", "tfoot", "thead", "tr", "ul",
]

// position 处的字符实体（"&amp;" "&#169;" "&#x1F600;"）：返回解出来的字符和它占的长度；不是认得的实体时字符为 nil。
// 最多往后看 40 个字符
private func decodeHTMLEntity(_ input: [Unicode.Scalar], at position: Int) -> (Unicode.Scalar?, Int) {
    let limit = min(input.count, position + 40)
    var cursor = position + 1
    guard cursor < limit else {
        return (nil, 1)
    }
    if input[cursor] == "#" {
        cursor += 1
        var radix: UInt32 = 10
        if cursor < limit, input[cursor] == "x" || input[cursor] == "X" {
            radix = 16
            cursor += 1
        }
        var value: UInt32 = 0
        var digits = 0
        while cursor < limit, let digit = Int(String(input[cursor]), radix: Int(radix)), digits < 8 {
            value = value * radix + UInt32(digit)
            digits += 1
            cursor += 1
        }
        guard digits > 0 else {
            return (nil, 1)
        }
        if cursor < input.count, input[cursor] == ";" {
            cursor += 1
        }
        // 0x80–0x9F 按 Windows-1252 解释（HTML 规范这样规定）；0、代理项、超出范围的换成 U+FFFD
        if let mapped = htmlWindows1252[value] {
            return (mapped, cursor - position)
        }
        guard value != 0, let decoded = Unicode.Scalar(value) else {
            return ("\u{FFFD}", cursor - position)
        }
        return (decoded, cursor - position)
    }
    var name = ""
    func isAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        (0x30...0x39).contains(scalar.value) || (0x41...0x5A).contains(scalar.value) || (0x61...0x7A).contains(scalar.value)
    }
    while cursor < limit, isAlphanumeric(input[cursor]) {
        name.unicodeScalars.append(input[cursor])
        cursor += 1
    }
    guard cursor < input.count, input[cursor] == ";", let decoded = htmlNamedEntities[name] else {
        return (nil, 1)
    }
    return (decoded, cursor + 1 - position)
}

private let htmlWindows1252: [UInt32: Unicode.Scalar] = [
    0x80: "\u{20AC}", 0x82: "\u{201A}", 0x83: "\u{0192}", 0x84: "\u{201E}", 0x85: "\u{2026}", 0x86: "\u{2020}", 0x87: "\u{2021}",
    0x88: "\u{02C6}", 0x89: "\u{2030}", 0x8A: "\u{0160}", 0x8B: "\u{2039}", 0x8C: "\u{0152}", 0x8E: "\u{017D}", 0x91: "\u{2018}",
    0x92: "\u{2019}", 0x93: "\u{201C}", 0x94: "\u{201D}", 0x95: "\u{2022}", 0x96: "\u{2013}", 0x97: "\u{2014}", 0x98: "\u{02DC}",
    0x99: "\u{2122}", 0x9A: "\u{0161}", 0x9B: "\u{203A}", 0x9C: "\u{0153}", 0x9E: "\u{017E}", 0x9F: "\u{0178}",
]

// 常用的命名实体：Latin-1 的全部（U+00A0–U+00FF，按顺序）以及标点、引号、货币、箭头、数学符号里常见的
private let htmlNamedEntities: [String: Unicode.Scalar] = {
    var table: [String: Unicode.Scalar] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "ndash": "\u{2013}", "mdash": "\u{2014}", "hellip": "\u{2026}", "lsquo": "\u{2018}", "rsquo": "\u{2019}", "sbquo": "\u{201A}",
        "ldquo": "\u{201C}", "rdquo": "\u{201D}", "bdquo": "\u{201E}", "lsaquo": "\u{2039}", "rsaquo": "\u{203A}", "bull": "\u{2022}",
        "dagger": "\u{2020}", "Dagger": "\u{2021}", "permil": "\u{2030}", "prime": "\u{2032}", "Prime": "\u{2033}", "trade": "\u{2122}",
        "euro": "\u{20AC}", "ensp": "\u{2002}", "emsp": "\u{2003}", "thinsp": "\u{2009}", "zwnj": "\u{200C}", "zwj": "\u{200D}",
        "lrm": "\u{200E}", "rlm": "\u{200F}", "larr": "\u{2190}", "uarr": "\u{2191}", "rarr": "\u{2192}", "darr": "\u{2193}",
        "harr": "\u{2194}", "lArr": "\u{21D0}", "rArr": "\u{21D2}", "hArr": "\u{21D4}", "minus": "\u{2212}", "ne": "\u{2260}",
        "le": "\u{2264}", "ge": "\u{2265}", "infin": "\u{221E}", "asymp": "\u{2248}", "equiv": "\u{2261}", "sum": "\u{2211}",
        "radic": "\u{221A}", "check": "\u{2713}", "OElig": "\u{0152}", "oelig": "\u{0153}", "Scaron": "\u{0160}", "scaron": "\u{0161}",
        "Yuml": "\u{0178}", "fnof": "\u{0192}", "circ": "\u{02C6}", "tilde": "\u{02DC}", "alpha": "\u{03B1}", "beta": "\u{03B2}",
        "gamma": "\u{03B3}", "delta": "\u{03B4}", "pi": "\u{03C0}", "mu": "\u{03BC}", "sigma": "\u{03C3}", "omega": "\u{03C9}",
        "Delta": "\u{0394}", "Omega": "\u{03A9}", "nbsp": "\u{00A0}",
    ]
    let latin1 = """
    nbsp iexcl cent pound curren yen brvbar sect uml copy ordf laquo not shy reg macr deg plusmn sup2 sup3 acute micro para middot \
    cedil sup1 ordm raquo frac14 frac12 frac34 iquest Agrave Aacute Acirc Atilde Auml Aring AElig Ccedil Egrave Eacute Ecirc Euml \
    Igrave Iacute Icirc Iuml ETH Ntilde Ograve Oacute Ocirc Otilde Ouml times Oslash Ugrave Uacute Ucirc Uuml Yacute THORN szlig \
    agrave aacute acirc atilde auml aring aelig ccedil egrave eacute ecirc euml igrave iacute icirc iuml eth ntilde ograve oacute \
    ocirc otilde ouml divide oslash ugrave uacute ucirc uuml yacute thorn yuml
    """
    for (offset, name) in latin1.split(separator: " ").enumerated() {
        table[String(name)] = Unicode.Scalar(UInt32(0xA0 + offset))
    }
    return table
}()
