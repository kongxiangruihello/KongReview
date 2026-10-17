import SwiftUI
import KongReviewCore

/// 按字符映射繁简折叠后的命中位置，不把查询当正则表达式。
enum KeywordHighlight {
    static func ranges(in text: String, query: String) -> [Range<String.Index>] {
        let needle = ChineseFold.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !needle.isEmpty else { return [] }
        var folded = "", starts: [String.Index] = [], ends: [String.Index] = []
        for index in text.indices {
            let end = text.index(after: index)
            let part = ChineseFold.fold(String(text[index..<end]))
            folded += part
            starts += Array(repeating: index, count: part.utf16.count)
            ends += Array(repeating: end, count: part.utf16.count)
        }
        let ns = folded as NSString
        var offset = 0, result: [Range<String.Index>] = []
        while offset < ns.length {
            let found = ns.range(of: needle, range: NSRange(location: offset, length: ns.length-offset))
            guard found.location != NSNotFound else { break }
            result.append(starts[found.location]..<ends[NSMaxRange(found)-1])
            offset = NSMaxRange(found)
        }
        return result
    }
    static func passages(_ text: String, query: String) -> [String] {
        text.components(separatedBy: .newlines).filter { !$0.isEmpty }.flatMap { paragraph -> [String] in
            let hits = ranges(in: paragraph, query: query)
            var start = paragraph.startIndex, pieces: [String] = []
            while start < paragraph.endIndex {
                var end = paragraph.index(start, offsetBy: 800, limitedBy: paragraph.endIndex) ?? paragraph.endIndex
                if let hit = hits.first(where: { $0.lowerBound < end && $0.upperBound > end }) { end = hit.upperBound }
                pieces.append(String(paragraph[start..<end])); start = end
            }
            return pieces
        }
    }
    static func attributed(_ text: String, query: String) -> AttributedString {
        var value = AttributedString(text)
        for range in ranges(in: text, query: query) {
            if let a = AttributedString.Index(range.lowerBound, within: value),
               let b = AttributedString.Index(range.upperBound, within: value) {
                value[a..<b].backgroundColor = .yellow.opacity(0.45)
                value[a..<b].foregroundColor = .primary
            }
        }
        return value
    }
}

struct LearningExplorerPresentation: ViewModifier {
    @Environment(LibraryStore.self) private var store
    func body(content: Content) -> some View {
        content.sheet(item: Binding(get: { store.learningExplorer }, set: { store.learningExplorer = $0 }), onDismiss: {
            if let target = store.learningExplorerPendingTarget {
                store.learningExplorerPendingTarget = nil
                store.openGlobalSearchResult(target)
            }
        }) { request in LearningExplorerView(initial: request.route) }
    }
}

