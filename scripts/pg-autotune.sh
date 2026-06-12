#!/bin/sh
#
# pg-autotune.sh — size-adaptive PostgreSQL startup wrapper for the `db` service.
#
# Stock `postgres:17-alpine` ships fixed, conservative defaults (shared_buffers
# 128MB, work_mem 4MB, effective_cache_size 4GB) regardless of how big the box
# is. This wrapper computes the key memory/parallelism settings from the
# resources actually available to the *container* at startup and execs Postgres
# with them, so the same image runs well on a 1GB box and a 128GB box with no
# per-server editing.
#
# How it plugs in: docker-compose.yml sets this as the `db` entrypoint. After
# computing `-c key=value` flags it execs the image's own `docker-entrypoint.sh
# postgres ...`, so first-boot initdb, the pgdata volume, and the healthcheck
# all behave exactly as before — this only appends runtime config flags. It
# never touches or migrates data.
#
# Resource detection (cgroup-aware):
#   - Memory: cgroup v2 /sys/fs/cgroup/memory.max, else cgroup v1
#     memory.limit_in_bytes, else host /proc/meminfo MemTotal. An "unlimited"
#     cgroup value (the literal `max`, or the v1 sentinel that exceeds physical
#     RAM) falls back to the host total. With no mem_limit set on the service the
#     container therefore sees the full host RAM.
#   - CPU: cgroup v2 /sys/fs/cgroup/cpu.max quota, else cgroup v1
#     cpu.cfs_quota_us/cpu.cfs_period_us, else `nproc`. No cpus limit => full host.
#
# Every computed parameter is individually overridable by an environment
# variable (PG_*). When an override is set it wins verbatim and the computed
# value is not applied. See README "Database tuning" and example.env for the
# full list. No absolute tuning value is hardcoded here — everything scales from
# detected resources via the fractions/floors/caps below (all themselves
# overridable).
#
# Sizing basis: PGTune "Web / OLTP" rules (https://pgtune.leopard.in.ua),
# adapted for Paperclip — which uses only 1-2 connections per server instance,
# so max_connections is deliberately left at the Postgres default (100) and the
# scaling path is memory/parallelism, not connection count.

set -eu

log() { echo "[pg-autotune] $*"; }

# ---------------------------------------------------------------------------
# Tunable knobs (override via env). These shape the formulas; they are not
# absolute Postgres values.
# ---------------------------------------------------------------------------
SHARED_BUFFERS_FRACTION="${PG_TUNE_SHARED_BUFFERS_FRACTION:-25}"      # % of RAM
SHARED_BUFFERS_FLOOR_MB="${PG_TUNE_SHARED_BUFFERS_FLOOR_MB:-128}"
SHARED_BUFFERS_CAP_MB="${PG_TUNE_SHARED_BUFFERS_CAP_MB:-16384}"       # don't over-reserve huge boxes
EFFECTIVE_CACHE_FRACTION="${PG_TUNE_EFFECTIVE_CACHE_FRACTION:-75}"    # % of RAM (planner hint)
MAINTENANCE_WORK_MEM_CAP_MB="${PG_TUNE_MAINTENANCE_WORK_MEM_CAP_MB:-2048}"
AUTOVACUUM_WORK_MEM_CAP_MB="${PG_TUNE_AUTOVACUUM_WORK_MEM_CAP_MB:-256}"
WORK_MEM_FLOOR_MB="${PG_TUNE_WORK_MEM_FLOOR_MB:-4}"
PARALLEL_PER_GATHER_CAP="${PG_TUNE_PARALLEL_PER_GATHER_CAP:-4}"
MAX_WAL_FLOOR_MB="${PG_TUNE_MAX_WAL_FLOOR_MB:-512}"
MAX_WAL_CAP_MB="${PG_TUNE_MAX_WAL_CAP_MB:-8192}"

# max_connections feeds the work_mem formula. Left at the Postgres default
# unless the operator explicitly overrides it (see non-goals: don't inflate it).
MAX_CONNECTIONS="${PG_MAX_CONNECTIONS:-100}"

# ---------------------------------------------------------------------------
# Detect available memory (MB) and CPUs.
# ---------------------------------------------------------------------------
host_mem_mb() { awk '/^MemTotal:/ { printf "%d", $2 / 1024; exit }' /proc/meminfo; }

cgroup_mem_bytes() {
    for f in /sys/fs/cgroup/memory.max /sys/fs/cgroup/memory/memory.limit_in_bytes; do
        [ -r "$f" ] || continue
        v=$(cat "$f" 2>/dev/null) || continue
        case "$v" in
            ''|max|*[!0-9]*) continue ;;   # unset / "max" / non-numeric => unlimited
        esac
        echo "$v"
        return 0
    done
    return 1
}

