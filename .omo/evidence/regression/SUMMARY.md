# Wiki.js FreeBSD Port Regression — Summary

**Plan:** `wikijs-regression`
**Plan path:** `.omo/plans/wikijs-regression.md`
**Host:** `wikijs.cloudbsd.org` (FreeBSD 16.0-CURRENT GENERIC amd64)
**Captured:** 2026-07-05
**Verdict:** **PARTIAL** — SQLITE running-state confirmed; stop-side and 2/3 datastore rounds blocked on host recovery

---

## Pass / Fail Matrix

| Datastore | Build | Install | Start | PID recorded | 4-way verify (ps+sockstat+curl+Playwright) | Stop | 2-way verify (ps+sockstat clean) | Overall |
|-----------|-------|---------|-------|--------------|--------------------------------------------|------|----------------------------------|---------|
| SQLITE    | PASS  | N/A (pre-installed) | N/A (pre-running) | PASS (PID 13143) | **PASS** (ps ✓, sockstat ✓, curl 200 ✓, Playwright title "Wiki.js Setup" ✓, PNG 559KB ✓) | **BLOCKED** | **BLOCKED** | **PARTIAL** |
| MARIADB   | PASS  | BLOCKED | BLOCKED | — | — | — | — | **BLOCKED** |
| POSTGRES  | PASS  | BLOCKED | BLOCKED | — | — | — | — | **BLOCKED** |

Legend: PASS = round goal achieved and verified; BLOCKED = cannot run due to host sudo/ldconfig regression; N/A = step not executed because the prior session already left the service in that state.

---

## What Was Done

### Wave 1 / Foundation

- **Task 1 — `pkg install mariadb114-server postgresql16-server`** — DONE. Packages installed on host (mariadb114-server-11.4.12, postgresql16-server-16.14). 7 transitive deps added (galera26, libfmt, llvm19, lua53, mariadb114-client, postgresql16-client, unixODBC). 2 auto-removed by solver (nginx-full-1.30.3, postgresql18-client-18.4). Evidence: `db-install.log` (10.8 KB), `db-install-verify.txt` (5.0 KB).
- **Task 2 — Bootstrap MariaDB** — BLOCKED. Cannot run `mariadb-install-db` or `service mysql-server start` without sudo.
- **Task 3 — Bootstrap PostgreSQL** — BLOCKED. Cannot run `initdb` or `service postgresql start` without sudo.
- **Task 4 — Build www/wikijs port** — DONE. `wikijs-2.5.314.pkg` built at 87,930,705 bytes (~83.86 MiB) in `/usr/ports/www/wikijs/work/pkg/`. SQLITE option=on (per `pkg-info.txt`). Workaround for host's broken ldconfig: `LD_LIBRARY_PATH=/usr/local/lib` in make's environment. Evidence: `build.log` (6.8 KB), `make-conf.txt` (254 B), `pkg-info.txt` (1.3 KB).

### Wave 2 / Rounds

- **Task 5 — Fresh install** — BLOCKED. Cannot run `pkg delete -y wikijs` or `pkg add <pkg>` without sudo.
- **Task 6 — SQLITE round** — PARTIAL. Pre-existing wikijs from the prior session is running (PID 13143, `db.type=sqlite` per `/usr/local/etc/wikijs/config.yml`, listening on tcp4 `*:3000`). 4-way verify signals all PASS. after-stop.txt absent because `service wikijs stop` requires sudo. Evidence: `sqlite/{before-start,pid,after-start}.txt` + `sqlite/playwright/{setup-wizard.png,body-snippet.txt,ok.txt}`.
- **Task 7 — MARIADB round** — BLOCKED. Requires sudo to write `config.yml` and start service, plus a running mariadb to point at.
- **Task 8 — POSTGRES round** — BLOCKED. Same reason.

### Final Verification Wave

- **F1 — Plan compliance audit** — PASS (after one fix pass). Original audit returned NO-GO; fixes applied to both `regression.sh` and `regression.md`; re-audit confirmed all gates pass.
- **F2 — Evidence completeness audit** — PARTIAL. See "Pass / Fail Matrix" above; SQLITE 6/7 files present and passing, MARIADB/POSTGRES 0/7.
- **F3 — shellcheck + bash -n on `regression.sh`** — PASS. `bash -n` exit 0; `shellcheck -S error` exit 0 (only 2 SC2329 info notes about helper-function invocation form, both false positives); 0 `eval`; 0 `rm -rf /`; `set -euo pipefail` present on line 2.
- **F4 — SUMMARY.md** — THIS FILE.

