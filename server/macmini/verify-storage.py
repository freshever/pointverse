"""Verify every database-referenced asset without logging user identifiers."""
import hashlib
import subprocess
from pathlib import Path

rows = subprocess.check_output(["/opt/homebrew/opt/postgresql@17/bin/psql", "-p", "15432", "-U", "alex",
    "-d", "pointverse", "-At", "-F", "|", "-c", "select user_id,sha256,byte_count from cloud_assets"], text=True)
root = Path.home() / "Library/Application Support/PointVerse/data/cloud"
count = 0
for row in rows.splitlines():
    user, digest, size = row.split("|")
    path = root / user / digest
    assert path.stat().st_size == int(size), "asset size mismatch"
    assert hashlib.file_digest(path.open("rb"), "sha256").hexdigest() == digest, "asset checksum mismatch"
    count += 1
print(f"Verified {count} database-referenced assets")
