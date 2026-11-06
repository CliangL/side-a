'use strict';
const el = (id) => document.getElementById(id);
const esc = (x) =>
  String(x == null ? '' : x).replace(
    /[&<>"']/g,
    (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c],
  );
const attr = (action, arg = '') => 'data-act="' + esc(action) + '" data-arg="' + esc(arg) + '"';
const icons = {
  search: '<circle cx="10.5" cy="10.5" r="7"/><path d="m16 16 5 5"/>',
  home: '<path d="m3 10 9-7 9 7v10h-6v-6H9v6H3Z"/>',
  lib: '<path d="M4 5v15m5-15v15m5-15 5 14"/>',
  play: '<path d="m7 4 13 8-13 8Z"/>',
  pause: '<path d="M6 4h3.5v16H6zm8 0h3.5v16H14z"/>',
  prev: '<path d="m20 5-11 7 11 7Zm-15 0h2v14H5z"/>',
  next: '<path d="m4 5 11 7-11 7Zm13 0h2v14h-2z"/>',
  heart: '<path d="M12 20C8 17 2.8 13 2.8 8.9A5 5 0 0 1 12 6.4a5 5 0 0 1 9.2 2.5c0 4-5.2 8-9.2 11.1Z"/>',
  queue: '<path d="M3 5h18M3 11h18m-9 6h9M3 15l4 2-4 2z"/>',
  lyrics: '<path d="M4 4h16v13H9l-5 4zm4 5h8m-8 3h5"/>',
  down: '<path d="m4 9 8 8 8-8"/>',
  back: '<path d="m15 4-8 8 8 8"/>',
  right: '<path d="m9 4 8 8-8 8"/>',
  more: '<circle cx="4" cy="12" r="1"/><circle cx="12" cy="12" r="1"/><circle cx="20" cy="12" r="1"/>',
  shuffle:
    '<path d="M2 6h3c5 0 8 12 13 12h3m-3-3 3 3-3 3M2 18h3c2 0 4-2 5-4m4-5c2-3 3-3 7-3m-3-3 3 3-3 3"/>',
  repeat: '<path d="M3 10c0-3 2-5 6-5h11l-3-3M20 14c0 3-2 5-6 5H4l3 3"/>',
  plus: '<path d="M12 4v16M4 12h16"/>',
  equal: '<path d="M3 10v4m5-8v12m5-16v20m5-16v12m4-8v4"/>',
  gear: '<path d="M3 6h18M3 12h18M3 18h18"/><circle cx="8" cy="6" r="2"/><circle cx="16" cy="12" r="2"/><circle cx="10" cy="18" r="2"/>',
  clock: '<circle cx="12" cy="12" r="9"/><path d="M12 6v6l4 2"/>',
  check: '<path d="m4 12 5 5L20 6"/>',
  up: '<path d="m5 15 7-7 7 7"/>',
  close: '<path d="m5 5 14 14M19 5 5 19"/>',
  optical: '<circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="3"/>',
  wave: '<path d="M3 12h2l2-5 3 11 3-15 3 16 2-7h3"/>',
};
function ic(k, solid = false) {
  return (
    '<svg aria-hidden="true" viewBox="0 0 24 24" class="ic ' +
    (solid || ['play', 'pause', 'prev', 'next'].includes(k) ? 'filled' : '') +
    '">' +
    (icons[k] || '') +
    '</svg>'
  );
}
function bt(action, arg, label, content, cl = 'icbtn') {
  return (
    '<button class="' +
    cl +
    '" ' +
    attr(action, arg) +
    ' aria-label="' +
    esc(label) +
    '">' +
    content +
    '</button>'
  );
}
function textBtn(a, arg, label, cl = 'subtle') {
  return bt(a, arg, label, esc(label), cl);
}
const awaiters = new Map();
let serial = 0;
function req(action, payload = {}) {
  return new Promise((resolve, reject) => {
    const id = ++serial;
    const timer = setTimeout(() => {
      awaiters.delete(id);
      reject(Error('请求超时，请重试'));
    }, 60000);
    awaiters.set(id, { resolve, reject, timer });
    try {
      window.SideA.request(id, action, JSON.stringify(payload));
    } catch (e) {
      clearTimeout(timer);
      awaiters.delete(id);
      reject(e);
    }
  });
}
window.sideAReply = (id, ok, value) => {
  const p = awaiters.get(Number(id));
  if (!p) return;
  clearTimeout(p.timer);
  awaiters.delete(Number(id));
  if (ok) p.resolve(value);
  else p.reject(Error(String((value && value.message) || value || '暂时无法完成请求')));
};
let toastTimer;
function notify(msg) {
  el('notice').textContent = String(msg);
  el('notice').style.display = 'block';
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => {
    el('notice').style.display = 'none';
  }, 2550);
}
const st = {
  library: { favorites: [], recent: [], playlists: [] },
  player: { queue: [] },
  charts: { hot: [], newReleases: [] },
  recommended: [],
  settings: {},
  starter: [],
  search: [],
  routes: [{ name: 'home' }],
  tab: 0,
  homeRecent: false,
  batch: 0,
  carousel: 0,
  playerOpen: false,
  sheet: null,
  uiMode: 'phone',
  selection: new Set(),
};
const tracks = new Map(),
  lists = new Map(),
  actions = Object.create(null);
