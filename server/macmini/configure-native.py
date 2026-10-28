"""Configure private Mac services after restoring the database and assets.

Requires an existing PostgreSQL 17 cluster and a copied, mode-600 app.env.
Does not start services or change the public proxy.
"""
import os
import plistlib
from urllib.parse import quote
from pathlib import Path

root = Path.home() / "Library/Application Support/PointVerse"
data = root / "data"
agents = Path.home() / "Library/LaunchAgents"
agents.mkdir(exist_ok=True)
for directory in (data, data / "cloud", root / "backups"):
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)

def agent(label, args, environment=None):
    destination = agents / (label + ".plist")
    value = {"Label": label, "ProgramArguments": args, "RunAtLoad": True,
             "KeepAlive": True, "WorkingDirectory": str(root),
             "EnvironmentVariables": environment or {},
             "StandardOutPath": str(Path.home() / "Library/Logs" / (label + ".log")),
             "StandardErrorPath": str(Path.home() / "Library/Logs" / (label + ".error.log"))}
    with destination.open("wb") as output:
        plistlib.dump(value, output)
    destination.chmod(0o600)

agent("org.dianjie.database", ["/opt/homebrew/opt/postgresql@17/bin/postgres",
      "-D", str(data / "postgres"), "-p", "15432", "-h", "127.0.0.1",
      "-c", "shared_buffers=128MB", "-c", "max_connections=20", "-c", "work_mem=4MB"],
      {"LC_ALL": "C", "LANG": "C"})

# Preserve all existing provider configuration while overriding storage/topology.
environment = dict(os.environ)
keys = ["GOOGLE_CLIENT_IDS", "APPLE_CLIENT_IDS", "AI_UPSTREAM_URL", "AI_UPSTREAM_TOKEN", "AI_MODEL"]
environment = {key: environment[key] for key in keys if key in environment}
password = (root / "database-password").read_text().strip()
environment.update({"HTTP_ADDR": "100.89.246.35:8081", "TRUSTED_PROXY_IP": "100.77.218.97",
    "DATABASE_URL": "postgres://alex:" + quote(password, safe="") + "@127.0.0.1:15432/pointverse?sslmode=disable&pool_max_conns=8",
    "CLOUD_STORAGE_DIR": str(data / "cloud"), "GOMAXPROCS": "2"})
agent("org.dianjie.server", [str(root / "server")], environment)
print("Native service definitions written; start only after database restore and verification")
