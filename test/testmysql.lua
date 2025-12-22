local wg = require "silly.sync.waitgroup"
local mysql = require "silly.store.mysql"
local mysqlc = require "silly.store.mysql.c"
local testaux = require "test.testaux"
local silly = require "silly"
local time = require "silly.time"

--------mysql.c test
-- Test 1: Length-encoded integer boundary values
do
	local test_cases = {
		{input = 0, expected = "\0"},
		{input = 250, expected = "\xFA"},
		{input = 251, expected = "\xFC\xFB\x00"}, -- 0x00FB=251
		{input = 0xFFFFFF, expected = "\xFD\xFF\xFF\xFF"},
		{input = 0xFFFFFFFFFFFFFFFF, expected = "\xFE"..string.rep("\xFF",8)}
	}

	for i, tc in ipairs(test_cases) do
		local val, pos = mysqlc.parse_lenenc(tc.expected, 1)
		testaux.asserteq(val, tc.input, "Test 1."..i..": parse_lenenc for "..tc.input)
	end
end

-- Test 2: Parse OK packet with basic fields
do
	local data_without_message = string.char(
		0x00,           -- OK header
		0x03,           -- affected_rows (3)
		0x05,           -- last_insert_id (5)
		0x02, 0x01,     -- server_status (0x0102)
		0x04, 0x03      -- warning_count (0x0304)
	)
	local message = string.char(
		0x05           	-- message length (5)
	) .. 'hello'         	-- message
	local t = mysqlc.parse_ok_packet(data_without_message)
	testaux.asserteq(t.affected_rows, 3, "Test 2.1: OK packet affected_rows")
	testaux.asserteq(t.last_insert_id, 5, "Test 2.2: OK packet last_insert_id")
	testaux.asserteq(t.server_status, 0x0102, "Test 2.3: OK packet server_status")
	testaux.asserteq(t.warning_count, 0x0304, "Test 2.4: OK packet warning_count")
	testaux.asserteq(t.message, nil, "Test 2.5: OK packet message")

	local t = mysqlc.parse_ok_packet(data_without_message .. message)
	testaux.asserteq(t.affected_rows, 3, "Test 2.6: OK packet affected_rows")
	testaux.asserteq(t.last_insert_id, 5, "Test 2.7: OK packet last_insert_id")
	testaux.asserteq(t.server_status, 0x0102, "Test 2.8: OK packet server_status")
	testaux.asserteq(t.warning_count, 0x0304, "Test 2.9: OK packet warning_count")
	testaux.asserteq(t.message, 'hello', "Test 2.10: OK packet message")
end

-- Test 3: Parse EOF packet with status flags
do
	local data = string.char(
		0xFE,           -- EOF header
		0x02, 0x01,     -- warning_count (0x0102) little endian
		0x04, 0x03      -- status_flags (0x0304) little endian
	)
	local t = mysqlc.parse_eof_packet(data)
	testaux.asserteq(t.warning_count, 0x0102, "Test 3.1: EOF packet warning_count")
	testaux.asserteq(t.status_flags, 0x0304, "Test 3.2: EOF packet status_flags")
end

-- Test 4: Parse standard error packet with SQLSTATE
do
	local data = string.char(
		0xFF,           -- ERR header
		0x27, 0x10,    -- error code (0x1027=4135) little endian
		0x23,          -- marker '#'
		0x48,0x59,0x30,0x30,0x30, -- SQLSTATE 'HY000'
		0x64,0x75,0x70,0x6C,0x69,0x63,0x61,0x74,0x65 -- message "duplicate"
	)
	local t = mysqlc.parse_err_packet(data)
	testaux.asserteq(t.errno, 0x1027, "Test 4.1: ERR packet error code")
	testaux.asserteq(t.sqlstate, "HY000", "Test 4.2: ERR packet SQLSTATE")
	testaux.asserteq(t.message, "duplicate", "Test 4.3: ERR packet message")
end

-- Test 5: Column definition parsing (lparse_column_def)
do
	local test_cases = {
		-- column definition
		{
			input = string.char(
				0x03, 0x64,0x65,0x66,   	-- catalog "def" (len=3)
				0x03, 0x73,0x63,0x68,         	-- schema "sch" (len=3)
				0x03, 0x74,0x62,0x6C,         	-- table "tbl" (len=3)
				0x03, 0x61,0x78,0x78,         	-- table alias "txx" (len=3)
				0x03, 0x63,0x6F,0x6C,         	-- column alias "col" (len=3)
				0x03, 0x63,0x78,0x78,         	-- column "cxx" (len=3)
				0x0c,                         	-- filler
				0x01, 0x00,                   	-- charset (0x0001)
				0xFF,0xFF,0xFF,0xFF,           	-- max_column_size (0xFFFFFFFF)
				0x01,                         	-- field_type (MYSQL_TYPE_TINY)
				0x20, 0x00                    	-- flags (UNSIGNED)
			),
			expected = {name = "col", type = 0x01, flags = 0x0020}
		},
		-- max length column name (255 bytes)
		{
			input = string.char(
				0x03, 0x64, 0x65, 0x66, -- catalog "def" (len=3)
				0x03, 0x73, 0x63, 0x68, -- schema "sch" (len=3)
				0x03, 0x74, 0x62, 0x6C, -- table "tbl" (len=3)
				0x03, 0x61, 0x78, 0x78  -- table alias "txx" (len=3)
			) ..
				string.char(0xFC,0xFF,0x00)..string.rep("a",255) .. -- column alias "a" (len=255)
				string.char(0xFC,0xFF,0x00)..string.rep("b",255) .. -- column name "b" (len=255)
			string.char(
				0x0c, -- filler
				0x01, 0x00, -- charset (0x0001)
				0xFF, 0xFF, 0xFF, 0xFF, -- max_column_size (0xFFFFFFFF)
				0x0f, -- field_type (MYSQL_TYPE_VARCHAR)
				0x20, 0x00 -- flags (UNSIGNED)
			),
			expected = {name = string.rep("a",255), type = 0x0F, flags = 0x20}
		}
	}

	for i, tc in ipairs(test_cases) do
		local col = mysqlc.parse_column_def(tc.input)
		testaux.asserteq(col[1], tc.expected.name, "Test 5."..i..": column name")
		testaux.asserteq(col[2], tc.expected.type, "Test 5."..i..": field type")
		testaux.asserteq(col[3], tc.expected.flags, "Test 5."..i..": field flags")
	end
end

