local wg = require "silly.sync.waitgroup"
local mysql = require "silly.store.mysql"
local mysqlc = require "silly.store.mysql.c"
local testaux = require "test.testaux"
local silly = require "silly"
local time = require "silly.time"
local pcall = silly.pcall

local function assert_error(fn, reason, label)
	local ok, err = pcall(fn)
	testaux.asserteq(ok, false, label)
	testaux.assertcontains(err, reason, label .. ": reason")
end

--------mysql.c test
-- Test 1: Length-encoded integer boundary values
testaux.case("Test 1: Length-encoded integer boundary values", function()
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
end)

-- Test 2: Parse OK packet with basic fields
testaux.case("Test 2: Parse OK packet with basic fields", function()
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
end)

-- Test 3: Parse EOF packet with status flags
testaux.case("Test 3: Parse EOF packet with status flags", function()
	local data = string.char(
		0xFE,           -- EOF header
		0x02, 0x01,     -- warning_count (0x0102) little endian
		0x04, 0x03      -- status_flags (0x0304) little endian
	)
	local t = mysqlc.parse_eof_packet(data)
	testaux.asserteq(t.warning_count, 0x0102, "Test 3.1: EOF packet warning_count")
	testaux.asserteq(t.status_flags, 0x0304, "Test 3.2: EOF packet status_flags")
end)

-- Test 4: Parse standard error packet with SQLSTATE
testaux.case("Test 4: Parse standard error packet with SQLSTATE", function()
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
end)

-- Test 5: Column definition parsing (lparse_column_def)
testaux.case("Test 5: Column definition parsing (lparse_column_def)", function()
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
end)

-- Test 6: Binary row data parsing (lparse_row_data_binary)
testaux.case("Test 6: Binary row data parsing (lparse_row_data_binary)", function()
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
		0x00, 0x00, 0x80, 0xFF,
		-- col12: INT24 unsigned (0)
		0x00, 0x00, 0x00, 0x00,
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
		0xFF, 0xFF, 0x7F, 0x00,
		-- col12: INT24 unsigned (16777215)
		0xFF, 0xFF, 0xFF, 0x00,
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
	local invalid_cols = {{"invalid", 0x14, 0}}
	assert_error(function()
		mysqlc.parse_row_data_binary("\x00\x00", invalid_cols)
	end, "invalid field type", "Test 6.3: invalid cols")

	-- test short data
	local short_data = "\x00\x00\x01\x02\x03" -- INT needs four value bytes
	assert_error(function()
		mysqlc.parse_row_data_binary(short_data, {{"value", 0x03, 0}})
	end, "read_uint32le pos out of range", "Test 6.4: short data")

	-- test null bitmap overflow
	local columns = {}
	for i = 1, 7 do
		columns[i] = {"null" .. i, 0x06, 0}
	end
	assert_error(function()
		mysqlc.parse_row_data_binary("\x00\xfc", columns)
	end, "NULL bitmap", "Test 6.5: truncated NULL bitmap")
end)

-- Test 7: Prepared statement encoding (lcompose_stmt_execute)
testaux.case("Test 7: Prepared statement encoding (lcompose_stmt_execute)", function()
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
end)

-------- silly.store.mysql test

-- Test 8: create `test` database
testaux.case("Test 8: create `test` database", function()
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
end)

-- Test 9: Basic connection tests
testaux.case("Test 9: Basic connection tests", function()
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
end)


-- Test 10: invalid authentication
testaux.case("Test 10: invalid authentication", function()
	local admin = mysql.open {
		addr = "127.0.0.1:3306",
		user = "root",
		password = "root",
	}
	assert(admin:query("DROP USER IF EXISTS 'silly_invalid_auth_test'@'127.0.0.1'"))
	assert(admin:query("CREATE USER 'silly_invalid_auth_test'@'127.0.0.1' IDENTIFIED BY 'correct_pass'"))
	local pool = mysql.open {
		addr = "127.0.0.1:3306",
		user = "silly_invalid_auth_test",
		password = "wrong_pass",
	}
	local res, err = pool:ping()
	pool:close()
	assert(admin:query("DROP USER 'silly_invalid_auth_test'@'127.0.0.1'"))
	admin:close()
	assert(err)
	testaux.asserteq(res, nil, "Test 10: Should handle invalid credentials")
	testaux.asserteq(err.message:find("Access denied") ~= nil, true, "Test 10: Should handle invalid credentials")
end)

-- Test 11: Connection timeout
testaux.case("Test 11: Connection timeout", function()
	local pool = mysql.open {
		addr = "127.0.0.1:0001", -- Invalid address
		connect_timeout = 1,
		user = "root",
		password = "root",
	}
	local res, err = pool:ping()
	assert(err)
	local errno = require "silly.errno"
	local f = err.message:find(errno.CONNREFUSED, 1, true) or err.message:find(errno.TIMEDOUT, 1, true)
	testaux.asserteq(f ~= nil, true, "Test 11: Should handle connection timeout:" .. err.message)
	pool:close()
end)

-- Test 12: Connection pool lifecycle tests
testaux.case("Test 12: Connection pool lifecycle tests", function()
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
end)

-- Test 13: Concurrency stress test
testaux.case("Test 13: Concurrency stress test", function()
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
end)

-- Test 14: Prepared statement tests
testaux.case("Test 14: Prepared statement tests", function()
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
end)

-- Test 15: Connection leak detection
testaux.case("Test 15: Connection leak detection", function()
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
end)

-- Test 16: test mysql query table field
testaux.case("Test 16: test mysql query table field", function()
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
end)


-- Test 17: Insert and retrieve large field values (1024 bytes)
testaux.case("Test 17: Insert and retrieve large field values (1024 bytes)", function()
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
end)


-- Test 18: Handle very large field values (65536 bytes)
testaux.case("Test 18: Handle very large field values (65536 bytes)", function()
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
end)

-- Test 19: Verify OK packet message contains changed rows info
testaux.case("Test 19: Verify OK packet message contains changed rows info", function()
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
		if i == 4 then
			testaux.assertcontains(res.message, "Rows matched: 1", "Test 19.1: UPDATE info is decoded")
			testaux.assertcontains(res.message, "Changed: 1", "Test 19.2: Changed-row count is preserved")
		end
	end
	pool:close()
end)


