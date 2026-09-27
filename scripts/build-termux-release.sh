#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

SQLITE_VERSION="3.53.4"
SQLITE_CODE="3530400"
SQLITE_YEAR="2026"
SQLITE3_SHA3="67f423e9ebbbdc473cbc4772c872ee6b89f31fde4ed0279a5c25d5f65c043a16"
ANDROID_API_LEVEL="${ANDROID_API_LEVEL:-24}"
ANDROID_NDK_ROOT="${ANDROID_NDK_ROOT:-${ANDROID_NDK_HOME:-}}"
WORK_DIR=".termux-build"
SQLITE_DIR="$WORK_DIR/sqlite-amalgamation-$SQLITE_CODE"
LIBC_FILE="$WORK_DIR/android-libc-aarch64.txt"

if [[ -z "$ANDROID_NDK_ROOT" ]]; then
  echo "ANDROID_NDK_ROOT or ANDROID_NDK_HOME must point at an Android NDK" >&2
  exit 1
fi

SYSROOT="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/sysroot"
if [[ ! -d "$SYSROOT" ]]; then
  echo "Android NDK sysroot not found: $SYSROOT" >&2
  exit 1
fi

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

cat > "$LIBC_FILE" <<EOF
include_dir=$SYSROOT/usr/include/aarch64-linux-android
sys_include_dir=$SYSROOT/usr/include
crt_dir=$SYSROOT/usr/lib/aarch64-linux-android/$ANDROID_API_LEVEL
msvc_lib_dir=
kernel32_lib_dir=
gcc_dir=
EOF

zig build \
  -Dtarget="aarch64-linux-android.$ANDROID_API_LEVEL" \
  -Doptimize=ReleaseFast \
  -Dbundled-sqlite="$SQLITE_DIR" \
  --libc "$LIBC_FILE"

file zig-out/bin/deez

elf_type="$(readelf -h zig-out/bin/deez | awk '/Type:/{print $2}')"
if [[ "$elf_type" != "DYN" ]]; then
  echo "Termux release must be PIE/ET_DYN; got ELF type: $elf_type" >&2
  readelf -h zig-out/bin/deez >&2
  exit 1
fi

if ! readelf -l zig-out/bin/deez | grep -q '/system/bin/linker64'; then
  echo "Termux release must use Android's /system/bin/linker64" >&2
  readelf -l zig-out/bin/deez >&2
  exit 1
fi

if ! readelf -d zig-out/bin/deez | grep -q 'Shared library: \[libc.so\]'; then
  echo "Termux release must link Android/Bionic libc dynamically" >&2
  readelf -d zig-out/bin/deez >&2
  exit 1
fi
