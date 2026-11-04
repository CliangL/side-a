'use strict';
const carRoutes = new Map();
let carScrubbing = false, carLyricTrack = '', carLyricRequest = 0, carLines = [], carActiveLine = -1;
let carLyricFollowAfter = 0;
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
  const name = current().name;
  const selected = ['playlist'].includes(name) ? 'library' : ['mix','recent','related'].includes(name) ? 'home' : name;
  const nav = el('carNav');
  if (nav.dataset.page === selected) return;
  nav.dataset.page = selected;
  nav.innerHTML = '<div class="car-brand"><span class="side">A.</span><span>SIDE A</span></div><div class="car-nav-items">' +
    [['home','home','推荐'],['search','search','搜索'],['favorites','heart','收藏'],['library','lib','歌单'],['settings','gear','设置']]
      .map(([route,icon,title]) => '<button ' + attr('carNav',route) + ' class="' + (selected === route ? 'sel' : '') + '" ' +
        (selected === route ? 'aria-current="page"' : '') + '>' + ic(icon) + '<span>' + title + '</span></button>').join('') + '</div>';
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
  if (r.name === 'carLyrics') return '<div class="car-lyrics-page">' + carHeader('同步歌词','',bt('back','','返回',ic('back'),'round')) +
    '<div id="carLyrics" class="car-lyrics" aria-label="同步歌词"></div></div>';
  if (['mix','favorites','recent','playlist','related'].includes(r.name)) return carCollection(r);
  return null;
}
function renderCarNow() {
  const p = st.player, t = p.track, panel = el('carNow');
  const sig = [t ? key(t) : '', p.playing,p.loading,p.error,p.quality,p.mode,t && favorite(t),soundPreset(),p.sound?.status].join('|');
  if (panel.dataset.sig !== sig) {
    panel.dataset.sig = sig;
    panel.innerHTML = '<div class="car-now-head">' + (t ? '<button class="car-quality" '+attr('quality')+' aria-label="播放音质">'+ic('wave')+esc(p.quality || '等待音源')+ic('right')+'</button>' : '<span class="caps">YOUR PRIVATE RADIO</span>') + (t ? bt('currentFavorite','','收藏歌曲',ic('heart',favorite(t)),'icbtn fav '+(favorite(t)?'on':'')) : '<span class="car-now-mark">33⅓</span>') + '</div>' +
      (t ? '<button class="car-cover-button" '+attr('carLyrics')+' aria-label="查看歌词">' + art(t,'car-cover') + '</button><div class="car-song-title"><h2>' + esc(t.title) +
        '</h2><p>' + esc(t.artist) + '</p></div>' :
        '<div class="car-idle-art"><div class="vinyl"></div><span class="side">Side A</span></div><div class="car-song-title"><h2>好音乐，随时出发</h2><p>选一首歌，开始今天的旅途</p></div>') +
      '<div class="car-progress-wrap"><input id="carProgress" type="range" class="progress" min="0" max="1" step="0.1" value="0" aria-label="播放进度"><div class="times"><span id="carElapsed">0:00</span><span id="carDuration">0:00</span></div></div>' +
      '<div class="car-controls">' + carControl('carMode','切换播放模式',ic(p.mode === 'shuffle' ? 'shuffle' : p.mode === 'repeatOne' ? 'repeat' : 'queue')+'<small>'+({sequence:'顺序',shuffle:'随机',repeatOne:'单曲'}[p.mode]||'顺序')+'</small>',!t,'mode '+(p.mode !== 'sequence'?'sel':'')) +
      carControl('prev','上一首',ic('prev'),!t) + carControl('toggle',p.playing?'暂停':'播放',ic(p.playing?'pause':'play'),!t,'car-play') +
      carControl('next','下一首',ic('next'),!t) + '</div>' +
      '<div class="car-now-tools">' + carControl('carLyrics','歌词',ic('lyrics')+'<span>歌词</span>',!t) +
      carControl('sound','场景音效',ic('equal')+'<span>'+esc(soundName())+'</span>',false) + carControl('queue','待播',ic('queue')+'<span>待播</span>',!t) + '</div>' +
      (p.error ? '<div class="car-play-error" role="status">' + esc(p.error) + textBtn('retryPlay','','重试播放','pill') + '</div>' :
        p.loading ? '<p class="car-load" role="status">正在载入音频…</p>' : '');
    const seek = el('carProgress');
    seek.oninput = () => { carScrubbing = true; updateCarProgress(Number(seek.value)); };
    seek.onchange = () => { carScrubbing = false; playCmd('seek',{seconds:Number(seek.value)}).catch(e=>notify(e.message)); };
    seek.onpointercancel = () => { carScrubbing = false; updateCarProgress(); };
    scanArt(panel);
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
  if (r.name !== 'carLyrics') return;
  el('carLyrics').ontouchmove=()=>{carLyricFollowAfter=Date.now()+5000;};
  carLyricTrack='';updateCarLyrics();
}
async function updateCarLyrics() {
  const body=el('carLyrics'),t=st.player.track;
  if (!body || !t || current().name !== 'carLyrics') return;
  if (carLyricTrack !== key(t)) {
    carLyricTrack=key(t);carActiveLine=-1;carLines=[];
    const id=++carLyricRequest,track=carLyricTrack;
    body.innerHTML=empty('正在读取歌词…');
    try {
      const result=await req('lyrics',{track:t});
      if (id!==carLyricRequest || track!==key(st.player.track) || !body.isConnected) return;
      carLines=(Array.isArray(result)?result:[]).filter(l=>Number.isFinite(Number(l.time))&&String(l.text||'').trim()).sort((a,b)=>a.time-b.time);
      body.innerHTML=carLines.length ? carLines.map(l=>'<p class="car-lyric-line">'+esc(l.text)+(l.translation&&l.translation!==l.text?'<small>'+esc(l.translation)+'</small>':'')+'</p>').join('') : empty('这首歌暂未提供歌词');
    } catch(e) {
      if(id===carLyricRequest&&body.isConnected)body.innerHTML=empty('歌词暂未载入')+textBtn('carRetryLyrics','','重新载入','pill');
    }
  }
  let index=carLines.length-1;
  while(index>=0 && Number(carLines[index].time)>Number(st.player.elapsed||0))index--;
  if(index===carActiveLine)return;
  body.querySelector('.active')?.classList.remove('active');
  const line=body.children[index];
  if(line){
    line.classList.add('active');
    if(Date.now()>carLyricFollowAfter)body.scrollTo({top:Math.max(0,line.offsetTop-body.offsetTop-body.clientHeight*.42),behavior:matchMedia('(prefers-reduced-motion:reduce)').matches?'instant':'smooth'});
  }
  carActiveLine=index;
}
Object.assign(actions,{
  carNav:carNavigate,
  carLyrics:carOpenLyrics,
  carRetryLyrics:()=>{carLyricTrack='';return updateCarLyrics();},
  carMode:()=>{const modes=['sequence','shuffle','repeatOne'];return playCmd('mode',{mode:modes[(modes.indexOf(st.player.mode)+1)%modes.length]});},
});