const key = (t) => String((t && t.id) || ((t && t.source) || 'netease') + ':' + ((t && t.trackID) || ''));
const known = (t) => {
  if (t && t.trackID != null) tracks.set(key(t), t);
  return t;
};
const current = () => st.routes[st.routes.length - 1];
const favorite = (t) => st.library.favorites.some((v) => key(v) === key(t));
const time = (s) => {
  s = Math.max(0, Math.floor(Number(s) || 0));
  return Math.floor(s / 60) + ':' + String(s % 60).padStart(2, '0');
};
function nameOf(t) {
  return (t && t.title) || '未知曲目';
}
const starterArt = new Map(),
  artCache = new Map(),
  artPending = new Map(),
  artFailed = new Set();
function art(t, cl = 'thumb') {
  if (!t) return '<span class="art ' + cl + '"></span>';
  known(t);
  let src = artCache.get(key(t)) || starterArt.get(key(t));
  return (
    '<span class="art ' +
    cl +
    '"><img alt="" data-art="' +
    esc(key(t)) +
    '" ' +
    (src ? 'src="' + esc(src) + '"' : '') +
    '></span>'
  );
}
const artObserver = new IntersectionObserver(
  (entries) => {
    for (const e of entries) {
      if (e.isIntersecting) {
        artObserver.unobserve(e.target);
        loadArt(e.target);
      }
    }
  },
  { rootMargin: '60px' },
);
function scanArt(root = document) {
  for (const img of root.querySelectorAll('img[data-art]:not([src])')) artObserver.observe(img);
}
function loadArt(img) {
  const id = img.dataset.art,
    t = tracks.get(id);
  if (!t || artFailed.has(id)) return;
  let url = artCache.get(id) || starterArt.get(id);
  if (url) {
    img.src = url;
    return;
  }
  if (!artPending.has(id)) {
    artPending.set(
      id,
      req('cover', { track: t })
        .then((uri) => {
          if (typeof uri !== 'string' || !/^data:image\/(?:jpeg|png|gif|webp|jpg);base64,/i.test(uri)) {
            artFailed.add(id);
            return '';
          }
          if (artCache.size >= 32) artCache.delete(artCache.keys().next().value);
          artCache.set(id, uri);
          return uri;
        })
        .catch(() => {
          artFailed.add(id);
          return '';
        })
        .finally(() => artPending.delete(id)),
    );
  }
  artPending.get(id).then((uri) => {
    if (uri && img.isConnected && img.dataset.art === id) img.src = uri;
  });
}
function sleeve(t) {
  return '<div class="sleeve"><i class="vinyl"></i>' + art(t, 'cover') + '</div>';
}
function backdrop(t) {
  return '<div class="backdrop">' + art(t, 'bgart') + '</div>';
}
const sourceNames = Object.freeze({ all: '全部曲库', central: '统一曲库', qq: 'QQ 音乐', wy: '网易云', kw: '酷我音乐', jx: 'JOOX', netease: '网易云音乐', joox: 'JOOX', bilibili: '哔哩哔哩', tencent: 'QQ 音乐' });
function trackSourceLabel(t) {
  const provider = t.trackID && t.trackID.split('.')[0];
  if (t.centralCatalog && t.source === 'central' && ['qq','wy','kw','jx'].includes(provider) &&
      (!t.sourceLabel || t.sourceLabel === '统一曲库' || /[（(]GD[）)]\s*$/.test(t.sourceLabel))) return sourceNames[provider];
  return t.sourceLabel || sourceNames[t.source] || t.source || '';
}
const failedPlaybacks = new Map();
function recordingNote(t) {
  const facts = [t.rankBadge];
  if (failedPlaybacks.has(key(t))) facts.push('本次未能播放');
  else if (t.originAccessNote) facts.push(t.originAccessNote);
  else if (t.canonicalRecovered) facts.push('官方目录补充 · 播放待验证');
  const note = facts.filter(Boolean).join(' · ');
  return note ? '<span class="recordnote">' + esc(note) + '</span>' : '';
}
function row(t, list, opts = {}) {
  known(t);
  return (
    '<div class="row ' +
    (key(t) === key(st.player.track) ? 'now' : '') +
    '" data-row="' +
    esc(key(t)) +
    '"><button class="trackpick" ' +
    attr(opts.pick || 'playRow', key(t)) +
    ' data-list="' +
    esc(list) +
    '">' +
    art(t) +
    '<span class="txt"><strong>' +
    esc(nameOf(t)) +
    '</strong><small>' +
    esc(t.artist) +
    (list === 'search' && t.album ? ' · ' + esc(t.album) : '') +
    (list === 'search' || t.apiEndpoint || t.source !== 'netease' ? ' · ' + esc(trackSourceLabel(t)) : '') +
    (opts.release && t.releaseLabel ? ' · ' + esc(t.releaseLabel) : '') +
    '</small>' +
    (list === 'search' ? recordingNote(t) : '') +
    '</span></button>' +
    (opts.select
      ? bt('pick', key(t), '选择歌曲', ic(st.selection.has(key(t)) ? 'check' : 'plus'))
      : bt(
          'favorite',
          key(t),
          favorite(t) ? '取消收藏' : '收藏',
          ic('heart', favorite(t)),
          'icbtn fav ' + (favorite(t) ? 'on' : ''),
        ) + (opts.menu === false ? '' : bt('trackMenu', key(t), '更多歌曲操作', ic('more')))) +
    '</div>'
  );
}
function rows(items, id, opts = {}) {
  lists.set(id, items);
  return items.map((t) => row(t, id, opts)).join('');
}
function empty(msg) {
  return '<div class="empty">' + esc(msg) + '</div>';
}
function sheetRow(action, arg, label, icon, cls = '') {
  return bt(action, arg, label, (icon ? ic(icon) : '') + esc(label), 'sheetrow ' + cls);
}
function sheet(title, body, kind = 'options') {
  st.sheet = kind;
  el('shade').dataset.kind = kind;
  el('sheet').dataset.kind = kind;
  el('shell').setAttribute('inert', '');
  el('player').setAttribute('inert', '');
  el('shade').hidden = false;
  el('sheet').innerHTML =
    '<div class="handle"></div><div class="modalhead"><h2>' +
    esc(title) +
    '</h2>' +
    bt('closeSheet', '', '关闭', ic('close')) +
    '</div>' +
    body;
  scanArt(el('sheet'));
}
function closeSheet() {
  st.sheet = null;
  el('shade').hidden = true;
  el('sheet').textContent = '';
  el('player').removeAttribute('inert');
  if (!st.playerOpen) el('shell').removeAttribute('inert');
}
function go(route) {
  current().scroll = el('main').scrollTop;
  st.routes.push(route);
  render();
  el('main').scrollTop = 0;
}
function goBack() {
  if (st.sheet) {
    closeSheet();
    return true;
  }
  if (st.playerOpen) {
    hidePlayer();
    return true;
  }
  if (st.routes.length > 1) {
    st.routes.pop();
    render();
    el('main').scrollTop = current().scroll || 0;
    return true;
  }
  if (st.tab) {
    setTab(0);
    return true;
  }
  if (st.uiMode === 'car' && current().name !== 'home') {
    carNavigate('home');
    return true;
  }
  return false;
}
window.sideABack = goBack;
function setTab(i) {
  st.tab = i;
  st.routes = [{ name: i ? 'library' : 'home' }];
  render();
  el('main').scrollTop = 0;
}
function libIsNew(l) {
  return l && (!st.library.revision || !l.revision || Number(l.revision) >= Number(st.library.revision));
}
async function mutate(op, data = {}) {
  const l = await req('libraryAction', Object.assign({ op }, data));
  if (libIsNew(l)) st.library = l;
  render();
  if (st.playerOpen) updatePlayer(true);
  scheduleRecommendations();
  return l;
}
async function playCmd(op, payload = {}) {
  const info = await req('playAction', Object.assign({ op }, payload));
  if (info && Array.isArray(info.queue)) applyPlayer(info);
  return info;
}
let recTimer,
  recToken = 0;
