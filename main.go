package main

const maxWorkers = 10

var sem = make(chan struct{}, maxWorkers)

func main() {
	// 1. Listen on TCP port from os.Args[1]
	// 2. Accept loop -> acquire sem -> create idempotent release() -> go handleConn(conn, release)
}
