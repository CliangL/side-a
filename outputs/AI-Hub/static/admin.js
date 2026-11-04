'use strict';
const $ = s => document.querySelector(s);
let state = {providers:[],models:[],apps:[],tasks:[],workers:[],usage:{}};
let csrf = '';
let activeView = 'overview';
let saving = false;
const titles = {overview:'运行总览',models:'模型与接口',apps:'软件分配',tasks:'调用记录',workers:'执行设备'};
const esc = v => String(v == null ? '' : v).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const number = v => Number(v || 0).toLocaleString('zh-CN');
const tokens = v => v == null ? '—' : number(v);
const money = v => '$' + Number(v || 0).toFixed(3);
const when = v => v ? new Date(typeof v === 'number' && v < 1e12 ? v*1000 : v).toLocaleString('zh-CN',{hour12:false}) : '尚无记录';
const byId = (list,id) => list.find(x => String(x.id) === String(id));
const modelName = id => (byId(state.models,id) || {}).name || '尚未分配';
const providerName = id => (byId(state.providers,id) || {}).name || '自定义接口';
function badge(label,kind) { return '<span class="badge '+(kind || '')+'">'+esc(label)+'</span>'; }
function notice(message,error) { $('#notice').hidden = false; $('#notice').className='notice'+(error?' error':''); $('#notice').textContent=message; }
function clearNotice() { $('#notice').hidden = true; }
async function api(path,method,body) {
  const opts={method:method || 'GET',headers:{'Content-Type':'application/json','X-CSRF-Token':csrf},credentials:'same-origin'};
  if(body !== undefined) opts.body=JSON.stringify(body);
  const response=await fetch(path,opts);
  let data;
  try { data=await response.json(); } catch(e) { throw new Error('服务暂时无法连接，请稍后刷新'); }
  if(response.status===401){location.replace('/login');throw new Error('请重新登录');}
  if(!response.ok || data.ok===false)throw new Error(data.error && data.error.message || '操作未完成，请重试');
  return data;
}
function status(item) {
  const code=item.status || item.last_test_status || (item.enabled===false?'disabled':'unconfigured');
  const map={succeeded:['已完成','good'],queued:['等待处理','warn'],leased:['处理中',''],running:['处理中',''],failed:['未完成','bad'],cancelled:['已取消',''],ok:['连接正常','good'],ready:['可用','good'],healthy:['连接正常','good'],success:['连接正常','good'],online:['在线','good'],offline:['离线','warn'],unconfigured:['待配置','warn'],untested:['待测试','warn'],disabled:['已停用',''],error:['连接异常','bad']};
  const v=map[code] || [code,''];return badge(v[0],v[1]);
}
function empty(text){return '<div class="empty">'+esc(text)+'</div>';}
function kv(key,value){return '<div class="kv"><span>'+esc(key)+'</span><span>'+esc(value)+'</span></div>';}
function heading(title,sub,buttons){return '<div class="section-heading"><div><h2>'+esc(title)+'</h2>'+(sub?'<p>'+esc(sub)+'</p>':'')+'</div><div class="section-actions">'+(buttons||'')+'</div></div>';}
function button(label,action,id,primary){return '<button class="'+(primary?'primary':'secondary')+'" data-action="'+action+'"'+(id?' data-id="'+esc(id)+'"':'')+'>'+esc(label)+'</button>';}
function appCards(){return state.apps.length?'<div class="cards">'+state.apps.map(a=>{
  const usage=(state.usage.apps || []).find(x=>x.app_id===a.id) || a;
  const spent=Number(usage.spent_usd || usage.monthly_spend_usd || 0),budget=Number(a.monthly_budget_usd || 0);const assigned=byId(state.models,a.model_id);const appLabel=a.enabled===false?'已停用':!assigned?'待分配模型':!assigned.has_key?'待填密钥':!assigned.pricing_configured?'待补单价':assigned.enabled===false?'模型已停用':'已启用';
  const usageDisplay=assigned && assigned.billing_mode==='subscription'
    ?kv('计费方式','已有订阅 / 固定费用')+kv('本月输入 Tokens',number(usage.input_tokens))+kv('本月输出 Tokens',number(usage.output_tokens))
    :kv('每月额度',money(budget))+kv('本月计费估算',money(spent))+'<div class="progress"><span style="width:'+Math.min(100,budget?spent/budget*100:0)+'%"></span></div>';
  return '<article class="card"><div class="card-head"><div><div class="card-icon">'+esc(a.name.slice(0,1))+'</div><h3>'+esc(a.name)+'</h3></div>'+badge(appLabel,appLabel==='已启用'?'good':'warn')+'</div>'+kv('分配模型',modelName(a.model_id))+usageDisplay+'<div class="card-actions">'+button('调整分配','edit-app',a.id)+button('更换接入密钥','rotate-key',a.id)+'</div></article>';
}).join('')+'</div>':empty('还没有接入的软件。添加后，每个软件都拥有独立的接入密钥和数据空间。');}
function renderOverview(){
  const usage=state.usage || {};
  const completed=state.tasks.filter(t=>t.status==='succeeded').length;
  const usable=state.models.filter(m=>['ok','success','ready','healthy'].includes(m.last_test_status || m.status)).length;
  $('#overview').innerHTML='<div class="stats">'+[
    ['已接入软件',state.apps.length,'各软件独立分配模型'],['配置的模型',state.models.length,usable+' 个已通过连接测试'],['近期完成任务',completed,'最近 '+state.tasks.length+' 条记录'],['本月 Tokens',number(Number(usage.input_tokens || 0)+Number(usage.output_tokens || 0)),'按接口返回的用量统计']
  ].map(x=>'<div class="stat"><div class="stat-label">'+esc(x[0])+'</div><div class="stat-value">'+esc(x[1])+'</div><div class="stat-sub">'+esc(x[2])+'</div></div>').join('')+'</div>'+
  '<div class="hero"><div><p class="eyebrow" style="color:#bccbb0">CONNECTED INTELLIGENCE</p><h2>'+(!state.models.length?'给软件配上合适的 AI。':'你的软件，有了统一的 AI 中心。')+'</h2><p>'+(!state.models.length?'添加兼容 OpenAI 的接口与模型，测试连接后即可分配给 Side A。':'更换模型在这里完成。Side A 根据听歌行为优化推荐，各个软件的数据和调用记录分别保存。')+'</p></div>'+button('管理模型 ↗','show-models',null,true)+'</div>'+heading('软件与模型','查看当前分配，随时调整',button('添加软件','add-app'))+appCards()+heading('最近的调用','只展示运行状态，不公开设备的听歌记录')+taskTable(state.tasks.slice(0,5));
}
function renderModels(){
  $('#models').innerHTML=heading('服务接口','同一接口可以配置多个模型',button('添加接口','add-provider',null,true))+
  (state.providers.length?'<div class="cards">'+state.providers.map(p=>'<article class="card"><div class="card-head"><h3>'+esc(p.name)+'</h3>'+badge(p.has_key?'已保存密钥':'待填写密钥',p.has_key?'good':'warn')+'</div><p class="mono">'+esc(p.base_url)+'</p><div class="card-actions">'+button('编辑接口','edit-provider',p.id)+button('获取模型列表','discover-models',p.id)+'</div></article>').join('')+'</div>':empty('添加你的模型服务商提供的 API 地址与密钥。密钥加密保存在服务器。'))+
  heading('可分配模型','修改后，新任务使用更新的配置',button('添加模型','add-model',null,true))+
  (state.models.length?'<div class="cards">'+state.models.map(m=>'<article class="card"><div class="card-head"><div><h3>'+esc(m.name)+'</h3><p class="muted">'+esc(providerName(m.provider_id))+'</p></div><div class="model-status">'+status(m)+(m.pricing_configured?'':badge('待补单价','warn'))+'</div></div>'+kv('实际模型',m.upstream_model)+kv('接口方式',m.api_mode==='responses'?'Responses':'Chat Completions')+kv('计费方式',m.billing_mode==='subscription'?'已有订阅 / 固定费用':'按 Tokens 计费')+kv('最近测试',when(m.last_test_at))+ '<div class="tag-list">'+state.apps.filter(a=>a.model_id===m.id).map(a=>badge(a.name)).join('')+'</div><div class="card-actions">'+button('编辑','edit-model',m.id)+button('测试连接','test-model',m.id)+'</div></article>').join('')+'</div>':empty('模型名请以服务商提供的名称为准，兼容接口不一定支持所有模型。'));
}
function taskTable(tasks){
  if(!tasks.length)return empty('还没有调用记录。软件发起 AI 请求后会自动出现在这里。');
  return '<div class="table-wrap"><table><thead><tr><th>软件 / 任务</th><th>模型</th><th>状态</th><th>时间</th><th>用量</th></tr></thead><tbody>'+tasks.map(t=>'<tr><td>'+esc((byId(state.apps,t.app_id)||{}).name || t.app_name || '应用')+'<small>'+esc(({'music.recommend.v1':'听歌偏好与推荐','hermes.analyze.v1':'文本分析'}[t.capability] || t.capability))+'</small></td><td>'+esc(modelName(t.model_id))+'</td><td>'+status(t)+(t.error?'<small>'+esc(typeof t.error==='string'?t.error:(t.error.message || t.error.code))+'</small>':'')+'</td><td>'+esc(when(t.created_at))+'</td><td>'+tokens(t.input_tokens)+' / '+tokens(t.output_tokens)+'<small>输入 / 输出 tokens</small></td></tr>').join('')+'</tbody></table></div>';
}
function renderWorkers(){
  $('#workers').innerHTML=heading('任务执行设备','普通模型调用由云端完成；家庭设备负责分配给它的任务')+(state.workers.length?'<div class="cards">'+state.workers.map(w=>'<article class="card"><div class="card-head"><h3>'+esc(w.name || w.id)+'</h3>'+status(w)+'</div>'+kv('执行方式',w.kind || w.type || 'Hermes')+kv('最近连接',when(w.last_seen_at || w.last_seen))+kv('版本',w.agent_version || w.version || '—')+kv('任务状态',w.ready?'运行就绪':'等待配置')+kv('允许的软件',(w.app_ids || []).map(id=>(byId(state.apps,id)||{}).name || '应用').join('、') || '尚未分配')+'<div class="card-actions">'+button('调整授权','edit-worker',w.id)+'</div></article>').join('')+'</div>':empty('家庭执行设备连接后会出现在这里。普通模型请求不依赖家庭设备在线。'));
}
function render(){renderOverview();renderModels();$('#apps').innerHTML=heading('软件分配','为每个软件选择模型与额度',button('添加软件','add-app',null,true))+appCards();$('#tasks').innerHTML=heading('调用记录','按软件区分，显示最近的任务状态')+taskTable(state.tasks);renderWorkers();}
function show(view){activeView=view;Object.keys(titles).forEach(v=>$('#'+v).hidden=v!==view);document.querySelectorAll('[data-view]').forEach(b=>b.classList.toggle('active',b.dataset.view===view));$('#page-title').textContent=titles[view];}
async function refresh(){const data=await api('/admin/api/state');state=Object.assign(state,data.state || data);['providers','models','apps','tasks','workers'].forEach(k=>{state[k]=state[k] || [];});state.usage={};['spent_usd','input_tokens','output_tokens'].forEach(k=>{state.usage[k]=state.apps.reduce((n,a)=>n+Number(a[k] || 0),0);});state.workers.forEach(w=>{w.status=w.enabled===false?'disabled':w.last_seen_at && Date.now()-new Date(w.last_seen_at).getTime()<180000?'online':'offline';});state.tasks.forEach(t=>{t.error=t.error || t.error_code;});render();}
function field(name,label,value,type,help){return '<label>'+esc(label)+'<input name="'+name+'" type="'+(type||'text')+'" value="'+esc(value)+'"'+(['password','number'].includes(type)?'':' required')+(type==='number'?' min="0" step="any"':'')+(type==='password'?' autocomplete="new-password"':'')+'>'+ (help?'<small>'+esc(help)+'</small>':'')+'</label>';}
function select(name,label,items,value){return '<label>'+esc(label)+'<select name="'+name+'">'+items.map(x=>'<option value="'+esc(x[0])+'"'+(String(value)===String(x[0])?' selected':'')+'>'+esc(x[1])+'</option>').join('')+'</select></label>';}
function check(name,label,value){return '<label><input name="'+name+'" type="checkbox"'+(value!==false?' checked':'')+'>'+esc(label)+'</label>';}
let submitEditor=null;
function editor(title,html,callback,submitLabel){$('#editor-title').textContent=title;$('#editor-fields').innerHTML=html;$('#editor-error').textContent='';$('#editor-submit').textContent=submitLabel || '保存配置';$('#editor-submit').hidden=!callback;submitEditor=callback;$('#editor').showModal();}
function closeEditor(){if(!saving){$('#editor').close();$('#editor-fields').innerHTML='';submitEditor=null;}}
function editProvider(id){const p=byId(state.providers,id)||{};editor(id?'编辑服务接口':'添加服务接口',field('name','接口名称',p.name || '')+field('base_url','API 地址',p.base_url || '','url','例如 https://你的服务商域名/v1')+field('api_key','API Key','','password',id?'留空保留原密钥。后台不会显示已保存的完整密钥。':'填写服务商提供的密钥，仅保存在服务器。'),async f=>{const b={name:f.get('name'),base_url:f.get('base_url')};if(f.get('api_key'))b.api_key=f.get('api_key');await api('/admin/api/providers'+(id?'/'+id:''),id?'PATCH':'POST',b);});}
function editModel(id,providerId,upstream){
  if(!state.providers.length){notice('请先添加一个服务接口。');show('models');return;}
  const m=byId(state.models,id)||{};
  editor(id?'编辑模型':'添加模型',field('name','显示名称',m.name || upstream || '')+
    select('provider_id','服务接口',state.providers.map(p=>[p.id,p.name]),m.provider_id || providerId || state.providers[0].id)+
    field('upstream_model','实际模型名',m.upstream_model || upstream || '',null,'填写服务商的模型 ID，大小写保持一致。')+
    select('api_mode','接口方式',[['chat','Chat Completions · 常用兼容接口'],['responses','Responses · 服务商需支持']],m.api_mode || 'chat')+
    select('billing_mode','计费方式',[['metered','按 Tokens 计费'],['subscription','已有订阅 / 固定费用，只统计用量']],m.billing_mode || 'metered')+
    '<div id="price-fields"><div class="field-row">'+field('input_price_per_million','输入单价 / 百万 tokens（美元）',m.input_price_per_million,'number')+
    field('output_price_per_million','输出单价 / 百万 tokens（美元）',m.output_price_per_million,'number')+'</div><p class="field-help">按量接口未填写单价时暂停软件调用；估算不能代替服务商账单。</p></div>'+
    '<details><summary>单次处理上限</summary><div class="field-row">'+field('max_input_tokens','输入上限',m.max_input_tokens || 32000,'number')+
    field('max_output_tokens','输出上限',m.max_output_tokens || 4096,'number')+'</div></details>'+check('enabled','启用这个模型',m.enabled),async f=>{
      const b={name:f.get('name'),provider_id:f.get('provider_id'),upstream_model:f.get('upstream_model'),api_mode:f.get('api_mode'),billing_mode:f.get('billing_mode'),enabled:f.has('enabled')};
      ['max_input_tokens','max_output_tokens'].forEach(k=>b[k]=Number(f.get(k)));
      ['input_price_per_million','output_price_per_million'].forEach(k=>{b[k]=b.billing_mode==='subscription'?0:f.get(k)===''?null:Number(f.get(k));});
      await api('/admin/api/models'+(id?'/'+id:''),id?'PATCH':'POST',b);
    });
  const billing=$('[name=billing_mode]');
  const updateBilling=()=>{$('#price-fields').hidden=billing.value==='subscription';};
  billing.onchange=()=>{if(billing.value==='metered'){['input_price_per_million','output_price_per_million'].forEach(k=>{$('[name='+k+']').value='';});}updateBilling();};
  updateBilling();
}
function editApp(id){const a=byId(state.apps,id)||{};const caps=a.capabilities || ['music.recommend.v1'];editor(id?'调整软件分配':'添加接入软件',field('name','软件名称',a.name || '')+select('model_id','使用的模型',[['','暂不分配']].concat(state.models.map(m=>[m.id,m.name])),a.model_id || '')+'<div id="budget-field">'+field('monthly_budget_usd','每月额度（美元）',a.monthly_budget_usd == null ? 5 : a.monthly_budget_usd,'number','按量计费接口使用这个额度。')+'</div>'+'<details><summary>软件使用的 AI 功能</summary>'+check('cap_music','听歌偏好与推荐',caps.includes('music.recommend.v1'))+check('cap_hermes','通过家庭 Hermes 分析文本',caps.includes('hermes.analyze.v1'))+'</details>'+check('enabled','允许软件使用 AI',a.enabled),async f=>{const result=await api('/admin/api/apps'+(id?'/'+id:''),id?'PATCH':'POST',{name:f.get('name'),model_id:f.get('model_id') || null,monthly_budget_usd:Number(f.get('monthly_budget_usd')),enabled:f.has('enabled'),capabilities:[f.has('cap_music')?'music.recommend.v1':null,f.has('cap_hermes')?'hermes.analyze.v1':null].filter(Boolean)});if(result.api_key)setTimeout(()=>showKey(result.api_key),0);});const selection=$('[name=model_id]');const updateBudget=()=>{$('#budget-field').hidden=(byId(state.models,selection.value)||{}).billing_mode==='subscription';};selection.onchange=updateBudget;updateBudget();}
function showKey(key){editor('软件接入密钥','<p class="muted">仅本次展示。将它保存到该软件的服务端配置，客户端不保存模型服务商的密钥。</p><div class="secret-value">'+esc(key)+'</div>',null);}
async function action(name,id){clearNotice();try{
  if(name==='show-models')show('models');
  else if(name==='add-provider'||name==='edit-provider')editProvider(id);
  else if(name==='add-model'||name==='edit-model')editModel(id);
  else if(name==='add-app'||name==='edit-app')editApp(id);
  else if(name==='edit-worker'){const w=byId(state.workers,id);editor('调整执行设备',check('enabled','启用这个执行设备',w.enabled)+state.apps.map(a=>check('app_'+a.id,a.name,(w.app_ids || []).includes(a.id))).join(''),async f=>{await api('/admin/api/workers/'+id,'PATCH',{enabled:f.has('enabled'),app_ids:state.apps.filter(a=>f.has('app_'+a.id)).map(a=>a.id)});});}
  else if(name==='test-model'){notice('正在发送一次简短测试请求…');const r=await api('/admin/api/models/'+id+'/test','POST',{confirm_cost:true});notice(r.test && r.test.success?((byId(state.models,id)||{}).pricing_configured?'模型连接成功，可以分配给软件。':'连接成功；补齐输入和输出单价后，软件才能启用这个模型。'):r.test && r.test.error && (r.test.error.message || r.test.error) || '连接测试未通过，请检查接口配置。',!(r.test && r.test.success));await refresh();}
  else if(name==='rotate-key'){editor('更换软件接入密钥','<p class="muted">更换后旧密钥会失效，需要同步更新该软件服务端的配置。</p>',async()=>{const r=await api('/admin/api/apps/'+id+'/rotate-key','POST',{});setTimeout(()=>showKey(r.api_key),0);},'生成新密钥');}
  else if(name==='discover-models'){notice('正在获取服务商的模型列表…');const r=await api('/admin/api/providers/'+id+'/models');const models=r.models || r.data || [];clearNotice();if(!models.length){notice('接口没有返回模型列表，可手动添加模型名。');return;}editor('选择服务商模型',select('model','可用模型',models.map(m=>[typeof m==='string'?m:m.id,typeof m==='string'?m:m.id]),''),async f=>{setTimeout(()=>editModel(null,id,f.get('model')),0);},'配置所选模型');}
}catch(e){notice(e.message,true);}}
$('#editor-form').addEventListener('submit',async function(e){e.preventDefault();if(!submitEditor||saving)return;saving=true;$('#editor-submit').disabled=true;try{await submitEditor(new FormData(this));saving=false;closeEditor();await refresh();notice('配置已保存。');}catch(err){$('#editor-error').textContent=err.message;}finally{saving=false;$('#editor-submit').disabled=false;}});
$('#close-editor').onclick=closeEditor;$('#cancel-editor').onclick=closeEditor;
$('#editor').addEventListener('cancel',function(e){e.preventDefault();closeEditor();});
document.addEventListener('click',function(e){const view=e.target.closest('[data-view]');if(view){show(view.dataset.view);return;}const a=e.target.closest('[data-action]');if(a){a.disabled=true;Promise.resolve(action(a.dataset.action,a.dataset.id)).finally(()=>a.disabled=false);}});
$('#refresh').onclick=async function(){this.disabled=true;try{clearNotice();await refresh();}catch(e){notice(e.message,true);}finally{this.disabled=false;}};
$('#logout-mobile').onclick=$('#logout').onclick=async()=>{try{await api('/admin/logout','POST',{});}finally{location.replace('/login');}};
(async()=>{try{const s=await api('/admin/api/session');if(!s.authenticated){location.replace('/login');return;}csrf=s.csrf_token;await refresh();show(activeView);}catch(e){notice(e.message,true);}})();
