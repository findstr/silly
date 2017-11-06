#include <stdlib.h>
#include <string.h>
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>

#include "silly.h"

static int
lmsggc(lua_State *L)
{
	struct silly_message_socket *sm;
	sm = tosocket(luaL_checkudata(L, 1, "sillymessage"));
	int type = sm->type;
	if (type == SILLY_SDATA || type == SILLY_SUDP)
		silly_free(tosocket(sm)->data);
	return 0;
}

static struct silly_message *
newmsg(lua_State *L, size_t sz)
{
	struct silly_message *sm = lua_newuserdata(L, sz);
	if (luaL_newmetatable(L, "sillymessage")) {
		lua_pushcfunction(L, lmsggc);
		lua_setfield(L, -2, "__gc");
	}
	lua_setmetatable(L, -2);
	return sm;
}

static int
lnewdatamsg(lua_State *L)
{
	size_t sz;
	struct silly_message_socket *sm;
	int sid = luaL_checkinteger(L, 1);
	const char *buff = luaL_checklstring(L, 2, &sz);
	sm = tosocket(newmsg(L, sizeof(*sm)));
	sm->type = SILLY_SDATA;
	sm->sid = sid;
	sm->ud = sz;
	sm->data= silly_malloc(sz);
	memcpy(sm->data, buff, sz);
	return 1;
};

int
luaopen_test_aux_c(lua_State *L)
{
	luaL_Reg tbl[] = {
		{"newdatamsg", lnewdatamsg},
		{NULL, NULL},
	};

	luaL_checkversion(L);
	luaL_newlibtable(L, tbl);
	luaL_setfuncs(L, tbl, 0);
	return 1;
}

