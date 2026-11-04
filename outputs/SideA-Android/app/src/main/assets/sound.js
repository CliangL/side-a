'use strict';
function soundPreset() {
  return st.player.sound?.preset || st.settings.soundPreset || 'original';
}
function soundName() {
  return (st.settings.soundPresets || []).find(p => p.id === soundPreset())?.name || '原声';
}
let soundSaving = false;
function soundSheet() {
  const selected = soundPreset(), state = st.player.sound || {};
  const presets = Array.isArray(st.settings.soundPresets) ? st.settings.soundPresets : [];
  sheet('场景音效', '<p class="sound-intro">给此刻，合适的声音</p><div class="sound-grid">' +
    presets.map(p => '<button class="sound-preset ' + (p.id === selected ? 'selected' : '') + '" ' +
      attr('soundPick', p.id) + ' aria-pressed="' + (p.id === selected) + '" ' + (soundSaving ? 'disabled' : '') + '>' +
      '<span class="sound-icon">' + ic(p.id === 'original' ? 'optical' : 'equal') + '</span><span class="txt"><strong>' +
      esc(p.name) + '</strong><small>' + esc(p.detail || '') + '</small></span><span class="sound-check">' +
      (p.id === selected ? ic('check') : '') + '</span></button>').join('') + '</div>' +
    (state.status === 'unavailable' || state.status === 'pending' ? '<p class="sound-status" role="status">' + esc(state.message || '') + '</p>' : '') +
    (!presets.length ? empty('音效选项暂未载入') : ''), 'sound');
}
actions.sound = soundSheet;
actions.soundPick = async preset => {
  if (soundSaving || !(st.settings.soundPresets || []).some(p => p.id === preset)) return;
  soundSaving = true;
  soundSheet();
  try {
    const next = await req('sound', { preset });
    st.settings.soundPreset = next.sound?.preset || preset;
    applyPlayer(next);
    if (current().name === 'settings') render();
  } finally {
    soundSaving = false;
    if (st.sheet === 'sound') soundSheet();
  }
};
