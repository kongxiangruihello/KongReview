import Foundation
import KongReviewCore

struct HTMLAttributeToken {
    var name: String
    var value: String
    var range: NSRange
    var wholeRange: NSRange
}
struct HTMLTagToken {
    var name: String
    var closing: Bool
    var range: NSRange
    var raw: String
    var attributes: [HTMLAttributeToken]
}
enum HTMLContentTokens {
    static func protectedRanges(_ source: String) -> [NSRange] {
        let re = try! NSRegularExpression(pattern:#"(?is)<!--.*?-->|<(script|style|pre)\b[^>]*>.*?</\1\s*>"#)
        return re.matches(in:source,range:NSRange(location:0,length:(source as NSString).length)).map(\.range)
    }
    static func tags(_ source: String) -> [HTMLTagToken] {
        let ns = source as NSString, protected = protectedRanges(source)
        let tags = try! NSRegularExpression(pattern:#"(?is)<(/?)([a-z][a-z0-9:-]*)\b(?:[^>"']|"[^"]*"|'[^']*')*>"#)
        let attrs = try! NSRegularExpression(pattern:#"\s+([A-Za-z_:][A-Za-z0-9_.:-]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#)
        return tags.matches(in:source,range:NSRange(location:0,length:ns.length)).compactMap { m in
            guard !protected.contains(where:{NSIntersectionRange($0,m.range).length > 0}) else { return nil }
            let raw = ns.substring(with:m.range), rawNS = raw as NSString
            let attributes = attrs.matches(in:raw,range:NSRange(location:0,length:rawNS.length)).compactMap { a -> HTMLAttributeToken? in
                guard let index = (2...4).first(where:{a.range(at:$0).location != NSNotFound}) else { return nil }
                let r = a.range(at:index)
                return .init(name:rawNS.substring(with:a.range(at:1)).lowercased(),value:rawNS.substring(with:r),range:NSRange(location:m.range.location+r.location,length:r.length),wholeRange:NSRange(location:m.range.location+a.range.location,length:a.range.length))
            }
            return .init(name:ns.substring(with:m.range(at:2)).lowercased(),closing:m.range(at:1).length > 0,range:m.range,raw:raw,attributes:attributes)
        }
    }
}

struct EditorCleanupOptions: Equatable {
    var fonts = true
    var colors = true
    var emptyLines = true
    var redundantTags = true
}
struct EditorCleanupResult {
    var text: String
    var changes: Int
}
enum EditorFormattingCleanup {
    static func clean(_ source: String, options: EditorCleanupOptions) -> EditorCleanupResult {
        var edits: [(NSRange,String)] = [], changes = 0
        var stacks: [String:[(HTMLTagToken,Bool)]] = [:]
        for token in HTMLContentTokens.tags(source) {
            var raw = token.raw
            if !token.closing {
                for attr in token.attributes.reversed() {
                    let relative = NSRange(location:attr.wholeRange.location-token.range.location,length:attr.wholeRange.length)
                    if attr.name == "style" {
                        let parts = declarations(attr.value)
                        let kept = parts.filter { part in
                            let key = part.split(separator:":",maxSplits:1).first?.trimmingCharacters(in:.whitespacesAndNewlines).lowercased() ?? ""
                            return !(options.fonts && ["font","font-family","font-size"].contains(key)) && !(options.colors && ["color","background","background-color","-webkit-text-fill-color"].contains(key))
                        }
                        if kept != parts {
                            let value = kept.joined(separator:";")
                            let replacement = value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? "" : " style=\"" + value.replacingOccurrences(of:"\"",with:"&quot;") + "\""
                            raw = (raw as NSString).replacingCharacters(in:relative,with:replacement); changes += parts.count-kept.count
                        }
                    } else if token.name == "font" && ((options.fonts && ["face","size"].contains(attr.name)) || (options.colors && attr.name == "color")) {
                        raw = (raw as NSString).replacingCharacters(in:relative,with:""); changes += 1
                    }
                }
            }
            if options.redundantTags && ["span","font","o:p"].contains(token.name) {
                if token.closing {
                    if let opening = stacks[token.name]?.popLast(), opening.1 {
                        edits.append((opening.0.range,"")); edits.append((token.range,"")); changes += 1
                        continue
                    }
                } else {
                    let stripped = raw.replacingOccurrences(of:#"(?is)^<(?:span|font)\s*>$"#,with:"",options:.regularExpression)
                    let unwrap = token.name == "o:p" || stripped.isEmpty
                    stacks[token.name,default:[]].append((token,unwrap))
                    if unwrap { continue }
                }
            }
            if raw != token.raw { edits.append((token.range,raw)) }
        }
        var text = source
        for edit in edits.sorted(by:{$0.0.location > $1.0.location}) { text = (text as NSString).replacingCharacters(in:edit.0,with:edit.1) }
        if options.emptyLines {
            let re = try! NSRegularExpression(pattern:#"(?is)<p\b[^>]*>(?:\s|&nbsp;|<br\s*/?>)*</p\s*>"#)
            let protected = HTMLContentTokens.protectedRanges(text)
            let matches = re.matches(in:text,range:NSRange(location:0,length:(text as NSString).length)).filter { m in !protected.contains(where:{NSIntersectionRange($0,m.range).length > 0}) }
            for m in matches.reversed() { text = (text as NSString).replacingCharacters(in:m.range,with:""); changes += 1 }
        }
        return .init(text:text,changes:text == source ? 0 : changes)
    }
    private static func declarations(_ css: String) -> [String] {
        var parts: [String] = [], current = "", quote: Character?, depth = 0, escaped = false
        for ch in css {
            if escaped { current.append(ch); escaped = false; continue }
            if ch == "\\" { current.append(ch); escaped = true; continue }
            if let q = quote { if ch == q { quote = nil } }
            else if ch == "\"" || ch == "'" { quote = ch }
            else if ch == "(" { depth += 1 }
            else if ch == ")" { depth = max(0,depth-1) }
            if ch == ";", quote == nil, depth == 0 { parts.append(current); current = "" }
            else { current.append(ch) }
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }
}

struct EditorResourceReference: Identifiable {
    var id: Int { range.location }
    var kind: String
    var value: String
    var range: NSRange
    var message: String
    var problem: Bool
}
enum EditorResourceCheck {
    static func references(_ source: String, localExists: (String) throws -> Bool) rethrows -> [EditorResourceReference] {
        let tokens = HTMLContentTokens.tags(source)
        let ids = Set(tokens.flatMap(\.attributes).filter { $0.name == "id" || $0.name == "name" }.map(\.value))
        var result: [EditorResourceReference] = []
        for token in tokens where !token.closing {
            for attr in token.attributes {
                let media = ["img","audio","video","source"].contains(token.name) && attr.name == "src"
                let link = token.name == "a" && attr.name == "href"
                guard media || link else { continue }
                let value = Markdown.plainText(fromHTML:attr.value)
                let status: (String,Bool)
                if link { status = linkStatus(value,ids:ids) }
                else { status = try mediaStatus(value,localExists:localExists) }
                result.append(.init(kind:link ? "链接" : (token.name == "img" ? "图片" : "音频／视频"),value:value,range:attr.range,message:status.0,problem:status.1))
            }
        }
        let re = try! NSRegularExpression(pattern:#"\[sound:([^\]]+)\]"#)
        let ns = source as NSString
        let protected = HTMLContentTokens.protectedRanges(source)
        for m in re.matches(in:source,range:NSRange(location:0,length:ns.length)) {
            guard !protected.contains(where:{NSIntersectionRange($0,m.range).length > 0}) else { continue }
            let value = ns.substring(with:m.range(at:1)), status = try mediaStatus(value,localExists:localExists)
            result.append(.init(kind:"音频",value:value,range:m.range(at:1),message:status.0,problem:status.1))
        }
        return result.sorted { $0.range.location < $1.range.location }
    }
    private static func linkStatus(_ value: String,ids: Set<String>) -> (String,Bool) {
        if value.isEmpty { return ("链接地址为空",true) }
        if value.hasPrefix("#") { return ids.contains(String(value.dropFirst())) ? ("页内目标存在",false) : ("未找到对应页内目标",true) }
        if value.range(of:#"^(?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,63}(?:[/?#][^\s]*)?$"#,options:.regularExpression) != nil { return ("缺少协议，建议使用 https://" + value,true) }
        guard !value.contains(where:\.isWhitespace), let url = URL(string:value), let scheme = url.scheme?.lowercased() else { return ("地址不完整或包含空白",true) }
        if ["http","https"].contains(scheme) { return url.host?.isEmpty == false ? ("写法有效；未联网检查可用性",false) : ("网页地址缺少域名",true) }
        if scheme == "mailto" { return value.dropFirst(7).contains("@") ? ("邮件地址；未测试投递",false) : ("邮件地址不完整",true) }
        return ("此类链接未作自动验证，请人工核对："+scheme,true)
    }
    private static func mediaStatus(_ value: String,localExists: (String) throws -> Bool) rethrows -> (String,Bool) {
        if value.isEmpty { return ("媒体地址为空",true) }
        if value.hasPrefix("data:") { return ("内嵌媒体；请用文字模式核对显示",false) }
        if let url = URL(string:value), let scheme = url.scheme?.lowercased() {
            if ["http","https","kr-img"].contains(scheme) { return ("远程媒体；未联网检查",false) }
            if scheme == "file" { return FileManager.default.fileExists(atPath:url.path) ? ("本地文件存在",false) : ("本地文件不存在或不可访问",true) }
            if scheme == "kr-media" {
                let name = String(url.path.dropFirst()).removingPercentEncoding ?? String(url.path.dropFirst())
                return try localExists(name) ? ("本地媒体存在",false) : ("本地媒体缺失",true)
            }
            return ("媒体地址类型无法识别",true)
        }
        let name = value.removingPercentEncoding ?? value
        return try localExists(name) ? ("本地媒体存在",false) : ("本地媒体缺失",true)
    }
}