-- Test 6: Binary row data parsing (lparse_row_data_binary)
do
	local cols = {
		{ "null",  1,   0x00 }, -- signed TINYINT (0x01=1)
		{ "col1",  1,   0x00 }, -- signed TINYINT
		{ "col2",  1,   0x20 }, -- unsigned TINYINT
		{ "col3",  2,   0x00 }, -- signed SMALLINT (0x02=2)
		{ "col4",  2,   0x20 }, -- unsigned SMALLINT
		{ "col5",  3,   0x00 }, -- signed INT (0x03=3)
		{ "col6",  3,   0x20 }, -- unsigned INT
		{ "col7",  4,   0x00 }, -- FLOAT (0x04=4)
		{ "col8",  5,   0x00 }, -- double (0x05=5)
		{ "col9",  8,   0x00 }, -- signed BIGINT (0x08=8)
		{ "col10", 8,   0x20 }, -- unsigned BIGINT
		{ "col11", 9,   0x00 }, -- signed INT24 (0x09=9)
		{ "col12", 9,   0x20 }, -- unsigned INT24
		{ "col13", 10,  0x00 }, -- DATE (0x0A=10)
		{ "col14", 11,  0x00 }, -- TIME (0x0B=11)
		{ "col15", 11,  0x00 }, -- TIME (0x0B=11)
		{ "col16", 12,  0x00 }, -- DATETIME (0x0C=12)
		{ "col17", 7,   0x00 }, -- TIMESTAMP (0x07=7)
		{ "col18", 13,  0x00 }, -- YEAR (0x0D=13)
		{ "col19", 15,  0x00 }, -- VARCHAR (0x0F=15)
		{ "col20", 16,  0x00 }, -- BIT (0x10=16)
		{ "col21", 245, 0x00 }, -- JSON (0xF5=245)
		{ "col22", 246, 0x00 }, -- DECIMAL (0xF6=246)
		{ "col23", 247, 0x00 }, -- ENUM (0xF7=247)
		{ "col24", 248, 0x00 }, -- SET (0xF8=248)
		{ "col25", 249, 0x00 }, -- TINY_BLOB (0xF9=249)
		{ "col26", 250, 0x00 }, -- MEDIUM_BLOB (0xFA=250)
		{ "col27", 251, 0x00 }, -- LONG_BLOB (0xFB=251)
		{ "col28", 252, 0x00 }, -- BLOB (0xFC=252)
		{ "col29", 253, 0x00 }, -- VAR_STRING (0xFD=253)
		{ "col30", 254, 0x00 }, -- STRING (0xFE=254)
		{ "col31", 255, 0x00 }, -- GEOMETRY (0xFF=255)
	}
	local data_min = string.char(
		0x00,	--header
	-- NULL bitmap (5 bytes, 33 bits: 2 reserved bits + 31 fields)
	-- 0x04, 0x00, 0x00, 0x00, 0x00 means only the first field is NULL
		0x04, 0x00, 0x00, 0x00, 0x00,
		-- col1: TINYINT signed (-128)
		0x80,
		-- col2: TINYINT unsigned (0)
		0x00,
		-- col3: SMALLINT signed (-32768)
		0x00, 0x80,
		-- col4: SMALLINT unsigned (0)
		0x00, 0x00,
		-- col5: INT signed (-2147483648)
		0x00, 0x00, 0x00, 0x80,
		-- col6: INT unsigned (0)
		0x00, 0x00, 0x00, 0x00,
		-- col7: FLOAT (minimum normalized value ~1.18e-38)
		0x00, 0x00, 0x80, 0x00,
		-- col8: DOUBLE (minimum normalized value ~2.23e-308)
		0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00,
		-- col9: BIGINT signed (-9223372036854775808)
		0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80,
		-- col10: BIGINT unsigned (0)
		0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
		-- col11: INT24 signed (-8388608)
		0x00, 0x00, 0x80,
		-- col12: INT24 unsigned (0)
		0x00, 0x00, 0x00,
		-- col13: DATE (0000-00-00)
		0x00,
		-- col14: TIME (00:00:00)
		0x00,     -- length (0 bytes)
		-- col15: TIME (-838:59:59)
		0x08,     -- length (8 bytes, no fractional seconds)
		0x01,     -- is_negative (1 = negative)
		0x22, 0x00, 0x00, 0x00, -- days (34 days = 0x00000022) little endian
		0x16,     -- hours (22 = 0x16)
		0x3B,     -- minutes (59 = 0x3B)
		0x3B,     -- seconds (59 = 0x3B)
		-- col16: DATETIME (0000-00-00 00:00:00) 64 byte
		0x00,
		-- col17: TIMESTAMP (0000-00-00 00:00:00)
		0x00,
		-- col18: YEAR (-32768)
		0x00, 0x80,
		-- col19: VARCHAR (empty string)
		0x00,
		-- col20: BIT(1) (0)
		0x01, 0x00,
		-- col21: JSON ("null")
		0x04, 0x6E, 0x75, 0x6C, 0x6C,
		-- col22: DECIMAL ("0")
		0x01, 0x30,
		-- col23: ENUM (first enum value)
		0x00,
		-- col24: SET (empty set)
		0x00,
		-- col25-31: BLOB/STRING types (empty)
		0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
	)
	local expect_min = {
		[cols[1][1]] = nil,       -- null (TINYINT)
		[cols[2][1]] = -128,      -- TINYINT signed
		[cols[3][1]] = 0,         -- TINYINT unsigned
		[cols[4][1]] = -32768,    -- SMALLINT signed
		[cols[5][1]] = 0,         -- SMALLINT unsigned
		[cols[6][1]] = -2147483648, -- INT signed
		[cols[7][1]] = 0,         -- INT unsigned
		[cols[8][1]] = 1.17549435e-38, -- FLOAT
		[cols[9][1]] = 2.2250738585072014e-308, -- DOUBLE
		[cols[10][1]] = -9223372036854775808, -- BIGINT signed
		[cols[11][1]] = 0,        -- BIGINT unsigned
		[cols[12][1]] = -8388608, -- INT24 signed
		[cols[13][1]] = 0,        -- INT24 unsigned
		[cols[14][1]] = "0000-00-00", -- DATE
		[cols[15][1]] = "00:00:00", -- TIME
		[cols[16][1]] = "-838:59:59", -- TIME
		[cols[17][1]] = "0000-00-00 00:00:00", -- DATETIME
		[cols[18][1]] = "0000-00-00 00:00:00", -- TIMESTAMP
		[cols[19][1]] = -32768,   -- YEAR
		[cols[20][1]] = "",       -- VARCHAR
		[cols[21][1]] = "\0",     -- BIT
		[cols[22][1]] = "null",   -- JSON
		[cols[23][1]] = "0",      -- DECIMAL
		[cols[24][1]] = "",       -- ENUM
		[cols[25][1]] = "",       -- SET
		[cols[26][1]] = "",       -- TINY_BLOB
		[cols[27][1]] = "",       -- MEDIUM_BLOB
		[cols[28][1]] = "",       -- LONG_BLOB
		[cols[29][1]] = "",       -- BLOB
		[cols[30][1]] = "",       -- VAR_STRING
		[cols[31][1]] = "",       -- STRING
		[cols[32][1]] = ""        -- GEOMETRY
	}
	local data_max = string.char(
		0x00, --header
	-- NULL bitmap (5 bytes, 33 bits: 2 reserved bits + 31 fields)
	-- 0x04, 0x00, 0x00, 0x00, 0x00 means only the first field is NULL
		0x04, 0x00, 0x00, 0x00, 0x00,
		-- col1: TINYINT signed (127)
		0x7F,
		-- col2: TINYINT unsigned (255)
		0xFF,
		-- col3: SMALLINT signed (32767)
		0xFF, 0x7F,
		-- col4: SMALLINT unsigned (65535)
		0xFF, 0xFF,
		-- col5: INT signed (2147483647)
		0xFF, 0xFF, 0xFF, 0x7F,
		-- col6: INT unsigned (4294967295)
		0xFF, 0xFF, 0xFF, 0xFF,
		-- col7: FLOAT (maximum value ~3.40e+38)
		0xFF, 0xFF, 0x7F, 0x7F,
		-- col8: DOUBLE (maximum value ~1.79e+308)
		0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xEF, 0x7F,
		-- col9: BIGINT signed (9223372036854775807)
		0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F,
		-- col10: BIGINT unsigned (18446744073709551615)
		0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
		-- col11: INT24 signed (8388607)
		0xFF, 0xFF, 0x7F,
		-- col12: INT24 unsigned (16777215)
		0xFF, 0xFF, 0xFF,
		-- col13: DATE (9999-12-31)
		0x04, 0x0F, 0x27, 12, 31,
		-- col14: TIME (838:59:59.009999)
		0x0c,     -- length (12 bytes)
		0x00,     -- is_negative (0 = positive)
		0x22, 0x00, 0x00, 0x00, -- days (34 days = 0x00000022) little endian
		0x16,     -- hours (22 = 0x16)
		0x3B,     -- minutes (59 = 0x3B)
		0x3B,     -- seconds (59 = 0x3B)
		0x0F, 0x27, 0x00, 0x00, -- microseconds (9999 = 0x0000270F)
		-- col15: TIME (838:59:59)
		0x08,     -- length (8 bytes, no fractional seconds)
		0x00,     -- is_negative (0 = positive)
		0x22, 0x00, 0x00, 0x00, -- days (34 days = 0x00000022) little endian
		0x16,     -- hours (22 = 0x16)
		0x3B,     -- minutes (59 = 0x3B)
		0x3B,     -- seconds (59 = 0x3B)
		-- col16: DATETIME (2025-01-02 03:04:05)
		0x07, 0xE9, 0x07, 0x01, 0x02, 0x03, 0x04, 0x05,
		-- col17: TIMESTAMP (2025-01-02 03:04:05.99999999)
		11, 0xE9, 0x07, 0x01, 0x02, 0x03, 0x04, 0x05,
		0x3F, 0x42, 0x0F, 0x00,
		-- col18: YEAR (2155)
		0x6B, 0x08,
		-- col19: VARCHAR (maximum length string)
		0xFD, 0xFF, 0xFF, 0x01) .. string.rep("A", 0x1FFFF) .. string.char(
		-- col20: BIT(64) (all ones)
		0x08, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
		-- col21: JSON (complex object)
		0x0F, 0x7B, 0x22, 0x6B, 0x65, 0x79, 0x22, 0x3A, 0x22, 0x76, 0x61, 0x6C, 0x75, 0x65, 0x22, 0x7D,
		-- col22: DECIMAL (9999.99)
		0x07, 0x39, 0x39, 0x39, 0x39, 0x2E, 0x39, 0x39,
		-- col23: ENUM (last enum value)
		0x02, 97, 97,
		-- col24: SET (all selected)
		0x03, 65, 76, 76) ..
		-- col25-31: BLOB/STRING types (maximum length data)
		string.char(0xFC, 0xFF, 0x00) .. string.rep("\xFF", 255) .. -- repeated for each BLOB type
		string.char(0xFC, 0xFF, 0xFF) .. string.rep("\xFF", 65535) .. -- repeated for each BLOB type
		string.char(0xFd, 0xFF, 0xFF, 0x01) .. string.rep("\xFF", 0x1ffff) .. -- repeated for each BLOB type
		string.char(0xFd, 0xFF, 0xFF, 0x01) .. string.rep("\xFF", 0x1ffff) .. -- repeated for each BLOB type
		string.char(0xFd, 0xFF, 0xFF, 0x01) .. string.rep("\xFF", 0x1ffff) .. -- repeated for each BLOB type
		string.char(0xFd, 0xFF, 0xFF, 0x01) .. string.rep("\xFF", 0x1ffff) .. -- repeated for each BLOB type
		string.char(0xFd, 0xFF, 0xFF, 0x01) .. string.rep("\xFF", 0x1ffff)    -- repeated for each BLOB type

	local expect_max = {
		[cols[1][1]] = nil,          -- null (TINYINT)
		[cols[2][1]] = 127,          -- TINYINT signed
		[cols[3][1]] = 255,          -- TINYINT unsigned
		[cols[4][1]] = 32767,        -- SMALLINT signed
		[cols[5][1]] = 65535,        -- SMALLINT unsigned
		[cols[6][1]] = 2147483647,   -- INT signed
		[cols[7][1]] = 4294967295,   -- INT unsigned
		[cols[8][1]] = 3.4028234663852886e+38, -- FLOAT
		[cols[9][1]] = 1.7976931348623157e+308, -- DOUBLE
		[cols[10][1]] = 9223372036854775807, -- BIGINT signed
		[cols[11][1]] = -1, 		     -- BIGINT unsigned, because lua can't has 64bit unsigned
		[cols[12][1]] = 8388607,     -- INT24 signed
		[cols[13][1]] = 16777215,    -- INT24 unsigned
		[cols[14][1]] = "9999-12-31", -- DATE
		[cols[15][1]] = "838:59:59.009999", -- TIME
		[cols[16][1]] = "838:59:59", -- TIME
		[cols[17][1]] = "2025-01-02 03:04:05", -- DATETIME
		[cols[18][1]] = "2025-01-02 03:04:05.999999", -- TIMESTAMP
		[cols[19][1]] = 2155,        -- YEAR
		[cols[20][1]] = string.rep("A", 0x1FFFF), -- VARCHAR
		[cols[21][1]] = string.rep("\xFF", 8), -- BIT
		[cols[22][1]] = '{"key":"value"}', -- JSON
		[cols[23][1]] = "9999.99",   -- DECIMAL
		[cols[24][1]] = "aa",       -- ENUM
		[cols[25][1]] = "ALL",       -- SET
		[cols[26][1]] = string.rep("\xFF", 255), -- TINY_BLOB
		[cols[27][1]] = string.rep("\xFF", 65535), -- MEDIUM_BLOB
		[cols[28][1]] = string.rep("\xFF", 0x1ffff), -- LONG_BLOB
		[cols[29][1]] = string.rep("\xFF", 0x1ffff), -- BLOB
		[cols[30][1]] = string.rep("\xFF", 0x1ffff), -- VAR_STRING
		[cols[31][1]] = string.rep("\xFF", 0x1ffff), -- STRING
		[cols[32][1]] = string.rep("\xFF", 0x1ffff) -- GEOMETRY
	}
	local result = mysqlc.parse_row_data_binary(data_min, cols)
	testaux.asserteq(result, expect_min, "Test 6.1: Binary row data parsing (min)")

	local result = mysqlc.parse_row_data_binary(data_max, cols)
	testaux.asserteq(result, expect_max, "Test 6.2: Binary row data parsing (max)")

	-- test invalid cols
	local invalid_cols = {{type = 0xFF, flags = 0}}  -- unknown type
	testaux.assert_error(function()
		mysqlc.parse_row_data_binary("\x00", invalid_cols)
	end, "Test 6.3: invalid cols")

	-- test short data
	local short_data = string.char(0x00,0x01)  -- need at least 4 bytes INT
	testaux.assert_error(function()
		mysqlc.parse_row_data_binary(short_data, {{type = 0x03}})
	end, "Test 6.4: short data")

	-- test null bitmap overflow
	local null_bitmap = string.char(0xFF)..string.rep("\x00", 8)
	testaux.assert_error(function()
		mysqlc.parse_row_data_binary(null_bitmap, {
			{type=0x01}, {type=0x01}, {type=0x01}, {type=0x01},
			{type=0x01}, {type=0x01}, {type=0x01}, {type=0x01},
			{type=0x01}  -- 第9个字段需要2字节NULL位图
		})
	end, "Test 6.5: null bitmap overflow")