function scheduleRecommendations() {
  clearTimeout(recTimer);
  recTimer = setTimeout(refreshRecommendation, 180);
}
window.sideARecommendations = scheduleRecommendations;
async function refreshRecommendation(fresh = false) {
  const token = ++recToken;
  try {
    const items = await req('recommend', { fresh: fresh === true });
    if (token !== recToken || !Array.isArray(items)) return;
    st.recommended = items;
    if (current().name === 'home' || (current().name === 'mix' && current().index === 0)) render();
  } catch (e) {
    if (!st.recommended.length) st.recommended = st.starter;
  }
}
async function refreshCharts(force = false) {
  try {
    st.charts = await req('discover', { force });
    if (['home', 'mix'].includes(current().name)) render();
    scheduleRecommendations();
  } catch (e) {
    st.charts.notice = e.message;
    if (['home', 'mix'].includes(current().name)) render();
  }
}
function render(remount = false) {
  const before = el('main').scrollTop,
    route = current();
  if (!remount && route.name === 'search' && el('query')) {
    renderResults();
    renderDock();
    return;
  }
  artObserver.disconnect();
  el('main').innerHTML = pageHTML(route);
  renderDock();
  scanArt();
  el('main').scrollTop = before;
  mountPage(route);
}
function renderDock() {
  if (st.uiMode === 'car') {
    renderCarNav();
    renderCarNow();
    return;
  }
  let p = st.player,
    t = p.track,
    mini = el('mini'),
    tabs = el('tabs');
  const sig = t ? [key(t), p.playing, p.loading, p.error, favorite(t)].join('|') : '';
  if (mini.dataset.sig !== sig) {
    mini.dataset.sig = sig;
    mini.innerHTML = t
      ? '<div class="mini"><button class="trackpick" ' +
        attr('openPlayer') +
        '>' +
        art(t) +
        '<span class="txt"><strong>' +
        esc(t.title) +
        '</strong><small>' +
        esc(p.error ? '播放失败 · 查看' : p.loading ? '正在载入…' : t.artist) +
        '</small></span></button>' +
        bt(
          'favorite',
          key(t),
          '收藏',
          ic('heart', favorite(t)),
          'icbtn fav ' + (favorite(t) ? 'on' : ''),
        ) +
        bt('toggle', '', p.playing ? '暂停' : '播放', ic(p.playing ? 'pause' : 'play')) +
        bt('queue', '', '待播列表', ic('queue')) +
        '</div>'
      : '';
    scanArt(mini);
  }
  if (tabs.dataset.tab !== String(st.tab)) {
    tabs.dataset.tab = st.tab;
    tabs.innerHTML = [
      ['home', '首页'],
      ['lib', '我的'],
    ]
      .map(([i, n], j) =>
        bt('tab', j, n, ic(i, j === 0 && st.tab === j) + esc(n), st.tab === j ? 'sel' : ''),
      )
      .join('');
  }
}
let openingTrack = null,
  openingExpires = 0,
  embeddedKey = '';
