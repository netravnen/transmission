#!/usr/bin/env bash
# Reproduce transmission/transmission#9151 on a clean transmission-daemon,
# following the issue's "Procedure to reproduce", steps 1 to 8.
#
# usage: repro-9151.sh <official|ntrv> <results.json>
#
#   official  expects: step 4 ok, step 6 mismatch, step 8 ok
#   ntrv      expects: step 4 ok, step 6 ok,       step 8 ok
#
# The daemon runs with its own config and data directory, DHT, LPD and PEX
# off, and no reachable tracker, so the only peer is the local BEP 9 client.

set -euo pipefail

VARIANT=$1
OUT=$2
HERE=$(cd "$(dirname "$0")" && pwd)
FETCH="python3 $HERE/bep9_fetch.py"
BASE=$(mktemp -d)
CONF=$BASE/config
DATA=$BASE/data
PORT=51413
RPC="transmission-remote 127.0.0.1:9091"
TEST_TRACKER=http://tracker.example.invalid:6969/announce
mkdir -p "$CONF" "$DATA"

cat > "$CONF/settings.json" <<EOF
{
  "rpc-authentication-required": false,
  "rpc-whitelist-enabled": true,
  "rpc-whitelist": "127.0.0.1,::1",
  "rpc-port": 9091,
  "peer-port": $PORT,
  "peer-port-random-on-start": false,
  "dht-enabled": false,
  "lpd-enabled": false,
  "pex-enabled": false,
  "port-forwarding-enabled": false,
  "encryption": 1,
  "download-dir": "$DATA",
  "incomplete-dir-enabled": false,
  "start-added-torrents": true
}
EOF

DPID=
start_daemon() {
  transmission-daemon -f -g "$CONF" >>"$BASE/daemon.log" 2>&1 &
  DPID=$!
  for _ in $(seq 1 60); do $RPC -l >/dev/null 2>&1 && return 0; sleep 1; done
  echo "daemon did not answer RPC"; cat "$BASE/daemon.log"; return 1
}
stop_daemon() { kill "$DPID"; wait "$DPID" || true; }
wait_seeding() {
  for _ in $(seq 1 120); do
    info=$($RPC -t 1 -i 2>/dev/null || true)
    if grep -q 'Percent Done: 100%' <<<"$info" && grep -Eq 'State: (Seeding|Idle)' <<<"$info"; then return 0; fi
    sleep 1
  done
  echo "torrent did not reach seeding"; $RPC -t 1 -i || true; return 1
}
fetch_retry() {
  local out rc
  for attempt in 1 2 3 4; do
    set +e; out=$($FETCH fetch 127.0.0.1 "$PORT" "$IH"); rc=$?; set -e
    [ "$rc" -ne 2 ] && break
    echo "  attempt $attempt: $out" >&2
    sleep 15
  done
  echo "$out"
}
stored_torrent_size() { stat -c %s "$CONF"/torrents/*.torrent; }

echo "== $VARIANT: $(transmission-daemon --version 2>&1 | head -1); package $(dpkg-query -W -f '${Version}' transmission-daemon)"

# Step 1: start transmission-daemon.
start_daemon

# Step 2: add a public torrent from a .torrent file, not a magnet link.
# 40 MiB of random data in 16 KiB pieces: 2560 pieces, about 51 KB of
# metadata, so the metadata spans several BEP 9 pieces.
head -c 41943040 /dev/urandom > "$DATA/repro-9151.bin"
transmission-create -o "$BASE/repro-9151.torrent" -s 16 -t http://tracker-a.example.invalid:6969/announce "$DATA/repro-9151.bin" >/dev/null
IH=$($FETCH hash "$BASE/repro-9151.torrent")
$RPC -a "$BASE/repro-9151.torrent" -w "$DATA" >/dev/null

# Step 3: start the torrent; make sure it is seeding. The data is already in
# place, so verify it first rather than wait for a download that has no peer.
$RPC -t 1 -v >/dev/null
sleep 2
$RPC -t 1 -s >/dev/null
wait_seeding

# Step 4: request the metadata through ut_metadata. Expected: hash equal.
R4=$(fetch_retry); echo "step 4: $R4"

# Step 5: add a tracker.
SIZE_BEFORE=$(stored_torrent_size)
$RPC -t 1 --tracker-add "$TEST_TRACKER" >/dev/null
sleep 2
SIZE_AFTER=$(stored_torrent_size)
echo "step 5: stored .torrent $SIZE_BEFORE -> $SIZE_AFTER bytes"

# Step 6: step 4 again.
R6=$(fetch_retry); echo "step 6: $R6"

# Step 7: restart the daemon.
stop_daemon
start_daemon
wait_seeding

# Step 8: step 4 again.
R8=$(fetch_retry); echo "step 8: $R8"

stop_daemon

python3 - "$VARIANT" "$OUT" "$IH" "$SIZE_BEFORE" "$SIZE_AFTER" "$R4" "$R6" "$R8" <<'PY'
import json, sys
variant, out, ih, sb, sa, r4, r6, r8 = sys.argv[1:9]
r4, r6, r8 = (json.loads(x) for x in (r4, r6, r8))
expected = {'official': ('ok', 'mismatch', 'ok'), 'ntrv': ('ok', 'ok', 'ok')}[variant]
got = (r4['status'], r6['status'], r8['status'])
res = {'variant': variant, 'info_hash': ih, 'stored_torrent_bytes': [int(sb), int(sa)],
       'step4': r4, 'step6': r6, 'step8': r8, 'expected': expected, 'got': got, 'as_expected': got == expected}
json.dump(res, open(out, 'w'), indent=2)
print(json.dumps({'variant': variant, 'expected': expected, 'got': got, 'step6_shift': r6.get('shift'),
                  'stored_torrent_bytes': [int(sb), int(sa)], 'as_expected': got == expected}))
sys.exit(0 if got == expected else 1)
PY
