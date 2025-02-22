-- protocol detail: https://mariadb.com/kb/en/clientserver-protocol/

local core = require "core"
local time = require "core.time"
local hash = require "core.crypto.hash"
local tcp = require "core.net.tcp"
local c = require "core.db.mysql.c"
local logger = require "core.logger"

local sub = string.sub
local strgsub = string.gsub
local strbyte = string.byte
local strchar = string.char
local strrep = string.rep
local strunpack = string.unpack
local strpack = string.pack
local setmetatable = setmetatable
local tremove = table.remove
local nowsec = time.nowsec

local tcp_connect = tcp.connect
local tcp_close = tcp.close
local tcp_read = tcp.read
local tcp_write = tcp.write

local digest = hash.digest
local sha1 = hash.new("sha1")

local C
local P

local cmt
local pmt

--- @class stmt
--- @field prepare_id number
--- @field warning_count number
--- @field param_count number
--- @field field_count number
--- @field params row[]
--- @field fields row[]

--- @class conn
--- @field private pool pool
--- @field private fd number				#socket fd
--- @field private auth_plugin_name string		#auth plugin name
--- @field private connection_id number			#connection id
--- @field private packet_no number			#packet number
--- @field private created_at number			#connection created time
--- @field private returned_at number			#connection returned time
--- @field private protocol_version number		#protocol version
--- @field private server_version string		#server version
--- @field private server_capabilities number		#server capabilities
--- @field private server_collation number		#server collation
--- @field private server_status number			#server status
--- @field private stmt_cache stmt[]			#statement cache
--- @field private is_broken boolean			#connection is broken
--- @field private is_autocommit boolean		#connection is autocommit

--- @class pool
--- @field addr string
--- @field database string
--- @field user string
--- @field private password string
--- @field charset string
--- @field max_packet_size number
--- @field max_open_conns number
--- @field max_idle_conns number
--- @field max_idle_time number
--- @field max_lifetime number
--- @field private conns_idle conn[]
--- @field private open_count number
--- @field private waiting_for_conn thread[]
--- @field private is_closed boolean

--- @class open_opts
--- @field addr string  #host:port
--- @field user string
--- @field password string
--- @field max_open_conns number? #default 0
--- @field max_idle_conns number? #default 0
--- @field max_idle_time number? #default 0
--- @field max_lifetime number? #default 0
--- @field database string? #default ""
--- @field charset string? #default _default
--- @field max_packet_size number? #default 1024 * 1024
--- @field compact_arrays boolean? #default false

--- @class eof_packet {
---	@field type string
---	@field warning_count number
---	@field status_flags number
--- }

--- @class err_packet {
---	@field type string
---	@field errno number?		#int<2>
---     #progress reporting
--- 	@field stage number?		#int<1>
--- 	@field progress number?		#int<1>
--- 	@field progress_info string?	#string<lenenc>
--- 	#else
--- 	@field sql_stage string?	#string<lenenc>
--- 	@field message string?		#string<EOF>
--- }

--- @class local_infile_packet {
---	@field type string
---	@field filename string
--- }

--- @class ok_packet {
---	@field type string
---	@field affected_rows number
---	@field last_insert_id number
---	@field server_status number
---	@field warning_count number
---	@field message string?
--- }

--- @class column_def {
---	@field name string
---	@field type number
---	@field is_signed boolean
--- }

--- @class row {
---	@field [string] string
--- }

-- constants
local COM_QUIT<const> = "\x01"
local COM_QUERY<const> = "\x03"
local COM_PING<const> = "\x0e"
local COM_STMT_PREPARE<const> = "\x16"
local COM_STMT_EXECUTE<const> = "\x17"
local COM_STMT_CLOSE<const> = "\x19"
local COM_STMT_RESET<const> = "\x1a"
local COM_BEGIN<const> = COM_QUERY .. "BEGIN"
local COM_COMMIT<const> = COM_QUERY .. "COMMIT"
local COM_ROLLBACK<const> = COM_QUERY .. "ROLLBACK"

local CURSOR_TYPE_NO_CURSOR<const> = 0x00
local SERVER_MORE_RESULTS_EXISTS<const> = 8

local OK<const> = 0x00
local EOF<const> = 0xfe
local ERR<const> = 0xff

local CLIENT_SSL<const> = 0x00000800
local CLIENT_PLUGIN_AUTH<const> = 0x00080000
local CLIENT_PLUGIN_AUTH_LENENC_CLIENT_DATA<const> = 0x00200000
local DEFAULT_AUTH_PLUGIN<const> = "mysql_native_password"

-- the following charset map is generated from the following mysql query:
--   SELECT CHARACTER_SET_NAME, ID
--   FROM information_schema.collations
--   WHERE IS_DEFAULT = 'Yes' ORDER BY id;
local CHARSET_MAP = {
	_default  = 0,
	big5	  = 1,
	dec8	  = 3,
	cp850	 = 4,
	hp8	   = 6,
	koi8r	 = 7,
	latin1	= 8,
	latin2	= 9,
	swe7	  = 10,
	ascii	 = 11,
	ujis	  = 12,
	sjis	  = 13,
	hebrew	= 16,
	tis620	= 18,
	euckr	 = 19,
	koi8u	 = 22,
	gb2312	= 24,
	greek	 = 25,
	cp1250	= 26,
	gbk	   = 28,
	latin5	= 30,
	armscii8  = 32,
	utf8	  = 33,
	ucs2	  = 35,
	cp866	 = 36,
	keybcs2   = 37,
	macce	 = 38,
	macroman  = 39,
	cp852	 = 40,
	latin7	= 41,
	utf8mb4   = 45,
	cp1251	= 51,
	utf16	 = 54,
	utf16le   = 56,
	cp1256	= 57,
	cp1257	= 59,
	utf32	 = 60,
	binary	= 63,
	geostd8   = 92,
	cp932	 = 95,
	eucjpms   = 97,
	gb18030   = 248
}

local pkt_fmt_cache = setmetatable({}, {
	__index = function(t, k)
		local v = "<I3Bc" .. k
		t[k] = v
		return v
	end
})

