package main

import (
	"bytes"
	"conformance/httpclient"
	"fmt"
	"io"
	"net"
	"net/http"
	"sync"
	"testing"
	"time"

	"golang.org/x/net/http2"
	"golang.org/x/net/http2/hpack"
)

func windowServer(t *testing.T) string {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	release, done := make(chan struct{}), make(chan struct{})
	var once sync.Once
	releaseBody := func() { once.Do(func() { close(release) }) }
	server := &http2.Server{
		MaxUploadBufferPerConnection: 4 * 1024 * 1024,
		MaxUploadBufferPerStream:     65535,
	}
	go func() {
		defer close(done)
		conn, err := listener.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		server.ServeConn(conn, &http2.ServeConnOpts{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.URL.Path == "/release" {
				releaseBody()
				w.WriteHeader(204)
				return
			}
			<-release
			body, err := io.ReadAll(r.Body)
			if err != nil {
				return
			}
			fmt.Fprint(w, len(body))
		})})
	}()
	t.Cleanup(func() {
		releaseBody()
		listener.Close()
		select {
		case <-done:
		case <-time.After(5 * time.Second):
			t.Error("Go HTTP/2 fixture did not close")
		}
	})
	return listener.Addr().String()
}

func TestReceiveWindowGrowthAndPadding(t *testing.T) {
	r, err := httpclient.FlowWindow(windowServer(t))
	if err != nil {
		t.Fatal(err)
	}
	if r.InitialConnectionWindow != 4*1024*1024 || r.StreamWindow != 65535 ||
		r.PaddingCredit != 4 || r.ReadCredit == 0 || r.Body != "65536" {
		t.Fatalf("window probe: %+v", r)
	}
	t.Logf("Go window probe: %+v", r)
}

func TestReceiveStreamWindowOverflow(t *testing.T) {
	addr := windowServer(t)
	conn, err := net.DialTimeout("tcp", addr, 5*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	if err := conn.SetDeadline(time.Now().Add(5 * time.Second)); err != nil {
		t.Fatal(err)
	}
	if _, err := conn.Write([]byte(http2.ClientPreface)); err != nil {
		t.Fatal(err)
	}
	f := http2.NewFramer(conn, conn)
	if err := f.WriteSettings(); err != nil {
		t.Fatal(err)
	}
	for {
		frame, err := f.ReadFrame()
		if err != nil {
			t.Fatal(err)
		}
		if settings, ok := frame.(*http2.SettingsFrame); ok {
			if settings.IsAck() {
				break
			}
			if err := f.WriteSettingsAck(); err != nil {
				t.Fatal(err)
			}
		}
	}
	var block bytes.Buffer
	encoder := hpack.NewEncoder(&block)
	for _, field := range []hpack.HeaderField{
		{Name: ":method", Value: "POST"}, {Name: ":scheme", Value: "http"},
		{Name: ":authority", Value: addr}, {Name: ":path", Value: "/flow"},
	} {
		if err := encoder.WriteField(field); err != nil {
			t.Fatal(err)
		}
	}
	if err := f.WriteHeaders(http2.HeadersFrameParam{
		StreamID: 1, BlockFragment: block.Bytes(), EndHeaders: true,
	}); err != nil {
		t.Fatal(err)
	}
	for left := 65535; left > 0; {
		n := min(left, 16384)
		if err := f.WriteData(1, false, bytes.Repeat([]byte{'x'}, n)); err != nil {
			t.Fatal(err)
		}
		left -= n
	}
	if err := f.WriteData(1, false, []byte("x")); err != nil {
		t.Fatal(err)
	}
	for {
		frame, err := f.ReadFrame()
		if err != nil {
			t.Fatal(err)
		}
		if reset, ok := frame.(*http2.RSTStreamFrame); ok {
			if reset.StreamID != 1 || reset.ErrCode != http2.ErrCodeFlowControl {
				t.Fatalf("oversized stream reset: %v", reset)
			}
			t.Logf("Go rejects the first excess byte with RST_STREAM FLOW_CONTROL_ERROR")
			break
		}
	}
}

func TestSendWindowOverflowScope(t *testing.T) {
	for _, source := range []string{"settings", "stream", "connection"} {
		t.Run(source, func(t *testing.T) {
			conn, err := net.DialTimeout("tcp", windowServer(t), 5*time.Second)
			if err != nil {
				t.Fatal(err)
			}
			defer conn.Close()
			if err := conn.SetDeadline(time.Now().Add(5 * time.Second)); err != nil {
				t.Fatal(err)
			}
			if _, err := io.WriteString(conn, http2.ClientPreface); err != nil {
				t.Fatal(err)
			}
			f := http2.NewFramer(conn, conn)
			if err := f.WriteSettings(); err != nil {
				t.Fatal(err)
			}
			var block bytes.Buffer
			encoder := hpack.NewEncoder(&block)
			for _, field := range []hpack.HeaderField{
				{Name: ":method", Value: "POST"}, {Name: ":scheme", Value: "http"},
				{Name: ":authority", Value: "example.test"}, {Name: ":path", Value: "/flow"},
			} {
				if err := encoder.WriteField(field); err != nil {
					t.Fatal(err)
				}
			}
			if err := f.WriteHeaders(http2.HeadersFrameParam{
				StreamID: 1, BlockFragment: block.Bytes(), EndHeaders: true,
			}); err != nil {
				t.Fatal(err)
			}
			id := uint32(1)
			if source == "connection" {
				id = 0
			}
			if err := f.WriteWindowUpdate(id, (1<<31-1)-65535); err != nil {
				t.Fatal(err)
			}
			if source == "settings" {
				err = f.WriteSettings(http2.Setting{ID: http2.SettingInitialWindowSize, Val: 65536})
			} else {
				err = f.WriteWindowUpdate(id, 1)
			}
			if err != nil {
				t.Fatal(err)
			}
			for {
				frame, err := f.ReadFrame()
				if err != nil {
					t.Fatal(err)
				}
				switch frame := frame.(type) {
				case *http2.SettingsFrame:
					if !frame.IsAck() {
						if err := f.WriteSettingsAck(); err != nil {
							t.Fatal(err)
						}
					}
				case *http2.GoAwayFrame:
					if source == "stream" || frame.ErrCode != http2.ErrCodeFlowControl {
						t.Fatalf("unexpected GOAWAY: %v", frame)
					}
					t.Logf("Go rejects %s overflow with GOAWAY FLOW_CONTROL_ERROR", source)
					return
				case *http2.RSTStreamFrame:
					if source != "stream" || frame.StreamID != 1 || frame.ErrCode != http2.ErrCodeFlowControl {
						t.Fatalf("unexpected RST_STREAM: %v", frame)
					}
					t.Log("Go rejects stream overflow with RST_STREAM FLOW_CONTROL_ERROR")
					return
				}
			}
		})
	}
}
