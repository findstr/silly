package httpclient

import (
	"bytes"
	"fmt"
	"net"
	"time"

	"golang.org/x/net/http2"
	"golang.org/x/net/http2/hpack"
)

// FlowWindow checks receive credits on a fixture server without reading its request body
// until a second request releases the handler. PING ACKs are processing barriers.
func FlowWindow(addr string) (*WindowResult, error) {
	conn, err := net.DialTimeout("tcp", addr, 5*time.Second)
	if err != nil {
		return nil, err
	}
	defer conn.Close()
	if err := conn.SetDeadline(time.Now().Add(5 * time.Second)); err != nil {
		return nil, err
	}
	if _, err := conn.Write([]byte(http2.ClientPreface)); err != nil {
		return nil, err
	}
	f := http2.NewFramer(conn, conn)
	f.ReadMetaHeaders = hpack.NewDecoder(4096, nil)
	if err := f.WriteSettings(); err != nil {
		return nil, err
	}
	r := &WindowResult{ConnectionWindow: 65535, StreamWindow: 65535}
	var ack, ended bool
	var credit uint32
	readUntil := func(done func(http2.Frame) bool) error {
		for {
			frame, err := f.ReadFrame()
			if err != nil {
				return err
			}
			switch frame := frame.(type) {
			case *http2.SettingsFrame:
				if frame.IsAck() {
					ack = true
				} else {
					if v, ok := frame.Value(http2.SettingInitialWindowSize); ok {
						r.StreamWindow = v
					}
					if err := f.WriteSettingsAck(); err != nil {
						return err
					}
				}
			case *http2.WindowUpdateFrame:
				if frame.StreamID == 0 {
					r.ConnectionWindow += int64(frame.Increment)
				} else if frame.StreamID == 1 {
					credit += frame.Increment
				}
			case *http2.MetaHeadersFrame:
				if frame.StreamID == 1 {
					if frame.PseudoValue("status") != "200" {
						return fmt.Errorf("flow response status: %s", frame.PseudoValue("status"))
					}
					ended = frame.StreamEnded()
				}
			case *http2.DataFrame:
				if frame.StreamID == 1 {
					r.Body += string(frame.Data())
					ended = frame.StreamEnded()
				}
			case *http2.GoAwayFrame:
				return fmt.Errorf("GOAWAY: %v", frame.ErrCode)
			case *http2.RSTStreamFrame:
				return fmt.Errorf("RST_STREAM %d: %v", frame.StreamID, frame.ErrCode)
			}
			if done(frame) {
				return nil
			}
		}
	}
	if err := readUntil(func(http2.Frame) bool { return ack && r.ConnectionWindow > 65535 }); err != nil {
		return nil, err
	}
	r.InitialConnectionWindow = r.ConnectionWindow
	if r.StreamWindow != 65535 {
		return nil, fmt.Errorf("fixture stream window = %d, want 65535", r.StreamWindow)
	}
	var block bytes.Buffer
	encoder := hpack.NewEncoder(&block)
	headers := func(id uint32, method, path string, end bool) error {
		block.Reset()
		for _, field := range []hpack.HeaderField{
			{Name: ":method", Value: method}, {Name: ":scheme", Value: "http"},
			{Name: ":authority", Value: addr}, {Name: ":path", Value: path},
		} {
			if err := encoder.WriteField(field); err != nil {
				return err
			}
		}
		return f.WriteHeaders(http2.HeadersFrameParam{
			StreamID: id, BlockFragment: block.Bytes(), EndHeaders: true, EndStream: end,
		})
	}
	barrier := func() error {
		token := [8]byte{'w', 'i', 'n', 'd', 'o', 'w', 's', '!'}
		if err := f.WritePing(false, token); err != nil {
			return err
		}
		return readUntil(func(frame http2.Frame) bool {
			ping, ok := frame.(*http2.PingFrame)
			return ok && ping.IsAck() && ping.Data == token
		})
	}
	if err := headers(1, "POST", "/flow", false); err != nil {
		return nil, err
	}
	// Padding consumes four extra octets: its length byte and three padding bytes.
	if err := f.WriteDataPadded(1, false, bytes.Repeat([]byte{'x'}, 1024), make([]byte, 3)); err != nil {
		return nil, err
	}
	for left := 65535 - 1028; left > 0; {
		n := min(left, 16384)
		if err := f.WriteData(1, false, bytes.Repeat([]byte{'x'}, n)); err != nil {
			return nil, err
		}
		left -= n
	}
	if err := barrier(); err != nil {
		return nil, err
	}
	r.PaddingCredit = credit
	if credit != 4 {
		return nil, fmt.Errorf("unread stream credit = %d, want padding credit 4", credit)
	}
	if err := f.WriteData(1, false, []byte("xxxx")); err != nil {
		return nil, err
	}
	if err := barrier(); err != nil {
		return nil, err
	}
	if credit != 4 {
		return nil, fmt.Errorf("unread stream refunded body bytes: %d", credit)
	}
	if err := headers(3, "GET", "/release", true); err != nil {
		return nil, err
	}
	if err := readUntil(func(http2.Frame) bool { return credit > r.PaddingCredit }); err != nil {
		return nil, err
	}
	if err := f.WriteData(1, true, []byte("x")); err != nil {
		return nil, err
	}
	if err := readUntil(func(http2.Frame) bool { return ended }); err != nil {
		return nil, err
	}
	r.ReadCredit = credit - r.PaddingCredit
	return r, nil
}

type WindowResult struct {
	InitialConnectionWindow int64  `json:"connection_window"`
	StreamWindow            uint32 `json:"stream_window"`
	PaddingCredit           uint32 `json:"padding_credit"`
	ReadCredit              uint32 `json:"read_credit"`
	Body                    string `json:"body"`
	ConnectionWindow        int64  `json:"-"`
}
