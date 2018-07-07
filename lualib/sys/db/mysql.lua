-- Copyright (C) 2012 Yichun Zhang (agentzh)


local sfifo = require "sys.socketdispatch"
local crypt = require "sys.crypt"
local sub = string.sub
local strbyte = string.byte
local strchar = string.char
local strfind = string.find
local strpack = string.pack
local strunpack = string.unpack
local format = string.format
local strrep = string.rep
local sha1 = crypt.sha1
local concat = table.concat
local unpack = unpack
local setmetatable = setmetatable
local error = error
local tonumber = tonumber

local print = function() end

local ok, new_tab = pcall(require, "table.new")
if not ok then
        new_tab = function (narr, nrec) return {} end
end


local _M = { _VERSION = '0.15' }

-- constants

local STATE_CONNECTED = 1
local STATE_COMMAND_SENT = 2

local COM_QUERY = 0x03
local CLIENT_SSL = 0x0800

local SERVER_MORE_RESULTS_EXISTS = 8

-- 16MB - 1, the default max allowed packet size used by libmysqlclient
local FULL_PACKET_SIZE = 16777215


local mt = { __index = _M }


-- mysql field value type converters
local converters = new_tab(0, 8)

for i = 0x01, 0x05 do
        -- tiny, short, long, float, double
        converters[i] = tonumber
end
-- converters[0x08] = tonumber  -- long long
converters[0x09] = tonumber  -- int24
converters[0x0d] = tonumber  -- year
converters[0xf6] = tonumber  -- newdecimal


local function _get_byte2(data, i)
	return strunpack("<I2", data, i)
end


local function _get_byte3(data, i)
        return strunpack("<I3", data, i)
end


local function _get_byte4(data, i)
        return strunpack("<I4", data, i)
end


local function _get_byte8(data, i)
            return strunpack("<I8", data, i)
end


local function _set_byte2(n)
            return strpack("<I2", n)
end


local function _set_byte3(n)
            return strpack("<I3", n)
end

local function _set_byte4(n)
            return strpack("<I4", n)
end


local function _from_cstring(data, i)
        local last = strfind(data, "\0", i, true)
        if not last then
            return nil, nil
        end

        return sub(data, i, last), last + 1
end


local function _to_cstring(data)
        return data .. "\0"
end


