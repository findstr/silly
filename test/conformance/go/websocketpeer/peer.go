// Package websocketpeer provides raw RFC 6455 fixtures over real TCP and TLS.
package websocketpeer

import (
	"bufio"
	"crypto/sha1"
	"crypto/tls"
	"encoding/base64"
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"net/http"
	"time"
)

const key = "dGhlIHNhbXBsZSBub25jZQ=="
const guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

func frames(params map[string]any) ([][]byte, error) {
	var result [][]byte
	list, _ := params["frames"].([]any)
	for _, item := range list {
		encoded, ok := item.(string)
		if !ok {
			return nil, fmt.Errorf("frame must be base64")
		}
		wire, err := base64.StdEncoding.DecodeString(encoded)
		if err != nil {
			return nil, err
		}
		result = append(result, wire)
	}
	return result, nil
}

// Handler performs only the HTTP upgrade; frame bytes are independent test vectors.
func Handler(params map[string]any) (http.Handler, error) {
	wire, err := frames(params)
	if err != nil {
		return nil, err
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, _, err := w.(http.Hijacker).Hijack()
		if err != nil {
			return
		}
		defer conn.Close()
		conn.SetDeadline(time.Now().Add(5 * time.Second))
		// RFC 6455 mandates SHA-1 here; it is not used for authentication.
		accept := sha1.Sum([]byte(r.Header.Get("Sec-WebSocket-Key") + guid))
		header := http.Header{
			"Upgrade": {"websocket"}, "Connection": {"Upgrade"},
			"Sec-Websocket-Accept": {base64.StdEncoding.EncodeToString(accept[:])},
		}
		if overrides, ok := params["headers"].(map[string]any); ok {
			for name, value := range overrides {
				header.Set(name, value.(string))
			}
		}
		if omit, ok := params["omit"].(string); ok {
			header.Del(omit)
		}
		fmt.Fprint(conn, "HTTP/1.1 101 Switching Protocols\r\n")
		header.Write(conn)
		io.WriteString(conn, "\r\n")
		for _, part := range wire {
			if _, err := conn.Write(part); err != nil {
				return
			}
		}
		// Drain the client's Close/alert before releasing the transport, avoiding RST.
		io.Copy(io.Discard, conn)
	}), nil
}

type Result struct {
	Version   string `json:"version,omitempty"`
	Status    int    `json:"status"`
	Opcode    int    `json:"opcode"`
	Masked    bool   `json:"masked"`
	CloseCode int    `json:"close_code"`
	Data      string `json:"data"`
}

// Request sends a raw handshake and optional raw frames to a Lua server.
func Request(params map[string]any) (*Result, error) {
	addr, _ := params["addr"].(string)
	raw, err := net.DialTimeout("tcp", addr, 5*time.Second)
	if err != nil {
		return nil, err
	}
	defer raw.Close()
	raw.SetDeadline(time.Now().Add(5 * time.Second))
	var conn net.Conn = raw
	if secure, _ := params["tls"].(bool); secure {
		// All endpoints are loopback fixtures with repository self-signed certificates.
		conn = tls.Client(raw, &tls.Config{InsecureSkipVerify: true, MinVersion: tls.VersionTLS12})
		defer conn.Close()
	}
	request, _ := params["request"].(string)
	if request == "" {
		request = "GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n" +
			"Connection: Upgrade\r\nSec-WebSocket-Version: 13\r\n" +
			"Sec-WebSocket-Key: " + key + "\r\n\r\n"
	}
	if _, err := io.WriteString(conn, request); err != nil {
		return nil, err
	}
	reader := bufio.NewReader(conn)
	response, err := http.ReadResponse(reader, nil)
	if err != nil {
		return nil, err
	}
	result := &Result{Status: response.StatusCode, Version: response.Header.Get("Sec-WebSocket-Version")}
	wire, err := frames(params)
	if err != nil {
		return nil, err
	}
	if result.Status != 101 || len(wire) == 0 {
		return result, nil
	}
	for _, part := range wire {
		if _, err := conn.Write(part); err != nil {
			return nil, err
		}
	}
	var header [2]byte
	if _, err := io.ReadFull(reader, header[:]); err != nil {
		return nil, err
	}
	length := uint64(header[1] & 127)
	if length == 126 {
		var extended [2]byte
		if _, err := io.ReadFull(reader, extended[:]); err != nil {
			return nil, err
		}
		length = uint64(binary.BigEndian.Uint16(extended[:]))
	} else if length == 127 {
		var extended [8]byte
		if _, err := io.ReadFull(reader, extended[:]); err != nil {
			return nil, err
		}
		length = binary.BigEndian.Uint64(extended[:])
	}
	if length > 1<<20 {
		return nil, fmt.Errorf("unexpected large test response: %d", length)
	}
	result.Opcode = int(header[0] & 15)
	result.Masked = header[1]&128 != 0
	var mask [4]byte
	if result.Masked {
		if _, err := io.ReadFull(reader, mask[:]); err != nil {
			return nil, err
		}
	}
	payload := make([]byte, int(length))
	if _, err := io.ReadFull(reader, payload); err != nil {
		return nil, err
	}
	if result.Masked {
		for i := range payload {
			payload[i] ^= mask[i%4]
		}
	}
	if result.Opcode == 8 && len(payload) >= 2 {
		result.CloseCode = int(binary.BigEndian.Uint16(payload))
	}
	result.Data = base64.StdEncoding.EncodeToString(payload)
	return result, nil
}
