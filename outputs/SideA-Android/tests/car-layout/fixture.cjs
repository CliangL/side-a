'use strict';
// Browser-only UI regression using generated artwork and a synthetic native bridge.
// No production endpoint, device credential, or audio playback is used here.
// Install Playwright outside source: npm install --prefix work/car-redesign playwright@1.64.1
// Run from repo root with NODE_PATH="$PWD/work/car-redesign/node_modules" node <this test>.
// CHROME_PATH overrides Chrome; SIDEA_QA_OUTPUT overrides ignored result/screenshot output.
const fs = require('node:fs/promises');
const path = require('node:path');
const { chromium } = require('playwright');
const assets = path.resolve(__dirname,'../../app/src/main/assets');
const mime = {'.html':'text/html','.js':'application/javascript','.css':'text/css','.jpg':'image/jpeg','.png':'image/png'};
async function launch() {
  return chromium.launch({executablePath:process.env.CHROME_PATH || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless:true,args:['--disable-background-networking']});
}
async function openFixture(browser, viewport, uiMode='car', {idle=false, reducedMotion='no-preference'}={}) {
  const page = await browser.newPage({viewport,deviceScaleFactor:1,reducedMotion});
  const errors=[];
  page.on('pageerror',e=>errors.push(e.message));
  await page.route('**/*', async route => {
    const u=new URL(route.request().url());
    if(u.origin !== 'https://sidea.test')return route.abort();
    const relative = decodeURIComponent(u.pathname==='/'?'/index.html':u.pathname);
    const target=path.resolve(assets,'.'+relative);
    if(!target.startsWith(assets+path.sep))return route.abort();
    try { await route.fulfill({body:await fs.readFile(target),contentType:mime[path.extname(target)]||'application/octet-stream'}); }
    catch { await route.fulfill({status:404,body:'not found'}); }
  });
  await page.addInitScript(({uiMode,idle})=>{
    const clone=x=>JSON.parse(JSON.stringify(x));
    const songs=[
      {id:'qa:1',trackID:'qq.qa1',source:'central',centralCatalog:true,apiEndpoint:'https://qa.invalid/v1/music',title:'海边的旧唱片',artist:'Side A 测试乐队',album:'沿海公路'},
      {id:'qa:2',trackID:'qq.qa2',source:'central',centralCatalog:true,apiEndpoint:'https://qa.invalid/v1/music',title:'山间清晨',artist:'Side A 测试乐队',album:'向远方'},
      {id:'qa:3',trackID:'wy.qa3',source:'central',centralCatalog:true,apiEndpoint:'https://qa.invalid/v1/music',title:'城市晚风',artist:'Side A 测试歌手',album:'夜色'},
      {id:'qa:4',trackID:'kw.qa4',source:'central',centralCatalog:true,apiEndpoint:'https://qa.invalid/v1/music',title:'雨落之后',artist:'Side A 测试歌手',album:'回声'},
      {id:'qa:5',trackID:'jx.qa5',source:'central',centralCatalog:true,apiEndpoint:'https://qa.invalid/v1/music',title:'一路向南',artist:'Side A 测试组合',album:'晴空'},
      {id:'qa:6',trackID:'qq.qa6',source:'central',centralCatalog:true,apiEndpoint:'https://qa.invalid/v1/music',title:'一首特别长的歌曲名字用来核对省略是否正确出现与控制按钮是否互不遮挡',artist:'一段特别长的歌手名字用于布局验证',album:'远行'},
    ];
    const covers=new Map();
    function cover(t){
      if(covers.has(t.id))return covers.get(t.id);
      const colors=[['#b6c8b5','#42626b','#dca291'],['#efd8aa','#586b4c','#192e28'],['#8eabb9','#192b3e','#b09b93'],['#b3bbc0','#425a58','#809b8f'],['#d8d2ac','#4d7b7a','#213b40'],['#b98683','#392f46','#bb956b']];
      const i=Math.max(0,songs.findIndex(s=>s.id===t.id));
      const canvas=document.createElement('canvas');canvas.width=canvas.height=512;
      const ctx=canvas.getContext('2d'),c=colors[i%colors.length],g=ctx.createLinearGradient(0,0,512,512);g.addColorStop(0,c[0]);g.addColorStop(1,c[1]);ctx.fillStyle=g;ctx.fillRect(0,0,512,512);
      ctx.fillStyle=c[2];ctx.beginPath();ctx.moveTo(0,330);ctx.lineTo(150,225);ctx.lineTo(295,350);ctx.lineTo(512,165);ctx.lineTo(512,512);ctx.lineTo(0,512);ctx.fill();
      ctx.fillStyle='rgba(255,255,235,.8)';ctx.beginPath();ctx.arc(350,120,48,0,Math.PI*2);ctx.fill();ctx.fillStyle='#f3eee1';ctx.font='italic 40px Georgia';ctx.fillText('Side A',38,447);ctx.font='14px sans-serif';ctx.fillText('ON THE ROAD / '+String(i+1).padStart(2,'0'),40,474);
      const result=canvas.toDataURL('image/png');covers.set(t.id,result);return result;
    }
    const presets=[['original','原声'],['surround','立体环绕'],['hall','音乐厅'],['vocal','清澈人声'],['studio','录音棚'],['bass','低音增强'],['soft','柔和聆听']].map(([id,name])=>({id,name}));
    let library={favorites:[songs[0]],recent:[songs[1],songs[0]],playlists:[{id:'qa-list',name:'在路上',tracks:songs.slice(0,4)}],trackingEnabled:true,revision:1,reason:'沿着你喜欢的旋律'};
    let settings={centralBase:'https://qa.invalid',searchSource:'all',allSources:['qq','wy','kw','jx'],cacheBytes:8388608,preferLossless:true,losslessOnly:false,cellularDataSaver:false,soundPreset:'original',soundPresets:presets};
    let player={track:idle?null:songs[0],queue:idle?[]:songs,index:0,playing:!idle,loading:false,error:'',elapsed:idle?0:43,duration:idle?0:234,mode:'sequence',quality:'无损 · FLAC',sound:{preset:'original',status:'off',engine:''}};
    const calls=[],delays={};
    function publish(){window.sideAPlayer(clone(player));}
    function playAction(p){
      switch(p.op){
        case 'play':player.queue=clone(p.tracks);player.index=p.index||0;player.track=player.queue[player.index];player.playing=true;player.elapsed=0;player.duration=234;break;
        case 'toggle':player.playing=!player.playing;break;
        case 'next':player.index=(player.index+1)%player.queue.length;player.track=player.queue[player.index];player.elapsed=0;break;
        case 'previous':player.index=(player.index+player.queue.length-1)%player.queue.length;player.track=player.queue[player.index];player.elapsed=0;break;
        case 'seek':player.elapsed=p.seconds;break;
        case 'mode':player.mode=p.mode;break;
        case 'move':{const [x]=player.queue.splice(p.from,1);player.queue.splice(p.to,0,x);player.index=player.queue.findIndex(t=>t.id===player.track.id);break;}
        case 'remove':player.queue.splice(p.index,1);break;
      }return clone(player);
    }
    function reply(action,p){
      switch(action){
        case 'init':return {uiMode,library:clone(library),settings:clone(settings),starter:clone(songs),player:clone(player)};
        case 'sysBars':return {};
        case 'player':return clone(player);
        case 'library':return clone(library);
        case 'recommend':case 'related':return clone(songs);
        case 'discover':return {hot:clone(songs.slice(1)),newReleases:clone(songs.slice(2)),hotSource:'热门曲目',newSource:'近期新作'};
        case 'cover':return cover(p.track);
        case 'lyrics':return Array.from({length:25},(_,i)=>({time:i*8,text:(p.track.id==='qa:2'?'山间的清晨':'沿着海岸的公路')+' · 第 '+(i+1)+' 行',translation:i===4?'一段测试译文':''}));
        case 'playAction':return playAction(p);
        case 'sound':player.sound={preset:p.preset,status:p.preset==='original'?'off':'active',engine:'equalizer'};settings.soundPreset=p.preset;return clone(player);
        case 'settings':if(p.op==='set')settings={...settings,...p};if(p.op==='clear')settings.cacheBytes=0;return clone(settings);
        case 'libraryAction':
          if(p.op==='favorite'){const i=library.favorites.findIndex(t=>t.id===p.track.id);if(i<0)library.favorites.push(p.track);else library.favorites.splice(i,1);}
          if(p.op==='tracking')library.trackingEnabled=p.enabled;
          library.revision++;return clone(library);
        case 'searchPage':return {items:p.page===1?clone(songs.filter(t=>t.trackID.startsWith(p.searchSource+'.'))):[],bySource:[{ok:true}]};
        case 'searchRank':case 'searchEvidence':return clone(p.tracks);
        case 'prepareSearch':return clone(settings);
        default:throw Error('Unhandled fixture bridge request: '+action);
      }
    }
    window.SideA={request(id,action,json){const p=JSON.parse(json);calls.push({action,payload:clone(p)});const respond=()=>{try{window.sideAReply(id,true,reply(action,p));}catch(e){window.sideAReply(id,false,e.message);}};const delay=delays[action+':'+(p.track?.id||'')]||0;if(delay)setTimeout(respond,delay);else queueMicrotask(respond);}};
    window.__qa={songs,calls,delays,snapshot:()=>clone({player,settings,library}),push(patch){Object.assign(player,patch);publish();},select(index){player.index=index;player.track=songs[index];player.queue=songs;player.elapsed=43;publish();},cover};
  },{uiMode,idle});
  await page.goto('https://sidea.test/');
  await page.waitForSelector(uiMode==='car'?'#carNow:not([hidden])':'#tabs button');
  await page.waitForTimeout(350);
  return {page,errors};
}
module.exports={launch,openFixture};
