package main

import (
	"fmt"
	"net"
	"os"
)

func main() {
	if len(os.Args) < 2 {
		fmt.Println("need to provide a port")
		return
	}
	port := os.Args[1]

	address := ":" + port
	listener, err := net.Listen("tcp", address)

	if err != nil {
		fmt.Printf("Error: %v\n", err)
		return
	}

	defer listener.Close()

	fmt.Printf("listening on %s\n", port)

	sem := make(chan struct{}, 10)

	for {
		conn, err := listener.Accept()
		if err != nil {
			fmt.Printf("Error accepting connection: %v\n", err)
			continue
		}

		sem <- struct{}{}

		go func(conn net.Conn) {

			defer conn.Close()
			release := func() { <-sem }

			handleConn(conn, release)

		}(conn)

	}
}
