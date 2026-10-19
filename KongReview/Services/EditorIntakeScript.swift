import Foundation

enum EditorIntakeScript {
    static let source = #"""
    (function(){
      var ed=document.getElementById('ed');if(!ed)return;
      var pasteRange=null,pasteOriginal='',returnRange=null;
      function safeHTML(html){
        var box=document.createElement('div');box.innerHTML=html;
        box.querySelectorAll('script,style,meta,link,base,title,noscript,iframe,object,embed,form,input,button,textarea,select,svg,math,template').forEach(function(n){n.remove()});
        var allowed=['font-size','font-family','font-weight','font-style','color','background-color','text-align','text-decoration','vertical-align'];
        box.querySelectorAll('*').forEach(function(n){
          Array.from(n.attributes).forEach(function(a){
            var k=a.name.toLowerCase();
            if(['href','src','alt','title','colspan','rowspan','id','name','controls','style','face','size','color'].indexOf(k)<0)n.removeAttribute(a.name);
            else if(k==='href'||k==='src'){
              var v=a.value.replace(/[\u0000-\u0020]/g,'');
              if(/^[a-z][a-z0-9+.-]*:/i.test(v)&&! /^(https?:|mailto:|kr-media:|kr-img:|data:image\/(?:png|jpeg|gif|webp);base64,)/i.test(v))n.removeAttribute(k);
            }
          });
          if(n.hasAttribute('style')){
            var s=n.style,kept='';allowed.forEach(function(k){var v=s.getPropertyValue(k);if(v&&!/url\s*\(|expression\s*\(|@import/i.test(v))kept+=k+':'+v+';'});
            if(kept)n.setAttribute('style',kept);else n.removeAttribute('style');
          }
          if(n.tagName==='AUDIO'||n.tagName==='VIDEO')n.setAttribute('controls','');
        });return box.innerHTML;
      }
      ed.addEventListener('paste',function(e){
        var dt=e.clipboardData,html=dt?dt.getData('text/html'):'';
        if(!ed.isContentEditable)return;
        if(!html){setTimeout(function(){krFlush();window.webkit.messageHandlers.krEditor.postMessage({type:'paste-attribution'});},80);return;}
        e.preventDefault();e.stopImmediatePropagation();
        var sel=getSelection();if(!sel.rangeCount||!ed.contains(sel.getRangeAt(0).commonAncestorContainer))return;
        pasteRange=sel.getRangeAt(0).cloneRange();pasteOriginal=ed.innerHTML;
        var clean=safeHTML(html),box=document.createElement('div');box.innerHTML=clean;
        window.webkit.messageHandlers.krEditor.postMessage({type:'paste-choice',html:clean,plain:dt.getData('text/plain')||box.innerText||box.textContent||'',original:pasteOriginal});
      },true);
      ed.addEventListener('dblclick',function(e){
        var n=e.target.closest&&e.target.closest('img,audio,video');if(!n)return;
        var value=n.getAttribute('data-kr-src')||n.getAttribute('src')||'';if(!value)return;
        var same=Array.from(ed.querySelectorAll(n.tagName.toLowerCase())).filter(function(x){return (x.getAttribute('data-kr-src')||x.getAttribute('src')||'')===value});
        window.webkit.messageHandlers.krEditor.postMessage({type:'media-picked',value:value,occurrence:same.indexOf(n)});
      });
      window.krEditorPasteApply=function(html,expected){
        if(!ed.isContentEditable||ed.innerHTML!==expected||pasteOriginal!==expected||!pasteRange||!ed.contains(pasteRange.commonAncestorContainer))return false;
        ed.focus();var s=getSelection();s.removeAllRanges();s.addRange(pasteRange);
        var ok=document.execCommand('insertHTML',false,safeHTML(html));
        if(ok){if(window.krPreserveHTML)krPreserveHTML();ed.dispatchEvent(new Event('input',{bubbles:true}));krFlush();}pasteRange=null;return ok;
      };
      window.krEditorOutline=function(){
        var s=getSelection();if(s.rangeCount&&ed.contains(s.getRangeAt(0).commonAncestorContainer))returnRange=s.getRangeAt(0).cloneRange();else{returnRange=document.createRange();returnRange.selectNodeContents(ed);returnRange.collapse(true);}
        krFlush();return {original:ed.innerHTML,headings:Array.from(ed.querySelectorAll('h1,h2,h3,h4,h5,h6')).map(function(n){return {title:n.textContent,level:parseInt(n.tagName[1])}})};
      };
      window.krEditorOutlineGo=function(index,expected){
        if(ed.innerHTML!==expected)return null;
        var r=document.createRange(),node;
        if(index===-2&&returnRange&&ed.contains(returnRange.commonAncestorContainer))r=returnRange;
        else if(index===-1){node=ed.firstElementChild||ed;r.selectNodeContents(node);r.collapse(true);}
        else{node=ed.querySelectorAll('h1,h2,h3,h4,h5,h6')[index];if(!node)return null;r.selectNodeContents(node);}
        var s=getSelection();s.removeAllRanges();s.addRange(r);
        var target=node||r.startContainer.parentElement;target.scrollIntoView({block:'nearest',inline:'nearest'});
        var b=r.getBoundingClientRect();if(!b.height)b=target.getBoundingClientRect();
        return {x:b.x,y:b.y,width:b.width,height:b.height};
      };
    })();
    """#
}
