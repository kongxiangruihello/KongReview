import SwiftUI

/// Reusable by formal study and disposable extra practice. The caller owns flipping
/// and formal rating; this panel only edits the session's scratchpad.
struct CardSelfAnswerPanel: View {
    @Binding var draft: CardSelfAnswerDraft
    let showingAnswer: Bool
    let referenceHTML: String
    var slot = "self-answer"
    var allowsAssessment = false
    /// 3.15.1：作答后点“对照参考答案”才显示参考答案；空格不再翻面
    var onReveal: (() -> Void)? = nil
    /// 新卡出现时把光标放进“我的回答”，按键直接写进回答框
    var focusOnAppear = true
    var onEditingChanged: (Bool) -> Void = { _ in }
    @FocusState private var editing: Bool
    @State private var availableWidth: CGFloat = 0

    private var answerLayout: AnyLayout {
        if showingAnswer && availableWidth >= 660 {
            return AnyLayout(HStackLayout(alignment:.top,spacing:14))
        }
        return AnyLayout(VStackLayout(alignment:.leading,spacing:14))
    }

    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            // Keep one editor and one reference web view alive. Measuring two
            // ViewThatFits candidates would make different web-view widths fight
            // over the same measured-height slot and continuously relayout.
            answerLayout {
                answerColumn.frame(maxWidth:.infinity,alignment:.leading)
                if showingAnswer {
                    referenceColumn.frame(maxWidth:.infinity,alignment:.leading)
                }
            }
            if !showingAnswer {
                HStack(spacing:12) {
                    if let onReveal {
                        Button {
                            editing = false
                            onReveal()
                        } label: {
                            Label("对照参考答案",systemImage:"eye")
                                .padding(.horizontal,6).padding(.vertical,2)
                        }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .keyboardShortcut(.return,modifiers:.command)
                        .handCursor()
                        .help("写完回答后点此显示参考答案（⌘↩，回答框里打字时也可用）")
                        .accessibilityIdentifier("card-self-answer-reveal")
                    }
                    Text(draft.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty
                         ? "参考答案已遮住。先写下自己的回答，写完点“对照参考答案”（⌘↩）；想不起来也可以直接对照。"
                         : "写完了就点“对照参考答案”（⌘↩）。不会自动判定对错。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal:false,vertical:true)
                }
            }
            if showingAnswer && allowsAssessment {
                HStack {
                    Text("本次自评").font(.caption).foregroundStyle(.secondary)
                    ForEach(CardSelfAssessment.allCases) { value in
                        Button(value.title) { draft.assessment = draft.assessment == value ? nil : value }
                            .tint(draft.assessment == value ? .accentColor : .secondary)
                            .buttonStyle(.bordered).handCursor()
                    }
                }
                Text("自评只保留在本次练习中；不改变正式复习排程或统计。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth:.infinity,alignment:.leading)
        .background {
            GeometryReader { geometry in
                Color.clear.preference(key:CardSelfAnswerWidthKey.self,value:geometry.size.width)
            }
        }
        .onPreferenceChange(CardSelfAnswerWidthKey.self) { width in
            guard width.isFinite,width > 0,abs(availableWidth - width) > 1 else { return }
            availableWidth = width
        }
        .onChange(of:editing) { _,value in onEditingChanged(value) }
        // 对照后交出键盘：数字键 1–4 直接评分；要补写回答，再点回答框即可
        .onChange(of:showingAnswer) { _,shown in if shown { editing = false } }
        .onAppear {
            guard focusOnAppear,!showingAnswer else { return }
            DispatchQueue.main.async { editing = true }
        }
        .onDisappear { onEditingChanged(false) }
    }

    private var answerColumn: some View {
        VStack(alignment:.leading,spacing:6) {
            Text("我的回答").font(.headline)
            TextEditor(text:$draft.text).font(.body).focused($editing)
                .frame(minHeight:120,idealHeight:160,maxHeight:220)
                .padding(6).background(.background,in:RoundedRectangle(cornerRadius:8))
                .overlay { RoundedRectangle(cornerRadius:8).stroke(.quaternary) }
                .accessibilityLabel("我的回答，仅本次会话")
                .accessibilityIdentifier("card-self-answer-input")
        }
    }

    private var referenceColumn: some View {
        VStack(alignment:.leading,spacing:6) {
            Text("参考答案").font(.headline)
            RichWebText(text:referenceHTML,slot:slot + "-reference")
                .frame(maxWidth:.infinity,alignment:.leading)
                .padding(10).background(.quaternary.opacity(0.3),in:RoundedRectangle(cornerRadius:8))
        }
    }
}

private struct CardSelfAnswerWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value,nextValue()) }
}
