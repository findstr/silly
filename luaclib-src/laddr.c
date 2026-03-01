#include <string.h>
#include <lua.h>
#include <lauxlib.h>

#include "silly.h"
#include "platform.h"

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

/* Returns 4 for IPv4, 6 for IPv6, 0 for anything else. */
static int
c_iptype(const char *host)
{
	struct in_addr addr4;
	struct in6_addr addr6;
	if (inet_pton(AF_INET, host, &addr4) == 1)
		return 4;
	if (inet_pton(AF_INET6, host, &addr6) == 1)
		return 6;
	return 0;
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

/* iptype(s) -> 4 | 6 | 0
 * Returns the IP address family of s, or 0 if s is not a valid IP literal. */
static int
liptype(lua_State *L)
{
	const char *host = luaL_checkstring(L, 1);
	lua_pushinteger(L, c_iptype(host));
	return 1;
}

static int
lisv4(lua_State *L)
{
	const char *host = luaL_checkstring(L, 1);
	lua_pushboolean(L, c_iptype(host) == 4);
	return 1;
}

static int
lisv6(lua_State *L)
{
	const char *host = luaL_checkstring(L, 1);
	lua_pushboolean(L, c_iptype(host) == 6);
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
	lua_pushboolean(L, c_iptype(host) == 0);
	return 1;
}

SILLY_MOD_API int
luaopen_silly_net_addr(lua_State *L)
{
	luaL_Reg tbl[] = {
		{"parse",  lparse  },
		{"join",   ljoin   },
		{"iptype", liptype },
		{"isv4",   lisv4   },
		{"isv6",   lisv6   },
		{"ishost", lishost },
		{NULL,     NULL    },
	};
	luaL_checkversion(L);
	luaL_newlib(L, tbl);
	return 1;
}
