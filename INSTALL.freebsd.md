# Installing Wiki.js on FreeBSD

This document describes how to install and run Wiki.js on FreeBSD
(13+/14+/15+/16.0-CURRENT, amd64). The instructions have been validated
on **FreeBSD 16.0-CURRENT (amd64) with Node 24.18.0 and npm 11.17.0**.

> If you only want a one-shot install, run:
>
> ```sh
> sudo pkg install -y node24 npm-node24 python311 sqlite3 gmake git
> git clone https://github.com/Requarks/wiki.git
> cd wiki && cp config.sample.yml config.yml
> ./scripts/install-freebsd.sh dev    # or `production`
> npm run build                         # dev mode only
> ./scripts/start-freebsd.sh
> ```
>
> Then browse to `http://localhost:3000/`.

---

## Why FreeBSD needs special handling

Wiki.js works on FreeBSD out of the box for the most part, but a few
upstream components assume a Linux/Windows/macOS environment. The known
issues are listed below, along with the workaround each requires.

### 1. node-gyp ↔ Python 3.12 (showstopper)

Wiki.js pins `sqlite3@5.1.7`, `ssh2@1.11.0`, and a handful of other
native modules that pull in **node-gyp 8.4.1**. That version imports
`distutils`, which was **removed in Python 3.12**. The default
`python3` on a fresh FreeBSD box is 3.12, so `npm install` fails with:

```
ModuleNotFoundError: No module named 'distutils'
```

**Workaround:** Install `python311` and point node-gyp at it.

```sh
sudo pkg install -y python311
export PYTHON=/usr/local/bin/python3.11
```

`scripts/install-freebsd.sh` does this automatically.

### 2. npm 11 + Apollo Server peer-deps (showstopper)

Wiki.js declares `graphql-subscriptions@1.1.0`, which has a peer
dependency on `graphql@^0.10 || ^0.11 || ^0.12 || ^0.13 || ^14`.
The project pins `graphql@15.3.0` via `resolutions`, but **npm 11+
enforces strict peer resolution and rejects the conflict** even though
it would resolve correctly through the resolutions field.

**Workaround:** `.npmrc` now ships with `legacy-peer-deps = true`, which
restores the pre-npm-7 behaviour. This is harmless on Linux/macOS/Windows
too — Yarn is unaffected either way.

### 3. Cypress postinstall (showstopper)

`cypress` is in `devDependencies` and its postinstall script bails out
with `Platform: "freebsd" is not supported.`. Cypress is only used for
E2E testing — it is **never needed to run the app**.

**Workaround:** `scripts/install-freebsd.sh` runs `npm install
--ignore-scripts`, then re-runs the specific postinstall scripts that
Wiki.js actually needs (`patch-package`, `node-gyp rebuild` for sqlite3,
`node-gyp-build` for bufferutil/utf-8-validate).

To run Cypress-based E2E tests on FreeBSD you would need to either
patch Cypress to support FreeBSD (upstream work) or run the tests in a
Linux VM/jail.

### 4. npm 11 sometimes drops the executable bit

On FreeBSD, npm 11 occasionally installs files inside `node_modules/.bin/`
with mode `644` instead of `755`, so `npm run build` fails with
`sh: cross-env: Permission denied`. `scripts/install-freebsd.sh`
restores the bit on `node_modules/.bin/*` after install.

### 5. OpenSSL legacy provider

Wiki.js's webpack 4 toolchain and some legacy crypto code in older
dependencies still call into the OpenSSL "legacy" provider. Node 17+
hides this provider by default. The standard workaround is:

```sh
export NODE_OPTIONS=--openssl-legacy-provider
```

`scripts/start-freebsd.sh` sets this automatically.

---

## Full step-by-step

### 1. System packages

```sh
sudo pkg install -y node24 npm-node24 python311 sqlite3 gmake git
```

Versions available at the time of writing on `pkg`:

