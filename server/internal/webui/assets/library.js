'use strict';
const $ = id => document.getElementById(id);
let versions = [], items = [], filter = 'all', loading = false, detailSequence = 0;
const formatDate = value => new Intl.DateTimeFormat('zh-CN', {year:'numeric',month:'short',day:'numeric'}).format(value);
function text(tag, value, className) { const node = document.createElement(tag); node.textContent = value; if(className) node.className = className; return node; }
function message(id,value) { $(id).textContent=value; $(id).hidden=!value; }
async function get(path) {
 const response = await fetch(path,{credentials:'same-origin',cache:'no-store'});
 if(response.status===401){location.assign('/account/');throw new Error('请先登录账户。');}
 if(!response.ok) throw new Error('暂时无法读取云端内容，请稍后重试。');
 return response.json();
}
function render() {
 const search=$('search').value.trim().toLocaleLowerCase();
 const shown=items.filter(item=>(filter==='all'||(filter==='image'&&item.thumbnail_hash)||(filter==='audio'&&item.audio_hash)||(filter==='text'&&!item.asset_count)) && (!search||(item.title+' '+item.preview).toLocaleLowerCase().includes(search)));
 $('count').textContent=`${items.length} 条云端想法 · 当前显示 ${shown.length} 条`;
 $('cloud-grid').replaceChildren();
 for(const item of shown){
  const card=text('button','', 'cloud-card');card.type='button';
  if(item.thumbnail_hash){const image=document.createElement('img');image.src='/web/sync/assets/'+encodeURIComponent(item.thumbnail_hash);image.alt='';image.className='cover';image.loading='lazy';card.append(image);}
  else card.append(text('div',item.audio_hash?'♫':'✧','text-cover'));
  const content=text('div','','cloud-card-content');
  content.append(text('h2',item.title||'未命名想法'),text('p',item.preview||'点开查看内容','excerpt'));
  const foot=text('div','','card-footer');foot.append(text('span',formatDate(new Date(item.created_at*1000))),text('span',item.asset_count?`${item.asset_count} 个附件`:'文字','badge'));content.append(foot);card.append(content);
  card.addEventListener('click',()=>showDetail(item));$('cloud-grid').append(card);
 }
 $('empty').hidden=shown.length>0;
 $('empty-title').textContent=items.length?'没有匹配的想法':'还没有云端想法';
 $('empty-message').textContent=items.length?'换个关键词或内容类型试试。':'在 iOS 登录同一账户，选中一条或多条想法上传后，会显示在这里。';
}
async function load(){
 if(loading)return;loading=true;$('refresh').disabled=true;message('library-message','');
 try{
  const current=await get('/web/auth/me');$('profile').textContent=current.user.identities.find(i=>i.provider==='email')?.email||'我的账户';
  const collected=[];let cursor='';
  do{const page=await get('/web/sync/points'+(cursor?'?cursor='+encodeURIComponent(cursor):''));collected.push(...page.items);if(page.next_cursor&&page.next_cursor===cursor)throw new Error('分页读取失败，请刷新重试。');cursor=page.next_cursor;}while(cursor);
  versions=collected;const seen=new Set();items=versions.filter(item=>{if(seen.has(item.point_id))return false;seen.add(item.point_id);return true;});render();
 }catch(error){message('library-message',error.message);$('count').textContent='读取未完成';}
 finally{loading=false;$('refresh').disabled=false;}
}
async function showDetail(item){
 const sequence=++detailSequence;
 $('detail-title').textContent=item.title||'未命名想法';$('detail-date').textContent=formatDate(new Date(item.created_at*1000));
 const count=versions.filter(v=>v.point_id===item.point_id).length;
 $('detail-meta').textContent=`第 ${item.revision} 修订 · ${item.asset_count} 个附件 · 云端保留 ${count} 个版本`;
 $('detail-body').replaceChildren(text('p','正在读取内容…','detail-text'));message('detail-message','');
 const selector=$('detail-version');selector.replaceChildren();selector.hidden=count<=1;
 for(const version of versions.filter(v=>v.point_id===item.point_id)){const option=document.createElement('option');option.value=version.manifest_hash;option.textContent=`${formatDate(new Date(version.uploaded_at))} · 修订 ${version.revision}`;selector.append(option);}
 selector.value=item.manifest_hash;
 if(!$('detail').open)$('detail').showModal();
 try{
  const manifest=await get('/web/sync/points/'+encodeURIComponent(item.point_id)+'/versions/'+encodeURIComponent(item.manifest_hash));
  if(sequence!==detailSequence)return;
  const payload=manifest.payload||{};$('detail-body').replaceChildren();
  const section=(heading,value)=>{const node=text('section','','detail-section');node.append(text('h3',heading),text('div',value,'detail-text'));$('detail-body').append(node);return node;};
  for(const entry of payload.messages||[]){if(entry.user_text){const node=section(entry.role==='assistant'?'AI 回复':'原文',entry.user_text);if(entry.model_id)node.append(text('p','来源：'+entry.model_id,'model-note'));}}
  for(const entry of payload.transcripts||[]){if(entry.user_text)section('用户修正转写',entry.user_text);if(entry.engine_text)section('引擎转写',entry.engine_text);}
  for(const asset of manifest.assets||[]){
   const node=text('section','','detail-section');const url='/web/sync/assets/'+encodeURIComponent(asset.sha256);
   if(asset.kind==='image'){const image=document.createElement('img');image.src=url;image.alt='上传的想法图片';image.className='detail-media';node.append(image);const description=(payload.point_images||[]).find(i=>i.id===asset.id)?.recognized_text;if(description)node.append(text('p',description,'detail-text'));}
   else{node.append(text('h3','原始录音'));const audio=document.createElement('audio');audio.src=url;audio.controls=true;audio.preload='none';node.append(audio);}
   $('detail-body').append(node);
  }
  if(!$('detail-body').childElementCount)section('内容',item.preview||'这条想法没有文字或附件。');
 }catch(error){if(sequence===detailSequence){$('detail-body').replaceChildren();message('detail-message',error.message);}}
}
$('close-detail').addEventListener('click',()=>{$('detail').close();});
$('detail').addEventListener('close',()=>{detailSequence++;for(const audio of $('detail').querySelectorAll('audio')){audio.pause();audio.removeAttribute('src');audio.load();}});
$('refresh').addEventListener('click',load);$('search').addEventListener('input',render);
for(const button of document.querySelectorAll('[data-filter]'))button.addEventListener('click',()=>{filter=button.dataset.filter;for(const other of document.querySelectorAll('[data-filter]')){other.classList.toggle('chosen',other===button);other.setAttribute('aria-pressed',String(other===button));}render();});
load();

$('detail-version').addEventListener('change',()=>{const version=versions.find(v=>v.manifest_hash===$('detail-version').value);if(version)showDetail(version);});
