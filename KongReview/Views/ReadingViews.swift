import SwiftUI
import KongReviewCore

// MARK: - 4.2.0：书架、书页上的阅读状态、进度与读书记录、首页“在读”

extension SourceReading.Status {
    var color: Color {
        switch self {
        case .want: ReviewPalette.sub
        case .reading: ReviewPalette.accent
        case .finished: ReviewPalette.done
        case .paused: ReviewPalette.sub
        }
    }
}

/// 日期键（yyyy-MM-dd）→“今天”“昨天”“10月18日”
func readingDayText(_ key: String?, today: Date = Date()) -> String {
    guard let key else { return "" }
    if key == ReminderPlan.dayKey(today) { return "今天" }
    if let y = Calendar.current.date(byAdding: .day, value: -1, to: today), key == ReminderPlan.dayKey(y) { return "昨天" }
    let parts = key.split(separator: "-")
    guard parts.count == 3, let m = Int(parts[1]), let d = Int(parts[2]) else { return key }
    return "\(m)月\(d)日"
}

/// 进度条
struct ReadingProgressBar: View {
    let fraction: Double?
    var width: CGFloat = 160
    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(ReviewPalette.hair).frame(width: width, height: 6)
            if let f = fraction { Capsule().fill(ReviewPalette.accent).frame(width: max(4, width * f), height: 6) }
        }
        .frame(width: width, height: 6)
        .accessibilityLabel(fraction.map { "进度 \(Int(($0 * 100).rounded()))%" } ?? "进度未知")
    }
}

/// 改状态的菜单项（书架、书页、出处管理共用）
struct ReadingStatusMenuItems: View {
    @Environment(LibraryStore.self) private var store
    let sourceId: Int64
    var body: some View {
        let current = store.readings[sourceId]?.status
        ForEach(SourceReading.Status.allCases) { s in
            Button {
                store.setReadingStatus(sourceId, s)
            } label: {
                if s == current { Label(s.title, systemImage: "checkmark") }
                else { Text(s == .reading && current == .finished ? "重读（回到在读）" : s.title) }
            }
        }
        if current != nil {
            Divider()
            Button("进度与计划…") { store.readingEditor = ReadingEditRequest(sourceId: sourceId) }
            Button("记一笔…") { store.readingLogRequest = ReadingLogRequest(sourceId: sourceId) }
            Divider()
            Button("移出书架（读书记录保留）", role: .destructive) { store.setReadingStatus(sourceId, nil) }
        }
    }
}

// MARK: 书架

struct BookshelfView: View {
    @Environment(LibraryStore.self) private var store
    @State private var items: [ShelfItem] = []
    @State private var query = ""
    @State private var depth: SourceReading.Depth?
    @State private var projectID: Int64?
    @State private var adding = false

