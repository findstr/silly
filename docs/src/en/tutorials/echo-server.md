---
title: TCP Echo Server Tutorial
icon: server
order: 2
category:
  - Tutorials
tag:
  - TCP
  - Network Programming
  - Coroutines
  - Async I/O
---

# TCP Echo Server Tutorial

## Learning Objectives

Through this tutorial, you will learn:

- **Network Programming Basics**: Understand how TCP servers work
- **TCP Protocol**: Master TCP connection establishment, data transmission, and closure
- **Lua Coroutines**: Learn to use coroutines to handle concurrent connections
- **Async I/O**: Understand Silly framework's asynchronous programming model
- **Error Handling**: Properly handle network errors and connection closures

## What is an Echo Server?

An Echo server is a simple network server that returns the data sent by the client unchanged. This is a classic introductory example for learning network programming because it:

- **Simple and Intuitive**: Logic is simple and easy to understand
- **Practical Value**: Can be used for network connectivity testing
- **Complete Flow**: Covers the complete network programming process including listening, receiving, sending, and closing

Typical Echo server workflow:

```
Client                     Server
  |                          |
  |---- "Hello" ------------>|
  |<--- "Hello" -------------|
  |                          |
  |---- "World" ------------>|
  |<--- "World" -------------|
  |                          |
```

## Implementation Steps

### Step 1: Create Listening Server

First, we need to create a TCP listening server on a specified address and port:

```lua
local socket = require "silly.net.tcp"

socket.listen("127.0.0.1:9999", function(conn)
    -- conn: client connection object
    print("New client connection:", conn:remoteaddr())
end)
```

**Key Points**:
- `socket.listen()` creates a listening socket at the specified address
- The callback function is called whenever a new client connects
- The callback function executes in an independent coroutine and does not block the main thread

### Step 2: Handle Client Connections

In the callback function, we need to loop and read client data and echo it back:

```lua
socket.listen("127.0.0.1:9999", function(conn)
    print("New client connection:", conn:remoteaddr())

    while true do
        -- Read one line
        local data, err = conn:read("\n")
        if err then
            print("Read error:", err)
            break
        end

        -- Echo data
        local ok, werr = conn:write(data)
        if not ok then
            print("Write error:", werr)
            break
        end
    end

    -- Close connection
    conn:close()
end)
```

### Step 3: Read and Echo Data

Silly provides multiple reading methods:

- `conn:read(delim)`: Read until delimiter is encountered (e.g., `"\n"`)
- `conn:read(n)`: Read specified number of bytes
- `conn:read(conn:unreadbytes())`: Read all available data

For Echo server, we use `read()` to read by line:

```lua
local line, err = conn:read("\n")  -- Read one line (including \n)
if err then
    -- Read failed, possibly connection closed or network error
    print("Read failed:", err)
    break
end

-- Echo data
local ok, werr = conn:write(line)
if not ok then
    print("Write failed:", werr)
    break
end
```

### Step 4: Graceful Shutdown

When a connection error occurs or the client closes the connection, we need to clean up resources:

```lua
while true do
    local data, err = conn:read("\n")
    if err then
        print("Connection closed:", conn:remoteaddr(), err)
        break
    end

    local ok, werr = conn:write(data)
    if not ok then
        print("Write failed:", conn:remoteaddr(), werr)
        break
    end
end

-- Close connection
conn:close()
print("Connection closed:", conn:remoteaddr())
```

## Complete Code

Below is a complete Echo server implementation, including server and client test code:

```lua
local silly = require "silly"
local task = require "silly.task"
local time = require "silly.time"
local crypto = require "silly.crypto.utils"
local socket = require "silly.net.tcp"

-- Start Echo server
socket.listen("127.0.0.1:9999", function(conn)
    print("Accept connection", conn:remoteaddr())

    while true do
        -- Read one line
        local line, err = conn:read("\n")
        if err then
            print("Read error [", conn:remoteaddr(), "] ->", err)
            break
        end

        -- Echo data
        local ok, werr = conn:write(line)
        if not ok then
            print("Write error [", conn:remoteaddr(), "] ->", werr)
            break
        end
    end

    -- Close connection
    print("Close connection", conn:remoteaddr())
    conn:close()
end)

-- Start test clients
-- Create 3 clients for testing
for i = 1, 3 do
    task.fork(function()
        -- Connect to server
        local conn, err = socket.connect("127.0.0.1:9999")
        if not conn then
            print("Connect failed:", err)
            return
        end

        print("Client", i, "connected:", conn:remoteaddr())

        -- Send 5 test messages
        for j = 1, 5 do
            -- Generate random data
            local msg = crypto.randomkey(5) .. "\n"
            print("Send [", conn:remoteaddr(), "] ->", msg)

            -- Send data
            local ok, werr = conn:write(msg)
            if not ok then
                print("Send failed [", conn:remoteaddr(), "] ->", werr)
                break
            end

            -- Receive echo data
            local recv, rerr = conn:read("\n")
            if not recv then
                print("Receive failed [", conn:remoteaddr(), "] ->", rerr)
                break
            end

            print("Receive [", conn:remoteaddr(), "] ->", recv)

            -- Verify echo data correctness
            assert(recv == msg, "Echo data mismatch!")

            -- Wait 1 second
            time.sleep(1000)
        end

        -- Close connection
        print("Client close connection", conn:remoteaddr())
        conn:close()
    end)
end
```

