#include <string.h>
#include <lua.h>
#include <lauxlib.h>

#include "silly.h"

static inline int
is_port_char(unsigned char c)
{
	if (c == '_')
		return 1;
	if (c >= '0' && c <= '9')
		return 1;
	if (c >= 'A' && c <= 'Z')
		return 1;
	if (c >= 'a' && c <= 'z')
		return 1;
	return 0;
}

static int
port_match(const char *s, size_t len)
{
	if (len == 0)
		return 0;
	for (size_t i = 0; i < len; i++) {
		if (!is_port_char((unsigned char)s[i]))
			return 0;
	}
	return 1;
}

static int
ipv4_pattern_match(const char *s, size_t len)
{
	size_t i = 0;
	for (int part = 0; part < 4; part++) {
		size_t begin = i;
		while (i < len && s[i] >= '0' && s[i] <= '9') {
			i++;
		}
		if (i == begin)
			return 0;
		if (part != 3) {
			if (i >= len || s[i] != '.')
				return 0;
			i++;
		}
	}
	return i == len;
}

static int
lparse(lua_State *L)
{
	size_t len = 0;
	const char *addr = luaL_checklstring(L, 1, &len);
	if (len > 0 && addr[0] == '[') {
		size_t close = 1;
		while (close < len && addr[close] != ']') {
			close++;
		}
		if (close < len) {
			size_t hostlen = close - 1;
			if (close == len - 1) {
				if (hostlen == 0)
					lua_pushnil(L);
				else
					lua_pushlstring(L, addr + 1, hostlen);
				lua_pushnil(L);
				return 2;
			}
			if (addr[close + 1] == ':') {
				size_t port_off = close + 2;
				size_t port_len = len - port_off;
				if (port_match(addr + port_off, port_len)) {
					if (hostlen == 0)
						lua_pushnil(L);
					else
						lua_pushlstring(L, addr + 1, hostlen);
					lua_pushlstring(L, addr + port_off, port_len);
					return 2;
				}
			}
		}
		lua_pushnil(L);
		lua_pushnil(L);
		return 2;
	}

	if (len > 0) {
		for (size_t i = len; i > 0; i--) {
			size_t colon = i - 1;
			if (addr[colon] != ':')
				continue;
			size_t port_off = colon + 1;
			size_t port_len = len - port_off;
			if (!port_match(addr + port_off, port_len))
				break;
			if (colon == 0)
				lua_pushnil(L);
			else
				lua_pushlstring(L, addr, colon);
			lua_pushlstring(L, addr + port_off, port_len);
			return 2;
		}
		lua_pushlstring(L, addr, len);
		lua_pushnil(L);
		return 2;
	}

	lua_pushnil(L);
	lua_pushnil(L);
	return 2;
}

static int
ljoin(lua_State *L)
{
	luaL_Buffer b;
	size_t hostlen = 0;
	size_t portlen = 0;
	const char *host = luaL_optlstring(L, 1, NULL, &hostlen);
	const char *port = luaL_checklstring(L, 2, &portlen);

	luaL_buffinit(L, &b);
	if (host == NULL || hostlen == 0) {
		luaL_addchar(&b, ':');
		luaL_addlstring(&b, port, portlen);
		luaL_pushresult(&b);
		return 1;
	}
	if (host[0] != '[' && memchr(host, ':', hostlen) != NULL) {
		luaL_addchar(&b, '[');
		luaL_addlstring(&b, host, hostlen);
		luaL_addlstring(&b, "]:", 2);
		luaL_addlstring(&b, port, portlen);
		luaL_pushresult(&b);
		return 1;
	}
	luaL_addlstring(&b, host, hostlen);
	luaL_addchar(&b, ':');
	luaL_addlstring(&b, port, portlen);
	luaL_pushresult(&b);
	return 1;
}

static int
lisv4(lua_State *L)
{
	size_t len = 0;
	const char *host = luaL_checklstring(L, 1, &len);
	lua_pushboolean(L, ipv4_pattern_match(host, len));
	return 1;
}

static int
lisv6(lua_State *L)
{
	size_t len = 0;
	const char *host = luaL_checklstring(L, 1, &len);
	lua_pushboolean(L, memchr(host, ':', len) != NULL);
	return 1;
}

static int
lishost(lua_State *L)
{
	size_t len = 0;
	const char *host = luaL_checklstring(L, 1, &len);
	if (len == 0) {
		lua_pushboolean(L, 0);
		return 1;
	}
	if (memchr(host, ':', len) != NULL) {
		lua_pushboolean(L, 0);
		return 1;
	}
	lua_pushboolean(L, !ipv4_pattern_match(host, len));
	return 1;
}

SILLY_MOD_API int
luaopen_silly_net_addr(lua_State *L)
{
	luaL_Reg tbl[] = {
		{"parse",  lparse },
		{"join",   ljoin  },
		{"isv4",   lisv4  },
		{"isv6",   lisv6  },
		{"ishost", lishost},
		{NULL,     NULL   },
	};
	luaL_checkversion(L);
	luaL_newlib(L, tbl);
	return 1;
}