local function _to_binary_coded_string(data)
        return strchar(#data) .. data
end


local function _dump(data)
        local len = #data
        local bytes = new_tab(len, 0)
        for i = 1, len do
            bytes[i] = format("%x", strbyte(data, i))
        end
        return concat(bytes, " ")
end

local function _compute_token(password, scramble)
        if password == "" then
            return ""
        end

        local stage1 = sha1(password)
        local stage2 = sha1(stage1)
        local stage3 = sha1(scramble .. stage2)
        local n = #stage1
        local bytes = new_tab(n, 0)
        for i = 1, n do
             bytes[i] = strchar(strbyte(stage3, i) ~ strbyte(stage1, i))
        end

        return concat(bytes)
end


local function _compose_packet(self, req, size)
        self.packet_no = self.packet_no + 1

        print("packet no: ", self.packet_no)

        local packet = _set_byte3(size) .. strchar(self.packet_no) .. req

        print("sending packet: ", _dump(packet))

        print("sending packet... of size " .. #packet)

        return packet

end

local function _send_packet(self, req, size)
        local sock = self.sock
        local packet = _compose_packet(self, req, size)
        return #packet, sock:write(packet)
end

local function _recv_packet(self)
    local sock = self.sock

    local data, err = sock:read(4) -- packet header
    if not data then
        return nil, nil, "failed to receive packet header: " .. err
    end

    --print("packet header: ", _dump(data))

    local len, pos = _get_byte3(data, 1)

    --print("packet length: ", len)

    if len == 0 then
        return nil, nil, "empty packet"
    end

    if len > self._max_packet_size then
        return nil, nil, "packet size too big: " .. len
    end

    local num = strbyte(data, pos)

    --print("recv packet: packet no: ", num)

    self.packet_no = num

    data, err = sock:read(len)

    --print("receive returned")

    if not data then
        return nil, nil, "failed to read packet content: " .. err
    end

    --print("packet content: ", _dump(data))
    --print("packet content (ascii): ", data)

    local field_count = strbyte(data, 1)

    local typ
    if field_count == 0x00 then
        typ = "OK"
    elseif field_count == 0xff then
        typ = "ERR"
    elseif field_count == 0xfe then
        typ = "EOF"
    elseif field_count <= 250 then
        typ = "DATA"
    end

    return data, typ
end


local function _from_length_coded_bin(data, pos)
    local first = strbyte(data, pos)

    --print("LCB: first: ", first)

    if not first then
        return nil, pos
    end

    if first >= 0 and first <= 250 then
        return first, pos + 1
    end

    if first == 251 then
        return null, pos + 1
    end

    if first == 252 then
        pos = pos + 1
        return _get_byte2(data, pos)
    end

    if first == 253 then
        pos = pos + 1
        return _get_byte3(data, pos)
    end

    if first == 254 then
        pos = pos + 1
        return _get_byte8(data, pos)
    end

    return false, pos + 1
end


local function _from_length_coded_str(data, pos)
    local len
    len, pos = _from_length_coded_bin(data, pos)
    if len == nil or len == null then
        return null, pos
    end

    return sub(data, pos, pos + len - 1), pos + len
end


local function _parse_ok_packet(packet)
    local res = new_tab(0, 5)
    local pos

    res.affected_rows, pos = _from_length_coded_bin(packet, 2)

    --print("affected rows: ", res.affected_rows, ", pos:", pos)

    res.insert_id, pos = _from_length_coded_bin(packet, pos)

    --print("insert id: ", res.insert_id, ", pos:", pos)

    res.server_status, pos = _get_byte2(packet, pos)

    --print("server status: ", res.server_status, ", pos:", pos)

    res.warning_count, pos = _get_byte2(packet, pos)

    --print("warning count: ", res.warning_count, ", pos: ", pos)

    local message = sub(packet, pos)
    if message and message ~= "" then
        res.message = message
    end

    --print("message: ", res.message, ", pos:", pos)

    return res
end


local function _parse_eof_packet(packet)
    local pos = 2

    local warning_count, pos = _get_byte2(packet, pos)
    local status_flags = _get_byte2(packet, pos)

    return warning_count, status_flags
end


local function _parse_err_packet(packet)
    local errno, pos = _get_byte2(packet, 2)
    local marker = sub(packet, pos, pos)
    local sqlstate
    if marker == '#' then
        -- with sqlstate
        pos = pos + 1
        sqlstate = sub(packet, pos, pos + 5 - 1)
        pos = pos + 5
    end

    local message = sub(packet, pos)
    return errno, message, sqlstate
end


local function _parse_result_set_header_packet(packet)
    local field_count, pos = _from_length_coded_bin(packet, 1)

    local extra
    extra = _from_length_coded_bin(packet, pos)

    return field_count, extra
end


local function _parse_field_packet(data)
    local col = new_tab(0, 2)
    local catalog, db, table, orig_table, orig_name, charsetnr, length
    local pos
    catalog, pos = _from_length_coded_str(data, 1)

    --print("catalog: ", col.catalog, ", pos:", pos)

    db, pos = _from_length_coded_str(data, pos)
    table, pos = _from_length_coded_str(data, pos)
    orig_table, pos = _from_length_coded_str(data, pos)
    col.name, pos = _from_length_coded_str(data, pos)

    orig_name, pos = _from_length_coded_str(data, pos)

    pos = pos + 1 -- ignore the filler

    charsetnr, pos = _get_byte2(data, pos)

    length, pos = _get_byte4(data, pos)

    col.type = strbyte(data, pos)

    --[[
    pos = pos + 1

    col.flags, pos = _get_byte2(data, pos)

    col.decimals = strbyte(data, pos)
    pos = pos + 1

    local default = sub(data, pos + 2)
    if default and default ~= "" then
        col.default = default
    end
    --]]

    return col
end


local function _parse_row_data_packet(data, cols, compact)
    local pos = 1
    local ncols = #cols
    local row
    if compact then
        row = new_tab(ncols, 0)
    else
        row = new_tab(0, ncols)
    end
    for i = 1, ncols do
        local value
        value, pos = _from_length_coded_str(data, pos)
        local col = cols[i]
        local typ = col.type
        local name = col.name

        --print("row field value: ", value, ", type: ", typ)

        if value ~= null then
            local conv = converters[typ]
            if conv then
                value = conv(value)
            end
        end

        if compact then
            row[i] = value

        else
            row[name] = value
        end
    end

    return row
end


local function _recv_field_packet(self)
    local packet, typ, err = _recv_packet(self)
    if not packet then
        return nil, err
    end

    if typ == "ERR" then
        local errno, msg, sqlstate = _parse_err_packet(packet)
        return nil, msg, errno, sqlstate
    end

    if typ ~= 'DATA' then
        return nil, "bad field packet type: " .. typ
    end

    -- typ == 'DATA'

    return _parse_field_packet(packet)
end

local function _mysql_login(self, opts)
        return function (sock)
                local packet, typ, err = _recv_packet(self)
                if not packet then
                    return false, false, err
                end

                if typ == "ERR" then
                    local errno, msg, sqlstate = _parse_err_packet(packet)
                    return false, false, msg, errno, sqlstate
                end

                self.protocol_ver = strbyte(packet)

                print("protocol version: ", self.protocol_ver)

                local server_ver, pos = _from_cstring(packet, 2)
                if not server_ver then
                    return false, false, "bad handshake initialization packet: bad server version"
                end

                print("server version: ", server_ver)

                self._server_ver = server_ver

                local thread_id, pos = _get_byte4(packet, pos)

                print("thread id: ", thread_id)

                local scramble = sub(packet, pos, pos + 8 - 1)
                if not scramble then
                    return false, false, "1st part of scramble not found"
                end

                pos = pos + 9 -- skip filler

                -- two lower bytes
                local capabilities  -- server capabilities
                capabilities, pos = _get_byte2(packet, pos)

                 print(format("server capabilities: %#x", capabilities))

                self._server_lang = strbyte(packet, pos)
                pos = pos + 1

                print("server lang: ", self._server_lang)

                self._server_status, pos = _get_byte2(packet, pos)

                print("server status: ", self._server_status)

                local more_capabilities
                more_capabilities, pos = _get_byte2(packet, pos)

                capabilities = capabilities | more_capabilities << 16

                print("server capabilities: ", capabilities)

                -- local len = strbyte(packet, pos)
                local len = 21 - 8 - 1

                print("scramble len: ", len)

                pos = pos + 1 + 10

                local scramble_part2 = sub(packet, pos, pos + len - 1)
                if not scramble_part2 then
                    return false, false, "2nd part of scramble not found"
                end

                scramble = scramble .. scramble_part2
                print("scramble: ", _dump(scramble))

                local client_flags = 0x3f7cf;

                local ssl_verify = opts.ssl_verify
                local use_ssl = opts.ssl or ssl_verify

                if use_ssl then
                    if capabilities & CLIENT_SSL == 0 then
                        return false, false, "ssl disabled on server"
                    end

                    -- send a SSL Request Packet
                    local req = _set_byte4(client_flags | CLIENT_SSL)
                                .. _set_byte4(self._max_packet_size)
                                .. "\0" -- TODO: add support for charset encoding
                                .. strrep("\0", 23)

                    local packet_len = 4 + 4 + 1 + 23
                    local bytes, err = _send_packet(self, req, packet_len)
                    if not bytes then
                        return false, false, "failed to send client authentication packet: " .. err
                    end

                    local ok, err = sock:sslhandshake(false, nil, ssl_verify)
                    if not ok then
                        return false, false, "failed to do ssl handshake: " .. (err or "")
                    end
                end

                local user = opts.user or ""
                local password = opts.password or ""
                local database = opts.database or ""
                local token = _compute_token(password, scramble)

                print("token: ", _dump(token))

                local req = _set_byte4(client_flags)
                            .. _set_byte4(self._max_packet_size)
                            .. "\0" -- TODO: add support for charset encoding
                            .. strrep("\0", 23)
                            .. _to_cstring(user)
                            .. _to_binary_coded_string(token)
                            .. _to_cstring(database)

                local packet_len = 4 + 4 + 1 + 23 + #user + 1
                    + #token + 1 + #database + 1

                print("packet content length: ", packet_len)
                print("packet content: ", _dump(req))

                local bytes, err = _send_packet(self, req, packet_len)
                if not bytes then
                    return false, false, "failed to send client authentication packet: " .. err
                end

                print("packet sent ", bytes, " bytes")

                local packet, typ, err = _recv_packet(self)
                if not packet then
                    return false, false, "failed to receive the result packet: " .. err
                end

                if typ == 'ERR' then
                    local errno, msg, sqlstate = _parse_err_packet(packet)
                    return false, false, msg, errno, sqlstate
                end

                if typ == 'EOF' then
                    return false, false, "old pre-4.1 authentication protocol not supported"
                end

                if typ ~= 'OK' then
                    return false, false, "bad packet type: " .. typ
                end

                print("login status: " .. typ)

                self.state = STATE_CONNECTED

                return true, true
        end
end

function _M.create(opts)
        local self = {
                opts = opts,
                auth = nil,
                sock = nil,
        }

        self.auth = _mysql_login(self, opts)
        self.sock = sfifo:create {
                addr = opts.host,
                auth = self.auth
        }

        setmetatable(self, mt)

        local max_packet_size = opts.max_packet_size
        if not max_packet_size then
            max_packet_size = 1024 * 1024 -- default 1 MB
        end
        self._max_packet_size = max_packet_size
        self.compact = opts.compact_arrays

        return self
end

function _M.connect(self)
        return self.sock:connect()
end


function _M.close(self)
    local sock = self.sock
    if not sock then
        return nil, "not initialized"
    end

    self.state = nil

    return sock:close()
end


function _M.server_ver(self)
    return self._server_ver
end

local function read_result(self, est_nrows)
            if self.state ~= STATE_COMMAND_SENT then
                return nil, "cannot read result in the current context: " .. self.state
            end

            local sock = self.sock
            if not sock then
                return nil, "not initialized"
            end

            local packet, typ, err = _recv_packet(self)
            if not packet then
                return nil, err
            end

            if typ == "ERR" then
                self.state = STATE_CONNECTED

                local errno, msg, sqlstate = _parse_err_packet(packet)
                return nil, msg, errno, sqlstate
            end

            if typ == 'OK' then
                local res = _parse_ok_packet(packet)
                if res and res.server_status & SERVER_MORE_RESULTS_EXISTS ~= 0 then
                    return res, "again"
                end

                self.state = STATE_CONNECTED
                return res
            end

            if typ ~= 'DATA' then
                self.state = STATE_CONNECTED

                return nil, "packet type " .. typ .. " not supported"
            end

            -- typ == 'DATA'

            --print("read the result set header packet")

            local field_count, extra = _parse_result_set_header_packet(packet)

            --print("field count: ", field_count)

            local cols = new_tab(field_count, 0)
            for i = 1, field_count do
                local col, err, errno, sqlstate = _recv_field_packet(self)
                if not col then
                    return nil, err, errno, sqlstate
                end

                cols[i] = col
            end

            local packet, typ, err = _recv_packet(self)
            if not packet then
                return nil, err
            end

            if typ ~= 'EOF' then
                return nil, "unexpected packet type " .. typ .. " while eof packet is "
                    .. "expected"
            end

            -- typ == 'EOF'

            local compact = self.compact

            local rows = new_tab(est_nrows or 4, 0)
            local i = 0
            while true do
                --print("reading a row")

                packet, typ, err = _recv_packet(self)
                if not packet then
                    return nil, err
                end

                if typ == 'EOF' then
                    local warning_count, status_flags = _parse_eof_packet(packet)

                    --print("status flags: ", status_flags)

                    if status_flags & SERVER_MORE_RESULTS_EXISTS ~= 0 then
                        return rows, "again"
                    end

                    break
                end

                local row = _parse_row_data_packet(packet, cols, compact)
                i = i + 1
                rows[i] = row
            end

            self.state = STATE_CONNECTED

            return rows
end

local function _query_response(self, est_nrows)
        return function(fifo)
                local res, err, errno, sqlstate = read_result(self, est_nrows)
                if not res then
                        local badresult = {}
                        badresult.badresult = true
                        badresult.err = err
                        badresult.errno = errno
                        badresult.sqlstate = sqlstate
                        return false, badresult
                end

                if err ~= "again" then
                        return true, res
                end

                local multiresultset = {res}
                multiresultset.multiresultset = true
                local i = 2
                while err == "again" do
                        res, err, errno, sqlstate = read_result(self, est_nrows)
                        if not res then
                                return true, multiresultset
                        end
                        multiresultset[i] = res
                        i = i + 1
                end
                return true, multiresultset
        end
end

function _M.query(self, query, est_nrows)
    if self.state ~= STATE_CONNECTED then
        return false,
                "cannot send query in the current context: "
                .. (self.state or "nil")
    end
    local sock = self.sock
    self.packet_no = -1
    local cmd_packet = strchar(COM_QUERY) .. query
    local packet_len = 1 + #query
    local packet = _compose_packet(self, cmd_packet, packet_len)
    self.state = STATE_COMMAND_SENT
    return self.sock:request(packet, _query_response(self, est_nrows))
end


function _M.set_compact_arrays(self, value)
    self.compact = value
end


return _M
