package main

import (
	"conformance/control"
	"conformance/httpclient"
	"conformance/httpserver"
	"flag"
	"fmt"
	"log"
	"net"
	"os"
)

func main() {
	port := flag.Int("port", 9090, "control port")
	flag.Parse()

	addr := fmt.Sprintf("127.0.0.1:%d", *port)
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		log.Fatalf("listen %s: %v", addr, err)
	}

	srvMgr := httpserver.NewManager()

	handlers := map[string]control.Handler{
		"start_server": func(cmd *control.Command) *control.Response {
			handlerName, _ := cmd.Params["handler"].(string)
			if handlerName == "" {
				return &control.Response{Error: "missing handler name"}
			}
			listenAddr := ":0"
			if a, ok := cmd.Params["addr"].(string); ok && a != "" {
				listenAddr = a
			}
			h, err := httpserver.GetHandler(handlerName, cmd.Params)
			if err != nil {
				return &control.Response{Error: err.Error()}
			}
			info, err := srvMgr.Start(listenAddr, h)
			if err != nil {
				return &control.Response{Error: err.Error()}
			}
			return &control.Response{Result: info}
		},
		"stop_server": func(cmd *control.Command) *control.Response {
			id, _ := cmd.Params["server_id"].(string)
			if err := srvMgr.Stop(id); err != nil {
				return &control.Response{Error: err.Error()}
			}
			return &control.Response{Result: "ok"}
		},
		"http_request": func(cmd *control.Command) *control.Response {
			result, err := httpclient.DoRequest(cmd.Params)
			if err != nil {
				return &control.Response{Error: err.Error()}
			}
			return &control.Response{Result: result}
		},
		"http_request_pair": func(cmd *control.Command) *control.Response {
			result, err := httpclient.DoRequestPair(cmd.Params)
			if err != nil {
				return &control.Response{Error: err.Error()}
			}
			return &control.Response{Result: result}
		},
		"shutdown": func(cmd *control.Command) *control.Response {
			go func() {
				srvMgr.StopAll()
				ln.Close()
				os.Exit(0)
			}()
			return &control.Response{Result: "ok"}
		},
	}

	fmt.Printf("conformance: listening on %s\n", addr)
	control.Serve(ln, handlers)
}