    var body: some View {
        let shown = filtered
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("书架").font(.system(size: 26, weight: .semibold, design: .serif)).foregroundStyle(ReviewPalette.ink)
                    Text("加入书架的书按想读、在读、读完、搁置排列。录入摘录时，页码超过当前进度会自动往前推；每天读了什么，在书页上“记一笔”。")
                        .font(.system(size: 13)).foregroundStyle(ReviewPalette.sub).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 10) {
                    Button { adding = true } label: { Label("加入书架…", systemImage: "plus") }
                        .buttonStyle(.borderedProminent).handCursor()
                    TextField("搜索书名、作者（繁简通搜）", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                    Spacer()
                    Menu {
                        Button("全部读法") { depth = nil }
                        Divider()
                        ForEach(SourceReading.Depth.allCases) { d in
                            Button { depth = d } label: { if d == depth { Label(d.title, systemImage: "checkmark") } else { Text(d.title) } }
                        }
                    } label: { Label(depth?.title ?? "读法", systemImage: "eyeglasses") }
                        .menuStyle(.borderlessButton).fixedSize()
                    Menu {
                        Button("全部项目") { projectID = nil }
                        Divider()
                        ForEach(store.researchProjects) { p in
                            Button { projectID = p.id } label: { if p.id == projectID { Label(p.title, systemImage: "checkmark") } else { Text(p.title) } }
                        }
                    } label: { Label(projectID.flatMap { id in store.researchProjects.first { $0.id == id }?.title } ?? "按项目", systemImage: "folder") }
                        .menuStyle(.borderlessButton).fixedSize()
                }
                .font(.system(size: 12.5))
                if items.isEmpty {
                    ContentUnavailableView("书架还是空的", systemImage: "books.vertical",
                                           description: Text("点“加入书架”，从已有的出处里挑出想读、在读的书；也可在出处书页、出处管理里加入。"))
                        .frame(maxWidth: .infinity, minHeight: 220)
                } else if shown.isEmpty {
                    Text("没有符合条件的书。").foregroundStyle(ReviewPalette.sub)
                }
                ForEach(SourceReading.Status.allCases.sorted { $0.order < $1.order }) { status in
                    let group = shown.filter { $0.reading.status == status }
                    if !group.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("\(status.title) · \(group.count)").font(.system(size: 13, weight: .semibold)).foregroundStyle(ReviewPalette.sub)
                            ForEach(group) { item in ShelfRow(item: item) }
                        }
                    }
                }
            }
            .frame(maxWidth: 860, alignment: .leading)
            .padding(.horizontal, 28).padding(.vertical, 32)
            .frame(maxWidth: .infinity)
        }
        .background(ReviewPalette.page)
        .navigationTitle("书架")
        .task(id: "\(store.readingRevision)|\(store.revision)") { items = (try? await store.db.shelf()) ?? [] }
        .sheet(isPresented: $adding) { AddToShelfSheet().environment(store) }
    }

    private var filtered: [ShelfItem] {
        let key = ChineseFold.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        let projectSources: Set<Int64>? = projectID.map { pid in
            Set(((try? store.db.researchProjectLinks(projectId: pid)) ?? []).filter { $0.kind == .source }.map(\.recordId))
        }
        return items.filter { item in
            (key.isEmpty || ChineseFold.fold(item.source.title + " " + item.source.author).contains(key))
                && (depth == nil || item.reading.depth == depth)
                && (projectSources == nil || projectSources!.contains(item.id))
        }
        .sorted { a, b in
            switch a.reading.status {
            case .reading: return (a.lastReadDay ?? "", a.reading.updatedAt) > (b.lastReadDay ?? "", b.reading.updatedAt)
            case .finished: return (a.reading.finishedAt ?? .distantPast) > (b.reading.finishedAt ?? .distantPast)
            default: return a.reading.updatedAt > b.reading.updatedAt
            }
        }
    }
}

struct ShelfRow: View {
    @Environment(LibraryStore.self) private var store
    let item: ShelfItem
    var body: some View {
        let r = item.reading
        HStack(alignment: .top, spacing: 12) {
            SourceThumb(source: item.source, size: CGSize(width: 34, height: 46))
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("《\(item.source.title)》").font(.system(size: 15, weight: .semibold, design: .serif)).foregroundStyle(ReviewPalette.ink).lineLimit(2)
                    if !item.source.author.isEmpty { Text(item.source.author).font(.system(size: 12.5)).foregroundStyle(ReviewPalette.sub).lineLimit(1) }
                    if let d = r.depth { Text(d.title).font(.system(size: 11)).padding(.horizontal, 6).padding(.vertical, 1).background(ReviewPalette.soft, in: Capsule()).foregroundStyle(ReviewPalette.sub) }
                }
                switch r.status {
                case .reading, .paused:
                    HStack(spacing: 10) {
                        ReadingProgressBar(fraction: r.fraction())
                        Text([r.progressText, item.lastReadDay.map { "上次 " + readingDayText($0) }, r.pagesPerDay(today: Date()).map { "每天约 \($0) 页" }]
                                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.system(size: 11.5).monospacedDigit()).foregroundStyle(ReviewPalette.sub)
                    }
                case .want:
                    if !r.reason.isEmpty { Text("为什么读：" + r.reason).font(.system(size: 12)).foregroundStyle(ReviewPalette.sub).lineLimit(2) }
                case .finished:
                    Text([r.finishedAt.map { "\($0.formatted(.dateTime.year().month().day()))读完" }, r.rereads > 0 ? "读过 \(r.rereads + 1) 遍" : nil]
                            .compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 11.5)).foregroundStyle(ReviewPalette.sub)
                }
                Text("摘录 \(item.highlightCount) 条").font(.system(size: 11)).foregroundStyle(ReviewPalette.sub)
            }
            Spacer(minLength: 8)
            Menu { ReadingStatusMenuItems(sourceId: item.id) } label: {
                Label(r.status.title, systemImage: r.status.symbol).font(.system(size: 12))
            }
            .menuStyle(.borderlessButton).fixedSize().foregroundStyle(r.status.color)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(ReviewPalette.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(ReviewPalette.hair))
        .contentShape(Rectangle())
        .onTapGesture { store.selection = .source(item.id) }
        .handCursor()
    }
}

