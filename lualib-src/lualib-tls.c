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

struct ctx {
	int mode;
	int alpn;
	SSL_CTX *ptr;
};

struct tls {
	int fd;
	SSL *ssl;
	BIO *in_bio;
	BIO *out_bio;
};

static int
lctx_free(lua_State *L)
{
	struct ctx *ctx;
	ctx = (struct ctx *)luaL_checkudata(L, 1, "TLS_CTX");
	if (ctx->ptr!= NULL)
		SSL_CTX_free(ctx->ptr);
	ctx->ptr= NULL;
	return 0;
}

static int
ltls_free(lua_State *L)
{
	struct tls *tls;
	tls = (struct tls *)luaL_checkudata(L, 1, "TLS");
	if (tls->ssl != NULL)
		SSL_free(tls->ssl);
	tls->ssl = NULL;
	return 0;
}


static struct ctx *
new_tls_ctx(lua_State *L, SSL_CTX *ptr, int mode)
{
	struct ctx *ctx;
	ctx = (struct ctx*)lua_newuserdatauv(L, sizeof(*ctx), 0);
	if (luaL_newmetatable(L, "TLS_CTX")) {
		lua_pushcfunction(L, lctx_free);
		lua_setfield(L, -2, "__gc");
	}
	ctx->ptr = ptr;
	ctx->mode = mode;
	ctx->alpn = 0;
	lua_setmetatable(L, -2);
	return ctx;
}

static struct tls *
new_tls(lua_State *L, int fd)
{
	struct tls *tls;
	tls= (struct tls*)lua_newuserdatauv(L, sizeof(*tls), 0);
	if (luaL_newmetatable(L, "TLS")) {
		lua_pushcfunction(L, ltls_free);
		lua_setfield(L, -2, "__gc");
	}
	memset(tls, 0, sizeof(*tls));
	tls->fd = fd;
	lua_setmetatable(L, -2);
	return tls;
}

#if OPENSSL_VERSION_NUMBER < 0x10100000L
#define TLS_method TLSv1_2_method
#endif

static int
lctx_client(lua_State *L)
{
	SSL_CTX *ptr;
	ptr = SSL_CTX_new(TLS_method());
	if (ptr == NULL) {
		lua_pushnil(L);
		lua_pushstring(L, "SSL_CTX_new fail");
		return 2;
	}
	new_tls_ctx(L, ptr, 'C');
	return 1;
}

static unsigned char alpn_h2[] = {
	2, 'h', '2',
};
static unsigned char alpn_h1[] = {
	8, 'h', 't', 't', 'p', '/', '1', '.', '1'
};


#define ALPN_NONE	(0)
#define ALPN_H2		(1)

int alpn_cb(SSL *ssl, const unsigned char **out, unsigned char *outlen,
	const unsigned char *in, unsigned int inlen, void *arg)
{
	int ret;
	unsigned int size;
	unsigned char *alpn;
	unsigned char *outx;
	(void)ssl;
	struct ctx *ctx = (struct ctx *)arg;
	if (ctx->ptr == NULL)
		return SSL_TLSEXT_ERR_NOACK;
	if (ctx->alpn == 1) {
		alpn = alpn_h2;
		size = sizeof(alpn_h2);
	} else {
		alpn = alpn_h1;
		size = sizeof(alpn_h1);
	}
	ret = SSL_select_next_proto(&outx, outlen, alpn, size, in, inlen);
	if (ret == OPENSSL_NPN_NEGOTIATED) {
		*out = outx;
		return SSL_TLSEXT_ERR_OK;
	} else {
		return SSL_TLSEXT_ERR_NOACK;
	}
}

