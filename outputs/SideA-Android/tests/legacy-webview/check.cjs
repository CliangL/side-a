"use strict";
// Node 22+ drives real old Chromium through its native CDP; no Playwright protocol assumptions.
// All expressions sent into the browser are ES2017 or earlier, including the fixture bridge.
const assert = require("node:assert/strict");
const fs = require("node:fs/promises");
const path = require("node:path");
const { connect, sleep } = require("./cdp.cjs");
const out = path.resolve(
  process.env.SIDEA_QA_OUTPUT || "work/maintenance/release-061",
);
const origin = process.env.SIDEA_QA_ORIGIN || "http://127.0.0.1:18771";
const port = Number(process.env.SIDEA_QA_CDP_PORT || 9227);
async function wait(c, expression) {
  for (let i = 0; i < 50; i++) {
    if (await c.eval(expression)) return;
    await sleep(100);
  }
  throw Error("Timed out: " + expression);
}
async function click(c, selector) {
  assert(
    await c.eval("!!document.querySelector(" + JSON.stringify(selector) + ")"),
    selector,
  );
  await c.eval(
    "document.querySelector(" + JSON.stringify(selector) + ").click()",
  );
  await sleep(100);
}
async function shot(c, name) {
  const v = await c.call("Page.captureScreenshot", { format: "png" });
  await fs.writeFile(
    path.join(out, name + ".png"),
    Buffer.from(v.data, "base64"),
  );
}
async function errors(c) {
  return c.events
    .filter((e) => e.method === "Runtime.exceptionThrown")
    .map((e) => e.params.exceptionDetails);
}
async function navigate(c, mode) {
  const r = await c.call("Page.navigate", { url: origin + "/" + mode + "/" });
  assert(!r.errorText, JSON.stringify(r));
  await wait(c, "document.readyState === 'complete'");
  await sleep(150);
}
async function layout(c) {
  return c.eval(
    `(function(){function rect(e){var r=e.getBoundingClientRect();return{left:r.left,right:r.right,top:r.top,bottom:r.bottom,width:r.width,height:r.height};}return{width:innerWidth,height:innerHeight,overflow:document.documentElement.scrollWidth-innerWidth,main:rect(document.getElementById('main')),dock:rect(document.getElementById('carNow')),nav:rect(document.getElementById('carNav')),buttons:Array.prototype.map.call(document.querySelectorAll('#carNow button'),function(b){return{action:b.getAttribute('data-act'),box:rect(b),icon:b.querySelector('svg')?rect(b.querySelector('svg')):null}})};})()`,
  );
}
function assertLayout(v) {
  assert(v.overflow <= 1, "Page overflow");
  assert(v.main.bottom <= v.dock.top + 1, "Dock overlaps content");
  assert(v.dock.bottom <= v.height + 1, "Dock offscreen");
  for (const b of v.buttons) {
    assert(b.box.width >= 43 && b.box.height >= 43, "Small button " + b.action);
    if (b.icon) {
      assert(
        Math.abs((b.icon.left + b.icon.right - b.box.left - b.box.right) / 2) <
          1,
        "Icon not centered " + b.action,
      );
    }
    assert(
      b.box.left >= -1 &&
        b.box.right <= v.width + 1 &&
        b.box.bottom <= v.height + 1,
      "Offscreen button " + b.action,
    );
  }
}
async function baseline() {
  const { c, version, close } = await connect(port);
  try {
    assert(
      Number(version.Browser.match(/\/(\d+)/)[1]) < 80,
      "Use actual pre-80 Chromium",
    );
    await navigate(c, "old");
    const state = await c.eval(
      "({url:location.href,text:document.body.innerText,buttons:document.querySelectorAll('#carNav button').length,ready:typeof window.sideAPlayer})",
    );
    const failure = await errors(c);
    assert.equal(state.text, "");
    assert.equal(state.buttons, 0);
    assert(
      failure.some(
        (e) =>
          e.url.endsWith("/core.js") &&
          e.exception.description.includes("SyntaxError"),
      ),
      "Baseline core.js must fail parsing",
    );
    await shot(c, "baseline-blank-chromium67");
    return { version, state, errors: failure, status: "expected-failure" };
  } finally {
    await close();
  }
}
async function car(w, h) {
  const { c, version, close } = await connect(port);
  try {
    await c.call("Emulation.setDeviceMetricsOverride", {
      width: w,
      height: h,
      deviceScaleFactor: 1,
      mobile: false,
    });
    await navigate(c, "new");
    await wait(c, "window.__qa && window.__qa.ready");
    let initial = await layout(c);
    assertLayout(initial);
    assert.equal(
      await c.eval("document.querySelectorAll('#carNav button').length"),
      6,
    );
    assert(
      await c.eval(
        "Array.prototype.every.call(document.querySelectorAll('.car-nav-items button'),function(b){var i=b.querySelector('svg').getBoundingClientRect(),r=b.getBoundingClientRect();return Math.abs((i.left+i.right-r.left-r.right)/2)<1})",
      ),
      "Navigation icons not centered",
    );
    await shot(c, "home-chromium67-" + w + "x" + h);
    await click(c, '#carNow [data-act="toggle"]');
    assert.equal(await c.eval("window.__qa.player.playing"), true);
    await click(c, '#carNow [data-act="next"]');
    assert.equal(await c.eval("window.__qa.player.index"), 1);
    await c.eval(
      "(function(){var e=document.getElementById('carProgress');e.value=65;e.dispatchEvent(new Event('input',{bubbles:true}));e.dispatchEvent(new Event('change',{bubbles:true}));})()",
    );
    await wait(c, "window.__qa.player.elapsed===65");
    await click(c, ".car-disc-button");
    await wait(
      c,
      "document.querySelectorAll('#carLyrics .car-lyric-line').length===12",
    );
    let lyrics = await layout(c);
    assertLayout(lyrics);
    assert.equal(lyrics.nav.width, initial.nav.width);
    assert.equal(
      await c.eval(
        "document.getElementById('carNav').getBoundingClientRect().height>0",
      ),
      true,
    );
    await click(c, '#carLyrics .car-lyric-line[data-arg="8"]');
    await wait(c, "window.__qa.player.elapsed===80");
    await shot(c, "lyrics-chromium67-" + w + "x" + h);
    await click(c, '#carNow [data-act="sound"]');
    assert.equal(
      await c.eval("document.querySelectorAll('#sheet .sound-option').length"),
      7,
    );
    assert(
      await c.eval(
        "document.getElementById('sheet').getBoundingClientRect().width<=340",
      ),
    );
    await shot(c, "sound-chromium67-" + w + "x" + h);
    await click(c, '[data-act="soundPick"][data-arg="hall"]');
    await wait(
      c,
      "window.__qa.player.sound.preset==='hall' && document.getElementById('shade').hidden",
    );
    await click(c, '[data-act="carNav"][data-arg="search"]');
    await c.eval(
      "(function(){var e=document.getElementById('query');e.value='测试';e.dispatchEvent(new Event('input',{bubbles:true}));})()",
    );
    await wait(
      c,
      "window.__qa.calls.some(function(v){return v.action==='searchPage'})",
    );
    await wait(c, "document.querySelectorAll('#searchResults .row').length>0");
    await click(c, '[data-act="selectSource"][data-arg="wy"]');
    await wait(
      c,
      "window.__qa.calls.some(function(v){return v.action==='searchPage' && v.payload.searchSource==='wy'})",
    );
    await wait(c, "document.querySelectorAll('#searchResults .row').length>0");
    await shot(c, "search-chromium67-" + w + "x" + h);
    assertLayout(await layout(c));
    assert.deepEqual(await errors(c), []);
    return {
      version: version.Browser,
      viewport: [w, h],
      initial,
      lyrics,
      calls: await c.eval("window.__qa.calls"),
      status: "passed",
    };
  } finally {
    await close();
  }
}
async function phone() {
  const { c, version, close } = await connect(port);
  try {
    await c.call("Emulation.setDeviceMetricsOverride", {
      width: 390,
      height: 844,
      deviceScaleFactor: 1,
      mobile: false,
    });
    await navigate(c, "phone");
    await wait(c, "window.__qa && window.__qa.ready");
    await click(c, '#mini [data-act="openPlayer"]');
    await wait(c, "!document.getElementById('player').hidden");
    const cover = await c.eval(
      "(function(){var e=document.querySelector('#player .sleeve .cover');var r=e.getBoundingClientRect();return {width:r.width,height:r.height};})()",
    );
    assert(
      cover.width > 100 &&
        cover.height > 100 &&
        Math.abs(cover.width - cover.height) < 1,
      JSON.stringify(cover),
    );
    await shot(c, "phone-chromium67-390x844");
    assert.deepEqual(await errors(c), []);
    return { version: version.Browser, phone: cover, status: "passed" };
  } finally {
    await close();
  }
}
(async () => {
  await fs.mkdir(out, { recursive: true });
  const results = { baseline: await baseline(), car: [], phone: null };
  for (const [w, h] of [
    [800, 480],
    [1024, 600],
  ])
    results.car.push(await car(w, h));
  results.phone = await phone();
  await fs.writeFile(
    path.join(out, "legacy-webview-results.json"),
    JSON.stringify(results, null, 2),
  );
  console.log(
    JSON.stringify(
      {
        baseline: results.baseline.status,
        car: results.car.map((r) => ({
          viewport: r.viewport,
          status: r.status,
        })),
        phone: results.phone,
      },
      null,
      2,
    ),
  );
})().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
