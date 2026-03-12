#ifndef _LUABUF_H
#define _LUABUF_H

#include <string.h>
#include <lua.h>
#include <lauxlib.h>
#include "silly.h"

#define CBUF_INLINE_SIZE LUAL_BUFFERSIZE
#include "cbuf.h"

/* Lua-aware buffer wrapping cbuf, adding:
 * - lua_State for error reporting
 * - zero-copy result push to Lua
 */
struct luabuf {
	struct cbuf cb;
	lua_State *L;
};

static inline void luabuf_init(struct luabuf *lb, lua_State *L)
{
	lb->L = L;
	cbuf_init(&lb->cb);
}

static inline void luabuf_free(struct luabuf *lb)
{
	cbuf_free(&lb->cb);
}

static inline void luabuf_grow(struct luabuf *lb, size_t need)
{
	cbuf_ensure(&lb->cb, need);
}

static inline void luabuf_addchar(struct luabuf *lb, char ch)
{
	cbuf_addchar(&lb->cb, ch);
}

static inline void luabuf_backspace(struct luabuf *lb, size_t n)
{
	cbuf_pop(&lb->cb, n);
}

static inline void luabuf_addlstring(struct luabuf *lb, const char *s, size_t n)
{
	cbuf_addlstr(&lb->cb, s, n);
}

static void *luabuf_falloc(void *ud, void *ptr, size_t osize, size_t nsize)
{
	(void)ud;
	(void)osize;
	if (nsize == 0) {
		silly_free(ptr);
		return NULL;
	}
	return silly_realloc(ptr, nsize);
}

/* Push result onto Lua stack; uses zero-copy for heap buffers */
static inline void luabuf_pushresult(struct luabuf *lb)
{
	if (lb->cb.data == CBUF_INLINE_BUF(&lb->cb)) {
		/* Small buffer: copy into Lua string */
		lua_pushlstring(lb->L, lb->cb.data, lb->cb.len);
	} else {
		/* Heap buffer: null-terminate and transfer ownership */
		cbuf_addchar(&lb->cb, '\0');
		cbuf_pop(&lb->cb, 1); /* remove null terminator from length */
		lua_pushexternalstring(lb->L, lb->cb.data, lb->cb.len,
				       luabuf_falloc, NULL);
		lb->cb.data = NULL; /* Lua owns it now */
	}
}

#endif
