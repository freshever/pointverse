import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import vm from 'node:vm';
const source=(await readFile(new URL('../assets/record.js',import.meta.url),'utf8')).replace(/^import[^\n]+\n/,'');
const settle=async()=>{for(let i=0;i<12;i++)await new Promise(r=>setImmediate(r));};
function setup({denied=false}={}){
 const elements=new Map(),events={},calls=[],tracks={stopped:false,stop(){this.stopped=true;}};let microphone=0;
 const element=id=>{if(!elements.has(id))elements.set(id,{value:'',hidden:false,listeners:{},addEventListener(event,fn){this.listeners[event]=fn;},removeAttribute(){},load(){}});return elements.get(id);};
 class Recorder{static isTypeSupported(type){return type==='audio/mp4';}constructor(){this.mimeType='audio/mp4';this.state='inactive';}start(){this.state='recording';}stop(){this.state='inactive';this.ondataavailable?.({data:new Blob(['sample'],{type:this.mimeType})});this.onstop?.();}}
 const context={prepareAudio:async()=>({wav:new Blob(['wav']),duration:3}),toBase64:()=> 'audio',recordingManifest:()=>({}),document:{getElementById:element,addEventListener:(event,fn)=>events[event]=fn},addEventListener:(event,fn)=>events[event]=fn,navigator:{mediaDevices:{getUserMedia:async()=>{microphone++;if(denied)throw Object.assign(new Error(),{name:'NotAllowedError'});return {getTracks:()=>[tracks]};}}},MediaRecorder:Recorder,Blob,AbortController,URL:{createObjectURL:()=> 'blob:preview',revokeObjectURL(){}},setInterval:()=>1,clearInterval(){},setTimeout,clearTimeout,performance:{now:()=>100},crypto:{randomUUID:()=> 'id'},fetch:async(path,options)=>{calls.push({path,method:options.method});return {ok:true,status:200,json:async()=>path==='/web/auth/me'?{user:{id:'owner'}}:{text:'测试文字',model:'whisper-small',language:'zh'}};}};
 vm.runInNewContext(source,context);
 return {element,events,calls,tracks,get microphone(){return microphone;}};
}
test('microphone opens only after user action, stops on finish, audio is uploaded only on explicit recognition',async()=>{
 const app=setup();await settle();assert.equal(app.microphone,0);
 await app.element('start').listeners.click();assert.equal(app.microphone,1);
 app.element('stop').listeners.click();await settle();assert(app.tracks.stopped);
 assert.deepEqual(app.calls.map(x=>x.path),['/web/auth/me']);
 await app.element('transcribe').listeners.click();await settle();
 assert.equal(app.calls.at(-1).path,'/web/ai/audio/transcriptions');assert.equal(app.element('transcript').value,'测试文字');
});
test('permission refusal leaves file import available and sends no audio',async()=>{
 const app=setup({denied:true});await settle();await app.element('start').listeners.click();await settle();
 assert.match(app.element('status').textContent,/麦克风权限/);assert.equal(app.element('file').disabled,false);assert.equal(app.calls.length,1);
});
test('leaving the page closes microphone tracks and never uploads the recording',async()=>{
 const app=setup();await settle();await app.element('start').listeners.click();app.events.pagehide();await settle();
 assert.equal(app.tracks.stopped,true);assert.equal(app.calls.length,1);
});
