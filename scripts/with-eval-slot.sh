#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Runs a command while holding one of 3 eval slots, so parallel agents never run more than 3
# Qwen evals at once (each loads its own ~2.4 GB model):
#   scripts/with-eval-slot.sh swift run -c release tcli eval fixtures/cases-en.json --lang en
#
# A slot is a directory lock, /tmp/voxum-eval-slots/slot-N, created atomically by mkdir. The root
# is fixed (not $TMPDIR), so every shell, worktree and agent shares it; VOXUM_EVAL_SLOTS_DIR
# overrides it (tests). The holder writes "<token> <pid> <command>" to slot-N/owner and touches
# the directory every minute while the command runs. A lock is stale when its holder's process is
# gone, or when it has not been touched for 10 min; a stale lock is taken over under a per-slot
# takeover lock (mkdir slot-N.takeover), re-checked there and moved away atomically (mv), so two
# waiters never take the same slot. On exit the slot is removed only if it still holds our token.
set -euo pipefail
[ $# -gt 0 ] || { echo "usage: $0 <command> [args…]" >&2; exit 2; }

ROOT="${VOXUM_EVAL_SLOTS_DIR:-/tmp/voxum-eval-slots}"
SLOTS=3
POLL="${VOXUM_EVAL_SLOTS_POLL:-5}"
HEARTBEAT=60
STALE_SECONDS=$((10 * 60))
TAKEOVER_STALE_SECONDS=120
TOKEN="$$-$RANDOM$RANDOM-$(date +%s)"
mkdir -p "$ROOT"

age() { # seconds since the path was modified (huge if it is gone)
    local mtime
    mtime=$(stat -f %m "$1" 2>/dev/null || echo 0)
    echo $(( $(date +%s) - mtime ))
}

owner_token() { cut -d' ' -f1 "$1/owner" 2>/dev/null || true; }

is_stale() {
    local dir=$1 pid
    [ -d "$dir" ] || return 1
    pid=$(cut -d' ' -f2 "$dir/owner" 2>/dev/null || true)
    if [ -n "$pid" ] && ! ps -p "$pid" >/dev/null 2>&1; then return 0; fi # holder is gone
    [ "$(age "$dir")" -gt "$STALE_SECONDS" ]                                # no heartbeat
}

take_over() {
    local dir=$1 guard="$1.takeover" reaped
    if [ -d "$guard" ] && [ "$(age "$guard")" -gt "$TAKEOVER_STALE_SECONDS" ]; then
        rmdir "$guard" 2>/dev/null || true # a waiter died mid-takeover
    fi
    mkdir "$guard" 2>/dev/null || return 1
    local won=1
    if is_stale "$dir"; then # re-checked under the takeover lock
        reaped="$ROOT/.reaped-${dir##*/}-$TOKEN"
        if mv "$dir" "$reaped" 2>/dev/null; then
            rm -rf "$reaped"
            if mkdir "$dir" 2>/dev/null; then won=0; fi
        fi
    fi
    rmdir "$guard" 2>/dev/null || true
    return $won
}

slot=""
waited=0
while [ -z "$slot" ]; do
    for i in $(seq 1 "$SLOTS"); do
        dir="$ROOT/slot-$i"
        if mkdir "$dir" 2>/dev/null; then
            slot="$dir"
            break
        fi
        if is_stale "$dir" && take_over "$dir"; then
            echo "with-eval-slot: took over stale ${dir##*/}" >&2
            slot="$dir"
            break
        fi
    done
    if [ -z "$slot" ]; then
        [ "$waited" -eq 0 ] && echo "with-eval-slot: all $SLOTS slots busy, waiting…" >&2
        waited=1
        sleep "$POLL"
    fi
done

heartbeat_pid=""
release() {
    [ -n "$heartbeat_pid" ] && kill "$heartbeat_pid" 2>/dev/null || true
    if [ "$(owner_token "$slot")" = "$TOKEN" ]; then rm -rf "$slot"; fi
}
trap release EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
echo "$TOKEN $$ $*" > "$slot/owner"

# Heartbeat: keeps a long run's lock fresh; stops once the lock is no longer ours.
( nap=""
  trap 'kill "$nap" 2>/dev/null; exit 0' TERM
  while :; do
      sleep "$HEARTBEAT" & nap=$!
      wait "$nap"
      [ "$(owner_token "$slot")" = "$TOKEN" ] || exit 0
      touch "$slot"
  done ) &
heartbeat_pid=$!

echo "with-eval-slot: holding ${slot##*/}" >&2
"$@"
