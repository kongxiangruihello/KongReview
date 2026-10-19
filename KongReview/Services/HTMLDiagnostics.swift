import Foundation

struct HTMLDiagnostics: Equatable, Sendable {
    var issues: [String]
    var proposed: String
    static func inspect(_ source: String) -> Self {
        var issues: [String] = [], stack: [(String,Int)] = []
        let chars = Array(source)
        var i = 0, line = 1, malformed = false, unclosedQuote = false
        let voids: Set<String> = ["area","base","br","col","embed","hr","img","input","link","meta","param","source","track","wbr"]
        while i < chars.count {
            if chars[i] == "\n" { line += 1 }
            guard chars[i] == "<", i+1 < chars.count, chars[i+1].isLetter || chars[i+1] == "/" || chars[i+1] == "!" else { i += 1; continue }
            let start = i, startLine = line
            if String(chars[i..<min(i+4,chars.count)]) == "<!--" {
                i += 4
                while i+2 < chars.count && String(chars[i...i+2]) != "-->" { if chars[i] == "\n" { line += 1 }; i += 1 }
                if i+2 >= chars.count { issues.append("第 \(startLine) 行：注释缺少 -->。"); malformed = true; break }
                i += 3; continue
            }
            var quote: Character?
            i += 1
            while i < chars.count {
                let ch = chars[i]
                if ch == "\n" { line += 1 }
                if let current = quote { if ch == current { quote = nil } }
                else if ch == "\"" || ch == "'" { quote = ch }
                else if ch == ">" { break }
                i += 1
            }
            guard i < chars.count else {
                unclosedQuote = quote != nil
                issues.append("第 \(startLine) 行：" + (quote == nil ? "标签缺少 >。" : "属性引号没有闭合。")); malformed = true; break
            }
            let token = String(chars[(start+1)..<i]).trimmingCharacters(in:.whitespacesAndNewlines)
            i += 1
            if token.hasPrefix("!") { continue }
            let closing = token.hasPrefix("/")
            let body = closing ? String(token.dropFirst()) : token
            let name = String(body.prefix { $0.isLetter || $0.isNumber || $0 == "-" }).lowercased()
            if name.isEmpty { issues.append("第 \(startLine) 行：闭合标签缺少名称，例如 </a>。"); malformed = true; continue }
            if closing {
                if stack.last?.0 == name { stack.removeLast() }
                else { issues.append("第 \(startLine) 行：</\(name)> 与前面的标签不匹配。"); malformed = true }
            } else if !voids.contains(name) && !token.hasSuffix("/") { stack.append((name,startLine)) }
        }
        for (name,line) in stack { issues.append("第 \(line) 行：<\(name)> 缺少 </\(name)>。") }
        var proposed = source
        // Only offer bounded, recognizable repairs; never apply silently.
        if unclosedQuote {
            proposed = replacing(proposed,pattern:#"(?is)<a\b([^<>]*?)href\s*=\s*"([^"\r\n<>]+)>(.*?)</(?:a)?>"#,template:"<a$1href=\"$2\">$3</a>")
        }
        proposed = replacing(proposed,pattern:#"(?is)(<a\b[^>]*>[^<]*)</>"#,template:"$1</a>")
        let links = try! NSRegularExpression(pattern:#"(?i)\bhref\s*=\s*(["'])([^"']+)\1"#)
        let ns = proposed as NSString
        for m in links.matches(in:proposed,range:NSRange(location:0,length:ns.length)).reversed() {
            let address = ns.substring(with:m.range(at:2))
            if address.range(of:#"^(?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,63}(?:[/?#][^\s]*)?$"#,options:.regularExpression) != nil {
                issues.append("链接 \(address) 缺少协议，建议补全 https://。")
                proposed = (proposed as NSString).replacingCharacters(in:m.range(at:2),with:"https://"+address)
            }
        }
        if !malformed && !stack.isEmpty { proposed += stack.reversed().map { "</\($0.0)>" }.joined() }
        return Self(issues:issues,proposed:proposed)
    }
    private static func replacing(_ text: String,pattern: String,template: String) -> String {
        guard let re = try? NSRegularExpression(pattern:pattern) else { return text }
        return re.stringByReplacingMatches(in:text,range:NSRange(text.startIndex...,in:text),withTemplate:template)
    }
}