Save the code as `echo-server.lua`.

## Running and Testing

### Start the Server

```bash
cd /path/to/silly
./silly echo-server.lua
```

You will see output similar to:

```
Accept connection 4 127.0.0.1:xxxxx
Client 1 connected, fd: 5
Send [fd: 5] -> AbCdE
Receive [fd: 5] -> AbCdE
Accept connection 6 127.0.0.1:xxxxx
Client 2 connected, fd: 7
...
```

### Testing with telnet

While the server is running, open another terminal:

```bash
telnet 127.0.0.1 9999
```

Then type any text and press Enter:

```
Trying 127.0.0.1...
Connected to 127.0.0.1.
Escape character is '^]'.
Hello Silly!
Hello Silly!
This is a test
This is a test
```

The server will immediately echo what you typed.

### Testing with Client Code

The complete code above already includes test clients. When running, it will automatically create 3 clients, each sending 5 messages.

If you want to write a separate client:

```lua
local silly = require "silly"
local task = require "silly.task"
local socket = require "silly.net.tcp"

task.fork(function()
    -- Connect to server
    local conn, err = socket.connect("127.0.0.1:9999")
    if not conn then
        print("Connect failed:", err)
        return
    end

    print("Connected to server:", conn:remoteaddr())

    -- Send message
    conn:write("Hello from client\n")

    -- Receive echo
    local msg, rerr = conn:read("\n")
    if msg then
        print("Received echo:", msg)
    else
        print("Receive failed:", rerr)
    end

    -- Close connection
    conn:close()
end)
```

## Code Analysis

### Listen Function

```lua
socket.listen(addr, callback, backlog)
```

**Parameters**:
- `addr`: Listen address in format `"IP:port"`, e.g., `"127.0.0.1:9999"` or `"0.0.0.0:8080"`
- `callback`: Client connection callback function with signature `function(conn)`
  - `conn`: Client connection object
- `backlog`: (optional) Listen queue length, default is 128

**Return Value**:
- Success: Returns listener object
- Failure: Returns `nil` and error message

**Important Features**:
- Each client connection is handled in an **independent coroutine**
- Coroutines don't block each other, enabling high-concurrency processing
- When the callback function returns or encounters an error, the framework automatically closes the connection

### Coroutine Processing

Silly uses Lua coroutines to implement asynchronous I/O:

```lua
-- Each client connection runs in an independent coroutine
socket.listen("127.0.0.1:9999", function(conn)
    -- Code here runs in an independent coroutine
    while true do
        local data = conn:read("\n")  -- Async read, doesn't block other connections
        if err then break end
        conn:write(data)              -- Async write
    end
    conn:close()
end)
```

**Advantages of Coroutines**:
- **Synchronous-Style Code**: Looks like synchronous code but executes asynchronously
- **High Concurrency**: Can handle thousands of connections simultaneously
- **Zero Callbacks**: No nested callback functions, code is clear and readable

### Read Operations

All read operations are **asynchronous**:

```lua
-- Read one line (blocks until \n is received)
local line, err = conn:read("\n")

-- Read specified number of bytes (blocks until n bytes are received)
local data, err = conn:read(1024)

-- Read all available data
local data, err = conn:read(conn:unreadbytes())
```

**Return Values**:
- Success: Returns data string
- Failure: Returns `nil` and error message (might be `nil`, indicating connection closed)

### Write Operations

```lua
local ok, err = conn:write(data)
```

**Features**:
- Write operations are **non-blocking**
- Data is buffered to the send queue
- Returns error if send queue is full

**Return Values**:
- Success: Returns `true`
- Failure: Returns `false` and error message

### Error Handling

Network programming must handle various error conditions:

```lua
-- Read errors
local data, err = conn:read("\n")
if err then
    if err then
        print("Network error:", err)
    else
        print("Client closed connection normally")
    end
    conn:close()
    return
end

-- Write errors
local ok, werr = conn:write(data)
if not ok then
    print("Write failed:", werr)
    conn:close()
    return
end
```

