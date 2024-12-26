#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>
#include <stdlib.h>
#include <string.h>

#ifdef USE_OPENSSL

#include <openssl/bio.h>
#include <openssl/ssl.h>
#include <openssl/err.h>
#include <openssl/x509v3.h>

#include "silly.h"
#include "silly_malloc.h"
#include "silly_socket.h"

#define ssl_malloc silly_malloc
#define ssl_free silly_free

struct ctx_entry {
	SSL_CTX *ptr;
	X509 *cert;
};

struct ctx {
	int mode;
	int alpn_size;
	const unsigned char *alpn_protos;
	int entry_count;
	struct ctx_entry entries[1];
};

struct tls {
	int fd;
	SSL *ssl;
	BIO *in_bio;
	BIO *out_bio;
};

static void ctx_destroy(struct ctx *ctx)
{
	int i;
	for (i = 0; i < ctx->entry_count; i++) {
		if (ctx->entries[i].ptr != NULL) {
			SSL_CTX_free(ctx->entries[i].ptr);
		}
		if (ctx->entries[i].cert != NULL) {
			X509_free(ctx->entries[i].cert);
		}
	}
	ctx->entry_count = 0;
}

static int lctx_free(lua_State *L)
{
	struct ctx *ctx;
	ctx = (struct ctx *)luaL_checkudata(L, 1, "TLS_CTX");
	ctx_destroy(ctx);
	return 0;
}

static int ltls_free(lua_State *L)
{
	struct tls *tls;
	tls = (struct tls *)luaL_checkudata(L, 1, "TLS");
	if (tls->ssl != NULL)
		SSL_free(tls->ssl);
	tls->ssl = NULL;
	return 0;
}

static struct ctx *new_tls_ctx(lua_State *L, int mode, int ctx_count,
			       int nupval)
{
	int size;
	struct ctx *ctx;
	size = offsetof(struct ctx, entries) +
	       ctx_count * sizeof(struct ctx_entry);
	ctx = (struct ctx *)lua_newuserdatauv(L, size, nupval);
	if (luaL_newmetatable(L, "TLS_CTX")) {
		lua_pushcfunction(L, lctx_free);
		lua_setfield(L, -2, "__gc");
	}
	memset(ctx, 0, size);
	ctx->mode = mode;
	ctx->entry_count = ctx_count;
	lua_setmetatable(L, -2);
	return ctx;
}

