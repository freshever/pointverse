#!/bin/zsh
# Prepare/verify a staged copy. This does not stop or reroute the public server.
set -euo pipefail
support="$HOME/Library/Application Support/PointVerse"
pg=/opt/homebrew/opt/postgresql@17/bin
[[ -x "$pg/initdb" && -x "$support/server" && -f "$support/backups/pointverse.dump" ]]
install -d -m 700 "$support/data" "$support/data/cloud"
if [[ ! -f "$support/database-password" ]]; then
  umask 077
  /usr/bin/openssl rand -hex 32 > "$support/database-password"
fi
if [[ ! -f "$support/data/postgres/PG_VERSION" ]]; then
  "$pg/initdb" -D "$support/data/postgres" -U alex --auth-local=trust --auth-host=scram-sha-256 \
    --pwfile="$support/database-password" --encoding=UTF8 --locale=C
fi
set -a
source "$support/backups/app.env"
set +a
python3 "${0:A:h}/configure-native.py"
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/org.dianjie.database.plist"
for attempt in {1..30}; do
  if "$pg/pg_isready" -h 127.0.0.1 -p 15432 >/dev/null; then break; fi
  sleep 1
done
"$pg/createdb" -p 15432 -U alex pointverse
"$pg/pg_restore" -p 15432 -U alex -d pointverse --no-owner --no-privileges --exit-on-error "$support/backups/pointverse.dump"
tar -xzf "$support/backups/cloud.tgz" -C "$support/data"
chmod 700 "$support/server"
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/org.dianjie.server.plist"
echo "Staged Mac services started. Verify counts and health before final sync/cutover."
