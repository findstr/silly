#include <string.h>
#ifdef __WIN32
#include <ws2tcpip.h>
#else
#include <arpa/inet.h>
#endif
#include <lua.h>
#include <lauxlib.h>

#include "silly.h"
#include "luastr.h"

/* Parse address string into host and port components.
 * Returns 0 on success, -1 on malformed input.
 * If port not found, port is set to NULL/0.
 */
static inline int split_addr(struct luastr *addr, struct luastr *host, struct luastr *port)
{
	if (addr->len == 0) {
		return -1;
	}
	const uint8_t *ps;
	const uint8_t *se = addr->str + addr->len;
	if (addr->str[0] == '[') {  // IPv6 or [host]:port format
		const uint8_t *p = memchr(addr->str, ']', addr->len);
		if (p == NULL) {
			return -1;  // unmatched '['
		}
		if (p + 1 < se && p[1] != ':') {
			return -1;  // ']' not followed by ':'
		}
		host->str = (const uint8_t *)(addr->str + 1);
		host->len = (int)(p - addr->str - 1);
		ps = p + 2;
	} else {
		const uint8_t *p = memchr(addr->str, ':', addr->len);
		if (p == NULL) {
			// No ':', entire string is host
			host->str = addr->str;
			host->len = (int)addr->len;
			ps = se;
		} else {
			// host:port format
			host->str = addr->str;
			host->len = (int)(p - addr->str);
			ps = p + 1;
		}
	}
	if (ps < se) {
		port->str = ps;
		port->len = (int)(se - ps);
	} else {
		port->str = NULL;
		port->len = 0;
	}
	return 0;
}

/* Returns 4 for IPv4, 6 for IPv6, 0 for anything else. */
static int iptype(const char *host)
{
	struct in_addr addr4;
	struct in6_addr addr6;
	if (inet_pton(AF_INET, host, &addr4) == 1)
		return 4;
	if (inet_pton(AF_INET6, host, &addr6) == 1)
		return 6;
	return 0;
}

static int lparse(lua_State *L)
{
	struct luastr addr, host, port;
	luastr_check(L, 1, &addr);
	if (split_addr(&addr, &host, &port) < 0) {
		lua_pushnil(L);
		lua_pushnil(L);
		return 2;
	}
	// Push host - use original Lua value if it's unchanged (optimization)
	if (host.str == addr.str && host.len == addr.len)
		lua_pushvalue(L, 1);
	else if (host.len > 0)
		lua_pushlstring(L, (const char *)host.str, host.len);
	else
		lua_pushnil(L);
	// Push port
	if (port.str)
		lua_pushlstring(L, (const char *)port.str, port.len);
	else
		lua_pushnil(L);
	return 2;
}

static int ljoin(lua_State *L)
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
static int liptype(lua_State *L)
{
	const char *host = luaL_checkstring(L, 1);
	lua_pushinteger(L, iptype(host));
	return 1;
}

static int lisv4(lua_State *L)
{
	const char *host = luaL_checkstring(L, 1);
	lua_pushboolean(L, iptype(host) == 4);
	return 1;
}

static int lisv6(lua_State *L)
{
	const char *host = luaL_checkstring(L, 1);
	lua_pushboolean(L, iptype(host) == 6);
	return 1;
}

static int lishost(lua_State *L)
{
	size_t len = 0;
	const char *host = luaL_checklstring(L, 1, &len);
	if (len == 0) {
		lua_pushboolean(L, 0);
		return 1;
	}
	lua_pushboolean(L, iptype(host) == 0);
	return 1;
}

SILLY_MOD_API int luaopen_silly_net_addr(lua_State *L)
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
