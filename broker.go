package main

import (
	"net"
	"net/http"
	"sync"
	"time"
)

const (
	queueSize   = 64
	pollTimeout = 30 * time.Second
)

type message struct {
	Seq     int    `json:"seq"`
	Message string `json:"message"`
}

type subscriber struct {
	id    int
	topic string
	queue chan message
	done  chan struct{}
}

type topicState struct {
	seq  int
	subs map[int]*subscriber
}

var broker = struct {
	mu     sync.Mutex
	nextID int
	topics map[string]*topicState
	subs   map[int]*subscriber
}{
	nextID: 1,
	topics: make(map[string]*topicState),
	subs:   make(map[int]*subscriber),
}

// Helpers (wrap writeResponse from server.go)
func badRequest(conn net.Conn)                   {}
func notFound(conn net.Conn)                     {}
func writeJSON(conn net.Conn, status int, v any) {}
func parseID(req *http.Request) (int, bool)      { return 0, false }
func lookup(id int, topic string) *subscriber    { return nil }

func handleBroker(conn net.Conn, req *http.Request, release func()) {
	// Validate HTTP method & topic -> dispatch to /subscribe, /unsubscribe, /publish, or /events
}

func handleSubscribe(conn net.Conn, topic string) {
	// Register new subscriber under broker.mu -> writeJSON(201)
}

func handleUnsubscribe(conn net.Conn, req *http.Request, topic string) {
	// Remove subscriber & close s.done under broker.mu -> writeResponse(200)
}

func handlePublish(conn net.Conn, req *http.Request, topic string) {
	// Read body (up to maxBodySize), increment seq, fan out to s.queue -> writeJSON(200)
}

func handleEvents(conn net.Conn, req *http.Request, topic string, release func()) {
	// Lookup subscriber -> call release() to free worker slot -> select on s.queue, s.done, or timeout
}
