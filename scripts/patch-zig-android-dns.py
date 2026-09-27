#!/usr/bin/env python3
"""Patch Zig 0.16's threaded resolver for Android/Bionic builds.

Zig 0.16 treats every Linux target alike in std.Io.Threaded.netLookupFallible,
so Android takes the native Linux DNS path that reads /etc/hosts and
/etc/resolv.conf directly. Android DNS is provided through Bionic/netd instead.
For Android targets we skip that Linux-only path and fall through to Zig's
existing libc getaddrinfo implementation.
"""

from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit("usage: patch-zig-android-dns.py <Threaded.zig>")

path = Path(sys.argv[1])
source = path.read_text()

old = """    if (native_os == .linux) {
        if (options.family != .ip4) {
"""
new = """    // Android does not use the normal Linux /etc/resolv.conf resolver path.
    // Let Android/Bionic fall through to the libc getaddrinfo implementation
    // below so DNS goes through Android's netd-backed resolver.
    if (native_os == .linux and builtin.target.abi != .android) {
        if (options.family != .ip4) {
"""

if new in source:
    print(f"{path}: Android DNS patch already applied")
    raise SystemExit(0)

count = source.count(old)
if count != 1:
    raise SystemExit(
        f"{path}: expected exactly one Zig 0.16 Linux resolver marker, found {count}"
    )

source = source.replace(old, new, 1)
path.write_text(source)
print(f"{path}: patched Android DNS to use Bionic getaddrinfo")
