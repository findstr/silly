package tlspeer

import (
	"bytes"
	"crypto/tls"
	"fmt"
	"io"
	"net"
	"time"
)

type flightConn struct {
	net.Conn
	first   bool
	holding bool
	data    bytes.Buffer
}

func (c *flightConn) Write(p []byte) (int, error) {
	if c.first {
		c.first = false
		return c.Conn.Write(p)
	}
	if c.holding {
		return c.data.Write(p)
	}
	return c.Conn.Write(p)
}

// CloseWrite sends close_notify while keeping the read direction open for a response.
func CloseWrite(addr string, version uint16) (string, error) {
	raw, err := net.DialTimeout("tcp", addr, 5*time.Second)
	if err != nil {
		return "", err
	}
	var flight *flightConn
	if version == tls.VersionTLS13 {
		// Coalesce Finished, request and close_notify after the initial ClientHello.
		flight = &flightConn{Conn: raw, first: true, holding: true}
		raw = flight
	}
	conn := tls.Client(raw, &tls.Config{
		MinVersion:       version,
		MaxVersion:       version,
		CurvePreferences: []tls.CurveID{tls.CurveP256},
		// The loopback peer uses the repository's self-signed test certificate.
		InsecureSkipVerify: true,
	})
	defer conn.Close()
	if err := conn.SetDeadline(time.Now().Add(5 * time.Second)); err != nil {
		return "", err
	}
	if err := conn.Handshake(); err != nil {
		return "", err
	}
	if _, err := conn.Write([]byte("request")); err != nil {
		return "", err
	}
	if err := conn.CloseWrite(); err != nil {
		return "", err
	}
	if flight != nil {
		flight.holding = false
		// CloseWrite expires the raw write deadline after queuing close_notify.
		if err := flight.Conn.SetWriteDeadline(time.Now().Add(5 * time.Second)); err != nil {
			return "", err
		}
		if _, err := flight.data.WriteTo(flight.Conn); err != nil {
			return "", err
		}
	}
	response := make([]byte, len("response"))
	if _, err := io.ReadFull(conn, response); err != nil {
		return "", err
	}
	return string(response), nil
}

// CloseAfterError drains the fatal alert before sending junk and a TCP FIN.
// Keeping the read half open prevents an unread alert from turning close into RST.
func CloseAfterError(addr string) (string, error) {
	raw, err := net.DialTimeout("tcp", addr, 5*time.Second)
	if err != nil {
		return "", err
	}
	defer raw.Close()
	if err := raw.SetDeadline(time.Now().Add(5 * time.Second)); err != nil {
		return "", err
	}
	conn := tls.Client(raw, &tls.Config{
		MinVersion: tls.VersionTLS12,
		MaxVersion: tls.VersionTLS12,
		// The loopback peer uses the repository's self-signed test certificate.
		InsecureSkipVerify: true,
	})
	if err := conn.Handshake(); err != nil {
		return "", err
	}
	if _, err := conn.Write([]byte("hello")); err != nil {
		return "", err
	}
	if _, err := raw.Write(append([]byte{23, 3, 3, 0, 32}, make([]byte, 32)...)); err != nil {
		return "", err
	}
	var header [5]byte
	if _, err := io.ReadFull(raw, header[:]); err != nil {
		return "", err
	}
	if header[0] != 21 {
		return "", fmt.Errorf("expected fatal alert, got record type %d", header[0])
	}
	if _, err := io.CopyN(io.Discard, raw, int64(header[3])<<8|int64(header[4])); err != nil {
		return "", err
	}
	if _, err := raw.Write(bytes.Repeat([]byte("discard"), 4096)); err != nil {
		return "", err
	}
	if err := raw.(*net.TCPConn).CloseWrite(); err != nil {
		return "", err
	}
	if _, err := io.Copy(io.Discard, raw); err != nil {
		return "", err
	}
	return "closed", nil
}

type eofConn struct {
	net.Conn
	eof bool
}

func (c *eofConn) Read(p []byte) (int, error) {
	n, err := c.Conn.Read(p)
	if err == io.EOF {
		c.eof = true
	}
	return n, err
}

// ReadClose distinguishes close_notify from the bare EOF Go also accepts at record boundaries.
func ReadClose(addr string, version uint16) (string, error) {
	raw, err := net.DialTimeout("tcp", addr, 5*time.Second)
	if err != nil {
		return "", err
	}
	tracked := &eofConn{Conn: raw}
	conn := tls.Client(tracked, &tls.Config{
		MinVersion: version,
		MaxVersion: version,
		// The loopback peer uses the repository's self-signed test certificate.
		InsecureSkipVerify: true,
	})
	defer raw.Close()
	if err := conn.SetDeadline(time.Now().Add(5 * time.Second)); err != nil {
		return "", err
	}
	data, err := io.ReadAll(conn)
	if err == nil && tracked.eof {
		err = fmt.Errorf("transport EOF without close_notify")
	}
	if err == nil {
		// Withhold our close_notify and require the server to close without it.
		var tail [1]byte
		if n, eofErr := raw.Read(tail[:]); n != 0 || eofErr != io.EOF {
			err = fmt.Errorf("server did not close without a shutdown reply: %v", eofErr)
		}
	}
	return string(data), err
}
