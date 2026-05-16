package httpclient

import (
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

type ResponseInfo struct {
	Status   int               `json:"status"`
	Headers  map[string]string `json:"headers"`
	Body     string            `json:"body"`
	Trailers map[string]string `json:"trailers,omitempty"`
}

func doSingle(client *http.Client, params map[string]any) (*ResponseInfo, error) {
	method, _ := params["method"].(string)
	if method == "" {
		method = "GET"
	}
	url, _ := params["url"].(string)
	if url == "" {
		return nil, fmt.Errorf("missing url")
	}

	var bodyReader io.Reader
	if body, ok := params["body"].(string); ok && body != "" {
		bodyReader = strings.NewReader(body)
	}

	req, err := http.NewRequest(method, url, bodyReader)
	if err != nil {
		return nil, err
	}

	if headers, ok := params["headers"].(map[string]any); ok {
		for k, v := range headers {
			switch vv := v.(type) {
			case string:
				req.Header.Set(k, vv)
			case []any:
				for _, val := range vv {
					if s, ok := val.(string); ok {
						req.Header.Add(k, s)
					}
				}
			}
		}
	}

	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}

	headers := make(map[string]string)
	for k, v := range resp.Header {
		headers[strings.ToLower(k)] = strings.Join(v, ", ")
	}

	var trailers map[string]string
	if len(resp.Trailer) > 0 {
		trailers = make(map[string]string)
		for k, v := range resp.Trailer {
			trailers[strings.ToLower(k)] = strings.Join(v, ", ")
		}
	}

	return &ResponseInfo{
		Status:   resp.StatusCode,
		Headers:  headers,
		Body:     string(body),
		Trailers: trailers,
	}, nil
}

func newClient(params map[string]any) *http.Client {
	timeoutMs := 10000
	if t, ok := params["response_timeout_ms"].(float64); ok {
		timeoutMs = int(t)
	}
	disableKeepAlives := true
	if v, ok := params["disable_keep_alives"].(bool); ok {
		disableKeepAlives = v
	}
	return &http.Client{
		Timeout: time.Duration(timeoutMs) * time.Millisecond,
		Transport: &http.Transport{
			DisableKeepAlives: disableKeepAlives,
		},
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
}

func DoRequest(params map[string]any) (*ResponseInfo, error) {
	client := newClient(params)
	defer client.CloseIdleConnections()
	return doSingle(client, params)
}

func DoRequestPair(params map[string]any) ([]*ResponseInfo, error) {
	first, ok := params["first"].(map[string]any)
	if !ok {
		return nil, fmt.Errorf("missing first request params")
	}
	second, ok := params["second"].(map[string]any)
	if !ok {
		return nil, fmt.Errorf("missing second request params")
	}

	client := newClient(params)
	defer client.CloseIdleConnections()

	r1, err := doSingle(client, first)
	if err != nil {
		return nil, err
	}
	r2, err := doSingle(client, second)
	if err != nil {
		return nil, err
	}
	return []*ResponseInfo{r1, r2}, nil
}

