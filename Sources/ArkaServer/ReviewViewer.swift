import Foundation

/// The static web viewer for playback-level review (multiplayer.md). Plays a shared Lottie with
/// lottie-web (real scrubbable timeline), and lets a viewer comment at a timeline moment + drop a
/// board pin. The page reads its share id from the URL (`/v/<id>`) and talks to `/share/<id>/…`.
enum ReviewViewer {
    static let html = """
    <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <title>Arka Review</title>
    <script src="https://cdnjs.cloudflare.com/ajax/libs/bodymovin/5.12.2/lottie.min.js"></script>
    <style>
      :root{color-scheme:dark}
      body{margin:0;font:13px -apple-system,system-ui,sans-serif;background:#1d1d20;color:#eee;display:flex;height:100vh}
      #main{flex:1;display:flex;flex-direction:column;min-width:0}
      #stageWrap{flex:1;display:flex;align-items:center;justify-content:center;overflow:hidden}
      #stage{position:relative;background:#0e0e10;box-shadow:0 4px 24px #0008}
      #anim{width:100%;height:100%}
      #pins{position:absolute;inset:0;pointer-events:none}
      .pin{position:absolute;width:18px;height:18px;margin:-9px 0 0 -9px;border-radius:50% 50% 50% 0;
           background:#5b8cff;border:2px solid #fff;transform:rotate(-45deg);box-shadow:0 1px 4px #0009}
      .pin.active{background:#ffb020}
      #bar{display:flex;align-items:center;gap:10px;padding:10px 14px;background:#222;border-top:1px solid #333}
      #scrub{flex:1}
      button{background:#3a3a40;color:#eee;border:0;border-radius:6px;padding:6px 12px;cursor:pointer}
      button.on{background:#5b8cff}
      #side{width:280px;background:#202024;border-left:1px solid #333;display:flex;flex-direction:column}
      #side h2{font-size:13px;margin:0;padding:12px 14px;border-bottom:1px solid #333}
      #list{flex:1;overflow:auto}
      .c{padding:10px 14px;border-bottom:1px solid #2a2a2e;cursor:pointer}
      .c:hover{background:#26262b}
      .c .t{color:#9ab;font-variant-numeric:tabular-nums}
      .c .a{color:#888;font-size:11px}
      #hint{padding:8px 14px;color:#888;font-size:11px;border-top:1px solid #333}
    </style></head><body>
    <div id="main">
      <div id="stageWrap"><div id="stage"><div id="anim"></div><div id="pins"></div></div></div>
      <div id="bar">
        <button id="play">▶︎</button>
        <input id="scrub" type="range" min="0" max="1" step="0.001" value="0">
        <span id="time" style="font-variant-numeric:tabular-nums">0.0s</span>
        <button id="commentBtn">💬 Comment</button>
      </div>
    </div>
    <div id="side">
      <h2 id="title">Review</h2>
      <div id="list"></div>
      <div id="hint">Click 💬 then click the canvas to pin a note at the current time.</div>
    </div>
    <script>
    const id = location.pathname.split('/').filter(Boolean).pop();
    const api = (p) => '/share/' + id + p;
    let meta, anim, commenting = false, dur = 1, fps = 60;
    const stage = document.getElementById('stage'), pins = document.getElementById('pins');
    const scrub = document.getElementById('scrub'), timeEl = document.getElementById('time');
    const playBtn = document.getElementById('play'), list = document.getElementById('list');
    const author = localStorage.getItem('arka_author') || (() => { const a = prompt('Your name?') || 'Anonymous'; localStorage.setItem('arka_author', a); return a; })();

    function layout(){
      const wrap = document.getElementById('stageWrap'), pad = 32;
      const s = Math.min((wrap.clientWidth-pad)/meta.width, (wrap.clientHeight-pad)/meta.height);
      stage.style.width = (meta.width*s)+'px'; stage.style.height = (meta.height*s)+'px';
      renderPins();
    }
    function setTime(t){ scrub.value = t; timeEl.textContent = t.toFixed(2)+'s'; if(anim) anim.goToAndStop(t*fps, true); }

    async function boot(){
      meta = await (await fetch(api(''))).json();
      dur = meta.duration; fps = meta.fps;
      document.getElementById('title').textContent = meta.name + ' · ' + meta.scope;
      scrub.max = dur;
      const data = await (await fetch(api('/lottie'))).json();
      anim = lottie.loadAnimation({container:document.getElementById('anim'), renderer:'svg', loop:true, autoplay:false, animationData:data});
      anim.addEventListener('enterFrame', () => { if(playing){ scrub.value = anim.currentFrame/fps; timeEl.textContent=(anim.currentFrame/fps).toFixed(2)+'s'; }});
      layout(); setTime(0); loadComments();
    }
    let playing = false;
    playBtn.onclick = () => { playing = !playing; playBtn.textContent = playing?'❚❚':'▶︎'; playing?anim.play():anim.pause(); };
    scrub.oninput = () => { playing=false; playBtn.textContent='▶︎'; setTime(parseFloat(scrub.value)); };
    document.getElementById('commentBtn').onclick = (e) => { commenting=!commenting; e.target.classList.toggle('on',commenting); };
    stage.onclick = async (e) => {
      if(!commenting) return;
      const r = stage.getBoundingClientRect();
      const x = (e.clientX-r.left)/r.width*meta.width, y = (e.clientY-r.top)/r.height*meta.height;
      const text = prompt('Comment at '+parseFloat(scrub.value).toFixed(2)+'s:'); if(!text) return;
      await fetch(api('/comments'), {method:'POST', headers:{'content-type':'application/json'},
        body: JSON.stringify({time: parseFloat(scrub.value), pin:[x,y], author, text})});
      commenting=false; document.getElementById('commentBtn').classList.remove('on'); loadComments();
    };

    let comments = [], activeId = null;
    async function loadComments(){ comments = await (await fetch(api('/comments'))).json(); renderList(); renderPins(); }
    function renderList(){
      list.innerHTML='';
      comments.forEach(c => {
        const el = document.createElement('div'); el.className='c';
        el.innerHTML = '<span class="t">'+c.time.toFixed(2)+'s</span> '+escapeHtml(c.text)+'<div class="a">'+escapeHtml(c.author)+'</div>';
        el.onclick = () => { activeId=c.id; setTime(c.time); playing=false; playBtn.textContent='▶︎'; renderPins(); };
        list.appendChild(el);
      });
    }
    function renderPins(){
      pins.innerHTML='';
      comments.filter(c=>c.pin).forEach(c => {
        const d = document.createElement('div'); d.className='pin'+(c.id===activeId?' active':'');
        d.style.left=(c.pin[0]/meta.width*100)+'%'; d.style.top=(c.pin[1]/meta.height*100)+'%';
        pins.appendChild(d);
      });
    }
    function escapeHtml(s){ return s.replace(/[&<>"]/g, m=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[m])); }
    window.onresize = () => meta && layout();
    boot();
    </script></body></html>
    """
}
