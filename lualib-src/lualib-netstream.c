#include <assert.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <lua.h>
#include <lauxlib.h>

#include "silly_malloc.h"
#include "silly_message.h"

#define min(a, b)       ((a) < (b) ? (a) : (b))

#define POOL            1
#define NB              2
#define MESSAGE         3

#define POOL_CHUNK              32
#define POOL_CHUNK_LIMIT        512 

struct node {
        int start;
        int size;
        char *buff;
        struct node *next;
};

struct node_buffer {
        int sid;
        int size;
        struct node *head;
        struct node *tail;
};

static int
free_pool(struct lua_State *L)
{
        int i;
        struct node *n = (struct node *)luaL_checkudata(L, 1, "nodepool");
        int sz = lua_rawlen(L, 1);
        assert(sz % sizeof(struct node) == 0);
        sz /= sizeof(struct node);

        for (i = 0; i < sz; i++) {
                if (n[i].buff)
                        silly_free(n[i].buff);
        }

        return 0;
}

static struct node *
new_pool(struct lua_State *L, int n)
{
        int i;
        struct node *free = (struct node *)lua_newuserdata(L, sizeof(struct node) * n);
        memset(free, 0, sizeof(struct node) * n);
        for (i = 0; i < n - 1; i++)
                free[i].next = &free[i + 1];
        free[i].next = NULL;

        if (luaL_newmetatable(L, "nodepool")) {
                lua_pushcfunction(L, free_pool);
                lua_setfield(L, -2, "__gc");
        }

        lua_setmetatable(L, -2);

        return free;
}

static struct node *
new_node(struct lua_State *L)
{
        lua_rawgeti(L, POOL, 1);
        struct node *free;
        if (lua_isnil(L, -1)) {
                int sz;
                int n = lua_rawlen(L, POOL);
                if (n == 0)
                        n = 1;

                sz = POOL_CHUNK << n;
                if (sz > POOL_CHUNK_LIMIT)
                        sz = POOL_CHUNK_LIMIT;

                struct node *new = new_pool(L, sz);
                lua_rawseti(L, POOL, n + 1);
                free = new;
        } else {
                free = (struct node *)lua_touserdata(L, -1);
        }
        lua_pushlightuserdata(L, free->next);
        lua_rawseti(L, POOL, 1);
        return free;
}


static void
append_node(struct node_buffer *nb, struct node *n)
{
        n->next = NULL;
        if (nb->head == NULL)
                nb->head = n;
        if (nb->tail == NULL) {
                nb->tail = n;
        } else {
                nb->tail->next = n;
                nb->tail = n;
        }

        nb->size += n->size;

        return ;
}

static void
remove_node(lua_State *L, struct node_buffer *nb, struct node *n)
{
        assert(n == nb->head);
        assert(nb->tail);
        nb->head = nb->head->next;
        if (nb->head == NULL)
                nb->tail = NULL;

        assert(n->buff);
        silly_free(n->buff);
        n->buff = NULL;

        lua_rawgeti(L, POOL, 1);
        struct node *free = lua_touserdata(L, -1);
        if (free == NULL) {
                lua_pushlightuserdata(L, n);
                lua_rawseti(L, POOL, 1);
        } else {
                n->next = free->next;
                free->next = n;
        }
        lua_pop(L, 1);

        return ;
}


//@input
//      pool, node, silly_message_socket
//@return
//      node buffer

static int
push(struct lua_State *L, int sid, char *data, int sz)
{
        struct node_buffer *nb;
        struct node *new = new_node(L);
        new->start = 0;
        new->size = sz;
        new->buff = data;

        if (lua_isnil(L, NB)) {
                nb = (struct node_buffer *)lua_newuserdata(L, sizeof(struct node_buffer));
                nb->sid = sid;
                nb->size = 0;
                nb->head = NULL;
                nb->tail = NULL;
                luaL_newmetatable(L, "nodebuffer");
                lua_setmetatable(L, -2);
        } else {
                nb = (struct node_buffer *)luaL_checkudata(L, NB, "nodebuffer");
                assert(nb->sid == sid);
                lua_pushvalue(L, NB);
        }

        append_node(nb, new);
 
        lua_replace(L, 1);
        lua_settop(L, 1);

        return 1;
}

static int
pushstring(struct lua_State *L, struct node_buffer *nb, int sz)
{
        struct node *n = nb->head;
        if (n->size >= sz) {
                char *s = &n->buff[n->start];
                lua_pushlstring(L, s, sz);
                n->start += sz;
                n->size -= sz; 
                if (n->size == 0)
                        remove_node(L, nb, n);



        } else {
                char *buff = (char *)silly_malloc(sz);
                char *p = buff;
                while (sz) {
                        int tmp;
                        tmp = min(sz, n->size);

                        memcpy(p, &n->buff[n->start], tmp);
                        p += tmp;
                        n->start += tmp;
                        n->size -= tmp;

                        if (n->size == 0) {
                                remove_node(L, nb, n);
                                n = nb->head;
                        }
                        
                        sz -= tmp;
                }
                assert(sz == 0);
                lua_pushlstring(L, buff, p - buff);
                silly_free(buff);
        }

        lua_replace(L, 1);
        lua_settop(L, 1);

        return 1;
}

