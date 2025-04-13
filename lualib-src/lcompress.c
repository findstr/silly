#include <stdlib.h>
#include <string.h>
#include <lua.h>
#include <zlib.h>
#include <lualib.h>
#include <lauxlib.h>

#include "silly.h"

// gzip_compress(data)
static int lgzip_compress(lua_State *L)
{
	int ret;
	size_t size;
	luaL_Buffer buf;
	z_stream stream;
	const char *data = luaL_checklstring(L, 1, &size);
	// init zlib stream
	memset(&stream, 0, sizeof(stream));
	stream.zalloc = Z_NULL;
	stream.zfree = Z_NULL;
	stream.opaque = Z_NULL;
	// init zlib stream as gzip format (windowBits = 15 + 16 for gzip)
	ret = deflateInit2(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15 + 16,
			   8, Z_DEFAULT_STRATEGY);
	if (ret != Z_OK) {
		lua_pushnil(L);
		lua_pushfstring(L, "deflateInit2 failed: %d", ret);
		return 2;
	}
	// set input data
	stream.next_in = (Bytef *)data;
	stream.avail_in = size;
	// prepare output buffer
	luaL_buffinit(L, &buf);
	// compress data
	do {
		char out[LUAL_BUFFERSIZE];
		stream.next_out = (Bytef *)out;
		stream.avail_out = LUAL_BUFFERSIZE;
		ret = deflate(&stream, Z_FINISH);
		if (ret != Z_STREAM_END && ret != Z_OK) {
			deflateEnd(&stream);
			lua_pushnil(L);
			lua_pushfstring(L, "deflate failed: %d", ret);
			return 2;
		}
		luaL_addlstring(&buf, out, LUAL_BUFFERSIZE - stream.avail_out);
	} while (ret != Z_STREAM_END);
	// end compression
	deflateEnd(&stream);
	// return compressed string
	luaL_pushresult(&buf);
	return 1;
}

// gzip_decompress(data)
static int lgzip_decompress(lua_State *L)
{
	int ret;
	size_t size;
	luaL_Buffer buf;
	z_stream stream;
	const char *data = luaL_checklstring(L, 1, &size);
	// init zlib decompression stream
	memset(&stream, 0, sizeof(stream));
	stream.zalloc = Z_NULL;
	stream.zfree = Z_NULL;
	stream.opaque = Z_NULL;
	stream.avail_in = 0;
	stream.next_in = Z_NULL;
	// init zlib decompression stream as gzip format (windowBits = 15 + 16 for gzip)
	ret = inflateInit2(&stream, 15 + 16);
	if (ret != Z_OK) {
		lua_pushnil(L);
		lua_pushfstring(L, "inflateInit2 failed: %d", ret);
		return 2;
	}
	// set input data
	stream.next_in = (Bytef *)data;
	stream.avail_in = size;
	// prepare output buffer
	luaL_buffinit(L, &buf);
	// decompress data
	do {
		char out[LUAL_BUFFERSIZE];
		stream.next_out = (Bytef *)out;
		stream.avail_out = LUAL_BUFFERSIZE;
		ret = inflate(&stream, Z_NO_FLUSH);
		switch (ret) {
		case Z_NEED_DICT:
		case Z_DATA_ERROR:
		case Z_MEM_ERROR:
			inflateEnd(&stream);
			lua_pushnil(L);
			lua_pushfstring(L, "inflate failed: %d", ret);
			return 2;
		}
		luaL_addlstring(&buf, out, LUAL_BUFFERSIZE - stream.avail_out);
	} while (stream.avail_out == 0);
	// end decompression
	inflateEnd(&stream);
	// return decompressed string
	luaL_pushresult(&buf);
	return 1;
}

int luaopen_core_compress_gzip(lua_State *L)
{
	luaL_Reg tbl[] = {
		{ "compress",   lgzip_compress   },
		{ "decompress", lgzip_decompress },
		{ NULL,         NULL             },
	};
	luaL_newlib(L, tbl);
	return 1;
}
