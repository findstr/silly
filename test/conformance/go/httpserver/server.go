package httpserver

import (
	"context"
	"crypto/tls"
	"fmt"
	"net"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"golang.org/x/net/http2"
)

type Manager struct {
	mu      sync.Mutex
	servers map[string]*http.Server
	nextID  atomic.Int64
}

func NewManager() *Manager {
	return &Manager{
		servers: make(map[string]*http.Server),
	}
}

type ServerInfo struct {
	ID   string `json:"server_id"`
	Addr string `json:"addr"`
}

func (m *Manager) Start(addr string, handler http.Handler, params map[string]any) (*ServerInfo, error) {
	var tlsConfig *tls.Config
	if enabled, _ := params["http2"].(bool); enabled {
		cert, _ := params["cert"].(string)
		key, _ := params["key"].(string)
		pair, err := tls.X509KeyPair([]byte(cert), []byte(key))
		if err != nil {
			return nil, fmt.Errorf("test TLS certificate: %w", err)
		}
		tlsConfig = &tls.Config{Certificates: []tls.Certificate{pair}, MinVersion: tls.VersionTLS12}
	}
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return nil, fmt.Errorf("listen %s: %w", addr, err)
	}
	actualAddr := ln.Addr().String()
	// Normalize [::]:port to 127.0.0.1:port for use in URLs
	if strings.HasPrefix(actualAddr, "[::]:") {
		actualAddr = "127.0.0.1:" + strings.TrimPrefix(actualAddr, "[::]:")
	} else if strings.HasPrefix(actualAddr, "0.0.0.0:") {
		actualAddr = "127.0.0.1:" + strings.TrimPrefix(actualAddr, "0.0.0.0:")
	}

	id := fmt.Sprintf("s%d", m.nextID.Add(1))
	srv := &http.Server{Handler: handler, TLSConfig: tlsConfig}
	if n, ok := params["header_table_size"].(float64); ok {
		if err := http2.ConfigureServer(srv, &http2.Server{MaxDecoderHeaderTableSize: uint32(n)}); err != nil {
			ln.Close()
			return nil, err
		}
	}

	m.mu.Lock()
	m.servers[id] = srv
	m.mu.Unlock()

	if tlsConfig != nil {
		go srv.ServeTLS(ln, "", "")
	} else {
		go srv.Serve(ln)
	}

	return &ServerInfo{ID: id, Addr: actualAddr}, nil
}

func (m *Manager) Stop(id string) error {
	m.mu.Lock()
	srv, ok := m.servers[id]
	if !ok {
		m.mu.Unlock()
		return fmt.Errorf("server %s not found", id)
	}
	delete(m.servers, id)
	m.mu.Unlock()

	return srv.Shutdown(context.Background())
}

func (m *Manager) StopAll() {
	m.mu.Lock()
	defer m.mu.Unlock()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	for id, srv := range m.servers {
		srv.Shutdown(ctx)
		delete(m.servers, id)
	}
}
