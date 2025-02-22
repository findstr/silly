local wg = require "core.sync.waitgroup"
local mysql = require "core.db.mysql"
local mysqlc = require "core.db.mysql.c"
local testaux = require "test.testaux"
local core = require "core"
local time = require "core.time"

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
	local stmt = mysqlc.compose_stmt_execute(1, #params, 0, table.unpack(params))
	testaux.asserteq(stmt, expected, "Test 7: compose_stmt_execute")
end

-------- core.db.mysql test

-- Test 8: create `test` database
do
	local pool = mysql.open {
		addr = "127.0.0.1:3306",
		user = "root",
		password = "root",
	}
	local res, err = pool:query("DROP DATABASE IF EXISTS test")
	testaux.assertneq(res, nil, "Test 8.1: drop `test` database")
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
	core.sleep(2500)
	testaux.asserteq(#pool.conns_idle, 0, "Test 12.2: Should clean up idle connections after timeout")

	-- Test max lifetime
	pool:query("SELECT 1") -- Create new connection
	core.sleep(4000)
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
		'drop table if exists test_usr',
		'create table test_usr (name varchar(10))',
		'insert into test_usr values ("name1")',
		'update test_usr set name="foo"',
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
	testaux.assertneq(res, nil, "Test 23.1: Should drop table")
	testaux.asserteq(err, nil, "Test 23.1: Should not return error")

	local res, err = pool:query("CREATE TABLE test_users (id INT PRIMARY KEY AUTO_INCREMENT, name VARCHAR(50))")
	testaux.assertneq(res, nil, "Test 23.2: Should create table")
	testaux.asserteq(err, nil, "Test 23.2: Should not return error")

	local tx<close>, err = pool:begin()
	testaux.asserteq(err, nil, "Test 23.3: Should not return error")

	assert(tx)
	local res, err = tx:query("INSERT INTO test_users (name) VALUES (?)", "Alice")
	testaux.assertneq(res, nil, "Test 23.4: Should insert data")
	testaux.asserteq(err, nil, "Test 23.4: Should not return error")

	local res, err = tx:query("SELECT * FROM test_users")
	testaux.asserteq(#res, 1, "Test 23.5: Should select data")
	testaux.asserteq(err, nil, "Test 23.5: Should not return error")

	local res, err = pool:query("SELECT * FROM test_users")
	testaux.asserteq(#res, 0, "Test 23.6: Transaction not commit, should not see data")
	testaux.asserteq(err, nil, "Test 23.6: Should not return error")

	local res, err = tx:commit()
	testaux.asserteq(err, nil, "Test 23.7: Should not return error")

	local res, err = tx:commit()
	testaux.asserteq(res, nil, "Test 23.8: Transaction already committed")
	testaux.assertneq(err, nil, "Test 23.8: Should return error")

	local res, err = pool:query("SELECT * FROM test_users")
	testaux.asserteq(#res, 1, "Test 23.8: Transaction commit, should see data")
	testaux.asserteq(err, nil, "Test 23.8: Should not return error")

	local res, err = pool:query("DROP TABLE IF EXISTS test_users")
	testaux.assertneq(res, nil, "Test 23.9: Should drop table")
	testaux.asserteq(err, nil, "Test 23.9: Should not return error")

	local res, err = pool:query("CREATE TABLE test_users (id INT PRIMARY KEY AUTO_INCREMENT, name VARCHAR(50))")
	testaux.assertneq(res, nil, "Test 23.10: Should create table")
	testaux.asserteq(err, nil, "Test 23.10: Should not return error")

	local tx<close>, err = pool:begin()
	testaux.asserteq(err, nil, "Test 23.11: Should not return error")
	assert(tx)

	local res, err = tx:query("INSERT INTO test_users (name) VALUES (?)", "Alice")
	testaux.assertneq(res, nil, "Test 23.12: Should insert data")
	testaux.asserteq(err, nil, "Test 23.12: Should not return error")

	local res, err = tx:rollback()
	testaux.asserteq(err, nil, "Test 23.13: Should not return error")

	local res, err = tx:rollback()
	testaux.asserteq(res, nil, "Test 23.14: Transaction already rolled back")
	testaux.assertneq(err, nil, "Test 23.14: Should return error")

	local res, err = pool:query("SELECT * FROM test_users")
	testaux.asserteq(#res, 0, "Test 23.15: Transaction rollback, should not see data")
	testaux.asserteq(err, nil, "Test 23.15: Should not return error")

	pool:close()
end