struct LearningExplorerView: View {
    @Environment(LibraryStore.self) private var store
    let initial: LearningExplorerRoute
    @State private var route: LearningExplorerRoute?
    @State private var deck = ""
    @State private var page = 0
    @State private var result = LearningExplorerPage(rows: [], total: 0)
    @State private var error: String?
    @State private var loading = false
    @State private var document: ResolvedGlobalSearchTarget?
    @State private var practice = false
    @State private var showAnswer = false
    @State private var matchIndex = 0
    @State private var history: [LearningExplorerRoute] = []
    private var current: LearningExplorerRoute { route ?? initial }
    private var key: String { "\(current)|\(deck)|\(page)|\(store.revision)" }
    private var title: String {
        switch current {
        case .day: return "学习记录日历"
        case .difficult: return "难卡集中练习"
        case .related: return "关联记忆卡"
        case .document: return practice ? "额外练习 · 不改变排程" : "阅读与定位"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                if !history.isEmpty { Button("返回") { route = history.removeLast(); practice = false; page = 0 } }
                Text(title).font(.title2.bold())
                Spacer()
                Button("关闭") { store.learningExplorer = nil }.keyboardShortcut(.cancelAction)
            }
            switch current {
            case .day(let selected):
                LearningMonthPicker(selection: Binding(get: { selected }, set: { route = .day($0); page = 0 }))
                Text("当天的全部操作与评分记录；条目按当前内容打开，已删除条目保留历史。")
                    .font(.caption).foregroundStyle(.secondary)
            case .difficult:
                Picker("牌组", selection: $deck) {
                    Text("全部牌组").tag("")
                    ForEach(store.deckSummaryCache, id: \.name) { Text($0.name).tag($0.name) }
                }.onChange(of: deck) { _, _ in page = 0 }
                Text("近30天至少3次“重来”的卡片。额外练习只展示问答，不评分、不写学习记录、不改变排程；正式学习仍从牌组开始。")
                    .font(.callout).foregroundStyle(.secondary)
            default: EmptyView()
            }
            if loading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if let error { ContentUnavailableView(error, systemImage: "exclamationmark.triangle") }
            else if case .document(let target, let query) = current { documentBody(target, query: query) }
            else { rows }
        }
        .padding(22).frame(minWidth: 680, idealWidth: 800, minHeight: 640, idealHeight: 760)
        .task(id: key) { await load() }
    }
    private var rows: some View {
        VStack {
            if result.rows.isEmpty { ContentUnavailableView("暂无记录", systemImage: "tray") }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(result.rows) { row in
                        Button {
                            guard let target = row.target else { return }
                            let isPractice: Bool = { if case .difficult = current { return true }; return false }()
                            navigate(.document(target, "")); practice = isPractice
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(row.title).lineLimit(3)
                                Text(row.detail).font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
                        }.buttonStyle(.plain).disabled(row.target == nil).handCursor()
                    }
                }
            }
            HStack {
                Text("共 \(result.total) 项 · 第 \(page + 1) / \(max(1,(result.total+49)/50)) 页")
                Spacer()
                Button("上一页") { page -= 1 }.disabled(page == 0)
                Button("下一页") { page += 1 }.disabled((page+1)*50 >= result.total)
            }
        }
    }
    @ViewBuilder private func documentBody(_ target: GlobalSearchTarget, query: String) -> some View {
        if let document {
            if practice, case .card(let card) = document {
                ScrollView {
                    RichWebText(text: store.faces(of: card).front, slot: "extra-practice-front-\(card.id ?? 0)")
                    if showAnswer { Divider(); RichWebText(text: store.faces(of: card).back, slot: "extra-practice-back-\(card.id ?? 0)") }
                }
                Button(showAnswer ? "收起答案" : "显示答案") { showAnswer.toggle() }.keyboardShortcut(.space, modifiers: [])
            } else {
                let paragraphs = KeywordHighlight.passages(documentText(document), query: query)
                let matches = paragraphs.indices.filter { !KeywordHighlight.ranges(in: paragraphs[$0], query: query).isEmpty }
                HStack {
                    Text(query.isEmpty ? "完整文字内容" : "关键词：\(query) · \(matches.count) 个命中段落").font(.caption)
                    Spacer()
                    if !matches.isEmpty {
                        Button("上一处") { matchIndex = (matchIndex + matches.count - 1) % matches.count }
                        Button("下一处") { matchIndex = (matchIndex + 1) % matches.count }
                    }
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(paragraphs.indices, id: \.self) { i in
                                Text(KeywordHighlight.attributed(paragraphs[i], query: query)).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading).id(i)
                            }
                        }.padding(8)
                    }
                    .onAppear { if let first = matches.first { proxy.scrollTo(first, anchor: .top) } }
                    .onChange(of: matchIndex) { _, i in if matches.indices.contains(i) { proxy.scrollTo(matches[i], anchor: .top) } }
                }
            }
            Divider()
            HStack {
                Button("打开原条目／编辑") {
                    store.learningExplorerPendingTarget = target
                    store.learningExplorer = nil
                }
                if case .highlight(let h, _) = document, let id = h.id {
                    Button("查看关联记忆卡") { navigate(.related(id)) }
                    if let sid = h.sourceId { Button("查看出处") { navigate(.document(.init(kind: .source, recordID: sid), "")) } }
                }
                if case .card(let c) = document, let hid = c.highlightId {
                    Button("查看原摘录与出处") { navigate(.document(.init(kind: .highlight, recordID: hid), "")) }
                }
            }
        }
    }
    private func navigate(_ next: LearningExplorerRoute) {
        history.append(current); route = next; page = 0; matchIndex = 0; showAnswer = false; practice = false
    }
    private func load() async {
        loading = true; error = nil; document = nil
        do {
            if case .document(let target, _) = current {
                let value = try await store.db.resolveGlobalSearchTarget(target)
                try Task.checkCancellation()
                document = value
                if value == nil { error = "原条目已删除或不存在" }
            } else {
                let value = try await store.db.learningExplorerPage(current, deck: deck, offset: page*50)
                try Task.checkCancellation(); result = value
            }
            loading = false
        } catch is CancellationError { } catch { self.error = error.localizedDescription; loading = false }
    }
    private func documentText(_ value: ResolvedGlobalSearchTarget) -> String {
        func plain(_ raw: String) -> String { Markdown.plainText(fromHTML: Card.renderHTML(raw)) }
        switch value {
        case .highlight(let h, _): return ["原文",plain(h.text),"译文",plain(h.translation ?? ""),"按语",plain(h.note ?? ""),h.location ?? "",h.tags.joined(separator: " "),store.sources.first(where: { $0.id == h.sourceId })?.title ?? "",store.sources.first(where: { $0.id == h.sourceId })?.author ?? ""].joined(separator: "\n")
        case .card(let c): return ["牌组："+c.deck,"正面",plain(c.front),"背面",plain(c.back)] .joined(separator: "\n") + "\n" + (c.fields + (c.sections ?? []).map { $0.name+"\n"+$0.text }).map(plain).joined(separator: "\n") + "\n" + c.tags.joined(separator: " ")
        case .article(let a): return [a.title,a.author ?? "",a.siteName ?? "",a.url,a.excerpt ?? "",a.contentText.isEmpty ? plain(a.contentHTML) : a.contentText].joined(separator: "\n")
        case .source(let s): return [s.title,s.author,s.publisher ?? "",s.edition ?? "",s.year ?? "",s.container ?? "",s.classicTitle ?? "",s.isbn ?? "",s.url ?? ""].joined(separator: "\n")
        }
    }
}