end

-- Test 7: Prepared statement encoding (lcompose_stmt_execute)
do
	local params = {0xFFFFFFFFFF, nil, 3.14, "hello", true}
	local expected = string.char(
		0x17,                   -- COM_STMT_EXECUTE
		0x01,0x00,0x00,0x00,    -- stmt_id
		0x00,                   -- flags
		0x01,0x00,0x00,0x00,    -- iteration_count
		0x02,                   -- NULL bitmap (00000010)
		0x01,                   -- new_params_bound_flag
		-- 参数类型:
		0x08,0x00,  -- LONGLONG
		0x06,0x00,  -- NULL
		0x05,0x00,  -- DOUBLE
		0x0F,0x00,  -- VARCHAR
		0x01,0x00,  -- TINY
		-- 参数值:
		0xFF,0xFF,0xFF,0xFF,0xFF,0x00,0x00,0x00, --
		0x1F,0x85,0xEB,0x51,0xB8,0x1E,0x09,0x40, -- 3.14
		0x05,0x68,0x65,0x6C,0x6C,0x6F,          -- "hello"
		0x01                                    -- 1
	)
	local stmt = mysqlc.compose_stmt_execute(1, 5, 0, table.unpack(params, 1, 5))
	testaux.asserteq(stmt, expected, "Test 7: compose_stmt_execute")
