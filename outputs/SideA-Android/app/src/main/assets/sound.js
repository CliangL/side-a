'use strict';
function soundPreset() {
  const id=st.player.sound?.preset || st.settings.soundPreset || 'original';
  return id==='commute'?'vocal':id==='night'?'soft':id;
}
function soundName() {
  return (st.settings.soundPresets || []).find(p => p.id === soundPreset())?.name || '原声';
}
let soundSaving = false;
function soundSheet() {
  const selected = soundPreset(), state = st.player.sound || {};
  const presets = Array.isArray(st.settings.soundPresets) ? st.settings.soundPresets : [];
  sheet('音效', '<div class="sound-options">' + presets.map(p =>
    '<button class="sound-option ' + (p.id === selected ? 'selected' : '') + '" ' + attr('soundPick',p.id) +
    ' aria-pressed="' + (p.id===selected) + '" '+(soundSaving?'disabled':'')+'><span>'+esc(p.name)+'</span>'+
    '<span class="sound-check">'+(p.id===selected?ic('check'):'')+'</span></button>').join('')+'</div>'+
    (state.status==='unavailable'?'<p class="sound-status" role="status">'+esc(state.message || '当前输出暂不支持，已使用原声')+'</p>':'')+
    (!presets.length?empty('音效选项暂未载入'):''),'sound');
}
actions.sound=soundSheet;
actions.soundPick=async preset=>{
  if(soundSaving || !(st.settings.soundPresets || []).some(p=>p.id===preset))return;
  soundSaving=true;soundSheet();
  try{
    const next=await req('sound',{preset});
    st.settings.soundPreset=next.sound?.preset || preset;
    applyPlayer(next);
    if(current().name==='settings')render();
    if(st.sheet==='sound')closeSheet();
  }finally{
    soundSaving=false;
    if(st.sheet==='sound')soundSheet();
  }
};
