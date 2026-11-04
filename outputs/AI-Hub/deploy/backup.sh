#!/bin/sh
# Run as root. Database contents and encryption keys are private, including backups.
set -eu
umask 077
root=/var/backups/ai-hub/daily
install -d -m700 "$root"
stamp=$(date -u +%Y%m%dT%H%M%SZ)
stage="$root/.pending-$stamp"
install -d -m700 "$stage"
trap 'rm -rf -- "$stage"' EXIT HUP INT TERM
runuser -u postgres -- pg_dump -Fc ai_hub > "$stage/ai_hub.dump"
runuser -u postgres -- pg_dump -Fc ai_gateway > "$stage/ai_gateway.dump"
cp /etc/ai-hub/service.env "$stage/ai-hub.env"
cp /etc/ai-gateway/service.env "$stage/ai-gateway.env"
cp /etc/ai-gateway/config.yaml "$stage/gateway-config.yaml"
test -s "$stage/ai_hub.dump"
test -s "$stage/ai_gateway.dump"
mv "$stage" "$root/$stamp"
find "$root" -mindepth 1 -maxdepth 1 -type d -name '20*T*Z' -mtime +7 -exec rm -rf -- {} +
