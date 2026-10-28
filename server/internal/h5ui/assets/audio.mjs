export const MAX_SECONDS=120;
export function encodeWAV(samples, sampleRate=16000) {
 if(!(samples instanceof Float32Array)||!samples.length||samples.length>sampleRate*MAX_SECONDS)throw new Error('录音需在 2 分钟以内。');
 const bytes=new ArrayBuffer(44+samples.length*2),view=new DataView(bytes);
 const word=(offset,value)=>{for(let i=0;i<value.length;i++)view.setUint8(offset+i,value.charCodeAt(i));};
 word(0,'RIFF');view.setUint32(4,36+samples.length*2,true);word(8,'WAVE');word(12,'fmt ');view.setUint32(16,16,true);view.setUint16(20,1,true);view.setUint16(22,1,true);view.setUint32(24,sampleRate,true);view.setUint32(28,sampleRate*2,true);view.setUint16(32,2,true);view.setUint16(34,16,true);word(36,'data');view.setUint32(40,samples.length*2,true);
 for(let i=0;i<samples.length;i++){const value=Number.isFinite(samples[i])?Math.max(-1,Math.min(1,samples[i])):0;view.setInt16(44+i*2,Math.round(value*(value<0?32768:32767)),true);}
 return bytes;
}
export async function prepareAudio(blob) {
 if(!blob.size||blob.size>20*1024*1024)throw new Error('请选择 20 MB 以内的音频文件。');
 const Context=globalThis.AudioContext||globalThis.webkitAudioContext;
 const Offline=globalThis.OfflineAudioContext||globalThis.webkitOfflineAudioContext;
 if(!Context||!Offline)throw new Error('当前浏览器无法处理音频，请使用 Safari 或 Chrome。');
 const context=new Context();let decoded;
 try{decoded=await context.decodeAudioData(await blob.arrayBuffer());}catch{throw new Error('无法读取此音频格式，请换用 WAV、M4A 或其他浏览器支持的音频。');}finally{await context.close();}
 if(!Number.isFinite(decoded.duration)||decoded.duration<=0||decoded.duration>MAX_SECONDS||decoded.numberOfChannels>2)throw new Error('请选择 2 分钟以内的单声道或双声道录音。');
 const length=Math.min(16000*MAX_SECONDS,Math.floor(decoded.duration*16000));
 if(!length)throw new Error('录音太短，请重新录制。');
 const offline=new Offline(1,length,16000),source=offline.createBufferSource();source.buffer=decoded;source.connect(offline.destination);source.start();
 const rendered=await offline.startRendering();
 return {wav:new Blob([encodeWAV(rendered.getChannelData(0))],{type:'audio/wav'}),duration:length/16000};
}
export function toBase64(buffer){
 const data=new Uint8Array(buffer);let text='';
 for(let i=0;i<data.length;i+=32768)text+=String.fromCharCode(...data.subarray(i,i+32768));
 return btoa(text);
}
export function recordingManifest({ids,createdAt,sha256,byteCount,duration,text,engineText,language,model}){
 const title=Array.from(text.trim()||'录音想法').slice(0,40).join('');
 const preview=Array.from(text).slice(0,500).join('');
 return {format_version:1,point_id:ids.point,revision:1,title,preview,created_at:createdAt,
 assets:[{id:ids.asset,sha256,byte_count:byteCount,kind:'audio'}],payload:{
 points:[{id:ids.point,accepted_title:title,status:'active',head_revision:1,created_at:createdAt,updated_at:createdAt}],
 messages:[{id:ids.message,operation_id:ids.operation,point_id:ids.point,sequence:1,role:'user',modality:'voice',user_text:null,created_at:createdAt}],
 audio_assets:[{id:ids.asset,message_id:ids.message,relative_path:'audio/'+ids.asset+'.wav',sha256,byte_count:byteCount,duration_ms:Math.round(duration*1000),codec:'pcm_s16le',sample_rate:16000,state:'available',created_at:createdAt}],
 transcripts:[{id:ids.transcript,asset_id:ids.asset,engine_text:engineText,user_text:text,locale:language||'und',model_id:model,model_sha256:'',state:'succeeded',error_code:null,created_at:createdAt,updated_at:createdAt}],
 point_images:[],transcription_candidates:[],derivations:[],facet_overrides:[],confirmed_relations:[],origins:[]}};
}
