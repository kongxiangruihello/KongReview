import SwiftUI
import KongReviewCore

// MARK: - 1.1：标签整理

/// 侧边栏里的一个标签行（分层显示时只显示本层名字，悬停看完整路径）
struct TagSidebarRow: View {
    @Environment(LibraryStore.self) private var store
    let node: TagNode

    var body: some View {
        HStack {
            Label(node.name, systemImage: "number")
                .lineLimit(1)
            Spacer()
            SidebarCount(node.count)
        }
        .help(node.path)
        .tag(SidebarItem.tag(node.path))
        .contextMenu {
            Button("改名或合并…") { store.beginRenameTag(node.path) }
            Button("删除标签…", role: .destructive) { store.beginDeleteTag(node.path) }
            Divider()
            Button("整理全部标签…") { store.showTagManager = true }
        }
    }
}

/// 改名 / 合并 / 删除一个标签
struct TagEditView: View {
    @Environment(LibraryStore.self) private var store

    var body: some View {
        if let req = store.tagEditor {
            content(req)
        } else {
            Color.clear.frame(width: 1, height: 1)
        }
    }

    private func content(_ req: TagEditRequest) -> some View {
        let target = TagOps.normalize(req.newName)
        let merging = req.mode == .rename && target != req.tag && store.tags.contains(target)
        let hasChildren = store.tags.contains { $0.hasPrefix(req.tag + "/") }
        return VStack(alignment: .leading, spacing: 14) {
            Text(req.mode == .delete ? "删除标签 #\(req.tag)" : "标签改名或合并").font(.title2.bold())

            if req.mode == .rename {
                TextField("新名称", text: Binding(
                    get: { store.tagEditor?.newName ?? "" },
                    set: { store.tagEditor?.newName = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .onSubmit { commit(req) }

                Menu("合并到已有标签") {
                    ForEach(store.tags.filter { $0 != req.tag && !TagOps.isWithin($0, req.tag) }, id: \.self) { t in
                        Button("#\(t)") { store.tagEditor?.newName = t }
                    }
                }
                .fixedSize()

                VStack(alignment: .leading, spacing: 4) {
                    Text("将改动 \(req.affected) 条摘录。用“/”分层，如“儒家/孟子”。")
                    if merging { Text("“\(target)”已存在：两个标签会合并成一个。").foregroundStyle(.orange) }
                    if hasChildren { Text("其下的子标签一并改名（如 \(req.tag)/… → \(target.isEmpty ? "…" : target)/…）。") }
                    Text("已存搜索里的这个标签也会跟着改。可用 ⌘Z 撤销。")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("从 \(req.affected) 条摘录上去掉这个标签\(hasChildren ? "（连同其下的子标签）" : "")。摘录本身不会删除。可用 ⌘Z 撤销。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("取消", role: .cancel) { store.tagEditor = nil }
                    .keyboardShortcut(.cancelAction)
                if req.mode == .delete {
                    Button("删除标签", role: .destructive) { commit(req) }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(merging ? "合并" : "改名") { commit(req) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(target.isEmpty || target == req.tag)
                }
            }
        }
        .padding(22)
        .frame(width: 420)
    }

    private func commit(_ req: TagEditRequest) {
        guard let cur = store.tagEditor else { return }
        store.tagEditor = nil
        switch req.mode {
        case .rename: store.renameTag(cur.tag, to: cur.newName)
        case .delete: store.deleteTag(cur.tag)
        }
    }
}

/// 整理全部标签：按层级列出，带摘录数；可改名、合并、删除
struct TagManagerView: View {
    @Environment(LibraryStore.self) private var store

    private struct Row: Identifiable {
        var path: String
        var depth: Int
        var name: String
        var own: Int
        var total: Int
        var id: String { path }
    }

    private func flatten(_ nodes: [TagNode], depth: Int = 0) -> [Row] {
        nodes.flatMap { n in
            [Row(path: n.path, depth: depth, name: n.name, own: n.ownCount, total: n.count)] + flatten(n.children, depth: depth + 1)
        }
    }

    var body: some View {
        let rows = flatten(store.tagTree)
        let similar = Self.similarPairs(store.tags)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("整理标签").font(.title2.bold())
                Spacer()
                Text("\(store.tags.count) 个标签").foregroundStyle(.secondary)
            }
            if !similar.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label("可能重复的标签", systemImage: "exclamationmark.triangle").font(.headline)
                    ForEach(similar) { pair in
                        let a = pair.keep, b = pair.other
                        HStack {
                            Text("#\(a)　#\(b)")
                            Spacer()
                            Button("把 #\(b) 并入 #\(a)") { store.renameTag(b, to: a) }
                                .buttonStyle(.link)
                                .handCursor()
                        }
                        .font(.callout)
                    }
                }
                .padding(10)
                .background(ReviewPalette.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            List {
                ForEach(rows) { r in
                    HStack(spacing: 6) {
                        Text("#").foregroundStyle(.tertiary)
                        Text(r.name).lineLimit(1)
                        Spacer()
                        Text(r.own == r.total ? "\(r.total)" : "\(r.own) / 共 \(r.total)")
                            .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                        Button("改名…") { store.beginRenameTag(r.path) }.buttonStyle(.link)
                        Button("删除…") { store.beginDeleteTag(r.path) }.buttonStyle(.link).foregroundStyle(.red)
                    }
                    .padding(.leading, CGFloat(r.depth) * 16)
                    .help(r.path)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .frame(minHeight: 320)
            Text("提示：给标签加“/”即可分层，如把 #孟子 改名为 #儒家/孟子；选中父标签时会列出其下全部摘录。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("完成") { store.showTagManager = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 560)
    }

    /// 只差大小写、全半角或空格的标签对（繁简不同的如“论语”“論語”不自动识别，需自己合并）
    struct SimilarPair: Identifiable {
        var keep: String
        var other: String
        var id: String { keep + "\u{1}" + other }
    }

    static func similarPairs(_ tags: [String]) -> [SimilarPair] {
        var seen: [String: String] = [:]
        var out: [SimilarPair] = []
        for t in tags {
            let key = t.folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive], locale: nil)
                .replacingOccurrences(of: " ", with: "")
            if let first = seen[key] { out.append(SimilarPair(keep: first, other: t)) } else { seen[key] = t }
        }
        return out
    }
}

/// 标签相关的面板（单独成修饰器，避免主视图修饰链过长）
struct TagSheets: ViewModifier {
    @Environment(LibraryStore.self) private var store

    func body(content: Content) -> some View {
        @Bindable var store = store
        return content
            .sheet(isPresented: $store.showTagManager) {
                TagManagerView()
                    .sheet(item: $store.tagEditor) { _ in TagEditView() }
            }
            .sheet(item: Binding(
                get: { store.showTagManager ? nil : store.tagEditor },
                set: { store.tagEditor = $0 }
            )) { _ in
                TagEditView()
            }
    }
}
