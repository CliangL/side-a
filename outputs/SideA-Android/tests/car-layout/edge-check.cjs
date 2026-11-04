'use strict';
// Browser-only UI regression using generated artwork and a synthetic native bridge.
// No production endpoint, device credential, or audio playback is used here.
// Install Playwright outside source: npm install --prefix work/car-redesign playwright@1.64.1
// Run from repo root with NODE_PATH="$PWD/work/car-redesign/node_modules" node <this test>.
// CHROME_PATH overrides Chrome; SIDEA_QA_OUTPUT overrides ignored result/screenshot output.
const assert=require('node:assert/strict');
const fs=require('node:fs/promises');
const path=require('node:path');
const {launch,openFixture}=require('./fixture.cjs');
const out=path.resolve(process.env.SIDEA_QA_OUTPUT || 'work/car-redesign');
(async()=>{
 await fs.mkdir(out,{recursive:true});
 const browser=await launch();
 const result={};
 try{
  const {page,errors}=await openFixture(browser,{width:1280,height:720});
  await page.locator('.car-disc-button').click();
  await page.waitForSelector('#carLyrics .active');
  await page.evaluate(()=>{window.__qa.delays['lyrics:qa:2']=500;window.__qa.select(1);window.__qa.select(2);});
  await page.waitForFunction(()=>document.getElementById('carLyricsTitle')?.textContent==='城市晚风');
  await page.waitForTimeout(650);
  assert.equal(await page.locator('#carLyricsTitle').textContent(),'城市晚风');
  assert((await page.locator('#carLyrics').textContent()).includes('沿着海岸的公路'),'Stale lyric response replaced current song');
  assert(!(await page.locator('#carLyrics').textContent()).includes('山间的清晨'));
  result.staleLyricResponse='passed';
  const count=await page.evaluate(()=>window.__qa.calls.filter(c=>c.action==='lyrics').length);
  await page.locator('#main [data-act="back"]').click();
  await page.locator('.car-disc-button').click();
  await page.waitForSelector('#carLyrics .active');
  assert.equal(await page.evaluate(()=>window.__qa.calls.filter(c=>c.action==='lyrics').length),count,'Reopening lyrics refetched cached track');
  result.lyricReopenCache='passed';
  await page.locator('#carLyrics').evaluate(e=>{e.dispatchEvent(new WheelEvent('wheel',{deltaY:-200,bubbles:true}));e.scrollTo({top:0,behavior:'instant'});});
  await page.evaluate(()=>window.__qa.push({elapsed:160}));
  await page.waitForTimeout(450);
  assert.equal(await page.locator('#carLyrics').evaluate(e=>e.scrollTop),0,'User lyric scroll overridden before follow timeout');
  await page.waitForTimeout(5000);
  const position=await page.locator('#carLyrics').evaluate(e=>{const r=e.querySelector('.active').getBoundingClientRect(),b=e.getBoundingClientRect();return (r.top+r.height/2-b.top)/b.height;});
  assert(position>.35&&position<.65,'Follow did not recenter after user scroll delay: '+position);
  result.manualScrollFollow='passed';
  await page.locator('#carLyrics').evaluate(e=>{e.dispatchEvent(new WheelEvent('wheel',{deltaY:-80,bubbles:true}));e.scrollTop-=60;});
  await page.locator('#carLyrics .active').click();
  await page.waitForTimeout(650);
  const samePosition=await page.locator('#carLyrics').evaluate(e=>{const r=e.querySelector('.active').getBoundingClientRect(),b=e.getBoundingClientRect();return (r.top+r.height/2-b.top)/b.height;});
  assert(samePosition>.35&&samePosition<.65,'Clicking current lyric did not immediately recenter: '+samePosition);
  result.currentLineSeekRecenter='passed';
  await page.locator('#main [data-act="back"]').click();
  await page.evaluate(()=>window.__qa.push({loading:true}));
  assert.equal(await page.locator('.car-disc').evaluate(e=>getComputedStyle(e).animationPlayState),'paused');
  await page.evaluate(()=>window.__qa.push({loading:false}));
  assert.equal(await page.locator('.car-disc').evaluate(e=>getComputedStyle(e).animationPlayState),'running');
  result.loadingDisc='passed';
  assert.deepEqual(errors,[]);
  await page.close();
  const reduced=await openFixture(browser,{width:800,height:480},'car',{reducedMotion:'reduce'});
  assert.equal(await reduced.page.locator('.car-disc').evaluate(e=>getComputedStyle(e).animationName),'none');
  result.reducedMotion='passed';
  await reduced.page.close();
  await fs.writeFile(path.join(out,'edge-results.json'),JSON.stringify(result,null,2));
  console.log(JSON.stringify(result));
 }catch(e){console.error(e);process.exitCode=1;}
 finally{await browser.close();}
})();