static struct tls *new_tls(lua_State *L, int fd)
{
	struct tls *tls;
	tls = (struct tls *)lua_newuserdatauv(L, sizeof(*tls), 0);
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

static int lctx_client(lua_State *L)
{
	SSL_CTX *ptr;
	struct ctx *ctx;
	ptr = SSL_CTX_new(TLS_method());
	if (ptr == NULL) {
		lua_pushnil(L);
		lua_pushstring(L, "SSL_CTX_new fail");
		return 2;
	}
	ctx = new_tls_ctx(L, 'C', 1, 0);
	ctx->entries[0].ptr = ptr;
	return 1;
}

int alpn_cb(SSL *ssl, const unsigned char **out, unsigned char *outlen,
	    const unsigned char *in, unsigned int inlen, void *arg)
{
	int ret;
	unsigned char *outx;
	(void)ssl;
	struct ctx *ctx = (struct ctx *)arg;
	if (ctx->entry_count == 0)
		return SSL_TLSEXT_ERR_NOACK;
	ret = SSL_select_next_proto(&outx, outlen, ctx->alpn_protos,
				    ctx->alpn_size, in, inlen);
	if (ret == OPENSSL_NPN_NEGOTIATED) {
		*out = outx;
		return SSL_TLSEXT_ERR_OK;
	} else {
		return SSL_TLSEXT_ERR_NOACK;
	}
}

static const char *fill_entry(lua_State *L, struct ctx_entry *entry, int stk)
{
	int ret;
	FILE *fp = NULL;
	X509 *cert = NULL;
	SSL_CTX *ptr = NULL;
	const char *err = NULL;
	const char *certpath, *keypath;
	int top = lua_gettop(L);
	ptr = SSL_CTX_new(TLS_method());
	if (ptr == NULL) {
		err = "SSL_CTX_new fail";
		goto fail;
	}
	SSL_CTX_set_min_proto_version(ptr, TLS1_1_VERSION);
	lua_getfield(L, stk, "cert");
	certpath = luaL_checkstring(L, -1);
	lua_getfield(L, stk, "cert_key");
	keypath = luaL_checkstring(L, -1);
	fp = fopen(certpath, "r");
	if (fp == NULL) {
		err = "open certificate file fail";
		goto fail;
	}
	cert = PEM_read_X509(fp, NULL, NULL, NULL);
	fclose(fp);
	fp = NULL;
	if (cert == NULL) {
		err = "read certificate file fail";
		goto fail;
	}
	ret = SSL_CTX_use_certificate_chain_file(ptr, certpath);
	if (ret != 1) {
		err = "SSL_CTX_use_certificate_file";
		goto fail;
	}
	ret = SSL_CTX_use_PrivateKey_file(ptr, keypath, SSL_FILETYPE_PEM);
	if (ret != 1) {
		printf("SSL_CTX_use_PrivateKey_file fail:%s\n",
		       ERR_error_string(ERR_get_error(), NULL));
		err = "SSL_CTX_use_PrivateKey_file";
		goto fail;
	}
	ret = SSL_CTX_check_private_key(ptr);
	if (ret != 1) {
		err = "SSL_CTX_check_private_key";
		goto fail;
	}
	lua_settop(L, top);
	entry->ptr = ptr;
	entry->cert = cert;
	return NULL;
fail:
	lua_settop(L, top);
	if (fp != NULL)
		fclose(fp);
	if (ptr != NULL)
		SSL_CTX_free(ptr);
	if (cert != NULL)
		X509_free(cert);
	return err;
}

static int ssl_servername_cb(SSL *s, int *ad, void *arg)
{
	int i;
	SSL_CTX *ptr = NULL;
	const char *servername;
	struct ctx *ctx = (struct ctx *)arg;
	(void)ad;
	servername = SSL_get_servername(s, TLSEXT_NAMETYPE_host_name);
	if (servername != NULL) {
		for (i = 0; i < ctx->entry_count; i++) {
			X509 *cert = ctx->entries[i].cert;
			if (cert == NULL)
				continue;
			if (X509_check_host(cert, servername, 0, 0, NULL) ==
			    1) {
				ptr = ctx->entries[i].ptr;
				break;
			}
		}
	}
	if (ptr == NULL) {
		ptr = ctx->entries[0].ptr;
	}
	SSL_set_SSL_CTX(s, ptr);
	return SSL_TLSEXT_ERR_OK;
}

static int lctx_server(lua_State *L)
{
	SSL_CTX *ptr;
	struct ctx *ctx;
	int i, ncert, r;
	size_t alpn_size;
	const char *err = NULL;
	const unsigned char *alpn_protos = NULL;
	ncert = luaL_len(L, 1);
	alpn_protos =
		(const unsigned char *)luaL_optlstring(L, 3, NULL, &alpn_size);
	ctx = new_tls_ctx(L, 'S', ncert, alpn_protos != NULL ? 1 : 0);
	ctx->alpn_protos = alpn_protos;
	ctx->alpn_size = alpn_size;
	for (i = 0; i < ctx->entry_count; i++) {
		int absidx;
		struct ctx_entry *entry;
		lua_rawgeti(L, 1, i + 1);
		absidx = lua_absindex(L, -1);
		entry = &ctx->entries[i];
		err = fill_entry(L, entry, absidx);
		lua_pop(L, 1);
		if (err != NULL)
			break;
		ptr = entry->ptr;
		SSL_CTX_set_tlsext_servername_callback(ptr, ssl_servername_cb);
		SSL_CTX_set_tlsext_servername_arg(ptr, ctx);
	}
	if (err != NULL) {
		ctx_destroy(ctx);
		lua_pushnil(L);
		lua_pushstring(L, err);
		return 2;
	}
	if (lua_type(L, 2) != LUA_TNIL) {
		const char *cipher;
		cipher = luaL_checkstring(L, 2);
		for (i = 0; i < ctx->entry_count; i++) {
			SSL_CTX *ptr = ctx->entries[i].ptr;
			r = SSL_CTX_set_cipher_list(ptr, cipher);
			if (r != 1) {
				ctx_destroy(ctx);
				lua_pushnil(L);
				lua_pushstring(L, "SSL_CTX_set_cipher_list");
				return 2;
			}
		}
	}
	if (ctx->alpn_protos != NULL) {
		for (i = 0; i < ctx->entry_count; i++) {
			SSL_CTX *ptr = ctx->entries[i].ptr;
			SSL_CTX_set_alpn_select_cb(ptr, alpn_cb, ctx);
		}
	}
	return 1;
}

static int ltls_open(lua_State *L)
{
	int fd;
	size_t alpn_size;
	struct ctx *ctx;
	struct tls *tls;
	const char *hostname;
	const unsigned char *alpn_protos;
	ctx = luaL_checkudata(L, 1, "TLS_CTX");
	fd = luaL_checkinteger(L, 2);
	hostname = lua_tostring(L, 3);
	alpn_protos =
		(const unsigned char *)luaL_optlstring(L, 4, NULL, &alpn_size);
	tls = new_tls(L, fd);
	tls->ssl = SSL_new(ctx->entries[0].ptr);
	if (tls->ssl == NULL)
		luaL_error(L, "SSL_new fail");
	if (alpn_protos != NULL)
		SSL_set_alpn_protos(tls->ssl, alpn_protos, alpn_size);
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

static int ltls_read(lua_State *L)
{
	char *ptr;
	int size, last;
	struct tls *tls;
	luaL_Buffer buf;
	tls = (struct tls *)luaL_checkudata(L, 1, "TLS");
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

static int ltls_readall(lua_State *L)
{
	char *ptr;
	struct tls *tls;
	luaL_Buffer buf;
	tls = (struct tls *)luaL_checkudata(L, 1, "TLS");
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

static int ltls_readline(lua_State *L)
{
	struct tls *tls;
	luaL_Buffer buf;
	tls = (struct tls *)luaL_checkudata(L, 1, "TLS");
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

static int flushwrite(struct tls *tls)
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

static int ltls_write(lua_State *L)
{
	size_t sz;
	struct tls *tls;
	const char *str;
	tls = (struct tls *)luaL_checkudata(L, 1, "TLS");
	str = luaL_checklstring(L, 2, &sz);
	SSL_write(tls->ssl, str, sz);
	lua_pushboolean(L, flushwrite(tls) >= 0);
	return 1;
}

static int ltls_handshake(lua_State *L)
{
	int ret;
	struct tls *tls;
	tls = (struct tls *)luaL_checkudata(L, 1, "TLS");
	ret = SSL_do_handshake(tls->ssl);
	lua_pushboolean(L, ret > 0);
	if (ret > 0) {
		unsigned int len;
		const unsigned char *data;
		SSL_get0_alpn_selected(tls->ssl, &data, &len);
		lua_pushlstring(L, (const char *)data, len);
	} else {
		lua_pushliteral(L, "");
	}
	flushwrite(tls);
	return 2;
}

static int ltls_message(lua_State *L)
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

int luaopen_core_tls_ctx(lua_State *L)
{
	luaL_Reg tbl[] = {
#ifdef USE_OPENSSL
		{ "client", lctx_client },
		{ "server", lctx_server },
		{ "free",   lctx_free   },
#endif
		{ NULL,     NULL        },
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

int luaopen_core_tls_tls(lua_State *L)
{
	luaL_Reg tbl[] = {
#ifdef USE_OPENSSL
		{ "open",      ltls_open      },
		{ "close",     ltls_free      },
		{ "read",      ltls_read      },
		{ "write",     ltls_write     },
		{ "readall",   ltls_readall   },
		{ "readline",  ltls_readline  },
		{ "handshake", ltls_handshake },
		{ "message",   ltls_message   },
#endif
		{ NULL,        NULL           },
	};

	luaL_checkversion(L);
	luaL_newlibtable(L, tbl);
	luaL_setfuncs(L, tbl, 0);
	return 1;
}
