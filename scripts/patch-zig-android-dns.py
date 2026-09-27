#!/usr/bin/env python3
"""Patch Zig 0.16's threaded resolver for Android/Bionic builds.

Zig 0.16 treats Android as generic Linux in std.Io.Threaded.netLookupFallible,
so Android takes the native Linux DNS path instead of Bionic/netd. For Android
targets we skip that Linux-only path and fall through to Zig's existing libc
getaddrinfo implementation.
"""

from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit("usage: patch-zig-android-dns.py <Threaded.zig>")

path = Path(sys.argv[1])
source = path.read_text()

fn_marker = "fn netLookupFallible("
fn_start = source.find(fn_marker)
if fn_start < 0:
    raise SystemExit(f"{path}: netLookupFallible not found")

next_fn = source.find("\nfn ", fn_start + len(fn_marker))
if next_fn < 0:
    next_fn = len(source)

section = source[fn_start:next_fn]
old = "if (native_os == .linux) {"
new = "if (native_os == .linux and builtin.target.abi != .android) {"

if new in section:
    print(f"{path}: Android DNS patch already applied")
    raise SystemExit(0)

count = section.count(old)
if count != 1:
    preview = "\n".join(
        line for line in section.splitlines()
        if "native_os" in line or "lookup" in line.lower() or "getaddrinfo" in line
    )
    raise SystemExit(
        f"{path}: expected one Linux resolver branch in netLookupFallible, "
        f"found {count}\nRelevant lines:\n{preview}"
    )

patched_section = section.replace(old, new, 1)
source = source[:fn_start] + patched_section + source[next_fn:]
path.write_text(source)
print(f"{path}: patched Android DNS to use Bionic getaddrinfo")
