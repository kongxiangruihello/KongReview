import Foundation

struct EditorTextMatch: Equatable, Sendable {
    static let limit = 5_000
    var ranges: [NSRange]
    var truncated: Bool
    static func find(_ text: String, query: String, caseSensitive: Bool) -> Self {
        guard !query.isEmpty else { return .init(ranges:[],truncated:false) }
        let ns = text as NSString
        var results: [NSRange] = [], offset = 0
        while offset <= ns.length {
            let found = ns.range(of:query,options:caseSensitive ? [] : [.caseInsensitive],range:NSRange(location:offset,length:ns.length-offset))
            guard found.location != NSNotFound, found.length > 0 else { break }
            if results.count == limit { return .init(ranges:results,truncated:true) }
            results.append(found); offset = NSMaxRange(found)
        }
        return .init(ranges:results,truncated:false)
    }
    func replacing(_ text: String, with replacement: String) -> String {
        var value = text
        for range in ranges.reversed() { value = (value as NSString).replacingCharacters(in:range,with:replacement) }
        return value
    }
}

struct EditorMutation: Identifiable {
    var id = UUID()
    var title: String
    var original: String
    var proposed: String
    var count: Int
    var source: Bool
    var storedBaseline: String? = nil
}

/// Search uses DOM text ranges; highlight decorations never become saved HTML.
enum EditorTextScript {
    static let source = #"""
    (function(){
      var ed=document.getElementById('ed'); if(!ed) return;
      var state={query:'',sensitive:false,index:0,matches:[]};
      function collect(root){
        var nodes=[],text='',last=null,w=document.createTreeWalker(root,NodeFilter.SHOW_TEXT);
        while(w.nextNode()){
          var n=w.currentNode,p=n.parentElement;
          if(!p || p.closest('script,style')) continue;
          var block=p.closest('p,div,li,h1,h2,h3,h4,h5,h6,pre,blockquote,tr');
          if(last && block!==last) text+='\n';
          nodes.push({node:n,start:text.length,end:text.length+n.data.length});text+=n.data;last=block;
        }
        return {nodes:nodes,text:text};
      }
      function matches(data,q,sensitive){
        if(!q) return {ranges:[],truncated:false};
        var escaped=q.replace(/[.*+?^${}()|[\]\\]/g,'\\$&');
        var re=new RegExp(escaped,sensitive?'gu':'giu'),out=[],m;
        while((m=re.exec(data.text))!==null){
          if(out.length===5000) return {ranges:out,truncated:true};
          out.push({start:m.index,end:m.index+m[0].length});
        }
        return {ranges:out,truncated:false};
      }
      function range(data,m){
        var a=data.nodes.find(function(x){return m.start>=x.start && m.start<x.end;});
        var b=data.nodes.find(function(x){return m.end>x.start && m.end<=x.end;});
        if(!a || !b) return null;
        var r=document.createRange();r.setStart(a.node,m.start-a.start);r.setEnd(b.node,m.end-b.start);return r;
      }
      function clear(){ if(window.CSS && CSS.highlights) CSS.highlights.delete('kr-editor-find'); }
      var style=document.createElement('style');style.textContent='::highlight(kr-editor-find){background:#ffe58a;color:#1f1e1c}';document.head.appendChild(style);
      window.krEditorFind=function(q,sensitive,step){
        var data=collect(ed),result=matches(data,q,sensitive);
        if(q!==state.query || sensitive!==state.sensitive) state.index=0;
        state.query=q;state.sensitive=sensitive;state.matches=result.ranges;
        if(result.ranges.length) state.index=(state.index+step+result.ranges.length)%result.ranges.length;
        else state.index=0;
        clear();
        var ranges=result.ranges.map(function(m){return range(data,m)}).filter(Boolean);
        if(window.CSS && CSS.highlights && window.Highlight) CSS.highlights.set('kr-editor-find',new Highlight(...ranges));
        var current=ranges[state.index];
        if(current){var s=window.getSelection();s.removeAllRanges();s.addRange(current);current.startContainer.parentElement.scrollIntoView({block:'nearest',inline:'nearest'});}
        var box=current ? current.getBoundingClientRect() : null;
        return {count:result.ranges.length,index:state.index,truncated:result.truncated,rect:box ? {x:box.x,y:box.y,width:box.width,height:box.height} : null};
      };
      window.krEditorClearFind=function(){clear();state.query='';state.matches=[];};
      window.krEditorReplaceOne=function(q,sensitive,replacement){
        if(!ed.isContentEditable) return false;
        var result=window.krEditorFind(q,sensitive,0);if(!result.count) return false;
        clear();ed.focus();document.execCommand('insertText',false,replacement);
        ed.dispatchEvent(new Event('input',{bubbles:true}));krFlush();return true;
      };
      window.krEditorReplacementPreview=function(q,sensitive,replacement){
        var clone=ed.cloneNode(true),data=collect(clone),result=matches(data,q,sensitive);
        if(result.truncated) return {truncated:true,count:result.ranges.length};
        result.ranges.slice().reverse().forEach(function(m){var r=range(data,m);if(r){r.deleteContents();r.insertNode(document.createTextNode(replacement));}});
        return {original:ed.innerHTML,proposed:clone.innerHTML,count:result.ranges.length,truncated:false};
      };
      window.krEditorSnapshot=function(){krFlush();return ed.innerHTML;};
      window.krEditorApply=function(html,expected){
        if(!ed.isContentEditable || ed.innerHTML!==expected) return false;
        clear();ed.focus();var r=document.createRange();r.selectNodeContents(ed);
        var s=window.getSelection();s.removeAllRanges();s.addRange(r);
        var ok=document.execCommand('insertHTML',false,html);
        if(ok){ed.dispatchEvent(new Event('input',{bubbles:true}));krFlush();}return ok;
      };
      document.addEventListener('keydown',function(e){
        if((e.metaKey||e.ctrlKey) && e.key.toLowerCase()==='f' && !e.isComposing){
          e.preventDefault();e.stopImmediatePropagation();window.webkit.messageHandlers.krEditor.postMessage({type:'find'});
        }
      },true);
    })();
    """#
}
