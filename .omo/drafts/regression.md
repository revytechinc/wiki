# Draft: Wikijs port regression test plan

## User's goal
Full end-to-end regression test for `www/wikijs` FreeBSD port:
1. Build (clean, then `make package` once with all 3 OPTIONS enabled)
2. Install (`sudo pkg add` the resulting .pkg)
3. Start the service, record the PID
4. Verify service is actually running (pidfile + ps + sockstat + HTTP 200)
5. Stop the service
6. Verify service is actually stopped (ps grep returns nothing, sockstat shows nothing on :3000)
7. Repeat steps 3-6 for each of: **SQLITE, MARIADB, PGSQL**
8. Also at build time, verify the OPTIONS selection produced the right RUN_DEPENDS

## User-confirmed decisions
- **DB test strategy**: Hybrid -- one build with OPTIONS=all (SQLITE+PGSQL+MARIADB), then 3 runtime rounds where we edit `/usr/local/etc/wikijs/config.yml` per datastore and exercise start/stop.
- **DB servers**: Yes, install + bootstrap both `mariadb-server` and `postgresql-server` on wikijs.cloudbsd.org, create `wikijs` DB user + `wikijs` DB per engine.
- **Evidence scope**: Full evidence per iteration -- pidfile, ps auxww, sockstat, curl HTTP code, log tail -- saved to `.omo/evidence/regression/{sqlite|mariadb|postgres}/`.
- **Script location**: Canonical copy under `contrib/freebsd-port/scripts/regression.{sh,md}` so it ships with the port. Ephemeral copy also deployed to `/tmp/regression.sh` on host for fast iteration.

## Technical decisions
- Use a single package built with `OPTIONS_SET+=SQLITE PGSQL MARIADB`. Build skips the per-DB `_RUN_DEPENDS` since all three are pulled in; that's still a valid package because `_RUN_DEPENDS` only fires when the option is selected (we'll select all 3 explicitly).
- For each datastore round:
  - **Before**: stop service, blow away `/var/db/wikijs/data/*` so SQLITE seed re-runs
  - Switch `db.type` in config.yml (SQLITE / postgres / mariadb)
  - For postgres/mariadb: also write `db.host`, `db.port`, `db.user`, `db.pass`, `db.storage` (where applicable)
  - Run `service wikijs start`, wait 8s for setup-mode to bind
  - Capture pid from `/var/run/wikijs/wikijs.pid`
  - `ps auxww -p $pid` -- should show `node server`
  - `sockstat -l -p 3000` -- should show node listening
  - `curl -sS -w '%{http_code}' http://127.0.0.1:3000/` -- should be 200 or 302
  - `service wikijs stop`
  - Wait 5s for graceful shutdown
  - `ps auxww | grep 'node server' | grep -v grep` -- should be empty
  - `sockstat -l -p 3000` -- should be empty
  - `cat /var/log/wikijs/wikijs.log | tail -40`
- For PGSQL/MARIADB, the start may take 15-20s (DB connect + migration). Need a polling loop on `curl` with 30s timeout.

## Open questions to verify in plan
- Does Wiki.js actually start in setup mode when DB is unreachable, or fail-fast? Need a check in the script.
- Does the port actually build with OPTIONS=all (i.e., can all 3 RUN_DEPENDS resolve simultaneously)? We had a previous bug where `${PGSQL_DEFAULT}` was empty. Need to verify build accepts it.
- Do we want to also smoke-test the SQL engine actually creates tables? For an MVP regression, HTTP 200 is enough.

## Scope boundaries
- IN: build, install, 3 datastore start/stop rounds with evidence
- OUT: full setup wizard completion (would require browser automation); load/perf tests; upgrade path; backup/restore
- DEFER: data import/export via Wiki.js API; concurrent user simulation

## Risks
- MariaDB and PostgreSQL servers may not be in default ports tree on this host. Need `pkg install mariadb-server postgresql-server`. ~200MB extra disk.
- PGSQL DEFAULT_VERSIONS may not be set in make.conf. The port still builds, but the resolved path is `postgresql${PGSQL_DEFAULT}-client` which becomes `postgresql-client`. Earlier build errored on this. Will retry.
- The plan is structurally simple, so Metis review should be light.

## Next steps
1. Write plan to `.omo/plans/wikijs-regression.md`
2. Run Metis consultation
3. Run Oracle phase 1
4. Present plan + ask start-work vs high-accuracy
5. Once approved, invoke `/start-work` to execute
