-- protocol detail: https://mariadb.com/kb/en/clientserver-protocol/

local silly = require "silly"
local time = require "silly.time"
local hash = require "silly.crypto.hash"
local tcp = require "silly.net.tcp"
local c = require "silly.store.mysql.c"
local logger = require "silly.logger"

local sub = string.sub
local strgsub = string.gsub
local strbyte = string.byte
local strchar = string.char
local strrep = string.rep
local strunpack = string.unpack
local strpack = string.pack
local setmetatable = setmetatable
local tremove = table.remove
local timenow = time.monotonic

local tcp_connect = tcp.connect
local tcp_close = tcp.close
local tcp_read = tcp.read
local tcp_write = tcp.write

local digest = hash.digest
local sha1 = hash.new("sha1")
local sha256 = hash.new("sha256")
local pkey = require "silly.crypto.pkey"

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
--- @field pool pool
--- @field fd number				#socket fd
--- @field auth_plugin_name string		#auth plugin name
--- @field connection_id number			#connection id
--- @field packet_no number			#packet number
--- @field created_at number			#connection created time
--- @field returned_at number			#connection returned time
--- @field protocol_version number		#protocol version
--- @field server_version string		#server version
--- @field server_capabilities number		#server capabilities
--- @field server_collation number		#server collation
--- @field server_status number			#server status
--- @field stmt_cache stmt[]			#statement cache
--- @field is_broken boolean			#connection is broken
--- @field is_autocommit boolean		#connection is autocommit

--- @class pool
--- @field addr string
--- @field database string
--- @field user string
--- @field password string
--- @field charset string
--- @field max_packet_size number
--- @field max_open_conns number
--- @field max_idle_conns number
--- @field max_idle_time number
--- @field max_lifetime number
--- @field conns_idle conn[]
--- @field open_count number
--- @field waiting_for_conn thread[]
--- @field is_closed boolean

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

local CLIENT_LONG_PASSWORD<const> = 1
local CLIENT_FOUND_ROWS<const> = 2
local CLIENT_LONG_FLAG<const> = 4
local CLIENT_CONNECT_WITH_DB<const> = 8
local CLIENT_NO_SCHEMA<const> = 16
local CLIENT_IGNORE_SPACE<const> = 256
local CLIENT_PROTOCOL_41<const> = 512
local CLIENT_TRANSACTIONS<const> = 8192
local CLIENT_SECURE_CONNECTION<const> = 32768
local CLIENT_MULTI_STATEMENTS<const> = 65536
local CLIENT_MULTI_RESULTS<const> = 131072

local CLIENT_SSL<const> = 0x00000800
local CLIENT_PLUGIN_AUTH<const> = 0x00080000
local CLIENT_PLUGIN_AUTH_LENENC_CLIENT_DATA<const> = 0x00200000
local DEFAULT_AUTH_PLUGIN<const> = "mysql_native_password"

-- caching_sha2_password protocol constants
local CACHE_SHA2_FAST_AUTH_SUCCESS<const> = 0x03
local CACHE_SHA2_FULL_AUTH_REQUEST<const> = 0x04
local CACHE_SHA2_REQUEST_PUBLIC_KEY<const> = 0x02

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

