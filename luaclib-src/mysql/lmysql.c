#include <stdlib.h>
#include <string.h>
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>

#include "silly.h"
#include "binary.h"
#include "field_type.h"
#include "lua_buffer_ex.h"

#define COM_QUERY 0x03
#define COM_PING 0x0e
#define COM_STMT_PREPARE 0x16
#define COM_STMT_EXECUTE 0x17
#define COM_STMT_CLOSE 0x19
#define COM_STMT_RESET 0x1a

#define COLUMN_DEF_NAME		1
#define COLUMN_DEF_FIELD_TYPE 	2
#define COLUMN_DEF_FIELD_FLAGS  3

enum UPVAL {
	UPVAL_OK = 1,
	UPVAL_ERR,
	UPVAL_EOF,
	UPVAL_LOCAL_INFILE,
	UPVAL_TYPE,
	UPVAL_AFFECTED_ROWS,
	UPVAL_LAST_INSERT_ID,
	UPVAL_SERVER_STATUS,
	UPVAL_WARNING_COUNT,
	UPVAL_MESSAGE,
	UPVAL_ERRNO,
	UPVAL_STAGE,
	UPVAL_MAX_STAGE,
	UPVAL_PROGRESS,
	UPVAL_PROGRESS_INFO,
	UPVAL_SQLSTATE,
	UPVAL_FILENAME,
	UPVAL_STATUS_FLAGS,
	UPVAL_MAX,
};

/// lenenc_parse(data: string, pos: number?): number, number pos
static int lparse_lenenc(lua_State *L)
{
	int is_null;
	lua_Integer v;
	struct binary chk;
	binary_check(L, &chk, "parse_enenc", 1);
	chk.start = luaL_optinteger(L, 2, 1) - 1; // lua index start from 1
	chk.pos = chk.start;
	v = binary_read_lenenc_with_null(&chk, &is_null);
	if (is_null) {
		lua_pushnil(L);
	} else {
		lua_pushinteger(L, v);
	}
	lua_pushinteger(L, chk.pos + 1); // lua index start from 1
	return 2;
}

/// to_ok_packet(packet: string)
static int lparse_ok_packet(lua_State *L)
{
	struct binary chk;
	lua_Integer affected_rows, last_insert_id, server_status, warning_count;
	binary_check(L, &chk, "parse_ok_packet", 1);
	chk.pos = 1; // skip the first byte
	affected_rows = binary_read_lenenc(&chk);
	last_insert_id = binary_read_lenenc(&chk);
	server_status = binary_read_uint16le(&chk);
	warning_count = binary_read_uint16le(&chk);
	/// t = {}
	lua_createtable(L, 0, 5);
	/// t.type = "OK"
	lua_pushvalue(L, lua_upvalueindex(UPVAL_TYPE));
	lua_pushvalue(L, lua_upvalueindex(UPVAL_OK));
	lua_settable(L, -3);
	/// t.affected_rows = affected_rows
	lua_pushvalue(L, lua_upvalueindex(UPVAL_AFFECTED_ROWS));
	lua_pushinteger(L, affected_rows);
	lua_settable(L, -3);
	/// t.last_insert_id = last_insert_id
	lua_pushvalue(L, lua_upvalueindex(UPVAL_LAST_INSERT_ID));
	lua_pushinteger(L, last_insert_id);
	lua_settable(L, -3);
	/// t.server_status = server_status
	lua_pushvalue(L, lua_upvalueindex(UPVAL_SERVER_STATUS));
	lua_pushinteger(L, server_status);
	lua_settable(L, -3);
	/// t.warning_count = warning_count
	lua_pushvalue(L, lua_upvalueindex(UPVAL_WARNING_COUNT));
	lua_pushinteger(L, warning_count);
	lua_settable(L, -3);
	if (chk.pos < chk.len) {
		lua_Integer len = binary_read_lenenc(&chk);
		if (len + chk.pos > chk.len) {
			return luaL_error(L, "invalid pos: %d, len: %d",
					  chk.pos, chk.len);
		}
		/// t.message = message
		lua_pushvalue(L, lua_upvalueindex(UPVAL_MESSAGE));
		lua_pushlstring(L, (const char *)chk.data + chk.pos, len);
		lua_settable(L, -3);
	}
	return 1;
}

