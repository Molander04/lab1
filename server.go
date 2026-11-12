package main

import (
	"io"
	"net"
	"net/http"
)

const (
	rootDir     = "www"
	maxBodySize = 10 << 20 // 10 MB
)

var contentTypes = map[string]string{
	".html": "text/html",
	".txt":  "text/plain",
	".gif":  "image/gif",
	".jpeg": "image/jpeg",
	".jpg":  "image/jpeg",
	".css":  "text/css",
}

func handleConn(conn net.Conn, release func()) {
	// Parse request -> route broker paths to handleBroker(), else dispatch GET/POST
}

func resolvePath(urlPath string) (full, ctype string, ok bool) {
	// Clean URL path, validate extension, and join with rootDir
	return "", "", false
}

func handleGet(conn net.Conn, req *http.Request) {
	// Resolve path, read file, and call writeResponse()
}

func handlePost(conn net.Conn, req *http.Request) {
	// Resolve path, read body, call atomicWrite(), and call writeResponse()
}

func atomicWrite(target string, data []byte) error {
	// Write to temp file and atomically rename over target
	return nil
}

// Shared helper used by both server.go and broker.go
func writeResponse(w io.Writer, status int, ctype string, body []byte) {
	// Write HTTP/1.1 status line, headers, and body
}
