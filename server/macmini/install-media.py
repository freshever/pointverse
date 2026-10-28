"""Operator-only, revision-pinned media assets. Never called by inference requests."""
import json
import shutil
from pathlib import Path
from huggingface_hub import HfApi, snapshot_download

ROOT = Path.home() / "Library/Application Support/PointVerse/models"
MODELS = {
    "e5-small": ("intfloat/multilingual-e5-small", "614241f622f53c4eeff9890bdc4f31cfecc418b3", 600 << 20),
    "clap": ("laion/clap-htsat-unfused", "8fa0f1c6d0433df6e97c127f64b2a1d6c0dcda8a", 800 << 20),
    "sd15": ("stable-diffusion-v1-5/stable-diffusion-v1-5", "451f4fe16113bff5a5d2269ed5ad43b0592e9a14", 3 << 30),
}

def install(name):
    repo, revision, budget = MODELS[name]
    info = HfApi().model_info(repo, revision=revision, files_metadata=True, token=False)
    files = []
    for item in info.siblings:
        filename = item.rfilename
        if name == "sd15":
            include = (filename.endswith((".json", "/merges.txt", "/vocab.json")) or filename.endswith(".fp16.safetensors")) and filename.split("/")[0] in (
                "model_index.json", "scheduler", "tokenizer", "feature_extractor", "text_encoder", "unet", "vae", "safety_checker")
        else:
            include = "/" not in filename and (filename.endswith((".json", ".txt")) or filename == "model.safetensors" or (name == "clap" and filename == "pytorch_model.bin"))
        if include:
            files.append(item)
    size = sum(item.size or 0 for item in files)
    if not 0 < size <= budget or shutil.disk_usage(ROOT.parent).free < size + (12 << 30):
        raise RuntimeError("model size or free disk budget exceeded")
    destination = ROOT / name
    print(f"Downloading {name}: {size / (1 << 20):.0f} MiB, revision {revision}", flush=True)
    snapshot_download(repo, revision=revision, allow_patterns=[f.rfilename for f in files], local_dir=destination, token=False, max_workers=4)
    # Persist readiness only after every required file passes its size check.
    for item in files:
        if (destination / item.rfilename).stat().st_size != item.size:
            raise RuntimeError("download size mismatch")
    (destination / "revision.json").write_text(json.dumps({"repo": repo, "revision": revision, "bytes": size}))
    print(f"Installed {name}", flush=True)

if __name__ == "__main__":
    import sys
    for name in sys.argv[1:] or MODELS:
        install(name)
