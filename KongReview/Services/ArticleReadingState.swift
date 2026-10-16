import Foundation
import Observation

/// 保留文章中的文字锚点和相对位置；图片加载或窗口尺寸变化后仍能回到附近段落。
struct ArticleReadingPosition: Codable, Equatable {
    var ratio: Double
    var anchor: String
    var anchorOffset: Double

    init(ratio: Double, anchor: String = "", anchorOffset: Double = 0) {
        self.ratio = ratio.isFinite ? min(1, max(0, ratio)) : 0
        self.anchor = String(anchor.prefix(160))
        self.anchorOffset = anchorOffset.isFinite ? anchorOffset : 0
    }
}

@MainActor
@Observable
final class ArticleReadingState {
    private(set) var articleID: Int64?
    var showsFind = false
    var query = ""
    var matchCount = 0
    var currentMatch = 0
    var searchRevision = 0
    var moveDirection = 0
    private let defaults: UserDefaults?

    init(defaults: UserDefaults? = .standard) { self.defaults = defaults }

    func open(articleID: Int64?) {
        guard self.articleID != articleID else { return }
        self.articleID = articleID
        closeFind()
    }

    func closeFind() {
        showsFind = false
        query = ""
        matchCount = 0
        currentMatch = 0
        moveDirection = 0
        searchRevision += 1
    }

    func move(_ direction: Int) {
        guard matchCount > 0 else { return }
        moveDirection = direction < 0 ? -1 : 1
        searchRevision += 1
    }

    func position(for articleID: Int64?) -> ArticleReadingPosition? {
        guard let articleID, let data = defaults?.data(forKey: key(articleID)),
              let decoded = try? JSONDecoder().decode(ArticleReadingPosition.self, from: data) else { return nil }
        return ArticleReadingPosition(ratio: decoded.ratio, anchor: decoded.anchor, anchorOffset: decoded.anchorOffset)
    }

    func save(_ position: ArticleReadingPosition, for articleID: Int64?) {
        guard let articleID, let data = try? JSONEncoder().encode(position) else { return }
        defaults?.set(data, forKey: key(articleID))
    }

    private func key(_ id: Int64) -> String { "articleReading.position.v1.\(id)" }
}

/// 查找只创建 Range 和视觉覆盖层，不拆分正文节点，也不改变用户的选区或摘录 mark。
enum ArticleReaderScript {
    static func install(position: ArticleReadingPosition?, session: String) -> String {
        let payload = PositionPayload(position: position, session: session)
        return "(function(saved) {\n" + script + "\n})(" + json(payload) + ");"
    }

    static func find(_ query: String, direction: Int = 0) -> String {
        "window.kgReader && window.kgReader.find(\(json(query)), \(direction));"
    }

    private struct PositionPayload: Encodable {
        var position: ArticleReadingPosition?
        var session: String
    }

    private static func json<T: Encodable>(_ value: T) -> String {
        String(decoding: (try? JSONEncoder().encode(value)) ?? Data("null".utf8), as: UTF8.self)
    }

