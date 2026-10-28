# PointVerse VPS disaster recovery

The normal writable service remains on the Mac mini. `backup-to-vps.sh` runs once daily at 03:30 Asia/Shanghai and sends a
logical PostgreSQL snapshot plus the attachment tree to the VPS. `receive-backup.sh` verifies SHA-256, path
safety, size limits, free disk, restores into `pointverse_standby`, and only then updates `latest-verified`.

Current VPS hard limits are 256 MiB for the restored database, 512 MiB for attachments, 2 GiB for the whole
DR directory, and at least 8 GiB free after an upload. Up to 7 daily database snapshots are retained. The latest
attachment tree is stored once. A failed backup never replaces the last verified version.

The standby database listens only on `127.0.0.1:15433`. The fallback API profile listens only on
`127.0.0.1:18081` and stays stopped during normal operation. Its health and readiness endpoints have been
tested against a restored production snapshot.

Promotion is manual because automatic failover could create two writable primaries. Record the exact value of
`/home/alex/dr/pointverse/latest-verified`, then run on the VPS:

```sh
/home/alex/dr/pointverse/bin/promote SNAPSHOT_ID PROMOTE_POINTVERSE_VPS
```

The script writes the `PROMOTED` fence, starts and checks the fallback API, validates Caddy, and switches the
public API upstream from the Mac mini to `127.0.0.1:18081`. While promoted, the receiver rejects Mac backups so
they cannot overwrite VPS writes. Promotion is not a routine availability probe.

There is intentionally no one-command failback. After the VPS accepts writes, stop public writes, create a new
snapshot from the VPS, rebuild the Mac database and attachments, verify them, and only then return Caddy to the
Mac upstream and remove the fence. Never reconnect the old Mac database as another writable primary.

Repository files:

- `macmini/backup-to-vps.sh`
- `macmini/org.dianjie.pointverse-backup.plist`
- `vps/compose.yaml`
- `vps/receive-backup.sh`
- `vps/promote.sh`

The shared capacity, monitoring, promotion, and failback policy is documented in
`docs/VPS灾备与临时接管.md`.