- `node24-24.18.0`, `npm-node24-11.17.0`
- `python311-3.11.15`
- `sqlite3-3.53.1`
- `gmake` (FreeBSD's GNU make — required by some node-gyp builds)

### 2. Clone and configure

```sh
git clone https://github.com/Requarks/wiki.git
cd wiki
cp config.sample.yml config.yml
$EDITOR config.yml      # set db.type, ports, etc.
```

The shipped `config.sample.yml` defaults to PostgreSQL. For a quick
FreeBSD smoke test, switch to SQLite:

```yaml
db:
  type: sqlite
  storage: /var/db/wiki/wiki.sqlite
```

### 3. Install dependencies

```sh
./scripts/install-freebsd.sh dev     # development install (build client too)
# or
./scripts/install-freebsd.sh production
```

The script will:
- verify pkg packages
- set `PYTHON=python3.11` for node-gyp
- run `npm install` with `--legacy-peer-deps --ignore-scripts`
- re-run `patch-package`
- rebuild native modules (`sqlite3`, `bufferutil`, `utf-8-validate`, `ssh2`)
- restore executable bits on bin scripts

### 4. Build the client (development installs only)

```sh
npm run build
```

Production installs already include the built client under `assets/`.

### 5. Start the server

```sh
./scripts/start-freebsd.sh
```

Browse to `http://YOUR-SERVER-IP:3000/` and complete the setup wizard.

---

## Running as a service (optional)

The `dev/installer/main.go` program (a small Go helper) can produce a
systemd-style unit for Linux, but FreeBSD uses `rc.d`. A minimal
`/usr/local/etc/rc.d/wiki` looks like:

```sh
#!/bin/sh
# PROVIDE: wiki
# REQUIRE: NETWORKING
# KEYWORD: shutdown

. /etc/rc.subr

name="wiki"
rcvar="${name}_enable"
wiki_command="/usr/local/bin/node server"
wiki_chdir="/usr/local/www/wiki"
wiki_user="www"

start_cmd="${name}_start"

wiki_start() {
    su -m "${wiki_user}" -c "\
        export NODE_OPTIONS=--openssl-legacy-provider && \
        export TMPDIR=/tmp && \
        cd '${wiki_chdir}' && \
        ${wiki_command} >> /var/log/wiki.log 2>&1 &"
}

load_rc_config $name
run_rc_command "$1"
```

Make it executable (`chmod +x`) and add `wiki_enable=YES` to
`/etc/rc.conf`.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `ModuleNotFoundError: No module named 'distutils'` | node-gyp 8.4.1 with Python 3.12 | `pkg install python311` and set `PYTHON=/usr/local/bin/python3.11` |
| `npm error ERESOLVE unable to resolve dependency tree` | npm 11 strict peer-dep | Already fixed in `.npmrc` via `legacy-peer-deps = true` |
| `Platform: "freebsd" is not supported.` | Cypress postinstall | Use `scripts/install-freebsd.sh` (skips Cypress) |
| `sh: cross-env: Permission denied` | npm 11 dropped exec bit | `chmod +x node_modules/.bin/cross-env` (script does this) |
| Server starts, then `ENOENT ... favicon.ico` | `npm run build` not run | Run `npm run build` (only for dev installs) |
| `ERR_OSSL_EVP_UNSUPPORTED` | Node 17+ hides legacy crypto | `export NODE_OPTIONS=--openssl-legacy-provider` (start script does this) |

---

## Verified environment

| Component | Version |
|---|---|
| FreeBSD | 16.0-CURRENT (main-n287194-fe6677e7f440) GENERIC amd64 |
| node | v24.18.0 |
| npm | 11.17.0 |
| python | 3.11.15 (for node-gyp) |
| sqlite | 3.53.1 |
| clang | 21.1.8 |
| Wiki.js | 2.0.0 |

End-to-end smoke test result:

```
HTTP 200  GET /
HTTP 200  GET /setup
HTTP 200  GET /_assets/favicon.ico  (15086 bytes)
HTTP 200  GET /.well-known/assetlinks.json
```

Setup wizard rendered, SQLite migrations ran successfully, server
stopped cleanly on SIGTERM.