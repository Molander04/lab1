# Lab 1 - HTTP Server and Pub-Sub Broker

Simple HTTP server in Go. Serves files with GET, saves files with POST.
Also has a small pub-sub broker on the same port.

No frameworks. Networking is done with `net`. `net/http` is only used to read requests.

## Files

| File | What it does |
|---|---|
| `main.go` | Starts server, listens on port, max 10 clients at a time |
| `server.go` | Reads request, GET / POST files, sends response |
| `broker.go` | Pub-sub: subscribe, unsubscribe, publish, events |
| `www/` | Files are served from here and saved here |
| `test_server.sh` | Tests for part 1 (file server) |
| `test_broker.sh` | Tests for part 2 (broker) |
| `run_tests.sh` | Runs both test scripts |

## Run

```bash
go build -o http_server .
./http_server 8080
```

With Docker:

```bash
docker compose up --build
```

## Test

Start the server first, then in another terminal:

```bash
./run_tests.sh 8080
```

Broker 30s timeout test too:

```bash
SLOW=1 ./test_broker.sh 8080
```

## Part 1 - file server

- `GET /file.html` - send the file
- `POST /file.html` - save the body as that file
- Allowed: html, txt, gif, jpeg, jpg, css
- Other file types: `400`
- File not found: `404`
- Other methods (PUT, DELETE...): `501`
- Broken request: `400`

How it works:
- Each client gets its own goroutine
- Max 10 at a time, using a channel with 10 slots. 11th waits for a free slot
- Client that sends nothing gets cut after 10s, so it cant block a slot forever
- POST writes to a temp file first, then renames it. Rename is instant, so GET always gets the full old or full new file, never half
- `../` in paths is cleaned, so nobody can read or write outside `www/`
- POST limit is 10 MB

## Part 2 - pub-sub broker

| Request | What it does |
|---|---|
| `POST /subscribe?topic=X` | New subscriber, gives back an id |
| `POST /unsubscribe?topic=X&id=N` | Removes subscriber N |
| `POST /publish?topic=X` | Sends the body to all subscribers of X |
| `GET /events?topic=X&id=N` | Get next message for subscriber N |

How it works:
- One mutex protects all broker data
- Every message gets a number (seq) per topic, so order is kept
- Each subscriber has a queue of 64. If full, that subscriber skips the message. Publish never waits
- `/events` uses long polling: waits up to 30s for a message, else `204 No Content`
- A waiting `/events` gives its slot back, so it doesnt count in the 10
- Missing topic or bad id: `400`. Wrong method: `501`

## Example

```bash
curl -X POST "localhost:8080/subscribe?topic=news"            # {"id":1}
curl -X POST --data "hi" "localhost:8080/publish?topic=news"
curl "localhost:8080/events?topic=news&id=1"                  # {"seq":1,"message":"hi"}
```
