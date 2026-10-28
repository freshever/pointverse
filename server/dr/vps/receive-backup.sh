#!/bin/sh
set -eu

snapshot_id=${1:-}
case "$snapshot_id" in
  20[0-9][0-9][01][0-9][0-3][0-9]T[0-2][0-9][0-5][0-9][0-5][0-9]Z) ;;
  *) echo "invalid snapshot id" >&2; exit 64 ;;
esac

dr_root=/home/alex/dr/pointverse
incoming="/tmp/pointverse-dr-$snapshot_id"
snapshot="$dr_root/snapshots/$snapshot_id"
max_dump_bytes=268435456
max_asset_bytes=536870912
max_dr_bytes=2147483648
min_free_bytes=8589934592

[ ! -f "$dr_root/PROMOTED" ] || { echo "VPS is promoted; refusing to overwrite its writable database" >&2; exit 69; }
[ -d "$incoming" ] || { echo "incoming snapshot missing" >&2; exit 66; }
[ ! -e "$snapshot" ] || { echo "snapshot already exists" >&2; exit 73; }
chmod -R go-rwx "$incoming"
cd "$incoming"
sha256sum -c SHA256SUMS
[ "$(stat -c %s database.dump)" -le "$max_dump_bytes" ] || { echo "database dump exceeds 256 MiB" >&2; exit 75; }
if tar -tzf cloud.tgz | grep -Eq '(^/|(^|/)\.\.(/|$))'; then
  echo "unsafe attachment archive" >&2
  exit 65
fi

next_assets="$dr_root/assets.next-$snapshot_id"
mkdir "$next_assets"
trap 'rm -rf "$next_assets"' EXIT HUP INT TERM
tar -xzf cloud.tgz -C "$next_assets"
asset_bytes=$(du -sb "$next_assets" | cut -f1)
[ "$asset_bytes" -le "$max_asset_bytes" ] || { echo "attachments exceed 512 MiB" >&2; exit 75; }
current_bytes=$(du -sb "$dr_root" | cut -f1)
incoming_bytes=$(du -sb "$incoming" | cut -f1)
[ $((current_bytes + incoming_bytes)) -le "$max_dr_bytes" ] || { echo "DR storage would exceed 2 GiB" >&2; exit 75; }
available=$(df -B1 --output=avail "$dr_root" | tail -1 | tr -d ' ')
[ $((available - incoming_bytes)) -ge "$min_free_bytes" ] || { echo "VPS would have less than 8 GiB free" >&2; exit 75; }

cd "$dr_root/config"
docker compose exec -T db psql -v ON_ERROR_STOP=1 -U pointverse_dr -d postgres \
  -c 'DROP DATABASE IF EXISTS pointverse_standby_next WITH (FORCE);' \
  -c 'CREATE DATABASE pointverse_standby_next;'
docker compose exec -T db pg_restore -U pointverse_dr -d pointverse_standby_next \
  --no-owner --no-privileges --exit-on-error < "$incoming/database.dump"
db_bytes=$(docker compose exec -T db psql -U pointverse_dr -d postgres -Atc \
  "select pg_database_size('pointverse_standby_next');")
[ "$db_bytes" -le "$max_dump_bytes" ] || { echo "restored database exceeds 256 MiB" >&2; exit 75; }
docker compose exec -T db psql -v ON_ERROR_STOP=1 -U pointverse_dr -d pointverse_standby_next -Atc \
  'select count(*) from schema_migrations; select count(*) from users; select count(*) from cloud_point_versions;' >/dev/null
docker compose exec -T db psql -v ON_ERROR_STOP=1 -U pointverse_dr -d postgres \
  -c 'DROP DATABASE IF EXISTS pointverse_standby WITH (FORCE);' \
  -c 'ALTER DATABASE pointverse_standby_next RENAME TO pointverse_standby;'

mv "$incoming" "$snapshot"
if [ -d "$dr_root/assets.current" ]; then rm -rf "$dr_root/assets.current"; fi
mv "$next_assets" "$dr_root/assets.current"
trap - EXIT HUP INT TERM
rm -f "$snapshot/cloud.tgz"
find "$dr_root/snapshots" -mindepth 2 -maxdepth 2 -type f -name cloud.tgz -delete
printf 'verified_at=%s\nrestored_database_bytes=%s\nasset_bytes=%s\n' \
  "$(date -u +%Y%m%dT%H%M%SZ)" "$db_bytes" "$asset_bytes" > "$snapshot/restore.env"
cd "$dr_root"
ln -sfn "snapshots/$snapshot_id" latest-verified.next
mv -Tf latest-verified.next latest-verified

count=0
for old in $(find "$dr_root/snapshots" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -r); do
  count=$((count + 1))
  [ "$count" -le 7 ] && continue
  [ "$old" = "$snapshot_id" ] || rm -rf "$dr_root/snapshots/$old"
done
printf 'verified snapshot %s (database=%s bytes, assets=%s bytes)\n' "$snapshot_id" "$db_bytes" "$asset_bytes"
