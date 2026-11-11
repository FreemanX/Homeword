#!/bin/sh
# Build the engine next to this script: predictd (the model host) and ghostd (the policies and their HTTP server, ghost/*.swift).
# The first launch of a fresh binary is slow (macOS verifies it), so burn it here.
set -e
cd "$(dirname "$0")"
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/predictd-modcache"
swiftc -O -parse-as-library predictd.swift -o predictd
swiftc -O ghost/*.swift -o ghostd
./predictd --version
./ghostd --selftest </dev/null
