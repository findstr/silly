#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>
#include <string.h>
#include <assert.h>

static const int HOOKKEY = 0;

static inline void
checkstack(lua_State *L, lua_State *L1, int n)
{
	if (L != L1 && !lua_checkstack(L1, n))
		luaL_error(L, "stack overflow");
}

static void
hookf(lua_State *L, lua_Debug *ar)
{
	static const char *const hooknames[] =
		{"call", "return", "line", "count", "tail call"};
	lua_rawgetp(L, LUA_REGISTRYINDEX, &HOOKKEY);
	lua_pushthread(L);
	if (lua_rawget(L, -2) == LUA_TFUNCTION) {  /* is there a hook function? */
		lua_pushstring(L, hooknames[(int)ar->event]);  /* push event name */
		if (ar->currentline >= 0)
			lua_pushinteger(L, ar->currentline);	/* push current line */
		else lua_pushnil(L);
		lua_assert(lua_getinfo(L, "lS", ar));
		lua_call(L, 2, 1);
		if (!lua_isnil(L, -1)) {
			lua_pop(L, 1);
			lua_yield(L, 0);
		}
	}
}

static lua_State *
getthread(lua_State *L, int *arg)
{
	if (lua_isthread(L, 1)) {
		*arg = 1;
		return lua_tothread(L, 1);
	}
	else {
		*arg = 0;
		return L;  /* function will operate over current thread */
	}
}

static int
makemask(const char *smask, int count)
{
	int mask = 0;
	if (strchr(smask, 'c')) mask |= LUA_MASKCALL;
	if (strchr(smask, 'r')) mask |= LUA_MASKRET;
	if (strchr(smask, 'l')) mask |= LUA_MASKLINE;
	if (count > 0) mask |= LUA_MASKCOUNT;
	return mask;
}

static int
lhook(lua_State *L)
{
	int arg, mask, count;
	lua_Hook func;
	lua_State *L1 = getthread(L, &arg);
	if (lua_isnoneornil(L, arg+1)) {	/* no hook? */
		lua_settop(L, arg+1);
		func = NULL; mask = 0; count = 0;  /* turn off hooks */
	}
	else {
		const char *smask = luaL_checkstring(L, arg+2);
		luaL_checktype(L, arg+1, LUA_TFUNCTION);
		count = (int)luaL_optinteger(L, arg + 3, 0);
		func = hookf; mask = makemask(smask, count);
	}
	if (lua_rawgetp(L, LUA_REGISTRYINDEX, &HOOKKEY) == LUA_TNIL) {
		lua_createtable(L, 0, 2);  /* create a hook table */
		lua_pushvalue(L, -1);
		lua_rawsetp(L, LUA_REGISTRYINDEX, &HOOKKEY);	/* set it in position */
		lua_pushstring(L, "k");
		lua_setfield(L, -2, "__mode");	/** hooktable.__mode = "k" */
		lua_pushvalue(L, -1);
		lua_setmetatable(L, -2);	/* setmetatable(hooktable) = hooktable */
	}
	checkstack(L, L1, 1);
	lua_pushthread(L1); lua_xmove(L1, L, 1);	/* key (thread) */
	lua_pushvalue(L, arg + 1);	/* value (hook function) */
	lua_rawset(L, -3);	/* hooktable[L1] = new Lua hook */
	lua_sethook(L1, func, mask, count);
	return 0;
}

int
luaopen_sys_debugger_helper(lua_State *L)
{
	luaL_Reg tbl[] = {
		{"hook", lhook},
		{NULL, NULL},
	};
	luaL_checkversion(L);
	luaL_newlibtable(L, tbl);
	luaL_setfuncs(L, tbl, 0);
	return 1;
}

