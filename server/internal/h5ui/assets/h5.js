'use strict';
(async()=>{
 try{
  const response=await fetch('/web/auth/me',{credentials:'same-origin',cache:'no-store',signal:AbortSignal.timeout(15000)});
  if(!response.ok)return;
  const result=await response.json();
  if(!result.user?.id)return;
  document.getElementById('session-status').textContent='已登录，继续浏览你的云端想法。';
  const link=document.getElementById('continue');link.textContent='进入云端想法 →';link.href='/account/library.html';
 }catch{}
})();
