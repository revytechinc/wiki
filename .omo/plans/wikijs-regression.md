# Wikijs port regression test (SQLITE / MARIADB / PGSQL)

## TL;DR

> **Quick Summary**: Full end-to-end regression test for the
> `www/wikijs` FreeBSD port on `wikijs.cloudbsd.org`. Build the port
> once with `OPTIONS_SET+=SQLITE` (the only valid choice given the
> port's `OPTIONS_SINGLE=DB` constraint; npm bundles the postgres /
> mariadb drivers regardless, so runtime `db.type` in `config.yml`
> switches engines). Bootstrap MariaDB and PostgreSQL servers, then
> run three identical start/stop rounds (SQLITE, MARIADB, PGSQL).
> Each round edits `/usr/local/etc/wikijs/config.yml` to point at
> the datastore under test, starts `wikijs`, records the PID,
> verifies via `ps` + `sockstat` + `curl` + **Playwright
> inspection** of the rendered setup wizard (page title, `<setup>`
> element visible, full-page PNG), stops the service, then verifies
> the process is gone.
>
> **Deliverables**:
> - `contrib/freebsd-port/scripts/regression.sh` (canonical, versioned)
> - `.omo/evidence/regression/{sqlite,mariadb,postgres}/` (per-iteration evidence)
> - `.omo/evidence/regression/SUMMARY.md` (pass/fail matrix)
>
> **Estimated Effort**: Short (~35 min total: 20 build + 5 DB bootstrap + 10 rounds)
> **Parallel Execution**: YES -- 2 waves (DB bootstrap + build can run concurrently)
> **Critical Path**: build -> install -> sqlite-round -> mariadb-round -> postgres-round -> summary

---

## Context

### Original Request
"Now do a full regression test, lets plan this. I want it to build,
install, start the service, record the pid, check to see if the
services are actually running, stop the service, and check with ps
to see that the service is actually stopped, and i want it done
with att 3 of the datastores, sqlite, maria and postgres."

### Interview Summary
**Key decisions** (confirmed via Question tool):
- DB test strategy: **Hybrid** -- one build with OPTIONS=all (SQLITE+PGSQL+MARIADB), then 3 runtime rounds switching `config.yml`
- DB server install: **Yes** -- install + bootstrap both `mariadb-server` and `postgresql-server`
- Evidence scope: **Full** -- per-iteration pidfile, ps, sockstat, curl, log tail -> `.omo/evidence/regression/{name}/`
- Script location: **Repo** -- canonical under `contrib/freebsd-port/scripts/regression.{sh,md}`, also deployed to `/tmp` on host

**Research findings** (from prior session):
- Port lives at `/usr/ports/www/wikijs/` on host (standalone portdir)
- Wiki.js reads config path from `CONFIG_FILE` env var (NOT `--config` flag)
- rc.d renamed `wikijs_user` -> `wikijs_run_user` to avoid rc.subr su-wrap
- User `wikijs` UID 425 GID 425, class `daemon`, home `/var/db/wikijs`
- `make package` produces `/usr/ports/www/wikijs/work/pkg/wikijs-2.5.314.pkg` (~87 MB)
- `pkg delete` requires manual `pw userdel wikijs && pw groupdel wikijs` cleanup; the deinstall script leaves the user

### Metis Review (anticipated)
- **Risk**: PGSQL_DEFAULT or MARIADB_DEFAULT may be empty in `/etc/make.conf`, causing the package to fail to install (we hit this earlier). Mitigation: set `DEFAULT_VERSIONS+=postgresql=16 mariadb=11.4` in `/etc/make.conf` BEFORE `make package`.
- **Risk**: Both DB servers will try to bind 5432/3306 on the same host. Fine if mariadb uses `socket` and pgsql uses TCP, but verify only one binds each.
- **Risk**: Wiki.js in setup-mode listens on :3000 but exits early if `db.type` doesn't match. Each round needs sufficient startup grace (15-20s for postgres/mariadb).
- **Ambiguity**: "services actually running" -- interpret as: pidfile present AND pid matches a `node server` process AND :3000 is listening per `sockstat` AND HTTP returns 2xx.

---