local function compute_token_sha256(password, scramble)
	if password == "" then
		return ""
	end

	-- caching_sha2_password algorithm (MySQL 8+):
	-- XOR(SHA256(password), SHA256(SHA256(SHA256(password)) || scramble))

	local message1 = digest(sha256, password)                       -- SHA256(password)
	local message1_hash = digest(sha256, message1)                  -- SHA256(SHA256(password))
	local message2 = digest(sha256, message1_hash .. scramble)      -- SHA256(SHA256(SHA256(password)) || scramble)

	local i = 0
	local token = strgsub(message1, ".",
		function(x)
			i = i + 1
			return strchar(strbyte(x) ~ strbyte(message2, i))
		end
	)
	return token
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
		-- The auth_plugin_data_len from the handshake is the length of auth data to be sent
		-- For caching_sha2_password, it's 20 bytes total (8 bytes part1 + 12 bytes part2)
		-- But the packet structure has: 8 bytes part1 + auth_plugin_data_len bytes of part2 + 1 byte NUL
		-- So part2 is auth_plugin_data_len - 8 bytes, but we should read only 12 bytes for the scramble
		local len = 12  -- For caching_sha2_password, we always want exactly 12 bytes for part2
		auth_plugin_data_part2 = sub(packet, pos, pos + len - 1)
		pos = pos + len + 1  -- +1 to skip the trailing NUL that separates part2 from auth_plugin_name
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
	local scramble = auth_plugin_data_part1 .. auth_plugin_data_part2

	-- For caching_sha2_password, scramble should be exactly 20 bytes (without trailing NUL)
	-- MySQL sends part1 (8 bytes) + part2 (12+ bytes), where part2 may have trailing NUL

	if auth_plugin_name == "caching_sha2_password" and #scramble > 20 then
		scramble = sub(scramble, 1, 20)
	end

	-- Compute token based on auth plugin
	local token
	if auth_plugin_name == "caching_sha2_password" then
		token = compute_token_sha256(pool.password, scramble)
	else
		-- default to mysql_native_password
		token = compute_token(pool.password, scramble)
	end

	-- Build client capabilities flags
	-- Only set plugin auth flags if server supports them
	local client_flags = CLIENT_LONG_PASSWORD |
			 CLIENT_FOUND_ROWS |
			 CLIENT_LONG_FLAG |
			 CLIENT_CONNECT_WITH_DB |
			 CLIENT_NO_SCHEMA |
			 CLIENT_IGNORE_SPACE |
			 CLIENT_PROTOCOL_41 |
			 CLIENT_TRANSACTIONS |
			 CLIENT_SECURE_CONNECTION |
			 CLIENT_MULTI_STATEMENTS |
			 CLIENT_MULTI_RESULTS

	-- Add plugin auth capabilities if server supports them
	local send_plugin_name = false
	if server_cap & CLIENT_PLUGIN_AUTH ~= 0 then
		client_flags = client_flags | CLIENT_PLUGIN_AUTH
		send_plugin_name = true
	end
	if server_cap & CLIENT_PLUGIN_AUTH_LENENC_CLIENT_DATA ~= 0 then
		client_flags = client_flags | CLIENT_PLUGIN_AUTH_LENENC_CLIENT_DATA
	end

	-- Build handshake response packet
	-- Format depends on capabilities:
	-- - Basic: client_flags(4) + max_packet_size(4) + charset(1) + filler(23) +
	--          user(z) + auth_response(lenenc) + database(z)
	-- - With CLIENT_PLUGIN_AUTH: ... + auth_plugin_name(z)
	local req
	if send_plugin_name then
		req = strpack("<I4I4c1c23zs1zz",
			client_flags,
			pool.max_packet_size,
			pool.charset,
			zero_23,
			pool.user,
			token,  -- s1 format is compatible with lenenc for length < 251
			pool.database,
			auth_plugin_name
		)
	else
		req = strpack("<I4I4c1c23zs1z",
			client_flags,
			pool.max_packet_size,
			pool.charset,
			zero_23,
			pool.user,
			token,
			pool.database
		)
	end
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

	-- Handle EOF packet which could be auth switch request
	-- In MySQL protocol, 0xFE can mean different things based on packet length:
	-- - length < 9: EOF packet (old protocol, deprecated)
	-- - length >= 9: Auth Switch Request or Auth More Data
	if first_byte == EOF and #data >= 9 then
		-- This is an Auth Switch Request
		-- Format: 0xFE + plugin_name<NUL> + plugin_data<NUL>
		local switch_plugin_name, pos = strunpack("<z", data, 2)
		-- Auth data includes trailing NUL which needs to be removed for correct scramble length
		local switch_auth_data = sub(data, pos, #data - 1)

		-- Server wants us to switch auth method
		-- Compute new token with the new method and scramble
		local new_token
		if switch_plugin_name == "caching_sha2_password" then
			new_token = compute_token_sha256(pool.password, switch_auth_data)
		elseif switch_plugin_name == "mysql_native_password" then
			new_token = compute_token(pool.password, switch_auth_data)
		elseif switch_plugin_name == "sha256_password" then
			-- sha256_password is deprecated in MySQL 8.0+ (use caching_sha2_password instead)
			-- For sha256_password, we need to send password encrypted with server's public key
			-- or plain text if using TLS (which we don't support yet)
			-- Since we don't have TLS, we need to send 0x01 byte to request public key
			new_token = "\x01"
		else
			return false, {
				type = "ERR",
				message = "unsupported auth switch plugin: " .. switch_plugin_name
			}
		end

		-- Send switched auth response
		-- For mysql_native_password and caching_sha2_password, send raw token (20 or 32 bytes)
		-- For sha256_password, send 0x01 to request public key
		ok, err = tcp_write(conn.fd, compose_packet(conn, new_token))
		if not ok then
			return false, {
				type = "ERR",
				message = "failed to write auth switch packet: " .. err
			}
		end

		-- For sha256_password, handle public key exchange
		if switch_plugin_name == "sha256_password" then
			-- Read public key packet
			data, err = read_packet(conn)
			if not data then
				return false, {
					type = "ERR",
					message = "failed to read public key for sha256_password: " .. err
				}
			end

			-- Check for error packet (e.g., invalid user)
			local pkey_first_byte = strbyte(data)
			if pkey_first_byte == ERR then
				return false, parse_err_packet(data)
			end

			-- For debugging: check if this is an OK packet (authentication might have succeeded)
			if pkey_first_byte == OK then
				-- Authentication succeeded without needing public key
				-- This might happen if password is empty or for other reasons
				return true, nil
			end

			-- Public key should start with "-----BEGIN PUBLIC KEY-----" or might be length-prefixed
			-- MySQL sends public key in plain format, may need to skip first byte if it's a length indicator
			local pubkey_data = data
			if not pubkey_data:match("^%-%-%-%-%-BEGIN") then
				-- Try skipping first byte (might be a type indicator)
				if #data > 1 then
					pubkey_data = sub(data, 2)
				end
				if not pubkey_data:match("^%-%-%-%-%-BEGIN") then
					return false, {
						type = "ERR",
						message = string.format("invalid public key format for sha256_password (first bytes: %02x %02x %02x)",
							strbyte(data, 1) or 0, strbyte(data, 2) or 0, strbyte(data, 3) or 0)
					}
				end
			end

			-- Load public key
			local public_key, err = pkey.new(pubkey_data)
			if not public_key then
				return false, {
					type = "ERR",
					message = "failed to load server public key for sha256_password: " .. err
				}
			end
			-- Encrypt password: XOR(password + NULL, scramble) then RSA encrypt
			local pass_null = pool.password .. "\0"
			local scrambled_pass = ""
			for i = 1, #pass_null do
				scrambled_pass = scrambled_pass .. strchar(strbyte(pass_null, i) ~ strbyte(switch_auth_data, (i - 1) % #switch_auth_data + 1))
			end

			local success2, encrypted_pass = pcall(public_key.encrypt, public_key, scrambled_pass, pkey.RSA_PKCS1_OAEP, "sha1")
			if not success2 then
				return false, {
					type = "ERR",
					message = "failed to encrypt password for sha256_password: " .. tostring(encrypted_pass)
				}
			end

			-- Send encrypted password
			ok, err = tcp_write(conn.fd, compose_packet(conn, encrypted_pass))
			if not ok then
				return false, {
					type = "ERR",
					message = "failed to write encrypted password for sha256_password: " .. err
				}
			end
		end

		-- Read response after switch
		data, err = read_packet(conn)
		if not data then
			return false, {
				type = "ERR",
				message = err
			}
		end
		first_byte = strbyte(data)
		auth_plugin_name = switch_plugin_name
	end

	-- Handle caching_sha2_password full auth
	if auth_plugin_name == "caching_sha2_password" and first_byte == 0x01 then
		local second_byte = strbyte(data, 2)
		if second_byte == CACHE_SHA2_FAST_AUTH_SUCCESS then
			-- Fast auth successful, read final OK packet
			data, err = read_packet(conn)
			if not data then
				return false, {
					type = "ERR",
					message = err
				}
			end
			first_byte = strbyte(data)
		elseif second_byte == CACHE_SHA2_FULL_AUTH_REQUEST then
			-- Server requests full authentication
			-- For non-TLS connections, we must use RSA encryption

			-- Request server's public key
			ok, err = tcp_write(conn.fd, compose_packet(conn, "\x02"))
			if not ok then
				return false, {
					type = "ERR",
					message = "failed to write request for public key: " .. err
				}
			end

			-- Read server's public key
			data, err = read_packet(conn)
			if not data then
				return false, {
					type = "ERR",
					message = "failed to read server public key: " .. err
				}
			end

			-- Check if this is an auth more data packet (0x01) containing the public key
			local first_pkey_byte = strbyte(data)
			if first_pkey_byte ~= 0x01 then
				return false, {
					type = "ERR",
					message = string.format("expected auth more data packet with public key, got 0x%02x", first_pkey_byte)
				}
			end

			-- Skip the 0x01 byte and extract the public key
			local pubkey_data = sub(data, 2)

			local public_key, err = pkey.new(pubkey_data)
			if not public_key then
				return false, {
					type = "ERR",
					message = "failed to load server public key: " .. err
				}
			end
			-- Encrypt password: XOR(password + NULL, scramble) then RSA encrypt
			local pass_null = pool.password .. "\0"
			local scramble = auth_plugin_data_part1 .. auth_plugin_data_part2
			local scrambled_pass = ""
			for i = 1, #pass_null do
				scrambled_pass = scrambled_pass .. strchar(strbyte(pass_null, i) ~ strbyte(scramble, (i - 1) % #scramble + 1))
			end

			local encrypted_pass, err = public_key:encrypt(scrambled_pass, pkey.RSA_PKCS1_OAEP, "sha1")
			if not encrypted_pass then
				return false, {
					type = "ERR",
					message = "failed to encrypt password: " .. err
				}
			end

			-- Send encrypted password
			ok, err = tcp_write(conn.fd, compose_packet(conn, encrypted_pass))
			if not ok then
				return false, {
					type = "ERR",
					message = "failed to write encrypted password: " .. err
				}
			end

			-- Read final response
			data, err = read_packet(conn)
			if not data then
				return false, {
					type = "ERR",
					message = err
				}
			end
			first_byte = strbyte(data)
		elseif second_byte == CACHE_SHA2_REQUEST_PUBLIC_KEY then
			-- Request server's public key
			ok, err = tcp_write(conn.fd, compose_packet(conn, "\x02"))
			if not ok then
				return false, {
					type = "ERR",
					message = "failed to write request for public key: " .. err
				}
			end

			-- Read server's public key
			data, err = read_packet(conn)
			if not data then
				return false, {
					type = "ERR",
					message = "failed to read server public key: " .. err
				}
			end

			local success, result = pcall(pkey.new, data)
			if not success then
				return false, {
					type = "ERR",
					message = "failed to load server public key: " .. tostring(result)
				}
			end
			local public_key = result

			-- Encrypt password
			local pass_null = pool.password .. "\0"
			local scramble = auth_plugin_data_part1 .. auth_plugin_data_part2
			local scrambled_pass = ""
			for i = 1, #pass_null do
				scrambled_pass = scrambled_pass .. strchar(strbyte(pass_null, i) ~ strbyte(scramble, (i - 1) % #scramble + 1))
			end

			local success2, encrypted_pass = pcall(public_key.encrypt, public_key, scrambled_pass, pkey.RSA_PKCS1_OAEP, "sha1")
			if not success2 then
				return false, {
					type = "ERR",
					message = "failed to encrypt password: " .. tostring(encrypted_pass)
				}
			end

			-- Send encrypted password
			ok, err = tcp_write(conn.fd, compose_packet(conn, encrypted_pass))
			if not ok then
				return false, {
					type = "ERR",
					message = "failed to write encrypted password: " .. err
				}
			end

			-- Read final response
			data, err = read_packet(conn)
			if not data then
				return false, {
					type = "ERR",
					message = err
				}
			end
			first_byte = strbyte(data)
		end
	end

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
	if not conn.is_autocommit then
		conn_rollback(conn)
	end
	if not pool.is_closed and not conn.is_broken then
		-- try waktup waiting conn
		local waiting_for_conn = pool.waiting_for_conn
		if #waiting_for_conn > 0 then
			local co = tremove(waiting_for_conn)
			if co then
				silly.wakeup(co, conn)
			end
			return
		end
		-- trye return to pool
		local conns_idle = pool.conns_idle
		if #conns_idle < pool.max_idle_conns then
			conn.returned_at = timenow() // 1000
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
	local now = timenow() // 1000
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
		local co = silly.running()
		local waiting_for_conn = pool.waiting_for_conn
		waiting_for_conn[#waiting_for_conn + 1] = co
		local conn = silly.wait()
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
	local now = timenow() // 1000
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
	time.after(1000, pool_clear, pool)
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
		silly.wakeup(co)
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
		time.after(1000, pool_clear, pool)
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
			logger.error("[silly.store.mysql] connection leaked", fd)
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