-- Test 20: Handle null string values
testaux.case("Test 20: Handle null string values", function()
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
end)

-- Test 21: test mysql last_insert_id
testaux.case("Test 21: test mysql last_insert_id", function()
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
end)


-- Test 22: test mysql transaction
testaux.case("Test 22: test mysql transaction", function()
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
end)

-- Test 23: test mysql query with date
testaux.case("Test 23: test mysql query with date", function()
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
end)

-- Test 24: test caching_sha2_password authentication (MySQL 8.0+)
testaux.case("Test 24: test caching_sha2_password authentication (MySQL 8.0+)", function()
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
end)

-- Test 25: test utf8mb4 charset support
testaux.case("Test 25: test utf8mb4 charset support", function()
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
end)

-- Test 26: test prepared statement cache validation
testaux.case("Test 26: test prepared statement cache validation", function()
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
end)

-- Test 27: test multi-statement query support
testaux.case("Test 27: test multi-statement query support", function()
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
end)

-- Test 28: test connection pool with max_open_conns = 0 (unlimited)
testaux.case("Test 28: test connection pool with max_open_conns = 0 (unlimited)", function()
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
end)

-- Test 29: test connection object methods directly
testaux.case("Test 29: test connection object methods directly", function()
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
end)

-- Test 30: test PING command detailed response
testaux.case("Test 30: test PING command detailed response", function()
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
end)

-- Test 31: test special data types (JSON, DECIMAL, BIT)
testaux.case("Test 31: test special data types (JSON, DECIMAL, BIT)", function()
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
end)

-- Test 32: test warning count validation
testaux.case("Test 32: test warning count validation", function()
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
end)

-- Test 33: test BLOB types (TINYBLOB, BLOB, MEDIUMBLOB, LONGBLOB)
testaux.case("Test 33: test BLOB types (TINYBLOB, BLOB, MEDIUMBLOB, LONGBLOB)", function()
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
end)

-- Test 34: test ENUM and SET types
testaux.case("Test 34: test ENUM and SET types", function()
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
end)

-- Test 35: test TIMESTAMP with microsecond precision
testaux.case("Test 35: test TIMESTAMP with microsecond precision", function()
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
end)

-- Test 36: test connection pool cleanup on error
testaux.case("Test 36: test connection pool cleanup on error", function()
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
end)

-- Test 37: test very long SQL query
testaux.case("Test 37: test very long SQL query", function()
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
end)

-- Test 38: test TIME type with negative values
testaux.case("Test 38: test TIME type with negative values", function()
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
	testaux.asserteq(res[1].duration, "-12:30:45", "Test 38.3: Preserve the complete negative TIME value")

	pool:close()
end)

-- Test 39: test prepared statement with all NULL parameters
testaux.case("Test 39: test prepared statement with all NULL parameters", function()
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
end)

-- Test 40: test auto-reconnect after connection close
testaux.case("Test 40: test auto-reconnect after connection close", function()
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
end)

-- Test 41: test transaction auto-rollback on connection close without explicit commit/rollback
testaux.case("Test 41: test transaction auto-rollback on connection close without explicit commit/rollback", function()
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
end)

-- Test 42.1: Parameter metadata survives payload buffer growth
testaux.case("Test 42.1: Parameter metadata survives payload buffer growth", function()
	local first = string.rep("a", 20000)
	local second = string.rep("b", 100000)
	local packet = mysqlc.compose_stmt_execute(0x12345678, 12, 0,
		first, nil, -2, 1.5, true, second, false, "", 7, nil, "tail", nil)
	-- The first payload moves the initial buffer; the second forces another growth.
	-- NULL parameters 2, 10 and 12 set bits 1, 9 and 11 respectively.
	local expected = "\x17\x78\x56\x34\x12\x00\x01\x00\x00\x00" ..
		"\x02\x0a\x01" ..
		"\x0f\x00\x06\x00\x08\x00\x05\x00\x01\x00\x0f\x00" ..
		"\x01\x00\x0f\x00\x08\x00\x06\x00\x0f\x00\x06\x00" ..
		"\xfc\x20\x4e" .. first ..
		"\xfe\xff\xff\xff\xff\xff\xff\xff" ..
		"\x00\x00\x00\x00\x00\x00\xf8\x3f\x01" ..
		"\xfd\xa0\x86\x01" .. second ..
		"\x00\x00\x07\x00\x00\x00\x00\x00\x00\x00\x04tail"
	testaux.asserteq(packet, expected, "Test 42.1: Complete mixed-parameter wire packet")
end)

-- Test 42.2: The parameter type array can itself grow the buffer
testaux.case("Test 42.2: NULL bitmap survives parameter metadata growth", function()
	local params = {}
	-- 5000 parameters are valid for COM_STMT_EXECUTE. Their 10000-byte type
	-- array moves the buffer after its 625-byte NULL bitmap was reserved.
	local packet = mysqlc.compose_stmt_execute(1, 5000, 0, table.unpack(params, 1, 5000))
	local expected = "\x17\x01\x00\x00\x00\x00\x01\x00\x00\x00" ..
		string.rep("\xff", 625) .. "\x01" .. string.rep("\x06\x00", 5000)
	testaux.asserteq(packet, expected, "Test 42.2: Complete all-NULL wire packet")
end)

-- Test 43: INT24 binary rows use four-byte wire integers
testaux.case("Test 43: INT24 binary rows preserve following columns", function()
	local cases = {
		{flags = 0, packet = "\x00\x00\x00\x00\x80\xff\x2a", value = -8388608},
		{flags = 0, packet = "\x00\x00\xff\xff\x7f\x00\x2a", value = 8388607},
		{flags = 0x20, packet = "\x00\x00\xff\xff\xff\x00\x2a", value = 16777215},
	}
	for i, case in ipairs(cases) do
		local columns = {{"medium", 9, case.flags}, {"following", 1, 0}}
		local row = mysqlc.parse_row_data_binary(case.packet, columns)
		testaux.asserteq(row, {medium = case.value, following = 42},
			"Test 43." .. i .. ": INT24 value and following TINYINT")
	end
end)