## Work Objectives

### Core Objective
Validate that the `www/wikijs` port, freshly built and installed, can
start and stop cleanly against each of SQLITE, MariaDB, and
PostgreSQL datastores, with **per-iteration evidence** captured --
including **Playwright-driven inspection** of the rendered setup
wizard (page title, `<setup>` element visible, full-page PNG,
body-text snippet).

### Concrete Deliverables
1. `contrib/freebsd-port/scripts/regression.sh` -- executable shell
   script driving the full suite
2. `contrib/freebsd-port/scripts/regression.md` -- operator-facing
   doc explaining how to invoke, what evidence is captured
3. `.omo/evidence/regression/sqlite/{before,after-start,after-stop}.{txt,json}`
4. `.omo/evidence/regression/mariadb/{...}`
5. `.omo/evidence/regression/postgres/{...}`
6. `.omo/evidence/regression/{sqlite,mariadb,postgres}/playwright/{setup-wizard.png,body-snippet.txt,ok.txt}`
   -- per-datastore Playwright artifacts
7. `.omo/evidence/regression/SUMMARY.md` -- pass/fail matrix

### Scope Boundaries

**IN scope**:
- One build of `www/wikijs` (with `OPTIONS_SET+=SQLITE`)
- Server packages installed + bootstrapped (mariadb, postgresql)
- For each of 3 datastores: start, record PID, 4-way verify (ps + sockstat + curl + Playwright), stop, 2-way verify (ps + sockstat clean)
- Per-iteration evidence captured

**OUT of scope** (explicitly excluded):
- Full completion of the setup wizard (we stop at the rendered first-step page; no operator email/password entry)
- Load / performance testing (no concurrent users, no soak time beyond 8s startup grace)
- Upgrade path testing (`pkg upgrade wikijs` is not exercised)
- Backup / restore of `/var/db/wikijs/data`
- Migration from one DB engine to another
- DB connection over TLS (defaults to plain TCP / socket)

### Definition of Done
- All evidence files exist for each datastore iteration
- Each "actually running" check returns positive
- Each "actually stopped" check returns negative
- `SUMMARY.md` shows three PASS rows
- Exit code 0 from `regression.sh`
- Script is committed to git

### Must Have
- One clean build with all 3 OPTIONS resolved at build time
- Server packages actually running (mariadb listening, postgresql listening)
- Wiki.js DB user + DB per engine created
- Round per datastore: start, PID record, 4-way verify, stop, 2-way verify

### Must NOT Have (Guardrails)
- Do NOT use the existing running `wikijs` process -- delete + reinstall fresh
- Do NOT rebuild the package between rounds -- one build, three runtime rounds
- Do NOT skip evidence capture -- every step MUST leave a file
- Do NOT leave DB servers running on the host after the test (revert `sysrc`)
- Do NOT commit evidence files -- they're transient (gitignored)
- Do NOT leave stale `/var/db/wikijs/data/*` between rounds -- clean per round

---

## Verification Strategy

### Test Decision
- **Infrastructure exists**: YES (port already builds at `/usr/ports/www/wikijs/`)
- **Automated tests**: NO unit tests for FreeBSD ports
- **Framework**: shell script with assertion helpers (bash strict mode, `set -euo pipefail`)
- **QA Policy**: Every checkpoint writes evidence; the orchestrator
  grep's evidence files before marking the round done.

### QA Policy
Every checkpoint MUST leave evidence at
`.omo/evidence/regression/{sqlite|mariadb|postgres}/{step}.txt`.
A round is PASS only when:
- before-start: pidfile absent (or stale), :3000 unbound
- after-start: pid recorded, `ps -p $pid` matches `node server`,
  `sockstat -p 3000` shows the pid, `curl` returns 2xx
- after-stop: pidfile gone, `ps auxww | grep 'node server' | grep -v grep` empty,
  `sockstat -p 3000` empty, log tail shows clean shutdown line

---

## Execution Strategy

### Parallel Execution Waves