/// to_eof_packet(packet: string)
static int lparse_eof_packet(lua_State *L)
{
	struct binary chk;
	lua_Integer warning_count, status_flags;
	binary_check(L, &chk, "parse_eof_packet", 1);
	chk.pos = 1; // skip the first byte
	warning_count = binary_read_uint16le(&chk);
	status_flags = binary_read_uint16le(&chk);
	/// t = {}
	lua_createtable(L, 0, 3);
	/// t.type = "EOF"
	lua_pushvalue(L, lua_upvalueindex(UPVAL_TYPE));
	lua_pushvalue(L, lua_upvalueindex(UPVAL_EOF));
	lua_settable(L, -3);
	/// t.warning_count = warning_count
	lua_pushvalue(L, lua_upvalueindex(UPVAL_WARNING_COUNT));
	lua_pushinteger(L, warning_count);
	lua_settable(L, -3);
	/// t.status_flags = status_flags
	lua_pushvalue(L, lua_upvalueindex(UPVAL_STATUS_FLAGS));
	lua_pushinteger(L, status_flags);
	lua_settable(L, -3);
	return 1;
}

/// to_local_infile_packet(packet: string)
static int lparse_local_infile_packet(lua_State *L)
{
	struct binary chk;
	binary_check(L, &chk, "parse_local_infile_packet", 1);
	chk.pos += 1; // skip the first byte
	/// t = {}
	lua_createtable(L, 0, 2);
	/// t.type = "LOCAL_INFILE"
	lua_pushvalue(L, lua_upvalueindex(UPVAL_TYPE));
	lua_pushvalue(L, lua_upvalueindex(UPVAL_LOCAL_INFILE));
	lua_settable(L, -3);
	/// t.filename = filename
	lua_pushvalue(L, lua_upvalueindex(UPVAL_FILENAME));
	lua_pushlstring(L, (const char *)chk.data + chk.pos, chk.len - chk.pos);
	lua_settable(L, -3);
	return 1;
}

/// to_err_packet(packet: string)
static int lparse_err_packet(lua_State *L)
{
	lua_Integer len;
	struct binary chk;
	lua_Integer errn;
	binary_check(L, &chk, "parse_err_packet", 1);
	chk.pos = 1; // skip the first byte
	errn = binary_read_uint16le(&chk);
	/// t = {}
	lua_createtable(L, 0, 6);
	/// t.type = "ERR"
	lua_pushvalue(L, lua_upvalueindex(UPVAL_TYPE));
	lua_pushvalue(L, lua_upvalueindex(UPVAL_ERR));
	lua_settable(L, -3);
	/// t.errno = errn
	lua_pushvalue(L, lua_upvalueindex(UPVAL_ERRNO));
	lua_pushinteger(L, errn);
	lua_settable(L, -3);
	if (errn == 0xffff) {
		/// t.stage = stage
		lua_pushvalue(L, lua_upvalueindex(UPVAL_STAGE));
		lua_pushinteger(L, binary_read_uint8(&chk));
		lua_settable(L, -3);
		/// t.max_stage = max_stage
		lua_pushvalue(L, lua_upvalueindex(UPVAL_MAX_STAGE));
		lua_pushinteger(L, binary_read_uint8(&chk));
		lua_settable(L, -3);
		/// t.progress = progress
		lua_pushvalue(L, lua_upvalueindex(UPVAL_PROGRESS));
		lua_pushinteger(L, binary_read_uint32le(&chk));
		lua_settable(L, -3);
		/// t.progress_info = progress_info
		len = binary_read_lenenc(&chk);
		if (len + chk.pos > chk.len) {
			return binary_error(&chk, "progress_info pos out of range");
		}
		lua_pushvalue(L, lua_upvalueindex(UPVAL_PROGRESS_INFO));
		lua_pushlstring(L, (const char *)(chk.data + chk.pos), len);
		lua_settable(L, -3);
		return 0;
	}
	if (binary_read_uint8(&chk) == '#') {
		if (chk.pos + 5 > chk.len) {
			return binary_error(&chk, "sqlstate pos out of range");
		}
		/// t.sqlstate = sqlstate
		lua_pushvalue(L, lua_upvalueindex(UPVAL_SQLSTATE));
		lua_pushlstring(L, (const char *)(chk.data + chk.pos), 5);
		lua_settable(L, -3);
		chk.pos += 5;
	}
	/// t.message = message
	len = chk.len - chk.pos;
	lua_pushvalue(L, lua_upvalueindex(UPVAL_MESSAGE));
	lua_pushlstring(L, (const char *)(chk.data + chk.pos), len);
	lua_settable(L, -3);
	return 1;
}

