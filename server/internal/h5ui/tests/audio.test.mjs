import {test} from 'node:test';
import assert from 'node:assert/strict';
import {encodeWAV,toBase64,recordingManifest} from '../assets/audio.mjs';
test('WAV header, clipping and PCM16 samples match server transcription contract',()=>{
 const wav=encodeWAV(new Float32Array([-2,-.5,0,.5,2,NaN])),view=new DataView(wav);
 assert.equal(new TextDecoder().decode(wav.slice(0,4)),'RIFF');assert.equal(view.getUint16(22,true),1);assert.equal(view.getUint32(24,true),16000);assert.equal(view.getUint16(34,true),16);assert.equal(view.getUint32(40,true),12);
 assert.deepEqual(Array.from({length:6},(_,i)=>view.getInt16(44+i*2,true)),[-32768,-16384,0,16384,32767,0]);
 assert.equal(Buffer.from(toBase64(wav),'base64').length,wav.byteLength);
});
test('oversized and empty audio are rejected before any upload',()=>{
 assert.throws(()=>encodeWAV(new Float32Array()),/2 分钟/);
 assert.throws(()=>encodeWAV(new Float32Array(16000*120+1)),/2 分钟/);
 assert.equal(encodeWAV(new Float32Array(16000*120)).byteLength,3840044);
});
test('cloud manifest preserves engine text separately from user edits and is retry-stable',()=>{
 const args={ids:{point:'p',message:'m',operation:'o',asset:'a',transcript:'t'},createdAt:1700000000,sha256:'a'.repeat(64),byteCount:160044,duration:5,text:'修正后的文字',engineText:'原始识别文字',language:'zh',model:'whisper-small'};
 const m=recordingManifest(args);assert.equal(m.payload.transcripts[0].engine_text,'原始识别文字');assert.equal(m.payload.transcripts[0].user_text,'修正后的文字');assert.equal(m.payload.points[0].head_revision,m.revision);assert.equal(m.assets[0].id,m.payload.audio_assets[0].id);assert.equal(m.payload.audio_assets[0].duration_ms,5000);assert.equal(JSON.stringify(m),JSON.stringify(recordingManifest(args)));
});
