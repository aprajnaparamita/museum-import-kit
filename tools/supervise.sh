#!/bin/bash
# Supervises a museum import run.
#
# Handles two distinct failure modes:
#
# 1. Luanti 5.16.1 intermittently dies with an uncaught DatabaseException
#    ("cannot commit transaction - SQL statements in progress") under
#    sustained heavy write load. The import is checkpointed in
#    spawnimport's registry -- a base only lands there once fully placed --
#    so restarting resumes rather than duplicating.
#
# 2. The world lives on an external USB drive, and a nudged cable makes the
#    whole volume vanish: the server takes SIGBUS on its memory-mapped
#    database and even getcwd() starts failing. Retrying instantly against
#    a missing volume just burns the stall counter and aborts a run that
#    would be fine ten seconds later, so wait for the volume to come back
#    instead of counting those as failed attempts.
#
# usage: supervise.sh <world> <logfile> <target_bases> <max_restarts>
WORLD="$1"; LOG="$2"; TARGET="$3"; MAX="${4:-100}"
CONF="${IMPORT_CONF:-$(dirname "$0")/import.conf}"
LUANTI="${LUANTI_BIN:-luantiserver}"

# Never sit in the world's own filesystem: if the drive drops, the shell's
# cwd becomes invalid and every subsequent command fails with getcwd errors.
cd /private/tmp || exit 1

placed () {
  python3 - "$WORLD/mod_storage.sqlite" <<'PY'
import sqlite3, re, sys
try:
    con = sqlite3.connect('file:%s?mode=ro' % sys.argv[1], uri=True)
    for _mn, k, v in con.execute('SELECT modname,key,value FROM entries'):
        k = k.decode() if isinstance(k, bytes) else k
        if k == 'placed_bases':
            s = v.decode() if isinstance(v, bytes) else v
            print(len(re.findall(r'name="', s))); break
    else: print(0)
except Exception: print(-1)
PY
}

# Blocks until the world is actually reachable again (drive re-mounted and
# the database readable). Returns 1 if it never comes back.
wait_for_volume () {
  local waited=0
  while [ ! -r "$WORLD/world.mt" ]; do
    if [ "$waited" -eq 0 ]; then
      echo "[supervisor] WORLD UNREACHABLE (drive disconnected?) -- waiting for it to return"
    fi
    sleep 10
    waited=$((waited + 10))
    if [ "$waited" -ge 3600 ]; then
      echo "[supervisor] ABORT: world still unreachable after 60 minutes"
      return 1
    fi
  done
  if [ "$waited" -gt 0 ]; then
    echo "[supervisor] world reachable again after ${waited}s -- resuming"
    sleep 5   # let the mount settle before hammering it
  fi
  return 0
}

stall=0
for attempt in $(seq 1 "$MAX"); do
  wait_for_volume || exit 1
  n=$(placed)
  if [ "$n" -lt 0 ]; then
    echo "[supervisor] registry unreadable -- treating as volume problem"
    sleep 10; continue
  fi
  if [ "$n" -ge "$TARGET" ]; then
    echo "[supervisor] COMPLETE: $n/$TARGET bases placed"; exit 0
  fi
  echo "[supervisor] attempt $attempt: $n/$TARGET placed, starting server $(date '+%H:%M:%S')"
  "$LUANTI" --server --config "$CONF" --world "$WORLD" --gameid mineclonia \
    --logfile "$LOG" < /dev/null >> "${LOG%.log}.out" 2>&1
  rc=$?

  # A vanished volume is not a failed attempt -- don't let it burn the
  # stall counter (that is what aborted the run at 02:57).
  if [ ! -r "$WORLD/world.mt" ]; then
    echo "[supervisor] server exited rc=$rc with the world unreachable -- drive dropped, not a stall"
    continue
  fi

  after=$(placed)
  echo "[supervisor] server exited rc=$rc, $after/$TARGET placed $(date '+%H:%M:%S')"
  if [ "$after" -ge "$TARGET" ]; then
    echo "[supervisor] COMPLETE: $after/$TARGET bases placed"; exit 0
  fi
  if [ "$after" -le "$n" ]; then
    stall=$((stall + 1))
    echo "[supervisor] WARNING: no progress this attempt (stall=$stall)"
    if [ "$stall" -ge 3 ]; then
      echo "[supervisor] ABORT: 3 consecutive attempts with no progress"; exit 1
    fi
  else
    stall=0
  fi
  sleep 3
done
echo "[supervisor] ABORT: hit max restarts ($MAX)"; exit 1