/// parse_column_def(data: string) col
static int lparse_column_def(lua_State *L)
{
	struct binary chk;
	const char *name;
	lua_Integer len;
	lua_Integer namelen;
	lua_Integer charset;
	lua_Integer max_column_size;
	lua_Integer field_type;
	lua_Integer field_flags;
	binary_check(L, &chk, "parse_column_def", 1);
	len = binary_read_lenenc(&chk); // catalog
	chk.pos += len;
	len = binary_read_lenenc(&chk); // schema
	chk.pos += len;
	len = binary_read_lenenc(&chk); // table alias
	chk.pos += len;
	len = binary_read_lenenc(&chk); // table
	chk.pos += len;
	len = binary_read_lenenc(&chk); // column alias
	name = (const char *)(chk.data + chk.pos);
	namelen = len;
	chk.pos += len;
	len = binary_read_lenenc(&chk); // column
	chk.pos += len;
	chk.pos += 1;                         // ignore the filler
	charset = binary_read_uint16le(&chk);         // charset
	max_column_size = binary_read_uint32le(&chk); // max_column_size
	field_type = binary_read_uint8(&chk);          // field_type
	field_flags = binary_read_uint16le(&chk);     // field_flags
	(void)charset;
	(void)max_column_size;
	lua_createtable(L, 3, 0);
	lua_pushlstring(L, name, namelen);
	lua_rawseti(L, -2, COLUMN_DEF_NAME);
	lua_pushinteger(L, field_type);
	lua_rawseti(L, -2, COLUMN_DEF_FIELD_TYPE);
	lua_pushinteger(L, field_flags);
	lua_rawseti(L, -2, COLUMN_DEF_FIELD_FLAGS);
	return 1;
}

static inline void parse_timestamp(lua_State *L, struct binary *chk, int is_date)
{
	int n;
	char buf[32];
	lua_Integer len;
	uint16_t year;
	uint8_t month, day, hour, minute, second;
	uint32_t microsecond;
	len = binary_read_uint8(chk);
	if (len == 0) {
		if (is_date) {
			lua_pushliteral(L, "0000-00-00");
		} else {
			lua_pushliteral(L, "0000-00-00 00:00:00");
		}
		return;
	}
	year = binary_read_uint16le(chk);
	month = binary_read_uint8(chk);
	day = binary_read_uint8(chk);
	switch (len) {
	case 4:
		n = snprintf(buf, sizeof(buf), "%04d-%02d-%02d", year, month, day);
		break;
	case 7:
		hour = binary_read_uint8(chk);
		minute = binary_read_uint8(chk);
		second = binary_read_uint8(chk);
		n = snprintf(buf, sizeof(buf), "%04d-%02d-%02d %02d:%02d:%02d",
			year, month, day, hour, minute, second);
		break;
	case 11:
		hour = binary_read_uint8(chk);
		minute = binary_read_uint8(chk);
		second = binary_read_uint8(chk);
		microsecond = binary_read_uint32le(chk);
		n = snprintf(buf, sizeof(buf), "%04d-%02d-%02d %02d:%02d:%02d.%06u",
			year, month, day, hour, minute, second, microsecond);
		break;
	default:
		lua_pushliteral(L, "2017-09-09 20:08:09");
		return;
	}
	lua_pushlstring(L, buf, n);
	return;
}

static inline void parse_time(lua_State *L, struct binary *chk)
{
	int len;
	uint8_t is_neg;
	uint32_t days;
	uint32_t hour;
	uint8_t minute;
	uint8_t second;
	char output[32];
	size_t output_len;
	len = binary_read_uint8(chk);
	if (len == 0) {
		lua_pushliteral(L, "00:00:00");
		return;
	}
	is_neg = binary_read_uint8(chk);
	days = binary_read_uint32le(chk);
	hour = binary_read_uint8(chk);
	minute = binary_read_uint8(chk);
	second = binary_read_uint8(chk);
	output_len = 0;
	if (is_neg) {
		output[0] = '-';
		output_len++;
	}
	hour += days * 24;
	if (len > 8 && output_len < sizeof(output)) {
		uint32_t microsecond = binary_read_uint32le(chk);
		output_len += snprintf(output + output_len, sizeof(output) - output_len,
			"%u:%02u:%02u.%06u", hour, minute, second, microsecond);
	} else {
		output_len += snprintf(output + output_len, sizeof(output) - output_len,
			"%u:%02u:%02u", hour, minute, second);
	}
	lua_pushlstring(L, output, output_len);
}

