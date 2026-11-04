'use strict';
const mixes = ['为你选的', '最近热歌', '近七天新歌'];
const recs = () => st.recommended;
function itemsFor(r) {
  switch (r.name) {
    case 'mix':
      return r.index === 0 ? recs() : r.index === 1 ? st.charts.hot || [] : st.charts.newReleases || [];
    case 'favorites':
      return st.library.favorites;
    case 'recent':
      return st.library.recent;
    case 'playlist':
      return (st.library.playlists.find((p) => String(p.id) === r.id) || {}).tracks || [];
    case 'related':
      return r.items || [];
    default:
      return [];
  }
}
function descFor(r) {
  if (r.name === 'mix')
    return [
      st.library.reason || '按你的收听偏好选曲',
      st.charts.hotSource || '热歌榜',
      st.charts.newSource || '新歌榜',
    ][r.index];
  if (r.name === 'related') return '从《' + r.seed.title + '》出发';
  return itemsFor(r).length + ' 首歌曲';
}
function bar(title = '', right = '') {
  return (
    '<div class="bar">' +
    bt('back', '', '返回', ic('back') + '返回', 'back') +
    '<h2>' +
    esc(title) +
    '</h2>' +
    (right || '<span></span>') +
    '</div>'
  );
}
function card(i) {
  const r = { name: 'mix', index: i },
    items = itemsFor(r),
    t = items[0];
  return (
    '<article class="card">' +
    backdrop(t) +
    bt('mix', i, '查看' + mixes[i], '', 'facehit') +
    '<div class="edition"><div class="side">Side ' +
    ['A', 'B', 'C'][i] +
    '</div><small>' +
    ['私人电台', '热歌唱片', '新发行'][i] +
    '</small></div>' +
    sleeve(t) +
    '<div class="strip"><div><h2>' +
    mixes[i] +
    '</h2><p>' +
    esc(i === 0 ? '按你的收听偏好选曲' : descFor(r)) +
    '</p></div><button ' +
    attr('playMix', i) +
    ' aria-label="播放' +
    mixes[i] +
    '" ' +
    (!items.length ? 'disabled' : '') +
    '>' +
    ic('play') +
    '</button></div></article>'
  );
}
function homePage() {
  const personal = recs(),
    sample = personal.length
      ? Array.from(
          { length: Math.min(personal.length, 3) },
          (_, i) => personal[(i + st.batch * 3) % personal.length],
        )
      : [];
  const search = bt(
    'search',
    '',
    '搜索歌曲、歌手、专辑',
    ic('search') + '搜索歌曲、歌手、专辑',
    'searchbar',
  );
  return (
    search +
    '<div class="segments">' +
    textBtn('segment', '0', '推荐', st.homeRecent ? '' : 'sel') +
    textBtn('segment', '1', '最近常听', st.homeRecent ? 'sel' : '') +
    '</div>' +
    (st.homeRecent
      ? '<div class="pad">' +
        (st.library.recent.length
          ? rows(st.library.recent, 'recent')
          : empty('听过的歌曲会出现在这里。')) +
        '</div>'
      : '<div class="reel" id="reel">' +
        [0, 1, 2].map(card).join('') +
        '</div><div class="dots" id="carddots">' +
        [0, 1, 2].map((i) => '<i class="' + (st.carousel === i ? 'sel' : '') + '"></i>').join('') +
        '</div><div class="section"><header><h2>顺着你的口味</h2>' +
        textBtn('batch', '', '换一批') +
        '</header><p class="hint">' +
        esc(st.library.reason || '从几张唱片开始，听见新的声音') +
        '</p>' +
        rows(sample, 'personal-home', { menu: false }) +
        '</div><div class="section"><header><h2>最近常听</h2>' +
        textBtn('recent', '', '全部') +
        '</header>' +
        (st.library.recent.length
          ? rows(st.library.recent.slice(0, 1), 'one-recent', { menu: false })
          : '<p class="hint">听过的歌曲会在这里留下唱片印记。</p>') +
        '</div>')
  );
}
function libraryPage() {
  return (
    '<div class="pad stack"><div class="spread"><div><div class="side">Side B' +
    '</div><h1 class="songti">我的唱片室</h1></div>' +
    bt('settings', '', '设置', ic('gear'), 'round') +
    '</div>' +
    bt(
      'favorites',
      '',
      '我的收藏',
      '<span class="badge">' +
        ic('heart', true) +
        '</span><span class="txt"><strong>我的收藏</strong><small>' +
        st.library.favorites.length +
        ' 首歌曲</small></span>',
      'banner glass',
    ) +
    '<div class="spread"><h2>我的歌单</h2>' +
    bt('newList', '', '新建歌单', ic('plus'), 'round') +
    '</div>' +
    (st.library.playlists
      .map((p) =>
        bt(
          'playlist',
          p.id,
          p.name,
          art(p.cover || p.tracks[0]) +
            '<span class="txt"><strong>' +
            esc(p.name) +
            '</strong><small>' +
            p.tracks.length +
            ' 首歌曲</small></span>' +
            ic('right'),
          'playlistentry',
        ),
      )
      .join('') || '<p class="hint">把适合某个时刻的歌收在一起。</p>') +
    '<div class="rule"></div>' +
    bt('recent', '', '最近播放', ic('clock') + '最近播放', 'toolrow') +
    '</div>'
  );
}
function collectionPage(r) {
  const list = st.library.playlists.find((p) => String(p.id) === r.id),
    items = itemsFor(r),
    title = {
      playlist: (list && list.name) || '歌单',
      favorites: '我的收藏',
      recent: '最近播放',
      related: '沿着这首听',
      mix: mixes[r.index],
    }[r.name];
  const a = (list && list.cover) || items[0] || r.seed,
    b = items.find((t) => key(a) !== key(t)) || a;
  return (
    bar('', r.name === 'playlist' ? bt('listMenu', r.id, '歌单管理', ic('more'), 'round') : '') +
    '<div class="collectionhero">' +
    backdrop(a) +
    '<div class="edition side">Side A</div><div class="albumstack">' +
    art(b, '') +
    art(a, '') +
    '</div><div class="strip"><div><h2>' +
    esc(title) +
    '</h2><p>' +
    esc(descFor(r)) +
    '</p></div><i class="side">33⅓</i></div></div><div class="pad"><div class="pair">' +
    bt('playDetail', '', '播放全部', ic('play') + '播放全部', 'primary') +
    bt('shuffleDetail', '', '随机播放', ic('shuffle') + '随机播放', '') +
    '</div><div class="sectionbar"><span>歌曲</span>' +
    bt('filter', '', '歌单内搜索', ic('search')) +
    (list
      ? textBtn('addMany', list.id, '添加歌曲') + textBtn('editList', list.id, '整理')
      : r.name === 'mix' || r.name === 'related'
        ? textBtn('saveMix', '', '存为歌单')
        : '') +
    '</div><div id="filterbox"></div><div id="collectionRows">' +
    collectionRows(r, '') +
    '</div></div>'
  );
}
function collectionRows(r, q) {
  let items = itemsFor(r);
  lists.set('detail', items);
  if (!items.length) {
    return (
      (r.busy
        ? empty('正在查找曲目…')
        : empty(
            r.name === 'mix'
              ? st.charts.notice || '暂无曲目，请稍后刷新'
              : r.name === 'related'
                ? '暂未找到相似曲目'
                : '这里还没有歌曲',
          )) +
      (r.name === 'mix' || r.name === 'related'
        ? textBtn('reloadDetail', '', '重新加载', 'pill')
        : r.name === 'playlist'
          ? textBtn('addMany', r.id, '添加歌曲', 'pill')
          : '')
    );
  }
  const matches = items.filter((t) =>
    (t.title + ' ' + t.artist).toLowerCase().includes(q.toLowerCase()),
  );
  return (
    matches.map((t) => row(t, 'detail', { release: r.name === 'mix' && r.index === 2 })).join('') ||
    empty('没有匹配的歌曲')
  );
}
function searchPage() {
  let r = current();
  return (
    bar(r.target ? '添加歌曲' : '搜索') +
    '<label class="searchbar">' +
    ic('search') +
    '<input id="query" type="search" maxlength="140" autocomplete="off" placeholder="歌曲、歌手、专辑" value="' +
    esc(r.q || '') +
    '"></label><div class="section"><div id="searchScopes" role="group" aria-label="搜索曲库">' + searchScopes() +
    '</div><header><h2 id="searchTitle"></h2>' +
    (r.target ? textBtn('commitAdd', '', '添加选中', 'pill') : '') +
    '</header><div id="searchResults"></div></div>'
  );
}
function renderResults() {
  const r = current();
  if (r.name !== 'search' || !el('searchResults')) return;
  const scope = st.settings.searchSource || 'all';
  const sourceOnly = scope !== 'all';
  const inScope = t => !sourceOnly || (st.settings.centralBase && t.centralCatalog && t.trackID && t.trackID.startsWith(scope + '.') &&
    t.apiEndpoint === st.settings.centralBase.replace(/\/$/,'') + '/v1/music');
  let items = (r.items || []).filter(inScope);
  let heading = '搜索结果';
  if (!r.q) {
    const suggestions = [['你的收藏',st.library.favorites],['最近播放',st.library.recent],['从这些歌开始',st.starter]];
    items = [];
    heading = sourceOnly ? '搜索 ' + searchSourceNames[scope] : '从这些歌开始';
    for (const [title, tracks] of suggestions) {
      items = tracks.filter(inScope);
      if (items.length) { heading = title; break; }
    }
  }
  el('searchTitle').textContent = heading;
  const target = el('searchResults');
  if (!items.length) target.innerHTML = !r.q ? '' : empty(r.busy ? '搜索中…' : (r.issues && r.issues.length) ? '暂未取得曲目' : '没有找到歌曲');
  else target.innerHTML = rows(items,'search',r.target ? { pick:'selectAdd',select:true } : {});
  if (r.q) {
    const footer = document.createElement('div');
    footer.className = 'search-pager';
    const settled = !r.moreBusy && !r.checkingEvidence;
    if ((r.issues && r.issues.length) && settled) footer.insertAdjacentHTML('beforeend',textBtn('retrySources','','重试','pill'));
    if (r.moreBusy && items.length) footer.appendChild(document.createTextNode('其他结果加载中…'));
    if (r.hasMore && settled) footer.insertAdjacentHTML('beforeend',textBtn('moreSearch','','加载更多','pill'));
    target.appendChild(footer);
  }
  if (r.target) {
    const btn = document.querySelector('[data-act="commitAdd"]');
    if (btn) btn.textContent = '添加 (' + st.selection.size + ')';
  }
  scanArt(el('searchResults'));
}
let queryTimer;
async function runSearch(r, mode = 'fresh') {
  if (mode !== 'fresh' && (r.moreBusy || r.checkingEvidence)) return;
  const q = r.q || '';
  const requestID = r.requestID = (r.requestID || 0) + 1;
  const currentRequest = () => requestID === r.requestID && q === r.q;
  if(mode === 'fresh'){
    r.items = []; r.rawHits = new Map(); r.pages = new Map(); r.rankTicket = 0;
    r.checkingEvidence = false;
    if(q && !st.settings.centralBase){
      const updated = await req('prepareSearch').catch(() => null);
      if(!currentRequest())return;
      if(updated)window.sideACatalogUpdated(updated);
    }
    const chosen = st.settings.searchSource || 'all';
    const sources = chosen === 'all' ? st.settings.allSources || ['central'] : [chosen];
    for(const selection of sources)r.pages.set(selection,{page:1,done:false,issue:''});
  }
  const pending = [...r.pages].filter(([,p]) => !p.done && (mode === 'retry' ? !!p.issue : mode === 'more' ? !p.issue : true));
  if(!q){r.busy=false;r.moreBusy=false;r.issues=[];r.hasMore=false;renderResults();return;}
  let remaining = pending.length;
  let earlyEvidence;
  let checkedSize = 0;
  r.checkingEvidence = true;
  const status = () => {
    if(!currentRequest())return;
    r.busy = !r.items.length && remaining > 0;
    r.moreBusy = remaining > 0;
    r.hasMore = [...r.pages.values()].some(p=>!p.done&&!p.issue);
    r.issues = [...r.pages.values()].filter(p=>p.issue).map(p=>p.issue);
    if(current()===r)renderResults();
  };
  const rank = async () => {
    const ticket=++r.rankTicket;
    let ranked;
    try { ranked=await req('searchRank',{query:q,tracks:[...r.rawHits.values()]}); }
    catch (_) { ranked=[...r.rawHits.values()]; }
    if(!currentRequest() || ticket!==r.rankTicket)return;
    r.items=ranked;
    status();
  };
  const checkEvidence = async () => {
    const hits = [...r.rawHits.values()];
    try {
      const enriched = await req('searchEvidence', {query:q, tracks:hits});
      if(!currentRequest())return;
      checkedSize = hits.length;
      for(const t of enriched)r.rawHits.set(key(t),t);
      // The sorted result is usable directly when no additional provider has returned.
      if(r.rawHits.size === hits.length){
        r.rankTicket++; r.items = enriched; status();
      } else await rank();
    } catch (_) { /* Keep the results already displayed by the local ranking. */ }
  };
  status();
  await Promise.all(pending.map(async ([selection,p])=>{
    try {
      const result=await req('searchPage',{query:q,searchSource:selection,page:p.page});
      if(!currentRequest())return;
      const info=result.bySource && result.bySource[0];
      if(!(info && info.ok))throw Error((info && info.error) || '曲库暂未响应');
      p.issue='';
      let added=0;
      for(const t of result.items || [])if(!r.rawHits.has(key(t))){r.rawHits.set(key(t),t);added++;}
      if(added)p.page++; else p.done=true;
      if(added){
        await rank();
        if (currentRequest() && !earlyEvidence && remaining > 1) {
          // A slow or unavailable provider should not delay recognition of the first matches.
          earlyEvidence = checkEvidence();
        }
      }
    }catch(e){
      if(!currentRequest())return;
      const name=sourceNames[selection] || '曲库';
      p.issue=name+'：'+e.message;
    }finally{remaining--;status();}
  }));
  if(!currentRequest())return;
  if(earlyEvidence)await earlyEvidence;
  if(!currentRequest())return;
  if(r.rawHits.size > checkedSize)await checkEvidence();
  if(currentRequest()){r.checkingEvidence = false;status();}
}
const searchSourceNames = { all:'全部', qq:'QQ 音乐', wy:'网易云', kw:'酷我音乐', jx:'JOOX' };
function searchScopes() {
  return Object.keys(searchSourceNames).map(code => '<button type="button" ' + attr('selectSource',code) +
    ' aria-pressed="' + (code === st.settings.searchSource) + '">' +
    searchSourceNames[code] + '</button>').join('');
}
window.sideACatalogUpdated = next => {
  st.settings = Object.assign({}, st.settings, next);
  if (el('searchScopes')) el('searchScopes').innerHTML = searchScopes();
};
async function setSearchScope(code) {
  if (st.settings.searchSource === code) return;
  const r = current();
  r.requestID = (r.requestID || 0) + 1;
  const next = await req('settings',{op:'set', searchSource:code});
  window.sideACatalogUpdated(next);
  if (r !== current() || r.name !== 'search') return;
  clearTimeout(queryTimer);
  r.items = []; r.issues = []; r.hasMore = false;
  renderResults();
  await runSearch(r);
}
async function refreshStorage() {
  const result = await req('settings', {op:'storage'});
  st.settings.cacheBytes = result.cacheBytes;
  if (current().name === 'settings') render();
}
function settingsPage() {
  const s = st.settings;
  const bytes = s.cacheBytes;
  const size = bytes == null ? '…' : (bytes / 1048576).toFixed(1) + ' MB';
  return bar('设置') + '<div class="section preferences"><h2>声音</h2>' +
    bt('sound','','场景音效','<span>场景音效</span><span class="muted">' + esc(soundName()) + ic('right') + '</span>', 'setting rule') + '<h2>缓存</h2>' +
    bt('clearCache','','清理缓存','<span>清理缓存</span><span class="muted">' + size + '</span>', 'setting rule') +
    '<h2>听歌偏好</h2><label class="setting rule">记录听歌偏好<input type="checkbox" data-setting="tracking" ' +
    (st.library.trackingEnabled ? 'checked' : '') + '></label>' +
    textBtn('resetPref','','重置听歌偏好','setting rule danger') + '</div>';
}
function pageHTML(r) {
  if (st.uiMode === 'car') {
    const page = carPageHTML(r);
    if (page != null) return page;
  }
  if (r.name === 'home') return homePage();
  if (r.name === 'library') return libraryPage();
  if (r.name === 'settings') return settingsPage();
  if (r.name === 'search') return searchPage();
  return collectionPage(r);
}
function mountPage(r) {
  if (st.uiMode === 'car') mountCarPage(r);
  if (r.name === 'home') {
    let reel = el('reel');
    if (reel) {
      if (st.carousel) reel.scrollLeft = reel.children[st.carousel].offsetLeft - 20;
      reel.onscroll = () => {
        const c = reel.children[0];
        st.carousel = Math.max(0, Math.min(2, Math.round(reel.scrollLeft / (c.offsetWidth + 12))));
        Array.from(el('carddots').children).forEach(
          (a, i) => (a.className = st.carousel === i ? 'sel' : ''),
        );
      };
    }
  }
  if (r.name === 'search') {
    renderResults();
    el('query').oninput = (e) => {
      r.q = e.target.value.trim();
      r.requestID = (r.requestID || 0) + 1;
      clearTimeout(queryTimer);
      r.busy = !!r.q;
      r.items = [];
      r.checkingEvidence = r.moreBusy = r.hasMore = false;
      r.issues = [];
      r.error = '';
      renderResults();
      queryTimer = setTimeout(() => runSearch(r), 420);
    };
    if (!r.q && !r.target && st.uiMode !== 'car') setTimeout(() => { const query = el('query'); if (query) query.focus(); }, 50);
  }
  if (r.name === 'settings') {
    document.querySelectorAll('[data-setting]').forEach(
      (control) =>
        (control.onchange = async () => {
          try {
            await mutate('tracking', { enabled: control.checked });
            render();
          } catch (e) {
            notify(e.message);
            render();
          }
        }),
    );
  }
}
async function fetchRelated(r) {
  r.busy = true;
  render();
  try {
    r.items = await req('related', { track: r.seed });
  } finally {
    r.busy = false;
    if (current() === r) render();
  }
}
function namedSheet(title, initial, submit) {
  sheet(
    title,
    '<label class="field"><input id="sheetName" type="text" maxlength="80" placeholder="歌单名称" value="' +
      esc(initial) +
      '"></label><div class="actions">' +
      textBtn('nameSubmit', '', '保存', 'primary pill') +
      '</div>',
    'name',
  );
  el('sheetName').focus();
  actions.nameSubmit = async () => {
    const n = el('sheetName').value.trim();
    if (!n) {
      notify('请输入歌单名称');
      return;
    }
    await submit(n);
    closeSheet();
    render();
  };
}
function confirmSheet(title, message, run) {
  sheet(
    title,
    '<p class="hint">' +
      esc(message) +
      '</p><div class="actions">' +
      textBtn('closeSheet', '', '取消', 'pill') +
      textBtn('yes', '', '确认', 'pill danger') +
      '</div>',
    'confirm',
  );
  actions.yes = async () => {
    await run();
    closeSheet();
    render();
  };
}
let chosenTrack = null;
function menuTrack(t) {
  if (!t) return;
  chosenTrack = t;
  sheet(
    t.title,
    (failedPlaybacks.has(key(t)) ? '<p class="hint">本次未能播放 · ' + esc(failedPlaybacks.get(key(t))) + '</p>' : '') +
    sheetRow('addToList', key(t), '加入歌单', 'plus') +
      sheetRow('enqueueNext', key(t), '下一首播放', 'next') +
      sheetRow('enqueue', key(t), '加入待播', 'queue') +
      sheetRow('similar', key(t), '沿着这首听', 'wave') +
      sheetRow('avoidSong', key(t), '少推荐这首', 'close') +
      sheetRow('avoidStyle', key(t), '少推荐这种风格', 'gear'),
    'track',
  );
}
function addToList(t) {
  sheet(
    '加入歌单',
    sheetRow('newForTrack', key(t), '创建歌单并加入', 'plus') +
      st.library.playlists
        .map((p) =>
          sheetRow('into', p.id, p.name, p.tracks.some((x) => key(x) === key(t)) ? 'check' : 'lib'),
        )
        .join(''),
    'add',
  );
}
async function playItems(items, index = 0, show = false) {
  if (!items.length) {
    notify('没有可播放的歌曲');
    return;
  }
  if (show && st.uiMode !== 'car') {
    openingTrack = key(items[index]);
    openingExpires = Date.now() + 7000;
  }
  try {
    await playCmd('play', { tracks: items, index });
  } catch (e) {
    openingTrack = null;
    throw e;
  }
}
function editList(id) {
  const list = st.library.playlists.find((p) => String(p.id) === id);
  if (!list) return;
  st.selection = new Set();
  function draw() {
    sheet(
      '整理歌单',
      list.tracks
        .map(
          (t, i) =>
            '<div class="queueitem">' +
            bt(
              'bulkPick',
              key(t),
              t.title,
              (st.selection.has(key(t)) ? ic('check') : ic('plus')) +
                '<span class="txt"><strong>' +
                esc(t.title) +
                '</strong></span>',
              'trackpick',
            ) +
            bt('listUp', i, '上移', ic('up')) +
            bt('listDown', i, '下移', ic('down')) +
            '</div>',
        )
        .join('') + textBtn('removePicked', '', '移除所选 (' + st.selection.size + ')', 'pill danger'),
      'list-edit',
    );
  }
  actions.bulkPick = (k) => {
    st.selection.has(k) ? st.selection.delete(k) : st.selection.add(k);
    draw();
  };
  for (const [a, d] of [
    ['listUp', -1],
    ['listDown', 1],
  ])
    actions[a] = async (n) => {
      let i = Number(n),
        j = i + d;
      if (j < 0 || j >= list.tracks.length) return;
      await mutate('reorder', { id, from: i, to: j });
      editList(id);
    };
  actions.removePicked = () => {
    if (st.selection.size)
      confirmSheet('移除歌曲', '只从这张歌单移除选中曲目。', () =>
        mutate('remove', { id, ids: [...st.selection] }),
      );
  };
  draw();
}
Object.assign(actions, {
  selectSource: setSearchScope,
  tab: (i) => setTab(Number(i)),
  back: goBack,
  closeSheet,
  search: () => go({ name: 'search' }),
  segment: (i) => {
    st.homeRecent = i === '1';
    render();
  },
  batch: () => {
    st.batch++;
    render();
  },
  mix: (i) => go({ name: 'mix', index: Number(i) }),
  playMix: async (i) => {
    await playItems(itemsFor({ name: 'mix', index: Number(i) }), 0, true);
  },
  favorites: () => go({ name: 'favorites' }),
  recent: () => go({ name: 'recent' }),
  playlist: (id) => go({ name: 'playlist', id }),
  settings: async () => {
    go({ name: 'settings' });
    await refreshStorage();
  },
  playRow: async (k, b) => {
    let list = lists.get(b.dataset.list) || [tracks.get(k)];
    await playItems(
      list,
      Math.max(
        0,
        list.findIndex((t) => key(t) === k),
      ),
      current().name === 'search',
    );
  },
  favorite: (k) => mutate('favorite', { track: tracks.get(k) }),
  trackMenu: (k) => menuTrack(tracks.get(k)),
  newList: () => namedSheet('新建歌单', '', (name) => mutate('create', { name, tracks: [] })),
  playDetail: () => playItems(itemsFor(current()), 0, false),
  shuffleDetail: () => {
    let xs = [...itemsFor(current())];
    for (let i = xs.length - 1; i > 0; i--) {
      let j = Math.floor(Math.random() * (i + 1));
      [xs[i], xs[j]] = [xs[j], xs[i]];
    }
    return playItems(xs);
  },
  saveMix: () => {
    let r = current();
    namedSheet('保存为歌单', r.name === 'mix' ? mixes[r.index] : '沿着' + r.seed.title, (name) =>
      mutate('create', { name, tracks: itemsFor(r) }),
    );
  },
  reloadDetail: () => (current().name === 'related' ? fetchRelated(current()) : refreshCharts(true)),
  retrySearch: () => runSearch(current()),
  moreSearch: () => runSearch(current(), 'more'),
  retrySources: () => runSearch(current(), 'retry'),
  filter: () => {
    const box = el('filterbox');
    if (box.firstChild) {
      box.textContent = '';
      el('collectionRows').innerHTML = collectionRows(current(), '');
      scanArt(el('collectionRows'));
      return;
    }
    box.innerHTML =
      '<div class="field"><input type="search" id="inList" placeholder="在歌单中搜索"></div>';
    el('inList').focus();
    el('inList').oninput = (e) => {
      el('collectionRows').innerHTML = collectionRows(current(), e.target.value);
      scanArt(el('collectionRows'));
    };
  },
  addMany: (id) => {
    st.selection = new Set();
    go({ name: 'search', target: id });
  },
  selectAdd: (k) => {
    if (st.selection.has(k)) st.selection.delete(k);
    else st.selection.add(k);
    renderResults();
  },
  pick: (k) => actions.selectAdd(k),
  commitAdd: async () => {
    if (!st.selection.size) return;
    let id = current().target;
    await mutate('add', { id, tracks: [...st.selection].map((k) => tracks.get(k)) });
    goBack();
  },
  listMenu: (id) => {
    sheet(
      '歌单管理',
      sheetRow('renameList', id, '重命名', 'lib') +
        sheetRow('setArt', id, '选择歌单封面', 'optical') +
        sheetRow('editList', id, '排序与移除', 'gear') +
        sheetRow('deleteList', id, '删除歌单', 'close', 'danger'),
    );
  },
  editList,
  renameList: (id) => {
    const l = st.library.playlists.find((x) => String(x.id) === id);
    namedSheet('重命名歌单', l.name, (name) => mutate('rename', { id, name }));
  },
  deleteList: (id) =>
    confirmSheet('删除歌单', '歌单中的收藏歌曲仍然保留。', async () => {
      await mutate('delete', { id });
      st.routes.pop();
    }),
  setArt: (id) => {
    const l = st.library.playlists.find((x) => String(x.id) === id);
    sheet(
      '歌单封面',
      sheetRow('autoArt', id, '使用自动封面', 'optical') +
        l.tracks
          .map((t) =>
            bt('pickArt', key(t), t.title, art(t) + '<span>' + esc(t.title) + '</span>', 'sheetrow'),
          )
          .join(''),
    );
    actions.pickArt = async (k) => {
      await mutate('setCover', { id, track: tracks.get(k) });
      closeSheet();
    };
  },
  autoArt: async (id) => {
    await mutate('setCover', { id, track: null });
    closeSheet();
  },
  enqueue: async (k) => {
    await playCmd('enqueue', { track: tracks.get(k), next: false });
    closeSheet();
  },
  enqueueNext: async (k) => {
    await playCmd('enqueue', { track: tracks.get(k), next: true });
    closeSheet();
  },
  similar: (k) => {
    closeSheet();
    if (st.playerOpen) hidePlayer();
    const seed = tracks.get(k),
      r = { name: 'related', seed, busy: true, items: [] };
    go(r);
    return fetchRelated(r);
  },
  avoidSong: async (k) => {
    await mutate('dislike', { track: tracks.get(k) });
    closeSheet();
  },
  avoidStyle: async (k) => {
    const t = tracks.get(k);
    sheet('少推荐这种风格', empty('读取风格标签…'), 'styles');
    const tags = await req('genres', { track: t });
    if (st.sheet !== 'styles') return;
    sheet(
      '少推荐这种风格',
      tags.length
        ? tags.map((v) => sheetRow('muteStyle', v, v, 'gear')).join('')
        : empty('这首歌暂时没有可核实的风格标签') +
            sheetRow('avoidSong', k, '只减少推荐这首歌', 'close'),
      'styles',
    );
    actions.muteStyle = async (tag) => {
      await mutate('reduceStyle', { track: t, tags: [tag] });
      closeSheet();
    };
  },
  addToList: (k) => {
    chosenTrack = tracks.get(k);
    addToList(chosenTrack);
  },
  newForTrack: (k) =>
    namedSheet('创建并加入', '', (name) => mutate('create', { name, tracks: [tracks.get(k)] })),
  into: async (id) => {
    await mutate('add', { id, tracks: [chosenTrack] });
    closeSheet();
  },
  clearCache: async () => {
    const result = await req('settings', {op:'clear'});
    st.settings.cacheBytes = result.cacheBytes;
    artCache.clear(); artFailed.clear();
    if (current().name === 'settings') render();
  },
  resetPref: () =>
    confirmSheet('重置听歌偏好', '清除听歌记录积累的偏好？', () =>
      mutate('reset'),
    ),
});