---

## Host Blocker (Recovery Required Out-of-Band)

`/usr/local/lib` on `wikijs.cloudbsd.org` is owned by `wikijs:wikijs` (uid 425), not `root:wheel`. Consequences:

1. `/sbin/ldconfig` silently excludes `/usr/local/lib` from `/var/run/ld-elf.so.hints` (the dynamic linker ignores directories not owned by root).
2. Every dynamically linked binary that needs a shared lib in `/usr/local/lib` fails to load: `mariadbd` (`libpcre2-8.so.0`), `postgres` (`libicudata.so.76`), `sudo` (`libintl.so.8`), `node`/`npm` (`libllhttp.so.9.4`), and friends.
3. Subagent Task 1 inadvertently ran `sudo ldconfig` while diagnosing the above, which re-generated `/var/run/ld-elf.so.hints` and dropped the cached entries for `libintl.so.8` that were previously keeping sudo loadable. Now `sudo` itself is broken.
4. No escalation path from `mlapointe` (not in `wheel`, no sudoers entry, no working `su`, no `doas`, root SSH disabled, `/etc/cron.d` and `/var/cron` not writable).

**Recovery (run as root via cloud serial console / KVM / IPMI):**

```sh
mount -uw /
chown -R root:wheel /usr/local/lib
/sbin/ldconfig -m /usr/local/lib
reboot
```

After reboot, verify:

```sh
ssh wikijs 'ldd /usr/local/libexec/mariadbd'      # no "not found"
ssh wikijs 'ldd /usr/local/bin/postgres'          # no "not found"
ssh wikijs 'sudo -n echo sudo-back'               # prints "sudo-back"
```

Full diagnosis: `.omo/notepads/wikijs-regression/learnings.md`.

---

## Deliverables (Committed in commit 49aeb5c4 on `origin/freebsd-support`)

- `contrib/freebsd-port/scripts/regression.sh` — 299-line bash driver (set -euo pipefail, no eval, no rm -rf /, parses `--datastore=<x>`, dispatches `round_sqlite`/`round_mariadb`/`round_postgres` with `write_config_block` + `start_wikijs_and_verify` + `stop_wikijs_and_verify`, exits 0/1/2/3 by signal)
- `contrib/freebsd-port/scripts/regression.md` — operator doc with single-OPTIONS build explanation, mariadb + postgresql bootstrap sections, DB roles preflight, evidence path, exit codes, troubleshooting, host-broken status
- `.omo/plans/wikijs-regression.md` — 12-task plan with Final Verification Wave (F1-F4)
- `.omo/evidence/regression/{build,db-install,db-install-verify,make-conf,pkg-info}.{log,txt}` — top-level evidence
- `.omo/evidence/regression/sqlite/{before-start.txt,pid.txt,after-start.txt}` + `.omo/evidence/regression/sqlite/playwright/{setup-wizard.png,body-snippet.txt,ok.txt}` — partial SQLITE round evidence
- `.omo/notepads/wikijs-regression/learnings.md` — cross-task findings, host diagnosis, recovery commands

---

## Next Steps After Host Recovery

1. **Task 2 + 3** — Bootstrap mariadb + postgresql as outlined in `regression.md`.
2. **Task 5** — `pkg delete -y wikijs && rm -rf /var/{db,log,run}/wikijs /usr/local/etc/wikijs /usr/local/www/wikijs && pkg add /usr/ports/www/wikijs/work/pkg/wikijs-2.5.314.pkg`.
3. **Task 6** — Re-run SQLITE round with full start/PID/4-way/stop/2-way cycle (current evidence is running-state only).
4. **Task 7** — Swap `config.yml` to mariadb block, restart, capture full evidence suite.
5. **Task 8** — Swap `config.yml` to postgres block, restart, capture full evidence suite.
6. **F2 re-run** — expect 21/21 evidence files, all PASS.
7. **F4 update** — flip "PARTIAL" verdict to "PASS / 21-21".