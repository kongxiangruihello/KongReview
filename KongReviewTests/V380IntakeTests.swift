import XCTest
import AppKit
import JavaScriptCore
import GRDB
import KongReviewCore
@testable import KongReview

@MainActor final class V380IntakeTests: XCTestCase {
    func testPasteChoicesAreScopedUndoableAndRejectStaleBinding() throws {
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:500,height:200),styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let view = HTMLSourceTextView(); window.contentView = view; window.makeFirstResponder(view); view.isRichText = false; view.isEditable = true; view.allowsUndo = true
        view.string = "<p>原文😀</p>"; let baseline = view.string
        let handle = RichEditorHandle(); handle.textView = view; var stored = baseline; handle.valueReader = { stored }
        let proposal = EditorPasteProposal(original:baseline,html:"<span style=\"font-size:30px;color:red\"><strong>粘贴</strong></span>",plain:"粘贴",source:true,selection:NSRange(location:3,length:2),baseline:baseline)
        handle.applyPaste(proposal,style:.clean) { XCTAssertTrue($0) }
        XCTAssertEqual(view.string,"<p><strong>粘贴</strong>😀</p>")
        view.undoManager?.undo(); XCTAssertEqual(view.string,baseline)
        stored = "新输入"
        handle.applyPaste(proposal,style:.keep) { XCTAssertFalse($0) }; XCTAssertEqual(view.string,baseline)
        XCTAssertEqual(proposal.fragment(.plain),"<p>粘贴</p>")
        XCTAssertTrue(proposal.fragment(.keep).contains("font-size:30px"))
    }
    func testAttributionRecognizesChineseAndWesternPagesWithoutRemovingBodyFormatting() throws {
        let source = "<p><strong>学习正文</strong>——钱穆《国史大纲》第12—14页</p>"
        let value = try XCTUnwrap(SourceAttributionRecognition.recognize(source))
        XCTAssertEqual(value.title,"国史大纲"); XCTAssertEqual(value.author,"钱穆"); XCTAssertEqual(value.location,"第12—14页")
        XCTAssertEqual(value.body,"<p><strong>学习正文</strong></p>")
        let west = try XCTUnwrap(SourceAttributionRecognition.recognize("some text\n--Author《Book》 P.23-24"))
        XCTAssertEqual(west.location,"P.23-24"); XCTAssertEqual(west.body,"some text\n")
        XCTAssertNil(SourceAttributionRecognition.recognize("——作者《书名》12页"))
        XCTAssertNil(SourceAttributionRecognition.recognize("正文提到《书名》，后面仍有论述"))
        XCTAssertNil(SourceAttributionRecognition.recognize("正文——作者《书名》第12页，后续正文"))
        let formatted = try XCTUnwrap(SourceAttributionRecognition.recognize("<p>正文——<b>作者</b>《书名》第12页</p>"))
        XCTAssertFalse(formatted.canRemove,"复杂引用不跨标签删正文")
    }
    func testOutlineUsesUTF16RangesAndIgnoresCodeExamples() throws {
        let source = "<h1>😀大标题</h1><p>正文</p><h3>子<em>标题</em></h3><pre><h2>示例</h2></pre>"
        let entries = EditorOutline.entries(source)
        XCTAssertEqual(entries.map(\.title),["😀大标题","子标题"]); XCTAssertEqual(entries.map(\.level),[1,3])
        XCTAssertEqual((source as NSString).substring(with:entries[1].range),"子<em>标题</em>")
    }
    func testMediaImportIsContentAddressedAndDoesNotOverwriteSharedMedia() async throws {
        let db = try AppDatabase(DatabaseQueue())
        let pixel = Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a1xoAAAAASUVORK5CYII=")!
        let file = try EditorMediaFile.make(data:pixel,extension:"PNG",for:"图片")
        XCTAssertEqual(file.mime,"image/png"); XCTAssertTrue(file.name.hasSuffix(".png"))
        XCTAssertThrowsError(try EditorMediaFile.make(data:Data("invalid".utf8),extension:"png",for:"图片"))
        XCTAssertThrowsError(try EditorMediaFile.make(data:pixel,extension:"png",for:"音频"))
        try db.saveMedia(["same.png":Data("original".utf8)])
        let source = "<p>保留<img src=\"same.png\"><img src=\"same.png\"></p>"
        let references = EditorResourceCheck.references(source) { _ in true }
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:500,height:200),styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false;defer { window.close() }
        let view = HTMLSourceTextView();window.contentView = view;window.makeFirstResponder(view);view.isRichText = false;view.isEditable = true;view.allowsUndo = true;view.string = source
        let handle = RichEditorHandle();handle.textView = view;handle.valueReader = { source }
        let done = expectation(description:"替换完成")
        handle.replaceMedia(references[0],in:source,baseline:source,file:file,db:db) { success in XCTAssertTrue(success); done.fulfill() }
        await fulfillment(of:[done],timeout:3)
        XCTAssertEqual(try db.media(named:"same.png"),Data("original".utf8))
        XCTAssertEqual(try db.media(named:file.name),pixel)
        XCTAssertTrue(view.string.contains("<img src=\"same.png\">"));XCTAssertTrue(view.string.contains(file.name))
        view.undoManager?.undo();XCTAssertEqual(view.string,source)
        XCTAssertEqual(LocalSchemeHandler.mime(for:"test.m4a"),"audio/mp4")
    }
    func testAuditPaginatesAllRowsExcludesTrashAndProtectsHighWatermark() async throws {
        let db = try AppDatabase(DatabaseQueue())
        for i in 0..<105 { _ = try db.save(Highlight(text:"<p>条目\(i)<img src=\"missing\(i).png\"></p>")) }
        var trash = Highlight(text:"<img src=\"trash.png\">");trash.deletedAt = Date();_ = try db.save(trash)
        var card = Card(deck:"牌组",front:"<p>卡片</p>",back:"<a href=\"example.com\">链接</a>")
        card.fields = ["<img src=\"field.png\">"];card.sections = [.init(name:"出处",text:"[sound:absent.mp3]")];_ = try db.save(card)
        try db.saveProgress(GrowthReflection(gains:"<img src=\"growth.png\">"),key:"growth.day.2026-10-19")
        let scopes = try await db.resourceAuditScopes()
        _ = try db.save(Highlight(text:"<img src=\"late.png\">"))
        let results = try AuditResultStore()
        var scanned = 0
        for var scope in scopes {
            while true {
                let docs = try await db.resourceAuditBatch(scope,limit:20)
                if docs.isEmpty { break }
                _ = try results.append(docs,mediaNames:[]);scanned += docs.count;scope.cursor = docs.last!.recordID
            }
        }
        XCTAssertEqual(scanned,107)
        let first = try results.page(0,kind:"",query:"")
        XCTAssertEqual(first.total,109);XCTAssertEqual(first.items.count,50)
        let end = try results.page(500,kind:"",query:"")
        XCTAssertEqual(end.items.count,9)
        XCTAssertEqual(try results.page(0,kind:"card",query:"").total,3)
        XCTAssertEqual(try results.page(0,kind:"app_progress",query:"growth.png").total,1)
        XCTAssertEqual(try results.page(0,kind:"",query:"late.png").total,0)
        XCTAssertEqual(try results.page(0,kind:"",query:"trash.png").total,0)
        let firstDocs = try await db.resourceAuditBatch(scopes[0],limit:20)
        _ = try results.append(firstDocs,mediaNames:[])
        XCTAssertEqual(try results.page(0,kind:"",query:"").total,109,"暂停后重复批次不增加问题")
    }
    func testAuditPauseResumeAndResetCannotResurrectOldPages() async throws {
        let db = try AppDatabase(DatabaseQueue())
        for i in 0..<75 { _ = try db.save(Highlight(text:"<a href=\"bad\(i)\">资料</a>")) }
        let state = LibraryResourceAuditState(); state.start(db:db)
        for _ in 0..<300 { if state.finished { break }; try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertTrue(state.finished);XCTAssertEqual(state.examined,75)
        state.refreshPage();state.reset();try await Task.sleep(for:.milliseconds(60))
        XCTAssertTrue(state.items.isEmpty);XCTAssertEqual(state.total,0)
        state.start(db:db);state.pause();XCTAssertFalse(state.running)
        state.start(db:db)
        for _ in 0..<300 { if state.finished { break }; try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertTrue(state.finished)
        state.refreshPage();try await Task.sleep(for:.milliseconds(40));XCTAssertEqual(state.total,75)
    }
    func testCompactKeepsMediaOwnedByGrowthHistoryDraftsAndDeletedCards() throws {
        let db = try AppDatabase(DatabaseQueue())
        try db.saveMedia(["growth.png":Data([1]),"history.png":Data([2]),"draft.png":Data([3]),"trash.png":Data([4]),"orphan.png":Data([5])])
        try db.saveProgress(GrowthReflection(gains:"<img src=\"growth.png\">"),key:"growth.day.2026-10-19")
        try db.saveProgress(["body":"<audio src=\"history.png\"></audio>"],key:"content-history.test")
        var card = Card(deck:"牌组",front:"<img src=\"trash.png\">",back:"");card.deletedAt = Date();_ = try db.save(card)
        XCTAssertEqual(try db.compact(additionalMedia:["draft.png"]).mediaRemoved,1)
        for name in ["growth.png","history.png","draft.png","trash.png"] { XCTAssertNotNil(try db.media(named:name)) }
        XCTAssertNil(try db.media(named:"orphan.png"))
    }
    func testPastePreferenceIsIncludedInFullBackupSettings() throws {
        let name = "KongReview-V380Tests-"+UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName:name));defer { defaults.removePersistentDomain(forName:name) }
        defaults.set("plain",forKey:EditorPasteStyle.defaultsKey)
        XCTAssertEqual(try FullBackupService.settingsSnapshot(defaults)[EditorPasteStyle.defaultsKey] as? String,"plain")
        defaults.set("invalid",forKey:EditorPasteStyle.defaultsKey)
        XCTAssertThrowsError(try FullBackupService.settingsSnapshot(defaults))
    }
    func testIntakeBridgeJavaScriptParses() throws {
        let context = try XCTUnwrap(JSContext());context.evaluateScript("new Function("+EditorPage.jsonString(EditorIntakeScript.source)+")")
        XCTAssertNil(context.exception)
    }
}