detect_mem_mb() {
    host=$(host_mem_mb)
    if cg=$(cgroup_mem_bytes); then
        # Compare in MB via awk to stay clear of 32-bit shell arithmetic.
        cg_mb=$(awk -v b="$cg" 'BEGIN { printf "%d", b / 1048576 }')
        # A real limit is positive and below physical RAM; otherwise it's the
        # cgroup "unlimited" sentinel and we use the host total.
        if [ "$cg_mb" -gt 0 ] && [ "$cg_mb" -lt "$host" ]; then
            echo "$cg_mb"
            return
        fi
    fi
    echo "$host"
}

detect_cpus() {
    cpus=""
    if [ -r /sys/fs/cgroup/cpu.max ]; then
        # Format: "<quota> <period>" or "max <period>".
        set -- $(cat /sys/fs/cgroup/cpu.max 2>/dev/null)
        q="${1:-max}"; p="${2:-0}"
        if [ "$q" != "max" ] && [ "$p" -gt 0 ] 2>/dev/null; then
            cpus=$(( (q + p - 1) / p ))   # ceil
        fi
    fi
    if [ -z "$cpus" ] && [ -r /sys/fs/cgroup/cpu/cpu.cfs_quota_us ]; then
        q=$(cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us 2>/dev/null || echo -1)
        p=$(cat /sys/fs/cgroup/cpu/cpu.cfs_period_us 2>/dev/null || echo 0)
        if [ "$q" -gt 0 ] 2>/dev/null && [ "$p" -gt 0 ] 2>/dev/null; then
            cpus=$(( (q + p - 1) / p ))
        fi
    fi
    if [ -z "$cpus" ] || [ "$cpus" -lt 1 ] 2>/dev/null; then
        cpus=$(nproc 2>/dev/null || echo 1)
    fi
    [ "$cpus" -ge 1 ] 2>/dev/null || cpus=1
    echo "$cpus"
}

# Detected totals, overridable (useful to reserve RAM for the app container,
# which shares the host, or to preview the tuning for a hypothetical box).
MEM_MB="${PG_TUNE_TOTAL_MEM_MB:-$(detect_mem_mb)}"
CPUS="${PG_TUNE_TOTAL_CPUS:-$(detect_cpus)}"

# ---------------------------------------------------------------------------
# Helpers.
# ---------------------------------------------------------------------------
clamp() { # value floor cap
    v=$1; lo=$2; hi=$3
    [ "$v" -lt "$lo" ] && v=$lo
    [ "$v" -gt "$hi" ] && v=$hi
    echo "$v"
}

ARGS=""
SUMMARY=""

# add_param <pg-name> <override-env-name> <computed-value>
# Emits the override verbatim when set, else the computed value.
add_param() {
    name=$1; env_name=$2; computed=$3
    override=$(eval "printf '%s' \"\${$env_name:-}\"")
    if [ -n "$override" ]; then
        val=$override; src="override"
    else
        val=$computed; src="auto"
    fi
    ARGS="$ARGS -c $name=$val"
    SUMMARY="$SUMMARY\n  $name = $val ($src)"
}

# ---------------------------------------------------------------------------
# Compute the parameters.
# ---------------------------------------------------------------------------
shared_buffers_mb=$(( MEM_MB * SHARED_BUFFERS_FRACTION / 100 ))
shared_buffers_mb=$(clamp "$shared_buffers_mb" "$SHARED_BUFFERS_FLOOR_MB" "$SHARED_BUFFERS_CAP_MB")
[ "$shared_buffers_mb" -gt "$MEM_MB" ] && shared_buffers_mb=$MEM_MB

effective_cache_mb=$(( MEM_MB * EFFECTIVE_CACHE_FRACTION / 100 ))
[ "$effective_cache_mb" -lt "$shared_buffers_mb" ] && effective_cache_mb=$shared_buffers_mb

maintenance_mb=$(( MEM_MB / 16 ))
maintenance_mb=$(clamp "$maintenance_mb" 64 "$MAINTENANCE_WORK_MEM_CAP_MB")

autovacuum_mb=$maintenance_mb
[ "$autovacuum_mb" -gt "$AUTOVACUUM_WORK_MEM_CAP_MB" ] && autovacuum_mb=$AUTOVACUUM_WORK_MEM_CAP_MB
[ "$autovacuum_mb" -lt 32 ] && autovacuum_mb=32

# Parallelism — scales with CPU count.
#   worker slots never drop below Postgres's stock default of 8, so small boxes
#   keep full background-worker capability; per-operation parallelism is half
#   the CPUs (capped) so a single query can't monopolise the box.
max_worker_processes=$CPUS
[ "$max_worker_processes" -lt 8 ] && max_worker_processes=8
max_parallel_workers=$CPUS
[ "$max_parallel_workers" -lt 8 ] && max_parallel_workers=8

