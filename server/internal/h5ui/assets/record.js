import {prepareAudio,toBase64,recordingManifest,MAX_SECONDS,wavChunk} from './audio.mjs';
const $=id=>document.getElementById(id);
let owner=null,recorder=null,stream=null,ticker=null,started=0,chunks=[],chunkBytes=0,wav=null,duration=0,previewURL=null,busy='',requestController=null,engineText='',model='',language='',savePayload=null,ids=null,createdAt=0,completedParts=[],generation=0,discarding=false,disposed=false;
const status=value=>{$('status').textContent=value;};
function controls(){
 const recording=!!stream,working=!!busy;
 $('start').disabled=!owner||working||recording;$('start').hidden=recording;
 $('stop').hidden=!recording;$('file').disabled=!owner||working||recording;
 $('transcribe').disabled=!owner||working||recording||!wav||!!savePayload?.saved;
 $('discard').disabled=working||recording;$('save').disabled=!owner||working||!!savePayload?.saved;
 $('transcript').disabled=working;$('transcript').readOnly=!!savePayload;$('cancel').hidden=busy!=='transcribing';
}
async function api(path,{body,method='GET',signal,timeout=30000}={}){
 const controller=new AbortController(),timer=setTimeout(()=>controller.abort(),timeout);
 const abort=()=>controller.abort();signal?.addEventListener('abort',abort,{once:true});if(signal?.aborted)controller.abort();
 try{
  const response=await fetch(path,{method,credentials:'same-origin',cache:'no-store',signal:controller.signal,headers:body instanceof Blob?{'Content-Type':'application/octet-stream'}:body?{'Content-Type':'application/json'}:{},body:body instanceof Blob?body:body?JSON.stringify(body):undefined});
  const result=await response.json();
  if(response.status===401){owner=null;$('login').hidden=false;throw new Error('登录已过期，请重新登录。录音仍可在本页下载。');}
  if(!response.ok){const code=result.error?.code;throw new Error(code==='storage_quota_exceeded'?'云端空间已满，请先整理资料。':response.status===429?'请求较多，请稍后再试。':response.status===413?'音频或文字超出限制。':response.status===503||response.status===502?'云端暂时繁忙或不可用，请保留录音稍后重试。':'请求未完成，请稍后重试。');}
  return result;
 }finally{clearTimeout(timer);signal?.removeEventListener('abort',abort);}
}
function stopTracks(){stream?.getTracks().forEach(track=>track.stop());stream=null;clearInterval(ticker);ticker=null;}
function clearAudio(){generation++;wav=null;duration=0;engineText='';completedParts=[];model='';savePayload=null;ids=null;if(previewURL)URL.revokeObjectURL(previewURL);previewURL=null;$('audio').removeAttribute('src');$('audio').load();$('preview').hidden=true;$('result').hidden=true;$('saved').hidden=true;$('transcript').value='';$('file').value='';$('timer').textContent='00:00 / 30:00';controls();}
async function accept(blob){
 const version=++generation;busy='preparing';controls();status('正在准备音频，尚未上传…');
 try{
  const result=await prepareAudio(blob);if(disposed||version!==generation)return;
  wav=result.wav;duration=result.duration;createdAt=Date.now()/1000;ids=Object.fromEntries(['point','message','operation','asset','transcript'].map(key=>[key,crypto.randomUUID()]));
  if(previewURL)URL.revokeObjectURL(previewURL);previewURL=URL.createObjectURL(wav);$('audio').src=previewURL;$('download-audio').href=previewURL;$('preview').hidden=false;$('duration').textContent=`${duration.toFixed(1)} 秒 · 可试听后上传`;
  $('result').hidden=true;$('saved').hidden=true;savePayload=null;status('录音已准备好，点击“上传并识别”发送到云端。');
 }catch(error){status(error.message);}finally{if(version===generation){busy='';controls();}}
}
$('start').addEventListener('click',async()=>{
 if(!owner||busy||stream)return;
 if(!navigator.mediaDevices?.getUserMedia||!globalThis.MediaRecorder){status('当前浏览器不支持直接录音，请选择音频文件，或在 Safari / Chrome 中打开。');return;}
 busy='permission';controls();
 try{
  const acquired=await navigator.mediaDevices.getUserMedia({audio:{channelCount:1,echoCancellation:true,noiseSuppression:true}});
  if(disposed){acquired.getTracks().forEach(track=>track.stop());return;}
  clearAudio();stream=acquired;chunks=[];chunkBytes=0;discarding=false;
  const type=['audio/webm;codecs=opus','audio/mp4','audio/webm'].find(value=>MediaRecorder.isTypeSupported(value));
  recorder=type?new MediaRecorder(stream,{mimeType:type}):new MediaRecorder(stream);
  recorder.ondataavailable=event=>{if(event.data.size){chunks.push(event.data);chunkBytes+=event.data.size;if(chunkBytes>100*1024*1024){discarding=true;if(recorder.state==='recording')recorder.stop();status('录音文件超出限制，请缩短后重录。');}}};
  recorder.onerror=()=>{discarding=true;stopTracks();busy='';status('录音中断，请重新录制或选择音频文件。');controls();};
  recorder.onstop=()=>{const blob=new Blob(chunks,{type:recorder.mimeType});chunks=[];stopTracks();busy='';controls();if(!discarding&&!disposed)accept(blob);};
  started=performance.now();recorder.start(1000);busy='';status('正在录音，音频暂存在当前页面，尚未上传。');
  ticker=setInterval(()=>{const seconds=Math.min(MAX_SECONDS,Math.floor((performance.now()-started)/1000));$('timer').textContent=`${String(Math.floor(seconds/60)).padStart(2,'0')}:${String(seconds%60).padStart(2,'0')} / 30:00`;if((performance.now()-started)/1000>=MAX_SECONDS-0.5&&recorder.state==='recording')recorder.stop();},250);
 }catch(error){stopTracks();busy='';status(error.name==='NotAllowedError'?'未获得麦克风权限。可在浏览器设置中允许，或选择音频文件。':'无法启动麦克风，请检查设备是否被占用。');}finally{if(busy==='permission')busy='';controls();}
});
$('stop').addEventListener('click',()=>{if(recorder?.state==='recording'){busy='stopping';controls();recorder.stop();}});
$('file').addEventListener('change',()=>{const file=$('file').files[0];if(file&&!busy){clearAudio();accept(file);}});
$('discard').addEventListener('click',()=>{if(!busy){clearAudio();status('录音已丢弃。');}});
$('transcribe').addEventListener('click',async()=>{
 if(!owner||busy||!wav)return;busy='transcribing';requestController=new AbortController();controls();status('正在上传并识别，请稍候…');
 try{
  const count=Math.ceil((wav.size-44)/(120*32000));
  for(let index=completedParts.length;index<count;index++){
   if(requestController.signal.aborted)throw new DOMException('Aborted','AbortError');
   status(`正在识别第 ${index+1} / ${count} 段，已完成 ${index} 段…`);
   const chunk=wavChunk(wav,index);
   const part=await api('/web/ai/audio/transcriptions',{method:'POST',body:{audio:toBase64(await chunk.arrayBuffer())},signal:requestController.signal,timeout:180000});
   if(typeof part.text!=='string')throw new Error('分段结果异常，请重试。');
   completedParts.push(part);
   $('transcript').value=completedParts.map(value=>value.text).filter(Boolean).join('\n');
  }
  const result={text:completedParts.map(value=>value.text).filter(Boolean).join('\n'),model:[...new Set(completedParts.map(value=>value.model))].join(' / '),language:completedParts[0]?.language};
  if(typeof result.text!=='string')throw new Error('识别结果异常，请保留录音重试。');
  engineText=result.text;model=result.model||'pointverse-cloud-speech';language=result.language||'und';$('transcript').value=engineText;$('result').hidden=false;$('model').textContent='识别模型：'+model;savePayload=null;
  status(engineText.trim()?'识别完成，可修改文字后保存。':'未识别到清晰语音，可重试或手动输入文字后保存。');
 }catch(error){status(error.name==='AbortError'?'已停止等待，录音仍保留在本页。云端可能仍在结束处理，请稍后再试。':error.message);}finally{busy='';requestController=null;controls();}
});
$('cancel').addEventListener('click',()=>requestController?.abort());
$('save').addEventListener('click',async()=>{
 if(!owner||busy||!wav||!ids)return;busy='saving';controls();status('正在保存录音与文字…');
 try{
  // Stable IDs and exact payload let a lost commit response be retried without duplication.
  if(!savePayload){const bytes=await wav.arrayBuffer();const sha256=Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',bytes)),byte=>byte.toString(16).padStart(2,'0')).join('');savePayload={manifest:recordingManifest({ids,createdAt,sha256,byteCount:wav.size,duration,text:$('transcript').value,engineText,model,language})};}
  const manifest=savePayload.manifest;
  await api('/web/sync/assets/'+manifest.assets[0].sha256,{method:'PUT',body:wav,timeout:300000});
  const saved=await api('/web/sync/points',{method:'POST',body:manifest});if(saved.point_id!==ids.point)throw new Error('保存结果异常，请重试。');
  savePayload.saved=true;$('saved').hidden=false;status('录音与文字已保存到云端想法。');
 }catch(error){status(error.name==='AbortError'?'保存超时，可点击保存重试；不会重复创建想法。':error.message);}finally{busy='';controls();}
});
$('transcript').addEventListener('input',()=>{if(savePayload&&!savePayload.saved)status('上次保存尚未确认，重试会保存上次提交的版本；请先完成保存。');});
$('copy').addEventListener('click',async()=>{try{await navigator.clipboard.writeText($('transcript').value);status('文字已复制。');}catch{status('无法自动复制，请长按文字选择复制。');}});
function leave(){disposed=true;generation++;discarding=true;requestController?.abort();if(recorder?.state==='recording')recorder.stop();stopTracks();if(previewURL)URL.revokeObjectURL(previewURL);}
addEventListener('pagehide',leave);
addEventListener('pageshow',event=>{if(event.persisted){disposed=false;clearAudio();busy='';controls();status('页面已恢复，请重新录音或选择文件。');}});
document.addEventListener('visibilitychange',()=>{if(document.hidden&&recorder?.state==='recording')recorder.stop();});
(async()=>{try{const result=await api('/web/auth/me');owner=result.user?.id||null;$('account-status').textContent=owner?'已登录，可以开始录音。':'请先登录。';$('login').hidden=!!owner;}catch(error){$('account-status').textContent=error.message;$('login').hidden=false;}controls();})();
