import {test} from 'node:test';
import assert from 'node:assert/strict';
import {encodeWAV,toBase64,recordingManifest,wavChunk} from '../assets/audio.mjs';
test('WAV header, clipping and PCM16 samples match server transcription contract',()=>{
 const wav=encodeWAV(new Float32Array([-2,-.5,0,.5,2,NaN])),view=new DataView(wav);
 assert.equal(new TextDecoder().decode(wav.slice(0,4)),'RIFF');assert.equal(view.getUint16(22,true),1);assert.equal(view.getUint32(24,true),16000);assert.equal(view.getUint16(34,true),16);assert.equal(view.getUint32(40,true),12);
 assert.deepEqual(Array.from({length:6},(_,i)=>view.getInt16(44+i*2,true)),[-32768,-16384,0,16384,32767,0]);
 assert.equal(Buffer.from(toBase64(wav),'base64').length,wav.byteLength);
});
test('oversized and empty audio are rejected before any upload',()=>{
 assert.throws(()=>encodeWAV(new Float32Array()),/30 分钟/);
 assert.throws(()=>encodeWAV(new Float32Array(16000*1800+1)),/30 分钟/);
 assert.equal(encodeWAV(new Float32Array(16000*120)).byteLength,3840044);
});
test('cloud manifest preserves engine text separately from user edits and is retry-stable',()=>{
 const args={ids:{point:'p',message:'m',operation:'o',asset:'a',transcript:'t'},createdAt:1700000000,sha256:'a'.repeat(64),byteCount:160044,duration:5,text:'修正后的文字',engineText:'原始识别文字',language:'zh',model:'whisper-small'};
 const m=recordingManifest(args);assert.equal(m.payload.transcripts[0].engine_text,'原始识别文字');assert.equal(m.payload.transcripts[0].user_text,'修正后的文字');assert.equal(m.payload.points[0].head_revision,m.revision);assert.equal(m.assets[0].id,m.payload.audio_assets[0].id);assert.equal(m.payload.audio_assets[0].duration_ms,5000);assert.equal(JSON.stringify(m),JSON.stringify(recordingManifest(args)));
});

test('30 minute WAV splits into fifteen bounded requests without losing bytes',async()=>{
 const header=encodeWAV(new Float32Array(1)).slice(0,44);
 const payload=new Uint8Array(1800*32000);payload[0]=7;payload[payload.length-1]=11;
 const blob=new Blob([header,payload]);let bytes=0;
 for(let i=0;i<15;i++){
  const part=wavChunk(blob,i);assert.equal(part.size,3840044);
  const h=new DataView(await part.slice(0,44).arrayBuffer());assert.equal(h.getUint32(40,true),3840000);bytes+=part.size-44;
 }
 assert.equal(bytes,payload.length);assert.equal(wavChunk(blob,15),null);
 assert.equal(new Uint8Array(await wavChunk(blob,0).slice(44,45).arrayBuffer())[0],7);
 assert.equal(new Uint8Array(await wavChunk(blob,14).slice(-1).arrayBuffer())[0],11);
});
