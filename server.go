package main

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net"
	"net/http"
	"os"
	"path"
	"path/filepath"
	"strings"
	"time"
)

const (
	rootDir     = "www"
	maxBodySize = 10 << 20 // 10 MB
	readTimeout = 10 * time.Second
)

var contentTypes = map[string]string{
	".html": "text/html",
	".txt":  "text/plain",
	".gif":  "image/gif",
	".jpeg": "image/jpeg",
	".jpg":  "image/jpeg",
	".css":  "text/css",
}

// Paths for the pub-sub broker
var brokerPaths = map[string]bool{
	"/subscribe":   true,
	"/unsubscribe": true,
	"/publish":     true,
	"/events":      true,
}

// Send HTTP response
// Shared by both server and broker
func writeResponse(w io.Writer, status int, ctype string, body []byte) {
	header := fmt.Sprintf("HTTP/1.1 %d %s\r\n", status, http.StatusText(status))

	if ctype != "" {
		header += "Content-Type: " + ctype + "\r\n"
	}

	header += fmt.Sprintf("Content-Length: %d\r\n", len(body))
	header += "Connection: close\r\n"
	header += "\r\n" // empty line: headers are finished

	w.Write([]byte(header))
	w.Write(body)

}

// error msg
func writeError(w io.Writer, status int) {
	msg := fmt.Sprintf("%d %s\n", status, http.StatusText(status))
	writeResponse(w, status, "text/plain", []byte(msg))
}

// handle single connection, from start to end
// release the worker slot when done
func handleConn(conn net.Conn, release func()) {
	defer release()
	defer conn.Close()

	// sets time limit to avoid hanging connections
	conn.SetReadDeadline(time.Now().Add(readTimeout))

	req, err := http.ReadRequest(bufio.NewReader(conn))
	if err != nil {
		writeError(conn, http.StatusBadRequest)
		return
	}

	// Check if path is for broker
	if brokerPaths[req.URL.Path] {
		handleBroker(conn, req, release)
		return
	}

	switch req.Method {
	case http.MethodGet:
		handleGet(conn, req)
	case http.MethodPost:
		handlePost(conn, req)
	default:
		writeError(conn, http.StatusNotImplemented)
	}
}

// Turns URL to real file path and checks content type
func resolvePath(urlPath string) (full, ctype string, ok bool) {
	clean := path.Clean("/" + urlPath) // "/../../x.txt" becomes "/x.txt"

	ext := strings.ToLower(path.Ext(clean))
	ctype, ok = contentTypes[ext]
	if !ok {
		return "", "", false
	}

	full = filepath.Join(rootDir, filepath.FromSlash(clean))
	return full, ctype, true
}

// sends a stored file back to the client.
func handleGet(conn net.Conn, req *http.Request) {
	full, ctype, ok := resolvePath(req.URL.Path)
	if !ok {
		writeError(conn, http.StatusBadRequest)
		return
	}

	data, err := os.ReadFile(full)
	if errors.Is(err, fs.ErrNotExist) {
		writeError(conn, http.StatusNotFound)
		return
	}
	if err != nil {
		writeError(conn, http.StatusBadRequest)
		return
	}

	writeResponse(conn, http.StatusOK, ctype, data)
}

// handles saving the request body as a file.
func handlePost(conn net.Conn, req *http.Request) {
	full, _, ok := resolvePath(req.URL.Path)
	if !ok {
		writeError(conn, http.StatusBadRequest)
		return
	}

	data, err := io.ReadAll(io.LimitReader(req.Body, maxBodySize+1))
	if err != nil || len(data) > maxBodySize {
		writeError(conn, http.StatusBadRequest)
		return
	}

	if err := atomicWrite(full, data); err != nil {
		writeError(conn, http.StatusBadRequest)
		return
	}

	writeResponse(conn, http.StatusOK, "text/plain", []byte("File saved\n"))
}

func atomicWrite(target string, data []byte) error {

	// Create dir if not exists
	dir := filepath.Dir(target)
	if err := os.MkdirAll(dir, 0755); err != nil {
		return err
	}

	// Create a temp file in the same dir
	tmp, err := os.CreateTemp(dir, ".upload-*")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()

	// Write data to the temp file
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		os.Remove(tmpName)
		return err
	}

	// make readable file
	if err := tmp.Chmod(0644); err != nil {
		tmp.Close()
		os.Remove(tmpName)
		return err
	}

	// close file and rename to target
	if err := tmp.Close(); err != nil {
		os.Remove(tmpName)
		return err
	}
	if err := os.Rename(tmpName, target); err != nil {
		os.Remove(tmpName)
		return err
	}

	return nil

}
