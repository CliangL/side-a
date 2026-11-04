'use strict';
let playerTrack = '',
  pageIndex = 0,
  lyricToken = 0,
  lines = [],
  lastLine = -1,
  lyricStatus = '',
  followResume = 0,
  scrubbing = false,
  autoFollow = false,
  followTimer = 0,
  qualityMenu = '',
  oldRevision = '';
function sysbars() {
  return req('sysBars', {
    dark: st.playerOpen || matchMedia('(prefers-color-scheme:dark)').matches,
  }).catch(() => {});
}
function openPlayer() {
  if (!st.player.track) {
    notify('先选择一首歌');
    return;
  }
  st.playerOpen = true;
  pageIndex = 0;
  el('player').hidden = false;
  el('shell').setAttribute('inert', '');
  sysbars();
  mountPlayer();
}
function hidePlayer() {
  st.playerOpen = false;
  el('player').hidden = true;
  el('shell').removeAttribute('inert');
  el('player').textContent = '';
  lyricToken++;
  clearTimeout(followTimer);
  sysbars();
}
function mountPlayer() {
  const t = st.player.track;
  if (!t) return;
  playerTrack = key(t);
  lines = [];
  lastLine = -1;
  lyricStatus = '正在读取歌词…';
  followResume = 0;
  el('player').innerHTML =
    backdrop(t) +
    '<div class="playtop">' +
    bt('hidePlayer', '', '收起播放器', ic('down'), 'round') +
    bt(
      'turnPage',
      '',
      '切换封面与歌词',
      '<b id="pagetitle"></b><span id="pagedots" class="dots"><i></i><i></i></span>',
      'pindicator',
    ) +
    bt('playerMenu', '', '更多播放选项', ic('more'), 'round') +
    '</div>' +
    '<div class="pager" id="pager"><section class="page coverpage" aria-label="唱片页"><div class="stage">' +
    sleeve(t) +
    '</div><div class="songhead"><p class="caps">' +
    esc((t.album || 'SIDE A').toUpperCase()) +
    '</p><div class="spread"><h1>' +
    esc(t.title) +
    '</h1>' +
    bt('currentFavorite', '', '收藏歌曲', ic('heart', favorite(t)), 'round playerfav') +
    '</div><div class="artistline"><span>' +
    esc(t.artist) + (t.apiEndpoint || t.source !== 'netease' ? ' · ' + esc(trackSourceLabel(t)) : '') +
    '</span><span class="chip" id="playerQuality"></span></div><button id="previewline" class="previewline" ' +
    attr('lyricPreview') +
    '></button><p id="audioNote" class="hint"></p></div></section>' +
    '<section class="page" aria-label="歌词页"><div class="lyhead"><h1>' +
    esc(t.title) +
    '</h1><p>' +
    esc(t.artist) +
    '</p></div><div class="lyricscroll" id="lyricBody"></div></section></div>' +
    '<div class="transport"><div class="playtools">' +
    bt('turnPage', '', '歌词', '<span id="pageTool"></span>', '') +
    bt('quality', '', '音质', ic('wave') + '音质', '') +
    bt('queue', '', '待播列表', ic('queue') + '待播', '') +
    '</div><input type="range" class="progress" id="progress" min="0" max="1" value="0" step="0.1" aria-label="播放进度"><div class="times"><span id="elapsed">0:00</span><span id="remain">−0:00</span></div><div class="controls">' +
    bt('shuffleMode', '', '随机播放', ic('shuffle'), 'mode') +
    bt('prev', '', '上一首', ic('prev'), '') +
    bt('toggle', '', '播放/暂停', ic('play'), 'big') +
    bt('next', '', '下一首', ic('next'), '') +
    bt('repeatMode', '', '单曲循环', ic('repeat'), 'mode') +
    '</div></div>';
  scanArt(el('player'));
  const pager = el('pager');
  pager.scrollLeft = pageIndex * pager.clientWidth;
  pager.onscroll = () => {
    const index = Math.round(pager.scrollLeft / Math.max(1, pager.clientWidth));
    if (index !== pageIndex) {
      pageIndex = index;
      showPageState();
      if (pageIndex) focusLine(true);
    }
  };
  showPageState();
  const seek = el('progress');
  seek.oninput = () => {
    scrubbing = true;
    setProgress(Number(seek.value), Number(st.player.duration) || 0);
  };
  seek.onchange = () => {
    const seconds = Number(seek.value);
    scrubbing = false;
    playCmd('seek', { seconds }).catch((e) => notify(e.message));
  };
  seek.onpointercancel = () => {
    scrubbing = false;
  };
  const body = el('lyricBody');
  body.ontouchmove = () => {
    followResume = Date.now() + 4300;
    clearTimeout(followTimer);
    followTimer = setTimeout(() => focusLine(true), 4400);
  };
  renderLines();
  loadLyrics(t);
  updatePlayer(true);
}
function showPageState() {
  el('pagetitle').textContent = pageIndex ? '同步歌词' : '正在播放';
  [...el('pagedots').children].forEach((a, i) => (a.className = i === pageIndex ? 'sel' : ''));
  el('pageTool').innerHTML = ic(pageIndex ? 'optical' : 'lyrics') + (pageIndex ? ' 唱片' : ' 歌词');
}
function turnPage(target = 1 - pageIndex) {
  const p = el('pager');
  if (!p) return;
  p.scrollTo({
    left: p.clientWidth * target,
    behavior: matchMedia('(prefers-reduced-motion:reduce)').matches ? 'instant' : 'smooth',
  });
}
async function loadLyrics(t) {
  const token = ++lyricToken;
  lyricStatus = '正在读取歌词…';
  lines = [];
  lastLine = -1;
  renderLines();
  try {
    const r = await req('lyrics', { track: t });
    if (token !== lyricToken || playerTrack !== key(t) || !st.playerOpen) return;
    lines = (Array.isArray(r) ? r : [])
      .filter((l) => Number.isFinite(Number(l.time)) && String(l.text || '').trim())
      .sort((a, b) => a.time - b.time);
    lyricStatus = lines.length ? '' : '暂未找到歌词';
  } catch (e) {
    if (token !== lyricToken) return;
    lyricStatus = '歌词加载失败';
  }
  renderLines();
  focusLine(true);
}
function renderLines() {
  const b = el('lyricBody');
  if (!b) return;
  if (!lines.length) {
    b.innerHTML =
      '<div class="lyempty">' +
      esc(lyricStatus) +
      (lyricStatus.includes('正在') ? '' : textBtn('retryLyrics', '', '重新载入', 'pill')) +
      '</div>';
    return;
  }
  b.innerHTML = lines
    .map((l, i) =>
      bt(
        'seekLine',
        i,
        l.text,
        esc(l.text) +
          (l.translation && l.translation !== l.text ? '<small>' + esc(l.translation) + '</small>' : ''),
        'lyline',
      ),
    )
    .join('');
}
function focusLine(force = false) {
  if (!lines.length || !el('lyricBody')) return;
  const e = Number(st.player.elapsed) || 0;
  let i = lines.length - 1;
  while (i >= 0 && Number(lines[i].time) > e) i--;
  if (i === lastLine && !force) return;
  const b = el('lyricBody'),
    old = b.querySelector('.active');
  if (old) old.classList.remove('active');
  const line = i >= 0 ? b.children[i] : null;
  if (line) line.classList.add('active');
  if (line && pageIndex === 1 && followResume < Date.now()) {
    const desired =
      line.getBoundingClientRect().top -
      b.getBoundingClientRect().top +
      b.scrollTop -
      b.clientHeight / 2 +
      line.clientHeight / 2;
    b.scrollTo({
      top: Math.max(0, desired),
      behavior: force || matchMedia('(prefers-reduced-motion:reduce)').matches ? 'instant' : 'smooth',
    });
  }
  lastLine = i;
  el('previewline').textContent = lines[Math.max(0, i)].text;
}
function setProgress(s, d) {
  let p = el('progress');
  if (!p) return;
  const duration = Math.max(0, d || 0),
    elapsed = Math.min(Math.max(0, s || 0), duration);
  p.max = duration || 1;
  p.value = elapsed;
  p.disabled = !duration;
  p.style.setProperty('--pct', duration ? (100 * elapsed) / duration + '%' : '0%');
  el('elapsed').textContent = time(elapsed);
  el('remain').textContent = '−' + time(duration - elapsed);
}
function updatePlayer(force = false, previous = null) {
  if (!st.player.track) {
    hidePlayer();
    return;
  }
  if (key(st.player.track) !== playerTrack) {
    mountPlayer();
    return;
  }
  const p = st.player;
  if (!el('progress')) return;
  if (!scrubbing) setProgress(p.elapsed, p.duration);
  if (force || !previous || p.playing !== previous.playing) {
    const b = el('player').querySelector('.big');
    b.innerHTML = ic(p.playing ? 'pause' : 'play');
    b.setAttribute('aria-label', p.playing ? '暂停' : '播放');
  }
  const q = el('playerQuality');
  q.textContent = p.quality || '等待音源';
  const n = el('audioNote');
  n.innerHTML = p.error
    ? '<span class="audioerror">' + esc(p.error) + '</span>' +
      textBtn('retryPlay', '', '重试播放', 'audioaction')
    : p.loading
      ? '正在载入音频…'
      : '';
  const heart = el('player').querySelector('.playerfav');
  heart.innerHTML = ic('heart', favorite(p.track));
  heart.style.color = favorite(p.track) ? '#ffbfb1' : 'inherit';
  el('player')
    .querySelector('[data-act="shuffleMode"]')
    .classList.toggle('sel', p.mode === 'shuffle');
  el('player')
    .querySelector('[data-act="repeatMode"]')
    .classList.toggle('sel', p.mode === 'repeatOne');
  focusLine();
}
function showQueue() {
  const p = st.player,
    queue = p.queue || [];
  sheet(
    '待播列表 · ' + queue.length,
    queue
      .map(
        (t, i) =>
          '<div class="queueitem">' +
          bt(
            'queuePick',
            i,
            t.title,
            art(t) +
              '<span class="txt"><strong>' +
              esc(t.title) +
              '</strong><small>' +
              esc(t.artist) +
              '</small></span>' +
              (i === p.index ? ic('equal') : ''),
            'trackpick',
          ) +
          bt('queueUp', i, '上移', ic('up')) +
          bt('queueDown', i, '下移', ic('down')) +
          bt('queueRemove', i, '移除', ic('close')) +
          '</div>',
      )
      .join('') || empty('还没有待播歌曲'),
    'queue',
  );
}
function qualitySheet() {
  const s = st.settings;
  sheet(
    '播放音质',
    '<p class="hint">当前 · ' +
      esc(st.player.quality || '等待音源') +
      '</p>' +
      [
        ['preferLossless', '优先请求无损'],
        ['losslessOnly', '仅播放无损'],
        ['cellularDataSaver', '移动网络优先省流'],
      ]
        .map(([k, n]) => sheetRow('qualityToggle', k, n, s[k] ? 'check' : 'plus'))
        .join(''),
    'quality',
  );
}
Object.assign(actions, {
  openPlayer,
  hidePlayer,
  turnPage: () => turnPage(),
  lyricPreview: () => turnPage(1),
  retryLyrics: () => loadLyrics(st.player.track),
  retryPlay: () => playCmd('play', { tracks: st.player.queue, index: st.player.index || 0 }),
  seekLine: (i) => {
    if (!lines[Number(i)]) return;
    followResume = 0;
    return playCmd('seek', { seconds: Number(lines[Number(i)].time) });
  },
  currentFavorite: () => mutate('favorite', { track: st.player.track }),
  toggle: () => (st.player.error ? actions.retryPlay() : playCmd('toggle')),
  prev: () => playCmd('previous'),
  next: () => playCmd('next'),
  shuffleMode: () => playCmd('mode', { mode: st.player.mode === 'shuffle' ? 'sequence' : 'shuffle' }),
  repeatMode: () => playCmd('mode', { mode: st.player.mode === 'repeatOne' ? 'sequence' : 'repeatOne' }),
  playerMenu: () => {
    const t = st.player.track;
    sheet(
      t.title,
        sheetRow('addToList', key(t), '加入歌单', 'plus') +
        sheetRow('similar', key(t), '沿着这首听', 'wave') +
        sheetRow('avoidSong', key(t), '少推荐这首', 'close') +
        sheetRow('avoidStyle', key(t), '少推荐这种风格', 'gear') +
        sheetRow('sleep', '', '睡眠定时', 'clock'),
      'player-menu',
    );
  },
  quality: qualitySheet,
  qualityToggle: async (k) => {
    st.settings = await req('settings', { op: 'set', [k]: !st.settings[k] });
    qualitySheet();
  },
  sleep: () =>
    sheet(
      '睡眠定时',
      (st.player.sleepEnd
        ? '<p class="hint">将在 ' +
          esc(
            new Date(st.player.sleepEnd).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }),
          ) +
          ' 暂停</p>'
        : '') +
        [15, 30, 45, 60].map((n) => sheetRow('setSleep', n, n + ' 分钟', 'clock')).join('') +
        sheetRow('setSleep', '0', '取消定时', 'close'),
      'sleep',
    ),
  setSleep: async (n) => {
    await playCmd('sleep', { minutes: Number(n) });
    closeSheet();
  },
  queue: showQueue,
  queuePick: async (i) => {
    const p = st.player;
    await playCmd('play', { tracks: p.queue, index: Number(i) });
    closeSheet();
  },
  queueRemove: async (i) => {
    await playCmd('remove', { index: Number(i) });
    showQueue();
  },
  queueUp: async (n) => {
    let i = Number(n);
    if (i > 0) {
      await playCmd('move', { from: i, to: i - 1 });
      showQueue();
    }
  },
  queueDown: async (n) => {
    let i = Number(n);
    if (i < st.player.queue.length - 1) {
      await playCmd('move', { from: i, to: i + 1 });
      showQueue();
    }
  },
});
