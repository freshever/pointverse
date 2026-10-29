#!/usr/bin/env python3
"""One-shot, offline-only MLX Qwen3-ASR worker; the gateway serializes device use."""
import contextlib
import json
import os
from pathlib import Path
import sys
import wave


def main():
    model_path=Path(sys.argv[1]);audio=Path(sys.argv[2])
    marker=json.loads((model_path/'revision.json').read_text())
    if marker.get('id')!='qwen3-asr-1.7b' or marker.get('precision')!='8bit':raise SystemExit('unapproved_speech_model')
    os.environ['HF_HUB_OFFLINE']='1';os.environ['TRANSFORMERS_OFFLINE']='1';os.environ['TOKENIZERS_PARALLELISM']='false'
    with wave.open(str(audio),'rb') as wav:
        if wav.getnchannels()!=1 or wav.getsampwidth()!=2 or wav.getframerate()!=16000:raise SystemExit('invalid_speech_audio')
        duration=wav.getnframes()/16000
        if not 0<duration<=120:raise SystemExit('invalid_speech_duration')
    # Import/load diagnostics must never corrupt the JSON protocol on stdout.
    with contextlib.redirect_stdout(sys.stderr):
        import mlx.core as mx
        from mlx_audio.stt.utils import load_model
        from qwen_speech_result import format_result
        mx.set_cache_limit(256*(1<<20));mx.set_memory_limit(8*(1<<30))
        model=load_model(model_path,strict=True)
        output=model.generate(str(audio),max_tokens=4096,temperature=0,chunk_duration=30,verbose=False)
        result=format_result(output,duration)
    print(json.dumps(result,ensure_ascii=False))


if __name__=='__main__':main()
