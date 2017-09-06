#include <stdlib.h>
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>

#ifdef USE_OPENSSL

#include <openssl/bio.h>
#include <openssl/ssl.h>
#include <openssl/err.h>

#include "silly.h"

struct item {
	uint8_t *buff;
	size_t size;
};

struct socketbuff {
	SSL *ssl;
	BIO *bio;
	size_t precap;
	size_t presize;
	char *prebuff;
	int offset;
	size_t datasz;
	size_t popi;
	size_t pushi;
	size_t queuecap;
	struct item queue[1];
};

static int gc(lua_State *L);

static struct socketbuff *
newsocketbuff(lua_State *L, size_t queuesz)
{
	struct socketbuff *sb;
	size_t sz = sizeof(*sb) + sizeof(sb->queue[0]) * (queuesz - 1);
	sb = (struct socketbuff *)lua_newuserdata(L, sz);
	if (luaL_newmetatable(L, "socketbuff")) {
		lua_pushcfunction(L, gc);
		lua_setfield(L, -2, "__gc");
	}
	lua_setmetatable(L, -2);
	memset(sb, 0, sizeof(*sb));
	sb->queuecap = queuesz;
	return sb;
}


static void
expandqueue(lua_State *L, struct socketbuff *sb)
{
	size_t i;
	size_t idx = sb->popi;
	struct socketbuff *newsb;
	size_t queuecap = sb->queuecap * 2;
	newsb = newsocketbuff(L, queuecap);
	newsb->bio = sb->bio;
	newsb->ssl = sb->ssl;
	newsb->precap = sb->precap;
	newsb->presize = sb->presize;
	newsb->prebuff = sb->prebuff;
	newsb->offset = sb->offset;
	newsb->datasz = sb->datasz;
	newsb->pushi = sb->queuecap;
	newsb->popi = 0;
	for (i = 0; i < sb->queuecap; i++) {
		newsb->queue[i] = sb->queue[idx % sb->queuecap];
		++idx;
	}
	memset(sb, 0, sizeof(*sb));
	newsb->bio->ptr = newsb;
	return ;
}

static void
queuepush(lua_State *L, struct socketbuff *sb, uint8_t *buff, size_t sz)
{
	struct item *i = &sb->queue[sb->pushi];
	i->buff = buff;
	i->size = sz;
	sb->datasz += sz;
	sb->pushi = (sb->pushi + 1) % sb->queuecap;
	if (sb->pushi == sb->popi)
		expandqueue(L, sb);
	return ;
}

static inline struct item *
queuepeek(struct socketbuff *sb)
{
	if (sb->popi == sb->pushi)
		return NULL;
	return &sb->queue[sb->popi];
}

static inline void
queuedrop(struct socketbuff *sb)
{
	assert(sb->popi != sb->pushi);
	sb->popi = (sb->popi + 1) % sb->queuecap;
	return ;
}

static struct item *
queuepop(struct socketbuff *sb)
{
	struct item *i;
	i = queuepeek(sb);
	if (i != NULL)
		queuedrop(sb);
	return i;
}

static int
gc(lua_State *L)
{
	struct socketbuff *sb;
	sb = (struct socketbuff *)luaL_checkudata(L, 1, "socketbuff");
	if (sb == NULL)
		return 0;
	for (;;) {
		struct item *i = queuepop(sb);
		if (i == NULL)
			break;
		silly_free(i->buff);
	}
	silly_free(sb->prebuff);
	SSL_free(sb->ssl);
	sb->ssl = NULL;
	return 0;
}

static int
sslwrite(BIO *h, const char *buff, int num)
{
	uint8_t *dat = (uint8_t *)silly_malloc(num);
	memcpy(dat, buff, num);
	silly_socket_send(h->num, dat, num, NULL);
	return num;
}

static int
sslputs(BIO *h, const char *str)
{
	int n = strlen(str);
	return sslwrite(h, str, n);
}

static int count = 0;

static int
sslread(BIO *h, char *buff, int size)
{
	int ret;
	int offset;
	struct socketbuff *sb;
	sb = h->ptr;
	if (sb->datasz < (size_t)size)
		return -1;
	count += size;
	ret = size;
	offset = sb->offset;
	while (size > 0) {
		int once;
		struct item *i;
		i = queuepeek(sb);
		assert(i);
		once = i->size;
		once = once > size ? size : once;
		memcpy(buff, i->buff + offset, once);
		if (once == (int)i->size) {
			offset = 0;
			silly_free(i->buff);
			queuedrop(sb);
		} else {
			offset += once;
			i->size -= once;
		}
		sb->datasz -= once;
		buff += once;
		size -= once;
	}
	sb->offset = offset;
	return ret;
}

static int
sslnew(BIO *bi)
{
	bi->init = 0;
	bi->num = 0;
	bi->ptr = NULL;
	bi->flags = 0;
	return 1;
}

static int
sslfree(BIO *a)
{
	if (a == NULL)
		return 0;
	if (a->shutdown) {
		if (a->init) {
			//silly_socket_close(a->num);
			//we'll do it at lua level
		}
		a->init = 0;
		a->flags = 0;
	}
	return 1;
}

