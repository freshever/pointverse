#!/usr/bin/env python3
"""Remove only hash-verified duplicate model backups after a successful cutover."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import urllib.request
from model_storage import model_storage_ready


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--backup',required=True,type=Path);args=parser.parse_args()
    root=Path.home()/'Library/Application Support/PointVerse';backup=args.backup.resolve()
    if not backup.is_relative_to((root/'deployment-backups').resolve()) or not (backup/'activated.json').is_file():raise SystemExit('Not an activated deployment backup')
    marker=json.loads((backup/'activated.json').read_text());mount=Path(marker['externalVolume']);models=mount/'PointVerse/models';cache=mount/'PointVerse/huggingface/hub'
    if not model_storage_ready(models,str(mount),marker['volumeUUID']):raise SystemExit('External models are unavailable; nothing removed')
    for source,target in [(root/'models',models),(Path.home()/'.cache/huggingface/hub',cache)]:
        if not source.is_symlink() or source.resolve()!=target.resolve():raise SystemExit('Active model paths do not point at verified external copies')
    if not (Path.home()/'.ollama/models').resolve().is_relative_to(mount):raise SystemExit('Ollama model path is not external')
    environment=plistlib.loads((Path.home()/'Library/LaunchAgents/org.dianjie.ai-gateway.plist').read_bytes())['EnvironmentVariables']
    opener=urllib.request.build_opener(urllib.request.ProxyHandler({}));address='http://'+environment['POINTVERSE_AI_HOST']+':'+environment.get('POINTVERSE_AI_PORT','11435')
    request=urllib.request.Request(address+'/v1/capabilities',headers={'Authorization':'Bearer '+environment['POINTVERSE_AI_TOKEN']})
    with opener.open(request,timeout=10) as response:capabilities=json.load(response)
    if not any(item.get('id')=='speech' and item.get('model')=='qwen3-asr-1.7b' for item in capabilities['capabilities']):raise SystemExit('New speech service is not healthy')
    spec=importlib.util.spec_from_file_location('activation',Path(__file__).with_name('activate-qwen-asr.py'));module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    verified=[];removed_bytes=0
    for name,target in [('models-internal',models),('hub-internal',cache)]:
        source=backup/name
        if not source.exists():continue
        if source.is_symlink():raise SystemExit('Unexpected backup link; nothing removed')
        module.verify_copy(source,target)
        verified.append(source);removed_bytes+=sum(path.stat().st_size for path in source.rglob('*') if path.is_file() and not path.is_symlink())
    for source in verified:shutil.rmtree(source)
    model=models/'qwen3-asr-1.7b'
    # These are only interrupted download fragments; the completed model is not touched.
    shutil.rmtree(model/'.cache',ignore_errors=True)
    for path in model.glob('.download-probe-*'):path.unlink()
    for name in json.loads((model/'revision.json').read_text())['files']:(model/(name+'.part')).unlink(missing_ok=True)
    result={'allActiveModelPathsExternal':True,'internalModelDuplicateBytesRemoved':removed_bytes,'externalVolume':str(mount),'volumeUUID':marker['volumeUUID']}
    (backup/'model-cleanup.json').write_text(json.dumps(result,indent=2));print(json.dumps(result),flush=True)


if __name__=='__main__':main()