```
Wave 1 (parallel, foundation):
├── Task 1: `pkg install mariadb-server postgresql-server` on host
├── Task 2: bootstrap mariadb (mysql_install_db, sysrc + start)
├── Task 3: bootstrap postgresql (initdb, sysrc + start, create wikijs user+db)
└── Task 4: build the port with OPTIONS=all (cd /usr/ports/www/wikijs && make clean && make package)

Wave 2 (sequential, install + 3 rounds):
├── Task 5: install the .pkg (pkg delete -y; rm -rf /usr/local/etc/wikijs /var/db/wikijs; pkg add)
├── Task 6: SQLITE round    -- start/verify/stop/verify + evidence
├── Task 7: MARIADB round   -- config swap, create role, start/verify/stop/verify + evidence
└── Task 8: POSTGRES round  -- config swap, create role, start/verify/stop/verify + evidence

Wave FINAL (parallel, 4 reviews + summary):
├── Task F1: plan compliance audit (oracle)
├── Task F2: evidence completeness audit (unspecified-high)
├── Task F3: shellcheck regression.sh + bash -n (unspecified-high)
└── Task F4: SUMMARY.md auto-generation + operator review (deep)
```

### Dependency Matrix
- 1 (mariadb pkg install): -
- 2 (mariadb bootstrap): 1
- 3 (postgres bootstrap): 1 (parallel with 2)
- 4 (port build): -
- 5 (pkg install): 4
- 6 (sqlite round): 5
- 7 (mariadb round): 5, 2
- 8 (postgres round): 5, 3
- F1-F4: 6, 7, 8

### Agent Dispatch Summary
- Wave 1: 1 -> `quick`; 2 -> `quick`; 3 -> `quick`; 4 -> `unspecified-high` (20-min build)
- Wave 2: 5 -> `quick`; 6-8 -> `quick` each
- Wave FINAL: F1 -> `oracle`; F2, F3, F4 -> `unspecified-high`

---

## TODOs

### Wave 1

- [ ] 1. Install MariaDB and PostgreSQL server packages on host

  **What to do**:
  - `ssh wikijs.cloudbsd.org 'sudo pkg install -y mariadb-server postgresql-server'`
  - Capture stdout/stderr to `.omo/evidence/regression/db-install.log`

  **Must NOT do**:
  - Don't auto-start the services via `service enable` flags -- do that in tasks 2/3

  **Recommended Agent Profile**:
  - Category: `quick`
  - Skills: `git-master` (for evidence write)

  **Parallelization**:
  - Can Run In Parallel: YES
  - Parallel Group: Wave 1 (with tasks 2, 3, 4)
  - Blocks: 2, 3
  - Blocked By: None

  **References**:
  - Pattern: `/usr/ports/databases/mariadb-server/pkg-install` (post-install bootstrap hooks)
  - Pattern: `/usr/ports/databases/postgresql*1?-server/pkg-install`

  **Acceptance Criteria**:
  - [ ] `pkg query '%Ok %Ov' mariadb-server postgresql-server` resolves both
  - [ ] `which mariadbd postgres` exits 0
  - [ ] `.omo/evidence/regression/db-install.log` > 1 KB

  **QA Scenarios (MANDATORY)**:
  ```
  Scenario: mariadb binary present
    Tool: Bash (ssh)
    Steps:
      1. ssh wikijs 'which mariadbd'
    Expected Result: exit 0, prints `/usr/local/sbin/mariadbd`
    Evidence: .omo/evidence/regression/mariadb-bin.txt

  Scenario: postgres binary present
    Tool: Bash (ssh)
    Steps:
      1. ssh wikijs 'which postgres'
    Expected Result: exit 0, prints `/usr/local/bin/postgres`
    Evidence: .omo/evidence/regression/postgres-bin.txt
  ```

  **Commit**: NO (logs are transient)

---