static long
sslctrl(BIO *b, int cmd, long num, void *ptr)
{
	long ret = 1;
	int *ip;
	switch (cmd) {
	case BIO_C_SET_FD:
		sslfree(b);
		b->num = *((int *)ptr);
		b->shutdown = (int)num;
		b->init = 1;
		break;
	case BIO_C_GET_FD:
		if (b->init) {
			ip = (int *)ptr;
			if (ip != NULL)
				*ip = b->num;
			ret = b->num;
		} else {
			ret = -1;
		}
		break;
	case BIO_CTRL_GET_CLOSE:
		ret = b->shutdown;
		break;
	case BIO_CTRL_SET_CLOSE:
		b->shutdown = (int)num;
		break;
	case BIO_CTRL_DUP:
	case BIO_CTRL_FLUSH:
		ret = 1;
		break;
	default:
		ret = 0;
		break;
	}
	return ret;
}

static BIO_METHOD ssl_method = {
	BIO_TYPE_SOCKET,
	"lua ssl socket",
	sslwrite,
	sslread,
	sslputs,
	NULL,
	sslctrl,
	sslnew,
	sslfree,
	NULL,
};

static int
lcreate(lua_State *L)
{
	struct socketbuff *sb;
	SSL_CTX *sslctx;
	int fd = luaL_checkinteger(L, 1);
	sb = newsocketbuff(L, 1);
	sslctx = SSL_CTX_new(SSLv23_client_method());
	sb->ssl = SSL_new(sslctx);
	sb->bio = BIO_new(&ssl_method);
	BIO_set_fd(sb->bio, fd, 0);
	sb->bio->ptr = sb;
	SSL_set_bio(sb->ssl, sb->bio, sb->bio);
	SSL_set_connect_state(sb->ssl);
	return 1;
}

static int
lmessage(lua_State *L)
{
	struct socketbuff *sb;
	struct silly_message_socket *msg;
	sb = luaL_checkudata(L, 1, "socketbuff");
	msg = tosocket(lua_touserdata(L, 2));
	lua_pop(L, 1);
	switch (msg->type) {
	case SILLY_SDATA:
		queuepush(L, sb, msg->data, msg->ud);
		//prevent silly_work free the msg->data
		msg->data = NULL;
		break;
	default:
		luaL_error(L, "netssl unsupport msg type:%d", msg->type);
		return 0;
	}
	return 1;
}

static void
checkprebuff(struct socketbuff *sb, size_t need)
{
	while ((need + sb->presize) > sb->precap) {
		sb->precap = 2 * (sb->precap + 1);
		sb->prebuff = silly_realloc(sb->prebuff, sb->precap);
	}
	return ;
}

static int
lread(lua_State *L)
{
	int ret;
	int size;
	struct socketbuff *sb;
	sb = (struct socketbuff *)luaL_checkudata(L, 1, "socketbuff");
	size = luaL_checkinteger(L, 2);
	assert(sb->presize == 0);
	checkprebuff(sb, size);
	ret = SSL_read(sb->ssl, sb->prebuff, size);
	if (ret < 0) {
		lua_pushnil(L);
	} else {
		assert(ret == size);
		lua_pushlstring(L, sb->prebuff, size);
		sb->presize = 0;
	}
	return 1;
}

static int
lreadline(lua_State *L)
{
	struct socketbuff *sb;
	sb = (struct socketbuff *)luaL_checkudata(L, 1, "socketbuff");
	for (;;) {
		int ret;
		char *buff;
		checkprebuff(sb, 1);
		buff = sb->prebuff + sb->presize;
		ret = SSL_read(sb->ssl, buff, 1);
		if (ret < 0) {
			lua_pushnil(L);
			break;
		}
		++sb->presize;
		if (*buff == '\n') {
			lua_pushlstring(L, sb->prebuff, sb->presize);
			sb->presize = 0;
			break;
		}
	}
	return 1;
}

static int
lwrite(lua_State *L)
{
	struct socketbuff *sb;
	const char *data;
	size_t datasz;
	sb = (struct socketbuff *)luaL_checkudata(L, 1, "socketbuff");
	data = luaL_checklstring(L, 2, &datasz);
	return SSL_write(sb->ssl, data, datasz);
}

static int
lhandshake(lua_State *L)
{
	int ret;
	struct socketbuff *sb;
	sb = (struct socketbuff *)luaL_checkudata(L, 1, "socketbuff");
	ret = SSL_do_handshake(sb->ssl);
	lua_pushboolean(L, ret > 0);
	return 1;
}

static luaL_Reg tbl[] = {
	{"create", lcreate},
	{"read", lread},
	{"write", lwrite},
	{"message", lmessage},
	{"readline", lreadline},
	{"handshake", lhandshake},
	{NULL, NULL},
};

#else

static luaL_Reg tbl[] = {
	{NULL, NULL},
};

#endif

int
luaopen_netssl_c(lua_State *L)
{
	luaL_checkversion(L);
	luaL_newlibtable(L, tbl);
	luaL_setfuncs(L, tbl, 0);
#ifdef USE_OPENSSL
	SSL_load_error_strings();
	SSL_library_init();
#endif
	return 1;
}