static int
lctx_server(lua_State *L)
{
	int r, alpn;
	SSL_CTX *ptr;
	struct ctx *ctx;
	const char *certpath, *keypath;
	ptr = SSL_CTX_new(TLS_method());
	if (ptr == NULL) {
		lua_pushnil(L);
		lua_pushstring(L, "SSL_CTX_new");
		return 2;
	}
	certpath = luaL_checkstring(L, 1);
	keypath = luaL_checkstring(L, 2);
	//create tls_ctx first so that
	//even lctx_server fail
	//gc also will free the ptr
	ctx = new_tls_ctx(L, ptr, 'S');
	r = SSL_CTX_use_certificate_file(ptr, certpath, SSL_FILETYPE_PEM);
	if (r != 1) {
		lua_pop(L, 1);
		lua_pushnil(L);
		lua_pushstring(L, "SSL_CTX_use_certificate_file");
		return 2;
	}
	r = SSL_CTX_use_PrivateKey_file(ptr, keypath, SSL_FILETYPE_PEM);
	if (r != 1) {
		lua_pop(L, 1);
		lua_pushnil(L);
		lua_pushstring(L, "SSL_CTX_use_PrivateKey_file");
		return 2;
	}
	r = SSL_CTX_check_private_key(ptr);
	if (r != 1) {
		lua_pop(L, 1);
		lua_pushnil(L);
		lua_pushstring(L, "SSL_CTX_check_private_key");
		return 2;
	}
	if (lua_type(L, 3) != LUA_TNIL) {
		const char *cipher;
		cipher = luaL_checkstring(L, 3);
		r = SSL_CTX_set_cipher_list(ptr, cipher);
		if (r != 1) {
			lua_pop(L, 1);
			lua_pushnil(L);
			lua_pushstring(L, "SSL_CTX_set_cipher_list");
			return 2;
		}
	}
	alpn = luaL_optinteger(L, 4, 0);
	if (alpn == 1) {
		ctx->alpn = alpn;
		SSL_CTX_set_alpn_select_cb(ptr, alpn_cb, ctx);
	}
	return 1;
}

static int
ltls_open(lua_State *L)
{
	int fd, alpn;
	struct ctx *ctx;
	struct tls *tls;
	const char *hostname;
	ctx = luaL_checkudata(L, 1, "TLS_CTX");
	fd = luaL_checkinteger(L, 2);
	hostname = lua_tostring(L, 3);
	alpn = luaL_optinteger(L, 4, 0);
	tls = new_tls(L, fd);
	tls->ssl = SSL_new(ctx->ptr);
	if (tls->ssl == NULL)
		luaL_error(L, "SSL_new fail");
	if (alpn == 1)
		SSL_set_alpn_protos(tls->ssl, alpn_h2, sizeof(alpn_h2));
	else
		SSL_set_alpn_protos(tls->ssl, alpn_h1, sizeof(alpn_h1));
	tls->in_bio = BIO_new(BIO_s_mem());
	if (tls->in_bio == NULL)
		luaL_error(L, "BIO_new fail");
	tls->out_bio = BIO_new(BIO_s_mem());
	if (tls->out_bio == NULL)
		luaL_error(L, "BIO_new fail");
	//ref: https://www.openssl.org/docs/crypto/BIO_s_mem.html
	BIO_set_mem_eof_return(tls->in_bio, -1);
	BIO_set_mem_eof_return(tls->out_bio, -1);
	SSL_set_bio(tls->ssl, tls->in_bio, tls->out_bio);
	if (ctx->mode == 'C') {
		if (hostname != NULL)
			SSL_set_tlsext_host_name(tls->ssl, hostname);
		SSL_set_connect_state(tls->ssl);
	} else {
		SSL_set_accept_state(tls->ssl);
	}
	return 1;
}

static int
ltls_read(lua_State *L)
{
	char *ptr;
	int size, last;
	struct tls *tls;
	luaL_Buffer buf;
	tls = (struct tls*)luaL_checkudata(L, 1, "TLS");
	last = size = luaL_checkinteger(L, 2);
	ptr = luaL_buffinitsize(L, &buf, size);
	while (last > 0) {
		int ret = SSL_read(tls->ssl, ptr, last);
		if (ret <= 0)
			break;
		ptr += ret;
		last -= ret;
	}
	luaL_pushresultsize(&buf, size - last);
	return 1;
}

static int
ltls_readall(lua_State *L)
{
	char *ptr;
	struct tls *tls;
	luaL_Buffer buf;
	tls = (struct tls*)luaL_checkudata(L, 1, "TLS");
	luaL_buffinit(L, &buf);
	for (;;) {
		int ret;
		ptr = luaL_prepbuffsize(&buf, 1024);
		ret = SSL_read(tls->ssl, ptr, 1024);
		if (ret <= 0)
			break;
		luaL_addsize(&buf, ret);
	}
	luaL_pushresult(&buf);
	return 1;
}



