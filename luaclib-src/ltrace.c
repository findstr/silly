#include <unistd.h>
#include <assert.h>
#include <errno.h>
#include <signal.h>
#include <stdlib.h>
#include <stdio.h>
#include <stddef.h>
#include <string.h>
#include <sys/time.h>
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>

#include "silly.h"

static int lsetnode(lua_State *L)
{
	silly_tracenode_t span;
	span = (silly_tracenode_t)luaL_checkinteger(L, 1);
	silly_trace_set_node(span);
	return 0;
}

static int lspawn(lua_State *L)
{
	silly_traceid_t oid, nid;
	nid = silly_trace_new();
	oid = silly_trace_exchange(nid);
	lua_pushinteger(L, (lua_Integer)nid);
	lua_pushinteger(L, (lua_Integer)oid);
	return 2;
}

static int lattach(lua_State *L)
{
	silly_traceid_t traceid;
	traceid = (silly_traceid_t)luaL_optinteger(L, 1, 0);
	traceid = silly_trace_exchange(traceid);
	lua_pushinteger(L, (lua_Integer)traceid);
	return 1;
}

/*
** Resumes a coroutine. Returns the number of results for non-error
** cases or -1 for errors.
*/
static int auxresume (lua_State *L, lua_State *co, int narg) {
	int status, nres;
	if (unlikely(!lua_checkstack(co, narg))) {
		lua_pushboolean(L, 0);
		lua_pushliteral(L, "too many arguments to resume");
		return 2;  /* error flag */
	}
	lua_xmove(L, co, narg);
	status = lua_resume(co, L, narg, &nres);
	if (likely(status == LUA_OK || status == LUA_YIELD)) {
		if (unlikely(!lua_checkstack(L, nres + 1))) {
			lua_pop(co, nres);	/* remove results anyway */
			lua_pushboolean(L, 0);
			lua_pushliteral(L, "too many results to resume");
			return 2;	/* error flag */
		}
		lua_pushboolean(L, 1);
		lua_xmove(co, L, nres);	/* move yielded values */
		return nres+1;
	} else {
		lua_pushboolean(L, 0);
		lua_xmove(co, L, 1);	/* move error message */
		return 2;	/* error flag */
	}
}

// lresume(co, traceid, ...)
static int lresume(lua_State *L)
{
	int r, top;
	lua_State *co;
	silly_traceid_t traceid, otraceid;
	top = lua_gettop(L);
	luaL_argcheck(L, top >= 2, 2, "at least two arguments expected");
	co = lua_tothread(L, 1);
	luaL_argexpected(L, co, 1, "thread");
	traceid = (silly_traceid_t)lua_tointeger(L, 2);
	otraceid = silly_trace_exchange(traceid);
	silly_resume(co);
	r = auxresume(L, co, top - 2);
	silly_resume(L);
	silly_trace_exchange(otraceid);
	return r;
}

SILLY_MOD_API int luaopen_silly_trace_c(lua_State *L)
{
	luaL_Reg tbl[] = {
		{ "setnode", lsetnode  },
		{ "spawn",   lspawn    },
		{ "attach",  lattach   },
		{ "resume",  lresume   },
		//end
		{ NULL,         NULL   },
	};
	luaL_checkversion(L);
	luaL_newlib(L, tbl);
	return 1;
}