per_gather=$(( CPUS / 2 ))
[ "$per_gather" -lt 1 ] && per_gather=1
[ "$per_gather" -gt "$PARALLEL_PER_GATHER_CAP" ] && per_gather=$PARALLEL_PER_GATHER_CAP
parallel_maintenance=$per_gather

# work_mem — conservative; it multiplies across concurrent sorts/hashes and
# parallel workers. Derived from available RAM, max_connections and parallelism.
divisor=$per_gather
[ "$divisor" -lt 1 ] && divisor=1
avail_kb=$(( (MEM_MB - shared_buffers_mb) * 1024 ))
[ "$avail_kb" -lt 0 ] && avail_kb=0
work_mem_kb=$(( avail_kb / (MAX_CONNECTIONS * 3 * divisor) ))
work_mem_floor_kb=$(( WORK_MEM_FLOOR_MB * 1024 ))
[ "$work_mem_kb" -lt "$work_mem_floor_kb" ] && work_mem_kb=$work_mem_floor_kb

# WAL/checkpoint — modest, RAM-aware.
max_wal_mb=$(( MEM_MB / 4 ))
max_wal_mb=$(clamp "$max_wal_mb" "$MAX_WAL_FLOOR_MB" "$MAX_WAL_CAP_MB")
min_wal_mb=$(( max_wal_mb / 4 ))
[ "$min_wal_mb" -lt 128 ] && min_wal_mb=128

# ---------------------------------------------------------------------------
# Assemble the postgres flags (override env wins for each).
# ---------------------------------------------------------------------------
add_param shared_buffers                   PG_SHARED_BUFFERS                   "${shared_buffers_mb}MB"
add_param effective_cache_size             PG_EFFECTIVE_CACHE_SIZE             "${effective_cache_mb}MB"
add_param maintenance_work_mem             PG_MAINTENANCE_WORK_MEM             "${maintenance_mb}MB"
add_param autovacuum_work_mem              PG_AUTOVACUUM_WORK_MEM              "${autovacuum_mb}MB"
add_param work_mem                         PG_WORK_MEM                         "${work_mem_kb}kB"
add_param max_worker_processes             PG_MAX_WORKER_PROCESSES             "$max_worker_processes"
add_param max_parallel_workers             PG_MAX_PARALLEL_WORKERS             "$max_parallel_workers"
add_param max_parallel_workers_per_gather  PG_MAX_PARALLEL_WORKERS_PER_GATHER  "$per_gather"
add_param max_parallel_maintenance_workers PG_MAX_PARALLEL_MAINTENANCE_WORKERS "$parallel_maintenance"
add_param random_page_cost                 PG_RANDOM_PAGE_COST                 "1.1"
add_param effective_io_concurrency         PG_EFFECTIVE_IO_CONCURRENCY         "200"
add_param min_wal_size                     PG_MIN_WAL_SIZE                     "${min_wal_mb}MB"
add_param max_wal_size                     PG_MAX_WAL_SIZE                     "${max_wal_mb}MB"
add_param checkpoint_completion_target     PG_CHECKPOINT_COMPLETION_TARGET     "0.9"

# max_connections: only emit when explicitly overridden — otherwise inherit the
# Postgres default (100), aligned with Paperclip's 1-2 connections/instance.
if [ -n "${PG_MAX_CONNECTIONS:-}" ]; then
    ARGS="$ARGS -c max_connections=$PG_MAX_CONNECTIONS"
    SUMMARY="$SUMMARY\n  max_connections = $PG_MAX_CONNECTIONS (override)"
else
    SUMMARY="$SUMMARY\n  max_connections = 100 (postgres default, untouched)"
fi

log "detected: ${MEM_MB}MB RAM, ${CPUS} CPU(s) available to the container"
# shellcheck disable=SC2059
printf "[pg-autotune] computed PostgreSQL settings:%b\n" "$SUMMARY"

# Dry-run hook: preview the settings without starting Postgres.
#   docker compose run --rm -e PG_TUNE_PRINT_ONLY=1 db
if [ -n "${PG_TUNE_PRINT_ONLY:-}" ]; then
    log "PG_TUNE_PRINT_ONLY set — not starting Postgres."
    log "would exec: docker-entrypoint.sh postgres$ARGS"
    exit 0
fi

# Full bypass: start Postgres untouched (operator opted out of auto-tuning).
if [ -n "${PG_TUNE_DISABLE:-}" ]; then
    log "PG_TUNE_DISABLE set — starting Postgres with image defaults."
    exec docker-entrypoint.sh postgres
fi

# Hand off to the image's own entrypoint so initdb / pgdata / healthcheck are
# unchanged; our computed flags are appended as server config.
# shellcheck disable=SC2086
exec docker-entrypoint.sh postgres $ARGS
