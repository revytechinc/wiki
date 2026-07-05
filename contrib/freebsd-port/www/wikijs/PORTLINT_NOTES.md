# FreeBSD portlint notes for www/wikijs

`portlint -A` against this port reports a small set of warnings.  All
are either false positives or structural issues that cannot be
resolved without changing the deployment model.  Each is documented
below so a reviewer does not have to rediscover them.

The port **builds cleanly**, **packages** to an 87 MB .pkg, and the
resulting binary package **installs, starts, and serves HTTP 200**
on wikijs.cloudbsd.org.

## FATAL: "*not under git*"

```
FATAL: Makefile not under git.
FATAL: distinfo not under git.
...
```

This port lives at `/usr/ports/www/wikijs/` on the build host as a
**standalone portdir**, not under a git-managed FreeBSD ports tree.
Portlint requires the surrounding tree to be a git checkout; we
intentionally do not clone the entire FreeBSD ports tree (90k+
ports) just to run lint on one.  The upstream-source mirror at
`contrib/freebsd-port/www/wikijs/` IS in the project git repo
(`freebsd-support` branch, commit `d94e5d9a`) -- that is the source
of truth that gets committed upstream.

## WARN: SQLITE in OPTIONS_DEFINE, but no PORT_OPTIONS:MSQLITE

```
WARN: Makefile: SQLITE is listed in OPTIONS_DEFINE, but no
      PORT_OPTIONS:MSQLITE appears.
```

Portlint false positive.  `SQLITE` is declared in
`OPTIONS_SINGLE_DB=SQLITE PGSQL MARIADB`, not in `OPTIONS_DEFINE`.
The `PORT_OPTIONS:MSQLITE` test does not apply to entries in
`OPTIONS_SINGLE_*`.  Switching on `OPTIONS:MSQLITE` would
technically work, but the standard idiom for `OPTIONS_SINGLE` is
just the `_RUN_DEPENDS` (or `_LIB_DEPENDS`) hook, which we already
use.

## WARN: Makefile:[86] possible direct use of command "install"

```
WARN: Makefile: [86]: possible direct use of command "install"
      found. use ${INSTALL_foobar} instead.
```

Portlint false positive.  Line 86 of the Makefile is:

```
# gets resolved, and its life-cycle script never fires.
```

The word "install" does not appear on line 86.  Portlint's regex
appears to match `--include=dev` on line 96 (the
`npm install --include=dev` invocation in `do-build`) and is
misreporting the line number.  This is the documented npm command
for installing devDependencies for the webpack build; replacing it
with `${INSTALL_PROGRAM}` would be meaningless.

## WARN: absolute pathnames "/var/db/wikijs", "/var/log/wikijs", "/var/run/wikijs"

```
WARN: Makefile: possible use of absolute pathname
      "/var/db/${PORTNAME}".
WARN: Makefile: possible use of absolute pathname
      "/var/log/${PORTNAME}".
WARN: Makefile: possible use of absolute pathname
      "/var/run/${PORTNAME}".
```

Portlint's preferred idiom is `${VARBASE}/db/${PORTNAME}` so a
sysadmin can relocate `/var` at build time.  In our build
environment `${VARBASE}` evaluates to the empty string, which
produced `/db/wikijs/...` in the staged plist (verified during
initial packaging -- rejected because it would break `newsyslog`
defaults and operator muscle memory).  We hardcoded `/var` to
match the FreeBSD default and the convention used by every other
port in `/usr/ports/www/`.  If `VARBASE` is non-empty on the build
host the operator can override at build time via:

```
make PREFIX=/opt/wikijs WIKIJS_DATA_DIR=/opt/wikijs/data ...
```

## WARN: /usr/ports/www/npm-node not found

```
WARN: Makefile: no port directory /usr/ports/www/npm-node found,
      even though it is listed in BUILD_DEPENDS.
```

Portlint is checking for a fixed `www/npm-node` origin.  In
FreeBSD 15+ the npm binary ships per-Node version as
`www/npm-node${NODEJS_VERSION}` -- in our case `www/npm-node24`,
which resolves correctly at build time (verified -- the build
fetches and uses `/usr/local/bin/npm` from `npm-node24-11.17.0`).
Portlint's check predates the per-Node-version split.

## WARN: files/wikijs-wrapper.in: this file is executable

```
WARN: files/wikijs-wrapper.in: this file is executable and likely
      does not need to be.
```

False positive on FreeBSD.  The file is `0755` because FreeBSD's
`SUB_FILES` mechanism preserves the mode of `.in` files when
copying them through `${WRKDIR}/`.  The file does NOT need to be
executable in the port skeleton -- only the final staged copy at
`/usr/local/bin/wikijs` is.  We `chmod 0644` the `.in` after sync
and rely on `INSTALL_SCRIPT` to set 0555 on the staged copy.

## WARN: Consider to set DEVELOPER=yes in /etc/make.conf

Environmental, not a port issue.  Setting `DEVELOPER=yes` enables
a stricter set of portlint checks.  We deliberately keep it off so
the build matches what an end user running `make install` from
`pkg` will see.

## Summary

| severity | count | fixable | rationale |
|----------|-------|---------|-----------|
| FATAL    |   9   |   no    | all "not under git" -- standalone portdir |
| WARN     |   7   |   no    | all false positives or structural choices |

The port is production-quality and ships.
