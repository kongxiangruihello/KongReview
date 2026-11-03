import XCTest
@testable import KongReviewCore

/// 6.0.0：卡片模板的 HTML——Anki 写法的渲染、检查、由放置生成、protobuf 读取
final class V600TemplateTests: XCTestCase {
    private let names = ["正文", "注释", "译文"]
    private let fields = ["学而时习之", "<b>时</b>：按时", ""]
    private var map: [String: String] { ["正文": "学而时习之", "注释": "<b>时</b>：按时", "译文": ""] }

    func testFieldsFrontSideAndConditionals() {
        let e = CardTemplateEngine.self
        XCTAssertEqual(e.render("<h1>{{正文}}</h1>", fields: map, side: .front), "<h1>学而时习之</h1>")
        XCTAssertEqual(e.render("{{ 正文 }}", fields: map, side: .front), "学而时习之", "花括号里可以有空格")
        XCTAssertEqual(e.render("{{FrontSide}}\n\n<hr id=answer>\n\n{{注释}}", fields: map, side: .back), "<b>时</b>：按时",
                       "背面不重复正面，也去掉紧随的分隔线")
        XCTAssertEqual(e.render("{{#译文}}译：{{译文}}{{/译文}}{{^译文}}（无译文）{{/译文}}", fields: map, side: .back), "（无译文）")
        XCTAssertEqual(e.render("{{#注释}}<div>{{#正文}}{{正文}}·{{/正文}}{{注释}}</div>{{/注释}}", fields: map, side: .back),
                       "<div>学而时习之·<b>时</b>：按时</div>", "可以嵌套")
        XCTAssertEqual(e.render("{{text:注释}}", fields: map, side: .back), "时：按时")
        XCTAssertTrue(e.render("{{hint:注释}}", fields: map, side: .front).contains("<details class=\"kr-hint\"><summary>显示提示</summary>"))
        XCTAssertEqual(e.render("{{hint:译文}}", fields: map, side: .front), "", "空字段不出提示")
        XCTAssertEqual(e.render("{{type:正文}}", fields: map, side: .front), "")
        XCTAssertEqual(e.render("{{type:正文}}", fields: map, side: .back), "学而时习之")
        XCTAssertEqual(e.render("{{不存在}}x", fields: map, side: .front), "x")
        XCTAssertEqual(e.render("未闭合 {{正文", fields: map, side: .front), "未闭合 {{正文")
    }

    func testCloze() {
        let m = ["正文": "学而{{c1::时习}}之"]
        let front = CardTemplateEngine.render("{{cloze:正文}}", fields: m, side: .front)
        let back = CardTemplateEngine.render("{{cloze:正文}}", fields: m, side: .back)
        XCTAssertFalse(front.contains("时习"), "正面挖空")
        XCTAssertTrue(back.contains("时习"), "背面显示答案")
        XCTAssertEqual(CardTemplateEngine.render("{{cloze:正文}}", fields: ["正文": "没有挖空"], side: .front), "")
    }

    func testIssues() {
        let e = CardTemplateEngine.self
        XCTAssertEqual(e.issues("{{正文}}{{#注释}}{{注释}}{{/注释}}", fieldNames: names, side: .front), [])
        XCTAssertEqual(e.issues("{{FrontSide}}<hr id=answer>{{注释}}", fieldNames: names, side: .back), [])
        XCTAssertEqual(e.issues("{{正闻}}", fieldNames: names, side: .front), ["没有名为“正闻”的字段"])
        XCTAssertEqual(e.issues("{{FrontSide}}", fieldNames: names, side: .front), ["正面模板不能用 {{FrontSide}}"])
        XCTAssertEqual(e.issues("{{#注释}}x", fieldNames: names, side: .back), ["{{#注释}} 或 {{^注释}} 没有收尾的 {{/注释}}"])
        XCTAssertEqual(e.issues("x{{/注释}}", fieldNames: names, side: .back), ["{{/注释}} 没有对应的开头"])
        XCTAssertEqual(e.issues("{{furigana:正文}}", fieldNames: names, side: .front), ["不认识的写法“furigana:”"])
        XCTAssertEqual(e.issues("{{}}", fieldNames: names, side: .front), ["有一处 {{}} 是空的"])
    }

