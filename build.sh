#!/bin/sh
# Build predictd next to this script. The first launch of a fresh binary is slow (macOS verifies it), so burn it here.
set -e
cd "$(dirname "$0")"
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/predictd-modcache"
swiftc -O -parse-as-library predictd.swift -o predictd
./predictd --version
