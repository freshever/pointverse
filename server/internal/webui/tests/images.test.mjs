import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import vm from 'node:vm';
const source=await readFile(new URL('../assets/images.js',import.meta.url),'utf8');
const jobID='12345678-1234-1234-1234-123456789abc';
const settle=async()=>{for(let i=0;i<15;i++)await new Promise(resolve=>setImmediate(resolve));};
function app(fetcher, saved) {
 const elements=new Map(), storage=new Map(saved||[]);
 const element=id=>{if(!elements.has(id))elements.set(id,{value:'',hidden:false,disabled:false,listeners:{},addEventListener(name,fn){this.listeners[name]=fn;},setAttribute(){}});return elements.get(id);};
 const context={document:{getElementById:element},sessionStorage:{getItem:k=>storage.get(k)||null,setItem:(k,v)=>storage.set(k,v),removeItem:k=>storage.delete(k)},crypto:{randomUUID:()=>jobID},fetch:fetcher,AbortController,setTimeout:(fn,ms)=>ms===3000?setImmediate(fn):setTimeout(fn,ms),clearTimeout,console};
 vm.runInNewContext(source,context);
 return {element,storage,submit:()=>element('image-form').listeners.submit({preventDefault(){}})};
}
const json=(value,status=200)=>({status,ok:status>=200&&status<300,json:async()=>value});
test('lost creation response reuses nonce and can resume to a downloadable image',async()=>{
 let creations=0;const nonces=[];
 const ui=app(async(path,options)=>{
  if(path==='/web/auth/me')return json({user:{id:'owner'}});
  if(path.endsWith('/images/generations')){
   nonces.push(JSON.parse(options.body).request_id);
   if(++creations===1)throw new TypeError('offline');
   return json({id:jobID,status:'queued'},202);
  }
  return json({id:jobID,status:'succeeded',model:'sd15@test',data:[{b64_json:'iVBORw0KGgo='}]});
 });
 await settle();ui.element('prompt').value='森林';ui.submit();await settle();
 assert.equal(ui.element('resume').hidden,false);
 ui.element('resume').listeners.click();await settle();
 assert.deepEqual(nonces,[jobID,jobID]);
 assert.equal(ui.element('result').hidden,false);
 assert.match(ui.element('save').href,/^data:image\/png;base64,/);
 assert.equal(ui.storage.size,0);
});
test('reload resumes the current account job and cancellation reaches its endpoint',async()=>{
 const calls=[];const key='pointverse.imageJob.owner';
 const ui=app(async(path)=>{
  calls.push(path);
  if(path==='/web/auth/me')return json({user:{id:'owner'}});
  if(path.endsWith('/cancel'))return json({id:jobID,status:'cancelled'});
  return json({id:jobID,status:'queued'});
 },[[key,JSON.stringify({prompt:'tree',requestID:jobID,id:jobID})]]);
 // Cancellation can occur while the first status request is in flight.
 await Promise.resolve();await Promise.resolve();
 ui.element('cancel').listeners.click();await settle();
 assert(calls.some(path=>path.endsWith('/cancel')));
 assert(!calls.some(path=>path.endsWith('/images/generations')));
 assert.equal(ui.storage.size,0);
});
test('another account never resumes a stored task from the previous account',async()=>{
 const calls=[];const ui=app(async(path)=>{calls.push(path);return json({user:{id:'other'}});},[['pointverse.imageJob.owner',JSON.stringify({id:jobID,prompt:'private',requestID:jobID})]]);
 await settle();assert.deepEqual(calls,['/web/auth/me']);assert.equal(ui.element('prompt').value,'');
});
