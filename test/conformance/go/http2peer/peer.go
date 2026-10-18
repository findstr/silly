// Package http2peer exposes a frame-level peer for conformance fixtures.
// net/http cannot inject malformed frames, so framing uses the existing x/net implementation.
package http2peer

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"sync"
	"time"

	"golang.org/x/net/http2"
)

type Manager struct {
	mu    sync.Mutex
	next  int
	peers map[string]*peer
}

type peer struct {
	ioMu     sync.Mutex
	mu       sync.Mutex
	listener net.Listener
	conn     net.Conn
	closed   bool
	framer   *http2.Framer
	wire     bytes.Buffer
}

type command struct {
	Op      string          `json:"op"`
	ID      string          `json:"id"`
	Addr    string          `json:"addr"`
	Data    []byte          `json:"data"`
	Size    int             `json:"size"`
	Timeout int             `json:"timeout"`
	Type    http2.FrameType `json:"type"`
}

type Frame struct {
	Type   http2.FrameType `json:"type"`
	Flags  http2.Flags     `json:"flags"`
	ID     uint32          `json:"id"`
	Data   []byte          `json:"data"`
	Length uint32          `json:"length"`
}

func (m *Manager) Handle(params map[string]interface{}) (interface{}, error) {
	data, err := json.Marshal(params)
	if err != nil {
		return nil, err
	}
	var cmd command
	if err := json.Unmarshal(data, &cmd); err != nil {
		return nil, err
	}
	if cmd.Op == "listen" || cmd.Op == "dial" {
		p := &peer{}
		var addr string
		if cmd.Op == "listen" {
			p.listener, err = net.Listen("tcp", "127.0.0.1:0")
			if err == nil {
				addr = p.listener.Addr().String()
			}
		} else {
			p.conn, err = net.DialTimeout("tcp", cmd.Addr, 5*time.Second)
			addr = cmd.Addr
		}
		if err != nil {
			return nil, err
		}
		m.mu.Lock()
		if m.peers == nil {
			m.peers = make(map[string]*peer)
		}
		m.next++
		id := fmt.Sprintf("peer-%d", m.next)
		m.peers[id] = p
		m.mu.Unlock()
		return map[string]string{"id": id, "addr": addr}, nil
	}
	if cmd.Op == "close" {
		m.Close(cmd.ID)
		return "ok", nil
	}
	m.mu.Lock()
	p := m.peers[cmd.ID]
	m.mu.Unlock()
	if p == nil {
		return nil, errors.New("unknown HTTP/2 peer")
	}
	p.ioMu.Lock()
	defer p.ioMu.Unlock()
	conn, err := p.connection()
	if err != nil {
		return nil, err
	}
	timeout := time.Duration(cmd.Timeout) * time.Millisecond
	if timeout <= 0 {
		timeout = 2 * time.Second
	}
	if err := conn.SetDeadline(time.Now().Add(timeout)); err != nil {
		return nil, err
	}
	switch cmd.Op {
	case "read":
		if cmd.Size < 0 || cmd.Size > 1<<24 {
			return nil, errors.New("invalid byte count")
		}
		data := make([]byte, cmd.Size)
		_, err := io.ReadFull(conn, data)
		return data, err
	case "write":
		_, err := io.Copy(conn, bytes.NewReader(cmd.Data))
		return true, err
	case "frame":
		return p.readFrame()
	case "until":
		for i := 0; i < 100; i++ {
			frame, err := p.readFrame()
			if err != nil {
				return nil, err
			}
			if frame.Type == cmd.Type {
				return frame, nil
			}
		}
		return nil, fmt.Errorf("expected frame %d", cmd.Type)
	case "serverhandshake":
		preface := make([]byte, len(http2.ClientPreface))
		if _, err := io.ReadFull(conn, preface); err != nil {
			return nil, err
		}
		if string(preface) != http2.ClientPreface {
			return nil, errors.New("invalid client preface")
		}
		if err := p.settings(); err != nil {
			return nil, err
		}
		if err := p.framer.WriteRawFrame(http2.FrameSettings, 0, 0, cmd.Data); err != nil {
			return nil, err
		}
		if err := p.framer.WriteSettingsAck(); err != nil {
			return nil, err
		}
		return true, p.settings()
	case "clienthandshake":
		if _, err := io.WriteString(conn, http2.ClientPreface); err != nil {
			return nil, err
		}
		if err := p.framer.WriteSettings(); err != nil {
			return nil, err
		}
		if err := p.settings(); err != nil {
			return nil, err
		}
		if err := p.framer.WriteSettingsAck(); err != nil {
			return nil, err
		}
		return true, p.settings()
	default:
		return nil, fmt.Errorf("unknown HTTP/2 peer operation %q", cmd.Op)
	}
}

// Only the owning control connection performs I/O; another control connection may close it.
func (p *peer) connection() (net.Conn, error) {
	p.mu.Lock()
	conn, ln, closed := p.conn, p.listener, p.closed
	p.mu.Unlock()
	if closed {
		return nil, net.ErrClosed
	}
	if conn == nil {
		if ln == nil {
			return nil, net.ErrClosed
		}
		if listener, ok := ln.(*net.TCPListener); ok {
			if err := listener.SetDeadline(time.Now().Add(5 * time.Second)); err != nil {
				return nil, err
			}
		}
		var err error
		conn, err = ln.Accept()
		if err != nil {
			return nil, err
		}
		p.mu.Lock()
		if p.closed {
			p.mu.Unlock()
			conn.Close()
			return nil, net.ErrClosed
		}
		p.conn = conn
		p.mu.Unlock()
	}
	if p.framer == nil {
		p.framer = http2.NewFramer(conn, io.TeeReader(conn, &p.wire))
		p.framer.SetMaxReadFrameSize((1 << 24) - 1)
	}
	return conn, nil
}

func (p *peer) readFrame() (*Frame, error) {
	p.wire.Reset()
	frame, err := p.framer.ReadFrame()
	if err != nil {
		return nil, err
	}
	h := frame.Header()
	return &Frame{Type: h.Type, Flags: h.Flags, ID: h.StreamID,
		Data: append([]byte{}, p.wire.Bytes()[9:]...), Length: h.Length}, nil
}

func (p *peer) settings() error {
	for i := 0; i < 100; i++ {
		frame, err := p.readFrame()
		if err != nil {
			return err
		}
		if frame.Type == http2.FrameSettings {
			return nil
		}
	}
	return errors.New("expected SETTINGS")
}

func (m *Manager) Close(id string) {
	m.mu.Lock()
	p := m.peers[id]
	delete(m.peers, id)
	m.mu.Unlock()
	if p == nil {
		return
	}
	p.mu.Lock()
	p.closed = true
	conn, ln := p.conn, p.listener
	p.mu.Unlock()
	if conn != nil {
		conn.Close()
	}
	if ln != nil {
		ln.Close()
	}
}

func (m *Manager) CloseAll() {
	m.mu.Lock()
	ids := make([]string, 0, len(m.peers))
	for id := range m.peers {
		ids = append(ids, id)
	}
	m.mu.Unlock()
	for _, id := range ids {
		m.Close(id)
	}
}
