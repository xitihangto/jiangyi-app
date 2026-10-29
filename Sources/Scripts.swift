import Foundation

/// 注入到网页里执行的 JS 片段。
/// 全部写成「一个表达式」，因为 Safari 的 do JavaScript 只返回最后一个表达式的值。
enum Scripts {

    /// 探测登录状态
    ///
    /// 注意 `bodyLen` 和 `hasLoginButton`：刚打开页面时 DOM 还没渲染，
    /// 既没有输入框也没有密码框，早期版本会把它误判成「未登录」，
    /// 于是 App 一启动就闪出「登录 DeepSeek」按钮。用这两个字段区分
    /// 「真的没登录」和「还没渲染完」。
    static let loginProbe = #"""
    (function(){
      var r={url:location.href,title:document.title,keys:[],hasChatInput:false,
             hasLoginForm:false,hasLoginButton:false,fileInputs:0,bodyLen:0};
      try{for(var i=0;i<localStorage.length;i++){r.keys.push(localStorage.key(i));}}catch(e){}
      r.hasChatInput = !!document.querySelector('textarea') || !!document.querySelector('[contenteditable="true"]');
      r.hasLoginForm = !!document.querySelector('input[type=password]');
      r.fileInputs = document.querySelectorAll('input[type=file]').length;
      r.bodyLen = document.body ? (document.body.textContent||'').length : 0;
      var bs=document.querySelectorAll('button,[role=button],a');
      for(var i=0;i<bs.length;i++){
        var t=(bs[i].textContent||'').replace(/\s+/g,'').trim();
        if(t.length>0&&t.length<=6&&/^(登录|立即登录|登入|Log in|Sign in)$/i.test(t)){r.hasLoginButton=true;break;}
      }
      return JSON.stringify(r);
    })()
    """#

    /// 在页面顶部打一条悬浮提示（登录等待 / 倒计时）。
    ///
    /// 为什么要注入而不是在 App 里显示：登录时浏览器窗口是唯一露出来的东西，
    /// 提示放在 App 主窗口里用户根本看不到。放在页面里才能贴着登录框。
    /// 每次调用都会复用同一个节点，SPA 重渲染把节点删了下次调用会自动补回来。
    static func loginBadge(text: String) -> String {
        """
        (function(){
          var T=\(jsString(text));
          var id='__wb_badge__';
          var el=document.getElementById(id);
          if(!el){
            el=document.createElement('div');
            el.id=id;
            el.style.cssText='position:fixed;left:50%;top:18px;transform:translateX(-50%);'
              +'z-index:2147483647;padding:11px 22px;border-radius:999px;'
              +'font:600 14px/1.45 -apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif;'
              +'color:#fff;background:linear-gradient(135deg,#2563eb,#7c3aed);'
              +'box-shadow:0 8px 26px rgba(37,99,235,.42);pointer-events:none;white-space:nowrap;';
            (document.body||document.documentElement).appendChild(el);
          }
          if(el.textContent!==T) el.textContent=T;
          return 'OK';
        })()
        """
    }

    /// 收起窗口前把提示条摘掉，下次登录不会看到上一轮的残留
    static let loginBadgeClear = #"""
    (function(){
      var e=document.getElementById('__wb_badge__');
      if(e) e.remove();
      return 'OK';
    })()
    """#

    // MARK: - v0.2 上传与发送

    // 原来这里有个 `newChat`：找页面上「开启新对话」按钮点一下。
    // 2026-10-27 撤掉了，原因是它在作文版上跑了 v0.12–v0.20 九个版本、**一次都没点中过**
    // （每轮日志都是 NOT_FOUND），等于白花两三次 JS 往返。现在改成直接重载
    // https://chat.deepseek.com/ 根地址 —— 根地址后面不带会话 id，重载出来必然是空白对话。
    // 别再把这个选择器加回来，加第四版也不会中，改版一次就废一次。

    /// 探测输入区结构，同时检查「深度思考」和「智能搜索」是否都已激活。
    ///
    /// 开关的配色会随 DeepSeek 的主题和版本变化，不能只认某两个蓝色 RGB 值；优先
    /// 使用 aria/data 状态和 class，再把颜色作为兜底。未激活时返回真实可点击元素的
    /// 视口坐标，App 侧会注入可信鼠标事件来打开它。
    static let probeComposer = #"""
    (function(){
      var ta=document.querySelector('textarea');
      var fi=document.querySelectorAll('input[type=file]');
      var btns=document.querySelectorAll('button');
      var send='';
      for(var i=0;i<btns.length;i++){
        var l=(btns[i].getAttribute('aria-label')||'')+' '+(btns[i].innerText||'');
        if(/发送|send/i.test(l)){send=l.replace(/\s+/g,' ').trim().slice(0,24);break;}
      }
      function compact(v){return (v||'').replace(/\s+/g,'').trim();}
      function labelOf(b){
        return compact((b.getAttribute('aria-label')||'')+' '+(b.getAttribute('title')||'')+' '+(b.innerText||b.textContent||''));
      }
      function isActive(b){
        var chain=[], current=b;
        for(var up=0;current&&up<4;up++,current=current.parentElement) chain.push(current);
        for(var ci=0;ci<chain.length;ci++){
          var node=chain[ci];
        var attrs=['aria-pressed','aria-checked','data-state','data-active','data-selected'];
        for(var j=0;j<attrs.length;j++){
          var v=(node.getAttribute(attrs[j])||'').toLowerCase();
          if(v==='true'||v==='on'||v==='active'||v==='checked'||v==='selected') return true;
        }
        var classes=(node.className||'')+' '+(node.parentElement&&node.parentElement.className||'');
        if(/(^|[ _-])(active|selected|checked|enabled|on)(?=$|[ _-])/i.test(classes)) return true;
        var colors=[window.getComputedStyle(node).backgroundColor,window.getComputedStyle(node).color,
                    window.getComputedStyle(node).borderColor];
        for(var k=0;k<colors.length;k++){
          var m=(colors[k]||'').match(/rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)/i);
          // DeepSeek 的启用色可能改色号；保留“明显偏蓝”的语义兜底。
          if(m && (+m[3] > +m[1]+25) && (+m[3] > +m[2]+15)) return true;
        }
        }
        return false;
      }
      function clickTarget(el){
        // DeepSeek 2026-10 的模式开关是普通 div/span，不带 role=button；沿父级找
        // 显式可点击容器。即使最终落在文字 span 的坐标，真实鼠标事件也会冒泡到容器。
        var cur=el;
        for(var hop=0;cur&&hop<6;hop++,cur=cur.parentElement){
          var cs=window.getComputedStyle(cur);
          if(cur.tagName==='BUTTON'||cur.getAttribute('role')==='button'||cur.tabIndex>=0||
             cs.cursor==='pointer'||typeof cur.onclick==='function') return cur;
        }
        return el;
      }
      function findMode(name){
        var nodes=document.querySelectorAll('button,[role=button],span,div,label,a'), best=null, score=-1;
        for(var i=0;i<nodes.length;i++){
          var text=labelOf(nodes[i]);
          if(text.indexOf(name)<0) continue;
          // 精确标签优先，避免命中包含整段输入区文案的外层 div。
          var s=(text===name ? 10000 : 100)-Math.min(text.length,80);
          if(s>score){best=nodes[i];score=s;}
        }
        if(!best) return {found:false,on:false,rect:null};
        var target=clickTarget(best), r=target.getBoundingClientRect();
        return {found:true,on:isActive(best)||isActive(target),
                rect:(r.width>0&&r.height>0?{x:r.left+r.width/2,y:r.top+r.height/2}:null)};
      }
      var deep=findMode('深度思考');
      var smart=findMode('智能搜索');
      return JSON.stringify({textarea:!!ta,fileInputs:fi.length,sendLabel:send,
                             deepThink:deep.on,smartSearch:smart.on,
                             deepThinkFound:deep.found,smartSearchFound:smart.found,
                             deepThinkRect:deep.rect,smartSearchRect:smart.rect});
    })()
    """#

    /// 清空分片缓冲
    static let resetBuffer = "window.__wbF={}; 'OK'"

    /// 往第 index 个文件追加一段 base64
    static func appendChunk(index: Int, chunk: String) -> String {
        "(window.__wbF[\(index)]=(window.__wbF[\(index)]||'')+'\(chunk)', window.__wbF[\(index)].length)"
    }

    /// 把缓冲里的字节组装成 File 并塞进页面
    static func commitFiles(defsJSON: String) -> String {
        #"""
        (function(defs){
          var dt=new DataTransfer();
          for(var i=0;i<defs.length;i++){
            var d=defs[i];
            var b64=window.__wbF[d.idx]||'';
            var bin=atob(b64);
            var n=bin.length;
            var bytes=new Uint8Array(n);
            for(var j=0;j<n;j++){bytes[j]=bin.charCodeAt(j);}
            dt.items.add(new File([bytes], d.name, {type:d.type}));
          }
          var input=document.querySelector('input[type=file]');
          if(input){
            input.files=dt.files;
            input.dispatchEvent(new Event('change',{bubbles:true}));
            return 'INPUT:'+input.files.length;
          }
          var ta=document.querySelector('textarea');
          var zone=(ta&&(ta.closest('form')||ta.parentElement))||document.body;
          try{
            zone.dispatchEvent(new DragEvent('drop',{bubbles:true,cancelable:true,dataTransfer:dt}));
            return 'DROP';
          }catch(e){}
          return 'NO_TARGET';
        })(\#(defsJSON))
        """#
    }

    /// 检查哪些文件名还没出现在页面上
    static func checkNames(namesJSON: String) -> String {
        #"""
        (function(names){
          var txt=document.body.innerText;
          var missing=[];
          for(var i=0;i<names.length;i++){
            if(txt.indexOf(names[i])<0){missing.push(names[i]);}
          }
          return JSON.stringify({missing:missing});
        })(\#(namesJSON))
        """#
    }

    /// 清空输入框（走 React 的 native setter，否则页面状态不更新）
    ///
    /// 为什么需要它：网页版收到附件后**自己**会把文件名当文字写进输入框
    /// （见 HANDOVER §6.9，作文版实测截图）。不是我们写的，是它的前端行为。
    /// 所以必须「等附件就位 → 清空 → 再填提示词」，顺序不能反：清早了网页还会补回来。
    static let clearText = #"""
    (function(){
      var ta=document.querySelector('textarea');
      if(!ta){return 'NO_TEXTAREA';}
      var setter=Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype,'value').set;
      setter.call(ta,'');
      ta.dispatchEvent(new Event('input',{bubbles:true}));
      ta.dispatchEvent(new Event('change',{bubbles:true}));
      return 'OK:'+ta.value.length;
    })()
    """#

    /// 回读输入框里的文字，用来校验填进去的提示词有没有被网页追加别的内容
    static let readText = #"""
    (function(){
      var ta=document.querySelector('textarea');
      return ta?ta.value:'__NO_TEXTAREA__';
    })()
    """#

    /// 把文字写进输入框（走 React 的 native setter，否则状态不更新）
    static func fillText(textJSON: String) -> String {
        #"""
        (function(text){
          var ta=document.querySelector('textarea');
          if(!ta){return 'NO_TEXTAREA';}
          var setter=Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype,'value').set;
          setter.call(ta,text);
          ta.dispatchEvent(new Event('input',{bubbles:true}));
          ta.dispatchEvent(new Event('change',{bubbles:true}));
          ta.focus();
          return 'OK:'+ta.value.length;
        })(\#(textJSON))
        """#
    }

    /// 点发送
    static let sendNow = #"""
    (function(){
      var btns=document.querySelectorAll('button');
      for(var i=btns.length-1;i>=0;i--){
        var b=btns[i];
        var l=(b.getAttribute('aria-label')||'')+' '+(b.innerText||'');
        if(!/发送|send/i.test(l)||b.disabled) continue;
        // offsetParent 判不出 position:fixed（输入区是吸底的），改用尺寸判断。
        var _rc=b.getBoundingClientRect();
        if(_rc.width<1||_rc.height<1) continue;
        b.click();return 'CLICK';
      }
      var ta=document.querySelector('textarea');
      if(ta){
        ta.focus();
        ta.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true,cancelable:true}));
        return 'ENTER';
      }
      return 'NO_TARGET';
    })()
    """#

    // MARK: - v0.5 回复区：状态探测 / 抓代码块 / 点继续

    /// 探测回复区状态
    /// 真实结构（据 20261025-043443 快照）：
    ///   代码块 = div.md-code-block > pre（里面没有 code，内容全是 span.token）
    ///   按钮   = div[role=button].ds-button
    ///   正文   = .ds-markdown
    ///
    /// 结束判定用「语义信号」而不是纯统计：
    ///   endsWithMain = 最后一个代码块以 `if __name__ == "__main__": main()` 收尾
    ///   afterLines   = 该代码块之后还有几行非空说明文字
    /// 两者同时成立 = 脚本写完了且完整（AI 收尾必有这段，写完必带说明）
    static let replyState = #"""
    (function(){
      var out={generating:false,hasContinue:false,blocks:0,codes:0,pres:0,
               codeLen:0,textLen:0,stopLabel:'',contLabel:'',vis:'',
               endsWithMain:false,hasSaveTail:false,hasEndMark:false,looksComplete:false,
               afterLines:0,codeTail:'',inputBtns:[]};
      try{out.vis=document.visibilityState||'';}catch(e){}
      // 虚拟滚动只渲染可视区：对话很长、滚动条没跟到底时，最新代码可能不在 DOM 里。
      // 浏览器窗口本身是隐形的，滚到底不会打扰用户，但能让虚拟列表把最新一段渲染出来，
      // 后面量 codeLen / textLen 才不会量到一段旧的、静止的内容。
      try{var vl=document.querySelector('.ds-virtual-list'); if(vl) vl.scrollTop=vl.scrollHeight;}catch(e){}
      var btns=document.querySelectorAll('[role=button],button');
      for(var i=0;i<btns.length;i++){
        var b=btns[i];
        // 不能用 offsetParent===null 判隐藏：position:fixed 的元素 offsetParent 也是 null。
        // 漏掉「停止」按钮 → generating 一直 false → 以为没在生成，提前点继续把生成掐死。
        var _st=getComputedStyle(b);
        if(_st.display==='none'||_st.visibility==='hidden'||parseFloat(_st.opacity||'1')<0.1) continue;
        var _rc=b.getBoundingClientRect();
        if(_rc.width<1||_rc.height<1) continue;
        var raw=((b.getAttribute('aria-label')||'')+' '+(b.getAttribute('title')||'')+' '+(b.innerText||''));
        var t=raw.replace(/\s+/g,'');
        if(!t) continue;
        if(t.indexOf('停止')>=0 || t.indexOf('中止')>=0 || /^stop/i.test(t)){
          out.generating=true;
          if(!out.stopLabel) out.stopLabel=t.slice(0,16);
        }
        if(/^(继续|继续生成|继续回复|继续输出)$/.test(t) || /^continue$/i.test(t)){
          out.hasContinue=true;
          if(!out.contLabel) out.contLabel=t.slice(0,16);
        }
      }
      var pres=document.querySelectorAll('.md-code-block pre');
      if(!pres.length) pres=document.querySelectorAll('pre');
      var total=0;
      for(var j=0;j<pres.length;j++){ total+=(pres[j].textContent||'').length; }
      out.pres=pres.length;
      out.codeLen=total;
      out.blocks=pres.length;
      out.codes=document.querySelectorAll('code').length;
      out.textLen=(document.body.textContent||'').length;

      // 语义判定任何时候都做，不能只在「没在生成」时做：
      // 2026-10-25 实测，深度思考会在出字间隙停很久、停止按钮还是纯图标，
      // generating 很容易在思考间隙误报 false，旧代码这时只看“稳定 10 秒”就抓代码，
      // 抓到的正是写了一半、字符串都没闭合的截断脚本。结束标记必须随时能被看到。
      if(pres.length){
        var last=pres[pres.length-1];
        var code=last.textContent||'';
        var tail=code.replace(/\s+$/,'');
        // 去掉尾部的纯注释行——AI 有时会在收尾后面补一段使用说明
        var ls=tail.split('\n');
        while(ls.length && /^\s*#/.test(ls[ls.length-1])) ls.pop();
        var clean=ls.join('\n').replace(/\s+$/,'');
        out.codeTail=clean.slice(-90);

        // 【最强信号】AI 按提示词要求在最后一行打的结束标记
        out.hasEndMark=/#\s*===LECTURE-END===/i.test(clean.slice(-300));

        // 收尾标志一：末尾出现 .save(...) 调用（规则要求最后 doc.save，实测 AI 常写 b.save(OUT_NAME)）
        // 括号必须闭合，否则「b.save(OUT_NA」这种写了一半的也会算进来
        out.hasSaveTail=/\.save\s*\([^)]*\)/.test(clean.slice(-400));

        // 收尾标志二：if __name__ == "__main__": main()
        var tailWin=clean.slice(-500);
        var hasGuard=/if\s+__name__\s*==\s*["']__main__["']\s*:/.test(tailWin);
        var endsMain=/main\s*\(\s*\)\s*$/.test(clean);
        out.endsWithMain=hasGuard&&endsMain;

        // 任一命中就算「脚本看起来写完了」
        out.looksComplete=out.hasEndMark||out.hasSaveTail||out.endsWithMain;

        // 代码块之后还有几行非空文字
        try{
          var host=last.closest('.ds-markdown')||document.body;
          var full=host.textContent||'';
          var pos=full.lastIndexOf(code);
          var after=pos>=0?full.slice(pos+code.length):'';
          var lines=after.split('\n');
          var n=0;
          for(var k=0;k<lines.length;k++){ if(lines[k].trim()) n++; }
          out.afterLines=n;
        }catch(e){}
      }

      // 输入区按钮（诊断用）
      try{
        var ta=document.querySelector('textarea');
        if(ta){
          var box=ta;
          for(var u=0;u<5&&box.parentElement;u++) box=box.parentElement;
          var ib=box.querySelectorAll('[role=button],button');
          for(var m=0;m<ib.length&&m<8;m++){
            out.inputBtns.push(
              ((ib[m].getAttribute('aria-label')||'')+'|'
               +(ib[m].innerText||'').replace(/\s+/g,'')).slice(0,24));
          }
        }
      }catch(e){}
      return JSON.stringify(out);
    })()
    """#

    /// 点「继续生成」
    /// 关键：不用 element.click()（事件 isTrusted=false，且部分框架监听的是 pointerdown），
    /// 而是按真人的顺序把整套指针/鼠标事件派发一遍。
    /// 优先选 <button> 标签、其次靠页面下方的那个，避免点到纯文字标签。
    static let clickContinue = #"""
    (function(){
      var cands=[];
      var all=document.querySelectorAll('button,[role=button],a');
      for(var i=0;i<all.length;i++){
        var b=all[i];
        // 同 probeComposer：offsetParent 判不出 position:fixed 的元素，改用尺寸判断。
        var _st=getComputedStyle(b);
        if(_st.display==='none'||_st.visibility==='hidden'||parseFloat(_st.opacity||'1')<0.1) continue;
        var _rc=b.getBoundingClientRect();
        if(_rc.width<1||_rc.height<1) continue;
        var t=(b.innerText||'').replace(/\s+/g,'').trim();
        if(!t || t.length>8) continue;
        if(/^(继续|继续生成|继续回复|继续输出)$/.test(t) || /^continue$/i.test(t)) cands.push(b);
      }
      if(!cands.length) return 'NOT_FOUND';

      cands.sort(function(a,b){
        var sa = a.tagName==='BUTTON' ? 0 : (a.getAttribute('role')==='button' ? 1 : 2);
        var sb = b.tagName==='BUTTON' ? 0 : (b.getAttribute('role')==='button' ? 1 : 2);
        if(sa!==sb) return sa-sb;
        return b.getBoundingClientRect().top - a.getBoundingClientRect().top;
      });

      var el=cands[0];
      try{ el.scrollIntoView({block:'center'}); }catch(e){}

      var r=el.getBoundingClientRect();
      if(r.width<2 || r.height<2) return 'ZERO_SIZE';

      var x=r.left+r.width/2, y=r.top+r.height/2;

      // 用命中测试确认这个坐标上真正在最上层的是谁——按钮可能被透明遮罩盖着
      var hitInfo='';
      try{
        var hit=document.elementFromPoint(x,y);
        if(hit && hit!==el && !el.contains(hit)){
          hitInfo=' hit='+hit.tagName.toLowerCase()+(hit.className?('.'+String(hit.className).split(/\s+/)[0]):'');
          var node=hit, found=null;
          for(var k=0;k<5 && node;k++){
            var nt=(node.innerText||'').replace(/\s+/g,'').trim();
            if(/^(继续|继续生成|继续回复|继续输出)$/.test(nt) || /^continue$/i.test(nt)){ found=node; break; }
            node=node.parentElement;
          }
          if(found){ el=found; r=el.getBoundingClientRect(); x=r.left+r.width/2; y=r.top+r.height/2; hitInfo+=' →retarget'; }
        }
      }catch(e){}

      var base={bubbles:true,cancelable:true,composed:true,view:window,
                clientX:x,clientY:y,screenX:x,screenY:y,
                button:0,buttons:1,detail:1};
      function ptr(t){
        try{
          var o=Object.assign({pointerId:1,pointerType:'mouse',isPrimary:true,width:1,height:1},base);
          el.dispatchEvent(new PointerEvent(t,o));
        }catch(e){}
      }
      function mouse(t,btns){
        try{ el.dispatchEvent(new MouseEvent(t,Object.assign({},base,{buttons:btns}))); }catch(e){}
      }

      ptr('pointerover'); mouse('mouseover',0);
      ptr('pointerenter'); mouse('mouseenter',0);
      ptr('pointermove'); mouse('mousemove',0);
      ptr('pointerdown'); mouse('mousedown',1);
      try{ el.focus(); }catch(e){}
      ptr('pointerup'); mouse('mouseup',0);
      mouse('click',0);

      var info={
        tag:el.tagName.toLowerCase(),
        cls:(el.className||'').toString().slice(0,60),
        text:(el.innerText||'').replace(/\s+/g,''),
        disabled:!!el.disabled,
        aria:(el.getAttribute('aria-disabled')||''),
        pe:(getComputedStyle(el).pointerEvents||''),
        x:Math.round(x), y:Math.round(y),
        w:Math.round(r.width), h:Math.round(r.height),
        cands:cands.length,
        vis:(document.visibilityState||'')
      };
      return 'CLICKED:'+JSON.stringify(info)+hitInfo;
    })()
    """#

    /// 把所有代码块装进 window.__wbCode（百分号编码），返回总长度
    /// 按 20261025 快照的真实结构：div.md-code-block > pre（无 code 子元素）
    static let grabBlocksBuild = #"""
    window.__wbCode=encodeURIComponent((function(){
      var arr=[];
      function push(t){
        t=(t||'').replace(/\r\n/g,'\n');
        // 剥掉 AI 打的结束标记行，别让它混进要执行的脚本里
        t=t.replace(/\n?[ \t]*#[ \t]*===LECTURE-END===[ \t]*$/i,'');
        t=t.replace(/\s+$/,'');
        if(t.length>60 && arr.indexOf(t)<0) arr.push(t);
      }
      var nodes=document.querySelectorAll('.md-code-block pre');
      if(!nodes.length) nodes=document.querySelectorAll('pre');
      if(!nodes.length) nodes=document.querySelectorAll('pre code');
      for(var i=0;i<nodes.length;i++) push(nodes[i].textContent);
      return JSON.stringify(arr);
    })());
    window.__wbCode.length
    """#

    static func grabBlocksChunk(from: Int, to: Int) -> String {
        "window.__wbCode.substring(\(from),\(to))"
    }

    /// 只定位「继续」按钮，返回它在视口里的中心坐标（给真实鼠标点击用）
    static let locateContinue = #"""
    (function(){
      var cands=[];
      var all=document.querySelectorAll('button,[role=button]');
      for(var i=0;i<all.length;i++){
        var b=all[i];
        var cs=getComputedStyle(b);
        // 不能用 offsetParent===null 判隐藏：position:fixed 的元素 offsetParent
        // 同样是 null，会把吸附在底部的按钮误判成不存在。改用 display + 实际尺寸。
        if(cs.display==='none'||cs.visibility==='hidden'||parseFloat(cs.opacity||'1')<0.1) continue;
        var r0=b.getBoundingClientRect();
        if(r0.width<1||r0.height<1) continue;
        // 2026-10-29 用户 DevTools 实测（试卷识别 app 同步过来）：这个按钮是
        //   <div role="button" class="ds-button …"><span class="ds-button__content">继续生成</span></div>
        // 文字装在 ds-button__content 里，读它比读整个 innerText 稳（不会被图标等子元素干扰）。
        var c=b.querySelector('.ds-button__content');
        var t=((c?c.innerText:b.innerText)||'').replace(/\s+/g,'').trim();
        if(!t||t.length>8) continue;
        if(/^(继续|继续生成|继续回复|继续输出)$/.test(t)||/^continue$/i.test(t)) cands.push(b);
      }
      if(!cands.length) return 'NOT_FOUND';
      cands.sort(function(a,b){
        // ds-button（DeepSeek 设计系统按钮）优先，其次普通 button，最后其它 role=button
        var sa=/ds-button/.test(a.className)?0:(a.tagName==='BUTTON'?1:2);
        var sb=/ds-button/.test(b.className)?0:(b.tagName==='BUTTON'?1:2);
        if(sa!==sb) return sa-sb;
        return b.getBoundingClientRect().top - a.getBoundingClientRect().top;
      });
      var el=cands[0];
      var vw=window.innerWidth, vh=window.innerHeight;
      var r=el.getBoundingClientRect();
      if(r.width<2||r.height<2) return 'ZERO_SIZE';

      // ① 只有真的看不见才滚动。
      //    原来无条件 scrollIntoView({behavior:'instant'})，而 'instant' 不是标准值
      //    （标准只有 'auto' / 'smooth'），WebKit 会退回平滑滚动 —— 下一行立刻取的 rect
      //    还是滚动前的旧坐标，点下去就落到别处。这就是「点空」最可能的原因。
      //    现在：在视口里就不滚；要滚就返回 SCROLLING，让 Swift 等滚动停下再取一次。
      var fullyVisible = r.top>=2 && r.bottom<=vh-2 && r.left>=0 && r.right<=vw;
      if(!fullyVisible){
        try{ el.scrollIntoView({block:'center',behavior:'auto'}); }
        catch(e){ try{ el.scrollIntoView(); }catch(e2){} }
        return 'SCROLLING';
      }

      // ② 命中测试：这个点上最顶层的元素必须就是按钮本身或它的子孙。
      //    防的是「按钮正在淡出 / 被浮层盖住 / 坐标过期」，这时点下去会点到别的东西。
      var cx=r.left+r.width/2, cy=r.top+r.height/2;
      var hit=document.elementFromPoint(cx,cy);
      if(!hit) return 'NOT_HIT:none';
      if(!(hit===el||el.contains(hit))){
        var d=(hit.tagName||'?')+':'+((hit.innerText||'').replace(/\s+/g,'').slice(0,8));
        return 'NOT_HIT:'+d;
      }

      return JSON.stringify({
        x:Math.round(cx*10)/10,
        y:Math.round(cy*10)/10,
        w:Math.round(r.width), h:Math.round(r.height),
        vw:vw, vh:vh,
        text:(el.innerText||'').replace(/\s+/g,''),
        vis:(document.visibilityState||''),
        dpr:(window.devicePixelRatio||1)
      });
    })()
    """#

    /// 只判断「刚点过的那个继续按钮」还在不在 —— 不滚动、不点击、无副作用。
    ///
    /// 用途：判断上一次点击到底有没有被页面接受。用户 2026-10-29 实测——
    /// 手点下去按钮**瞬间消失**，绝不会变成「停止」，所以「按钮还在不在」
    /// 比「N 秒内有没有涨字」可靠得多（AI 点完要先想十几秒才出字）。
    ///
    /// ⚠️ 只认 `nearY`（点击时的视口 y）±40px 那个位置上的按钮，不能写成
    /// 「页面上有任意一个继续按钮就算」—— `locateContinue` 是按 top 降序取
    /// **最靠下**（最新）的那个去点，两套判据必须对齐。历史消息里如果还留着
    /// 旧的「继续生成」按钮（DOM 没清掉），按「任意一个」判就会永远认为
    /// 「按钮还在」→ 误判成「点击被吞」→ 攒够 2 次直接抛错。
    /// `nearY` 为 nil 时退化成「任意位置存在即算」，只在走 JS 兜底点击时发生。
    static func probeContinue(nearY: Double?) -> String {
        let nearFilter = nearY.map {
            "if(Math.abs((r.top+r.height/2)-\($0))>40) continue;"
        } ?? ""
        return """
        (function(){
          var all=document.querySelectorAll('button,[role=button]');
          for(var i=0;i<all.length;i++){
            var b=all[i];
            var st=getComputedStyle(b);
            // 不能用 offsetParent===null 判隐藏：position:fixed 的元素 offsetParent
            // 同样是 null，会把吸附在底部的按钮误判成不存在。改用 display + 实际尺寸。
            if(st.display==='none'||st.visibility==='hidden'||parseFloat(st.opacity||'1')<0.1) continue;
            var r=b.getBoundingClientRect();
            if(r.width<1||r.height<1) continue;
            var c=b.querySelector('.ds-button__content');
            var t=((c?c.innerText:b.innerText)||'').replace(/\\s+/g,'').trim();
            if(!t||t.length>8) continue;
            if(!(/^(继续|继续生成|继续回复|继续输出)$/.test(t)||/^continue$/i.test(t))) continue;
            \(nearFilter)
            return 'YES';
          }
          return 'NO';
        })()
        """
    }

    /// 把 Swift 字符串安全地塞进 JS 源码里（转义引号、换行、反斜杠、emoji 都能过）
    private static func jsString(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(
                withJSONObject: s, options: .fragmentsAllowed),
              let text = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return text
    }
}
