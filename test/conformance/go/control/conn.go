package control

import (
	"bufio"
	"encoding/json"
	"net"
)

type Command struct {
	ID     int                    `json:"id"`
	Cmd    string                 `json:"cmd"`
	Params map[string]interface{} `json:"params,omitempty"`
}

type Response struct {
	ID     int         `json:"id"`
	Result interface{} `json:"result,omitempty"`
	Error  string      `json:"error,omitempty"`
}

func ReadCommand(r *bufio.Reader) (*Command, error) {
	line, err := r.ReadString('\n')
	if err != nil {
		return nil, err
	}
	var cmd Command
	if err := json.Unmarshal([]byte(line), &cmd); err != nil {
		return nil, err
	}
	return &cmd, nil
}

func WriteResponse(conn net.Conn, resp *Response) error {
	data, err := json.Marshal(resp)
	if err != nil {
		return err
	}
	data = append(data, '\n')
	_, err = conn.Write(data)
	return err
}
