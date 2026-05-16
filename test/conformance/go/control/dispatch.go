package control

import (
	"bufio"
	"log"
	"net"
)

type Handler func(cmd *Command) *Response

func Serve(ln net.Listener, handlers map[string]Handler) {
	for {
		conn, err := ln.Accept()
		if err != nil {
			log.Printf("accept error: %v", err)
			return
		}
		go handleConn(conn, handlers, "shutdown")
	}
}

func handleConn(conn net.Conn, handlers map[string]Handler, exitCmds ...string) {
	defer conn.Close()
	r := bufio.NewReader(conn)
	for {
		cmd, err := ReadCommand(r)
		if err != nil {
			log.Printf("control: read command error: %v", err)
			return
		}
		h, ok := handlers[cmd.Cmd]
		if !ok {
			WriteResponse(conn, &Response{ID: cmd.ID, Error: "unknown command: " + cmd.Cmd})
			continue
		}
		resp := h(cmd)
		resp.ID = cmd.ID
		if err := WriteResponse(conn, resp); err != nil {
			return
		}
		for _, exitCmd := range exitCmds {
			if cmd.Cmd == exitCmd {
				return
			}
		}
	}
}
