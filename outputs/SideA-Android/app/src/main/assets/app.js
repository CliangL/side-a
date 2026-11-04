'use strict';
window.sideAPreferences = (preferences) => {
  const oldScope = st.settings.searchSource;
  window.sideACatalogUpdated(preferences);
  const route = current();
  if (oldScope !== st.settings.searchSource && route && route.name === 'search') {
    route.requestID = (route.requestID || 0) + 1;
    route.items = []; route.issues = []; route.hasMore = false;
    renderResults(); runSearch(route);
  }
};
async function start() {
  el('main').innerHTML =
    '<div class="section"><i class="side">Side A</i></div>';
  try {
    const boot = await req('init');
    st.uiMode = boot.uiMode === 'car' ? 'car' : 'phone';
    setupCarLayout();
    st.library = boot.library;
    st.settings = boot.settings;
    st.starter = boot.starter || [];
    st.recommended = [...st.starter];
    for (const track of st.starter) {
      known(track);
      if (track.source === 'netease' && /^\d+$/.test(track.trackID))
        starterArt.set(key(track), 'StarterArt/cover-' + track.trackID + '.jpg');
    }
    st.player = boot.player || { queue: [] };
    known(st.player.track);
    render();
    window.sideaBoot.ready();
    sysbars();
    refreshCharts();
    scheduleRecommendations();
  } catch (e) {
    window.sideaBoot.failed('startup');
    el('main').innerHTML =
      '<div class="section"><i class="side">Side A</i>' +
      empty(e.message || '暂时无法打开') +
      textBtn('boot', '', '重新打开', 'pill') +
      '</div>';
  }
}
actions.boot = start;
document.addEventListener('visibilitychange', async () => {
  if (document.visibilityState === 'visible') {
    try {
      applyPlayer(await req('player'));
      window.sideALibrary(await req('library'));
    } catch (e) {
      notify(e.message);
    }
  }
});
const colorScheme = window.matchMedia('(prefers-color-scheme: dark)');
if (colorScheme.addEventListener) colorScheme.addEventListener('change', sysbars);
else if (colorScheme.addListener) colorScheme.addListener(sysbars);
window.addEventListener('resize', () => {
  if (st.playerOpen) {
    const v = el('pager');
    if (v) v.scrollTo({ left: v.clientWidth * pageIndex, behavior: 'instant' });
  }
});
start();
