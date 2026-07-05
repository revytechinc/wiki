#!/usr/bin/env bash
set -euo pipefail

# regression.sh - FreeBSD port regression driver for wikijs
# Runs SSH-based commands against a remote host and captures evidence
# for each datastore backend under test.
#
# This script does not connect anywhere by itself.  Each helper
# function shells out to ssh with a single command string and is
# intended to be invoked from a CI runner that has the matching
# private key installed at $SSH_KEY.
#
# Current status: the host wikijs.cloudbsd.org is broken (sudo +
# ldconfig).  Do not run this until that is repaired.

HOST="wikijs.cloudbsd.org"
EVIDENCE_DIR="/home/mlapointe/.omo/evidence/regression"
WIKIJS_PKG="/usr/ports/www/wikijs/work/pkg/wikijs-2.5.314.pkg"
WIKIJS_CONFIG="/usr/local/etc/wikijs/config.yml"
WIKIJS_RC="wikijs"
WIKIJS_PIDFILE="/var/run/wikijs/pid"
WIKIJS_HTTP="http://127.0.0.1:3000/"
SSH_KEY="$HOME/.ssh/id_ed25519"
REMOTE_USER="mlapointe"
START_TIMEOUT=30

# Exit codes.  Capped at 3 per operator policy.
EXIT_OK=0
EXIT_FATAL=1
EXIT_VERIFY_FAIL=2
EXIT_STOP_VERIFY_FAIL=3

# Round ordering matters: we always start on sqlite (the cheapest
# backend) and only proceed if it ends clean.
ROUNDS=(round_sqlite round_mariadb round_postgres)

# Datastore filter (set by --datastore=, defaults to "all").
DATASTORE="all"

log() {
    printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

die() {
    printf 'FATAL: %s\n' "$*" >&2
    exit "${EXIT_FATAL}"
}

require_var() {
    [[ -n "${!1:-}" ]] || die "required variable $1 is empty"
}

# host_run <cmd>
# Run a command on the remote host as the regular user.
host_run() {
    local cmd="$1"
    ssh -i "$SSH_KEY" "${REMOTE_USER}@${HOST}" "$cmd"
}

# host_sudo <cmd>
# Run a command on the remote host under sudo.
host_sudo() {
    local cmd="$1"
    ssh -i "$SSH_KEY" "${REMOTE_USER}@${HOST}" "sudo ${cmd}"
}

# capture_evidence <datastore> <step> <text>
# Write the supplied text to a per-datastore / per-step file under
# EVIDENCE_DIR on the remote host.  Creates intermediate directories.
capture_evidence() {
    local datastore="$1"
    local step="$2"
    local text="$3"
    local target="${EVIDENCE_DIR}/${datastore}/${step}.txt"

    host_run "mkdir -p '${EVIDENCE_DIR}/${datastore}' && cat > '${target}' <<'__OMO_EVIDENCE__'
${text}
__OMO_EVIDENCE__"
}

# write_config_block <datastore>
# Push the active datastore's db block into config.yml.  Assumes the
# operator has bootstrapped the matching DB engine externally.
write_config_block() {
    local datastore="$1"
    local config_block
    case "${datastore}" in
        sqlite)
            config_block=$(cat <<'__CFG__'
db:
  type: sqlite
  storage: /var/db/wikijs/data/wiki.sqlite
__CFG__
)
            ;;
        mariadb)
            config_block=$(cat <<'__CFG__'
db:
  type: mariadb
  host: 127.0.0.1
  port: 3306
  user: wikijs
  pass: wikijs
  db: wikijs
__CFG__
)
            ;;
        postgres)
            config_block=$(cat <<'__CFG__'
db:
  type: postgres
  host: 127.0.0.1
  port: 5432
  user: wikijs
  pass: wikijs
  db: wikijs
__CFG__
)
            ;;
        *)
            die "unknown datastore: ${datastore}"
            ;;
    esac

    host_sudo "mkdir -p '/usr/local/etc/wikijs' && printf '%s\n' '${config_block}' > '${WIKIJS_CONFIG}'"
}

# start_wikijs_and_verify <datastore>
# Start the wikijs service, poll for the pidfile up to START_TIMEOUT
# seconds, capture after-start evidence, and return EXIT_VERIFY_FAIL
# if the pidfile never appears.
start_wikijs_and_verify() {
    local datastore="$1"
    local pid=""
    local elapsed=0

    host_sudo "service '${WIKIJS_RC}' start"

    while [[ "${elapsed}" -lt "${START_TIMEOUT}" ]]; do
        if pid=$(host_run "cat '${WIKIJS_PIDFILE}' 2>/dev/null") && [[ -n "${pid}" ]]; then
            break
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done

    if [[ -z "${pid}" ]]; then
        log "${datastore}: pidfile ${WIKIJS_PIDFILE} never appeared within ${START_TIMEOUT}s"
        return "${EXIT_VERIFY_FAIL}"
    fi

    capture_evidence "${datastore}" "pid" "${pid}"
    capture_evidence "${datastore}" "before-start" "$(host_run 'ps -ax -o pid,command | head -40; echo ---sockstat---; sockstat -l -P tcp 2>/dev/null || true')"
    capture_evidence "${datastore}" "after-start" "$(host_run 'ps -p '"${pid}"' -o pid,ppid,stat,etime,command 2>/dev/null; echo ---sockstat---; sockstat -l -P tcp 2>/dev/null; echo ---curl---; curl -sS -o /dev/null -w "http_code=%{http_code}\n" '"${WIKIJS_HTTP}"' 2>&1 || echo curl-failed')"
    return "${EXIT_OK}"
}