function refreshEmbedded(next) {
  const id = next.embeddedCoverId;
  if (!id) {
    embeddedKey = '';
    return;
  }
  if (id === embeddedKey || !next.track) return;
  embeddedKey = id;
  req('cover', { track: next.track })
    .then((uri) => {
      if (
        embeddedKey !== id ||
        typeof uri !== 'string' ||
        !/^data:image\/(?:jpeg|png|gif|webp|jpg);base64,/i.test(uri)
      )
        return;
      artCache.set(id, uri);
      document.querySelectorAll('img[data-art]').forEach((im) => {
        if (im.dataset.art === id) im.src = uri;
      });
    })
    .catch(() => {
      if (embeddedKey === id) embeddedKey = '';
    });
}
function applyPlayer(next) {
  if (!next || !Array.isArray(next.queue)) return;
  const previous = st.player;
  st.player = next;
  known(next.track);
  if(next.track && (next.error || next.playing)) {
    const id = key(next.track);
    const before = failedPlaybacks.has(id);
    if(next.error) failedPlaybacks.set(id, String(next.error));
    else failedPlaybacks.delete(id);
    if(before !== failedPlaybacks.has(id) && current().name === 'search')renderResults();
  }
  if ((next.sound && next.sound.status) === 'unavailable' && ((previous.sound && previous.sound.status) !== 'unavailable' || (previous.sound && previous.sound.preset) !== next.sound.preset))
    notify(next.sound.message || '当前输出暂不支持此音效，已使用原声');
  refreshEmbedded(next);
  renderDock();
  if (openingTrack && openingExpires > Date.now() && next.track && openingTrack === key(next.track)) {
    openingTrack = null;
    openPlayer();
  }
  if (st.playerOpen) updatePlayer(false, previous);
  if (st.uiMode === 'car') updateCarLyrics();
  if (st.sheet === 'sound' && JSON.stringify(previous.sound) !== JSON.stringify(next.sound)) soundSheet();
  if (
    st.sheet === 'queue' &&
    (previous.index !== next.index || JSON.stringify(previous.queue) !== JSON.stringify(next.queue))
  )
    showQueue();
}
window.sideAPlayer = applyPlayer;
window.sideALibrary = (l) => {
  if (!libIsNew(l)) return;
  st.library = l;
  render();
  if (st.playerOpen) updatePlayer(true);
  scheduleRecommendations();
};
document.addEventListener('click', async (e) => {
  const b = e.target.closest('[data-act]');
  if (!b || b.disabled) return;
  try {
    const action = actions[b.dataset.act];
    if (action) await action(b.dataset.arg, b, e);
  } catch (err) {
    notify(err.message || '操作失败');
  }
});
el('shade').addEventListener('click', (e) => {
  if (e.target === el('shade')) closeSheet();
});
document.addEventListener('contextmenu', (e) => {
  const r = e.target.closest('[data-row]');
  if (r && !st.sheet) {
    e.preventDefault();
    actions.trackMenu(r.dataset.row);
  }
});
