'use strict';
function node(tag,text,className){const n=document.createElement(tag);if(text!==undefined)n.textContent=text;if(className)n.className=className;return n;}
function renderRelease(release,latest){
  if(!/^[a-zA-Z0-9._-]+\.apk$/.test(release.file)||!/^[a-f0-9]{64}$/.test(release.sha256))throw new Error('版本信息有误');
  const card=node(latest?'div':'article');const title=node(latest?'h2':'h3',`点界 ${release.versionName}`);title.append(node('span','开发测试版','tag'));card.append(title);
  const list=node('dl');const date=new Intl.DateTimeFormat('zh-CN',{timeZone:'Asia/Shanghai',dateStyle:'medium',timeStyle:'short'}).format(new Date(release.publishedAt));
  for(const [k,v] of [['发布时间',date],['构建版本',String(release.versionCode)],['系统要求',`Android ${release.minAndroid} 及以上 · API ${release.minSdk}`],['安装包',`${(release.size/1024).toFixed(1)} KB`]]){list.append(node('dt',k),node('dd',v));}card.append(list);
  const download=node('a',latest?'下载 Android 测试版':'下载此版本',latest?'download':'');download.href=`files/${release.file}`;download.download=release.file;card.append(download);
  card.append(node('p',release.notes,'notes'));
  const details=node('details');details.append(node('summary','文件与签名校验'));details.append(node('p','文件 SHA-256'),node('code',release.sha256),node('p','签名证书 SHA-256'),node('code',release.signerSha256));card.append(details);return card;
}
async function load(){const latest=document.querySelector('#latest');try{const response=await fetch('releases.json',{cache:'no-store'});if(!response.ok)throw new Error();const manifest=await response.json();const releases=manifest.releases;const current=releases.find(r=>r.file===manifest.latest);if(!current)throw new Error();latest.replaceChildren(renderRelease(current,true));document.querySelector('#history').replaceChildren(...releases.map(r=>renderRelease(r,false)));}catch{latest.replaceChildren(node('p','暂时无法读取版本列表，请稍后刷新重试。'));}}
load();
