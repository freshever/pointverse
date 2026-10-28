#!/bin/sh
set -eu

support="$HOME/Library/Application Support/PointVerse"
lock="$support/backups/vps-backup.lock"
work=
cleanup() {
  [ -n "$work" ] && rm -rf "$work"
  rmdir "$lock" 2>/dev/null || true
}
mkdir "$lock" 2>/dev/null || exit 0
trap cleanup EXIT HUP INT TERM

snapshot_id=$(date -u +%Y%m%dT%H%M%SZ)
work="$support/backups/outgoing-$snapshot_id"
umask 077
mkdir "$work"
database_url=$(/usr/bin/plutil -extract EnvironmentVariables.DATABASE_URL raw -o - \
  "$HOME/Library/LaunchAgents/org.dianjie.server.plist")
database_url=${database_url%%&pool_max_conns=*}
/opt/homebrew/opt/postgresql@17/bin/pg_dump "$database_url" --format=custom --compress=zstd:6 \
  --file="$work/database.dump"
[ "$(stat -f %z "$work/database.dump")" -le 268435456 ] || { echo 'database dump exceeds 256 MiB' >&2; exit 75; }
asset_bytes=$(du -sk "$support/data/cloud" | awk '{print $1 * 1024}')
[ "$asset_bytes" -le 536870912 ] || { echo 'attachments exceed 512 MiB VPS limit' >&2; exit 75; }
COPYFILE_DISABLE=1 tar --no-xattrs -czf "$work/cloud.tgz" -C "$support/data" cloud
printf 'service=pointverse\nsnapshot_id=%s\ncreated_at=%s\nformat=pg_dump_custom_v17\n' \
  "$snapshot_id" "$snapshot_id" > "$work/metadata.env"
(cd "$work" && shasum -a 256 database.dump cloud.tgz metadata.env > SHA256SUMS)

remote=alex@172.245.205.27
remote_upload="/tmp/pointverse-dr-$snapshot_id.uploading"
remote_ready="/tmp/pointverse-dr-$snapshot_id"
ssh "$remote" "mkdir '$remote_upload'"
rsync -a "$work/" "$remote:$remote_upload/"
ssh "$remote" "mv '$remote_upload' '$remote_ready' && /home/alex/dr/pointverse/bin/receive-backup '$snapshot_id'"
