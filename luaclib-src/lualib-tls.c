#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>
#include <stdlib.h>
#include <string.h>
#include "silly.h"
#include "luastr.h"
#ifdef USE_OPENSSL

#include <openssl/bio.h>
#include <openssl/ssl.h>
#include <openssl/err.h>
#include <openssl/x509v3.h>

#define UPVAL_ERROR_TABLE (1)

#define ssl_malloc silly_malloc
#define ssl_free silly_free
#define ssl_realloc silly_realloc

#ifdef SILLY_TEST
#define BUF_SIZE (32)
#else
#define BUF_SIZE (1024)
#endif

struct buf {
	uint8_t *buf;
	int offset;
	int size;
	int cap;
};

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
	silly_socket_id_t fd;
	SSL *ssl;
	BIO *in_bio;
	BIO *out_bio;
	struct buf buf;
	int limit;
	int pause;
};

static inline void push_error(lua_State *L, int code)
{
	silly_push_error(L, lua_upvalueindex(UPVAL_ERROR_TABLE), code);
}

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

static inline void buf_init(struct buf *buf)
{
	buf->buf = NULL;
	buf->offset = 0;
	buf->size = 0;
	buf->cap = 0;
}

static inline void buf_destroy(struct buf *buf)
{
	if (buf->buf == NULL) {
		return;
	}
	ssl_free(buf->buf);
	buf->buf = NULL;
	buf->offset = 0;
	buf->size = 0;
	buf->cap = 0;
}

static void *buf_prepsize(struct buf *b, int size)
{

	if (b->cap == 0) {
		b->cap = BUF_SIZE;
		b->buf = (uint8_t *)ssl_malloc(b->cap);
	}
	if (b->size + b->offset + size > b->cap) {
		if (b->offset != 0) {
			memmove(b->buf, b->buf + b->offset, b->size);
			b->offset = 0;
		}
		b->cap = b->cap * 3 / 2; /* 1.5 */
		if (b->cap < b->size + size) {
			b->cap = b->size + size;
		}
		b->buf = ssl_realloc(b->buf, b->cap);
	}
	return b->buf + b->offset + b->size;
}