/// 加入书架：从已有出处里挑（可多选），一并设成想读、在读或读完
struct AddToShelfSheet: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var chosen: [Int64] = []
    @State private var status: SourceReading.Status = .want

    var body: some View {
        let key = ChineseFold.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        let candidates = store.sources.filter { s in
            guard let id = s.id, store.readings[id] == nil else { return false }
            return key.isEmpty || ChineseFold.fold(s.title + " " + s.author).contains(key)
        }.prefix(200)
        VStack(alignment: .leading, spacing: 12) {
            Text("加入书架").font(.title2.bold())
            TextField("搜索出处的书名、作者", text: $query).textFieldStyle(.roundedBorder)
            List(Array(candidates)) { s in
                let id = s.id ?? -1
                Button {
                    if let i = chosen.firstIndex(of: id) { chosen.remove(at: i) } else { chosen.append(id) }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: chosen.contains(id) ? "checkmark.circle.fill" : "circle").foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("《\(s.title)》").font(.system(size: 13.5))
                            Text([s.author, s.kind.label].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain).handCursor()
            }
            .frame(minHeight: 280)
            HStack {
                Picker("加入后", selection: $status) {
                    ForEach([SourceReading.Status.want, .reading, .finished]) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).fixedSize()
                Text(chosen.isEmpty ? "可多选" : "已选 \(chosen.count) 本").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("加入") { store.addToShelf(chosen, status: status); dismiss() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent).disabled(chosen.isEmpty)
            }
            Text("新的书先在“出处管理”或录入摘录时建出处，再加入书架。").font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(minWidth: 560, idealWidth: 640, minHeight: 480)
    }
}

// MARK: 书页上的阅读状态

/// 出处书页头的一行：状态、进度、记一笔
struct SourceReadingBar: View {
    @Environment(LibraryStore.self) private var store
    let sourceId: Int64
    var chapterTotal: Int? = nil

    var body: some View {
        if let r = store.readings[sourceId] {
            HStack(spacing: 10) {
                Menu { ReadingStatusMenuItems(sourceId: sourceId) } label: {
                    Label(r.status.title, systemImage: r.status.symbol).font(.system(size: 12.5, weight: .medium))
                }
                .menuStyle(.borderlessButton).fixedSize().foregroundStyle(r.status.color)
                if r.status != .want || r.fraction(chapterTotal: chapterTotal) != nil {
                    ReadingProgressBar(fraction: r.fraction(chapterTotal: chapterTotal), width: 120)
                }
                Text(summary(r)).font(.system(size: 12).monospacedDigit()).foregroundStyle(ReviewPalette.sub).lineLimit(1)
                Button("记一笔…") { store.readingLogRequest = ReadingLogRequest(sourceId: sourceId) }
                    .buttonStyle(.link).font(.system(size: 12)).handCursor()
                    .help("记下今天读了哪几页、读了多久；读书天数与页数进入学习小结")
                Button("进度…") { store.readingEditor = ReadingEditRequest(sourceId: sourceId) }
                    .buttonStyle(.link).font(.system(size: 12)).handCursor()
            }
        } else {
            Menu {
                ForEach([SourceReading.Status.want, .reading, .finished]) { s in
                    Button(s.title) { store.setReadingStatus(sourceId, s) }
                }
            } label: { Label("加入书架", systemImage: "books.vertical").font(.system(size: 12.5)) }
                .menuStyle(.borderlessButton).fixedSize()
                .help("设为想读、在读或读完：记进度、记读书，读完时写提要")
        }
    }

    private func summary(_ r: SourceReading) -> String {
        var parts: [String] = []
        if let n = chapterTotal, n > 0, !r.chaptersRead.isEmpty, r.currentPage == nil, r.percent == nil {
            parts.append("已读 \(r.chaptersRead.count)／\(n) 篇")
        } else if !r.progressText.isEmpty {
            parts.append(r.progressText)
        }
        switch r.status {
        case .finished: if let f = r.finishedAt { parts.append("\(f.formatted(.dateTime.year().month().day()))读完") }
        case .reading: if let p = r.pagesPerDay(today: Date()) { parts.append("每天约 \(p) 页") }
        case .want: if !r.reason.isEmpty { parts.append("为什么读：" + r.reason) }
        case .paused: break
        }
        if let d = r.depth { parts.append(d.title) }
        if r.rereads > 0 { parts.append("第 \(r.rereads + 1) 遍") }
        return parts.joined(separator: " · ")
    }
}

