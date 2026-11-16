#!/usr/bin/env bash
# part 1 tests - file server
# run server first: ./http_server 8080
# then: ./test_server.sh 8080

PORT=${1:-8080}
URL="http://localhost:$PORT"
DIR="testfiles"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP" "www/$DIR"' EXIT   # cleanup at end

PASS=0
FAIL=0

# compare expected vs actual
check() {
  if [ "$2" = "$3" ]; then
    echo "  ok    $1"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $1  (expected '$2', got '$3')"
    FAIL=$((FAIL + 1))
  fi
}

# send request, give status code
status() {
  curl -s -m 5 -o /dev/null -w '%{http_code}' --path-as-is -X "$1" "$URL$2"
}

# post a file, give status code
post() {
  curl -s -m 5 -o /dev/null -w '%{http_code}' --path-as-is --data-binary "@$1" "$URL$2"
}

# send raw text over tcp, give first reply line
# curl cant send broken requests, so this
raw() {
  exec 3<>"/dev/tcp/localhost/$PORT"
  printf "$1" >&3
  timeout 5 head -n 1 <&3 | tr -d '\r'
  exec 3>&-
}

# get
echo "== GET"
check "existing file -> 200"           200       "$(status GET /index.html)"
check "content type of .html"          text/html "$(curl -s -o /dev/null -w '%{content_type}' "$URL/index.html")"
check "missing file -> 404"            404       "$(status GET /nope.html)"

# all file types - post random bytes, get back, compare
echo "== every allowed file type (POST, then GET it back)"
for pair in "html text/html" "txt text/plain" "gif image/gif" \
            "jpeg image/jpeg" "jpg image/jpeg" "css text/css"; do
  set -- $pair
  head -c 1000 /dev/urandom > "$TMP/sent"
  check "POST .$1 -> 200" 200 "$(post "$TMP/sent" "/$DIR/file.$1")"
  type=$(curl -s -o "$TMP/got" -w '%{content_type}' "$URL/$DIR/file.$1")
  check "  GET .$1 has type $2" "$2" "$type"
  cmp -s "$TMP/sent" "$TMP/got" && same=yes || same=no
  check "  GET .$1 returns exactly what was posted" yes "$same"
done

# bad endings
echo "== bad file endings -> 400"
for p in /file.pdf /noending /; do
  check "GET $p -> 400" 400 "$(status GET "$p")"
done
check "POST .sh -> 400"                400 "$(post "$TMP/sent" "/$DIR/evil.sh")"

# other methods
echo "== other methods -> 501"
for m in PUT DELETE HEAD; do
  check "$m -> 501" 501 "$(status "$m" /index.html)"
done

# broken requests
echo "== broken requests -> 400"
check "random text"                    "HTTP/1.1 400 Bad Request" "$(raw 'hello\r\n\r\n')"
check "header line without a colon"    "HTTP/1.1 400 Bad Request" "$(raw 'GET /index.html HTTP/1.1\r\nno colon here\r\n\r\n')"

# ../ tricks
echo "== cannot escape the www folder"
check "GET /../../etc/passwd.txt -> 404" 404 "$(status GET /../../etc/passwd.txt)"
post "$TMP/sent" "/../../$DIR/escape.txt" > /dev/null
[ -e "www/$DIR/escape.txt" ] && inside=yes || inside=no
check "POST to /../../ is saved inside www" yes "$inside"

# post
echo "== POST"
echo "version 1" > "$TMP/v1"
echo "version 2" > "$TMP/v2"
post "$TMP/v1" "/$DIR/notes.txt" > /dev/null
check "POST then GET returns the content" "version 1" "$(curl -s "$URL/$DIR/notes.txt")"
post "$TMP/v2" "/$DIR/notes.txt" > /dev/null
check "second POST replaces the file"     "version 2" "$(curl -s "$URL/$DIR/notes.txt")"
check "POST into a new subfolder -> 200"  200 "$(post "$TMP/v1" "/$DIR/new/page.html")"
head -c 11000000 /dev/zero > "$TMP/big"   # 11mb, limit 10mb
check "POST bigger than 10 MB -> 400"     400 "$(post "$TMP/big" "/$DIR/big.txt")"

# many clients same time
echo "== many clients at once"
for i in $(seq 1 30); do
  status GET /index.html &
done > "$TMP/codes"
wait
check "30 parallel GETs all return 200" 30 "$(grep -o 200 "$TMP/codes" | wc -l | tr -d ' ')"

# atomic write
# each writer sends 100000 x one letter
# readers must get one letter only, full size
echo "== atomic writes: 10 writers + 30 readers on the same file"
for c in a b c d e f g h i j; do
  head -c 100000 /dev/zero | tr '\0' "$c" > "$TMP/$c"
done
post "$TMP/a" "/$DIR/race.txt" > /dev/null
for c in a b c d e f g h i j; do post "$TMP/$c" "/$DIR/race.txt" > /dev/null & done
for i in $(seq 1 30); do curl -s -o "$TMP/read$i" "$URL/$DIR/race.txt" & done
wait
broken=0
for i in $(seq 1 30); do
  f="$TMP/read$i"
  letter=$(head -c 1 "$f")
  leftover=$(tr -d "$letter" < "$f" | wc -c)   # other letters = mixed
  size=$(wc -c < "$f")                         # wrong size = half written
  [ "$leftover" -eq 0 ] && [ "$size" -eq 100000 ] || broken=$((broken + 1))
done
check "every read is one complete version" 0 "$broken"

# max 10 at a time
# 10 silent clients take all slots, 11th waits
# after 10s read timeout server ok again
echo "== max 10 clients at a time (takes ~12 seconds)"
for i in $(seq 1 10); do
  (exec 3<>"/dev/tcp/localhost/$PORT"; sleep 12) &
done
sleep 1
check "11th client has to wait"        000 "$(curl -s -m 3 -o /dev/null -w '%{http_code}' "$URL/index.html")"
check "after the 10s read timeout, server works again" \
                                       200 "$(curl -s -m 15 -o /dev/null -w '%{http_code}' "$URL/index.html")"
wait

echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ]
