#include <assert.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <lua.h>
#include <lauxlib.h>

#include "silly_malloc.h"
#include "silly_message.h"


#define DEFAULT_QUEUE_SIZE      2048
#define INCOMPLETE_HASH_SIZE    2024
#define INCOMPLETE_HASH(a)      (a % INCOMPLETE_HASH_SIZE)

#define min(a, b)               ((a) > (b) ? (b) : (a))

struct packet {
        int fd;
        int size;
        char *buff;
};

struct incomplete {
        int fd;
        int rsize;
        int psize;
        char *buff;
        struct incomplete *prev;
        struct incomplete *next;
};

struct rawpacket {
        struct incomplete       *incomplete_hash[INCOMPLETE_HASH_SIZE];
        int                     cap;                            //default DEFAULT_QUEUE_SIZE
        int                     head;
        int                     tail;
        struct packet           queue[DEFAULT_QUEUE_SIZE];      //for more effective gc
};

static int
_create_rawpacket(lua_State *L)
{
        struct rawpacket *r = lua_newuserdata(L, sizeof(struct rawpacket));
        memset(r, 0, sizeof(*r));

        r->cap = DEFAULT_QUEUE_SIZE;

        luaL_getmetatable(L, "rawpacket");
        lua_setmetatable(L, -2);

        return 1;
}

static struct incomplete *
_get_incomplete(struct rawpacket *p, int fd)
{
        struct incomplete *i;

        i = p->incomplete_hash[INCOMPLETE_HASH(fd)];
        
        while (i) {
                if (i->fd == fd) {
                        if (i->prev == NULL)
                                p->incomplete_hash[INCOMPLETE_HASH(fd)] = i->next;
                        else
                                i->prev->next = i->next;
                                                                          
                        return i;
                }
                i = i->next;
        }

        return NULL;
}

static void
_put_incomplete(struct rawpacket *p, struct incomplete *ic)
{
        struct incomplete *i;
        i = p->incomplete_hash[INCOMPLETE_HASH(ic->fd)];
        
        ic->next = i;
        ic->prev = NULL;
        i = ic;
}

static void
_push_one_complete(struct rawpacket *p, struct incomplete *ic)
{
        struct packet *pk;
        int h = p->head;
        p->head = (p->head + 1) % p->cap;

        pk = &p->queue[h];
        pk->fd = ic->fd;
        assert(ic->psize == ic->rsize);
        pk->size = ic->psize;
        pk->buff = ic->buff;

        assert(p->head < p->cap);
        assert(p->tail < p->cap);
        if (p->head == p->tail) {
                fprintf(stderr, "packet queue full\n");
                assert(!"queue full\n");
        }


        return ;
}

static int
_push_raw_once(struct rawpacket *p, int fd, int size, const char *buff)
{
        int eat;
        struct incomplete *ic = _get_incomplete(p, fd);
        if (ic) {       //continue it
                if (ic->rsize >= 0) {   //have already alloc memory
                        assert(ic->buff);
                        eat = min(ic->psize - ic->rsize, size);
                        memcpy(&ic->buff[ic->rsize], buff, eat);
                        ic->rsize += eat;
                } else {                //have no enough psize info
                        assert(ic->rsize == -1);
                        ic->psize |= *buff;
                        ++buff;
                        --size;
                        ++ic->rsize;
                        
                        assert(ic->rsize == 0);

                        eat = min(ic->psize - ic->rsize, size);
                        memcpy(&ic->buff[ic->rsize], buff, eat);
                        ic->rsize += eat;
                        eat += 1;               //for the length header
                }
        } else {        //new incomplete
                ic = silly_malloc(sizeof(*ic));
                ic->fd = fd;
                ic->buff = NULL;
                ic->psize = 0;
                ic->rsize = -2;
                
                if (size >= 2) {
                        ic->psize = (*buff << 8) | *(buff + 1);
                        ic->rsize = min(ic->psize, size - 2);
                        ic->buff = silly_malloc(ic->psize);
                        eat = ic->rsize + 2;
                        memcpy(ic->buff, buff + 2, ic->rsize);
                } else {
                        assert(size == 1);
                        ic->psize |= *buff << 8;
                        ic->rsize = -1;
                        eat = 1;
                }
        }


        if (ic->rsize == ic->psize) {
                _push_one_complete(p, ic);
                silly_free(ic);
        } else {
                assert(ic->rsize < ic->psize);
                _put_incomplete(p, ic);
        }


        return eat;
}

static void
_push_rawdata(struct rawpacket *p, struct silly_message_socket *s)
{
        int n;
        int left;
        char *d;
        assert(s->type == SILLY_SOCKET_DATA);

        left = s->data_size;
        d = s->data;

        do {
                n = _push_raw_once(p, s->sid, left, d);
                left -= n;
                d += n;

        } while (left);

        return ;
}

static int
_push_rawpacket(lua_State *L)
{
        struct rawpacket                *p;
        struct silly_message_socket     *s;
        
        p = luaL_checkudata(L, 1, "rawpacket");
        s = luaL_checkudata(L, 2, "silly_message_socket");

        if (s->type == SILLY_SOCKET_DATA)
                _push_rawdata(p, s);
        else
                assert(s->data == NULL);

        lua_pushinteger(L, s->sid);
        lua_pushinteger(L, s->type);

        return 2;
}

static int
_pop_packet(lua_State *L)
{
        int t;
        struct packet *pk;
        struct rawpacket *p;
        p = luaL_checkudata(L, 1, "rawpacket");

        assert(p->head < p->cap);
        assert(p->tail < p->cap);
 
        if (p->tail == p->head) {       //empty
                lua_pushnil(L);
                lua_pushnil(L);
        } else {
                t = p->tail;
                p->tail = (p->tail + 1) % p->cap;
                pk = &p->queue[t];
                lua_pushinteger(L, pk->fd);
        
                //TODO:when implete the cryption module, will use the lua_pushlightuserdata funciton,
                //the lua_pushlstring function will be called by cryption module

                lua_pushlstring(L, pk->buff, pk->size);
                silly_free(pk->buff);
        }

        return 2;
}


int luaopen_rawpacket(lua_State *L)
{
        luaL_Reg tbl[] = {
                {"create", _create_rawpacket},
                {"push", _push_rawpacket},
                {"pop", _pop_packet},
                {NULL, NULL},
        };
 
        luaL_checkversion(L);

        luaL_newmetatable(L, "rawpacket");

        luaL_newlibtable(L, tbl);
        luaL_setfuncs(L, tbl, 0);
        
        return 1;
}
