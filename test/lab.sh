#!/usr/bin/env bash
# What the README promises, checked from inside the lab's own network and through docker exec,
# which is how the platform's terminal reaches the broker's tools: run by check.sh.
# The sensors' values depend on timing, so only their shape is asserted, never a number.
set -euo pipefail
: "${NET:?run through test/check.sh}"
: "${CID:?run through test/check.sh}"
probe() { docker run --rm --network "$NET" lab-check-probe bash -c "$1"; }
run() { docker exec "$CID" "$@"; }
fail() { echo "$1" >&2; exit 1; }

echo "- the broker accepts a connection from another machine in the lab, and there is no web page"
probe '
set -eu
(exec 3<>/dev/tcp/broker/1883) || { echo "broker port 1883 is closed" >&2; exit 1; }
if curl -s -m 3 -o /dev/null http://broker:80/; then echo "something answers on port 80" >&2; exit 1; fi
if (exec 3<>/dev/tcp/broker/8883) 2>/dev/null; then echo "an encrypted listener is open, the lab says it has none" >&2; exit 1; fi
'

echo "- home/# carries all four sensor topics"
out=$(run mosquitto_sub -t 'home/#' -v -C 8 -W 15) || fail "no 8 messages on home/# in 15 seconds"
for t in home/livingroom/temperature home/livingroom/humidity home/kitchen/temperature home/door/state; do
  echo "$out" | grep -q "^$t " || fail "no message on $t in: $out"
done

echo "- the readings have the shape the comment names"
out=$(run mosquitto_sub -t 'home/#' -v -C 12 -W 15)
echo "$out" | grep "^home/livingroom/temperature " | grep -Evq '^home/livingroom/temperature (20|21|22|23)$' && fail "a livingroom temperature outside 20 to 23: $out"
echo "$out" | grep "^home/livingroom/humidity " | grep -Evq '^home/livingroom/humidity (4[0-9])$' && fail "a humidity outside 40 to 49: $out"
echo "$out" | grep "^home/kitchen/temperature " | grep -Evq '^home/kitchen/temperature (18|19|20)$' && fail "a kitchen temperature outside 18 to 20: $out"
echo "$out" | grep "^home/door/state " | grep -Evq '^home/door/state (open|closed)$' && fail "a door state that is not open or closed: $out"
echo "  ok"

echo "- home/+/temperature reads only temperatures"
out=$(run mosquitto_sub -t 'home/+/temperature' -v -C 6 -W 15) || fail "no 6 temperatures in 15 seconds"
[ "$(echo "$out" | grep -c .)" = 6 ] || fail "not 6 lines: $out"
echo "$out" | grep -Evq '^home/(livingroom|kitchen)/temperature [0-9]+$' && fail "a message that is not a temperature: $out"

echo "- the kitchen temperature and the door state are retained: a new subscriber is handed one at once"
for t in home/kitchen/temperature home/door/state; do
  start=$(date +%s)
  out=$(run mosquitto_sub -t "$t" -v -C 1 -W 5 --retained-only) || fail "no retained message on $t"
  echo "$out" | grep -Eq "^$t [a-z0-9]+$" || fail "retained $t was: $out"
done

echo "- the livingroom readings are not retained"
out=$(run mosquitto_sub -t home/livingroom/temperature -v -W 3 --retained-only 2>/dev/null || true)
[ -z "$out" ] || fail "livingroom temperature is retained, the comment says it is not: $out"

echo "- a message of your own, retained, is handed to a later subscriber, then cleared"
run mosquitto_pub -t home/notes/first -r -m hello
out=$(run mosquitto_sub -t home/notes/first -v -C 1 -W 5 --retained-only) || fail "own retained message not handed back"
[ "$out" = "home/notes/first hello" ] || fail "own message came back as: $out"
run mosquitto_pub -t home/notes/first -r -n
out=$(run mosquitto_sub -t home/notes/first -v -W 2 --retained-only 2>/dev/null || true)
[ -z "$out" ] || fail "the message was not cleared: $out"

echo "- the broker is open: any client may write under any topic, as the comment says"
run mosquitto_pub -h 127.0.0.1 -t other/anything -m x

echo "- no way out to the internet"
if run sh -c 'nc -z -w 4 1.1.1.1 443'; then fail "the lab reached the internet"; fi
probe 'if curl -s -m 4 -o /dev/null https://example.com; then echo "the lab reached the internet" >&2; exit 1; fi'
echo "  ok"