- [ ] 2. Bootstrap MariaDB -- init datadir, sysrc, start, create wikijs user+db

  **What to do**:
  - `sudo mariadb-install-db --user=mysql --datadir=/var/db/mysql`
  - `sudo sysrc mariadb_enable=YES`
  - `sudo service mysql-server start` (mariadb-server ships rc.d as `mysql-server`)
  - Wait for unix socket to appear
  - `sudo mariadb -e "CREATE USER 'wikijs'@'localhost' IDENTIFIED BY 'wikijs'; CREATE DATABASE wikijs CHARACTER SET utf8mb4; GRANT ALL ON wikijs.* TO 'wikijs'@'localhost'; FLUSH PRIVILEGES;"`
  - Evidence: capture version, users, grants

  **Recommended Agent Profile**: `quick`
  **Parallelization**: Wave 1 with 1, 3, 4

  **References**:
  - `/usr/ports/databases/mariadb-server/files/mysql-server.in` (rc.d script)
  - MariaDB docs: `mysql_install_db` and `mariadb-install-db` are interchangeable

  **Acceptance Criteria**:
  - [ ] `service mysql-server status` reports running
  - [ ] `sudo mariadb -e 'SELECT user,host FROM mysql.user'` shows `wikijs@localhost`
  - [ ] `sudo mariadb -e 'USE wikijs; SELECT 1'` returns 1

  **QA Scenarios**:
  ```
  Scenario: mariadb socket reachable
    Tool: Bash
    Steps: ssh wikijs 'sudo mariadb -e "SELECT VERSION();"'
    Expected Result: prints version like `11.4.x`
    Evidence: .omo/evidence/regression/mariadb-boot.txt
  ```

  **Commit**: NO

---

- [ ] 3. Bootstrap PostgreSQL -- initdb, sysrc, start, create wikijs user+db

  **What to do**:
  - `sudo /usr/local/etc/rc.d/postgresql initdb` (or `initdb -D /var/db/postgres/data16`)
  - `sudo sysrc postgresql_enable=YES postgresql_data=/var/db/postgres/data16`
  - `sudo service postgresql start`
  - Wait for unix socket
  - `sudo -u postgres psql -c "CREATE USER wikijs WITH PASSWORD 'wikijs';"`
  - `sudo -u postgres psql -c "CREATE DATABASE wikijs OWNER wikijs;"`
  - `sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE wikijs TO wikijs;"`

  **Recommended Agent Profile**: `quick`
  **Parallelization**: Wave 1 with 1, 2, 4

  **References**:
  - `/usr/ports/databases/postgresql16-server/files/postgresql.in`
  - pkg-message for first-time initdb instructions

  **Acceptance Criteria**:
  - [ ] `service postgresql status` reports running
  - [ ] `sudo -u postgres psql -l` lists `wikijs` database
  - [ ] `PGUSER=wikijs PGPASSWORD=wikijs psql -h 127.0.0.1 -d wikijs -c 'SELECT 1'` returns 1

  **QA Scenarios**:
  ```
  Scenario: postgres accepting TCP connections
    Tool: Bash
    Steps: ssh wikijs "PGPASSWORD=wikijs psql -h 127.0.0.1 -U wikijs -d wikijs -c 'SELECT version();'"
    Expected Result: prints `PostgreSQL 1x.x` line
    Evidence: .omo/evidence/regression/postgres-boot.txt
  ```

  **Commit**: NO

---

