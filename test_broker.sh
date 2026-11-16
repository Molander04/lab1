#!/usr/bin/env bash
# Integration tests for the pub-sub broker.
#
# Usage:  ./test_broker.sh [port]        (default 8080)
#         SLOW=1 ./test_broker.sh        also runs the 30s long-poll timeout test
#
# Start the server first:  go run . 8080

PORT="${1:-8080}"
BASE="http://localhost:$PORT"
T="t$$"                      # unique topic prefix per run
TMP="$(mktemp -d)"
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

# req METHOD PATH [BODY] -> sets STATUS and BODY
req() {
  local out
  if [ $# -ge 3 ]; then
    out=$(curl -s -m 5 -X "$1" --data-binary "$3" -w '\n%{http_code}' "$BASE$2")
  else
    out=$(curl -s -m 5 -X "$1" -w '\n%{http_code}' "$BASE$2")
  fi
  STATUS="${out##*$'\n'}"
  BODY="${out%$'\n'*}"
  BODY="${BODY%$'\n'}"   # drop the server's own trailing newline
}

ok()   { PASS=$((PASS + 1)); echo "  ok    $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL  $1"; echo "        $2"; }

assert_status() { # name expected
  if [ "$STATUS" = "$2" ]; then ok "$1"; else fail "$1" "expected status $2, got $STATUS (body: $BODY)"; fi
}

assert_body() { # name expected-exact-body
  if [ "$BODY" = "$2" ]; then ok "$1"; else fail "$1" "expected body '$2', got '$BODY'"; fi
}

assert_eq() { # name expected actual
  if [ "$2" = "$3" ]; then ok "$1"; else fail "$1" "expected '$2', got '$3'"; fi
}

json_int() { # field -> value from $BODY
  echo "$BODY" | sed -nE "s/.*\"$1\":([0-9]+).*/\1/p"
}

subscribe() { # topic -> prints id
  req POST "/subscribe?topic=$1"
  json_int id
}

echo "Testing broker at $BASE"

# ---------------------------------------------------------------- subscribe
echo "== subscribe"
req POST "/subscribe?topic=$T-a"
assert_status "subscribe returns 201" 201
ID_A=$(json_int id)
[ -n "$ID_A" ] && ok "subscribe returns an id ($ID_A)" || fail "subscribe returns an id" "$BODY"

ID_A2=$(subscribe "$T-a")
[ "$ID_A2" != "$ID_A" ] && ok "ids are unique" || fail "ids are unique" "both $ID_A"

req POST "/subscribe"
assert_status "subscribe without topic -> 400" 400
req POST "/subscribe?topic="
assert_status "subscribe with empty topic -> 400" 400

# ------------------------------------------------------------ wrong methods
echo "== methods"
req GET "/subscribe?topic=$T-a"
assert_status "GET /subscribe -> 501" 501
req GET "/publish?topic=$T-a"
assert_status "GET /publish -> 501" 501
req GET "/unsubscribe?topic=$T-a&id=$ID_A"
assert_status "GET /unsubscribe -> 501" 501
req POST "/events?topic=$T-a&id=$ID_A"
assert_status "POST /events -> 501" 501

# ------------------------------------------------------------------ publish
echo "== publish"
req POST "/publish?topic=$T-empty" "nobody home"
assert_status "publish with no subscribers -> 200" 200
assert_body "  seq 1, delivered 0" '{"delivered":0,"seq":1}'

req POST "/publish?topic=$T-empty" "again"
assert_body "sequence increments per topic" '{"delivered":0,"seq":2}'

req POST "/publish" "x"
assert_status "publish without topic -> 400" 400

req POST "/publish?topic=$T-a" "hello"
assert_status "publish to topic with 2 subscribers" 200
assert_body "  seq 1, delivered 2" '{"delivered":2,"seq":1}'

# ------------------------------------------------------------------- events
echo "== events"
req GET "/events?topic=$T-a&id=$ID_A"
assert_status "events returns queued message" 200
assert_body "  seq and message correct" '{"seq":1,"message":"hello"}'

req GET "/events?topic=$T-a&id=$ID_A2"
assert_body "second subscriber got the same message" '{"seq":1,"message":"hello"}'

req POST "/publish?topic=$T-a" 'quote " and \ backslash'
req GET "/events?topic=$T-a&id=$ID_A"
assert_body "special characters are JSON-escaped" '{"seq":2,"message":"quote \" and \\ backslash"}'

req GET "/events?topic=$T-a"
assert_status "events without id -> 400" 400
req GET "/events?topic=$T-a&id=abc"
assert_status "events with non-numeric id -> 400" 400
req GET "/events?topic=$T-a&id=0"
assert_status "events with id=0 -> 400" 400
req GET "/events?topic=$T-a&id=-5"
assert_status "events with negative id -> 400" 400
req GET "/events?topic=$T-a&id=999999"
assert_status "events with unknown id -> 404" 404
req GET "/events?topic=$T-other&id=$ID_A"
assert_status "events with id on the wrong topic -> 404" 404

# ----------------------------------------------------------- topic isolation
echo "== topic isolation"
ID_X=$(subscribe "$T-x")
ID_Y=$(subscribe "$T-y")
req POST "/publish?topic=$T-x" "for x only"
assert_body "publish only reaches that topic" '{"delivered":1,"seq":1}'
req GET "/events?topic=$T-x&id=$ID_X"
assert_body "x subscriber receives it" '{"seq":1,"message":"for x only"}'
# y must have nothing queued: a short poll should time out client-side
code=$(curl -s -m 1 -o /dev/null -w '%{http_code}' "$BASE/events?topic=$T-y&id=$ID_Y")
assert_eq "y subscriber receives nothing" "000" "$code"

# ----------------------------------------------------------------- ordering
echo "== ordering"
ID_O=$(subscribe "$T-ord")
for i in 1 2 3 4 5; do req POST "/publish?topic=$T-ord" "m$i"; done
seqs=""
for i in 1 2 3 4 5; do
  req GET "/events?topic=$T-ord&id=$ID_O"
  seqs="$seqs$(json_int seq)"
done
assert_eq "messages arrive in sequence order" "12345" "$seqs"

# --------------------------------------------------------------- long polling
echo "== long polling"
ID_L=$(subscribe "$T-long")
curl -s -m 10 -w '\n%{http_code}' "$BASE/events?topic=$T-long&id=$ID_L" > "$TMP/poll1" &
POLL_PID=$!
sleep 1
if kill -0 $POLL_PID 2>/dev/null; then ok "poll is held open while queue is empty"; else fail "poll is held open" "returned early: $(cat "$TMP/poll1")"; fi
req POST "/publish?topic=$T-long" "wake up"
wait $POLL_PID
assert_eq "waiting poll receives published message" '{"seq":1,"message":"wake up"}' "$(head -n1 "$TMP/poll1")"

# --------------------------------------------------------------- unsubscribe
echo "== unsubscribe"
ID_U=$(subscribe "$T-unsub")

curl -s -m 10 -w '\n%{http_code}' "$BASE/events?topic=$T-unsub&id=$ID_U" > "$TMP/poll2" &
POLL_PID=$!
sleep 1
req POST "/unsubscribe?topic=$T-unsub&id=$ID_U"
assert_status "unsubscribe -> 200" 200
assert_body "  body is OK" "OK"
wait $POLL_PID
assert_eq "unsubscribe wakes waiting poll with 404" "404" "$(tail -n1 "$TMP/poll2")"

req POST "/unsubscribe?topic=$T-unsub&id=$ID_U"
assert_status "unsubscribe twice -> 404" 404
req GET "/events?topic=$T-unsub&id=$ID_U"
assert_status "events after unsubscribe -> 404" 404
req POST "/publish?topic=$T-unsub" "gone"
assert_body "publish after unsubscribe delivers to nobody" '{"delivered":0,"seq":1}'

req POST "/unsubscribe?topic=$T-unsub"
assert_status "unsubscribe without id -> 400" 400
req POST "/unsubscribe?id=1"
assert_status "unsubscribe without topic -> 400" 400
ID_W=$(subscribe "$T-w")
req POST "/unsubscribe?topic=$T-notw&id=$ID_W"
assert_status "unsubscribe with wrong topic -> 404" 404
req GET "/events?topic=$T-w&id=$ID_W" >/dev/null 2>&1 &  # leave it; just confirm still subscribed
req POST "/publish?topic=$T-w" "still here"
assert_body "wrong-topic unsubscribe did not remove subscriber" '{"delivered":1,"seq":1}'

# ---------------------------------------------------------------- queue full
echo "== bounded queue (64)"
ID_Q=$(subscribe "$T-full")
last_ok=""
first_dropped=""
for i in $(seq 1 70); do
  req POST "/publish?topic=$T-full" "n$i"
  d=$(json_int delivered)
  [ "$i" = 64 ] && last_ok="$d"
  [ "$i" = 65 ] && first_dropped="$d"
done
assert_eq "message 64 still delivered" "1" "$last_ok"
assert_eq "message 65 dropped (queue full, publish did not block)" "0" "$first_dropped"
req GET "/events?topic=$T-full&id=$ID_Q"
assert_eq "oldest message is first out" "1" "$(json_int seq)"
for i in $(seq 2 63); do req GET "/events?topic=$T-full&id=$ID_Q"; done
req GET "/events?topic=$T-full&id=$ID_Q"
assert_eq "64th and last queued message is seq 64" "64" "$(json_int seq)"

# ------------------------------------------- worker slots (semaphore, 10)
echo "== waiting polls release their worker slot"
# 12 concurrent long polls > 10 workers. If polls kept their slots, the
# publish below would never be accepted.
ID_S=$(subscribe "$T-slots")
PIDS=""
for i in $(seq 1 12); do
  curl -s -m 20 -o /dev/null "$BASE/events?topic=$T-slots&id=$ID_S" &
  PIDS="$PIDS $!"
done
sleep 1
req POST "/publish?topic=$T-slots" "got a slot"
assert_status "publish succeeds with 12 polls waiting" 200
req POST "/unsubscribe?topic=$T-slots&id=$ID_S"   # wakes all the pollers
wait $PIDS 2>/dev/null

# Run more than 10 normal requests afterwards: a double release would let
# extra workers through, a leaked slot would eventually hang the server.
okcount=0
for i in $(seq 1 30); do
  req POST "/publish?topic=$T-slots" "x"
  [ "$STATUS" = 200 ] && okcount=$((okcount + 1))
done
assert_eq "server still healthy after polls finish (30 requests)" "30" "$okcount"

# ------------------------------------------------------------ poll timeout
if [ "${SLOW:-0}" = 1 ]; then
  echo "== poll timeout (30s)"
  ID_T=$(subscribe "$T-timeout")
  code=$(curl -s -m 40 -o /dev/null -w '%{http_code}' "$BASE/events?topic=$T-timeout&id=$ID_T")
  assert_eq "idle poll returns 204 after timeout" "204" "$code"
else
  echo "== poll timeout: skipped (run with SLOW=1 to include)"
fi

# ------------------------------------------------------------------- summary
echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ]