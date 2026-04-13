#include <errno.h>
#include <lua.h>
#include <lauxlib.h>
#include "silly.h"

static int errno_index(lua_State *L)
{
	const char *key = luaL_checkstring(L, 2);
	lua_pushfstring(L, "Unknown error '%s'", key);
	lua_pushvalue(L, 2); /* key */
	lua_pushvalue(L, 3); /* value */
	lua_rawset(L, 1);    /* cache */
	return 1;
}

SILLY_MOD_API int luaopen_silly_errno(lua_State *L)
{
	luaL_checkversion(L);
	lua_newtable(L);
	silly_error_table(L);
	int errtbl = lua_absindex(L, -1);
#define ERR(name, code) \
	silly_push_error(L, errtbl, code); \
	lua_setfield(L, -3, name)
	/* Standard errno */
	ERR("INTR",         EINTR);
	ERR("ACCES",        EACCES);
	ERR("BADF",         EBADF);
	ERR("FAULT",        EFAULT);
	ERR("INVAL",        EINVAL);
	ERR("MFILE",        EMFILE);
	ERR("NFILE",        ENFILE);
	ERR("NOMEM",        ENOMEM);
	ERR("NOBUFS",       ENOBUFS);
	ERR("NOTSOCK",      ENOTSOCK);
	ERR("OPNOTSUPP",    EOPNOTSUPP);
	ERR("AFNOSUPPORT",  EAFNOSUPPORT);
	ERR("PROTONOSUPPORT", EPROTONOSUPPORT);
	ERR("ADDRINUSE",    EADDRINUSE);
	ERR("ADDRNOTAVAIL", EADDRNOTAVAIL);
	ERR("NETDOWN",      ENETDOWN);
	ERR("NETUNREACH",   ENETUNREACH);
	ERR("NETRESET",     ENETRESET);
	ERR("HOSTUNREACH",  EHOSTUNREACH);
	ERR("CONNABORTED",  ECONNABORTED);
	ERR("CONNRESET",    ECONNRESET);
	ERR("CONNREFUSED",  ECONNREFUSED);
	ERR("TIMEDOUT",     ETIMEDOUT);
	ERR("ISCONN",       EISCONN);
	ERR("NOTCONN",      ENOTCONN);
	ERR("INPROGRESS",   EINPROGRESS);
	ERR("ALREADY",      EALREADY);
	ERR("AGAIN",        EAGAIN);
	ERR("WOULDBLOCK",   EWOULDBLOCK);
	ERR("PIPE",         EPIPE);
	ERR("DESTADDRREQ",  EDESTADDRREQ);
	ERR("MSGSIZE",      EMSGSIZE);
	ERR("PROTOTYPE",    EPROTOTYPE);
	ERR("NOPROTOOPT",   ENOPROTOOPT);

	/* Custom EX* errors */
	ERR("RESOLVE",      EXRESOLVE);
	ERR("NOSOCKET",     EXNOSOCKET);
	ERR("CLOSING",      EXCLOSING);
	ERR("CLOSED",       EXCLOSED);
	ERR("EOF",          EXEOF);
	ERR("TLS",        EXTLS);
#undef ERR
	lua_pop(L, 1); /* pop the numeric error table */
	/* Set __index metamethod */
	lua_newtable(L);
	lua_pushcfunction(L, errno_index);
	lua_setfield(L, -2, "__index");
	lua_setmetatable(L, -2);
	return 1;
}
