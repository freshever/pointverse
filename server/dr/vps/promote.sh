#!/bin/sh
set -eu

expected_snapshot=${1:-}
confirmation=${2:-}
dr_root=/home/alex/dr/pointverse
config_root=/home/alex/pointverse/server
caddy_file="$config_root/Caddyfile.native"
infra_compose="$config_root/compose.infrastructure.yaml"
latest=$(basename "$(readlink "$dr_root/latest-verified")")

[ "$expected_snapshot" = "$latest" ] || { echo "expected snapshot must equal latest verified snapshot: $latest" >&2; exit 64; }
[ "$confirmation" = "PROMOTE_POINTVERSE_VPS" ] || { echo "explicit promotion confirmation missing" >&2; exit 64; }
[ ! -f "$dr_root/PROMOTED" ] || { echo "VPS is already promoted" >&2; exit 73; }

stamp=$(date -u +%Y%m%dT%H%M%SZ)
backup_dir="$dr_root/caddy-backups"
backup="$backup_dir/Caddyfile.native.$stamp"
candidate="$backup_dir/Caddyfile.native.candidate.$stamp"
mkdir -p "$backup_dir"
chmod 700 "$backup_dir"
cp "$caddy_file" "$backup"
count=$(grep -c 'reverse_proxy 100\.89\.246\.35:8081' "$caddy_file" || true)
[ "$count" -gt 0 ] || { echo "Mac mini upstream not found; refusing promotion" >&2; exit 65; }
sed 's#reverse_proxy 100\.89\.246\.35:8081#reverse_proxy 127.0.0.1:18081#g' "$caddy_file" > "$candidate"

rollback() {
  cp "$backup" "$caddy_file"
  cd "$config_root"
  docker compose -f "$infra_compose" exec -T caddy caddy reload --config /etc/caddy/Caddyfile >/dev/null 2>&1 || true
  cd "$dr_root/config"
  docker compose --profile failover stop api >/dev/null 2>&1 || true
  rm -f "$dr_root/PROMOTED"
}
trap rollback EXIT HUP INT TERM

printf 'snapshot=%s\npromoted_at=%s\n' "$latest" "$stamp" > "$dr_root/PROMOTED.next"
mv "$dr_root/PROMOTED.next" "$dr_root/PROMOTED"
cd "$dr_root/config"
docker compose --profile failover up -d --wait api
curl -fsS http://127.0.0.1:18081/readyz >/dev/null
mv "$candidate" "$caddy_file"
cd "$config_root"
if ! docker compose -f "$infra_compose" exec -T caddy caddy validate --config /etc/caddy/Caddyfile; then
  rollback
  exit 70
fi
if ! docker compose -f "$infra_compose" exec -T caddy caddy reload --config /etc/caddy/Caddyfile; then
  rollback
  exit 70
fi
trap - EXIT HUP INT TERM
printf 'PointVerse promoted to VPS snapshot %s at %s\n' "$latest" "$stamp"
