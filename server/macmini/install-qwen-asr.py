#!/usr/bin/env python3
"""Install pinned weights on an explicitly identified external APFS volume."""
import argparse,hashlib,json,os,plistlib,shutil,subprocess,urllib.request
from pathlib import Path


def volume_ready(mount,expected_uuid):
    try:
        info=plistlib.loads(subprocess.check_output(['diskutil','info','-plist',str(mount)],stderr=subprocess.DEVNULL))
        return info.get('VolumeUUID')==expected_uuid and info.get('Internal') is False and info.get('MountPoint')==str(mount)
    except (OSError,subprocess.SubprocessError,ValueError):return False


def verified(path,description):
    size,kind,expected=description
    if not path.is_file() or path.stat().st_size!=size:return False
    digest=hashlib.sha256() if kind=='sha256' else hashlib.sha1()
    if kind=='git':digest.update(('blob '+str(size)+'\0').encode())
    with path.open('rb') as stream:
        for chunk in iter(lambda:stream.read(1<<20),b''):digest.update(chunk)
    return digest.hexdigest()==expected


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--volume',required=True,type=Path);parser.add_argument('--volume-uuid',required=True)
    args=parser.parse_args();mount=args.volume.resolve()
    if not volume_ready(mount,args.volume_uuid):raise SystemExit('Expected external model volume is not mounted')
    manifest=json.loads(Path(__file__).with_name('qwen-asr-model.json').read_text())
    total=sum(value[0] for value in manifest['files'].values())
    if total>3*(1<<30) or shutil.disk_usage(mount).free<total+10*(1<<30):raise SystemExit('Insufficient model budget or external disk reserve')
    curl_env=os.environ.copy()
    for scheme,proxy in urllib.request.getproxies().items():
        if scheme in ('http','https'):curl_env.setdefault(scheme+'_proxy',proxy)
    root=mount/'PointVerse';destination=root/'models'/manifest['id'];destination.mkdir(parents=True,exist_ok=True)
    os.environ['HF_HOME']=str(root/'huggingface');os.environ['HF_XET_CACHE']=str(root/'huggingface/xet')
    os.environ['HF_XET_HIGH_PERFORMANCE']='1';os.environ['HF_HUB_DISABLE_TELEMETRY']='1'
    for name,description in sorted(manifest['files'].items(),key=lambda item:item[0]!='model.safetensors'):
        if not volume_ready(mount,args.volume_uuid):raise SystemExit('External model volume disappeared')
        target=destination/name
        if verified(target,description):print(name,'already verified',flush=True);continue
        print('Downloading',name,description[0],flush=True)
        if description[0]>16*(1<<20):
            from download_model_ranges import download
            url='https://hf-mirror.com/'+manifest['repository']+'/resolve/'+manifest['revision']+'/'+name+'?download=true'
            download(target,url,description[0],description[2],workers=16)
        else:
            for host in ('hf-mirror.com','huggingface.co'):
                temporary=target.with_suffix(target.suffix+'.part')
                url='https://'+host+'/'+manifest['repository']+'/resolve/'+manifest['revision']+'/'+name+'?download=true'
                result=subprocess.run(['curl','-fLsS','--connect-timeout','15','--max-time','180','--retry','2','--output',str(temporary),url],env=curl_env)
                if result.returncode==0 and verified(temporary,description):os.replace(temporary,target);break
            else:raise SystemExit('Model metadata download/integrity failed: '+name)
        if not verified(target,description):raise SystemExit('Model integrity check failed: '+name)
        print(name,'verified',flush=True)
    marker=destination/'revision.json.next';marker.write_text(json.dumps(manifest,indent=2));os.replace(marker,destination/'revision.json')
    print('Installed and verified',manifest['repository'],manifest['revision'],flush=True)


if __name__=='__main__':main()