static int 
compare(struct node *n, int start, int sz, const char *delim, int delim_len)
{
        while (delim_len > 0) {
                if (sz >= delim_len) {
                        return memcmp(&n->buff[start], delim, delim_len);
                } else if (memcmp(&n->buff[start], delim, sz) != 0) {
                        return -1;
                } else if (n->next == NULL) {
                        return -1;
                } else {
                        assert(delim_len > sz);
                        delim_len -= sz;
                        delim += sz;
                        n = n->next;
                        sz = n->size;
                        start = 0;
                }
        }

        return -1;
}

static int
checkdelim(struct node_buffer *nb, const char *delim, int delim_len)
{
        int ret = -1;
        int nr = 0;
        struct node *n;

        for (n = nb->head; n; n = n->next) {
                int i;
                int start = n->start;
                int sz = n->size;
                for (i = 0; i < n->size; i++) {
                        int e = compare(n, start, sz, delim, delim_len);
                        if (e == 0)     //return value from memcmp
                                break;

                        nr += 1;
                        sz -= 1;
                        start += 1;
                        continue;
                }

                if (i >= n->size)
                        continue;
                
                nr += delim_len;
                ret = nr;
                break;
        }

        return ret;
}

//@input
//      pool
//      node buffer

static int
lclear(struct lua_State *L)
{
        if (lua_isnil(L, 2))
                return 0;

        struct node_buffer *nb = (struct node_buffer *)luaL_checkudata(L, 2, "nodebuffer");
        nb->size = 0;
        while (nb->head) {
                remove_node(L, nb, nb->head);
        }

        return 0;
}

static int
lcheck(struct lua_State *L)
{
        if (lua_isnil(L, 2)) {
                lua_pushboolean(L, 0);
                return 1;
        }

        struct node_buffer *nb = (struct node_buffer *)luaL_checkudata(L, 1, "nodebuffer");
        assert(nb);
        int readn = luaL_checkinteger(L, 2);
        lua_pushboolean(L, readn <= nb->size);
        return 1;
}

//@input
//      pool
//      node buffer
//      read byte count
//@return
//      string or nil
static int
lread(struct lua_State *L)
{
        if (lua_isnil(L, 2)) {
                lua_pushnil(L);
                return 1;
        }

        struct node_buffer *nb = (struct node_buffer *)luaL_checkudata(L, 2, "nodebuffer");
        assert(nb);
        int readn = luaL_checkinteger(L, 3);
        if (readn > nb->size) {
                lua_pushnil(L);
                return 1;
        }
        
        nb->size -= readn;
        return pushstring(L, nb, readn);
}

static int
lcheckline(struct lua_State *L)
{
        if (lua_isnil(L, 2)) {
                lua_pushboolean(L, 0);
                return 1;
        }

        struct node_buffer *nb = (struct node_buffer *)luaL_checkudata(L, 1, "nodebuffer");
        assert(nb);
        size_t delim_len;
        const char *delim = lua_tolstring(L, 2, &delim_len);
        int readn = checkdelim(nb, delim, delim_len);
        lua_pushboolean(L, readn != -1 && readn <= nb->size);
        return 1;
}

//@input
//      pool
//      node buffer
//      read delim
//@return
//      string or nil
static int
lreadline(struct lua_State *L)
{
        if (lua_isnil(L, 2)) {
                lua_pushnil(L);
                return 1;
        }

        struct node_buffer *nb = luaL_checkudata(L, 2, "nodebuffer");
        size_t delim_len;
        const char *delim = lua_tolstring(L, 3, &delim_len);
        int readn = checkdelim(nb, delim, delim_len);
        if (readn == -1 || readn > nb->size) {
                lua_pushnil(L);
                return 1;
        }

        nb->size -= readn;

        return pushstring(L, nb, readn);
}

static int
lpack(struct lua_State *L)
{
        const char *str;
        size_t size;
        char *p;

        str = luaL_checklstring(L, 1, &size);
        assert(size < (unsigned short)-1);

        p = silly_malloc(size);
        memcpy(p, str, size);

        lua_pushlightuserdata(L, p);
        lua_pushinteger(L, size);
        
        return 2;
}

static int
lpush(lua_State *L)
{
        struct silly_message *msg = lua_touserdata(L, 3);
        struct silly_message_socket *sm = (struct silly_message_socket *)(msg + 1);
        enum silly_message_type mt = msg->type;

        switch (mt) {
        case SILLY_SOCKET_DATA:
                return push(L, sm->sid, (char *)sm->data, sm->data_size);
        case SILLY_SOCKET_ACCEPT:
        case SILLY_SOCKET_CLOSE:
        case SILLY_SOCKET_CONNECTED:
        default:
                assert(!"never come here");
                fprintf(stderr, "lmessage unspport:%d\n", mt);
                return 1;
        }
}

static int
tpush(lua_State *L)
{
        int fd = luaL_checkinteger(L, 3);
        char *ud = lua_touserdata(L, 4);
        int sz = luaL_checkinteger(L, 5);
        return push(L, fd, ud, sz);
}

int luaopen_netstream(lua_State *L)
{
        luaL_Reg tbl[] = {
                {"push",        lpush},
                {"tpush",       tpush},
                {"clear",       lclear},
                {"read",        lread},
                {"readline",    lreadline},
                {"check",       lcheck},
                {"checkline",   lcheckline},
                {"pack",        lpack},
                {NULL, NULL},
        };
 
        luaL_checkversion(L);

        luaL_newlibtable(L, tbl);
        luaL_setfuncs(L, tbl, 0);
        
        return 1;
}
