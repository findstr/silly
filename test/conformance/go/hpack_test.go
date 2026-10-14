package main

import (
	"bytes"
	"io"
	"strings"
	"testing"

	"golang.org/x/net/http2"
	"golang.org/x/net/http2/hpack"
)

func TestIndexedHeaderListSize(t *testing.T) {
	block := append([]byte{0x88}, bytes.Repeat([]byte{0x90}, 1200)...)
	fields, err := hpack.NewDecoder(4096, nil).DecodeFull(block)
	if err != nil {
		t.Fatal(err)
	}
	var size uint32
	for _, field := range fields {
		size += field.Size()
	}
	if len(block) != 1201 || len(fields) != 1201 || size != 72042 {
		t.Fatalf("wire=%d fields=%d RFC size=%d", len(block), len(fields), size)
	}
	t.Logf("Go accepts valid HPACK: wire=%d fields=%d RFC size=%d", len(block), len(fields), size)
}

func TestHTTP2DecodedHeaderListBoundary(t *testing.T) {
	amplified := "\x88" + strings.Repeat("\x90", 1200)
	boundary := "\x88" + strings.Repeat("\x90", 1091) + "\x00\x01x"
	for _, tt := range []struct {
		name      string
		block     string
		limit     uint32
		truncated bool
	}{
		{"amplified-default", amplified, 0, false},
		{"amplified-65535", amplified, 65535, true},
		{"amplified-one-short", amplified, 72041, true},
		{"amplified-exact", amplified, 72042, false},
		{"local-exact", boundary + "\x00", 65535, false},
		{"local-one-over", boundary + "\x01v", 65535, true},
	} {
		t.Run(tt.name, func(t *testing.T) {
			var wire bytes.Buffer
			writer := http2.NewFramer(&wire, nil)
			if err := writer.WriteHeaders(http2.HeadersFrameParam{
				StreamID: 1, BlockFragment: []byte(tt.block), EndHeaders: true, EndStream: true,
			}); err != nil {
				t.Fatal(err)
			}
			reader := http2.NewFramer(io.Discard, &wire)
			reader.ReadMetaHeaders = hpack.NewDecoder(4096, nil)
			reader.MaxHeaderListSize = tt.limit
			frame, err := reader.ReadFrame()
			if err != nil {
				t.Fatal(err)
			}
			if got := frame.(*http2.MetaHeadersFrame).Truncated; got != tt.truncated {
				t.Fatalf("Truncated=%v, want %v", got, tt.truncated)
			}
		})
	}
}

func TestHTTP2HeaderLimitPreservesCompressionState(t *testing.T) {
	for _, malformed := range []bool{false, true} {
		var wire bytes.Buffer
		writer := http2.NewFramer(&wire, nil)
		// :status/200 (42), x/v (34), y/z (34). Both literals update the table.
		block := "\x88\x40\x01x\x01v\x40\x01y\x01z"
		if malformed {
			block += "\x80" // Indexed field zero stays invalid after the size limit.
		}
		if err := writer.WriteHeaders(http2.HeadersFrameParam{
			StreamID: 1, BlockFragment: []byte(block), EndHeaders: true, EndStream: true,
		}); err != nil {
			t.Fatal(err)
		}
		if err := writer.WriteHeaders(http2.HeadersFrameParam{
			StreamID: 3, BlockFragment: []byte("\x88\xbe\xbf"), EndHeaders: true, EndStream: true,
		}); err != nil {
			t.Fatal(err)
		}
		reader := http2.NewFramer(io.Discard, &wire)
		reader.ReadMetaHeaders = hpack.NewDecoder(4096, nil)
		reader.MaxHeaderListSize = 75
		frame, err := reader.ReadFrame()
		if malformed {
			if err != http2.ConnectionError(http2.ErrCodeCompression) {
				t.Fatalf("malformed over-limit block: got %v, want COMPRESSION_ERROR", err)
			}
			continue
		}
		if err != nil {
			t.Fatal(err)
		}
		first := frame.(*http2.MetaHeadersFrame)
		if !first.Truncated || len(first.Fields) != 1 {
			t.Fatalf("bounded fields: %+v", first)
		}
		reader.MaxHeaderListSize = 110
		frame, err = reader.ReadFrame()
		if err != nil {
			t.Fatal(err)
		}
		next := frame.(*http2.MetaHeadersFrame)
		if next.Truncated || len(next.Fields) != 3 || next.Fields[1].Name != "y" ||
			next.Fields[1].Value != "z" || next.Fields[2].Name != "x" ||
			next.Fields[2].Value != "v" {
			t.Fatalf("fields after truncation: %+v", next)
		}
	}
}
