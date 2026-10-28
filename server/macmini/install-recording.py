"""Reuse the pinned iOS Core ML models on Apple silicon; no extra ML runtime."""
import json
import shutil
from pathlib import Path
from huggingface_hub import HfApi, snapshot_download

root = Path.home() / "Library/Application Support/PointVerse/models/recording-coreml"
models = [
    ("aufklarer/CamPlusPlus-Speaker-CoreML", "c3cbd83f0c1028cf753b3e3e67639854218206a1", ["CamPlusPlus.mlmodelc/"]),
    ("FluidInference/sensevoice-small-coreml", "74bdbe74b2258f25b5400db72f6cbfbef7c74ded", ["SenseVoicePreprocessor.mlmodelc/", "SenseVoiceSmall_int8.mlmodelc/", "vocab.json"]),
]
manifests = []
for repo, revision, prefixes in models:
    info = HfApi().model_info(repo, revision=revision, files_metadata=True, token=False)
    files = [f for f in info.siblings if any(f.rfilename.startswith(prefix) for prefix in prefixes)]
    size = sum(f.size or 0 for f in files)
    if not 0 < size < 400 << 20 or shutil.disk_usage(root.parent).free < size + (12 << 30):
        raise RuntimeError("recording model disk budget exceeded")
    print(repo, round(size / (1 << 20)), "MiB", flush=True)
    snapshot_download(repo, revision=revision, allow_patterns=[f.rfilename for f in files], local_dir=root, token=False, max_workers=4)
    for f in files:
        assert (root / f.rfilename).stat().st_size == f.size
    manifests.append({"repo": repo, "revision": revision, "bytes": size})
(root / "revision.json").write_text(json.dumps(manifests))
print("Recording models installed", flush=True)
