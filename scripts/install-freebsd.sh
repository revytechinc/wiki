#!/bin/sh
# install-freebsd.sh — Install Wiki.js dependencies on FreeBSD.
#
# Usage:  ./scripts/install-freebsd.sh [production|dev]
#
# Targets FreeBSD 13+/14+/15+/16.0-CURRENT. Tested on
# FreeBSD 16.0-CURRENT (amd64) with Node 24 + npm 11.
#
# What this script does (and why):
#
#   1. Ensures `node`, `npm`, `python311`, `gmake`, and `sqlite3` are
#      installed via pkg. We pin Python 3.11 because the bundled
#      node-gyp 8.4.1 (transitively pulled in by sqlite3, ssh2, etc.)
#      imports `distutils`, which was removed from Python 3.12+.
#
#   2. Runs `npm install` with `--legacy-peer-deps --ignore-scripts`,
#      then manually re-runs the postinstall steps we actually need:
#        - patch-package (apply patches/*.patch to deps)
#        - node-gyp rebuild for native modules (sqlite3, bufferutil,
#          utf-8-validate, ssh2)
#      The `--ignore-scripts` flag avoids the Cypress installer, which
#      throws "Platform: freebsd is not supported" and aborts the
#      install on FreeBSD. Cypress is a devDependency used for E2E
#      tests only and is not required to run Wiki.js.
#
#   3. chmods CLI bin scripts that npm 11 occasionally installs
#      without the executable bit (FreeBSD-specific quirk).
#
# Reference: INSTALL.freebsd.md

set -eu

MODE="${1:-production}"
NODE_VERSION="${NODE_VERSION:-24}"
PKG_PYTHON_VERSION="${PKG_PYTHON_VERSION:-3.11}"

log() { printf '\033[1;34m[freebsd-install]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[freebsd-install]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[freebsd-install]\033[0m %s\n' "$*" >&2; exit 1; }

# -- Sanity: FreeBSD only --------------------------------------------------
[ "$(uname -s)" = "FreeBSD" ] || die "This script is FreeBSD-only (got: $(uname -s))."

# -- 1. System packages ---------------------------------------------------
log "Checking required pkg packages..."
PKGS_NEEDED="node${NODE_VERSION} npm-node${NODE_VERSION} python${PKG_PYTHON_VERSION} sqlite3 gmake"
PKGS_MISSING=""
for pkg in $PKGS_NEEDED; do
    if ! pkg info -e "$pkg" >/dev/null 2>&1; then
        PKGS_MISSING="$PKGS_MISSING $pkg"
    fi
done

if [ -n "$PKGS_MISSING$EXTRA_PKGS" ]; then
    log "Installing missing packages:$PKGS_MISSING$EXTRA_PKGS"
    sudo pkg install -y $PKGS_MISSING $EXTRA_PKGS
else
    log "All required packages already installed."
fi

# -- 2. Set Python 3.11 for node-gyp ---------------------------------------
# node-gyp 8.4.1 (pulled in by sqlite3 5.1.7) imports distutils.
export PYTHON="$(which python${PKG_PYTHON_VERSION})"
[ -x "$PYTHON" ] || die "Python $PKG_PYTHON_VERSION not found at $PYTHON"
log "node-gyp Python: $PYTHON ($($PYTHON --version))"

# -- 3. npm install --------------------------------------------------------
case "$MODE" in
    production) NPM_FLAGS="--omit=dev" ;;
    dev)        NPM_FLAGS="--include=dev" ;;
    *)          die "Unknown mode: $MODE (expected: production|dev)" ;;
esac

log "Running: npm install $NPM_FLAGS --legacy-peer-deps --ignore-scripts"
# shellcheck disable=SC2086
npm install $NPM_FLAGS --legacy-peer-deps --ignore-scripts --no-audit --no-fund

# -- 4. Re-run required postinstalls --------------------------------------
log "Applying patches via patch-package..."
npx --no-install patch-package

log "Rebuilding native modules via node-gyp / node-gyp-build..."
# sqlite3 (uses node-gyp directly)
if [ -f node_modules/sqlite3/binding.gyp ]; then
    (cd node_modules/sqlite3 && ../.bin/node-gyp rebuild || npx node-gyp rebuild) >/dev/null
fi

# bufferutil / utf-8-validate / ssh2 (use node-gyp-build or prebuild)
for native in bufferutil utf-8-validate; do
    if [ -d "node_modules/$native" ]; then
        (cd "node_modules/$native" && ../../.bin/node-gyp-build || true) >/dev/null 2>&1 || true
    fi
done

# ssh2 — pulls a small install.js for crypto bindings
if [ -d node_modules/ssh2 ]; then
    (cd node_modules/ssh2 && node install.js) >/dev/null 2>&1 || \
        warn "ssh2 install.js failed (non-fatal; SSH module will fall back to openssl)"
fi

# -- 5. Restore exec bit on bin scripts (npm 11 + FreeBSD quirk) -----------
log "Restoring executable bit on bin scripts..."
chmod -R u+x node_modules/.bin/ 2>/dev/null || true
find node_modules -type f -name "*.js" -path "*/bin/*" ! -perm -u+x -exec chmod u+x {} + 2>/dev/null || true

# -- 6. Done ---------------------------------------------------------------
log "Install complete (mode: $MODE)."
log "Next: copy config.sample.yml to config.yml, then run 'node server'."
log "See INSTALL.freebsd.md for full instructions."