    func testHTMLFromPlacementMatchesPlacementRendering() {
        let t = NoteTemplate.defaultTemplate(name: "论语", fieldNames: ["正文", "注释", "译文", "解题", "备注"])
        let f = ["学而时习之", "", "学习并时常温习", "首章", "<i>朱注</i>"]
        var h = t
        h.html = CardTemplateEngine.html(from: t)
        let a = t.render(f), b = h.render(f)
        func norm(_ s: String) -> String { s.replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression) }
        XCTAssertEqual(norm(a.front), norm(b.front), "生成的 HTML 与放置显示一样")
        XCTAssertEqual(norm(a.back), norm(b.back))
        XCTAssertTrue(h.html!.back.hasPrefix("{{FrontSide}}"))
        XCTAssertEqual(CardTemplateEngine.issues(h.html!.front, fieldNames: t.fieldNames, side: .front), [])
        XCTAssertEqual(CardTemplateEngine.issues(h.html!.back, fieldNames: t.fieldNames, side: .back), [])
        // 完形填空类型
        var c = NoteTemplate.defaultTemplate(name: "填空", fieldNames: ["正文", "补充"], isCloze: true)
        let cf = ["学而{{c1::时习}}之", "补"]
        let before = c.render(cf)
        c.html = CardTemplateEngine.html(from: c)
        XCTAssertEqual(norm(before.front), norm(c.render(cf).front))
        XCTAssertTrue(c.render(cf).back.contains("时习"))
    }

    func testTemplateUsesHTMLAndCodable() throws {
        var t = NoteTemplate.defaultTemplate(name: "论语", fieldNames: names)
        XCTAssertEqual(t.css, "")
        t.html = NoteTemplateHTML(front: "<p class='q'>{{正文}}</p>", back: "{{FrontSide}}<hr id=answer>{{注释}}", css: ".q { color: red; }")
        let r = t.render(fields)
        XCTAssertEqual(r.front, "<p class='q'>学而时习之</p>")
        XCTAssertEqual(r.back, "<b>时</b>：按时")
        XCTAssertEqual(t.css, ".q { color: red; }")
        let data = try JSONEncoder().encode(t)
        XCTAssertEqual(try JSONDecoder().decode(NoteTemplate.self, from: data), t)
        // 旧数据没有 html 也能读
        let old = #"{"name":"旧","fieldNames":["a"],"front":[0],"back":[],"collapsed":[],"isCloze":false}"#
        XCTAssertNil(try JSONDecoder().decode(NoteTemplate.self, from: Data(old.utf8)).html)
    }

    func testProtobufStrings() {
        // 字段 1（varint 1）、字段 2（"{{Front}}"）、字段 3（"b"）、字段 4（固定 32 位）
        var d = Data([0x08, 0x01])
        let q = Array("{{Front}}".utf8), a = Array("{{FrontSide}}<hr id=answer>{{Back}}".utf8)
        d.append(contentsOf: [0x0A, UInt8(q.count)] + q)
        d.append(contentsOf: [0x12, UInt8(a.count)] + a)
        d.append(contentsOf: [0x1D, 1, 2, 3, 4])
        d.append(contentsOf: [0x1A, 1, 0x62])
        let s = AnkiProtobuf.strings(d)
        XCTAssertEqual(s[1], "{{Front}}")
        XCTAssertEqual(s[2], "{{FrontSide}}<hr id=answer>{{Back}}")
        XCTAssertEqual(s[3], "b")
        XCTAssertTrue(AnkiProtobuf.strings(Data([0x0A, 0x50, 0x41])).isEmpty, "长度超出不出错")
    }
}