/// 进度与计划
struct ReadingEditSheet: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let request: ReadingEditRequest
    @State private var r: SourceReading?
    @State private var current = ""
    @State private var total = ""
    @State private var percent = ""
    @State private var hasTarget = false
    @State private var target = Date().addingTimeInterval(30 * 86_400)
    @State private var chapters: [String] = []

    var body: some View {
        let source = store.sources.first { $0.id == request.sourceId }
        VStack(alignment: .leading, spacing: 14) {
            Text("《\(source?.title ?? "")》的进度与计划").font(.title2.bold()).lineLimit(2)
            if r != nil {
                Form {
                    Picker("读法", selection: Binding(get: { r?.depth }, set: { r?.depth = $0 })) {
                        Text("未定").tag(SourceReading.Depth?.none)
                        ForEach(SourceReading.Depth.allCases) { Text($0.title).tag(SourceReading.Depth?.some($0)) }
                    }
                    .pickerStyle(.segmented)
                    if source?.kind == .article || source?.kind == .web {
                        TextField("读到（%）", text: $percent)
                    } else {
                        TextField("读到第几页", text: $current)
                        TextField("全书页数", text: $total)
                    }
                    Toggle("计划读完的日期", isOn: $hasTarget)
                    if hasTarget { DatePicker("日期", selection: $target, displayedComponents: .date) }
                    TextField("为什么要读（一句）", text: Binding(get: { r?.reason ?? "" }, set: { r?.reason = $0 }))
                }
                if !chapters.isEmpty {
                    Text("已读篇目（按摘录位置里的篇名）").font(.system(size: 12.5, weight: .medium))
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), alignment: .leading)], alignment: .leading, spacing: 6) {
                            ForEach(chapters, id: \.self) { name in
                                Toggle(name, isOn: Binding(get: { r?.chaptersRead.contains(name) == true }, set: { on in
                                    if on { if r?.chaptersRead.contains(name) == false { r?.chaptersRead.append(name) } }
                                    else { r?.chaptersRead.removeAll { $0 == name } }
                                }))
                                .toggleStyle(.checkbox).font(.system(size: 12.5))
                            }
                        }
                    }
                    .frame(maxHeight: 160)
                }
                Text("页码超过当前进度时会自动记一笔；想读的书改了进度即转为在读。").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { save() }.keyboardShortcut(.return, modifiers: .command).buttonStyle(.borderedProminent).disabled(r == nil)
            }
        }
        .padding(24)
        .frame(minWidth: 480, idealWidth: 560, minHeight: 380)
        .onAppear {
            let loaded = store.readings[request.sourceId] ?? SourceReading(sourceId: request.sourceId, status: .want)
            r = loaded
            current = loaded.currentPage.map(String.init) ?? ""
            total = loaded.totalPages.map(String.init) ?? ""
            percent = loaded.percent.map { String(Int($0.rounded())) } ?? ""
            hasTarget = loaded.targetDate != nil
            if let t = loaded.targetDate { target = t }
            if source?.isClassic == true { chapters = ((try? store.db.chapterProgress(request.sourceId)) ?? []).map(\.name) }
        }
    }

    private func save() {
        guard var value = r else { return }
        value.currentPage = Int(current.trimmingCharacters(in: .whitespaces))
        value.totalPages = Int(total.trimmingCharacters(in: .whitespaces)).flatMap { $0 > 0 ? $0 : nil }
        value.percent = Double(percent.trimmingCharacters(in: .whitespaces)).map { min(100, max(0, $0)) }
        value.targetDate = hasTarget ? target : nil
        if store.saveReading(value) { store.readingEditor = nil; dismiss() }
    }
}

