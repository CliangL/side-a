const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

// Run the actual row renderer with the listeners normally supplied by WebView.
const document = { addEventListener() {}, getElementById() { return this; } };
const ui = vm.createContext({ window: {}, document, IntersectionObserver: class {} });
vm.runInContext(fs.readFileSync(path.join(__dirname, '../app/src/main/assets/core.js'), 'utf8'), ui);

const saved = Object.freeze({ source: 'central', trackID: 'qq.fixture', centralCatalog: true,
  artist: '周杰伦', sourceLabel: '统一曲库' });
assert.match(ui.row(saved, 'search'), /周杰伦 · QQ 音乐/);
assert.equal(ui.trackSourceLabel({ ...saved, sourceLabel: '' }), 'QQ 音乐');
assert.equal(ui.trackSourceLabel({ ...saved, sourceLabel: '我的曲库' }), '我的曲库');
assert.equal(ui.trackSourceLabel({ ...saved, providerID: 'qq' }), 'QQ 音乐');
assert.equal(ui.trackSourceLabel({ ...saved, trackID: 'wy.fixture' }), '网易云');
assert.equal(ui.trackSourceLabel({ ...saved, trackID: 'jx.fixture' }), 'JOOX');
assert.equal(ui.trackSourceLabel({ ...saved, trackID: 'kw.fixture' }), '酷我音乐');
assert.equal(ui.trackSourceLabel({ ...saved, trackID: 'wy.fixture', providerID: 'wy', sourceLabel: '网易云音乐（GD）' }), '网易云');
assert.equal(ui.trackSourceLabel({ ...saved, centralCatalog: false }), '统一曲库');
