'use strict';
// Browser-only UI regression using generated artwork and a synthetic native bridge.
// No production endpoint, device credential, or audio playback is used here.
// Install Playwright outside source: npm install --prefix work/car-redesign playwright@1.64.1
// Run from repo root with NODE_PATH="$PWD/work/car-redesign/node_modules" node <this test>.
// CHROME_PATH overrides Chrome; SIDEA_QA_OUTPUT overrides ignored result/screenshot output.
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const {launch,openFixture} = require('./fixture.cjs');
const out=path.resolve(process.env.SIDEA_QA_OUTPUT || 'work/car-redesign');
async function checkLayout(page){
  const result=await page.evaluate(()=>{
    const b=id=>{const r=document.getElementById(id).getBoundingClientRect();return {left:r.left,top:r.top,right:r.right,bottom:r.bottom,width:r.width,height:r.height};};
    return {main:b('main'),dock:b('carNow'),nav:b('carNav'),width:innerWidth,height:innerHeight,overflow:document.documentElement.scrollWidth-innerWidth,mainOverflow:document.getElementById('main').scrollWidth-document.getElementById('main').clientWidth,
      buttons:[...document.querySelectorAll('#carNow button')].filter(b=>b.getClientRects().length).map(b=>{const r=b.getBoundingClientRect();return {action:b.dataset.act,left:r.left,right:r.right,top:r.top,bottom:r.bottom,width:r.width,height:r.height};})};
  });
  assert(result.overflow<=1,'Page horizontal overflow');assert(result.mainOverflow<=1,'Main horizontal overflow');
  assert(result.main.bottom<=result.dock.top+1,'Main extends behind bottom dock');
  assert(result.dock.bottom<=result.height+1,'Dock extends outside viewport');
  assert(result.dock.width>=result.width*.80,'Dock does not span content area');

  for(const b of result.buttons){assert(b.left>=-1&&b.right<=result.width+1&&b.top>=0&&b.bottom<=result.height+1,'Button out of screen: '+b.action);assert(b.width>=43&&b.height>=43,'Small hit target: '+b.action);}
  return result;
}
async function carRun(browser,w,h){
  const {page,errors}=await openFixture(browser,{width:w,height:h});
  try{
    await page.waitForSelector('.car-disc img[src]');
    const initial=await checkLayout(page);
    assert.equal(await page.locator('#player').isVisible(),false,'Phone player must stay hidden');
    const currentCover=await page.locator('.car-disc img').getAttribute('src');
    const discState=()=>page.locator('.car-disc').evaluate(e=>getComputedStyle(e).animationPlayState);
    assert.equal(await discState(),'running','Playing CD should rotate');
    const nodeHandle=await page.locator('.car-disc').elementHandle();
    await page.evaluate(()=>window.__qa.push({elapsed:44}));
    assert(await nodeHandle.evaluate(n=>n===document.querySelector('.car-disc')),'Progress poll replaced CD element');
    await page.locator('#carNow [data-act="toggle"]').click();
    assert.equal(await discState(),'paused','Paused CD should stop');
    await page.locator('#carNow [data-act="toggle"]').click();
    assert.equal(await discState(),'running');
    await page.locator('#carNow [data-act="next"]').click();
    await page.waitForFunction(src=>document.querySelector('.car-disc img')?.src!==src,currentCover);
    assert.equal((await page.evaluate(()=>window.__qa.snapshot())).player.track.id,'qa:2');
    await page.locator('#carNow [data-act="currentFavorite"]').click();
    assert((await page.evaluate(()=>window.__qa.snapshot())).library.favorites.some(t=>t.id==='qa:2'),'Favorite not saved');
    await page.locator('#carProgress').evaluate(e=>{e.value='96';e.dispatchEvent(new Event('input',{bubbles:true}));e.dispatchEvent(new Event('change',{bubbles:true}));});
    await page.waitForFunction(()=>window.__qa.snapshot().player.elapsed===96);
    await page.locator('#carNow [data-act="carMode"]').click();
    assert.equal((await page.evaluate(()=>window.__qa.snapshot())).player.mode,'shuffle');
    await page.screenshot({path:path.join(out,`home-${w}x${h}.png`)});
    await page.locator('.car-disc-button').click();
    await page.waitForSelector('html.car-lyrics-open');
    await page.waitForSelector('#carLyrics .car-lyric-line');
    const lyrics=await checkLayout(page);
    assert.deepEqual(lyrics.main,initial.main,'Lyrics changed main content area');
    assert.deepEqual(lyrics.dock,initial.dock,'Lyrics moved playback controls');
    const lyricRequests=await page.evaluate(()=>window.__qa.calls.filter(c=>c.action==='lyrics').length);
    await page.evaluate(()=>{for(let i=0;i<5;i++)window.__qa.push({elapsed:96+i});});
    assert.equal(await page.evaluate(()=>window.__qa.calls.filter(c=>c.action==='lyrics').length),lyricRequests,'Playback polling refetched lyrics');
    await page.locator('#carLyrics .car-lyric-line').nth(10).click();
    await page.waitForFunction(()=>window.__qa.snapshot().player.elapsed===80);
    await page.waitForFunction(()=>document.querySelector('#carLyrics .active')?.textContent.includes('第 11 行'));
    await page.waitForTimeout(650);
    const activePosition=await page.locator('#carLyrics').evaluate(body=>{const line=body.querySelector('.active'),r=line.getBoundingClientRect(),b=body.getBoundingClientRect();return (r.top+r.height/2-b.top)/b.height;});
    assert(activePosition>=.35 && activePosition<=.65,'Active lyric not centered after seek: '+activePosition);
    assert.equal(await page.locator('#carNav').isVisible(),true,'Lyrics must retain navigation');
    assert.equal(await page.locator('#carNow [data-act="toggle"]').isVisible(),true,'Playback controls lost on lyrics');
    await page.screenshot({path:path.join(out,`lyrics-${w}x${h}.png`)});
    await page.locator('#carNow [data-act="next"]').click();
    await page.waitForFunction(()=>document.querySelector('#carLyrics')?.textContent.includes('沿着海岸的公路'));
    await page.locator('#carNow [data-act="toggle"]').click();
    assert.equal((await page.evaluate(()=>window.__qa.snapshot())).player.playing,false);
    await page.locator('#carNow [data-act="sound"]').click();
    await page.waitForSelector('#sheet .sound-preset');
    await page.locator('[data-act="soundPick"][data-arg="commute"]').click();
    await page.waitForSelector('[data-act="soundPick"][data-arg="commute"][aria-pressed="true"]');
    assert.equal((await page.evaluate(()=>window.__qa.snapshot())).settings.soundPreset,'commute');
    await page.locator('#sheet [data-act="closeSheet"]').click();
    await page.locator('#carNow [data-act="queue"]').click();
    await page.waitForSelector('#sheet .queueitem');
    await page.locator('#sheet [data-act="closeSheet"]').click();
    await page.locator('[data-act="carNav"][data-arg="search"]').click();
    await page.waitForSelector('#query');
    await page.locator('.car-disc-button').click();
    await page.waitForSelector('#carLyrics .active');
    await page.locator('[data-act="carNav"][data-arg="favorites"]').click();
    await page.waitForSelector('#collectionRows');
    await page.locator('.car-disc-button').click();
    await page.waitForSelector('#carLyrics .active');
    await page.locator('#main [data-act="back"]').click();
    assert.equal(await page.locator('html').evaluate(e=>e.classList.contains('car-lyrics-open')),false);
    await page.locator('[data-act="carNav"][data-arg="search"]').click();
    await page.locator('#query').fill('海边');
    await page.waitForFunction(()=>window.__qa.calls.some(c=>c.action==='searchPage'));
    await page.locator('[data-act="selectSource"][data-arg="wy"]').click();
    await page.waitForSelector('[data-act="selectSource"][data-arg="wy"][aria-pressed="true"]');
    await page.waitForFunction(()=>window.__qa.calls.some(c=>c.action==='searchPage'&&c.payload.searchSource==='wy'));
    assert.equal((await page.evaluate(()=>window.__qa.snapshot())).settings.searchSource,'wy');
    await checkLayout(page);
    await page.locator('[data-act="carNav"][data-arg="settings"]').click();
    await page.locator('[data-act="resetPref"]').scrollIntoViewIfNeeded();
    const reset=await page.locator('[data-act="resetPref"]').boundingBox(),dock=await page.locator('#carNow').boundingBox();
    assert(reset.y+reset.height<=dock.y+1,'Last setting hidden under dock');
    await page.evaluate(()=>window.__qa.select(5));
    await checkLayout(page);
    assert.deepEqual(errors,[],'Browser JS error');
    const events=await page.evaluate(()=>window.__qa.calls.filter(c=>['playAction','sound','libraryAction','settings','searchPage','lyrics'].includes(c.action)));
    await fs.writeFile(path.join(out,`events-${w}x${h}.json`),JSON.stringify(events,null,2));
    return {viewport:`${w}×${h}`,home:initial,lyrics,status:'passed'};
  }finally{await page.close();}
}
async function idleRun(browser){
  const {page,errors}=await openFixture(browser,{width:800,height:480},'car',{idle:true});
  try{
    await checkLayout(page);
    assert.equal(await page.locator('#carNow [data-act="toggle"]').isDisabled(),true);
    await page.locator('[data-act="playRow"]').first().click();
    await page.waitForSelector('.car-disc img[src]');
    assert.equal((await page.evaluate(()=>window.__qa.snapshot())).player.playing,true);
    await page.locator('.car-disc-button').click();
    await page.waitForSelector('html.car-lyrics-open');
    await checkLayout(page);
    assert.deepEqual(errors,[]);
    return {idle:'passed'};
  }finally{await page.close();}
}
async function phoneRun(browser){
  const {page,errors}=await openFixture(browser,{width:390,height:844},'phone');
  try{
    assert.equal(await page.locator('#carNav').isVisible(),false);
    assert.equal(await page.locator('#carNow').isVisible(),false);
    assert.equal(await page.locator('#dock').isVisible(),true);
    await page.locator('#mini [data-act="openPlayer"]').click();
    await page.waitForSelector('#player:not([hidden])');
    await page.locator('#player [data-act="sound"]').click();
    await page.locator('[data-act="soundPick"][data-arg="soft"]').click();
    await page.waitForSelector('[data-act="soundPick"][data-arg="soft"][aria-pressed="true"]');
    assert.deepEqual(errors,[]);
    return {phone:'passed'};
  }finally{await page.close();}
}
(async()=>{
  await fs.mkdir(out,{recursive:true});
  const browser=await launch(),report=[];
  try{
    for(const [w,h] of [[800,480],[1024,600],[1280,720],[1920,720]])report.push(await carRun(browser,w,h));
    report.push(await idleRun(browser),await phoneRun(browser));
    await fs.writeFile(path.join(out,'results.json'),JSON.stringify(report,null,2));
    console.log(JSON.stringify(report.map(({viewport,status,idle,phone})=>({viewport,status,idle,phone})),null,2));
  }catch(e){console.error(e);process.exitCode=1;}
  finally{await browser.close();}
})();
