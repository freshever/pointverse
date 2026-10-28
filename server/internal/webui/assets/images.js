'use strict';
const $ = id => document.getElementById(id);
let record = null, storageKey = '', busy = false, cancelRequested = false, ready = false;
const terminal = new Set(['succeeded', 'failed', 'cancelled']);
const errors = {queue_full:'当前生成任务较多，请稍后重试。',model_not_installed:'图片模型暂时不可用。',insufficient_disk:'云端空间不足，请稍后重试。',invalid_request:'请检查描述，最多 600 字。',ai_unavailable:'云端暂时无法连接，请稍后继续查询。'};
function persist() { try { if(record)sessionStorage.setItem(storageKey, JSON.stringify(record));else sessionStorage.removeItem(storageKey); } catch {} }
function controls() {
 $('generate').disabled = !ready || busy || !!record;
 $('prompt').disabled = busy || !!record;
 $('cancel').hidden = !record;
 $('cancel').disabled = cancelRequested;
 $('resume').hidden = !record || busy;
 $('image-form').setAttribute('aria-busy', String(busy));
}
async function api(path, body) {
 const controller = new AbortController(), timer = setTimeout(()=>controller.abort(),30000);
 try {
  const response = await fetch(path,{method:body?'POST':'GET', credentials:'same-origin',cache:'no-store',signal:controller.signal,headers:body?{'Content-Type':'application/json'}:{},body:body?JSON.stringify(body):undefined});
  if(response.status===401){ready=false;throw new Error('登录已过期，请返回账户页重新登录。');}
  if(response.status===404){record=null;persist();throw new Error('任务已过期或不存在，请重新生成。');}
  const result = await response.json();
  if(!response.ok)throw new Error(errors[result.error?.code] || '请求未完成，请稍后重试。');
  return result;
 } catch(error) {
  if(error.name==='AbortError'||error instanceof TypeError)throw new Error('网络中断，任务可能仍在生成。请点击继续查询。');
  throw error;
 } finally {clearTimeout(timer);}
}
async function run() {
 if(busy||!record)return;
 busy=true;controls();
 try {
  // Retrying creation always reuses the saved UUID, including after a lost response.
  let job = record.id ? await api('/web/ai/jobs/'+encodeURIComponent(record.id)) : await api('/web/ai/images/generations',{prompt:record.prompt,request_id:record.requestID,model:'pointverse-image',size:'512x512',n:1});
  if(!/^[0-9a-f-]{36}$/i.test(job.id))throw new Error('任务响应异常，请稍后重试。');
  record.id=job.id;persist();
  const deadline=Date.now()+10*60*1000;
  while(true){
   if(cancelRequested && !terminal.has(job.status))job=await api('/web/ai/jobs/'+encodeURIComponent(job.id)+'/cancel',{});
   if(job.status==='succeeded'){
    const encoded=job.data?.[0]?.b64_json;
    if(typeof encoded!=='string'||encoded.length>6000000||!encoded.startsWith('iVBORw0KGgo'))throw new Error('图片响应异常，请继续查询。');
    const url='data:image/png;base64,'+encoded;
    $('generated').src=url;$('save').href=url;$('model').textContent='实际模型：'+(job.model||'Stable Diffusion 1.5');$('result').hidden=false;
    $('status').textContent='图片已生成，请保存。';record=null;persist();break;
   }
   if(job.status==='failed'||job.status==='cancelled'){
    record=null;persist();$('status').textContent=job.status==='cancelled'?'已取消生成。':'生成失败或图片未通过检查，请调整描述后重试。';break;
   }
   if(!['queued','running'].includes(job.status))throw new Error('任务状态异常，请继续查询。');
   $('status').textContent=job.status==='queued'?'任务已排队，请稍候…':'正在生成图片，通常需要几十秒…';
   if(Date.now()>deadline)throw new Error('任务仍在处理中，请稍后继续查询。');
   await new Promise(resolve=>setTimeout(resolve,3000));
   job=await api('/web/ai/jobs/'+encodeURIComponent(job.id));
  }
 } catch(error){$('status').textContent=error.message;}
 finally{busy=false;cancelRequested=false;controls();}
}
$('image-form').addEventListener('submit',event=>{
 event.preventDefault();if(!ready||busy||record)return;
 const prompt=$('prompt').value.trim();if(!prompt||[...prompt].length>600)return;
 record={prompt,requestID:crypto.randomUUID()};persist();$('result').hidden=true;run();
});
$('resume').addEventListener('click',run);
$('cancel').addEventListener('click',()=>{cancelRequested=true;controls();if(!busy)run();});
(async()=>{
 try{
  const current=await api('/web/auth/me');storageKey='pointverse.imageJob.'+current.user.id;ready=true;
  try{record=JSON.parse(sessionStorage.getItem(storageKey));if(record&&(!record.requestID||typeof record.prompt!=='string'))record=null;}catch{record=null;}
  if(record){$('prompt').value=record.prompt;controls();await run();}
  else $('status').textContent='已登录，可以开始生成。';
 }catch(error){$('status').textContent=error.message;}
 controls();
})();