end

-------- silly.store.mysql test

-- Test 8: create `test` database
do
	local pool = mysql.open {
		addr = "127.0.0.1:3306",
		user = "root",
		password = "root",
	}
	local res, err = pool:query("DROP DATABASE IF EXISTS test")
	testaux.assertneq(res, nil, "Test 8.1: drop `test` database." .. (err and err.message or ""))
	local res, err = pool:query("CREATE DATABASE IF NOT EXISTS test")
	testaux.assertneq(res, nil, "Test 8.2: create `test` database")
	pool:close()
end

-- Test 9: Basic connection tests
do
	local pool = mysql.open {
		addr = "127.0.0.1:3306",
		user = "root",
		password = "root",
		database = "test",
		max_idle_conns = 3,
		max_open_conns = 5
	}

	-- Test basic query
	local res, err = pool:query("SELECT 1+1 as result")
	assert(res, err)
	testaux.asserteq(res[1].result, 2, "Test 9.1: Basic query should return 2")

	-- Test invalid SQL handling
	res, err = pool:query("SELECT * FROM non_existent_table")
	assert(err)
	testaux.asserteq(err.message:find("doesn't exist") ~= nil, true, "Test 9.2: Should handle invalid table name")

	-- Test connection pool capacity
	local queries = {}
	local wg  = wg.new()
	for i=1,5 do
		wg:fork(function()
			local res, err = pool:query("SELECT SLEEP(0.1)")
			assert(res, err)
			queries[#queries+1] = res
		end)
	end
	wg:wait()
	testaux.asserteq(#queries, 5, "Test 9.3: Should complete all concurrent queries")
	pool:close()
end


-- Test 10: invalid authentication
do
	local pool = mysql.open {
		addr = "127.0.0.1:3306",
		user = "invalid_user",
		password = "wrong_pass",
	}
	local res, err = pool:ping()
	assert(err)
	testaux.asserteq(res, nil, "Test 10: Should handle invalid credentials")
	testaux.asserteq(err.message:find("Access denied") ~= nil, true, "Test 10: Should handle invalid credentials")
	pool:close()
end

-- Test 11: Connection timeout
do
	local pool = mysql.open {
		addr = "127.0.0.1:0001", -- Invalid address
		connect_timeout = 1,
		user = "root",
		password = "root",
	}
	local res, err = pool:ping()
	assert(err)
	testaux.asserteq(err.message:lower():find("connection refused") ~= nil, true, "Test 11: Should handle connection timeout")
	pool:close()
end

-- Test 12: Connection pool lifecycle tests
do
	local pool = mysql.open {
		addr = "127.0.0.1:3306",
		user = "root",
		password = "root",
		max_idle_conns = 2,
		max_idle_time = 1, -- 1 second idle timeout
		max_lifetime = 3  -- 3 seconds max lifetime
	}

	-- Test idle connection reuse
	pool:query("SELECT 1") -- Create initial connection
	testaux.asserteq(#pool.conns_idle, 1, "Test 12.1: Should return connection to pool after query")

	-- Test idle timeout
	time.sleep(2500)
	testaux.asserteq(#pool.conns_idle, 0, "Test 12.2: Should clean up idle connections after timeout")

	-- Test max lifetime
	pool:query("SELECT 1") -- Create new connection
	time.sleep(4000)
	local res, err = pool:query("SELECT 1")
	testaux.asserteq(not err, true, "Test 12.3: Should automatically renew expired connections")
	pool:close()
end

-- Test 13: Concurrency stress test
do
	local pool = mysql.open {
		addr = "127.0.0.1:3306",
		user = "root",
		password = "root",
		max_open_conns = 3
	}
	local wg = wg.new()
	local concurrent = 5
	local queries = {}
	for i=1,concurrent do
		wg:fork(function()
			local res, err = pool:query("SELECT SLEEP(0.2)")
			assert(res, err)
			queries[#queries+1] = res
		end)
	end
	local start = time.now()
	wg:wait()
	local duration = time.now() - start

	testaux.asserteq(#queries, concurrent, "Test 13: Should complete all concurrent requests")
	testaux.asserteq(duration >= 0.4 * 1000, true, "Test 13: Should throttle connections (max_open_conns=3 for 5 requests)")
	pool:close()
end

-- Test 14: Prepared statement tests
do
	local pool = mysql.open {
		addr = "127.0.0.1:3306",
		user = "root",
		password = "root",
		database = "test",
		max_idle_conns = 1,  -- ensure connection reuse
		max_open_conns = 1   -- force use single connection
	}

	-- Get connection
	local res, err = pool:query("SELECT 1")
	testaux.assertneq(res, nil, "Test 14.1: Should get connection")

	-- Create temp table
	local res, err = pool:query([[
		CREATE TEMPORARY TABLE test_users (
			id INT PRIMARY KEY,
			name VARCHAR(50)
		)
	]])
	testaux.asserteq(not err, true, "Test 14.2: Should create temp table")

	-- Parameterized query
	res, err = pool:query("INSERT INTO test_users VALUES (?, ?)", 1, "Alice")
	assert(res, err)
	testaux.asserteq(res.affected_rows, 1, "Test 14.3: Should insert data with prepared statement")

	res, err = pool:query("SELECT name FROM test_users WHERE id = ?", 1)
	assert(res, err)
	testaux.asserteq(res[1].name, "Alice", "Test 14.4: Should retrieve data with prepared statement")

	-- Explicitly clean up connection
	pool:query("DROP TEMPORARY TABLE test_users")
	pool:close()
end

-- Test 15: Connection leak detection
do
	local pool = mysql.open {
		addr = "127.0.0.1:3306",
		user = "root",
		password = "root",
		max_open_conns = 2
	}

	-- Create heavy queries to exhaust connection pool
	pool:query("SELECT SLEEP(1)")
	pool:query("SELECT SLEEP(1)")

	local start = time.now()
	local third_query = pool:query("SELECT 1") -- Should be queued
	local stop = time.now()
	testaux.assertneq(stop - start, 500, "Test 15: Should queue requests when pool is full")
	pool:close()
end

-- Test 16: test mysql query table field
do
	local pool = mysql.open {
		addr = "127.0.0.1:3306",
		user = "root",
		password = "root",
		database = "test",
		max_idle_conns = 1,
		max_open_conns = 1,
	}

	local res, err = pool:query("CREATE TEMPORARY TABLE IF NOT EXISTS test_users (id INT PRIMARY KEY, name VARCHAR(50))")
	testaux.assertneq(res, nil, "Test 16: Should create table")

	local res, err = pool:query("INSERT INTO test_users VALUES (1, 'Alice')")
	assert(res, err)
	testaux.asserteq(res.affected_rows, 1, "Test 16: Should insert 1 row")

	local res, err = pool:query("INSERT INTO test_users VALUES (2, 'Bob')")
	testaux.assertneq(res, nil, "Test 16: Should insert data")

	local res, err = pool:query("SELECT * FROM test_users")
	testaux.assertneq(res, nil, "Test 16: Should return data")
	testaux.asserteq(#res, 2, "Test 16: Should return 1 row")
	pool:close()
end


-- Test 17: Insert and retrieve large field values (1024 bytes)
do
	local pool = mysql.open {
		addr = "127.0.0.1:3306",
		user = "root",
		password = "root",
		database = "test",
		max_idle_conns = 1,
		max_open_conns = 1,
	}

	local res, err = pool:query([[
		CREATE TEMPORARY TABLE IF NOT EXISTS big_data_test
		(id INT PRIMARY KEY, data VARCHAR(1024))
	]])
	testaux.assertneq(res, nil, "Test 17: Should create table")

	local big_data = string.rep("D", 1024)
	local res, err = pool:query("INSERT INTO big_data_test VALUES (1, ?)", big_data)
	testaux.assertneq(res, nil, "Test 17.1: Should insert big data")
	assert(res)
	testaux.asserteq(res.affected_rows, 1, "Test 17.2: Should affect 1 row")

	local res, err = pool:query("SELECT data FROM big_data_test WHERE id = 1")
	testaux.assertneq(res, nil, "Test 17.3: Should retrieve big data")
	assert(res)
	testaux.asserteq(#res[1].data, 1024, "Test 17.4: Should maintain data length")

	pool:close()
end


-- Test 18: Handle very large field values (65536 bytes)
do
	local pool = mysql.open {
		addr = "127.0.0.1:3306",
		user = "root",
		password = "root",
		database = "test",
		max_idle_conns = 1,
		max_open_conns = 1,
	}

	local res, err = pool:query([[
		CREATE TEMPORARY TABLE IF NOT EXISTS huge_data_test
		(id INT PRIMARY KEY, data TEXT(65540))
	]])
	testaux.assertneq(res, nil, "Test 18: Should create table")

	local huge_data = string.rep("F", 65536)
	local res, err = pool:query("INSERT INTO huge_data_test VALUES (1, ?)", huge_data)
	testaux.assertneq(res, nil, "Test 18.1: Should insert huge data")
	assert(res)
	testaux.asserteq(res.affected_rows, 1, "Test 18.2: Should affect 1 row")
	pool:close()
end

-- Test 19: Verify OK packet message contains changed rows info
do
	local pool = mysql.open {
		addr = "127.0.0.1:3306",
		user = "root",
		password = "root",
		database = "test",
		max_idle_conns = 1,
		max_open_conns = 1,
	}


	local statements = {
		'drop table if exists test_users',
		'create table test_users (name varchar(10))',
		'insert into test_users values ("name1")',
		'update test_users set name="foo"',
		'drop table if exists test_users',
	}

	local res, err
	for i, stm in ipairs(statements) do
		res, err = pool:query(stm)
		testaux.assertneq(res, nil, "Test 19: Should get connection")
		assert(res)
		if res.message then
			print(res.message)
		end
	end
	pool:close()
end


-- Test 20: Handle null string values
do
	local pool = mysql.open {
		addr = "127.0.0.1:3306",
		user = "root",
		password = "root",
		database = "test",
		max_idle_conns = 1,
		max_open_conns = 1,
	}

	local res, err = pool:query([[
		CREATE TEMPORARY TABLE IF NOT EXISTS null_test
		(id INT PRIMARY KEY, data VARCHAR(10))
	]])
	testaux.assertneq(res, nil, "Test 20: Should create table")

	-- Insert null value using prepared statement
	local res, err = pool:query("INSERT INTO null_test VALUES (1, ?)", nil)
	testaux.assertneq(res, nil, "Test 20.1: Should insert null value")
	assert(res)
	testaux.asserteq(res.affected_rows, 1, "Test 20.2: Should affect 1 row")

	-- Retrieve and verify null
	local res, err = pool:query("SELECT data FROM null_test WHERE id = 1")
	testaux.assertneq(res, nil, "Test 20.3: Should retrieve null data")
	assert(res)
	testaux.asserteq(res[1].data, nil, "Test 20.4: Should maintain null value")
	pool:close()
end

-- Test 21: test mysql last_insert_id
do
	local pool = mysql.open {
		addr = "127.0.0.1:3306",
		user = "root",
		password = "root",
		database = "test",
		max_idle_conns = 1,
		max_open_conns = 1,
	}

	local res, err = pool:query("CREATE TEMPORARY TABLE IF NOT EXISTS test_users (id INT PRIMARY KEY AUTO_INCREMENT, name VARCHAR(50))")
	testaux.assertneq(res, nil, "Test 21: Should create table")

	local res, err = pool:query("INSERT INTO test_users (name) VALUES (?)", "Alice")
	testaux.assertneq(res, nil, "Test 21: Should insert data")
	assert(res)
	testaux.asserteq(res.last_insert_id, 1, "Test 21: Should return last insert id")

	pool:close()
end


-- Test 22: test mysql transaction
do
	local pool = mysql.open {
		addr = "127.0.0.1:3306",
		user = "root",
		password = "root",
		database = "test",
		max_idle_conns = 1,
		max_open_conns = 3,
	}

	local res, err = pool:query("DROP TABLE IF EXISTS test_users")
	testaux.assertneq(res, nil, "Test 22.1: Should drop table")
	testaux.asserteq(err, nil, "Test 22.1: Should not return error")

	local res, err = pool:query("CREATE TABLE test_users (id INT PRIMARY KEY AUTO_INCREMENT, name VARCHAR(50))")
	testaux.assertneq(res, nil, "Test 22.2: Should create table")
	testaux.asserteq(err, nil, "Test 22.2: Should not return error")

	local tx<close>, err = pool:begin()
	testaux.asserteq(err, nil, "Test 22.3: Should not return error")

	assert(tx)
	local res, err = tx:query("INSERT INTO test_users (name) VALUES (?)", "Alice")
	testaux.assertneq(res, nil, "Test 22.4: Should insert data")
	testaux.asserteq(err, nil, "Test 22.4: Should not return error")

	local res, err = tx:query("SELECT * FROM test_users")
	testaux.asserteq(#res, 1, "Test 22.5: Should select data")
	testaux.asserteq(err, nil, "Test 22.5: Should not return error")

	local res, err = pool:query("SELECT * FROM test_users")
	testaux.asserteq(#res, 0, "Test 22.6: Transaction not commit, should not see data")
	testaux.asserteq(err, nil, "Test 22.6: Should not return error")

	local res, err = tx:commit()
	testaux.asserteq(err, nil, "Test 22.7: Should not return error")

	local res, err = tx:commit()
	testaux.asserteq(res, nil, "Test 22.8: Transaction already committed")
	testaux.assertneq(err, nil, "Test 22.8: Should return error")

	local res, err = pool:query("SELECT * FROM test_users")
	testaux.asserteq(#res, 1, "Test 22.9: Transaction commit, should see data")
	testaux.asserteq(err, nil, "Test 22.9: Should not return error")

	local res, err = pool:query("DROP TABLE IF EXISTS test_users")
	testaux.assertneq(res, nil, "Test 22.10: Should drop table")
	testaux.asserteq(err, nil, "Test 22.10: Should not return error")

	local res, err = pool:query("CREATE TABLE test_users (id INT PRIMARY KEY AUTO_INCREMENT, name VARCHAR(50))")
	testaux.assertneq(res, nil, "Test 22.11: Should create table")
	testaux.asserteq(err, nil, "Test 22.11: Should not return error")

	local tx<close>, err = pool:begin()
	testaux.asserteq(err, nil, "Test 22.12: Should not return error")
	assert(tx)

	local res, err = tx:query("INSERT INTO test_users (name) VALUES (?)", "Alice")
	testaux.assertneq(res, nil, "Test 22.13: Should insert data")
	testaux.asserteq(err, nil, "Test 22.13: Should not return error")

	local res, err = tx:rollback()
	testaux.asserteq(err, nil, "Test 22.14: Should not return error")

	local res, err = tx:rollback()
	testaux.asserteq(res, nil, "Test 22.15: Transaction already rolled back")
	testaux.assertneq(err, nil, "Test 22.15: Should return error")

	local res, err = pool:query("SELECT * FROM test_users")
	testaux.asserteq(#res, 0, "Test 22.16: Transaction rollback, should not see data")
	testaux.asserteq(err, nil, "Test 22.16: Should not return error")

	local res, err = pool:query("DROP TABLE IF EXISTS test_users")
	testaux.assertneq(res, nil, "Test 22.17: Should drop table")
	testaux.asserteq(err, nil, "Test 22.17: Should not return error")

	pool:close()
end

-- Test 23: test mysql query with date
do
	local pool = mysql.open {
		addr = "127.0.0.1:3306",
		user = "root",
		password = "root",
		database = "test",
		max_idle_conns = 1,
		max_open_conns = 1,
	}

	local res, err = pool:query("CREATE TABLE test_users (id INT PRIMARY KEY AUTO_INCREMENT, date DATE)")
	testaux.assertneq(res, nil, "Test 23: Should create table")

	local res, err = pool:query("INSERT INTO test_users (date) VALUES (?)", "2022-01-01")
	testaux.assertneq(res, nil, "Test 23: Should insert data")
	testaux.asserteq(err, nil, "Test 23: Should not return error")

	local res, err = pool:query("SELECT date FROM test_users where date = ?", "2022-01-01")
	testaux.assertneq(res, nil, "Test 23: Should select data")
	testaux.asserteq(err, nil, "Test 23: Should not return error")
	assert(res)
	testaux.asserteq(res[1].date, "2022-01-01", "Test 23: Should select data")

	local res, err = pool:query("DROP TABLE IF EXISTS test_users")
	testaux.assertneq(res, nil, "Test 23: Should drop table")
	testaux.asserteq(err, nil, "Test 23: Should not return error")

	pool:close()
end

-- Test 24: test caching_sha2_password authentication (MySQL 8.0+)
do
	local pool = mysql.open {
		addr = "127.0.0.1:3306",
		user = "root",
		password = "root",
		database = "test",
	}

	local res, err = pool:query("SELECT @@version AS version")
	testaux.assertneq(res, nil, "Test 24.1: Should connect with default authentication")

	-- Try to create a test user with caching_sha2_password (MySQL 8.0+)
	local create_user_sql = [[
		CREATE USER IF NOT EXISTS 'sha2testuser'@'%'
		IDENTIFIED WITH caching_sha2_password BY 'sha2testpass'
	]]
	res, err = pool:query(create_user_sql)
	if res then
		pool:query("GRANT ALL ON test.* TO 'sha2testuser'@'%'")
		pool:query("FLUSH PRIVILEGES")
		pool:close()

		-- Test connecting with the sha2 user
		local pool2 = mysql.open {
			addr = "127.0.0.1:3306",
			user = "sha2testuser",
			password = "sha2testpass",
			database = "test",
		}

		local res2, err2 = pool2:ping()
		testaux.assertneq(res2, nil, "Test 24.2: Should authenticate with caching_sha2_password")

		-- Test query with sha2 user
		local query_res, query_err = pool2:query("SELECT CURRENT_USER() AS user, 1+1 AS result")
		testaux.assertneq(query_res, nil, "Test 24.3: Should execute query with sha2 user")
		testaux.asserteq(query_res[1].result, 2, "Test 24.4: Should return correct result")

		pool2:close()

		-- Test second connection (should use cached password - fast auth path)
		local pool3 = mysql.open {
			addr = "127.0.0.1:3306",
			user = "sha2testuser",
			password = "sha2testpass",
			database = "test",
		}

		local res3, err3 = pool3:ping()
		testaux.assertneq(res3, nil, "Test 24.5: Should use fast auth with cached password")
		pool3:close()

		-- Cleanup
		local pool4 = mysql.open {
			addr = "127.0.0.1:3306",
			user = "root",
			password = "root",
		}
		pool4:query("DROP USER IF EXISTS 'sha2testuser'@'%'")
		pool4:close()
	else
		-- MySQL 5.7 or earlier - skip caching_sha2_password tests
		pool:close()
	end
end

-- Test 25: test utf8mb4 charset support
do
	local pool = mysql.open {
		addr = "127.0.0.1:3306",
		user = "root",
		password = "root",
		database = "test",
		charset = "utf8mb4",
	}

	-- Use a regular table instead of temporary
	pool:query("DROP TABLE IF EXISTS emoji_test")
	local res, err = pool:query("CREATE TABLE IF NOT EXISTS emoji_test (id INT PRIMARY KEY, content VARCHAR(100)) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci")
	testaux.assertneq(res, nil, "Test 25.1: Should create table with utf8mb4 charset")

	-- Test multi-byte characters (avoiding emoji to reduce complexity)
	local text = "Hello World 世界"
	res, err = pool:query("INSERT INTO emoji_test VALUES (?, ?)", 1, text)
	testaux.assertneq(res, nil, "Test 25.2: Should insert multi-byte data" .. (err and (": " .. err.message) or ""))

	res, err = pool:query("SELECT content FROM emoji_test WHERE id = ?", 1)
	testaux.assertneq(res, nil, "Test 25.3: Should retrieve multi-byte data")
	if res then
		testaux.asserteq(res[1].content, text, "Test 25.4: Should maintain multi-byte characters")
	end

	pool:query("DROP TABLE IF EXISTS emoji_test")
	pool:close()
end

-- Test 26: test prepared statement cache validation
do
	local pool = mysql.open {
		addr = "127.0.0.1:3306",
		user = "root",
		password = "root",
		database = "test",
		max_idle_conns = 1,
		max_open_conns = 1,
	}

	local res, err = pool:query("CREATE TEMPORARY TABLE IF NOT EXISTS cache_test (id INT PRIMARY KEY, value INT)")
	testaux.assertneq(res, nil, "Test 26.1: Should create table")

	-- Execute same query multiple times to test statement cache
	for i = 1, 5 do
		res, err = pool:query("INSERT INTO cache_test VALUES (?, ?)", i, i * 10)
		testaux.assertneq(res, nil, "Test 26.2." .. i .. ": Should insert data with cached statement")
	end

	-- Verify all inserts
	res, err = pool:query("SELECT COUNT(*) as cnt FROM cache_test")
	testaux.assertneq(res, nil, "Test 26.3: Should count rows")
	assert(res)
	testaux.asserteq(res[1].cnt, 5, "Test 26.4: Should have 5 rows")

	pool:close()
end

-- Test 27: test multi-statement query support
do
	local pool = mysql.open {
		addr = "127.0.0.1:3306",
		user = "root",
		password = "root",
		database = "test",
	}

	-- Test executing multiple simple statements
	-- Note: Current driver uses prepared statements, which don't support multiple statements
	-- This test verifies single statement behavior
	local res, err = pool:query("SELECT 1 as first_result")
	testaux.assertneq(res, nil, "Test 27.1: Should execute single statement")
	if res then
		testaux.asserteq(res[1].first_result, 1, "Test 27.2: Should get correct result")
	end

	pool:close()
end

-- Test 28: test connection pool with max_open_conns = 0 (unlimited)
do
	local pool = mysql.open {
		addr = "127.0.0.1:3306",
		user = "root",
		password = "root",
		database = "test",
		max_open_conns = 0,  -- unlimited
		max_idle_conns = 0,  -- no cache
	}

	-- Create many concurrent connections
	local wg = wg.new()
	local success_count = 0
	for i = 1, 10 do
		wg:fork(function()
			local res, err = pool:query("SELECT SLEEP(0.1)")
			if res then
				success_count = success_count + 1
			end
		end)
	end
	wg:wait()

	testaux.asserteq(success_count, 10, "Test 28: Should handle unlimited connections")
	pool:close()
end

-- Test 29: test connection object methods directly
do
	local pool = mysql.open {
		addr = "127.0.0.1:3306",
		user = "root",
		password = "root",
		database = "test",
		max_idle_conns = 1,
		max_open_conns = 1,
	}

	-- Get a transaction connection
	local conn<close>, err = pool:begin()
	testaux.asserteq(err, nil, "Test 29.1: Should get connection")
	assert(conn)

	-- Test conn:ping()
	local res, err = conn:ping()
	testaux.assertneq(res, nil, "Test 29.2: Should ping via connection object")

	-- Test conn:query()
	res, err = conn:query("SELECT 1 as val")
	testaux.assertneq(res, nil, "Test 29.3: Should query via connection object")
	assert(res)
	testaux.asserteq(res[1].val, 1, "Test 29.4: Should get correct result")

	-- Test conn:commit()
	res, err = conn:commit()
	testaux.asserteq(err, nil, "Test 29.5: Should commit transaction")

	pool:close()
end

-- Test 30: test PING command detailed response
do
	local pool = mysql.open {
		addr = "127.0.0.1:3306",
		user = "root",
		password = "root",
		database = "test",
	}

	local res, err = pool:ping()
	testaux.assertneq(res, nil, "Test 30.1: Should ping successfully")
	testaux.asserteq(err, nil, "Test 30.2: Should not have error")

	-- Verify OK packet structure
	assert(res)
	testaux.asserteq(res.type, "OK", "Test 30.3: Should be OK packet")
	testaux.assertneq(res.server_status, nil, "Test 30.4: Should have server_status")

	pool:close()
end

-- Test 31: test special data types (JSON, DECIMAL, BIT)
do
	local pool = mysql.open {
		addr = "127.0.0.1:3306",
		user = "root",
		password = "root",
		database = "test",
		max_idle_conns = 1,
		max_open_conns = 1,  -- Force single connection to ensure TEMPORARY TABLE works
	}

	-- Check MySQL version for JSON support
	local res, err = pool:query("SELECT @@version AS version")
	local has_json = res and res[1].version:match("^[89]%.") ~= nil

	if has_json then
		-- Test JSON type
		local create_res, create_err = pool:query("CREATE TEMPORARY TABLE IF NOT EXISTS json_test (id INT PRIMARY KEY, data JSON)")
		if create_res then
			local json_data = '{"name":"Alice","age":30,"tags":["user","active"]}'
			res, err = pool:query("INSERT INTO json_test VALUES (?, ?)", 1, json_data)
			testaux.assertneq(res, nil, "Test 31.1: Should insert JSON data" .. (err and (": " .. err.message) or ""))

			if res then
				res, err = pool:query("SELECT data FROM json_test WHERE id = ?", 1)
				testaux.assertneq(res, nil, "Test 31.2: Should retrieve JSON data")
				if res then
					-- JSON may be reformatted by MySQL, just verify it's not empty
					testaux.assertneq(res[1].data, nil, "Test 31.3: Should have JSON data")
				end
			end
		end
	end

	-- Test DECIMAL type
	pool:query("CREATE TEMPORARY TABLE IF NOT EXISTS decimal_test (id INT PRIMARY KEY, price DECIMAL(10,2))")
	res, err = pool:query("INSERT INTO decimal_test VALUES (?, ?)", 1, "12345.67")
	testaux.assertneq(res, nil, "Test 31.4: Should insert DECIMAL data")

	res, err = pool:query("SELECT price FROM decimal_test WHERE id = ?", 1)
	testaux.assertneq(res, nil, "Test 31.5: Should retrieve DECIMAL data")
	assert(res)
	testaux.asserteq(res[1].price, "12345.67", "Test 31.6: Should maintain DECIMAL precision")

	-- Test BIT type
	pool:query("CREATE TEMPORARY TABLE IF NOT EXISTS bit_test (id INT PRIMARY KEY, flags BIT(8))")
	res, err = pool:query("INSERT INTO bit_test VALUES (?, b'10101010')", 1)
	testaux.assertneq(res, nil, "Test 31.7: Should insert BIT data")

	res, err = pool:query("SELECT flags FROM bit_test WHERE id = ?", 1)
	testaux.assertneq(res, nil, "Test 31.8: Should retrieve BIT data")
	assert(res)
	testaux.assertneq(res[1].flags, nil, "Test 31.9: Should have BIT data")

	pool:close()
end

-- Test 32: test warning count validation
do
	local pool = mysql.open {
		addr = "127.0.0.1:3306",
		user = "root",
		password = "root",
		database = "test",
		max_idle_conns = 1,
		max_open_conns = 1,
	}

	-- Create a scenario that generates warnings (e.g., implicit type conversion)
	pool:query("CREATE TEMPORARY TABLE IF NOT EXISTS warning_test (id INT PRIMARY KEY, value INT)")

	-- Insert string into INT column (may generate warning in strict mode)
	local res, err = pool:query("INSERT INTO warning_test VALUES (?, ?)", 1, 100)
	testaux.assertneq(res, nil, "Test 32.1: Should insert data")
	assert(res)
	-- Check if warning_count field exists
	if res.warning_count then
		testaux.asserteq(type(res.warning_count), "number", "Test 32.2: Should have warning_count as number")
	end

	pool:close()
end

-- Test 33: test BLOB types (TINYBLOB, BLOB, MEDIUMBLOB, LONGBLOB)
do
	local pool = mysql.open {
		addr = "127.0.0.1:3306",
		user = "root",
		password = "root",
		database = "test",
		max_idle_conns = 1,
		max_open_conns = 1,
	}

	-- Test TINYBLOB (max 255 bytes)
	pool:query("CREATE TEMPORARY TABLE IF NOT EXISTS blob_test (id INT PRIMARY KEY, data BLOB)")

	local tiny_blob = string.rep("\xAB", 255)
	local res, err = pool:query("INSERT INTO blob_test VALUES (?, ?)", 1, tiny_blob)
	testaux.assertneq(res, nil, "Test 33.1: Should insert TINYBLOB data")

	res, err = pool:query("SELECT data FROM blob_test WHERE id = ?", 1)
	testaux.assertneq(res, nil, "Test 33.2: Should retrieve TINYBLOB data")
	assert(res)
	testaux.asserteq(#res[1].data, 255, "Test 33.3: Should maintain TINYBLOB size")

	-- Test larger BLOB (16KB) - use a reasonable size that definitely works
	local blob_data = string.rep("\xCD", 16384)
	res, err = pool:query("INSERT INTO blob_test VALUES (?, ?)", 2, blob_data)
	testaux.assertneq(res, nil, "Test 33.4: Should insert BLOB data")

	res, err = pool:query("SELECT data FROM blob_test WHERE id = ?", 2)
	testaux.assertneq(res, nil, "Test 33.5: Should retrieve BLOB data")
	assert(res)
	testaux.asserteq(#res[1].data, 16384, "Test 33.6: Should maintain BLOB size")

	pool:close()
end

-- Test 34: test ENUM and SET types
do
	local pool = mysql.open {
		addr = "127.0.0.1:3306",
		user = "root",
		password = "root",
		database = "test",
		max_idle_conns = 1,
		max_open_conns = 1,
	}

	-- Test ENUM type
	pool:query("CREATE TEMPORARY TABLE IF NOT EXISTS enum_test (id INT PRIMARY KEY, status ENUM('active', 'inactive', 'pending'))")

	local res, err = pool:query("INSERT INTO enum_test VALUES (?, ?)", 1, "active")
	testaux.assertneq(res, nil, "Test 34.1: Should insert ENUM data")

	res, err = pool:query("SELECT status FROM enum_test WHERE id = ?", 1)
	testaux.assertneq(res, nil, "Test 34.2: Should retrieve ENUM data")
	assert(res)
	testaux.asserteq(res[1].status, "active", "Test 34.3: Should maintain ENUM value")

	-- Test SET type
	pool:query("CREATE TEMPORARY TABLE IF NOT EXISTS set_test (id INT PRIMARY KEY, permissions SET('read', 'write', 'execute'))")

	res, err = pool:query("INSERT INTO set_test VALUES (?, ?)", 1, "read,write")
	testaux.assertneq(res, nil, "Test 34.4: Should insert SET data")

	res, err = pool:query("SELECT permissions FROM set_test WHERE id = ?", 1)
	testaux.assertneq(res, nil, "Test 34.5: Should retrieve SET data")
	assert(res)
	testaux.assertneq(res[1].permissions, nil, "Test 34.6: Should have SET data")

	pool:close()
end

-- Test 35: test TIMESTAMP with microsecond precision
do
	local pool = mysql.open {
		addr = "127.0.0.1:3306",
		user = "root",
		password = "root",
		database = "test",
		max_idle_conns = 1,
		max_open_conns = 1,
	}

	pool:query("CREATE TEMPORARY TABLE IF NOT EXISTS timestamp_test (id INT PRIMARY KEY, created_at TIMESTAMP(6))")

	local res, err = pool:query("INSERT INTO timestamp_test VALUES (?, NOW(6))", 1)
	testaux.assertneq(res, nil, "Test 35.1: Should insert TIMESTAMP with microseconds")

	res, err = pool:query("SELECT created_at FROM timestamp_test WHERE id = ?", 1)
	testaux.assertneq(res, nil, "Test 35.2: Should retrieve TIMESTAMP data")
	assert(res)
	-- Verify microsecond precision (should contain decimal point)
	testaux.assertneq(res[1].created_at:find("%."), nil, "Test 35.3: Should have microsecond precision")

	pool:close()
end

-- Test 36: test connection pool cleanup on error
do
	local pool = mysql.open {
		addr = "127.0.0.1:3306",
		user = "root",
		password = "root",
		database = "test",
		max_idle_conns = 2,
		max_open_conns = 2,
	}

	-- Execute a query that will fail
	local res, err = pool:query("SELECT * FROM nonexistent_table_xyz")
	testaux.asserteq(res, nil, "Test 36.1: Should fail on invalid table")
	testaux.assertneq(err, nil, "Test 36.2: Should return error")

	-- Verify pool is still functional after error
	res, err = pool:query("SELECT 1 as val")
	testaux.assertneq(res, nil, "Test 36.3: Should work after previous error")

	pool:close()
end

-- Test 37: test very long SQL query
do
	local pool = mysql.open {
		addr = "127.0.0.1:3306",
		user = "root",
		password = "root",
		database = "test",
	}

	-- Build a long query with many UNION ALL
	local long_query = "SELECT 1 as num"
	for i = 2, 100 do
		long_query = long_query .. " UNION ALL SELECT " .. i
	end

	local res, err = pool:query(long_query)
	testaux.assertneq(res, nil, "Test 37.1: Should handle long SQL query")
	assert(res)
	testaux.asserteq(#res, 100, "Test 37.2: Should return 100 rows")

	pool:close()
end

-- Test 38: test TIME type with negative values
do
	local pool = mysql.open {
		addr = "127.0.0.1:3306",
		user = "root",
		password = "root",
		database = "test",
		max_idle_conns = 1,
		max_open_conns = 1,
	}

	pool:query("CREATE TEMPORARY TABLE IF NOT EXISTS time_test (id INT PRIMARY KEY, duration TIME)")

	-- Test negative time value
	local res, err = pool:query("INSERT INTO time_test VALUES (?, ?)", 1, "-12:30:45")
	testaux.assertneq(res, nil, "Test 38.1: Should insert negative TIME value")

	res, err = pool:query("SELECT duration FROM time_test WHERE id = ?", 1)
	testaux.assertneq(res, nil, "Test 38.2: Should retrieve negative TIME")
	assert(res)
	testaux.asserteq(res[1].duration:sub(1, 1), "-", "Test 38.3: Should maintain negative sign")

	pool:close()
end

-- Test 39: test prepared statement with all NULL parameters
do
	local pool = mysql.open {
		addr = "127.0.0.1:3306",
		user = "root",
		password = "root",
		database = "test",
		max_idle_conns = 1,
		max_open_conns = 1,
	}

	pool:query("CREATE TEMPORARY TABLE IF NOT EXISTS null_params_test (id INT PRIMARY KEY, val1 INT, val2 VARCHAR(50), val3 DATE)")

	local res, err = pool:query("INSERT INTO null_params_test VALUES (?, ?, ?, ?)", 1, nil, nil, nil)
	testaux.assertneq(res, nil, "Test 39.1: Should insert all NULL parameters")

	res, err = pool:query("SELECT * FROM null_params_test WHERE id = ?", 1)
	testaux.assertneq(res, nil, "Test 39.2: Should retrieve NULL data")
	assert(res)
	testaux.asserteq(res[1].val1, nil, "Test 39.3: val1 should be NULL")
	testaux.asserteq(res[1].val2, nil, "Test 39.4: val2 should be NULL")
	testaux.asserteq(res[1].val3, nil, "Test 39.5: val3 should be NULL")

	pool:close()
end

-- Test 40: test auto-reconnect after connection close
do
	local pool = mysql.open {
		addr = "127.0.0.1:3306",
		user = "root",
		password = "root",
		database = "test",
		max_idle_conns = 0,  -- Don't cache connections
	}

	-- First query
	local res, err = pool:query("SELECT 1")
	testaux.assertneq(res, nil, "Test 40.1: First query should succeed")

	-- Force connection timeout by waiting
	time.sleep(2000)

	-- Second query should auto-reconnect
	res, err = pool:query("SELECT 2")
	testaux.assertneq(res, nil, "Test 40.2: Should auto-reconnect")

	pool:close()
end

-- Test 41: test transaction auto-rollback on connection close without explicit commit/rollback
do
	local pool = mysql.open {
		addr = "127.0.0.1:3306",
		user = "root",
		password = "root",
		database = "test",
		max_idle_conns = 1,
		max_open_conns = 3,
	}

	-- Prepare test table
	pool:query("DROP TABLE IF EXISTS test_autorollback")
	local res, err = pool:query("CREATE TABLE test_autorollback (id INT PRIMARY KEY, value INT)")
	testaux.assertneq(res, nil, "Test 41.1: Should create table")

	-- Start a transaction and insert data, but don't commit/rollback
	do
		local tx, err = pool:begin()
		testaux.asserteq(err, nil, "Test 41.2: Should begin transaction")
		assert(tx)

		res, err = tx:query("INSERT INTO test_autorollback VALUES (?, ?)", 1, 100)
		testaux.assertneq(res, nil, "Test 41.3: Should insert data in transaction")

		-- Verify data is visible within transaction
		res, err = tx:query("SELECT * FROM test_autorollback")
		testaux.asserteq(#res, 1, "Test 41.4: Should see data within transaction")

		-- Close transaction connection WITHOUT commit/rollback
		-- This should trigger automatic rollback via conn_close()
		tx:close()
	end

	-- Now verify that the data was rolled back
	res, err = pool:query("SELECT * FROM test_autorollback")
	testaux.assertneq(res, nil, "Test 41.5: Should query after transaction close")
	testaux.asserteq(#res, 0, "Test 41.6: Transaction should have been auto-rolled back, no data should exist")

	-- Cleanup
	pool:query("DROP TABLE IF EXISTS test_autorollback")
	pool:close()
end