static inline void parse_field(struct binary *chk, lua_Integer field_type, lua_Integer field_flags)
{
	lua_Integer len;
	lua_State *L = chk->L;
	int is_signed = (field_flags & FIELD_FLAG_UNSIGNED) == 0;
	switch (field_type) {
	case MYSQL_TYPE_TINY:
		if (is_signed) {
			lua_pushinteger(L, binary_read_int8(chk));
		} else {
			lua_pushinteger(L, binary_read_uint8(chk));
		}
		break;
	case MYSQL_TYPE_SHORT:
	case MYSQL_TYPE_YEAR:
		if (is_signed) {
			lua_pushinteger(L, binary_read_int16le(chk));
		} else {
			lua_pushinteger(L, binary_read_uint16le(chk));
		}
		break;
	case MYSQL_TYPE_LONG:
		if (is_signed) {
			lua_pushinteger(L, binary_read_int32le(chk));
		} else {
			lua_pushinteger(L, binary_read_uint32le(chk));
		}
		break;
	case MYSQL_TYPE_FLOAT:
		lua_pushnumber(L, binary_read_float32le(chk));
		break;
	case MYSQL_TYPE_DOUBLE:
		lua_pushnumber(L, binary_read_float64le(chk));
		break;
	case MYSQL_TYPE_LONGLONG:
		if (is_signed) {
			lua_pushinteger(L, binary_read_int64le(chk));
		} else {
			lua_pushinteger(L, binary_read_uint64le(chk));
		}
		break;
	case MYSQL_TYPE_INT24:
		if (is_signed) {
			lua_pushinteger(L, binary_read_int24le(chk));
		} else {
			lua_pushinteger(L, binary_read_uint24le(chk));
		}
		break;
		case MYSQL_TYPE_NULL:
		lua_pushnil(L);
		break;
	case MYSQL_TYPE_DATE:
		parse_timestamp(L, chk, 1);
		break;
	case MYSQL_TYPE_TIMESTAMP:
	case MYSQL_TYPE_DATETIME:
		parse_timestamp(L, chk, 0);
		break;
	case MYSQL_TYPE_TIME:
		parse_time(L, chk);
		break;
	case MYSQL_TYPE_NEWDATE:
	case MYSQL_TYPE_VARCHAR:
	case MYSQL_TYPE_BIT:
	case MYSQL_TYPE_JSON:
	case MYSQL_TYPE_NEWDECIMAL:
	case MYSQL_TYPE_ENUM:
	case MYSQL_TYPE_SET:
	case MYSQL_TYPE_TINY_BLOB:
	case MYSQL_TYPE_MEDIUM_BLOB:
	case MYSQL_TYPE_LONG_BLOB:
	case MYSQL_TYPE_BLOB:
	case MYSQL_TYPE_VAR_STRING:
	case MYSQL_TYPE_STRING:
	case MYSQL_TYPE_GEOMETRY:
		len = binary_read_lenenc(chk);
		if (len + chk->pos > chk->len) {
			binary_error(chk, "lenenc_string pos out of range");
		}
		lua_pushlstring(L, (const char *)(chk->data + chk->pos), len);
		chk->pos += len;
		break;
	default:
		binary_error(chk, "invalid field type");
	}
}

// parse_row_data_binary(data:string, def:column_def[])
static int lparse_row_data_binary(lua_State *L)
{
	int stk_def = 2;
	struct binary chk;
	lua_Integer i;
	lua_Integer ncols;
	lua_Integer null_bytes;
	const uint8_t *null_map;
	binary_check(L, &chk, "parse_row_data_binary", 1);
	chk.pos += 1;
	if (chk.pos >= chk.len) {
		return binary_error(&chk, "parse_row_data_binary only one byte");
	}
	null_map = (const uint8_t *)(chk.data + chk.pos);
	ncols = lua_rawlen(L, stk_def);
	// system reserved first 2 bits
	null_bytes = (ncols + 7 + 2) / 8;
	chk.pos += null_bytes;
	lua_createtable(L, 0, ncols);
	for (i = 0; i < ncols; i++) {
		lua_Integer field_type;
		lua_Integer field_flags;
		int bits = i + 2;
		int byte = bits / 8;
		int bit = bits % 8;
		if (null_map[byte] & (1 << bit)) { // null
			continue;
		}
		lua_rawgeti(L, stk_def, i + 1);	//col def
		lua_rawgeti(L, -1, COLUMN_DEF_FIELD_TYPE);
		field_type = lua_tointeger(L, -1);
		lua_rawgeti(L, -2, COLUMN_DEF_FIELD_FLAGS);
		field_flags = lua_tointeger(L, -1);
		lua_pop(L, 2);
		lua_rawgeti(L, -1, COLUMN_DEF_NAME);
		parse_field(&chk, field_type, field_flags);
		lua_settable(L, -4);
		lua_pop(L, 1);
	}
	return 1;
}