-- Test 44: Compact DATETIME and TIMESTAMP rows retain the midnight component
testaux.case("Test 44: Compact temporal values retain midnight", function()
	local columns = {
		{"date", 10, 0}, {"datetime", 12, 0}, {"timestamp", 7, 0}, {"following", 1, 0},
	}
	local packet = "\x00\x00" ..
		"\x04\xe8\x07\x02\x1d\x04\xe8\x07\x02\x1d\x04\xe8\x07\x02\x1d\x2a"
	local row = mysqlc.parse_row_data_binary(packet, columns)
	testaux.asserteq(row, {
		date = "2024-02-29",
		datetime = "2024-02-29 00:00:00",
		timestamp = "2024-02-29 00:00:00",
		following = 42,
	}, "Test 44: DATE format and DATETIME/TIMESTAMP midnight")
end)

do
	local task = require "silly.task"
	local tcp = require "silly.net.tcp"
	local channel = require "silly.sync.channel"
	local hash = require "silly.crypto.hash"
	local pkey = require "silly.crypto.pkey"
	local pcall = silly.pcall
	local MAX_PAYLOAD = 0xffffff
	local OK_PACKET = "\0\0\0\2\0\0\0"
	local EOF_PACKET = "\xfe\0\0\2\0"
	local SCRAMBLE = "abcdefghijklmnopqrst"
	local PUBLIC_KEY = [[-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEApmUl+7J8zeWdOH6aiNwR
SOcFePTxuAyYsAEewVtBCAEvLVGxQtrsVvd6UosEd0aO/Qz3hvV32wYzI0ZzjGGf
y0lCCx9YB05SyYY+KpDwe/osMf4RtBS/jN1dVX7TiRQ3KsngMFSXp2aC6IpI5ngF
0PS/o2qbwkU19FCELE6G5WnAfniUaf7XEwrhAkMAczJovqOu4BAhBColr7cQK7CQ
K6VNEhQBzM/N/hGmIniPbC7kTjqyohWoLGPT+xQAe8WB39zbIHl+xEDoGAYaaI8I
7TlcQWwCOIxdm+w67CQmC/FyGTX5fPoK96drushzwvAKphQrpQwT5MxTDvoE9xgb
hQIDAQAB
-----END PUBLIC KEY-----
]]
	local function openpool(opts)
		opts = opts or {}
		opts.addr = opts.addr or "127.0.0.1:3306"
		opts.user = opts.user or "root"
		opts.password = opts.password or "root"
		opts.max_open_conns = opts.max_open_conns or 1
		opts.max_idle_conns = opts.max_idle_conns or 1
		return mysql.open(opts)
	end
	local function forkresult(fn)
		local started, done = channel.new(), channel.new()
		task.fork(function()
			started:push(true)
			done:push(table.pack(pcall(fn)))
		end)
		testaux.await(started, "MySQL request started")
		return done
	end
	local function awaitresult(done, label)
		local result = testaux.await(done, label)
		assert(result[1], result[2])
		return table.unpack(result, 2, result.n)
	end
	local function readframe(sock)
		local header = assert(sock:read(4, 3000))
		local len, seq = string.unpack("<I3B", header)
		local data = ""
		if len > 0 then
			data = assert(sock:read(len, 3000))
		end
		return data, seq
	end
	local function readmessage(sock)
		local chunks = {}
		local data, seq = readframe(sock)
		local first_seq = seq
		while #data == MAX_PAYLOAD do
			chunks[#chunks + 1] = data
			local next_seq
			data, next_seq = readframe(sock)
			assert(next_seq == (seq + 1) % 256, "fragment sequence")
			seq = next_seq
		end
		chunks[#chunks + 1] = data
		return table.concat(chunks), first_seq, seq
	end
	local function sendmessage(sock, data, seq)
		local pos = 1
		while #data - pos + 1 >= MAX_PAYLOAD do
			assert(sock:write({string.pack("<I3B", MAX_PAYLOAD, seq),
				data:sub(pos, pos + MAX_PAYLOAD - 1)}))
			pos = pos + MAX_PAYLOAD
			seq = (seq + 1) % 256
		end
		local tail = data:sub(pos)
		assert(sock:write({string.pack("<I3B", #tail, seq), tail}))
		return (seq + 1) % 256
	end
	local function greeting(sock, caps, plugin)
		caps = caps or 0x00288201
		plugin = plugin or "mysql_native_password"
		local packet = "\x0a" .. string.pack("<zI4c8BI2BI2I2Bc10", "8.0.0", 1,
			SCRAMBLE:sub(1, 8), 0, caps & 0xffff, 45, 2, caps >> 16, 21, "") ..
			SCRAMBLE:sub(9) .. "\0" .. plugin .. "\0"
		sendmessage(sock, packet, 0)
		return readmessage(sock)
	end
	local function login(sock)
		greeting(sock)
		sendmessage(sock, OK_PACKET, 2)
	end
	local function checkpassword(sock, challenge)
		local encrypted = readmessage(sock)
		local private_key = assert(pkey.new(testaux.KEY_A))
		local scrambled = assert(private_key:decrypt(encrypted, pkey.RSA_PKCS1_OAEP, "sha1"))
		local password = {}
		for i = 1, #scrambled do
			password[i] = string.char(scrambled:byte(i) ~ challenge:byte((i - 1) % #challenge + 1))
		end
		assert(table.concat(password) == "root\0", "RSA password uses auth-switch challenge")
	end
	local function column(name, typ)
		return "\3def\0\0\0" .. string.char(#name) .. name .. "\0\12" ..
			string.pack("<I2I4BI2Bxx", 45, 0xffffff, typ or 3, 0, 0)
	end
	local function preparepeer(sock, fields, params, id)
		local cmd, seq = readmessage(sock)
		assert(seq == 0 and cmd:byte() == 0x16, "COM_STMT_PREPARE")
		seq = sendmessage(sock, string.pack("<BI4I2I2BI2", 0, id or 1,
			#fields, params or 0, 0, 0), 1)
		for _ = 1, params or 0 do
			seq = sendmessage(sock, column("?", 253), seq)
		end
		if params and params > 0 then
			seq = sendmessage(sock, EOF_PACKET, seq)
		end
		for _, col in ipairs(fields) do
			seq = sendmessage(sock, col, seq)
		end
		if #fields > 0 then
			sendmessage(sock, EOF_PACKET, seq)
		end
		cmd, seq = readmessage(sock)
		assert(seq == 0 and cmd:byte() == 0x17, "COM_STMT_EXECUTE")
		return cmd
	end
	local function resulthead(sock, cols, seq)
		seq = sendmessage(sock, string.char(#cols), seq)
		for _, col in ipairs(cols) do
			seq = sendmessage(sock, col, seq)
		end
		return sendmessage(sock, EOF_PACKET, seq)
	end
	local function withpeer(port, opts, handler, body)
		local finished = channel.new()
		local sockets = {}
		local listener = assert(tcp.listen {
			addr = "127.0.0.1:" .. port,
			accept = function(sock)
				sockets[#sockets + 1] = sock
				local ok, err = pcall(handler, sock)
				sock:close()
				finished:push({ok = ok, err = err})
			end,
		})
		opts = opts or {}
		opts.addr = "127.0.0.1:" .. port
		local pool = openpool(opts)
		local ok, err = pcall(body, pool)
		pool:close()
		listener:close()
		for _, sock in ipairs(sockets) do
			sock:close()
		end
		for _ = 1, #sockets do
			local result = testaux.await(finished, "MySQL peer finished")
			if not result.ok then
				if ok then
					err = result.err
				else
					err = err .. "\nMySQL peer: " .. result.err
				end
				ok = false
			end
		end
		assert(ok, err)
	end

	testaux.case("Test 45.1: Idle expiration releases pool capacity", function()
		local pool = openpool {max_idle_time = 1}
		assert(pool:ping())
		testaux.elapse(2200)
		testaux.asserteq(pool.open_count, 0, "Test 45.1: Expired connection is not counted")
		assert(awaitresult(forkresult(function()
			return pool:ping()
		end), "replacement after idle expiration"))
		pool:close()
	end)

	testaux.case("Test 45.2: Lifetime expiration uses creation time", function()
		local pool = openpool {max_open_conns = 0}
		assert(pool:ping())
		local old = pool.conns_idle[1]
		local sock = old.fd
		old.created_at = old.created_at - 10
		pool.max_lifetime = 1
		assert(pool:ping())
		testaux.assertneq(pool.conns_idle[1].fd, sock, "Test 45.2: Lifetime is independent of return time")
		testaux.asserteq(pool.open_count, 1, "Test 45.3: Replacing expired connection preserves count")
		pool:close()
	end)

	testaux.case("Test 46: Broken connection releases a waiting request", function()
		local pool = openpool()
		local tx = assert(pool:begin())
		local done = forkresult(function()
			return pool:ping()
		end)
		tx.fd:close()
		local ok = tx:ping()
		assert(not ok)
		tx:close()
		local ok, err = awaitresult(done, "waiter after broken connection")
		assert(ok, err and err.message)
		pool:close()
	end)

	testaux.case("Test 46.1: Failed login releases capacity to the next waiter", function()
		local authenticating, release = channel.new(), channel.new()
		local attempts = 0
		withpeer(33146, nil, function(sock)
			attempts = attempts + 1
			if attempts == 1 then
				greeting(sock)
				authenticating:push(true)
				testaux.await(release, "release failed login")
				sendmessage(sock, "\xff" .. string.pack("<I2", 1045) .. "#28000Access denied", 2)
			else
				login(sock)
				assert(readmessage(sock):byte() == 0x0e)
				sendmessage(sock, OK_PACKET, 1)
			end
		end, function(pool)
			local first = forkresult(function()
				return pool:ping()
			end)
			testaux.await(authenticating, "first login is in flight")
			local second = forkresult(function()
				return pool:ping()
			end)
			release:push(true)
			local result, err = awaitresult(first, "failed login returns")
			testaux.asserteq(result, nil, "Test 46.1: Failed login is rejected")
			testaux.asserteq(err.errno, 1045, "Test 46.2: Preserve login error")
			assert(awaitresult(second, "waiter after failed login"))
			testaux.asserteq(attempts, 2, "Test 46.3: Waiter creates a replacement connection")
		end)
	end)

	testaux.case("Test 47: Pool close rejects waiting and subsequent requests", function()
		local pool = openpool()
		local tx = assert(pool:begin())
		local done = forkresult(function()
			return pool:query("SELECT 1")
		end)
		pool:close()
		local result, err = awaitresult(done, "waiter after pool close")
		testaux.asserteq(result, nil, "Test 47.1: Waiting query cannot execute after close")
		testaux.asserteq(err.message, "pool is closed", "Test 47.2: Waiting query reports pool closure")
		for _, method in ipairs({"ping", "begin", "query"}) do
			local result, err = pool[method](pool, "SELECT 1")
			testaux.asserteq(result, nil, "Test 47.3: Closed pool rejects " .. method)
			testaux.asserteq(err.message, "pool is closed", "Test 47.4: Closed pool error")
		end
		tx:close()
	end)

	testaux.case("Test 48: Pool close wins an in-flight handshake", function()
		local accepted, release = channel.new(), channel.new()
		withpeer(33148, nil, function(sock)
			accepted:push(true)
			testaux.await(release, "release MySQL greeting")
			login(sock)
			local cmd = sock:read(4, 3000)
			if cmd then
				local n = string.unpack("<I3", cmd)
				local payload = assert(sock:read(n, 3000))
				if payload:byte() == 0x0e then
					sendmessage(sock, OK_PACKET, 1)
				end
			end
		end, function(pool)
			local done = forkresult(function()
				return pool:ping()
			end)
			testaux.await(accepted, "MySQL socket accepted")
			pool:close()
			release:push(true)
			local result, err = awaitresult(done, "handshake after pool close")
			testaux.asserteq(result, nil, "Test 48.1: Closing pool cancels acquisition")
			testaux.asserteq(err.message, "pool is closed", "Test 48.2: Handshake reports pool closure")
		end)
	end)

	testaux.case("Test 49: Repeated close cannot affect a later transaction", function()
		local pool = openpool {max_idle_conns = 2}
		local old = assert(pool:begin())
		assert(old:commit())
		old:close()
		old:close()
		local current = assert(pool:begin())
		testaux.assertneq(old, current, "Test 49.1: Each checkout has its own transaction handle")
		old:close()
		local rows = assert(current:query("SELECT @@in_transaction AS active"))
		testaux.asserteq(rows[1].active, 1, "Test 49.2: Old handle cannot roll back current transaction")
		local result, err = old:query("SELECT 1")
		testaux.asserteq(result, nil, "Test 49.3: Closed handle cannot issue a query")
		testaux.assertneq(err, nil, "Test 49.4: Closed handle reports an error")
		assert(current:rollback())
		current:close()
		pool:close()
		testaux.asserteq(pool.open_count, 0, "Test 49.5: Connection is destroyed once")
	end)

	testaux.case("Test 50: Native authentication without lenenc capability", function()
		withpeer(33150, nil, function(sock)
			local response = greeting(sock, 0x00088201)
			local user, token, database, plugin = string.unpack("<zs1zz", response, 33)
			local sha = hash.new("sha1")
			local stage1 = hash.digest(sha, "root")
			local stage3 = hash.digest(sha, SCRAMBLE .. hash.digest(sha, stage1))
			local expected = {}
			for i = 1, #stage1 do
				expected[i] = string.char(stage1:byte(i) ~ stage3:byte(i))
			end
			assert(user == "root" and database == "" and plugin == "mysql_native_password",
				"native plugin name in handshake response")
			assert(token == table.concat(expected), "native token uses complete scramble")
			sendmessage(sock, OK_PACKET, 2)
			assert(readmessage(sock):byte() == 0x0e)
			sendmessage(sock, OK_PACKET, 1)
		end, function(pool)
			local ok, err = pool:ping()
			assert(ok, err and err.message)
		end)
	end)

	testaux.case("Test 51: Full authentication uses the auth-switch challenge", function()
		local challenge = "ABCDEFGHIJKLMNOPQRST"
		withpeer(33151, nil, function(sock)
			greeting(sock)
			sendmessage(sock, "\xfecaching_sha2_password\0" .. challenge .. "\0", 2)
			local token, seq = readmessage(sock)
			assert(#token == 32 and seq == 3, "caching_sha2 token")
			sendmessage(sock, "\1\4", 4)
			local request = readmessage(sock)
			assert(request == "\2", "public key requested")
			sendmessage(sock, "\1" .. PUBLIC_KEY, 6)
			checkpassword(sock, challenge)
			sendmessage(sock, OK_PACKET, 8)
			assert(readmessage(sock):byte() == 0x0e)
			sendmessage(sock, OK_PACKET, 1)
		end, function(pool)
			local ok, err = pool:ping()
			assert(ok, err and err.message)
		end)
	end)

	testaux.case("Test 52: Query errors during row transmission terminate the result", function()
		withpeer(33152, nil, function(sock)
			login(sock)
			local cols = {column("value", 3)}
			preparepeer(sock, cols)
			local seq = resulthead(sock, cols, 1)
			seq = sendmessage(sock, "\0\0" .. string.pack("<i4", 7), seq)
			sendmessage(sock, "\xff" .. string.pack("<I2", 1317) ..
				"#70100Query execution was interrupted", seq)
			local cmd = readmessage(sock)
			assert(cmd:byte() == 0x0e, "connection reusable after result ERR")
			sendmessage(sock, OK_PACKET, 1)
		end, function(pool)
			local rows, err = awaitresult(forkresult(function()
				return pool:query("SELECT value")
			end), "result ERR returns without another read")
			testaux.asserteq(rows, nil, "Test 52.1: Interrupted result is not returned")
			testaux.asserteq(err.errno, 1317, "Test 52.2: Preserve server error code")
			assert(pool:ping())
		end)
	end)

	testaux.case("Test 53: Multiple resultsets use their own column definitions", function()
		withpeer(33153, nil, function(sock)
			login(sock)
			preparepeer(sock, {})
			local seq = resulthead(sock, {column("first", 3)}, 1)
			seq = sendmessage(sock, "\0\0" .. string.pack("<i4", 7), seq)
			seq = sendmessage(sock, "\xfe\0\0\x0a\0", seq)
			seq = resulthead(sock, {column("second", 253)}, seq)
			seq = sendmessage(sock, "\0\0\3two", seq)
			seq = sendmessage(sock, "\xfe\0\0\x0a\0", seq)
			sendmessage(sock, OK_PACKET, seq)
			assert(readmessage(sock):byte() == 0x0e, "all resultsets drained before ping")
			sendmessage(sock, OK_PACKET, 1)
		end, function(pool)
			local rows, err = pool:query("CALL multi()")
			assert(rows, err and err.message)
			testaux.asserteq(rows, {{first = 7}, {second = "two"}}, "Test 53.1: Decode each resultset")
			assert(pool:ping())
		end)
	end)

	for i, size in ipairs({MAX_PAYLOAD - 1, MAX_PAYLOAD, MAX_PAYLOAD + 1}) do
		testaux.case("Test 54." .. i .. ": Outgoing packet boundary " .. size, function()
			withpeer(33160 + i, {max_packet_size = 64 * 1024 * 1024}, function(sock)
				login(sock)
				local data, first, last = readmessage(sock)
				assert(#data == size and data:sub(1, 5) == "\x16DO '", "complete prepare payload")
				assert(first == 0 and last == (size >= MAX_PAYLOAD and 1 or 0), "command fragments")
				sendmessage(sock, string.pack("<BI4I2I2BI2", 0, 1, 0, 0, 0, 0), (last + 1) % 256)
				assert(readmessage(sock):byte() == 0x17)
				sendmessage(sock, OK_PACKET, 1)
			end, function(pool)
				local sql = "DO '" .. string.rep("x", size - 6) .. "'"
				local result, err = pool:query(sql)
				assert(result, err and err.message)
			end)
			collectgarbage("collect")
		end)
	end
	for i, size in ipairs({MAX_PAYLOAD - 1, MAX_PAYLOAD, MAX_PAYLOAD + 1}) do
		testaux.case("Test 54." .. (i + 3) .. ": Incoming packet boundary " .. size, function()
			withpeer(33170 + i, {max_packet_size = 64 * 1024 * 1024}, function(sock)
				login(sock)
				local cols = {column("payload", 253)}
				preparepeer(sock, cols)
				local seq = resulthead(sock, cols, 1)
				local n = size - 6
				local row = "\0\0\xfd" .. string.pack("<I3", n) .. string.rep("x", n - 1) .. "z"
				seq = sendmessage(sock, row, seq)
				sendmessage(sock, EOF_PACKET, seq)
			end, function(pool)
				local rows, err = pool:query("SELECT payload")
				assert(rows, err and err.message)
				testaux.asserteq(#rows[1].payload, size - 6, "Test 54: Complete logical row length")
				testaux.asserteq(rows[1].payload:sub(-1), "z", "Test 54: Final fragment preserved")
			end)
			collectgarbage("collect")
		end)
	end

	testaux.case("Test 54.7: Multiple full fragments wrap packet sequence", function()
		local size = 2 * MAX_PAYLOAD
		withpeer(33177, {max_packet_size = 64 * 1024 * 1024}, function(sock)
			login(sock)
			local cols = {column("payload", 253)}
			preparepeer(sock, cols)
			local seq = resulthead(sock, cols, 1)
			for _ = 1, 251 do
				seq = sendmessage(sock, "\0\0\1s", seq)
			end
			assert(seq == 255, "large row begins at sequence 255")
			local n = size - 11
			local row = "\0\0\xfe" .. string.pack("<I8", n) .. string.rep("x", n - 1) .. "z"
			seq = sendmessage(sock, row, seq)
			assert(seq == 2, "two full fragments and empty terminator wrap through zero")
			sendmessage(sock, EOF_PACKET, seq)
		end, function(pool)
			local rows, err = pool:query("SELECT payload")
			assert(rows, err and err.message)
			testaux.asserteq(#rows, 252, "Test 54.7: All rows preserved across sequence wrap")
			testaux.asserteq(rows[1].payload, "s", "Test 54.8: Preceding row preserved")
			testaux.asserteq(#rows[252].payload, size - 11, "Test 54.9: Full-size fragments reassembled")
			testaux.asserteq(rows[252].payload:sub(-1), "z", "Test 54.10: Final data byte preserved")
		end)
		collectgarbage("collect")
	end)

	testaux.case("Test 55: Statement cache releases evicted server statements", function()
		local stats = channel.new()
		withpeer(33155, {max_stmts = 2}, function(sock)
			login(sock)
			local live = {}
			local prepared, closed, executed, count = 0, 0, 0, 0
			while true do
				local header = sock:read(4, 3000)
				if not header then
					return
				end
				local n = string.unpack("<I3", header)
				local cmd = assert(sock:read(n, 3000))
				local typ = cmd:byte()
				if typ == 0x16 then
					assert(count < 2, "eviction precedes the next server prepare")
					prepared = prepared + 1
					live[prepared] = true
					count = count + 1
					sendmessage(sock, string.pack("<BI4I2I2BI2", 0, prepared, 0, 0, 0, 0), 1)
				elseif typ == 0x19 then
					local id = string.unpack("<I4", cmd, 2)
					assert(live[id], "close a live statement")
					live[id] = nil
					count = count - 1
					closed = closed + 1
				elseif typ == 0x17 then
					local id = string.unpack("<I4", cmd, 2)
					assert(live[id], "execute a live statement")
					executed = executed + 1
					sendmessage(sock, OK_PACKET, 1)
					if executed == 4 then
						stats:push({prepared = prepared, closed = closed, count = count})
					end
				elseif typ == 0x01 then
					return
				else
					error("unexpected cache command: " .. typ)
				end
			end
		end, function(pool)
			for _, sql in ipairs({"DO 1", "DO 2", "DO 3", "DO 2"}) do
				local result, err = pool:query(sql)
				assert(result, err and err.message)
			end
			testaux.asserteq(testaux.await(stats, "statement cache activity"),
				{prepared = 3, closed = 1, count = 2}, "Test 55: Cache bound, eviction and reuse")
		end)
	end)

	testaux.case("Test 55.1: Zero statement capacity disables caching", function()
		local stats = channel.new()
		withpeer(33156, {max_stmts = 0}, function(sock)
			login(sock)
			for id = 1, 2 do
				preparepeer(sock, {}, 0, id)
				sendmessage(sock, OK_PACKET, 1)
				local closed = readmessage(sock)
				assert(closed:byte() == 0x19 and string.unpack("<I4", closed, 2) == id,
					"uncached statement is closed after execution")
			end
			stats:push(true)
		end, function(pool)
			assert(pool:query("DO 1"))
			assert(pool:query("DO 1"))
			testaux.await(stats, "uncached statements released")
		end)
	end)

	testaux.case("Test 55.2: Closed sessions do not retain SQL packets globally", function()
		withpeer(33157, {max_idle_conns = 0}, function(sock)
			login(sock)
			preparepeer(sock, {})
			sendmessage(sock, OK_PACKET, 1)
		end, function(pool)
			collectgarbage("collect")
			collectgarbage("collect")
			local before = collectgarbage("count")
			for i = 1, 24 do
				local sql = "DO '" .. string.rep("x", 65536) .. i .. "'"
				assert(pool:query(sql))
			end
			collectgarbage("collect")
			collectgarbage("collect")
			local retained = collectgarbage("count") - before
			testaux.assertlt(retained, 512, "Test 55.2: 1.5MB of one-shot SQL is collectible")
		end)
	end)

	testaux.case("Test 55.3: Failed prepare does not corrupt cache eviction state", function()
		withpeer(33158, {max_stmts = 1}, function(sock)
			login(sock)
			preparepeer(sock, {}, 0, 1)
			sendmessage(sock, OK_PACKET, 1)
			local closed = readmessage(sock)
			assert(closed:byte() == 0x19 and string.unpack("<I4", closed, 2) == 1,
				"old statement evicted")
			assert(readmessage(sock):byte() == 0x16)
			sendmessage(sock, "\xff" .. string.pack("<I2", 1064) .. "#42000Syntax error", 1)
			preparepeer(sock, {}, 0, 2)
			sendmessage(sock, OK_PACKET, 1)
		end, function(pool)
			assert(pool:query("DO 1"))
			local result, err = pool:query("invalid SQL")
			testaux.asserteq(result, nil, "Test 55.3: Failed prepare returns no result")
			testaux.asserteq(err.errno, 1064, "Test 55.4: Preserve prepare error")
			assert(pool:query("DO 2"))
		end)
	end)

	testaux.case("Test 56: Initial ERR packets preserve messages without SQLSTATE", function()
		local packet = "\xff" .. string.pack("<I2", 1040) .. "Too many connections"
		local err = mysqlc.parse_err_packet(packet)
		testaux.asserteq(err, {type = "ERR", errno = 1040, message = "Too many connections"},
			"Test 56.1: Error without SQLSTATE preserves the first character")
		local empty = mysqlc.parse_err_packet("\xff" .. string.pack("<I2", 1040))
		testaux.asserteq(empty.message, "", "Test 56.2: Empty error message is valid")
		withpeer(33180, nil, function(sock)
			sendmessage(sock, packet, 0)
		end, function(pool)
			local result, err = pool:ping()
			testaux.asserteq(result, nil, "Test 56.3: Reject the connection")
			testaux.asserteq(err.message, "Too many connections", "Test 56.4: Preserve initial server error")
			testaux.asserteq(pool.open_count, 0, "Test 56.5: Rejected connection releases capacity")
		end)
	end)

	testaux.case("Test 57.1: Invalid DATETIME wire lengths are rejected", function()
		for _, length in ipairs({1, 2, 3, 5, 6, 8, 9, 10, 12, 255}) do
			assert_error(function()
				mysqlc.parse_row_data_binary("\0\0" .. string.char(length) ..
					"\xe8\7\2\29\12\30\45\0\0\0\0", {{"value", 12, 0}})
			end, "invalid timestamp length", "Test 57.1: Reject length " .. length)
		end
	end)

	testaux.case("Test 57.2: Invalid TIME wire lengths are rejected", function()
		for _, length in ipairs({1, 4, 7, 9, 11, 13, 255}) do
			assert_error(function()
				mysqlc.parse_row_data_binary("\0\0" .. string.char(length) ..
					string.rep("\0", 12), {{"value", 11, 0}})
			end, "invalid time length", "Test 57.2: Reject length " .. length)
		end
	end)

	testaux.case("Test 57.3: Oversized decoded timestamps are rejected", function()
		assert_error(function()
			mysqlc.parse_row_data_binary("\0\0\11" ..
				string.pack("<I2BBBBBI4", 65535, 255, 255, 255, 255, 255, 0xffffffff),
				{{"value", 12, 0}})
		end, "timestamp is too long", "Test 57.3: Formatting cannot read past its output buffer")
	end)

	testaux.case("Test 58: Large bound parameters use eight-byte length encoding", function()
		local size = 0x1000000
		withpeer(33181, {max_packet_size = 64 * 1024 * 1024}, function(sock)
			login(sock)
			local packet = preparepeer(sock, {}, 2)
			assert(#packet == size + 25, "complete execute payload")
			assert(packet:sub(11, 17) == "\2\1\15\0\6\0\xfe", "parameter metadata and length marker")
			assert(string.unpack("<I8", packet, 18) == size, "eight-byte length")
			assert(packet:sub(26, 26) == "x" and packet:sub(-1) == "z", "complete parameter bytes")
			sendmessage(sock, OK_PACKET, 2)
		end, function(pool)
			local result, err = pool:query("DO ?, ?", string.rep("x", size - 1) .. "z", nil)
			assert(result, err and err.message)
		end)
		collectgarbage("collect")
	end)

	testaux.case("Test 59: Length-encoded integers distinguish NULL and truncation", function()
		local value, pos = mysqlc.parse_lenenc("\xfb", 1)
		testaux.asserteq(value, nil, "Test 59.1: NULL marker is not integer zero")
		testaux.asserteq(pos, 2, "Test 59.2: NULL marker advances one byte")
		for _, case in ipairs({
			{"", "read_lenenc"}, {"\xfc\1", "read_uint16le"},
			{"\xfd\1\2", "read_uint24le"}, {"\xfe" .. string.rep("\0", 7), "read_uint64le"},
			{"\xff", "invalid lenenc"},
		}) do
			assert_error(function()
				mysqlc.parse_lenenc(case[1], 1)
			end, case[2], "Test 59.3: Reject malformed length encoding")
		end
		assert_error(function()
			mysqlc.parse_row_data_binary("\0\0\xfb", {{"value", 253, 0}})
		end, "read_lenenc is null", "Test 59.4: Non-NULL binary string cannot use NULL length")
		assert_error(function()
			mysqlc.parse_row_data_binary("\0\0\5ab", {{"value", 253, 0}})
		end, "lenenc_string pos out of range", "Test 59.5: Truncated string value is rejected")
		assert_error(function()
			mysqlc.parse_err_packet("\xff\x28\4#HY")
		end, "sqlstate pos out of range", "Test 59.6: Truncated SQLSTATE is rejected")
		assert_error(function()
			mysqlc.parse_ok_packet(OK_PACKET .. "\5ab")
		end, "invalid pos", "Test 59.7: Truncated OK info is rejected")
		assert_error(function()
			mysqlc.parse_row_data_binary("\0", {{"value", 3, 0}})
		end, "only one byte", "Test 59.8: Row header cannot replace the NULL bitmap")
		assert_error(function()
			mysqlc.parse_row_data_binary("\0\0", {{"value", 1, 0}})
		end, "read_uint8 pos out of range", "Test 59.9: Non-NULL TINYINT requires a value byte")
	end)

	for i, plugin in ipairs({"mysql_native_password", "caching_sha2_password"}) do
		testaux.case("Test 60." .. i .. ": Empty password with " .. plugin, function()
			withpeer(33182 + i, {password = ""}, function(sock)
				local response = greeting(sock, nil, plugin)
				local _, token = string.unpack("<zs1", response, 33)
				assert(token == "", "empty password has no challenge token")
				sendmessage(sock, OK_PACKET, 2)
				assert(readmessage(sock):byte() == 0x0e)
				sendmessage(sock, OK_PACKET, 1)
			end, function(pool)
				assert(pool:ping())
			end)
		end)
	end

	testaux.case("Test 60.3: Fast SHA2 authentication consumes the final OK", function()
		withpeer(33185, nil, function(sock)
			greeting(sock, nil, "caching_sha2_password")
			sendmessage(sock, "\1\3", 2)
			sendmessage(sock, OK_PACKET, 3)
			assert(readmessage(sock):byte() == 0x0e)
			sendmessage(sock, "\xff" .. string.pack("<I2", 1053) .. "#08S01Server shutdown", 1)
		end, function(pool)
			local result, err = pool:ping()
			testaux.asserteq(result, nil, "Test 60.3: PING error is not confused with login OK")
			testaux.asserteq(err.errno, 1053, "Test 60.4: Preserve PING server error")
		end)
	end)

	testaux.case("Test 60.4: SHA256 authentication switch completes RSA exchange", function()
		local challenge = "ABCDEFGHIJKLMNOPQRST"
		withpeer(33187, nil, function(sock)
			greeting(sock)
			sendmessage(sock, "\xfesha256_password\0" .. challenge .. "\0", 2)
			assert(readmessage(sock) == "\1", "SHA256 public key request")
			sendmessage(sock, "\1" .. PUBLIC_KEY, 4)
			checkpassword(sock, challenge)
			sendmessage(sock, OK_PACKET, 6)
			for _ = 1, 2 do
				assert(readmessage(sock):byte() == 0x0e)
				sendmessage(sock, OK_PACKET, 1)
			end
		end, function(pool)
			assert(pool:ping())
			assert(pool:ping())
		end)
	end)

	testaux.case("Test 61: Failed COMMIT still rolls back on close", function()
		withpeer(33186, nil, function(sock)
			login(sock)
			assert(readmessage(sock) == "\3BEGIN")
			sendmessage(sock, "\0\0\0\3\0\0\0", 1)
			assert(readmessage(sock) == "\3COMMIT")
			sendmessage(sock, "\xff" .. string.pack("<I2", 1180) .. "#HY000Commit failed", 1)
			assert(readmessage(sock) == "\3ROLLBACK", "failed COMMIT cannot suppress rollback")
			sendmessage(sock, OK_PACKET, 1)
			assert(readmessage(sock):byte() == 0x0e)
			sendmessage(sock, OK_PACKET, 1)
		end, function(pool)
			local tx = assert(pool:begin())
			local result, err = tx:commit()
			testaux.asserteq(result, nil, "Test 61.1: COMMIT failure is reported")
			testaux.asserteq(err.errno, 1180, "Test 61.2: Preserve commit error")
			tx:close()
			assert(pool:ping())
		end)
	end)

	testaux.case("Test 62: Invalid parameters retire their acquired session", function()
		local pool = openpool()
		assert_error(function()
			pool:query("SELECT ?", {})
		end, "invalid parameter type", "Test 62.1: Reject unsupported parameter type")
		testaux.asserteq(pool.open_count, 0, "Test 62.2: Error does not leak a pool slot")
		assert_error(function()
			pool:query("SELECT ?", 1, 2)
		end, "require param_count", "Test 62.3: Reject incorrect parameter count")
		testaux.asserteq(pool.open_count, 0, "Test 62.4: Argument mismatch does not leak a pool slot")
		assert(pool:ping())
		pool:close()
	end)

	testaux.case("Test 63: EOF during result metadata retires the session", function()
		local attempts = 0
		withpeer(33188, nil, function(sock)
			attempts = attempts + 1
			login(sock)
			if attempts == 1 then
				preparepeer(sock, {column("value", 3)})
				sendmessage(sock, "\1", 1)
			else
				assert(readmessage(sock):byte() == 0x0e)
				sendmessage(sock, OK_PACKET, 1)
			end
		end, function(pool)
			local errno = require "silly.errno"
			local result, err = pool:query("SELECT value")
			testaux.asserteq(result, nil, "Test 63.1: Truncated metadata returns no rows")
			testaux.assertcontains(err.message, errno.EOF, "Test 63.2: Preserve transport closure")
			testaux.asserteq(pool.open_count, 0, "Test 63.3: Failed reader releases its slot")
			assert(pool:ping())
			testaux.asserteq(attempts, 2, "Test 63.4: Subsequent request uses a fresh session")
		end)
	end)

	testaux.case("Test 64: Failed automatic rollback wakes a waiting request", function()
		local attempts = 0
		withpeer(33189, nil, function(sock)
			attempts = attempts + 1
			login(sock)
			if attempts == 1 then
				assert(readmessage(sock) == "\3BEGIN")
				sendmessage(sock, "\0\0\0\3\0\0\0", 1)
				assert(readmessage(sock) == "\3ROLLBACK")
				sendmessage(sock, "\xff" .. string.pack("<I2", 1317) .. "#70100Rollback interrupted", 1)
			else
				assert(readmessage(sock):byte() == 0x0e)
				sendmessage(sock, OK_PACKET, 1)
			end
		end, function(pool)
			local tx = assert(pool:begin())
			local done = forkresult(function()
				return pool:ping()
			end)
			tx:close()
			assert(awaitresult(done, "waiter after failed rollback"))
			testaux.asserteq(attempts, 2, "Test 64.1: Failed rollback session is not reused")
			testaux.asserteq(pool.open_count, 1, "Test 64.2: Replacement owns the single pool slot")
		end)
	end)
end
