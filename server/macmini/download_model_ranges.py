"""Resumable bounded-range download; a pinned whole-file digest is mandatory."""
from concurrent.futures import ThreadPoolExecutor,as_completed
import hashlib,json,os,re,subprocess,threading,time,urllib.request
from pathlib import Path


def sha256(path):
    digest=hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda:stream.read(1<<20),b''):digest.update(block)
    return digest.hexdigest()


def download(target,url,size,expected,workers=12,chunk_size=8*(1<<20)):
    target=Path(target)
    if target.is_file() and target.stat().st_size==size and sha256(target)==expected:return
    chunks=target.parent/('.'+target.name+'.ranges');chunks.mkdir(exist_ok=True)
    curl_env=os.environ.copy()
    for scheme,proxy in urllib.request.getproxies().items():
        if scheme in ("http","https"):curl_env.setdefault(scheme+"_proxy",proxy)
    count=(size+chunk_size-1)//chunk_size
    gate=threading.Lock();next_allowed=[0.0]
    def await_slot():
        while True:
            with gate:
                delay=next_allowed[0]-time.monotonic()
                if delay<=0:next_allowed[0]=time.monotonic()+1;return
            time.sleep(min(delay,5))
    def fetch(index):
        start=index*chunk_size;end=min(size,start+chunk_size)-1
        path=chunks/f'{index:05d}.bin';marker=chunks/f'{index:05d}.json';headers=chunks/f'{index:05d}.headers'
        if marker.is_file() and path.is_file():
            data=json.loads(marker.read_text())
            if path.stat().st_size==end-start+1 and data.get('sha256')==sha256(path):return index
        part=chunks/f'{index:05d}.part'
        for attempt in range(6):
            await_slot()
            result=subprocess.run(['curl','-fLsS','--connect-timeout','15','--max-time','180',
                '--range',f'{start}-{end}','--max-filesize',str(end-start+1),'--dump-header',str(headers),'--output',str(part),url],env=curl_env)
            if result.returncode:
                content=headers.read_text() if headers.exists() else ''
                if re.search(r'(?im)^HTTP/[^ ]+ 429',content):
                    retry=re.findall(r'(?im)^retry-after:\s*(\d+)',content)
                    pause=max(60,int(retry[-1]) if retry else 60)
                    with gate:next_allowed[0]=max(next_allowed[0],time.monotonic()+pause)
                    print('Download source rate-limited; waiting before retry.',flush=True)
                else:time.sleep(min(2**attempt,30))
                continue
            ranges=re.findall(r'(?im)^content-range:\s*bytes (\d+)-(\d+)/(\d+)\s*$',headers.read_text())
            if not ranges or tuple(map(int,ranges[-1]))!=(start,end,size) or part.stat().st_size!=end-start+1:continue
            os.replace(part,path);marker.write_text(json.dumps({'sha256':sha256(path)}));return index
        raise RuntimeError(f'Model range download failed: {index}')
    completed=0
    with ThreadPoolExecutor(max_workers=workers) as pool:
        futures=[pool.submit(fetch,index) for index in range(count)]
        try:
            for future in as_completed(futures):
                future.result();completed+=1
                if completed%8==0 or completed==count:print(f'Model ranges verified: {completed}/{count}',flush=True)
        except BaseException:
            for future in futures:future.cancel()
            pool.shutdown(wait=True,cancel_futures=True)
            raise
    assembled=target.with_suffix(target.suffix+'.verified-next')
    with assembled.open('wb') as output:
        for index in range(count):
            with (chunks/f'{index:05d}.bin').open('rb') as source:
                for data in iter(lambda:source.read(1<<20),b''):output.write(data)
        output.flush();os.fsync(output.fileno())
    if assembled.stat().st_size!=size or sha256(assembled)!=expected:raise RuntimeError('Pinned model SHA256 mismatch')
    os.replace(assembled,target)
    import shutil
    shutil.rmtree(chunks)