static inline void add_params(luaL_Buffer *b, int arg_start, int arg_num)
{
	lua_Integer null_count;
	uint8_t *null_map;
	uint8_t *types_buf;
	// null map
	null_count = (arg_num + 7) / 8;
	null_map = (uint8_t *)luaL_prepbuffsize(b, null_count);
	luaL_addsize(b, null_count);
	memset(null_map, 0, null_count);
	// send server type
	luaL_addchar(b, 0x01);
	types_buf = (uint8_t *)luaL_prepbuffsize(b, arg_num * 2);
	luaL_addsize(b, arg_num * 2);
	memset(types_buf, 0, arg_num * 2);
	// byte<1> field type, byte<1> param flags
	for (lua_Integer i = 0; i < arg_num; i++) {
		int stk = i + arg_start;
		int type = lua_type(b->L, stk);
		switch (type) {
		case LUA_TNUMBER:
			if (lua_isinteger(b->L, stk)) {
				types_buf[i * 2] = MYSQL_TYPE_LONGLONG;
				luaL_addint8(b, lua_tointeger(b->L, stk));
			} else {
				types_buf[i * 2] = MYSQL_TYPE_DOUBLE;
				luaL_adddouble(b, lua_tonumber(b->L, stk));
			}
			break;
		case LUA_TSTRING:
			types_buf[i * 2] = MYSQL_TYPE_VARCHAR;
			luaL_addlenenc_string(b, stk);
			break;
		case LUA_TBOOLEAN:
			types_buf[i * 2] = MYSQL_TYPE_TINY;
			luaL_addchar(b, lua_toboolean(b->L, stk) ? 0x01 : 0x00);
			break;
		case LUA_TNIL:
			types_buf[i * 2] = MYSQL_TYPE_NULL;
			null_map[i / 8] |= (1 << (i % 8));
			break;
		default:
			luaL_error(b->L, "invalid parameter type: %s",
				   lua_typename(b->L, type));
		}
	}
}

/// compose_stmt_execute(prepare_id: number, param_count: number, cursor_type: number, params: varargs)
static int lcompose_stmt_execute(lua_State *L)
{
	int arg_start = 4;
	luaL_Buffer b;
	lua_Integer prepare_id = luaL_checkinteger(L, 1);
	lua_Integer param_count = luaL_checkinteger(L, 2);
	lua_Integer cursor_type = luaL_checkinteger(L, 3);
	lua_Integer arg_num = lua_gettop(L) - arg_start + 1;
	if (arg_num != param_count) {
		return luaL_error(L, "require param_count: %d get arg_num: %d",
				  param_count, arg_num);
	}
	luaL_buffinit(L, &b);
	// header
	luaL_addchar(&b, COM_STMT_EXECUTE);
	luaL_addint4(&b, prepare_id);
	luaL_addchar(&b, cursor_type);
	luaL_addint4(&b, 0x01);
	if (arg_num > 0) {
		add_params(&b, arg_start, arg_num);
	}
	luaL_pushresult(&b);
	return 1;
}

int luaopen_core_db_mysql_c(lua_State *L)
{
	luaL_Reg tbl[] = {
		{ "parse_lenenc",              lparse_lenenc              },
		{ "parse_ok_packet",           lparse_ok_packet           },
		{ "parse_eof_packet",          lparse_eof_packet          },
		{ "parse_local_infile_packet", lparse_local_infile_packet },
		{ "parse_err_packet",          lparse_err_packet          },
		{ "parse_column_def",          lparse_column_def          },
		{ "parse_row_data_binary",     lparse_row_data_binary     },
		{ "compose_stmt_execute",      lcompose_stmt_execute      },
		{ NULL,			NULL                       },
	};
	luaL_newlibtable(L, tbl);
	// all functions upvalue
	lua_pushliteral(L, "OK");
	lua_pushliteral(L, "ERR");
	lua_pushliteral(L, "EOF");
	lua_pushliteral(L, "LOCAL_INFILE");
	lua_pushliteral(L, "type");
	lua_pushliteral(L, "affected_rows");
	lua_pushliteral(L, "last_insert_id");
	lua_pushliteral(L, "server_status");
	lua_pushliteral(L, "warning_count");
	lua_pushliteral(L, "message");
	lua_pushliteral(L, "errno");
	lua_pushliteral(L, "stage");
	lua_pushliteral(L, "max_stage");
	lua_pushliteral(L, "progress");
	lua_pushliteral(L, "progress_info");
	lua_pushliteral(L, "sqlstate");
	lua_pushliteral(L, "filename");
	lua_pushliteral(L, "status_flags");
	luaL_setfuncs(L, tbl, UPVAL_MAX - 1);
	return 1;
}