**Common Errors**:
- Connection closed: `err` is `nil` or `"socket closed"`
- Network error: `err` contains specific error message (e.g., `"Connection reset by peer"`)
- Active close: `err` is `"active closed"`

## Extension Exercises

### 1. Support Multiple Concurrent Clients

The current code already supports multiple clients, but you can try:

```lua
-- Add connection counter
local connections = 0

socket.listen("127.0.0.1:9999", function(conn)
    connections = connections + 1
    print(string.format("New connection from %s, current connections: %d",
        conn:remoteaddr(), connections))

    while true do
        local line, err = conn:read("\n")
        if err then break end
        conn:write(line)
    end

    connections = connections - 1
    conn:close()
    print(string.format("Connection closed %s, remaining connections: %d",
        conn:remoteaddr(), connections))
end)
```

### 2. Add Timeout Handling

Use `time.after()` to add timeout mechanism:

```lua
local time = require "silly.time"

socket.listen("127.0.0.1:9999", function(conn)
    print("New connection:", conn:remoteaddr())

    -- Set 30-second timeout
    local timeout_timer = time.after(30000, function()
        print("Connection timeout:", conn:remoteaddr())
        conn:close()
    end)

    while true do
        local line, err = conn:read("\n")
        if err then break end

        -- Data activity, reset timeout
        time.cancel(timeout_timer)
        timeout_timer = time.after(30000, function()
            print("Connection timeout:", conn:remoteaddr())
            conn:close()
        end)

        conn:write(line)
    end

    time.cancel(timeout_timer)
    conn:close()
end)
```

### 3. Add Data Statistics

Record data transfer volume for each connection:

```lua
socket.listen("127.0.0.1:9999", function(conn)
    local bytes_recv = 0
    local bytes_sent = 0
    local msg_count = 0

    print("New connection:", conn:remoteaddr())

    while true do
        local line, err = conn:read("\n")
        if err then break end

        bytes_recv = bytes_recv + #line
        msg_count = msg_count + 1

        local ok = conn:write(line)
        if ok then
            bytes_sent = bytes_sent + #line
        else
            break
        end
    end

    conn:close()
    print(string.format("Connection %s statistics: received %d bytes, sent %d bytes, messages %d",
        conn:remoteaddr(), bytes_recv, bytes_sent, msg_count))
end)
```

### 4. Implement Simple Protocol

Make the Echo server support simple commands:

```lua
socket.listen("127.0.0.1:9999", function(conn)
    conn:write("Welcome to Silly Echo Server!\n")
    conn:write("Type 'help' for commands\n")

    while true do
        conn:write("> ")
        local line, err = conn:read("\n")
        if err then break end

        local cmd = line:match("^%s*(.-)%s*$")  -- Trim whitespace

        if cmd == "help" then
            conn:write("Command list:\n")
            conn:write("  help  - Show this help\n")
            conn:write("  time  - Show server time\n")
            conn:write("  quit  - Disconnect\n")
        elseif cmd == "time" then
            conn:write(os.date() .. "\n")
        elseif cmd == "quit" then
            conn:write("Goodbye!\n")
            break
        else
            conn:write("Echo: " .. line)
        end
    end

    conn:close()
end)
```

### 5. Performance Testing

Write a stress test client:

```lua
local silly = require "silly"
local task = require "silly.task"
local socket = require "silly.net.tcp"

local client_count = 100  -- 100 concurrent clients
local msg_per_client = 100  -- 100 messages per client

local start_time = os.time()
local total_messages = 0

for i = 1, client_count do
    task.fork(function()
        local conn = socket.connect("127.0.0.1:9999")
        if not conn then return end

        for j = 1, msg_per_client do
            conn:write("test message\n")
            local msg = conn:read("\n")
            if msg then
                total_messages = total_messages + 1
            end
        end

        conn:close()

        if i == client_count then
            local elapsed = os.time() - start_time
            print(string.format("Completed: %d messages, elapsed %d seconds, %.2f msg/s",
                total_messages, elapsed, total_messages / elapsed))
        end
    end)
end
```

## Next Steps

Congratulations on completing the TCP Echo Server tutorial! Now you have mastered:

- Basic usage of Silly framework
- TCP server implementation
- Coroutines and asynchronous I/O
- Error handling and resource management

Next, you can learn:

- **[HTTP Server Tutorial](./http-server.md)**: Build web applications
- **[WebSocket Tutorial](./websocket-chat.md)**: Implement real-time communication
- **[Database Application Tutorial](./database-app.md)**: Use MySQL and Redis

Continue exploring the powerful features of Silly framework!
