package http2peer

import (
	"bytes"
	"errors"
	"io"
	"net"
	"testing"
	"time"

	"golang.org/x/net/http2"
)

func fixture(t *testing.T) (*Manager, net.Conn) {
	t.Helper()
	local, remote := net.Pipe()
	m := &Manager{peers: map[string]*peer{"fixture": {conn: local}}}
	t.Cleanup(func() { m.CloseAll(); remote.Close() })
	return m, remote
}

func receive(t *testing.T, m *Manager) *Frame {
	t.Helper()
	v, err := m.Handle(map[string]interface{}{"op": "frame", "id": "fixture"})
	if err != nil {
		t.Fatal(err)
	}
	return v.(*Frame)
}

func TestFramePayloadAndIndependentResults(t *testing.T) {
	m, conn := fixture(t)
	done := make(chan error, 1)
	go func() {
		f := http2.NewFramer(conn, conn)
		if err := f.WriteDataPadded(1, false, []byte("abc"), []byte{0, 0}); err != nil {
			done <- err
			return
		}
		done <- f.WritePing(true, [8]byte{'b', 'i', 'n', 'a', 'r', 'y', 0, 255})
	}()
	data := receive(t, m)
	if data.Type != http2.FrameData || data.ID != 1 || data.Length != 6 ||
		!bytes.Equal(data.Data, []byte{2, 'a', 'b', 'c', 0, 0}) {
		t.Fatalf("padded frame: %+v", data)
	}
	ping := receive(t, m)
	if ping.Type != http2.FramePing || ping.Flags != http2.FlagPingAck || ping.ID != 0 ||
		!bytes.Equal(ping.Data, []byte{'b', 'i', 'n', 'a', 'r', 'y', 0, 255}) {
		t.Fatalf("PING: %+v", ping)
	}
	if !bytes.Equal(data.Data, []byte{2, 'a', 'b', 'c', 0, 0}) {
		t.Fatal("next read changed the previous payload")
	}
	if err := <-done; err != nil {
		t.Fatal(err)
	}
}

func TestFramerRejectsInterleaving(t *testing.T) {
	m, conn := fixture(t)
	go func() {
		defer conn.Close()
		f := http2.NewFramer(conn, conn)
		if err := f.WriteRawFrame(http2.FrameHeaders, 0, 1, []byte{0x88}); err != nil {
			return
		}
		f.WritePing(false, [8]byte{})
	}()
	receive(t, m)
	_, err := m.Handle(map[string]interface{}{"op": "frame", "id": "fixture"})
	if err != http2.ConnectionError(http2.ErrCodeProtocol) {
		t.Fatalf("interleaved frame: %v", err)
	}
}

func TestFramerRejectsTruncatedFrame(t *testing.T) {
	m, conn := fixture(t)
	go func() {
		defer conn.Close()
		// Length says eight bytes, but only three payload bytes follow.
		conn.Write([]byte{0, 0, 8, 6, 0, 0, 0, 0, 0, 1, 2, 3})
	}()
	_, err := m.Handle(map[string]interface{}{"op": "frame", "id": "fixture"})
	if !errors.Is(err, io.ErrUnexpectedEOF) {
		t.Fatalf("truncated payload: %v", err)
	}
}

type observedConn struct {
	net.Conn
	reading chan struct{}
}

func (c *observedConn) Read(p []byte) (int, error) {
	select {
	case c.reading <- struct{}{}:
	default:
	}
	return c.Conn.Read(p)
}

func TestCloseUnblocksFrameRead(t *testing.T) {
	local, remote := net.Pipe()
	defer remote.Close()
	reading := make(chan struct{}, 1)
	m := &Manager{peers: map[string]*peer{"fixture": {conn: &observedConn{local, reading}}}}
	t.Cleanup(m.CloseAll)
	done := make(chan error, 1)
	go func() { _, err := m.Handle(map[string]interface{}{"op": "frame", "id": "fixture"}); done <- err }()
	select {
	case <-reading:
	case <-time.After(5 * time.Second):
		t.Fatal("read did not start")
	}
	m.Close("fixture")
	select {
	case err := <-done:
		if !errors.Is(err, io.ErrClosedPipe) {
			t.Fatalf("closed frame read: %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("close did not unblock read")
	}
	m.Close("fixture")
}
