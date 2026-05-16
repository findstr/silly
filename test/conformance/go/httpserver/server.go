package httpserver

import (
	"context"
	"fmt"
	"net"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"time"
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

func (m *Manager) Start(addr string, handler http.Handler) (*ServerInfo, error) {
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
	srv := &http.Server{Handler: handler}

	m.mu.Lock()
	m.servers[id] = srv
	m.mu.Unlock()

	go srv.Serve(ln)

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