- [x] 4. Build the port

  **What to do**:
  - Set `DEFAULT_VERSIONS+=postgresql=16 mariadb=11.4` in `/etc/make.conf` (handle empty-defaults bug; needed for tasks 7/8 even though the package itself does not pull the clients when SQLITE is selected)
  - `cd /usr/ports/www/wikijs && sudo rm -rf work`
  - `sudo chown -R mlapointe:mlapointe /var/db/ports/www_wikijs` (recover write perms)
  - `DISABLE_VULNERABILITIES=yes NO_DIALOG=1 BATCH=yes OPTIONS_SET+=SQLITE make package`
    - The port declares `OPTIONS_SINGLE=DB` with `OPTIONS_SINGLE_DB=SQLITE PGSQL MARIADB`. Because OPTIONS_SINGLE is mutually exclusive, only ONE option is selected at build time. We pick SQLITE because SQLITE needs no external client. The other engines (postgres/mariadb npm drivers) are bundled in node_modules by npm install regardless, and the runtime `db.type` field in `config.yml` switches the engine. We do NOT need a separate build per datastore.
  - Capture last 30 lines of build output to evidence log
  - Verify `work/pkg/wikijs-2.5.314.pkg` is ~87 MB

  **Recommended Agent Profile**: `unspecified-high` (20-min runtime)
  **Parallelization**: Wave 1 with 1, 2, 3

  **Acceptance Criteria**:
  - [x] `make package` exits 0
  - [x] `/usr/ports/www/wikijs/work/pkg/wikijs-2.5.314.pkg` exists, > 80 MB
  - [x] `pkg info -d <pkg> | head` shows `origin: www/wikijs` and `www/node24` BUILD_DEPENDS

  **QA Scenarios**:
  ```
  Scenario: build succeeds with single OPTIONS_SINGLE selection
    Tool: Bash (ssh)
    Preconditions: ports tree writable
    Steps:
      1. sudo bash -c 'echo "DEFAULT_VERSIONS+=postgresql=16 mariadb=11.4" >> /etc/make.conf'
      2. cd /usr/ports/www/wikijs && DISABLE_VULNERABILITIES=yes OPTIONS_SET+=SQLITE make package
    Expected Result: exit 0, prints "Building wikijs-2.5.314", "===>  Building packages for wikijs-2.5.314"
    Failure Indicators: "non existing origin", "only one DB option", "Error code 1", plist truncation warning
    Evidence: .omo/evidence/regression/build.log

  Scenario: package is installable (sanity check, not yet installed)
    Tool: Bash
    Steps:
      1. ssh wikijs 'pkg info -f /usr/ports/www/wikijs/work/pkg/wikijs-2.5.314.pkg'
    Expected Result: shows name=wikijs version=2.5.314 origin=www/wikijs
    Failure Indicators: "No package(s) matching"
    Evidence: .omo/evidence/regression/pkg-info.txt
  ```

  **DONE**: Build completed in ~4 min. Package = 87,930,705 bytes (~83.86 MiB). SQLITE=on per pkg-info.txt. Build needed `LD_LIBRARY_PATH=/usr/local/lib` workaround because `/usr/local/bin/{node,npm}` cannot load shared libs (host's `/usr/local/lib` is owned by wikijs, not root:wheel, so ldconfig excludes it). Used `~/.make.conf` for DEFAULT_VERSIONS (no /etc/make.conf write needed).

  **Commit**: NO (build artifact is transient; regression.sh reads path from `REGRESSION_PKG` env var)

---

### Wave 2

- [ ] 5. Fresh install of the .pkg

  **What to do**:
  - Stop existing wiki + DB servers (idempotent)
  - `sudo pw userdel wikijs && sudo pw groupdel wikijs` (so pkg add re-creates)
  - `sudo pkg delete -y wikijs || true`
  - `sudo rm -rf /usr/local/etc/wikijs /usr/local/www/wikijs /var/db/wikijs /var/log/wikijs /var/run/wikijs`
  - `sudo pkg add /usr/ports/www/wikijs/work/pkg/wikijs-2.5.314.pkg`
  - `sudo cp /usr/local/etc/wikijs/config.sample.yml /usr/local/etc/wikijs/config.yml`
  - `sudo chown wikijs:wikijs /usr/local/etc/wikijs/config.yml`

  **Recommended Agent Profile**: `quick`
  **Parallelization**: Wave 2 (blocking 6, 7, 8)

  **Acceptance Criteria**:
  - [ ] `pkg query '%Ok' wikijs` resolves
  - [ ] `/usr/local/bin/wikijs` exists, mode 0555, owner wikijs
  - [ ] `/usr/local/etc/wikijs/config.yml` exists, mode 0644, owner wikijs
  - [ ] `service wikijs rcvar` prints `wikijs_enable`

  **QA Scenarios**:
  ```
  Scenario: package extracts cleanly
    Tool: Bash (ssh)
    Steps:
      1. sudo pkg add /usr/ports/www/wikijs/work/pkg/wikijs-2.5.314.pkg 2>&1 | grep -E "Extracting|Error"
    Expected Result: "Extracting wikijs-2.5.314: .. done"
    Failure Indicators: "Truncated tar archive", "Permission denied", retry loops
    Evidence: .omo/evidence/regression/install.log
  ```

  **Commit**: NO

---

- [ ] 6. SQLITE round -- start, record pid, verify 4-way + Playwright, stop, verify 2-way

  **What to do**:
  - `before-start`: snapshot `ls /var/run/wikijs/`, `sockstat -p 3000`, `ps auxww | grep wikijs | grep -v grep` -> sqlite/before-start.txt
  - Write config.yml SQLITE block (type: sqlite, storage: /var/db/wikijs/data/wiki.sqlite)
  - `sudo service wikijs start`
  - Poll up to 30s for `/var/run/wikijs/wikijs.pid` to appear + content is int
  - Capture PID -> sqlite/pid.txt
  - `after-start` (cheap gate, fail fast):
    - `ps auxww -p $pid` -> expects `node server`
    - `sockstat -l -p 3000` -> expects node on :3000
    - `curl -sS -w '%{http_code}\n' http://127.0.0.1:3000/` -> expects 2xx
    - Save all 3 to `sqlite/after-start.txt`
  - **NEW Playwright inspection** (rich check after cheap gate passes):
    - Run `/playwright` workflow with `playwright_navigate("http://wikijs.cloudbsd.org:3000/")`, `playwright_wait_for_load_state("networkidle")`, `playwright_assert_text("Wiki.js Setup")`, `playwright_assert_visible("setup")` (the `<setup wiki-version=...>` element), `playwright_save_screenshot(".omo/evidence/regression/sqlite/playwright/setup-wizard.png", fullPage=true)`, `playwright_get_body_text()` -> `playwright/body-snippet.txt`
    - If wikijs.cloudbsd.org:3000 not reachable from local browser, fall back to `playwright_navigate("http://127.0.0.1:3000/")` via SSH tunnel (`ssh -L 3000:127.0.0.1:3000 -N wikijs`)
    - Write a `playwright/ok.txt` with timestamp + browser + viewport on success
  - `sudo service wikijs stop`
  - Wait up to 10s for pidfile removal
  - `after-stop`: `ps auxww | grep 'node server' | grep -v grep` (expect empty), `sockstat -l -p 3000` (expect empty), `tail -25 /var/log/wikijs/wikijs.log` -> sqlite/after-stop.txt
  - Mark round PASS / FAIL

  **Recommended Agent Profile**: `quick`
  **Parallelization**: Wave 2 (runs sequentially with 7, 8)

  **Acceptance Criteria (per round)**:
  - [ ] `before-start.txt` documents pre-state cleanly
  - [ ] `pid.txt` contains exactly one integer
  - [ ] `after-start.txt` shows: ps matches `node server`, sockstat shows node on :3000, curl returns 2xx
  - [ ] `playwright/setup-wizard.png` exists, > 30 KB (a blank page is ~5KB; rendered page is 100KB+)
  - [ ] `playwright/body-snippet.txt` contains "Wiki.js Setup" string
  - [ ] `playwright/ok.txt` exists with timestamp
  - [ ] `after-stop.txt` shows: ps grep empty, sockstat -p 3000 empty, log has "Stopping" or similar
  - [ ] `ROUND=sqlite PASS` written to evidence

  **QA Scenarios**:
  ```
  Scenario: wikijs actually running (cheap gate)
    Tool: Bash (ssh)
    Preconditions: service wikijs start returned 0
    Steps:
      1. PID=$(cat /var/run/wikijs/wikijs.pid)
      2. ps -p $PID -o pid,user,command | grep -E "node server"
      3. sockstat -l -p 3000 | grep node
      4. curl -sS -o /dev/null -w "%{http_code}" http://127.0.0.1:3000/
    Expected Result: line 2 has a row, line 3 has a row, line 4 is 200 or 302
    Failure Indicators: line 2 or 3 empty, line 4 returns 000 or 500
    Evidence: .omo/evidence/regression/sqlite/after-start.txt

  Scenario: setup wizard actually rendered (Playwright)
    Tool: Playwright (browser, via /playwright skill)
    Preconditions: curl returned 2xx in the previous scenario
    Steps:
      1. browser_navigate http://wikijs.cloudbsd.org:3000/ (or 127.0.0.1:3000 via tunnel)
      2. wait for loadstate "networkidle"
      3. assert page.title() contains "Wiki.js Setup"
      4. assert page.locator("setup").isVisible() is true
      5. capture full-page screenshot -> playwright/setup-wizard.png
      6. capture page.locator("body").innerText() -> playwright/body-snippet.txt
    Expected Result: title contains "Wiki.js Setup", setup element visible, PNG file created
    Failure Indicators: title is blank, "About" or "404" or other static page, no <setup> element
    Evidence: .omo/evidence/regression/sqlite/playwright/{setup-wizard.png,body-snippet.txt,ok.txt}

  Scenario: wikijs actually stopped
    Tool: Bash (ssh)
    Preconditions: service wikijs stop returned 0, waited 5s
    Steps:
      1. ps auxww | grep "node server" | grep -v grep
      2. sockstat -l -p 3000
      3. ls /var/run/wikijs/
    Expected Result: step 1 returns no lines, step 2 returns no lines, step 3 has no .pid file
    Failure Indicators: any node process still listed, port still bound, pidfile still present
    Evidence: .omo/evidence/regression/sqlite/after-stop.txt
  ```

  **Commit**: NO

---

- [ ] 7. MARIADB round -- start, record pid, verify 4-way + Playwright, stop, verify 2-way

  **What to do**:
  - Same shape as task 6, but:
  - Replace SQLITE config block with mariadb block:
    ```yaml
    db:
      type: mariadb
      host: 127.0.0.1
      port: 3306
      user: wikijs
      pass: wikijs
      db: wikijs
    ```
  - `sudo service wikijs start` (after the previous round stopped it)
  - Poll up to 30s; mariadb may take longer for first migration
  - Same before/after evidence files under `.omo/evidence/regression/mariadb/`
  - Same Playwright inspection under `.omo/evidence/regression/mariadb/playwright/` per task 6

  **Recommended Agent Profile**: `quick`
  **Parallelization**: Wave 2 (sequential with 6, 8)

  **Acceptance Criteria**: same as task 6, plus:
  - [ ] `mariadb -e 'SHOW TABLES' wikijs` lists migration-created tables (e.g., `users`, `pages`)
  - [ ] wiki log shows "Database Connection Successful [OK]" and "HTTP Server: [RUNNING]"

  **QA Scenarios**: same as task 6 (cheap gate + Playwright + stopped), plus:
  ```
  Scenario: mariadb schema migrated
    Tool: Bash (ssh)
    Steps:
      1. sudo mariadb wikijs -e "SHOW TABLES" | head -20
    Expected Result: lists `knex_migrations`, `users`, `pages`, etc.
    Failure Indicators: "ERROR 1049 (Unknown database)", empty table list (no migration ran)
    Evidence: .omo/evidence/regression/mariadb/schema.txt
  ```

  **Commit**: NO

---

- [ ] 8. POSTGRES round -- start, record pid, verify 4-way + Playwright, stop, verify 2-way

  **What to do**:
  - Same shape, postgres block:
    ```yaml
    db:
      type: postgres
      host: 127.0.0.1
      port: 5432
      user: wikijs
      pass: wikijs
      db: wikijs
      ssl: false
    ```
  - Evidence under `.omo/evidence/regression/postgres/`
  - Same Playwright inspection under `.omo/evidence/regression/postgres/playwright/` per task 6

  **Recommended Agent Profile**: `quick`
  **Parallelization**: Wave 2 (sequential with 6, 7)

  **Acceptance Criteria**: same as task 6, plus:
  - [ ] `psql -c '\dt' wikijs` shows migration tables
  - [ ] wiki log shows successful postgres connect and "HTTP Server: [RUNNING]"

  **QA Scenarios**: same as task 6 (cheap gate + Playwright + stopped), plus:
  ```
  Scenario: postgres schema migrated
    Tool: Bash (ssh)
    Steps:
      1. PGPASSWORD=wikijs psql -h 127.0.0.1 -U wikijs -d wikijs -c '\dt' | head -20
    Expected Result: lists `knex_migrations`, `users`, `pages`, etc.
    Failure Indicators: "FATAL: database does not exist", empty table list
    Evidence: .omo/evidence/regression/postgres/schema.txt
  ```

  **Commit**: NO

---

### Final Verification Wave

- [x] F1. Plan compliance audit (oracle)
  Read `regression.sh` and `regression.md`; verify they cover the 8-step user requirement for each of 3 datastores. Compare with plan sections 5-8.
  Output: `Must Have [N/N] | Must NOT Have [N/N] | Tasks [N/N] | VERDICT`

- [ ] F2. Evidence completeness audit (unspecified-high)
  `tree .omo/evidence/regression/`; verify per datastore (sqlite, mariadb, postgres):
  - `before-start.txt`, `pid.txt`, `after-start.txt` present
  - `playwright/setup-wizard.png` (>= 30KB), `playwright/body-snippet.txt` (contains "Wiki.js Setup"), `playwright/ok.txt` present
  - `after-stop.txt` present
  Spot-check after-start.txt shows all 4 verify-actually-running signals; after-stop.txt shows the 2 verify-actually-stopped signals; playwright PNG is non-blank.
  Output: `Files [N/N] | Signals [N/N present/N missing] | VERDICT`

- [ ] F3. shellcheck + bash -n (unspecified-high)
  `shellcheck contrib/freebsd-port/scripts/regression.sh` and `bash -n`; verify strict mode (`set -euo pipefail`), no `eval`, no `rm -rf /`.
  Output: `Lint [N/N clean] | Strict [yes/no] | VERDICT`

- [ ] F4. SUMMARY.md synthesis (deep)
  Generate `.omo/evidence/regression/SUMMARY.md` from the per-round evidence:
  - Row per datastore (sqlite, mariadb, postgres)
  - Columns: started? pid recorded? ps match? sockstat match? HTTP 2xx? stopped? ps clean? sockstat clean? -> overall PASS/FAIL
  Commit `regression.sh` and `regression.md` to git in a final commit referencing `d94e5d9a` and `4fac00f0`.
  Output: `Rows [N/N] | Commits [N new] | VERDICT`

---

## Commit Strategy

- **Final commit** (after F4):
  ```
  feat(freebsd): add regression.sh exercising all 3 datastores
  
  Validates the www/wikijs port against SQLITE, MariaDB, and
  PostgreSQL backends in one shot. Each round: start, record PID,
  verify via ps + sockstat + HTTP, stop, verify process gone.
  
  Closes the loop on the user's regression request from session
  planning. See scripts/regression.md for invocation.
  ```
  Files: `contrib/freebsd-port/scripts/regression.{sh,md}`

---

## Success Criteria

### Verification Commands
```bash
# After Wave 1:
ssh wikijs.cloudbsd.org 'pkg query "%Ok %Ov" mariadb-server postgresql-server'
# expected: both resolve

# After Wave 2 task 4:
ls -la /usr/ports/www/wikijs/work/pkg/wikijs-2.5.314.pkg
# expected: ~87 MB

# After Wave 2 task 5:
ssh wikijs.cloudbsd.org 'pkg query "%Ok" wikijs && service wikijs rcvar'

# After all rounds:
ssh wikijs.cloudbsd.org 'cat .omo/evidence/regression/{sqlite,mariadb,postgres}/pid.txt'
# expected: three PIDs

# Final:
cat .omo/evidence/regression/SUMMARY.md
# expected: three PASS rows
```

### Final Checklist
- [ ] Port built with `OPTIONS_SET+=SQLITE` -> 87 MB .pkg (npm installs all 3 DB drivers regardless)
- [ ] mariadb-server + postgresql-server installed and running on host
- [ ] `wikijs` user/DB created for each of mariadb and postgres
- [ ] SQLITE round: started, PID recorded, ps+sockstat+curl all green, Playwright PNG + body-snippet captured, stopped, ps+sockstat clean
- [ ] MARIADB round: same plus `SHOW TABLES` lists migration tables
- [ ] PGSQL round: same plus `\dt` lists migration tables
- [ ] `regression.sh` committed under `contrib/freebsd-port/scripts/`
- [ ] `regression.md` committed alongside
- [ ] SUMMARY.md shows 3/3 PASS
