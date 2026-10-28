#!/usr/bin/env python3
"""Bounded, one-shot speech worker. The gateway owns its temporary WAV file."""
import json
import sys
from pathlib import Path
from faster_whisper import WhisperModel
from speech_text import transcription_result

model = WhisperModel(sys.argv[1], device="cpu", compute_type="int8", cpu_threads=4,
                     num_workers=1, local_files_only=True)
segments, info = model.transcribe(sys.argv[2], beam_size=3, vad_filter=True)
result = [{"start": s.start, "end": s.end, "text": s.text} for s in segments]
print(json.dumps(transcription_result(result, info.language, Path(sys.argv[1]).name), ensure_ascii=False))
