#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

SQLITE_VERSION="3.53.4"
SQLITE_CODE="3530400"
SQLITE_YEAR="2026"
SQLITE3_SHA3="67f423e9ebbbdc473cbc4772c872ee6b89f31fde4ed0279a5c25d5f65c043a16"
WORK_DIR=".termux-build"
SQLITE_DIR="$WORK_DIR/sqlite-amalgamation-$SQLITE_CODE"

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

curl -fsSL \
  "https://www.sqlite.org/$SQLITE_YEAR/sqlite-amalgamation-$SQLITE_CODE.zip" \
  -o "$WORK_DIR/sqlite.zip"
unzip -q "$WORK_DIR/sqlite.zip" -d "$WORK_DIR"

test -f "$SQLITE_DIR/sqlite3.c"
test -f "$SQLITE_DIR/sqlite3.h"

actual_sha3="$(openssl dgst -sha3-256 "$SQLITE_DIR/sqlite3.c" | awk '{print $2}')"
if [[ "$actual_sha3" != "$SQLITE3_SHA3" ]]; then
  echo "sqlite3.c SHA3-256 mismatch for SQLite $SQLITE_VERSION" >&2
  echo "expected: $SQLITE3_SHA3" >&2
  echo "actual:   $actual_sha3" >&2
  exit 1
fi

zig build \
  -Dtarget=aarch64-linux-musl \
  -Doptimize=ReleaseFast \
  -Dbundled-sqlite="$SQLITE_DIR"

file zig-out/bin/deez

if readelf -l zig-out/bin/deez | grep -q 'Requesting program interpreter'; then
  echo "Termux release must be statically linked; dynamic interpreter found" >&2
  readelf -l zig-out/bin/deez >&2
  exit 1
fi
