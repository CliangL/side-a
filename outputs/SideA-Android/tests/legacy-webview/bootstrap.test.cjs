'use strict';
// Startup bridge and compatibility behavior, without endpoints or device data.
// Run: node outputs/SideA-Android/tests/legacy-webview/bootstrap.test.cjs
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const script = fs.readFileSync(path.join(__dirname, '../../app/src/main/assets/bootstrap.js'), 'utf8');

function setup({nativeFinally = false, bridge = true} = {}) {
  const handlers = {}, calls = [];
  const context = {
    document: {addEventListener() {}},
    addEventListener: (kind, callback) => { handlers[kind] = callback; }
  };
  if (bridge) context.SideA = {
    uiReady: () => calls.push('ready'),
    uiFailed: kind => calls.push(kind)
  };
  context.window = context;
  vm.createContext(context);
  vm.runInContext('window.Promise = Promise; window.Element = function Element() {};', context);
  const originalFinally = vm.runInContext('Promise.prototype.finally', context);
  if (!nativeFinally) vm.runInContext('delete Promise.prototype.finally;', context);
  vm.runInContext(script, context);
  return {context, handlers, calls, originalFinally};
}

(async () => {
  let run = setup();
  run.context.sideaBoot.ready();
  run.context.sideaBoot.ready();
  run.context.sideaBoot.failed('private error details');
  assert.deepEqual(run.calls, ['ready'], 'Successful startup reports once and ignores later failures');

  run = setup();
  run.handlers.error({target: {tagName: 'IMG'}});
  assert.deepEqual(run.calls, [], 'An artwork failure must not fail startup');
  run.handlers.error({target: {tagName: 'SCRIPT'}});
  run.context.sideaBoot.ready();
  assert.deepEqual(run.calls, ['script'], 'A failed script must not later signal ready');

  run = setup();
  run.context.sideaBoot.failed('https://private.invalid/?token=secret');
  assert.deepEqual(run.calls, ['startup'], 'Only a fixed classification may cross the bridge');

  run = setup();
  run.handlers.unhandledrejection({reason: 'private detail'});
  assert.deepEqual(run.calls, ['runtime']);

  run = setup({bridge: false});
  assert.doesNotThrow(() => run.context.sideaBoot.ready(), 'Browser fixtures need no native bridge');
  run = setup({bridge: false});
  assert.doesNotThrow(() => run.context.sideaBoot.failed('startup'));

  run = setup({nativeFinally: true});
  assert.equal(vm.runInContext('Promise.prototype.finally', run.context), run.originalFinally,
    'Keep the native implementation when available');

  run = setup();
  assert.equal(await vm.runInContext(
    'Promise.resolve(7).finally(function () { return Promise.resolve(9); })', run.context), 7);
  assert.equal(await vm.runInContext(
    'Promise.reject("first").finally(function () { return 9; }).catch(function (reason) { return reason; })', run.context), 'first');
  assert.equal(await vm.runInContext(
    'Promise.resolve(7).finally(function () { throw new Error("next"); }).catch(function (reason) { return reason.message; })', run.context), 'next');
  assert.equal(await vm.runInContext('Promise.resolve(7).finally(null)', run.context), 7);

  const node = vm.runInContext('new Element()', run.context);
  node.scrollLeft = 10;
  node.scrollTo({top: 80});
  assert.equal(node.scrollLeft, 10, 'Vertical lyric scrolling must preserve horizontal position');
  assert.equal(node.scrollTop, 80);
  node.scrollTo(22, 33);
  assert.equal(node.scrollLeft, 22);
  assert.equal(node.scrollTop, 33);

  console.log('Legacy bootstrap: startup reporting, privacy, Promise.finally and scrolling passed');
})().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
