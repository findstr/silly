package httpserver

import (
	"bufio"
	"compress/gzip"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
	"time"
)

func GetHandler(name string, params map[string]interface{}) (http.Handler, error) {
	switch name {
	case "echo":
		return echoHandler(), nil
	case "chunked":
		return chunkedHandler(params), nil
	case "content_length":
		return contentLengthHandler(params), nil
	case "read_until_eof":
		return readUntilEOFHandler(params), nil
	case "status_code":
		return statusCodeHandler(params), nil
	case "head_no_body":
		return headNoBodyHandler(params), nil
	case "trailers":
		return trailersHandler(params), nil
	case "gzip_response":
		return gzipResponseHandler(params), nil
	case "slow_response": // alias for chunkedHandler; use delay_ms param
		return chunkedHandler(params), nil
	case "close_midway":
		return closeMidwayHandler(params), nil
	case "invalid_chunk":
		return invalidChunkHandler(params), nil
	case "conn_close":
		return connCloseHandler(params), nil
	case "custom":
		return customHandler(params), nil
	case "connection_echo":
		return connectionEchoHandler(), nil
	case "redirect":
		return redirectHandler(params), nil
	case "chunked_extensions":
		return chunkedExtensionsHandler(params), nil
	case "chunked_leading_zeros":
		return chunkedLeadingZerosHandler(params), nil
	case "chunked_mixed_hex":
		return chunkedMixedHexHandler(params), nil
	case "bare_newline":
		return bareNewlineHandler(params), nil
	case "ows_headers":
		return owsHeadersHandler(params), nil
	case "header_echo":
		return headerEchoHandler(), nil
	case "empty_eof":
		return emptyEOFHandler(), nil
	case "multi_1xx":
		return multi1xxHandler(params), nil
	case "payload_limit":
		return payloadLimitHandler(params), nil
	default:
		return nil, fmt.Errorf("unknown handler: %s", name)
	}
}

func echoHandler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body) // test helper, input is controlled
		r.Body.Close()

		headers := make(map[string][]string)
		for k, v := range r.Header {
			headers[k] = v
		}

		resp := map[string]interface{}{
			"method":  r.Method,
			"path":    r.URL.Path,
			"query":   r.URL.RawQuery,
			"headers": headers,
			"body":    string(body),
		}
		data, _ := json.Marshal(resp) // test helper, input is controlled
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Content-Length", fmt.Sprintf("%d", len(data)))
		w.Write(data)
	})
}

func chunkedHandler(params map[string]interface{}) http.Handler {
	chunks := getStringSlice(params, "chunks")
	delayMs := getInt(params, "delay_ms", 0)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain")
		w.Header().Set("Transfer-Encoding", "chunked")
		for _, chunk := range chunks {
			if delayMs > 0 {
				time.Sleep(time.Duration(delayMs) * time.Millisecond)
			}
			w.Write([]byte(chunk))
			if f, ok := w.(http.Flusher); ok {
				f.Flush()
			}
		}
	})
}

func contentLengthHandler(params map[string]interface{}) http.Handler {
	body := getString(params, "body")
	status := getInt(params, "status", 200)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain")
		w.Header().Set("Content-Length", fmt.Sprintf("%d", len(body)))
		w.WriteHeader(status)
		w.Write([]byte(body))
	})
}

func readUntilEOFHandler(params map[string]interface{}) http.Handler {
	body := getString(params, "body")
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, buf, ok := hijackConn(w)
		if !ok {
			return
		}
		defer conn.Close()
		buf.WriteString("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n")
		buf.WriteString(body)
		buf.Flush()
	})
}

func statusCodeHandler(params map[string]interface{}) http.Handler {
	status := getInt(params, "status", 200)
	body := getString(params, "body")
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain")
		if body != "" {
			w.Header().Set("Content-Length", fmt.Sprintf("%d", len(body)))
		}
		w.WriteHeader(status)
		if body != "" {
			w.Write([]byte(body))
		}
	})
}

func headNoBodyHandler(params map[string]interface{}) http.Handler {
	bodyLen := getInt(params, "body_length", 100)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain")
		w.Header().Set("Content-Length", fmt.Sprintf("%d", bodyLen))
		w.WriteHeader(200)
	})
}