struct LearningMonthPicker: View {
    @Binding var selection: Date
    private var calendar: Calendar { .current }
    private var start: Date { calendar.date(from: calendar.dateComponents([.year, .month], from: selection))! }
    private var leading: Int { (calendar.component(.weekday, from: start) - calendar.firstWeekday + 7) % 7 }
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Button("上个月") { selection = calendar.date(byAdding: .month, value: -1, to: start)! }
                Spacer()
                Text(start.formatted(.dateTime.year().month())).font(.headline)
                Spacer()
                Button("下个月") { selection = calendar.date(byAdding: .month, value: 1, to: start)! }
                Button("今天") { selection = Date() }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 4) {
                ForEach(0..<7, id: \.self) { i in
                    Text(["日","一","二","三","四","五","六"][(i + calendar.firstWeekday - 1) % 7])
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(0..<(leading + (calendar.range(of: .day, in: .month, for: start)?.count ?? 30)), id: \.self) { i in
                    if i < leading { Color.clear.frame(height: 28) }
                    else {
                        let date = calendar.date(byAdding: .day, value: i-leading, to: start)!
                        let selected = calendar.isDate(date, inSameDayAs: selection)
                        Button { selection = date } label: {
                            Text("\(i-leading+1)").monospacedDigit()
                                .frame(maxWidth: .infinity).frame(height: 28)
                                .background(selected ? Color.accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(calendar.isDateInToday(date) ? Color.accentColor : .clear))
                        }.buttonStyle(.plain).handCursor()
                            .accessibilityLabel(date.formatted(date: .complete, time: .omitted))
                    }
                }
            }
        }.padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }
}