static int
ltls_readline(lua_State *L)
{
	struct tls *tls;
	luaL_Buffer buf;
	tls = (struct tls*)luaL_checkudata(L, 1, "TLS");
	luaL_buffinit(L, &buf);
	for (;;) {
		char c;
		int ret = SSL_read(tls->ssl, &c, 1);
		if (ret <= 0)
			break;
		luaL_addchar(&buf, c);
		if (c == '\n') {
			luaL_pushresult(&buf);
			lua_pushboolean(L, 1);
			return 2;
		}
	}
	luaL_pushresult(&buf);
	lua_pushboolean(L, 0);
	return 2;
}

static int
flushwrite(struct tls *tls)
{
	int sz;
	uint8_t *dat;
	sz = BIO_pending(tls->out_bio);
	if (sz <= 0)
		return -1;
	dat = ssl_malloc(sz);
	BIO_read(tls->out_bio, dat, sz);
	return silly_socket_send(tls->fd, dat, sz, NULL);
}

static int
ltls_write(lua_State *L)
{
	size_t sz;
	struct tls *tls;
	const char *str;
	tls = (struct tls*)luaL_checkudata(L, 1, "TLS");
	str = luaL_checklstring(L, 2, &sz);
	SSL_write(tls->ssl, str, sz);
	lua_pushboolean(L, flushwrite(tls) >= 0);
	return 1;
}

static int
ltls_handshake(lua_State *L)
{
	int ret;
	struct tls *tls;
	tls = (struct tls *)luaL_checkudata(L, 1, "TLS");
	ret = SSL_do_handshake(tls->ssl);
	lua_pushboolean(L, ret > 0);
	flushwrite(tls);
	return 1;
}

static int
ltls_message(lua_State *L)
{
	struct tls *tls;
	struct silly_message_socket *msg;
	tls = luaL_checkudata(L, 1, "TLS");
	msg = tosocket(lua_touserdata(L, 2));
	switch (msg->type) {
	case SILLY_SDATA:
		BIO_write(tls->in_bio, msg->data, msg->ud);
		break;
	default:
		luaL_error(L, "TLS unsupport msg type:%d", msg->type);
		break;
	}
	return 0;
}


#endif

int
luaopen_sys_tls_ctx(lua_State *L)
{
	luaL_Reg tbl[] = {
#ifdef USE_OPENSSL
		{"client", lctx_client},
		{"server", lctx_server},
		{"free", lctx_free},
#endif
		{NULL, NULL},
	};
	luaL_checkversion(L);
	luaL_newlibtable(L, tbl);
	luaL_setfuncs(L, tbl, 0);
#ifdef USE_OPENSSL
	SSL_library_init();
	SSL_load_error_strings();
#if OPENSSL_VERSION_NUMBER >= 0x30000000L && !defined(LIBRESSL_VERSION_NUMBER)
	/*
	* ERR_load_*(), ERR_func_error_string(), ERR_get_error_line(), ERR_get_error_line_data(), ERR_get_state()
	* OpenSSL now loads error strings automatically so these functions are not needed.
	* SEE FOR MORE:
	*	https://www.openssl.org/docs/manmaster/man7/migration_guide.html
	*
	*/
#else
	/* Load error strings into mem*/
	ERR_load_BIO_strings();
#endif
#if OPENSSL_VERSION_NUMBER < 0x10100000L
	OpenSSL_add_all_algorithms();
#endif
#endif
	return 1;
}


int
luaopen_sys_tls_tls(lua_State *L)
{
	luaL_Reg tbl[] = {
#ifdef USE_OPENSSL
		{"open", ltls_open},
		{"close", ltls_free},
		{"read", ltls_read},
		{"write", ltls_write},
		{"readall", ltls_readall},
		{"readline", ltls_readline},
		{"handshake", ltls_handshake},
		{"message", ltls_message},
#endif
		{NULL, NULL},
	};

	luaL_checkversion(L);
	luaL_newlibtable(L, tbl);
	luaL_setfuncs(L, tbl, 0);
	return 1;
}

