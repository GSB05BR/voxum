#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Checks scripts/with-eval-slot.sh on a private slot root (never the shared one):
#   1. 5 parallel jobs → at most 3 at once, all 5 run, no lock left behind;
#   2. a lock whose holder is gone is taken over; a live one is not;
#   3. a lock without heartbeat for > 10 min is taken over;
#   4. a run whose lock was taken over does not delete the new owner's lock on exit.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
slot_cmd="$here/with-eval-slot.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/eval-slot-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
export VOXUM_EVAL_SLOTS_DIR="$work/slots" VOXUM_EVAL_SLOTS_POLL=0.2
fail() { echo "FAIL: $*" >&2; exit 1; }

# 1. Concurrency cap.
mkdir -p "$work/running"
job() {
    "$slot_cmd" sh -c '
        touch "$1/running/$2"
        ls "$1/running" | wc -l | tr -d " " >> "$1/counts"
        sleep 1
        rm "$1/running/$2"
        echo done >> "$1/done"' _ "$work" "$1" 2>/dev/null
}
for n in 1 2 3 4 5; do job "$n" & done
wait
max=$(sort -n "$work/counts" | tail -1)
[ "$(wc -l < "$work/done" | tr -d ' ')" = 5 ] || fail "not every job ran"
[ "$max" -le 3 ] || fail "$max jobs ran at once"
[ -z "$(ls "$work/slots")" ] || fail "locks left behind: $(ls "$work/slots")"
echo "ok: 5 jobs, at most $max at once, no lock left"

# 2. Dead holder → taken over; live holder → kept.
dead_pid=$(sh -c 'echo $$')
for i in 1 2; do mkdir "$work/slots/slot-$i"; echo "live $$ test" > "$work/slots/slot-$i/owner"; done
mkdir "$work/slots/slot-3"; echo "dead $dead_pid test" > "$work/slots/slot-3/owner"
out=$("$slot_cmd" sh -c 'cat "$VOXUM_EVAL_SLOTS_DIR/slot-3/owner"' 2>&1)
case "$out" in *"took over stale slot-3"*) ;; *) fail "dead holder's lock not taken over: $out" ;; esac
[ "$(cut -d' ' -f1 "$work/slots/slot-1/owner")" = live ] || fail "a live lock was taken"
[ ! -e "$work/slots/slot-3" ] || fail "slot-3 not released"
echo "ok: dead holder taken over, live holders kept"

# 3. No heartbeat for > 10 min → taken over (holder looks alive: our own pid).
mkdir "$work/slots/slot-3"; echo "old $$ test" > "$work/slots/slot-3/owner"
touch -t "$(date -v-11M +%Y%m%d%H%M.%S)" "$work/slots/slot-3"
out=$("$slot_cmd" true 2>&1)
case "$out" in *"took over stale slot-3"*) ;; *) fail "lock without heartbeat not taken over: $out" ;; esac
rm -rf "$work/slots"/slot-*
echo "ok: lock without heartbeat taken over"

# 4. Exit after losing the lock leaves the new owner's lock alone.
"$slot_cmd" sh -c '
    slot="$VOXUM_EVAL_SLOTS_DIR/slot-1"
    echo "someone-else 1 x" > "$slot/owner"' 2>/dev/null
[ "$(cut -d' ' -f1 "$work/slots/slot-1/owner" 2>/dev/null)" = someone-else ] || fail "removed a lock it no longer owned"
echo "ok: a lost lock is not removed on exit"
echo "all eval-slot checks passed"