static int ltls_free(lua_State *L)
{
	struct tls *tls;
	tls = (struct tls *)luaL_checkudata(L, 1, "TLS");
	if (tls->ssl != NULL) {
		SSL_free(tls->ssl);
		tls->ssl = NULL;
	}
	buf_destroy(&tls->buf);
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

static struct tls *new_tls(lua_State *L, int64_t fd)
{
	struct tls *tls;
	tls = (struct tls *)lua_newuserdatauv(L, sizeof(*tls), 0);
	if (luaL_newmetatable(L, "TLS")) {
		lua_pushcfunction(L, ltls_free);
		lua_setfield(L, -2, "__gc");
	}
	memset(tls, 0, sizeof(*tls));
	tls->fd = fd;
	tls->limit = INT_MAX;
	tls->pause = 0;
	buf_init(&tls->buf);
	lua_setmetatable(L, -2);
	return tls;
}

static inline void read_enable(struct tls *tls)
{
	if (tls->pause == 0)
		return;
	tls->pause = 0;
	silly_socket_readenable(tls->fd, 1);
}

static inline void read_pause(struct tls *tls)
{
	if (tls->pause == 1)
		return;
	tls->pause = 1;
	silly_socket_readenable(tls->fd, 0);
}

static inline int needpause(struct tls *tls)
{
	return tls->buf.size >= tls->limit;
}

static inline void read_adjust(struct tls *tls)
{
	if (needpause(tls))
		read_pause(tls);
	else
		read_enable(tls);
}

static inline void adjust_read(struct tls *tls)
{
	read_adjust(tls);
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
	BIO *cert_bio = NULL;
	BIO *key_bio = NULL;
	X509 *cert = NULL;
	EVP_PKEY *pkey = NULL;
	SSL_CTX *ptr = NULL;
	const char *err = NULL;
	const char *cert_pem, *key_pem;
	size_t cert_len, key_len;
	int top = lua_gettop(L);

	ptr = SSL_CTX_new(TLS_method());
	if (ptr == NULL) {
		err = "SSL_CTX_new fail";
		goto fail;
	}
	SSL_CTX_set_min_proto_version(ptr, TLS1_1_VERSION);

	/* Get certificate PEM content */
	lua_getfield(L, stk, "cert");
	cert_pem = luaL_checklstring(L, -1, &cert_len);
	lua_getfield(L, stk, "key");
	key_pem = luaL_checklstring(L, -1, &key_len);

	/* Load certificate from memory */
	cert_bio = BIO_new_mem_buf(cert_pem, cert_len);
	if (cert_bio == NULL) {
		err = "BIO_new_mem_buf for certificate fail";
		goto fail;
	}

	/* Read the first certificate */
	cert = PEM_read_bio_X509(cert_bio, NULL, NULL, NULL);
	if (cert == NULL) {
		err = "PEM_read_bio_X509 fail";
		goto fail;
	}

	/* Use the first certificate */
	ret = SSL_CTX_use_certificate(ptr, cert);
	if (ret != 1) {
		err = "SSL_CTX_use_certificate fail";
		goto fail;
	}

	/* Load the rest of the certificate chain */
	for (;;) {
		X509 *chain_cert;
		chain_cert = PEM_read_bio_X509(cert_bio, NULL, NULL, NULL);
		if (chain_cert == NULL)
			break;
		ret = SSL_CTX_add_extra_chain_cert(ptr, chain_cert);
		if (ret != 1) {
			X509_free(chain_cert);
			err = "SSL_CTX_add_extra_chain_cert fail";
			goto fail;
		}
		/* chain_cert is now owned by SSL_CTX, don't free it */
	}
	BIO_free(cert_bio);
	cert_bio = NULL;

	/* Load private key from memory */
	key_bio = BIO_new_mem_buf(key_pem, key_len);
	if (key_bio == NULL) {
		err = "BIO_new_mem_buf for private key fail";
		goto fail;
	}

	pkey = PEM_read_bio_PrivateKey(key_bio, NULL, NULL, NULL);
	if (pkey == NULL) {
		err = "PEM_read_bio_PrivateKey fail";
		goto fail;
	}

	ret = SSL_CTX_use_PrivateKey(ptr, pkey);
	EVP_PKEY_free(pkey);
	pkey = NULL;
	BIO_free(key_bio);
	key_bio = NULL;

	if (ret != 1) {
		err = "SSL_CTX_use_PrivateKey fail";
		goto fail;
	}

	/* Verify private key matches certificate */
	ret = SSL_CTX_check_private_key(ptr);
	if (ret != 1) {
		err = "SSL_CTX_check_private_key fail";
		goto fail;
	}

	lua_settop(L, top);
	entry->ptr = ptr;
	entry->cert = cert;
	return NULL;

fail:
	lua_settop(L, top);
	if (cert_bio != NULL)
		BIO_free(cert_bio);
	if (key_bio != NULL)
		BIO_free(key_bio);
	if (pkey != NULL)
		EVP_PKEY_free(pkey);
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
	int64_t fd;
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
	struct tls *tls = (struct tls *)luaL_checkudata(L, 1, "TLS");
	int size = luaL_checkinteger(L, 2);
	if (size <= 0) {
		lua_pushliteral(L, "");
	} else if (size > tls->buf.size) {
		read_enable(tls);
		lua_pushnil(L);
		return 1;
	} else {
		lua_pushlstring(L, (char *)(tls->buf.buf + tls->buf.offset), size);
		tls->buf.offset += size;
		tls->buf.size -= size;
		adjust_read(tls);
	}
	return 1;
}

static int ltls_readline(lua_State *L)
{
	struct tls *tls;
	struct luastr delim;
	uint8_t *s, *e, *x;
	tls = (struct tls *)luaL_checkudata(L, 1, "TLS");
	luastr_check(L, 2, &delim);
	luaL_argcheck(L, delim.len == 1, 2, "delim length must be 1");
	s = tls->buf.buf + tls->buf.offset;
	e = s + tls->buf.size;
	x = memchr(s, delim.str[0], e - s);
	if (x == NULL) {
		read_enable(tls);
		lua_pushnil(L);
	} else {
		size_t line_size = x - s + 1;
		lua_pushlstring(L, (char *)s, line_size);
		tls->buf.offset += line_size;
		tls->buf.size -= line_size;
		adjust_read(tls);
	}
	return 1;
}

static int flushwrite(struct tls *tls)
{
	int sz;
	uint8_t *dat;
	sz = BIO_pending(tls->out_bio);
	if (sz <= 0)
		return 0;
	dat = ssl_malloc(sz);
	BIO_read(tls->out_bio, dat, sz);
	return silly_tcp_send(tls->fd, dat, sz, NULL);
}

static int ltls_write(lua_State *L)
{
	int ret;
	size_t sz;
	struct tls *tls;
	const char *str;
	tls = (struct tls *)luaL_checkudata(L, 1, "TLS");
	switch (lua_type(L, 2)) {
	case LUA_TSTRING: {
		str = luaL_checklstring(L, 2, &sz);
		SSL_write(tls->ssl, str, sz);
		break;
	}
	case LUA_TTABLE: {
		size_t i, n;
		n = luaL_len(L, 2);
		for (i = 1; i <= n; i++) {
			lua_geti(L, 2, i);
			str = luaL_checklstring(L, -1, &sz);
			SSL_write(tls->ssl, str, sz);
			lua_pop(L, 1);
		}
		break;
	}
	default:
		return luaL_error(L, "invalid data type");
	}
	ret = flushwrite(tls);
	lua_pushboolean(L, ret >= 0);
	if (ret < 0) {
		push_error(L, -ret);
	} else {
		lua_pushnil(L);
	}
	return 2;
}

static int ltls_handshake(lua_State *L)
{
	int ret;
	struct tls *tls;
	tls = (struct tls *)luaL_checkudata(L, 1, "TLS");
	ret = SSL_do_handshake(tls->ssl);
	// 1:success 0:error <0:continue
	lua_pushinteger(L, ret);
	if (ret == 1) {// success
		unsigned int len;
		const unsigned char *data;
		SSL_get0_alpn_selected(tls->ssl, &data, &len);
		lua_pushlstring(L, (const char *)data, len);
	} else if (ret <= 0) {
		lua_pushnil(L);
	}
	if (flushwrite(tls) < 0) {
		lua_pop(L, 2);
		lua_pushinteger(L, 0);
		push_error(L, -ret);
	}
	return 2;
}

static int ltls_push(lua_State *L)
{
	struct tls *tls = luaL_checkudata(L, 1, "TLS");
	struct buf *buf = &tls->buf;
	char *str = lua_touserdata(L, 2);
	int size = luaL_checkinteger(L, 3);
	BIO_write(tls->in_bio, str, size);
	silly_free(str);
	for (;;) {
		buf_prepsize(buf, BUF_SIZE);
		uint8_t *s = buf->buf + buf->offset + buf->size;
		uint8_t *e = buf->buf + buf->cap;
		int n = SSL_read(tls->ssl, s, e - s);
		if (n <= 0)
			break;
		buf->size += n;
	}
	lua_pushinteger(L, buf->size);
	adjust_read(tls);
	return 1;
}

static int ltls_limit(lua_State *L)
{
	int limit, prev;
	struct tls *tls = luaL_checkudata(L, 1, "TLS");
	limit = luaL_checkinteger(L, 2);
	prev = tls->limit;
	tls->limit = limit;
	read_adjust(tls);
	lua_pushinteger(L, prev);
	return 1;
}

static int ltls_size(lua_State *L)
{
	struct tls *tls = luaL_checkudata(L, 1, "TLS");
	lua_pushinteger(L, tls->buf.size);
	return 1;
}

#endif

SILLY_MOD_API int luaopen_silly_tls_ctx(lua_State *L)
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

SILLY_MOD_API int luaopen_silly_tls_tls(lua_State *L)
{
	luaL_Reg tbl[] = {
#ifdef USE_OPENSSL
		{ "open",      ltls_open      },
		{ "close",     ltls_free      },
		{ "read",      ltls_read      },
		{ "write",     ltls_write     },
		{ "readline",  ltls_readline  },
		{ "handshake", ltls_handshake },
		{ "push",      ltls_push      },
		{ "limit",     ltls_limit     },
		{ "size",      ltls_size      },
#endif
		{ NULL,        NULL           },
	};

	luaL_checkversion(L);
	luaL_newlibtable(L, tbl);
	silly_error_table(L);
	luaL_setfuncs(L, tbl, 1);
	return 1;
}
