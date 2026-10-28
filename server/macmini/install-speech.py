"""Install pinned Whisper large-v3-turbo files, with resume and integrity checks."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

REPO = "dropbox-dash/faster-whisper-large-v3-turbo"
REVISION = "0a363e9161cbc7ed1431c9597a8ceaf0c4f78fcf"
FILES = {
    "config.json": (2263, "git", "0351d1d6870005e865747b781b5d7c23ea0459cd"),
    "model.bin": (1617884929, "sha256", "e76620f83d5f5b69efd3d87e3dc180c1bd21df9fbebacfd4335e5e1efcc018da"),
    "preprocessor_config.json": (340, "git", "931c77a740890c46365c7ae0c9d350ba3cca908f"),
    "tokenizer.json": (2710337, "git", "17456db595adc78a973f97d69d8cb50bc87c0b1c"),
    "vocabulary.json": (1068114, "git", "0adcd01e7c237205d593b707e66dd5d7bc785d2d"),
}

def verified(path, size, kind, expected):
    if not path.is_file() or path.stat().st_size != size:
        return False
    digest = hashlib.sha256() if kind == "sha256" else hashlib.sha1()
    if kind == "git":
        digest.update(("blob " + str(size) + "\0").encode())
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest() == expected

support = Path.home() / "Library/Application Support/PointVerse"
destination = support / "models/whisper-large-v3-turbo"
if sum(item[0] for item in FILES.values()) > 2 << 30:
    raise SystemExit("Speech model exceeds 2 GiB budget")
if shutil.disk_usage(support).free < 12 * (1 << 30):
    raise SystemExit("Speech installation requires 12 GiB free, preserving 10 GiB reserve")
destination.mkdir(parents=True, exist_ok=True)
for name, (size, kind, expected) in FILES.items():
    target = destination / name
    if verified(target, size, kind, expected):
        print(name, "already verified", flush=True)
        continue
    if size < 4 << 20:
        from huggingface_hub import hf_hub_download
        hf_hub_download(repo_id=REPO, filename=name, revision=REVISION, local_dir=destination, token=False)
        if not verified(target, size, kind, expected):
            raise SystemExit("Speech metadata integrity verification failed: " + name)
        print(name, "verified", size, flush=True)
        continue
    partial = target.with_suffix(target.suffix + ".part")
    for host in ("hf-mirror.com", "huggingface.co"):
        if partial.exists() and partial.stat().st_size > size:
            partial.unlink()
        if not verified(partial, size, kind, expected):
            result = subprocess.run(["curl", "--fail", "--location", "--continue-at", "-", "--retry", "3",
                "--connect-timeout", "20", "--max-time", "1800", "--speed-limit", "1024", "--speed-time", "60",
                "--output", str(partial), f"https://{host}/{REPO}/resolve/{REVISION}/{name}?download=true"])
            if result.returncode:
                continue
        if verified(partial, size, kind, expected):
            os.replace(partial, target)
            print(name, "verified", size, flush=True)
            break
        partial.unlink(missing_ok=True)
    else:
        raise SystemExit("Speech download/integrity verification failed: " + name)
(destination / "revision.txt").write_text(REVISION + "\n")
(destination / "revision.json").write_text(json.dumps({"repository": REPO, "revision": REVISION, "size_bytes": sum(x[0] for x in FILES.values())}))
for source_name in ("transcribe.py", "speech_text.py"):
    source = Path(__file__).with_name(source_name)
    staged = support / (source_name + ".next")
    shutil.copy2(source, staged)
    os.replace(staged, support / source_name)
print("Installed whisper-large-v3-turbo with verified upstream file hashes", flush=True)
