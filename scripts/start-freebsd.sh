#!/bin/sh
# start-freebsd.sh — Start Wiki.js with FreeBSD-compatible defaults.
#
# Sets NODE_OPTIONS=--openssl-legacy-provider (required by webpack 4 /
# older native crypto code in dependencies), ensures TMPDIR is writable,
# and exec's `node server`.
#
# Usage: ./scripts/start-freebsd.sh

set -eu

log() { printf '\033[1;32m[freebsd-start]\033[0m %s\n' "$*"; }

[ "$(uname -s)" = "FreeBSD" ] || { printf '\033[1;31m[freebsd-start]\033[0m FreeBSD only.\n' >&2; exit 1; }

# node-gyp, sqlite3 and friends need a writable TMPDIR.
# On FreeBSD /tmp is the in-memory tmpfs and is always writable; export
# it explicitly so that child npm/postinstall scripts behave.
export TMPDIR="${TMPDIR:-/tmp}"

# webpack 4 (used by `npm run build`) and some legacy crypto paths in
# dependencies still rely on the deprecated OpenSSL provider API. Node
# 17+ hides the legacy provider by default; this flag re-enables it.
export NODE_OPTIONS="${NODE_OPTIONS:-} --openssl-legacy-provider"

log "TMPDIR=$TMPDIR  NODE_OPTIONS=$NODE_OPTIONS"
log "Starting: node server"
exec node server