package main

import (
	"conformance/control"
	"conformance/http2peer"
	"conformance/httpclient"
	"conformance/httpserver"
	"conformance/tlspeer"
	"encoding/base64"
	"flag"
	"fmt"
	"log"
	"net"
	"os"

	"golang.org/x/net/http2/hpack"
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
	peers := &http2peer.Manager{}
	defer peers.CloseAll()

	handlers := map[string]control.Handler{
		"tls_readclose": func(cmd *control.Command) *control.Response {
			addr, _ := cmd.Params["addr"].(string)
			version, _ := cmd.Params["version"].(float64)
			result, err := tlspeer.ReadClose(addr, uint16(version))
			if err != nil {
				return &control.Response{Error: err.Error()}
			}
			return &control.Response{Result: result}
		},
		"tls_closeaftererror": func(cmd *control.Command) *control.Response {
			addr, _ := cmd.Params["addr"].(string)
			result, err := tlspeer.CloseAfterError(addr)
			if err != nil {
				return &control.Response{Error: err.Error()}
			}
			return &control.Response{Result: result}
		},
		"tls_closewrite": func(cmd *control.Command) *control.Response {
			addr, _ := cmd.Params["addr"].(string)
			version, _ := cmd.Params["version"].(float64)
			result, err := tlspeer.CloseWrite(addr, uint16(version))
			if err != nil {
				return &control.Response{Error: err.Error()}
			}
			return &control.Response{Result: result}
		},
		"http2_peer": func(cmd *control.Command) *control.Response {
			result, err := peers.Handle(cmd.Params)
			if err != nil {
				return &control.Response{Error: err.Error()}
			}
			return &control.Response{Result: result}
		},
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
			info, err := srvMgr.Start(listenAddr, h, cmd.Params)
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
		"http2_flow": func(cmd *control.Command) *control.Response {
			addr, _ := cmd.Params["addr"].(string)
			result, err := httpclient.FlowWindow(addr)
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
				peers.CloseAll()
				ln.Close()
				os.Exit(0)
			}()
			return &control.Response{Result: "ok"}
		},
		"hpack_decode": func(cmd *control.Command) *control.Response {
			blocks, ok := cmd.Params["blocks"].([]any)
			if !ok {
				return &control.Response{Error: "missing HPACK blocks"}
			}
			size := uint32(4096)
			if n, ok := cmd.Params["table_size"].(float64); ok {
				size = uint32(n)
			}
			var headers []hpack.HeaderField
			decoder := hpack.NewDecoder(size, func(field hpack.HeaderField) { headers = append(headers, field) })
			decoded := make([][]hpack.HeaderField, 0, len(blocks))
			for _, block := range blocks {
				encoded, ok := block.(string)
				if !ok {
					return &control.Response{Error: "HPACK block must be base64"}
				}
				wire, err := base64.StdEncoding.DecodeString(encoded)
				if err != nil {
					return &control.Response{Error: err.Error()}
				}
				headers = nil
				if _, err := decoder.Write(wire); err != nil {
					return &control.Response{Error: err.Error()}
				}
				if err := decoder.Close(); err != nil {
					return &control.Response{Error: err.Error()}
				}
				decoded = append(decoded, headers)
			}
			return &control.Response{Result: decoded}
		},
	}

	fmt.Printf("conformance: listening on %s\n", addr)
	control.Serve(ln, handlers)
}