/// 记一笔：哪天、从第几页读到第几页、读了多久、一句话；下方列出最近的记录
struct ReadingLogSheet: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let request: ReadingLogRequest
    @State private var sourceId: Int64?
    @State private var day = Date()
    @State private var from = ""
    @State private var to = ""
    @State private var minutes = ""
    @State private var note = ""
    @State private var logs: [ReadingLog] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("记一笔").font(.title2.bold())
            Form {
                Picker("书", selection: $sourceId) {
                    Text("请选择").tag(Int64?.none)
                    ForEach(choices, id: \.id) { s in Text("《\(s.title)》").tag(s.id) }
                }
                DatePicker("日期", selection: $day, in: ...Date(), displayedComponents: .date)
                HStack {
                    TextField("从第几页", text: $from)
                    TextField("读到第几页", text: $to)
                }
                TextField("读了多少分钟（可不填）", text: $minutes)
                TextField("一句话（可不填）", text: $note)
            }
            if !logs.isEmpty {
                Text("最近的记录").font(.system(size: 12.5, weight: .medium))
                List(logs) { log in
                    HStack(spacing: 8) {
                        Text(readingDayText(log.day)).frame(width: 64, alignment: .leading)
                        Text(pagesText(log)).foregroundStyle(.secondary)
                        if let m = log.minutes { Text("\(m) 分钟").foregroundStyle(.secondary) }
                        Text(log.note).lineLimit(1)
                        Spacer()
                        if log.origin != .manual { Text("自动").font(.caption).foregroundStyle(.secondary) }
                        Button { if let id = log.id { store.deleteReadingLog(id); reload() } } label: { Image(systemName: "trash") }
                            .buttonStyle(.plain).foregroundStyle(.secondary).handCursor()
                    }
                    .font(.system(size: 12.5).monospacedDigit())
                }
                .frame(minHeight: 120, maxHeight: 180)
            }
            HStack {
                Text("止页超过当前进度时，进度随之前移。").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消", role: .cancel) { close() }.keyboardShortcut(.cancelAction)
                Button("记下") {
                    guard let sid = sourceId else { return }
                    if store.logReading(sourceId: sid, day: day, fromPage: Int(from), toPage: Int(to), minutes: Int(minutes), note: note) { close() }
                }
                .keyboardShortcut(.return, modifiers: .command).buttonStyle(.borderedProminent).disabled(sourceId == nil)
            }
        }
        .padding(24)
        .frame(minWidth: 520, idealWidth: 580, minHeight: 420)
        .onAppear {
            sourceId = request.sourceId ?? store.currentReads(limit: 1).first?.source.id
            if let sid = sourceId, let p = store.readings[sid]?.currentPage { from = String(p) }
            reload()
        }
        .onChange(of: sourceId) { _, _ in reload() }
    }

    private var choices: [Source] {
        let shelf = Set(store.readings.keys)
        let onShelf = store.sources.filter { s in s.id.map { shelf.contains($0) } ?? false }
        if let sid = request.sourceId, !shelf.contains(sid), let s = store.sources.first(where: { $0.id == sid }) { return [s] + onShelf }
        return onShelf
    }

    private func pagesText(_ log: ReadingLog) -> String {
        switch (log.fromPage, log.toPage) {
        case let (f?, t?) where f != t: return "第 \(f)–\(t) 页"
        case let (_, t?): return "读到第 \(t) 页"
        default: return log.percent.map { "\(Int($0))%" } ?? "读过"
        }
    }

    private func reload() { logs = sourceId.flatMap { try? store.db.readingLogs(sourceId: $0, limit: 20) } ?? [] }

    private func close() {
        store.readingLogRequest = nil
        dismiss()
    }
}

// MARK: 首页“在读”

struct HomeReadingCard: View {
    @Environment(LibraryStore.self) private var store
    var body: some View {
        let reads = store.currentReads()
        if !reads.isEmpty {
            let today = ReminderPlan.dayKey(Date())
            let readToday = (try? store.db.writer.read { db in
                try Set(Int64.fetchAll(db, sql: "SELECT DISTINCT sourceId FROM reading_log WHERE day = ?", arguments: [today]))
            }) ?? []
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("在读", systemImage: "book").font(.system(size: 13, weight: .semibold)).foregroundStyle(ReviewPalette.accent)
                    Spacer()
                    Button("书架") { store.selection = .bookshelf }.buttonStyle(.link).font(.system(size: 12)).handCursor()
                }
                ForEach(reads) { item in
                    HStack(spacing: 12) {
                        Button("《\(item.source.title)》") { store.selection = .source(item.reading.sourceId) }
                            .buttonStyle(.plain).font(.system(size: 14, weight: .semibold, design: .serif)).foregroundStyle(ReviewPalette.ink)
                            .lineLimit(1).handCursor()
                        Spacer(minLength: 8)
                        ReadingProgressBar(fraction: item.reading.fraction(), width: 110)
                        Text([item.reading.progressText, item.reading.pagesPerDay(today: Date()).map { "每天约 \($0) 页" }]
                                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.system(size: 11.5).monospacedDigit()).foregroundStyle(ReviewPalette.sub).lineLimit(1)
                        if readToday.contains(item.reading.sourceId) {
                            Label("今天读过", systemImage: "checkmark").font(.system(size: 11.5)).foregroundStyle(ReviewPalette.done)
                        } else {
                            Button("今天读了") { store.markReadToday(item.reading.sourceId) }
                                .controlSize(.small).handCursor()
                                .help("不填页码，只记下今天读过；要记页码就到书页上“记一笔”")
                        }
                    }
                }
            }
            .padding(16)
            .background(ReviewPalette.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(ReviewPalette.hair))
        }
    }
}
