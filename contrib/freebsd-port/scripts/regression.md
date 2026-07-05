# Wiki.js FreeBSD Port Regression Test

Operator-facing documentation for the regression test script that validates the wikijs FreeBSD port across three datastores.

## What it does

- Runs three full port lifecycle rounds: sqlite (default), mariadb, postgresql
- Builds the port exactly once with `OPTIONS_SINGLE=SQLITE`; `npm` bundles the mariadb and postgres drivers into the package, and the runtime `db.type` switch in `/usr/local/etc/wikijs/config.yml` selects the active engine
- For each datastore: writes a matching `db:` block to config.yml, starts the service, verifies the web UI is reachable, stops the service, and re-verifies the process is gone
- Captures evidence files at every checkpoint for post-mortem analysis

## Prerequisites

- SSH key at `~/.ssh/id_ed25519` with access to the target host
- Host `wikijs.cloudbsd.org` reachable on the network
- Sudo working on the host (passwordless for the regression user)
- `mariadb-server` and `postgresql-server` packages installed on the host
- The port built once with `OPTIONS_SINGLE=SQLITE` so `npm` pre-bundles all three drivers

### Bootstrap MariaDB (pre-flight, run on the host via sudo)

```sh
sudo mariadb-install-db --user=mysql --basedir=/usr/local --datadir=/var/db/mysql
sudo sysrc mysql_enable="YES"
sudo service mysql-server start
sudo mariadb -e "SELECT VERSION()"
```

The `SELECT VERSION()` probe must succeed before the regression is started; if it fails the mariadb round will not be able to connect.

### Bootstrap PostgreSQL (pre-flight, run on the host via sudo)

```sh
sudo /usr/local/etc/rc.d/postgresql initdb
sudo sysrc postgresql_enable="YES"
sudo service postgresql start
sudo -u postgres psql -l
```

The `psql -l` probe must list at least the default `postgres` database before the regression is started.

### DB roles

Both engines need a `wikijs` role with password `wikijs` and a `wikijs` database owned by that role. Run these once per host, after the engines above are up.

MariaDB:

```sh
sudo mariadb -e "CREATE USER IF NOT EXISTS 'wikijs'@'127.0.0.1' IDENTIFIED BY 'wikijs';"
sudo mariadb -e "CREATE DATABASE IF NOT EXISTS wikijs CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
sudo mariadb -e "GRANT ALL PRIVILEGES ON wikijs.* TO 'wikijs'@'127.0.0.1';"
sudo mariadb -e "FLUSH PRIVILEGES;"
```

PostgreSQL:

```sh
sudo -u postgres psql -c "DO \$\$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='wikijs') THEN CREATE ROLE wikijs LOGIN PASSWORD 'wikijs'; END IF; END \$\$;"
sudo -u postgres psql -c "SELECT 'CREATE DATABASE wikijs OWNER wikijs' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname='wikijs') \gexec"
```

The sqlite round needs no DB role — `db.type: sqlite` writes to `/var/db/wikijs/data/wiki.sqlite` directly.

## Usage

```bash
bash regression.sh                                # run all three datastores
bash regression.sh --datastore=mariadb            # run a single round
bash regression.sh --datastore=postgresql         # run a single round
bash regression.sh --datastore=sqlite             # run a single round
```

## Evidence

Each round writes its evidence under the per-user evidence directory on the host: `/home/mlapointe/.omo/evidence/regression/<datastore>/`.

| Datastore   | Evidence directory                                            | Captured files                                                                                                                                                                  |
|-------------|---------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `sqlite`    | `/home/mlapointe/.omo/evidence/regression/sqlite/<step>.txt` | `before-start.txt`, `pid.txt`, `after-start.txt`, `after-stop.txt`                                                                                                             |
| `mariadb`   | `/home/mlapointe/.omo/evidence/regression/mariadb/<step>.txt` | `before-start.txt`, `pid.txt`, `after-start.txt`, `after-stop.txt`                                                                                                             |
| `postgresql`| `/home/mlapointe/.omo/evidence/regression/postgres/<step>.txt` | `before-start.txt`, `pid.txt`, `after-start.txt`, `after-stop.txt`                                                                                                             |

The four files captured per round:

- `before-start.txt` — pre-start state: `ps` snapshot and listening TCP sockets
- `pid.txt` — PID of the wikijs service after start
- `after-start.txt` — post-start state: `ps` for the captured PID, listening sockets, and the `curl` HTTP status code against `http://127.0.0.1:3000/`
- `after-stop.txt` — post-stop state: full `ps` snapshot and listening sockets (used to confirm wikijs really exited)

## Exit codes

- `0` — success: all rounds passed
- `1` — fatal: build, install, or configuration step failed
- `2` — verify failed: the service was started but the pidfile never appeared within the start timeout
- `3` — stopped verify failed: the service did not stop, or still had a wikijs process / socket after stop

## Troubleshooting

- **Sudo broken on host** — recover via the cloud console, then run `sudo chown -R root:wheel /usr/local/lib && sudo ldconfig -m /usr/local/lib`. The port's shared libraries will not load otherwise.
- **Playwright cannot reach the host** — open an SSH tunnel and run Playwright through it: `ssh -L 3000:127.0.0.1:3000 -N wikijs`. Point Playwright at `http://127.0.0.1:3000` while the tunnel is up.
- **`mariadbd` not found** — PATH issue. The binary lives at `/usr/local/libexec/mariadbd`; either invoke it by full path or fix the shell PATH for the regression user before running.

## Status (2026-07-05)

The host `wikijs.cloudbsd.org` is currently in a broken state: sudo is unusable and the dynamic linker cannot find port-installed shared libraries. The script will not run cleanly until the host is recovered. See `.omo/notepads/wikijs-regression/learnings.md` for the full diagnosis and the recovery steps. **Do not run until the host is recovered.** The script itself is currently a skeleton: `round_sqlite` / `round_mariadb` / `round_postgres` functions are placeholders that drive the start/stop lifecycle and capture evidence, but the underlying port build, install, and Playwright UI verification steps are not yet wired in. Full implementations will be added once the host is recovered.
