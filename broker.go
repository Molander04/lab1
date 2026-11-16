package main

import (
	"encoding/json"
	"io"
	"net"
	"net/http"
	"strconv"
	"sync"
	"time"
)

const (
	queueSize   = 64               // bounded queue per subscriber
	pollTimeout = 30 * time.Second // long-poll timeout
)

type message struct {
	Seq     int    `json:"seq"`
	Message string `json:"message"`
}

type subscriber struct {
	id    int
	topic string
	queue chan message  // bounded; publish never blocks on it
	done  chan struct{} // closed on unsubscribe to wake a waiting GET /events
}

type topicState struct {
	seq  int // last sequence number assigned on this topic
	subs map[int]*subscriber
}

// One mutex protects all broker state.
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

func badRequest(conn net.Conn) {
	writeResponse(conn, 400, "text/plain", []byte("Bad Request\n"))
}

func notFound(conn net.Conn) {
	writeResponse(conn, 404, "text/plain", []byte("Not Found\n"))
}

func writeJSON(conn net.Conn, status int, v any) {
	b, _ := json.Marshal(v)
	writeResponse(conn, status, "application/json", append(b, '\n'))
}

// parseID returns ok=false if the id parameter is missing or not a positive integer.
func parseID(req *http.Request) (int, bool) {
	n, err := strconv.Atoi(req.URL.Query().Get("id"))
	if err != nil || n <= 0 {
		return 0, false
	}
	return n, true
}

func handleBroker(conn net.Conn, req *http.Request, release func()) {
	want := http.MethodPost
	if req.URL.Path == "/events" {
		want = http.MethodGet
	}
	if req.Method != want {
		writeResponse(conn, 501, "text/plain", []byte("Not Implemented\n"))
		return
	}

	topic := req.URL.Query().Get("topic")
	if topic == "" {
		badRequest(conn)
		return
	}

	switch req.URL.Path {
	case "/subscribe":
		handleSubscribe(conn, topic)
	case "/unsubscribe":
		handleUnsubscribe(conn, req, topic)
	case "/publish":
		handlePublish(conn, req, topic)
	case "/events":
		handleEvents(conn, req, topic, release)
	}
}

func handleSubscribe(conn net.Conn, topic string) {
	broker.mu.Lock()
	t := broker.topics[topic]
	if t == nil {
		t = &topicState{subs: make(map[int]*subscriber)}
		broker.topics[topic] = t
	}
	s := &subscriber{
		id:    broker.nextID,
		topic: topic,
		queue: make(chan message, queueSize),
		done:  make(chan struct{}),
	}
	broker.nextID++
	t.subs[s.id] = s
	broker.subs[s.id] = s
	broker.mu.Unlock()

	writeJSON(conn, 201, map[string]int{"id": s.id})
}

// lookup finds a subscriber by id and checks it belongs to the topic.
// Caller must hold broker.mu.
func lookup(id int, topic string) *subscriber {
	s := broker.subs[id]
	if s == nil || s.topic != topic {
		return nil
	}
	return s
}

func handleUnsubscribe(conn net.Conn, req *http.Request, topic string) {
	id, ok := parseID(req)
	if !ok {
		badRequest(conn)
		return
	}

	broker.mu.Lock()
	s := lookup(id, topic)
	if s == nil {
		broker.mu.Unlock()
		notFound(conn)
		return
	}
	delete(broker.subs, id)
	delete(broker.topics[topic].subs, id)
	close(s.done) // wakes any waiting GET /events
	broker.mu.Unlock()

	writeResponse(conn, 200, "text/plain", []byte("OK\n"))
}

func handlePublish(conn net.Conn, req *http.Request, topic string) {
	body, err := io.ReadAll(io.LimitReader(req.Body, maxBodySize))
	if err != nil {
		badRequest(conn)
		return
	}

	// Assigning the sequence number and enqueueing happen under the same lock,
	// so every subscriber sees a topic's messages in sequence order.
	broker.mu.Lock()
	t := broker.topics[topic]
	if t == nil {
		t = &topicState{subs: make(map[int]*subscriber)}
		broker.topics[topic] = t
	}
	t.seq++
	msg := message{Seq: t.seq, Message: string(body)}
	delivered := 0
	for _, s := range t.subs {
		select {
		case s.queue <- msg:
			delivered++
		default: // queue full: skip this subscriber, never block
		}
	}
	broker.mu.Unlock()

	writeJSON(conn, 200, map[string]int{"seq": msg.Seq, "delivered": delivered})
}

// handleEvents implements long polling: hold the request until a message
// arrives, the subscriber is removed, or the timeout expires.
func handleEvents(conn net.Conn, req *http.Request, topic string, release func()) {
	id, ok := parseID(req)
	if !ok {
		badRequest(conn)
		return
	}

	broker.mu.Lock()
	s := lookup(id, topic)
	broker.mu.Unlock()
	if s == nil {
		notFound(conn)
		return
	}

	// A waiting poll does no work, so give its worker slot back.
	release()

	timer := time.NewTimer(pollTimeout)
	defer timer.Stop()

	select {
	case msg := <-s.queue:
		writeJSON(conn, 200, msg)
	case <-s.done:
		notFound(conn) // unsubscribed while waiting
	case <-timer.C:
		writeResponse(conn, 204, "text/plain", nil)
	}
}