func trailersHandler(params map[string]interface{}) http.Handler {
	chunks := getStringSlice(params, "chunks")
	trailerKey := getString(params, "trailer_key", "X-Checksum")
	trailerVal := getString(params, "trailer_val", "abc123")
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain")
		w.Header().Set("Transfer-Encoding", "chunked")
		w.Header().Set("Trailer", trailerKey)
		for _, chunk := range chunks {
			w.Write([]byte(chunk))
		}
		w.Header().Set(trailerKey, trailerVal)
	})
}

func gzipResponseHandler(params map[string]interface{}) http.Handler {
	body := getString(params, "body")
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain")
		w.Header().Set("Content-Encoding", "gzip")
		gz := gzip.NewWriter(w)
		gz.Write([]byte(body))
		gz.Close()
	})
}

func closeMidwayHandler(params map[string]interface{}) http.Handler {
	part1 := getString(params, "part1", "hel")
	part2 := getString(params, "part2", "lo")
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, buf, ok := hijackConn(w)
		if !ok {
			return
		}
		defer conn.Close()
		buf.WriteString("HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\n")
		buf.WriteString(part1)
		buf.WriteString(part2)
		buf.Flush()
	})
}

func invalidChunkHandler(params map[string]interface{}) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, buf, ok := hijackConn(w)
		if !ok {
			return
		}
		defer conn.Close()
		buf.WriteString("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n")
		buf.WriteString("5\r\nHello\r\n")
		buf.WriteString("ZZZ\r\n")
		buf.Flush()
	})
}

func connCloseHandler(params map[string]interface{}) http.Handler {
	body := getString(params, "body", "closed")
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain")
		w.Header().Set("Content-Length", fmt.Sprintf("%d", len(body)))
		w.Header().Set("Connection", "close")
		w.Write([]byte(body))
	})
}

func customHandler(params map[string]interface{}) http.Handler {
	status := getInt(params, "response_status", 200)
	headers := getStringMap(params, "response_headers")
	body := getString(params, "response_body")
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		for k, v := range headers {
			w.Header().Set(k, v)
		}
		w.WriteHeader(status)
		if body != "" {
			w.Write([]byte(body))
		}
	})
}

func connectionEchoHandler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body) // test helper, input is controlled
		r.Body.Close()

		resp := map[string]interface{}{
			"method": r.Method,
			"body":   string(body),
		}
		data, _ := json.Marshal(resp) // test helper, input is controlled
		w.Header().Set("Connection", "X-Test-Hop")
		w.Header().Set("X-Test-Hop", "should-be-stripped")
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Content-Length", fmt.Sprintf("%d", len(data)))
		w.Write(data)
	})
}

func redirectHandler(params map[string]interface{}) http.Handler {
	status := getInt(params, "redirect_status", 301)
	location := getString(params, "redirect_location", "/target")
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Location", location)
		w.WriteHeader(status)
	})
}

func chunkedExtensionsHandler(params map[string]interface{}) http.Handler {
	chunks := getStringSlice(params, "chunks")
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, buf, ok := hijackConn(w)
		if !ok {
			return
		}
		defer conn.Close()
		buf.WriteString("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n")
		for _, chunk := range chunks {
			buf.WriteString(fmt.Sprintf("%x;foo=bar\r\n%s\r\n", len(chunk), chunk))
		}
		buf.WriteString("0\r\n\r\n")
		buf.Flush()
	})
}

func chunkedLeadingZerosHandler(params map[string]interface{}) http.Handler {
	chunks := getStringSlice(params, "chunks")
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, buf, ok := hijackConn(w)
		if !ok {
			return
		}
		defer conn.Close()
		buf.WriteString("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n")
		for _, chunk := range chunks {
			buf.WriteString(fmt.Sprintf("%04x\r\n%s\r\n", len(chunk), chunk))
		}
		buf.WriteString("0\r\n\r\n")
		buf.Flush()
	})
}

func chunkedMixedHexHandler(params map[string]interface{}) http.Handler {
	chunks := getStringSlice(params, "chunks")
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, buf, ok := hijackConn(w)
		if !ok {
			return
		}
		defer conn.Close()
		buf.WriteString("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n")
		for _, chunk := range chunks {
			hexStr := fmt.Sprintf("%x", len(chunk))
			hexStr = strings.ToLower(hexStr[:1]) + strings.ToUpper(hexStr[1:])
			if len(hexStr) == 1 {
				hexStr = strings.ToUpper(hexStr)
			}
			buf.WriteString(fmt.Sprintf("%s\r\n%s\r\n", hexStr, chunk))
		}
		buf.WriteString("0\r\n\r\n")
		buf.Flush()
	})
}

