#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>
#include <stdlib.h>
#include <string.h>

#ifdef USE_OPENSSL

#include <openssl/bio.h>
#include <openssl/ssl.h>
#include <openssl/err.h>

#include "silly.h"

#define	ssl_malloc	silly_malloc
#define	ssl_free	silly_free

static BIO_METHOD *ssl_method = NULL;

#if (OPENSSL_VERSION_NUMBER < 0x10100000L)

static inline
BIO_METHOD *BIO_meth_new(int type, const char *name)
{
	BIO_METHOD *bm = ssl_malloc(sizeof(BIO_METHOD));
	memset(bm, 0 , sizeof(*bm));
	if (bm != NULL) {
		bm->type = type;
		bm->name = name;
	}
	return bm;
}

#define	BIO_set_init(b, val) (b)->init = (val)
#define	BIO_set_data(b, val) (b)->ptr = (val)
#define BIO_set_shutdown(b, val) (b)->shutdown = (val)
#define	BIO_clear_flags(b, flag) (b)->flags &= ~(flag)
#define BIO_get_init(b) (b)->init
#define	BIO_get_data(b) (b)->ptr
#define	BIO_get_shutdown(b) (b)->shutdown

#define BIO_meth_set_write(b, f) (b)->bwrite = (f)
#define BIO_meth_set_read(b, f) (b)->bread = (f)
#define BIO_meth_set_puts(b, f) (b)->bputs = (f)
#define BIO_meth_set_ctrl(b, f) (b)->ctrl = (f)
#define BIO_meth_set_create(b, f) (b)->create = (f)
#define BIO_meth_set_destroy(b, f) (b)->destroy = (f)


#endif



struct item {
	uint8_t *buff;
	size_t size;
};

struct socketbuff {
	int fd;
	int offset;
	SSL *ssl;
	BIO *bio;
	char *prebuff;
	size_t precap;
	size_t presize;
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
	newsb->fd = sb->fd;
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
	BIO_set_data(newsb->bio, newsb);
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
	struct socketbuff *sb;
	uint8_t *dat = (uint8_t *)silly_malloc(num);
	memcpy(dat, buff, num);
 	sb = (struct socketbuff *)BIO_get_data(h);
	silly_socket_send(sb->fd, dat, num, NULL);
	return num;
}

static int
sslputs(BIO *h, const char *str)
{
	int n = strlen(str);
	return sslwrite(h, str, n);
}

static int
sslread(BIO *h, char *buff, int size)
{
	int ret;
	int offset;
	struct socketbuff *sb;
	sb = (struct socketbuff *)BIO_get_data(h);
	if (sb->datasz < (size_t)size)
		return -1;
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
	BIO_set_init(bi, 0);
	BIO_set_data(bi, 0);
	BIO_clear_flags(bi, ~0);
	return 1;
}

static int
sslfree(BIO *a)
{
	if (a == NULL)
		return 0;
	if (BIO_get_shutdown(a)) {
		if (BIO_get_init(a)) {
			//silly_socket_close(a->num);
			//we'll do it at lua level
		}
		BIO_set_init(a, 0);
		BIO_clear_flags(a, ~0);
	}
	return 1;
}

static long
sslctrl(BIO *b, int cmd, long num, void *ptr)
{
	long ret = 1;
	(void)ptr;
	switch (cmd) {
	case BIO_C_SET_FD:
		sslfree(b);
		BIO_set_init(b, 1);
		BIO_set_shutdown(b, num);
		break;
	case BIO_CTRL_GET_CLOSE:
		ret = BIO_get_shutdown(b);
		break;
	case BIO_CTRL_SET_CLOSE:
		BIO_set_shutdown(b, (int)num);
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


static void
sslmethodcreate()
{
	ssl_method = BIO_meth_new(BIO_TYPE_SOCKET, "lua ssl socket");
	BIO_meth_set_write(ssl_method, sslwrite);
	BIO_meth_set_read(ssl_method, sslread);
	BIO_meth_set_puts(ssl_method, sslputs);
	BIO_meth_set_ctrl(ssl_method, sslctrl);
	BIO_meth_set_create(ssl_method, sslnew);
	BIO_meth_set_destroy(ssl_method, sslfree);
	return ;
}


static int
lcreate(lua_State *L)
{
	struct socketbuff *sb;
	SSL_CTX *sslctx;
	int fd = luaL_checkinteger(L, 1);
	sb = newsocketbuff(L, 1);
	sslctx = SSL_CTX_new(SSLv23_client_method());
	sb->ssl = SSL_new(sslctx);
	sb->bio = BIO_new(ssl_method);
	sb->fd = fd;
	BIO_set_fd(sb->bio, fd, 0);
	BIO_set_data(sb->bio, sb);
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
	assert((size_t)size > sb->presize);
	size -= sb->presize;
	checkprebuff(sb, size);
	for (;;) {
		ret = SSL_read(sb->ssl, &sb->prebuff[sb->presize], size);
		if (ret < 0) {
			lua_pushnil(L);
			break;
		} else {
			sb->presize += ret;
			size -= ret;
			assert(size >= 0);
			if (size == 0) {//read finish
				lua_pushlstring(L, sb->prebuff, sb->presize);
				sb->presize = 0;
				break;
			}
		}
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
luaopen_sys_netssl_c(lua_State *L)
{
	luaL_checkversion(L);
	luaL_newlibtable(L, tbl);
	luaL_setfuncs(L, tbl, 0);
#ifdef USE_OPENSSL
	SSL_load_error_strings();
	SSL_library_init();
	sslmethodcreate();
#endif
	return 1;
}