local prepare_pkt_cache = setmetatable({}, {
	__index = function(t, sql)
		local cmd = COM_STMT_PREPARE .. sql
		local pkt = strpack(pkt_fmt_cache[#cmd], #cmd, 0, cmd)
		t[sql] = pkt
		return pkt
	end
})


local ping_packet = strpack("<I3Bc1", 1, 0, COM_PING)
local quit_packet = strpack("<I3Bc1", 1, 0, COM_QUIT)
local begin_packet = strpack("<I3Bc6", 6, 0, COM_BEGIN)
local commit_packet = strpack("<I3Bc7", 7, 0, COM_COMMIT)
local rollback_packet = strpack("<I3Bc9", 9, 0, COM_ROLLBACK)

--- @overload fun(data:string, pos:number): number|nil, number
local parse_lenenc = c.parse_lenenc
--- @overload fun(packet:string): ok_packet
local parse_ok_packet = c.parse_ok_packet
--- @overload fun(packet:string): eof_packet
local parse_eof_packet = c.parse_eof_packet
--- @overload fun(packet:string): err_packet
local parse_err_packet = c.parse_err_packet
--- @overload fun(packet:string): column_def
local parse_column_def = c.parse_column_def
--- @overload fun(data:string, cols:table<string|number, table>): table<string|number, any>
local parse_row_data_binary = c.parse_row_data_binary
--- @overload fun(prepare_id: number, param_count: number, cursor_type: number, params...): string
local compose_stmt_execute = c.compose_stmt_execute

local function compute_token(password, scramble)
	if password == "" then
		return ""
	end

	local stage1 = digest(sha1, password)
	local stage2 = digest(sha1, stage1)
	local stage3 = digest(sha1, scramble .. stage2)

	local i = 0
	return strgsub(stage3, ".",
		function(x)
			i = i + 1
			-- ~ is xor in lua 5.3
			return strchar(strbyte(x) ~ strbyte(stage1, i))
		end
	)
end

--- @param conn conn
--- @param req string
--- @return string
local function compose_packet(conn, req)
	local packet_no = conn.packet_no + 1
	conn.packet_no = packet_no
	local size = #req
	return strpack(pkt_fmt_cache[size], size, packet_no, req)
end

--- @param conn conn
--- @return string?, string? error
local function read_packet(conn)
	local fd = conn.fd
	local data, err = tcp_read(fd, 4)
	if not data then
		conn.is_broken = true
		return nil, "failed to receive packet header: " .. err
	end
	conn.packet_no = strbyte(data, 4)
	local len, _ = strunpack("<I3", data, 1)
	if len == 0 then
		return nil, "empty packet"
	end
	data, err = tcp_read(fd, len)
	if not data then
		conn.is_broken = true
		return nil, "failed to read packet content: " .. err
	end
	return data, nil
end



local zero_23 = strrep("\0", 23)

-- https://dev.mysql.com/doc/dev/mysql-server/8.4.3/page_protocol_connection_phase_packets_protocol_handshake_v10.html

--- @param conn conn
--- @return boolean, err_packet|nil
local function _mysql_login(conn)
	local packet, err = read_packet(conn)
	if not packet then
		return false, {
			type = "ERR",
			message = err
		}
	end
	if strbyte(packet) == ERR then
		return false, parse_err_packet(packet)
	end
	local protocol_ver = strbyte(packet)
	if protocol_ver ~= 10 then
		return false, {
			type = "ERR",
			message = "unsupported protocol version: " .. protocol_ver
		}
	end
	local auth_plugin_data_part2 = ""
	local auth_plugin_name = DEFAULT_AUTH_PLUGIN
	local server_ver,			--string<NUL>
		connection_id,			--int<4>
		auth_plugin_data_part1,		--string<8>
		filler, 			--int<1>
		server_cap,			--int<2>
		server_collation,		--int<1>
		server_status,			--int<2>
		server_cap2, 			--int<2>
		auth_plugin_data_len,		--int<1>
		pos = strunpack("<zI4c8I1I2I1I2I2I1", packet, 2)
	pos = pos + 10 --skip filler
	server_cap = server_cap | server_cap2 << 16
	if server_cap & CLIENT_PLUGIN_AUTH_LENENC_CLIENT_DATA ~= 0 then
		local len = auth_plugin_data_len - 8 - 1
		if len < 12 then
			len = 12
		end
		auth_plugin_data_part2 = sub(packet, pos, pos + len - 1)
		pos = pos + len
	end
	if server_cap & CLIENT_PLUGIN_AUTH ~= 0 then
		auth_plugin_name = strunpack("<z", packet, pos)
	end
	conn.protocol_version = protocol_ver
	conn.server_version = server_ver
	conn.connection_id = connection_id
	conn.server_capabilities = server_cap
	---@cast server_collation number
	conn.server_collation = server_collation
	---@cast server_status number
	conn.server_status = server_status
	conn.auth_plugin_name = auth_plugin_name
	local pool = conn.pool
	local token = compute_token(pool.password, auth_plugin_data_part1 .. auth_plugin_data_part2)
	local client_flags = 260047
	local req = strpack("<I4I4c1c23zs1z",
		client_flags,
		pool.max_packet_size,
		pool.charset,
		zero_23,
		pool.user,
		token,
		pool.database
	)
	local ok, err = tcp_write(conn.fd, compose_packet(conn, req))
	if not ok then
		return false, {
			type = "ERR",
			message = "failed to write auth packet: " .. err
		}
	end
	local data, err = read_packet(conn)
	if not data then
		return false, {
			type = "ERR",
			message = err
		}
	end
	local first_byte = strbyte(data)
	if first_byte == ERR then
		return false, parse_err_packet(data)
	end
	if first_byte == OK then
		conn.is_broken = false
		return true, nil
	end
	return false, {
		type = "ERR",
		message = "packet type: " .. first_byte
	}
end

--- @param conn conn
--- @param array column_def[]
--- @return boolean, err_packet? error
local function recv_col_def_packet(conn, array)
	local i = #array + 1
	while true do
		local data , err = read_packet(conn)
		if not data then
			return false, {
				type = "ERR",
				message = err,
			}
		end
		local first = strbyte(data)
		if first == EOF then
			break
		end
		array[i] = parse_column_def(data)
		i = i + 1
	end
	return true, nil
end

--- @param conn conn
--- @param sql string
--- @return stmt|? stmt, err_packet? error
local function prepare(conn, sql)
	local ok, data ,err
	ok, err = tcp_write(conn.fd, prepare_pkt_cache[sql])
	if not ok then
		conn.is_broken = true
		return nil, {
			type = "ERR",
			message = "failed to write prepare packet: " .. err,
		}
	end
	data, err = read_packet(conn)
	if not data then
		return nil, {
			type = "ERR",
			message = err,
		}
	end
	local typ = strbyte(data, 1)
	if typ ~= OK then
		return nil, parse_err_packet(data)
	end
	local prepare_id, field_count, param_count, warning_count = strunpack("<I4I2I2xI2", data, 2)
	local fields = {}
	local params = {}
	if param_count > 0 then
		ok, err = recv_col_def_packet(conn, params)
		if not ok then
			return nil, err
		end
	end
	if field_count > 0 then
		ok, err = recv_col_def_packet(conn, fields)
		if not ok then
			return nil, err
		end
	end
	return {
		type = "STMT",
		prepare_id = prepare_id,
		field_count = field_count or 0,
		param_count = param_count or 0,
		warning_count = warning_count or 0,
		params = params,
		fields = fields
	}, nil
end

-----------------------------connection--------------------------

--- @param self conn
--- @return ok_packet? result, err_packet? error
local function conn_ping(self)
	local ok, err = tcp_write(self.fd, ping_packet)
	if not ok then
		self.is_broken = true
		return nil, {
			type = "ERR",
			message = "failed to write ping packet: " .. err
		}
	end
	local data, err = read_packet(self)
	if not data then
		return nil, {
			type = "ERR",
			message = "failed to read ping packet: " .. err
		}
	end
	return parse_ok_packet(data), nil
end

--- @param conn conn
--- @param sql string
--- @vararg any
--- @return ok_packet|row[]|nil result, err_packet? error
local function conn_query(conn, sql, ...)
	local err
	local cache = conn.stmt_cache
	local stmt = cache[sql]
	if not stmt then
		stmt, err = prepare(conn, sql)
		if not stmt then
			return nil, err
		end
		cache[sql] = stmt
	end
	conn.packet_no = -1
	local stmt_packet = compose_stmt_execute(stmt.prepare_id, stmt.param_count, CURSOR_TYPE_NO_CURSOR, ...)
	local querypacket = compose_packet(conn, stmt_packet)
	local ok, err = tcp_write(conn.fd, querypacket)
	if not ok then
		conn.is_broken = true
		return nil, {
			type = "ERR",
			message = "failed to write execute packet: " .. err,
		}
	end
	-- read execute result
	local data, errstr = read_packet(conn)
	if not data then
		return nil, {
			type = "ERR",
			message = errstr,
		}
	end
	local first = strbyte(data)
	if first == ERR then
		return nil, parse_err_packet(data)
	end
	if first == OK then
		return parse_ok_packet(data), nil
	end
	-- result set
	-- metadata
	local field_count, _ = parse_lenenc(data, 1)
	local cols = {}
	if field_count > 0 then
		local ok, err = recv_col_def_packet(conn, cols)
		if not ok then
			return nil, err
		end
	end

	local i = 0
	local rows = {}
	while true do
		local data, errstr = read_packet(conn)
		if not data then
			return nil, {
				type = "ERR",
				message = errstr,
			}
		end
		local first = strbyte(data)
		if first == EOF then
			local eof = parse_eof_packet(data)
			if eof.status_flags & SERVER_MORE_RESULTS_EXISTS == 0 then -- no more result set
				break
			end
		else
			i = i + 1
			rows[i] = parse_row_data_binary(data, cols)
		end
	end
	return rows, nil
end

local function conn_close_transaction(packet)
	--- @param conn conn
	--- @return ok_packet? result, err_packet? error
	return function(conn)
		if conn.is_autocommit then
			return nil, {
				type = "ERR",
				message = "not in transaction",
			}
		end
		conn.is_autocommit = true
		local ok, err = tcp_write(conn.fd, packet)
		if not ok then
			conn.is_broken = true
			return nil, {
				type = "ERR",
				message = "failed to write packet: " .. err,
			}
		end
		local data, errstr = read_packet(conn)
		if not data then
			return nil, {
				type = "ERR",
				message = errstr,
			}
		end
		local first = strbyte(data)
		if first == ERR then
			return nil, parse_err_packet(data)
		end
		return parse_ok_packet(data), nil
	end
end

local conn_commit = conn_close_transaction(commit_packet)
local conn_rollback = conn_close_transaction(rollback_packet)

--- @param conn conn
local function conn_close(conn)
	local pool = conn.pool
	if conn.is_autocommit then
		conn_rollback(conn)
	end
	if not pool.is_closed and not conn.is_broken then
		-- try waktup waiting conn
		local waiting_for_conn = pool.waiting_for_conn
		if #waiting_for_conn > 0 then
			local co = tremove(waiting_for_conn)
			if co then
				core.wakeup(co, conn)
			end
			return
		end
		-- trye return to pool
		local conns_idle = pool.conns_idle
		if #conns_idle < pool.max_idle_conns then
			conn.returned_at = nowsec()
			conns_idle[#conns_idle + 1] = conn
			return
		end
	end
	pool.open_count = pool.open_count - 1
	local fd = conn.fd
	conn.fd = nil
	tcp_write(fd, quit_packet)
	tcp_close(fd)
end

--- @param pool pool
--- @return conn? conn, err_packet? error
local function conn_new(pool)
	local lifetime_since
	local now = nowsec()
	local conns_idle = pool.conns_idle
	local max_lifetime = pool.max_lifetime
	if max_lifetime > 0 then
		lifetime_since = now - max_lifetime
	end
	while #conns_idle > 0 do
		local conn = tremove(conns_idle)
		if not conn then
			break
		end
		if not lifetime_since or conn.returned_at > lifetime_since then
			return conn
		end
		--- old conn will be closed
		tcp_close(conn.fd)
		conn.fd = nil
	end
	local max_open_conns = pool.max_open_conns
	if max_open_conns > 0 and pool.open_count >= max_open_conns then
		local co = core.running()
		local waiting_for_conn = pool.waiting_for_conn
		waiting_for_conn[#waiting_for_conn + 1] = co
		local conn = core.wait()
		if conn then
			return conn
		end
	end
	pool.open_count = pool.open_count + 1
	local fd , err = tcp_connect(pool.addr)
	if not fd then
		pool.open_count = pool.open_count - 1
		return nil, {
			type = "ERR",
			message = "connect to " .. pool.addr .. " failed: " .. err
		}
	end
	local conn = setmetatable({
		pool = pool,
		fd = fd,
		packet_no = -1,
		server_capabilities = 0,
		server_collation = 0,
		server_status = 0,
		server_version = "",
		protocol_version = 0,
		created_at = now,
		returned_at = now,
		stmt_cache = {},
		is_broken = true,
		connection_id = 0,
		auth_plugin_name = "",
		is_autocommit = true,
	}, cmt)
	local ok, err = _mysql_login(conn)
	if not ok then
		conn_close(conn)
		return nil, err
	end
	return conn, nil
end

--------------------------connection pool--------------------------
--- @param pool pool
local function pool_clear(pool)
	if pool.is_closed then
		return
	end
	local now = nowsec()
	local idle_since, created_since
	local max_idle_time = pool.max_idle_time
	local max_lifetime = pool.max_lifetime
	if max_idle_time > 0 then
		idle_since = now - max_idle_time
	end
	if max_lifetime > 0 then
		created_since = now - max_lifetime
	end
	local conns_idle = pool.conns_idle
	local wi = 1
	for i = 1, #conns_idle do
		local conn = conns_idle[i]
		if idle_since and conn.returned_at < idle_since or
			created_since and conn.created_at < created_since then
			tcp_close(conn.fd)
			conn.fd = nil
		else
			conns_idle[wi] = conn
			wi = wi + 1
		end
	end
	for i = wi, #conns_idle do -- clear old conn
		conns_idle[i] = nil
	end
	core.timeout(1000, pool_clear, pool)
end

--- @param self pool
local function pool_close(self)
	self.is_closed = true
	local conns_idle = self.conns_idle
	for i = 1, #conns_idle do
		local conn = conns_idle[i]
		local fd = conn.fd
		if fd then
			conn.fd = nil
			tcp_close(fd)
		end
		conns_idle[i] = nil
	end
	local waiting_for_conn = self.waiting_for_conn
	for i = 1, #waiting_for_conn do
		local co = waiting_for_conn[i]
		waiting_for_conn[i] = nil
		core.wakeup(co)
	end
end

--- @param opts open_opts
--- @return pool
local function pool_open(opts)
	local pool = setmetatable({
		addr = opts.addr or "127.0.0.1:3306",
		database = opts.database or "",
		user = opts.user or "",
		password = opts.password or "",
		charset = strchar(CHARSET_MAP[opts.charset or "_default"]),
		max_packet_size = opts.max_packet_size or (1024 * 1024), -- default 1 MB
		max_open_conns = opts.max_open_conns or 0,
		max_idle_conns = opts.max_idle_conns or 0,
		max_idle_time = opts.max_idle_time or 0,
		max_lifetime = opts.max_lifetime or 0,
		open_count = 0,
		conns_idle = {},
		waiting_for_conn = {},
		is_closed = false,
	}, pmt)
	if pool.max_idle_time > 0 or pool.max_lifetime > 0 then
		core.timeout(1000, pool_clear, pool)
	end
	return pool
end

--- @param self pool
--- @return ok_packet? result, err_packet? error
local function pool_ping(self)
	local conn<close>, err = conn_new(self)
	if not conn then
		return nil, err
	end
	return conn_ping(conn)
end

--- @param self pool
--- @param sql string
--- @vararg any
--- @return ok_packet|row[]? result, err_packet? error
local function pool_query(self, sql, ...)
	if self.is_closed then
		return nil, {
			type = "ERR",
			message = "pool is closed",
		}
	end
	local conn<close>, err = conn_new(self)
	if not conn then
		return nil, err
	end
	return conn_query(conn, sql, ...)
end

--- @param self pool
--- @return conn? conn, err_packet? error
local function pool_begin(self)
	local conn, err = conn_new(self)
	if not conn then
		return nil, err
	end
	local ok, err = tcp_write(conn.fd, begin_packet)
	if not ok then
		conn.is_broken = true
		conn_close(conn)
		return nil, {
			type = "ERR",
			message = "failed to write begin packet: " .. err,
		}
	end
	local data, errstr = read_packet(conn)
	if not data then
		conn_close(conn)
		return nil, {
			type = "ERR",
			message = errstr,
		}
	end
	local first = strbyte(data)
	if first == ERR then
		conn_close(conn)
		return nil, parse_err_packet(data)
	end
	conn.is_autocommit = false
	return conn, nil
end

----------export

--- @class conn
C = {
	close = conn_close,
	ping = conn_ping,
	query = conn_query,
	commit = conn_commit,
	rollback = conn_rollback,
}

cmt = {
	__index = C,
	__close = conn_close,
	__gc = function(conn)
		local fd = conn.fd
		if fd then
			logger.error("[core.db.mysql] connection leaked", fd)
			conn.fd = nil
			local ok = tcp_close(fd)
		end
	end
}


--- @class pool
P = {
	_VERSION = "0.14",
	open = pool_open,
	close = pool_close,
	ping = pool_ping,
	query = pool_query,
	begin = pool_begin,
}

pmt = {
	__index = P,
	__gc = P.close,
}

return P