func bareNewlineHandler(params map[string]interface{}) http.Handler {
	body := getString(params, "body", "hello")
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, buf, ok := hijackConn(w)
		if !ok {
			return
		}
		defer conn.Close()
		buf.WriteString(fmt.Sprintf("HTTP/1.1 200 OK\nContent-Length: %d\n\n%s", len(body), body))
		buf.Flush()
	})
}

func owsHeadersHandler(params map[string]interface{}) http.Handler {
	body := getString(params, "body", "test")
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, buf, ok := hijackConn(w)
		if !ok {
			return
		}
		defer conn.Close()
		buf.WriteString(fmt.Sprintf("HTTP/1.1 200 OK\r\nContent-Length: %d\r\nX-With-Spaces:  has-ows  \r\n\r\n%s", len(body), body))
		buf.Flush()
	})
}

func headerEchoHandler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		headers := make(map[string][]string)
		for k, v := range r.Header {
			headers[k] = v
		}
		resp := map[string]interface{}{
			"headers": headers,
		}
		data, _ := json.Marshal(resp) // test helper, input is controlled
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Content-Length", fmt.Sprintf("%d", len(data)))
		w.Write(data)
	})
}

func emptyEOFHandler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, buf, ok := hijackConn(w)
		if !ok {
			return
		}
		defer conn.Close()
		buf.WriteString("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n")
		buf.Flush()
	})
}

func multi1xxHandler(params map[string]interface{}) http.Handler {
	body := getString(params, "body", "final")
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, buf, ok := hijackConn(w)
		if !ok {
			return
		}
		defer conn.Close()
		buf.WriteString("HTTP/1.1 100 Continue\r\n\r\n")
		buf.WriteString("HTTP/1.1 103 Early Hints\r\nLink: </style.css>; rel=preload\r\n\r\n")
		buf.WriteString(fmt.Sprintf("HTTP/1.1 200 OK\r\nContent-Length: %d\r\n\r\n%s", len(body), body))
		buf.Flush()
	})
}

func payloadLimitHandler(params map[string]interface{}) http.Handler {
	maxBytes := getInt(params, "max_bytes", 10)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body) // test helper, input is controlled
		r.Body.Close()
		if len(body) > maxBytes {
			w.Header().Set("Content-Type", "text/plain")
			w.Header().Set("Content-Length", "17")
			w.WriteHeader(413)
			w.Write([]byte("Payload Too Large"))
			return
		}
		w.Header().Set("Content-Type", "text/plain")
		w.Header().Set("Content-Length", "2")
		w.WriteHeader(200)
		w.Write([]byte("OK"))
	})
}

func hijackConn(w http.ResponseWriter) (net.Conn, *bufio.ReadWriter, bool) {
	hj, ok := w.(http.Hijacker)
	if !ok {
		http.Error(w, "cannot hijack", 500)
		return nil, nil, false
	}
	conn, buf, _ := hj.Hijack()
	return conn, buf, true
}

func getString(params map[string]interface{}, key string, defaultVal ...string) string {
	val, ok := params[key]
	if !ok {
		if len(defaultVal) > 0 {
			return defaultVal[0]
		}
		return ""
	}
	s, ok := val.(string)
	if !ok {
		return fmt.Sprintf("%v", val)
	}
	return s
}

func getInt(params map[string]interface{}, key string, defaultVal int) int {
	val, ok := params[key]
	if !ok {
		return defaultVal
	}
	switch v := val.(type) {
	case float64:
		return int(v)
	case int:
		return v
	case json.Number:
		n, _ := v.Int64()
		return int(n)
	}
	return defaultVal
}

func getStringSlice(params map[string]interface{}, key string) []string {
	val, ok := params[key]
	if !ok {
		return nil
	}
	arr, ok := val.([]interface{})
	if !ok {
		return nil
	}
	result := make([]string, len(arr))
	for i, v := range arr {
		result[i], _ = v.(string)
	}
	return result
}

func getStringMap(params map[string]interface{}, key string) map[string]string {
	val, ok := params[key]
	if !ok {
		return nil
	}
	m, ok := val.(map[string]interface{})
	if !ok {
		return nil
	}
	result := make(map[string]string)
	for k, v := range m {
		result[k], _ = v.(string)
	}
	return result
}