    static let script = #"""
      'use strict';
      if (window.kgReader) window.kgReader.dispose();
      const root = document.getElementById('kg-content') || document.body;
      let restoring = true, ready = false, disposed = false, imagesSettled = false, userControlled = false;
      let restoreTimer, saveTimer, current = -1, ranges = [], needle = '';
      const listeners = [];
      const post = data => { try { window.webkit.messageHandlers.kg.postMessage(Object.assign({session:saved.session}, data)); } catch (_) {} };
      const listen = (target, name, fn, options) => { target.addEventListener(name,fn,options); listeners.push([target,name,fn,options]); };
      const height = () => Math.max(0, document.documentElement.scrollHeight - window.innerHeight);
      const blocks = () => Array.from(root.querySelectorAll('p,h1,h2,h3,h4,li,blockquote,pre,figure,td')).filter(e => e.getClientRects().length && e.textContent.trim());
      function snapshot() {
        if (restoring || !ready || disposed) return null;
        const y = window.scrollY, list = blocks();
        let block = list.find(e => e.getBoundingClientRect().bottom > 0) || list[list.length-1];
        return {ratio: height() ? y / height() : 0,
                anchor: block ? block.textContent.trim().slice(0,160) : '',
                anchorOffset: block ? block.getBoundingClientRect().top : 0};
      }
      function save() { const value = snapshot(); if (value) post({type:'readerPosition', position:value}); return value; }
      function restorePosition() {
        if (!saved.position) return;
        const value = saved.position;
        const block = value.anchor && blocks().find(e => e.textContent.trim().slice(0,160) === value.anchor);
        window.scrollTo(0, block ? window.scrollY + block.getBoundingClientRect().top - value.anchorOffset : height() * value.ratio);
      }
      function stopRestoring() {
        if (!restoring) return;
        restorePosition(); restoring = false; ready = true;
        clearTimeout(restoreTimer); observer.disconnect();
      }
      const observer = new ResizeObserver(() => {
        if (!restoring) return;
        restorePosition(); clearTimeout(restoreTimer);
        if (imagesSettled) restoreTimer = setTimeout(stopRestoring, 400);
      });
      observer.observe(document.body);
      // 提前加载懒加载图片，使保存的下方段落在恢复期间能够获得实际布局。
      const images = Array.from(root.querySelectorAll('img'));
      const imageReady = images.map(img => {
        img.loading = 'eager';
        if (img.complete) return Promise.resolve();
        return new Promise(resolve => { img.addEventListener('load',resolve,{once:true}); img.addEventListener('error',resolve,{once:true}); });
      });
      const deadline = setTimeout(stopRestoring, 6000);
      Promise.all([document.fonts ? document.fonts.ready : Promise.resolve(), ...imageReady]).then(() => {
        if (disposed) return;
        imagesSettled = true;
        // 极慢图片超过等待上限后再补偿一次布局；用户已经操作时尊重其当前阅读位置。
        if (!restoring) {
          if (!userControlled && saved.position) {
            restoring = true; ready = false;
            requestAnimationFrame(() => { if (disposed || userControlled) return; restorePosition(); restoring = false; ready = true; save(); });
          }
          return;
        }
        requestAnimationFrame(() => { restorePosition(); clearTimeout(restoreTimer); restoreTimer = setTimeout(stopRestoring,400); });
      });
      restorePosition();
      // 用户主动滚动就接管位置；恢复期间的程序滚动绝不能把旧进度覆盖成顶部。
      function takeControl() {
        userControlled = true;
        if (restoring) { restoring = false; ready = true; clearTimeout(restoreTimer); observer.disconnect(); }
      }
      listen(window,'wheel',takeControl,{passive:true});
      listen(window,'touchstart',takeControl,{passive:true});
      listen(window,'pointerdown',takeControl,{passive:true});
      listen(window,'keydown',e => { if (['ArrowDown','ArrowUp','PageDown','PageUp','Home','End',' '].includes(e.key)) takeControl(); });
      listen(window,'scroll',() => {
        if (!restoring && ready) { clearTimeout(saveTimer); saveTimer = setTimeout(save,100); }
        if (!window.CSS || !CSS.highlights) drawFallback();
      },{passive:true});
      listen(window,'pagehide',save);
      function textIndex() {
        const walker = document.createTreeWalker(root,NodeFilter.SHOW_TEXT);
        let node, full = '', map = [];
        while ((node = walker.nextNode())) {
          if (!node.parentElement || node.parentElement.closest('script,style,noscript,[hidden]') || !node.parentElement.getClientRects().length) continue;
          const start = full.length; full += node.nodeValue;
          map.push({node,start,end:full.length});
        }
        return {full,map};
      }
      const style = document.createElement('style');
      style.textContent = '::highlight(kg-reader-search){background:rgba(255,223,72,.48);color:inherit}::highlight(kg-reader-current){background:rgba(255,143,30,.72);color:inherit}';
      document.head.appendChild(style);
      const layer = document.createElement('div');
      layer.id = 'kg-reader-find-layer'; layer.style.cssText = 'position:absolute;left:0;top:0;pointer-events:none;z-index:2;'; document.body.appendChild(layer);
      function drawFallback() {
        layer.replaceChildren();
        if (window.CSS && CSS.highlights && window.Highlight) return;
        ranges.forEach((range,index) => Array.from(range.getClientRects()).forEach(rect => {
          const span = document.createElement('span');
          span.style.cssText = `position:absolute;left:${rect.left+scrollX}px;top:${rect.top+scrollY}px;width:${rect.width}px;height:${rect.height}px;background:${index===current?'rgba(255,143,30,.45)':'rgba(255,223,72,.35)'};border-radius:2px;`;
          layer.appendChild(span);
        }));
      }
      function paint() {
        if (window.CSS && CSS.highlights && window.Highlight) {
          CSS.highlights.set('kg-reader-search',new Highlight(...ranges));
          CSS.highlights.set('kg-reader-current',new Highlight(...(current>=0?[ranges[current]]:[])));
        }
        drawFallback();
      }
      function find(query,direction) {
        if (restoring && query) takeControl();
        if (query !== needle || !direction) {
          needle = query; ranges = []; current = -1;
          if (query.trim()) {
            const {full,map} = textIndex();
            // 正则 literal 匹配保留原 UTF-16 偏移，不受大小写转换长度变化的影响。
            const escaped = query.replace(/[.*+?^${}()|[\]\\]/g,'\\$&');
            const regex = new RegExp(escaped,'giu');
            let match;
            while ((match = regex.exec(full))) {
              const first = map.find(p => p.end > match.index);
              const last = map.find(p => p.end >= match.index + match[0].length);
              if (!first || !last) continue;
              const range = document.createRange(); range.setStart(first.node,match.index-first.start); range.setEnd(last.node,match.index+match[0].length-last.start); ranges.push(range);
            }
          }
          current = ranges.length ? 0 : -1;
        } else if (ranges.length) current = (current + direction + ranges.length) % ranges.length;
        paint();
        if (current >= 0) { const rect = ranges[current].getBoundingClientRect(); window.scrollTo({top:scrollY+rect.top-innerHeight/3,behavior:'instant'}); }
        post({type:'readerFind',query:needle,total:ranges.length,current:current+1});
        return {total:ranges.length,current:current+1};
      }
      listen(window,'resize',() => { if (!restoring) paint(); });
      window.kgReader = {session:saved.session,find,save,snapshot,
        refresh:() => { if (needle) find(needle,0); },
        dispose:() => { save(); disposed = true; observer.disconnect(); clearTimeout(deadline); clearTimeout(restoreTimer); clearTimeout(saveTimer); listeners.forEach(([t,n,f,o])=>t.removeEventListener(n,f,o)); style.remove(); layer.remove(); if(window.CSS&&CSS.highlights){CSS.highlights.delete('kg-reader-search');CSS.highlights.delete('kg-reader-current');} }
      };
    """#
}
