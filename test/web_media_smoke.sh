#!/usr/bin/env bash
set -euo pipefail

tmp=$(mktemp -d)
port=49322
base="http://127.0.0.1:${port}"
api="$base/api/v1"
export HOME="$tmp/home"
export DEEZ_STORAGE=sqlite
export DEEZ_DB="$tmp/deez.db"
mkdir -p "$HOME"

cleanup() {
  if [[ -n "${server_pid:-}" ]]; then
    kill "$server_pid" >/dev/null 2>&1 || true
    wait "$server_pid" >/dev/null 2>&1 || true
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT

on_error() {
  status=$?
  line=${BASH_LINENO[0]:-unknown}
  echo "Deez Web media smoke failed at line $line (status $status)" >&2
  if [[ -f "$tmp/media-headers.txt" ]]; then
    echo '--- media response headers ---' >&2
    cat "$tmp/media-headers.txt" >&2
  fi
  if [[ -f "$tmp/web.log" ]]; then
    echo '--- deez web log ---' >&2
    cat "$tmp/web.log" >&2
  fi
  exit "$status"
}
trap on_error ERR

python3 - "$tmp/pixel.png" <<'PY'
import base64, sys
# A valid 1x1 transparent PNG.
raw = base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=')
with open(sys.argv[1], 'wb') as f:
    f.write(raw)
PY

media_ref=$(./zig-out/bin/deez media add "$tmp/pixel.png" | head -n 1)
echo "$media_ref" | grep -Eq '^deez-media://sha256:[0-9a-f]{64}$'
media_hash=${media_ref#deez-media://sha256:}
media_path="$HOME/.local/share/deez/media/sha256/${media_hash:0:2}/$media_hash"
test -f "$media_path"

./zig-out/bin/deez web --port "$port" --no-open >"$tmp/web.log" 2>&1 &
server_pid=$!

ready=0
for _ in $(seq 1 50); do
  if curl -fsS "$api/health" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 0.1
done
if [[ "$ready" != 1 ]]; then
  cat "$tmp/web.log" >&2
  exit 1
fi

curl -fsS -D "$tmp/media-headers.txt" "$api/media/$media_hash" -o "$tmp/served.png"
cmp "$tmp/pixel.png" "$tmp/served.png"
grep -qi '^content-type: image/png' "$tmp/media-headers.txt"
grep -qi '^cache-control: public, max-age=31536000, immutable' "$tmp/media-headers.txt"
grep -qi '^x-content-type-options: nosniff' "$tmp/media-headers.txt"
grep -qi '^cross-origin-resource-policy: same-origin' "$tmp/media-headers.txt"
grep -qi "^content-security-policy: sandbox; default-src 'none'" "$tmp/media-headers.txt"
grep -qi "^etag: \"$media_hash\"" "$tmp/media-headers.txt"

not_modified_code=$(curl -sS -o "$tmp/not-modified.txt" -w '%{http_code}' \
  -H "If-None-Match: \"$media_hash\"" "$api/media/$media_hash")
test "$not_modified_code" = "304"

invalid_code=$(curl -sS -o "$tmp/invalid.json" -w '%{http_code}' "$api/media/abc")
test "$invalid_code" = "400"
python3 - "$tmp/invalid.json" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    body = json.load(f)
assert body['error']['code'] == 'invalid_media_hash', body
PY

uppercase_hash=$(printf 'A%.0s' $(seq 1 64))
uppercase_code=$(curl -sS -o "$tmp/uppercase.json" -w '%{http_code}' "$api/media/$uppercase_hash")
test "$uppercase_code" = "400"

missing_hash=$(printf '0%.0s' $(seq 1 64))
missing_code=$(curl -sS -o "$tmp/missing.json" -w '%{http_code}' "$api/media/$missing_hash")
test "$missing_code" = "404"
python3 - "$tmp/missing.json" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    body = json.load(f)
assert body['error']['code'] == 'media_not_found', body
PY

forbidden_code=$(curl -sS -o "$tmp/forbidden.json" -w '%{http_code}' \
  -H 'Origin: https://example.com' "$api/media/$media_hash")
test "$forbidden_code" = "403"

# Content-addressed reads must fail closed if the on-disk blob is modified.
python3 - "$media_path" <<'PY'
import sys
path = sys.argv[1]
with open(path, 'rb') as f:
    data = bytearray(f.read())
data[0] ^= 0xff
with open(path, 'wb') as f:
    f.write(data)
PY

tampered_code=$(curl -sS -o "$tmp/tampered.json" -w '%{http_code}' "$api/media/$media_hash")
test "$tampered_code" = "500"
python3 - "$tmp/tampered.json" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    body = json.load(f)
assert body['error']['code'] == 'internal_error', body
PY

echo "Deez Web media smoke passed"