# stop_wikijs_and_verify <datastore>
# Stop the wikijs service and confirm it actually exited.  Returns
# EXIT_STOP_VERIFY_FAIL if a wikijs process or socket survives.
stop_wikijs_and_verify() {
    local datastore="$1"
    local after

    host_sudo "service '${WIKIJS_RC}' stop"
    sleep 2

    after=$(host_run 'ps -ax -o pid,command 2>/dev/null; echo ---sockstat---; sockstat -l -P tcp 2>/dev/null || true')
    capture_evidence "${datastore}" "after-stop" "${after}"

    if printf '%s' "${after}" | grep -q wikijs; then
        log "${datastore}: wikijs still present after stop"
        return "${EXIT_STOP_VERIFY_FAIL}"
    fi

    return "${EXIT_OK}"
}

# round_sqlite
# Exercise the sqlite datastore: install (caller's responsibility),
# configure, start, smoke test, capture evidence, stop.
round_sqlite() {
    log "round_sqlite: begin"
    write_config_block sqlite
    start_wikijs_and_verify sqlite || return "$?"
    stop_wikijs_and_verify sqlite || return "$?"
    log "round_sqlite: end"
    return "${EXIT_OK}"
}

# round_mariadb
# Exercise the mariadb datastore.
round_mariadb() {
    log "round_mariadb: begin"
    write_config_block mariadb
    start_wikijs_and_verify mariadb || return "$?"
    stop_wikijs_and_verify mariadb || return "$?"
    log "round_mariadb: end"
    return "${EXIT_OK}"
}

# round_postgres
# Exercise the postgres datastore.
round_postgres() {
    log "round_postgres: begin"
    write_config_block postgres
    start_wikijs_and_verify postgres || return "$?"
    stop_wikijs_and_verify postgres || return "$?"
    log "round_postgres: end"
    return "${EXIT_OK}"
}

# map_round <datastore>
# Echo "round_<datastore>" for the named datastore, nothing for "all".
map_round() {
    local datastore="$1"
    case "${datastore}" in
        sqlite|mariadb|postgres)
            printf 'round_%s\n' "${datastore}"
            ;;
        all)
            : # handled by caller
            ;;
        *)
            die "unknown datastore: ${datastore}"
            ;;
    esac
}

# main: parse flags, validate environment, dispatch each round.
main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --datastore=*)
                DATASTORE="${1#--datastore=}"
                ;;
            --datastore)
                shift
                [[ $# -gt 0 ]] || die "--datastore requires a value"
                DATASTORE="$1"
                ;;
            --help|-h)
                printf 'usage: bash regression.sh [--datastore=sqlite|mariadb|postgres|all]\n'
                exit "${EXIT_OK}"
                ;;
            *)
                die "unknown argument: $1"
                ;;
        esac
        shift
    done

    log "regression driver starting for host=${HOST}"
    log "evidence root: ${EVIDENCE_DIR}"
    log "package under test: ${WIKIJS_PKG}"
    log "config under test: ${WIKIJS_CONFIG}"
    log "datastore filter: ${DATASTORE}"

    require_var HOST
    require_var EVIDENCE_DIR
    require_var WIKIJS_PKG
    require_var WIKIJS_CONFIG
    require_var SSH_KEY

    if [[ ! -f "${SSH_KEY}" ]]; then
        die "ssh key not found at ${SSH_KEY}"
    fi

    case "${DATASTORE}" in
        sqlite|mariadb|postgres|all) ;;
        *) die "unknown datastore: ${DATASTORE}" ;;
    esac

    local rounds
    if [[ "${DATASTORE}" == "all" ]]; then
        rounds=$(printf '%s\n' "${ROUNDS[@]}")
    else
        rounds=$(map_round "${DATASTORE}")
    fi

    local round=""
    local rc=0
    while IFS= read -r round; do
        [[ -n "${round}" ]] || continue
        log "dispatching ${round}"
        if "${round}"; then
            log "${round} ok"
        else
            rc=$?
            log "${round} failed with rc=${rc}"
            exit "${rc}"
        fi
    done <<<"${rounds}"

    log "regression driver complete"
    exit "${EXIT_OK}"
}

main "$@"
