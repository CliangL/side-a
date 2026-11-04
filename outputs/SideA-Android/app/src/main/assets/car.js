'use strict';
const carRoutes = new Map();
let carScrubbing = false, carLyricTrack = '', carLyricRequest = 0, carLines = [], carActiveLine = -1;
let carLyricFollowAfter = 0, carLyricFollowTimer = 0;
const carLyricCache = new Map(), carLyricPending = new Map();
function setupCarLayout() {
  const car = st.uiMode === 'car';
  document.documentElement.classList.toggle('car', car);
  el('carNav').hidden = el('carNow').hidden = !car;
  el('dock').hidden = car;
}
function carNavigate(name) {
  if (current().name === 'search' && !current().target) carRoutes.set('search', current());
  if (st.sheet) closeSheet();
  st.routes = [name === 'search' ? carRoutes.get('search') || { name } : { name }];
  st.tab = 0;
  render(true);
  el('main').scrollTop = 0;
  if (name === 'settings') refreshStorage().catch(e => notify(e.message));
}
function renderCarNav() {
  const name = current().name, lyricsOpen = name === 'carLyrics';
  document.documentElement.classList.toggle('car-lyrics-open', lyricsOpen);
  const selected = ['playlist'].includes(name) ? 'library' : ['mix','recent','related'].includes(name) ? 'home' : name;
  const nav = el('carNav');
  nav.hidden = false;
  if (!nav.querySelector('.car-disc-button')) {
    nav.innerHTML = '<button class="car-disc-button" '+attr('carLyrics')+' aria-label="打开全屏歌词"><span class="car-disc"></span></button><div class="car-nav-items">' +
      [['home','home','推荐'],['search','search','搜索'],['favorites','heart','收藏'],['library','lib','歌单'],['settings','gear','设置']]
        .map(([route,icon,title]) => '<button '+attr('carNav',route)+'>'+ic(icon)+'<span>'+title+'</span></button>').join('')+'</div>';
  }
  if (nav.dataset.page !== selected) {
    nav.dataset.page = selected;
    nav.querySelectorAll('[data-act="carNav"]').forEach(button => {
      const active = button.dataset.arg === selected;
      button.classList.toggle('sel', active);
      if (active) button.setAttribute('aria-current','page');
      else button.removeAttribute('aria-current');
    });
  }
  const p = st.player, t = p.track, disc = nav.querySelector('.car-disc'), button = nav.querySelector('.car-disc-button');
  const track = t ? key(t) : '';
  // Keep this element mounted so normal progress polls never restart rotation.
  if (disc.dataset.track !== track) {
    disc.dataset.track = track;
    disc.innerHTML = (t ? art(t,'car-disc-art') : '<span class="car-disc-idle side">A.</span>') + '<span class="car-disc-hole" aria-hidden="true"></span>';
    scanArt(disc);
  }
  disc.classList.toggle('is-spinning', Boolean(t && p.playing && !p.loading));
  button.disabled = !t;
  button.classList.toggle('is-open', lyricsOpen);
  button.setAttribute('aria-pressed', String(lyricsOpen));
  button.setAttribute('aria-label', t ? '打开 '+t.title+' 的全屏歌词' : '尚未播放歌曲');
}
function carHeader(title, subtitle = '', action = '') {
  return '<header class="car-header"><div><p class="caps">SIDE A / ON THE ROAD</p><h1>' + esc(title) +
    '</h1>' + (subtitle ? '<p class="hint">' + esc(subtitle) + '</p>' : '') + '</div>' + action + '</header>';
}
function carHome() {
  return '<div class="car-page">' + carHeader('一路，好音乐', '', bt('recent','','最近播放',ic('clock'),'round')) +
    '<div class="car-mixes">' + [0,1,2].map(i => {
      const songs = itemsFor({name:'mix',index:i});
      return '<button class="car-mix" ' + attr('mix',i) + '>' + art(songs[0], 'car-mix-art') +
        '<span class="car-mix-shade"></span><span class="car-mix-caption"><small>' + ['YOUR MIX','TRENDING','NEW RELEASES'][i] +
        '</small><strong>' + esc(mixes[i]) + '</strong><span>' + ic('right') + '</span></span></button>';
    }).join('') + '</div><div class="car-section-head"><h2>顺着你的口味</h2>' + textBtn('batch','','换一批','pill') +
    '</div><div class="car-song-list">' + (recs().length ? rows(Array.from({length:Math.min(recs().length,6)},(_,i)=>recs()[(i+st.batch*3)%recs().length]),'car-personal',{menu:false}) : empty('推荐曲目正在准备')) + '</div></div>';
}
function carLibrary() {
  return '<div class="car-page">' + carHeader('我的歌单', st.library.playlists.length + ' 张私人歌单',bt('newList','','新建歌单',ic('plus'),'round')) +
    '<div class="car-playlists">' + (st.library.playlists.map(p => bt('playlist',p.id,p.name,art(p.cover || p.tracks[0],'car-list-cover') +
      '<span class="txt"><strong>' + esc(p.name) + '</strong><small>' + p.tracks.length + ' 首歌曲</small></span>' + ic('right'),'car-list-entry')).join('') ||
      '<div class="car-empty-list">' + ic('lib') + '<h2>留一张歌单给旅途</h2><p class="hint">收藏喜欢的歌，或创建自己的歌单。</p>' + textBtn('newList','','新建歌单','primary pill') + '</div>') + '</div></div>';
}
function carCollection(r) {
  const list = st.library.playlists.find(p => String(p.id) === r.id), songs = itemsFor(r);
  const title = {playlist:list?.name || '歌单',favorites:'我的收藏',recent:'最近播放',related:'沿着这首听',mix:mixes[r.index]}[r.name];
  return '<div class="car-page">' + carHeader(title,descFor(r),r.name === 'playlist' ? bt('listMenu',r.id,'歌单管理',ic('more'),'round') : '') +
    '<div class="car-collection-actions">' + bt('playDetail','','播放全部',ic('play') + '播放全部','primary pill') +
    bt('shuffleDetail','','随机播放',ic('shuffle') + '随机','pill') + bt('filter','','歌单内搜索',ic('search'),'round') +
    (list ? textBtn('addMany',list.id,'添加歌曲','pill') : r.name === 'mix' || r.name === 'related' ? textBtn('saveMix','','存为歌单','pill') : '') +
    '</div><div id="filterbox"></div><div id="collectionRows">' + collectionRows(r,'') + '</div></div>';
}
function carPageHTML(r) {
  if (r.name === 'home') return carHome();
  if (r.name === 'library') return carLibrary();
  if (r.name === 'carLyrics') return '<div class="car-lyrics-page"><header class="car-lyrics-header">' +
    bt('back','','返回曲库',ic('back'),'round') + '<div class="car-lyrics-heading"><h1 id="carLyricsTitle">'+esc(st.player.track?.title || '同步歌词')+
    '</h1><p id="carLyricsArtist">'+esc(st.player.track?.artist || '')+'</p></div><span class="car-lyrics-header-spacer" aria-hidden="true"></span></header>' +
    '<div id="carLyrics" class="car-lyrics" aria-label="同步歌词" tabindex="0"></div></div>';
  if (['mix','favorites','recent','playlist','related'].includes(r.name)) return carCollection(r);
  return null;
}
function renderCarNow() {
  const p = st.player, t = p.track, panel = el('carNow');
  if (!el('carProgress')) {
    panel.innerHTML = '<div class="car-progress-wrap"><input id="carProgress" type="range" class="progress" min="0" max="1" step="0.1" value="0" aria-label="播放进度"><div class="times"><span id="carElapsed">0:00</span><span id="carDuration">0:00</span></div></div>' +
      '<div class="car-track-info"></div><div class="car-controls"></div><div class="car-now-tools"></div><div class="car-play-error" role="status" hidden></div>';
    const seek = el('carProgress');
    seek.oninput = () => { carScrubbing = true; updateCarProgress(Number(seek.value)); };
    seek.onchange = () => { carScrubbing = false; playCmd('seek',{seconds:Number(seek.value)}).catch(e=>notify(e.message)); };
    seek.onpointercancel = () => { carScrubbing = false; updateCarProgress(); };
  }
  const info = panel.querySelector('.car-track-info');
  const infoSig = [t ? key(t) : '',t?.title,t?.artist,p.quality,p.loading].join('|');
  if (info.dataset.sig !== infoSig) {
    info.dataset.sig = infoSig;
    info.innerHTML = t ? '<button class="car-song-title" '+attr('carLyrics')+' aria-label="打开全屏歌词"><strong>'+esc(t.title)+'</strong><span>'+esc(p.loading ? '载入中…' : t.artist)+'</span></button>' :
      '<div class="car-song-title"><strong>好音乐，随时出发</strong><span>选一首歌，开始今天的旅途</span></div>';
  }
  const controls = panel.querySelector('.car-controls');
  const controlSig = [Boolean(t),p.playing,p.mode,t && favorite(t)].join('|');
  if (controls.dataset.sig !== controlSig) {
    controls.dataset.sig = controlSig;
    controls.innerHTML = carControl('carMode','切换播放模式',ic(p.mode === 'shuffle' ? 'shuffle' : p.mode === 'repeatOne' ? 'repeat' : 'queue')+'<small>'+({sequence:'顺序',shuffle:'随机',repeatOne:'单曲'}[p.mode]||'顺序')+'</small>',!t,'mode '+(p.mode !== 'sequence'?'sel':'')) +
      carControl('prev','上一首',ic('prev'),!t) + carControl('toggle',p.playing?'暂停':'播放',ic(p.playing?'pause':'play'),!t,'car-play') + carControl('next','下一首',ic('next'),!t) +
      carControl('currentFavorite',t && favorite(t)?'取消收藏':'收藏歌曲',ic('heart',t && favorite(t)),!t,'fav '+(t && favorite(t)?'on':''));
  }
  const tools = panel.querySelector('.car-now-tools');
  const toolsSig = [Boolean(t),soundPreset()].join('|');
  if (tools.dataset.sig !== toolsSig) {
    tools.dataset.sig = toolsSig;
    tools.innerHTML = carControl('quality','播放音质',ic('wave')+'<span>音质</span>',!t) + carControl('sound','场景音效',ic('equal')+'<span>'+esc(soundName())+'</span>',false) + carControl('queue','待播列表',ic('queue')+'<span>待播</span>',!t);
  }
  const error = panel.querySelector('.car-play-error');
  error.hidden = !p.error;
  if (error.dataset.message !== (p.error || '')) {
    error.dataset.message = p.error || '';
    error.innerHTML = p.error ? '<span>'+esc(p.error)+'</span>'+textBtn('retryPlay','','重试播放','pill') : '';
  }
  if (!carScrubbing) updateCarProgress();
}
function carControl(action,label,content,disabled,cls='') {
  return '<button '+attr(action)+' aria-label="'+esc(label)+'" class="'+cls+'" '+(disabled?'disabled':'')+'>'+content+'</button>';
}
function updateCarProgress(value = st.player.elapsed) {
  const input=el('carProgress');
  if (!input) return;
  const duration=Math.max(0,Number(st.player.duration)||0),elapsed=Math.max(0,Math.min(duration,Number(value)||0));
  input.max=duration||1;input.value=elapsed;input.disabled=!duration;
  input.style.setProperty('--pct',(duration?100*elapsed/duration:0)+'%');
  el('carElapsed').textContent=time(elapsed);el('carDuration').textContent=time(duration);
}
function carOpenLyrics() {
  if (!st.player.track) return;
  if (current().name !== 'carLyrics') go({name:'carLyrics'});
}
function mountCarPage(r) {
  clearTimeout(carLyricFollowTimer);
  if (r.name !== 'carLyrics') return;
  const body = el('carLyrics');
  const deferFollow = () => {
    carLyricFollowAfter = Date.now()+5000;
    clearTimeout(carLyricFollowTimer);
    carLyricFollowTimer = setTimeout(() => {
      if (body.isConnected && current().name === 'carLyrics') focusCarLine(true);
    },5100);
  };
  body.addEventListener('touchmove',deferFollow,{passive:true});
  body.addEventListener('wheel',deferFollow,{passive:true});
  body.addEventListener('keydown',e=>{if(['ArrowUp','ArrowDown','PageUp','PageDown','Home','End'].includes(e.key))deferFollow();});
  carLyricTrack='';carLyricFollowAfter=0;updateCarLyrics();
}
function carLyricsFor(t) {
  const id = key(t);
  if (carLyricCache.has(id)) return Promise.resolve(carLyricCache.get(id));
  if (!carLyricPending.has(id)) {
    carLyricPending.set(id,req('lyrics',{track:t}).then(result=>{
      const resultLines=(Array.isArray(result)?result:[]).filter(l=>Number.isFinite(Number(l.time))&&String(l.text||'').trim()).sort((a,b)=>a.time-b.time);
      if(carLyricCache.size>=8)carLyricCache.delete(carLyricCache.keys().next().value);
      carLyricCache.set(id,resultLines);
      return resultLines;
    }).finally(()=>carLyricPending.delete(id)));
  }
  return carLyricPending.get(id);
}
async function updateCarLyrics() {
  const body=el('carLyrics'),t=st.player.track;
  if (!body || current().name !== 'carLyrics') return;
  el('carLyricsTitle').textContent=t?.title || '同步歌词';
  el('carLyricsArtist').textContent=t?.artist || '';
  if(!t){
    carLyricRequest++;carLyricTrack='';carLines=[];carActiveLine=-1;
    body.innerHTML=empty('还没有正在播放的歌曲');
    return;
  }
  if (carLyricTrack !== key(t)) {
    carLyricTrack=key(t);carActiveLine=-1;carLines=[];carLyricFollowAfter=0;
    clearTimeout(carLyricFollowTimer);
    const id=++carLyricRequest,track=carLyricTrack;
    body.scrollTop=0;
    body.innerHTML=empty('正在读取歌词…');
    try {
      const result=await carLyricsFor(t);
      if (id!==carLyricRequest || track!==key(st.player.track) || !body.isConnected || current().name!=='carLyrics') return;
      carLines=result;
      body.innerHTML=carLines.length ? carLines.map((l,i)=>bt('carSeekLine',i,'播放这一句：'+l.text,esc(l.text)+(l.translation&&l.translation!==l.text?'<small>'+esc(l.translation)+'</small>':''),'car-lyric-line')).join('') : empty('这首歌暂未提供歌词');
      focusCarLine(true);
    } catch(e) {
      if(id===carLyricRequest&&body.isConnected&&current().name==='carLyrics')body.innerHTML=empty('歌词暂未载入')+textBtn('carRetryLyrics','','重新载入','pill');
    }
    return;
  }
  focusCarLine();
}
function focusCarLine(force=false) {
  const body=el('carLyrics');
  if(!body || current().name!=='carLyrics' || !carLines.length)return;
  let index=carLines.length-1;
  while(index>=0 && Number(carLines[index].time)>Number(st.player.elapsed||0))index--;
  if(index===carActiveLine && !force)return;
  body.querySelector('.active')?.classList.remove('active');
  const line=index>=0?body.children[index]:null;
  if(line){
    line.classList.add('active');
    if(Date.now()>carLyricFollowAfter){
      const top=line.getBoundingClientRect().top-body.getBoundingClientRect().top+body.scrollTop-body.clientHeight*.43+line.clientHeight*.5;
      body.scrollTo({top:Math.max(0,top),behavior:force||matchMedia('(prefers-reduced-motion:reduce)').matches?'instant':'smooth'});
    }
  }
  carActiveLine=index;
}
Object.assign(actions,{
  carNav:carNavigate,
  carLyrics:carOpenLyrics,
  carRetryLyrics:()=>{if(st.player.track)carLyricCache.delete(key(st.player.track));carLyricTrack='';return updateCarLyrics();},
  carSeekLine:async i=>{
    const line=carLines[Number(i)],track=key(st.player.track);
    if(!line)return;
    carLyricFollowAfter=0;clearTimeout(carLyricFollowTimer);
    await playCmd('seek',{seconds:Number(line.time)});
    if(key(st.player.track)===track && current().name==='carLyrics')focusCarLine(true);
  },
  carMode:()=>{const modes=['sequence','shuffle','repeatOne'];return playCmd('mode',{mode:modes[(modes.indexOf(st.player.mode)+1)%modes.length]});},
});
