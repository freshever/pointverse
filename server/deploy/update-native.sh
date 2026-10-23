#!/usr/bin/env bash
set -euo pipefail
cd /home/alex/pointverse/server
export PATH=/usr/local/go/bin:$PATH
export GOMAXPROCS=1
install -d /home/alex/pointverse/bin
go build -p 1 -trimpath -ldflags='-s -w' -o /home/alex/pointverse/bin/server.next ./cmd/server
go build -p 1 -trimpath -ldflags='-s -w' -o /home/alex/pointverse/bin/migrate.next ./cmd/migrate
set -a
. ./app.env
set +a
/home/alex/pointverse/bin/migrate.next
mv /home/alex/pointverse/bin/server.next /home/alex/pointverse/bin/server
mv /home/alex/pointverse/bin/migrate.next /home/alex/pointverse/bin/migrate
sudo systemctl restart pointverse
for attempt in $(seq 1 30); do
  if curl --fail --silent http://127.0.0.1:8081/readyz; then exit 0; fi
  sleep 1
done
sudo journalctl -u pointverse -n 30 --no-pager
exit 1
