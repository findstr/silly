#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>
#include <assert.h>
#include <stdlib.h>
#include <string.h>
#include "silly.h"
#include "luastr.h"
#ifdef USE_OPENSSL

#include <openssl/bio.h>
#include <openssl/ssl.h>
#include <openssl/err.h>
#include <openssl/x509v3.h>
#include <limits.h>

#define META_CTX "silly.tls.ctx"
#define META_TLS "silly.tls.tls"

#define WRITE_FLUSH_SIZE (2 * 1024 * 1024)
#define TLS_ERROR_CLOSED (-1) /* Local owner close; OpenSSL has no matching SSL_ERROR_*. */
#define TLS_WANT_IO(err) ((err) == SSL_ERROR_WANT_READ || (err) == SSL_ERROR_WANT_WRITE)
#define TLS_HAS_ERROR(err) ((err) != SSL_ERROR_NONE && (err) != SSL_ERROR_ZERO_RETURN)

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
	size_t offset;
	size_t size;
	size_t cap;
};

struct ctx_entry {
	SSL_CTX *ptr;
	X509 *cert;
};

struct ctx {
	void *meta;
	int mode;
	int alpn_size;
	const unsigned char *alpn_protos;
	int entry_count;
	struct ctx_entry entries[1];
};

struct tls {
	void *meta;
	silly_socket_id_t fd; /* borrowed socket ID */
	SSL *ssl;
	BIO *in_bio;
	BIO *out_bio;
	struct buf readbuf;
	struct buf writebuf;
	int writelen;
	int readenabled;
	int readlimit; /* -1 means unlimited. */
	int readwaiting;
	int err; /* SSL_ERROR_* or TLS_ERROR_CLOSED; transport errors stay in Lua. */
};

static inline int tls_error(int err)
{
	switch (err) {
	case SSL_ERROR_NONE:
		return 0;
	case SSL_ERROR_ZERO_RETURN:
		return EXEOF;
	case TLS_ERROR_CLOSED:
		return EXCLOSED;
	default:
		return EXTLS;
	}
}

static inline void buf_init(struct buf *buf)
{
	buf->buf = NULL;
	buf->offset = 0;
	buf->size = 0;
	buf->cap = 0;
}

static inline void buf_clear(struct buf *buf)
{
	buf->offset = 0;
	buf->size = 0;
}

static inline void buf_destroy(struct buf *buf)
{
	if (buf->buf != NULL)
		ssl_free(buf->buf);
	buf_init(buf);
}

static void *buf_prepsize(struct buf *b, size_t size)
{
	size_t cap;
	assert(size <= SIZE_MAX - b->size);
	if (b->cap == 0) {
		b->cap = BUF_SIZE;
		b->buf = (uint8_t *)ssl_malloc(b->cap);
	}
	if (size > b->cap - b->offset - b->size) {
		if (b->offset != 0) {
			memmove(b->buf, b->buf + b->offset, b->size);
			b->offset = 0;
		}
		if (size > b->cap - b->size) {
			cap = b->size + size;
			if (b->cap / 2 <= SIZE_MAX - b->cap)
				cap = max(cap, b->cap + b->cap / 2);
			b->cap = cap;
			b->buf = ssl_realloc(b->buf, b->cap);
		}
	}
	return b->buf + b->offset + b->size;
}

static inline void write_clear(struct tls *tls)
{
	buf_clear(&tls->writebuf);
	tls->writelen = 0;
}

static inline int read_update(struct tls *tls)
{
	int enable;
	if (tls->ssl == NULL)
		return 0;
	/* TLS progress and error draining must not be blocked by application limits. */
	enable = tls->readlimit < 0 || tls->readbuf.size < (size_t)tls->readlimit || tls->readwaiting ||
		 tls->err != SSL_ERROR_NONE || tls->writebuf.size > 0 || SSL_in_init(tls->ssl);
	if (tls->readenabled != enable) {
		tls->readenabled = enable;
		silly_socket_readenable(tls->fd, enable);
	}
	return enable;
}

static void log_error(struct tls *tls, int err)
{
	unsigned long e;
	char buf[256];
	if (err == SSL_ERROR_ZERO_RETURN)
		return;
	e = ERR_get_error();
	if (e != 0) {
		ERR_error_string_n(e, buf, sizeof(buf));
		silly_log_error("[tls] openssl fd:%lu error: %s\n", (uint64_t)tls->fd, buf);
	} else {
		silly_log_error("[tls] openssl fd:%lu ssl error code:%d\n", (uint64_t)tls->fd, err);
	}
}

static struct ctx *new_ctx(lua_State *L, int mode, int ctx_count, int nupval)
{
	int size;
	struct ctx *ctx;
	size = offsetof(struct ctx, entries) + ctx_count * sizeof(struct ctx_entry);
	ctx = (struct ctx *)lua_newuserdatauv(L, size, nupval);
	luaL_getmetatable(L, META_CTX);
	memset(ctx, 0, size);
	ctx->mode = mode;
	ctx->entry_count = ctx_count;
	ctx->meta = (void *)new_ctx;
	lua_setmetatable(L, -2);
	return ctx;
}

static inline struct ctx *check_ctx(lua_State *L, int index)
{
	struct ctx *c = (struct ctx *)lua_touserdata(L, index);
	if (unlikely(c == NULL || c->meta != (void *)&new_ctx))
		luaL_typeerror(L, index, META_CTX);
	return c;
}

static void ctx_destroy(struct ctx *ctx)
{
	int i;
	for (i = 0; i < ctx->entry_count; i++) {
		SSL_CTX_free(ctx->entries[i].ptr);
		X509_free(ctx->entries[i].cert);
	}
	ctx->entry_count = 0;
}

static int lctx_free(lua_State *L)
{
	struct ctx *ctx = check_ctx(L, 1);
	ctx_destroy(ctx);
	ctx->meta = NULL;
	return 0;
}

static struct tls *new_tls(lua_State *L, int64_t fd)
{
	struct tls *tls;
	tls = (struct tls *)lua_newuserdatauv(L, sizeof(*tls), 1);
	luaL_getmetatable(L, META_TLS);
	memset(tls, 0, sizeof(*tls));
	buf_init(&tls->readbuf);
	buf_init(&tls->writebuf);
	tls->fd = fd;
	tls->readenabled = 1;
	tls->readlimit = -1;
	tls->meta = (void *)&new_tls;
	lua_setmetatable(L, -2);
	return tls;
}

static inline struct tls *check_tls(lua_State *L, int index)
{
	struct tls *tls = (struct tls *)lua_touserdata(L, index);
	if (unlikely(tls == NULL || tls->meta != (void *)&new_tls))
		luaL_typeerror(L, index, META_TLS);
	return tls;
}

static int ltls_free(lua_State *L)
{
	struct tls *tls;
	tls = check_tls(L, 1);
	SSL_free(tls->ssl);
	tls->ssl = NULL;
	buf_destroy(&tls->readbuf);
	buf_destroy(&tls->writebuf);
	tls->meta = NULL;
	return 0;
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
	ctx = new_ctx(L, 'C', 1, 0);
	ctx->entries[0].ptr = ptr;
	return 1;
}

int alpn_cb(SSL *ssl, const unsigned char **out, unsigned char *outlen, const unsigned char *in, unsigned int inlen,
	    void *arg)
{
	int ret;
	unsigned char *outx;
	struct ctx *ctx = (struct ctx *)arg;
	(void)ssl;
	ret = SSL_select_next_proto(&outx, outlen, ctx->alpn_protos, ctx->alpn_size, in, inlen);
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

	/* Validate Lua fields before allocating resources that errors would bypass. */
	lua_getfield(L, stk, "cert");
	cert_pem = luaL_checklstring(L, -1, &cert_len);
	lua_getfield(L, stk, "key");
	key_pem = luaL_checklstring(L, -1, &key_len);

	ptr = SSL_CTX_new(TLS_method());
	if (ptr == NULL) {
		err = "SSL_CTX_new fail";
		goto fail;
	}
	SSL_CTX_set_min_proto_version(ptr, TLS1_1_VERSION);

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
	BIO_free(cert_bio);
	BIO_free(key_bio);
	EVP_PKEY_free(pkey);
	SSL_CTX_free(ptr);
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
			if (X509_check_host(cert, servername, 0, 0, NULL) == 1) {
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
	int i, ncert, ret;
	lua_Integer count;
	size_t alpn_size;
	const char *cipher;
	const char *err = NULL;
	const unsigned char *alpn_protos;
	const lua_Integer maxcert = (INT_MAX - offsetof(struct ctx, entries)) / sizeof(struct ctx_entry);
	luaL_checktype(L, 1, LUA_TTABLE);
	count = luaL_len(L, 1);
	luaL_argcheck(L, count > 0 && count <= maxcert, 1, "invalid certificate count");
	cipher = luaL_optstring(L, 2, NULL);
	ncert = (int)count;
	alpn_protos = (const unsigned char *)luaL_optlstring(L, 3, NULL, &alpn_size);
	ctx = new_ctx(L, 'S', ncert, alpn_protos != NULL ? 1 : 0);
	ctx->alpn_protos = alpn_protos;
	ctx->alpn_size = alpn_size;
	if (alpn_protos != NULL) {
		lua_pushvalue(L, 3);
		lua_setiuservalue(L, -2, 1);
	}
	for (i = 0; i < ctx->entry_count; i++) {
		int absidx;
		struct ctx_entry *entry;
		lua_geti(L, 1, i + 1);
		absidx = lua_absindex(L, -1);
		entry = &ctx->entries[i];
		err = fill_entry(L, entry, absidx);
		lua_pop(L, 1);
		if (err != NULL)
			break;
		ptr = entry->ptr;
		if (cipher != NULL) {
			ret = SSL_CTX_set_cipher_list(ptr, cipher);
			if (ret != 1) {
				err = "SSL_CTX_set_cipher_list";
				break;
			}
		}
		SSL_CTX_set_tlsext_servername_callback(ptr, ssl_servername_cb);
		SSL_CTX_set_tlsext_servername_arg(ptr, ctx);
		if (alpn_protos != NULL)
			SSL_CTX_set_alpn_select_cb(ptr, alpn_cb, ctx);
	}
	if (err != NULL) {
		ctx_destroy(ctx);
		lua_pushnil(L);
		lua_pushstring(L, err);
		return 2;
	}
	return 1;
}

static int ltls_open(lua_State *L)
{
	int64_t fd;
	int ret;
	size_t alpn_size;
	struct ctx *ctx;
	struct tls *tls;
	BIO *in = NULL;
	BIO *out = NULL;
	const char *hostname;
	const unsigned char *alpn_protos;
	ctx = check_ctx(L, 1);
	fd = luaL_checkinteger(L, 2);
	hostname = lua_tostring(L, 3);
	alpn_protos = (const unsigned char *)luaL_optlstring(L, 4, NULL, &alpn_size);
	luaL_argcheck(L, alpn_size <= UINT_MAX, 4, "ALPN list is too large");
	tls = new_tls(L, fd);
	/* OpenSSL callbacks borrow the Lua context and its ALPN string. */
	lua_pushvalue(L, 1);
	lua_setiuservalue(L, -2, 1);
	ERR_clear_error();
	tls->ssl = SSL_new(ctx->entries[0].ptr);
	if (tls->ssl == NULL)
		goto error;
	/* A blocked write is copied out of Lua before returning to its caller. */
	SSL_set_mode(tls->ssl, SSL_MODE_ACCEPT_MOVING_WRITE_BUFFER);
	if (alpn_protos != NULL) {
		ret = SSL_set_alpn_protos(tls->ssl, alpn_protos, (unsigned int)alpn_size);
		if (ret != 0)
			goto error;
	}
	if (ctx->mode == 'C') {
		if (hostname != NULL) {
			ret = SSL_set_tlsext_host_name(tls->ssl, hostname);
			if (ret != 1)
				goto error;
		}
		SSL_set_connect_state(tls->ssl);
	} else {
		SSL_set_accept_state(tls->ssl);
	}
	in = BIO_new(BIO_s_mem());
	if (in == NULL)
		goto error;
	out = BIO_new(BIO_s_mem());
	if (out == NULL)
		goto error;
	BIO_set_mem_eof_return(in, -1);
	BIO_set_mem_eof_return(out, -1);
	SSL_set_bio(tls->ssl, in, out);
	tls->in_bio = in;
	tls->out_bio = out;
	return 1;
error:
	log_error(tls, SSL_ERROR_SSL);
	BIO_free(in);
	BIO_free(out);
	SSL_free(tls->ssl);
	tls->ssl = NULL;
	lua_pushnil(L);
	silly_push_error(L, EXTLS);
	return 2;
}

static inline int read_line(lua_State *L, struct tls *tls, int delim)
{
	uint8_t *s, *x;
	if (tls->readbuf.size == 0) {
		lua_pushnil(L);
		return 0;
	}
	s = tls->readbuf.buf + tls->readbuf.offset;
	x = memchr(s, delim, tls->readbuf.size);
	if (x == NULL) {
		lua_pushnil(L);
		return 0;
	} else {
		size_t line_size = x - s + 1;
		lua_pushlstring(L, (char *)s, line_size);
		tls->readbuf.offset += line_size;
		tls->readbuf.size -= line_size;
		return 1;
	}
}

static inline int read_bytes(lua_State *L, struct tls *tls, size_t size)
{
	if (size == 0) {
		lua_pushliteral(L, "");
		return 1;
	} else if (size > tls->readbuf.size) {
		lua_pushnil(L);
		return 0;
	} else {
		lua_pushlstring(L, (char *)(tls->readbuf.buf + tls->readbuf.offset), size);
		tls->readbuf.offset += size;
		tls->readbuf.size -= size;
		return 1;
	}
}

static int ltls_read(lua_State *L)
{
	int ok;
	lua_Integer size;
	struct luastr delim;
	struct tls *tls = check_tls(L, 1);
	switch (lua_type(L, 2)) {
	case LUA_TNUMBER:
		size = luaL_checkinteger(L, 2);
		luaL_argcheck(L, size >= 0 && size <= INT_MAX, 2, "read size exceeds native buffer range");
		ok = read_bytes(L, tls, size);
		break;
	case LUA_TSTRING:
		luastr_check(L, 2, &delim);
		luaL_argcheck(L, delim.len == 1, 2, "delimiter length must be 1");
		ok = read_line(L, tls, delim.str[0]);
		break;
	default:
		return luaL_error(L, "invalid read argument type");
	}
	if (ok) {
		tls->readwaiting = 0;
		read_update(tls);
	}
	return 1;
}

static int write_flush(struct tls *tls)
{
	int sz, n;
	size_t pending;
	uint8_t *dat;
	while ((pending = BIO_ctrl_pending(tls->out_bio)) > 0) {
		sz = (int)min(pending, (size_t)WRITE_FLUSH_SIZE);
		dat = ssl_malloc(sz);
		n = BIO_read(tls->out_bio, dat, sz);
		if (n <= 0) {
			ssl_free(dat);
			return SSL_ERROR_SSL;
		}
		/* The socket owner receives transport failures through its close event. */
		silly_tcp_send(tls->fd, dat, n, NULL);
	}
	return 0;
}

static inline void write_append(struct tls *tls, const char *data, size_t size)
{
	struct buf *buf = &tls->writebuf;
	memcpy(buf_prepsize(buf, size), data, size);
	buf->size += size;
}

static int write_data(struct tls *tls, const char *data, size_t size)
{
	int len, ret, sslerr;
	if (tls->writebuf.size > 0) {
		write_append(tls, data, size);
		return 0;
	}
	while (size > 0) {
		len = (int)min(size, (size_t)WRITE_FLUSH_SIZE);
		ERR_clear_error();
		ret = SSL_write(tls->ssl, data, len);
		if (ret <= 0) {
			sslerr = SSL_get_error(tls->ssl, ret);
			if (!TLS_WANT_IO(sslerr))
				return sslerr;
			/* Appends must not change the length of this unfinished SSL_write. */
			tls->writelen = len;
			write_append(tls, data, size);
			return 0;
		}
		/* Partial-write mode is disabled; success consumes this entire chunk. */
		data += ret;
		size -= ret;
		if (BIO_ctrl_pending(tls->out_bio) >= WRITE_FLUSH_SIZE) {
			sslerr = write_flush(tls);
			if (sslerr != SSL_ERROR_NONE)
				return sslerr;
		}
	}
	return 0;
}

static int write_drain(struct tls *tls)
{
	int ret, sslerr;
	struct buf *buf = &tls->writebuf;
	while (buf->size > 0) {
		ERR_clear_error();
		ret = SSL_write(tls->ssl, buf->buf + buf->offset, tls->writelen);
		if (ret <= 0) {
			sslerr = SSL_get_error(tls->ssl, ret);
			if (TLS_WANT_IO(sslerr))
				return 0;
			return sslerr;
		}
		buf->offset += ret;
		buf->size -= ret;
		tls->writelen = (int)min(buf->size, (size_t)WRITE_FLUSH_SIZE);
		if (BIO_ctrl_pending(tls->out_bio) >= WRITE_FLUSH_SIZE) {
			sslerr = write_flush(tls);
			if (sslerr != SSL_ERROR_NONE)
				return sslerr;
		}
	}
	write_clear(tls);
	return 0;
}

static int ltls_close(lua_State *L)
{
	int ret, sslerr, err;
	struct tls *tls = check_tls(L, 1);
	err = tls->err;
	if (tls->ssl != NULL) {
		/* Make a final attempt without waiting for more peer input. */
		if (err == SSL_ERROR_NONE) {
			err = write_drain(tls);
			if (err != SSL_ERROR_NONE)
				log_error(tls, err);
		}
		/* Pending plaintext must be drained before sending close_notify. */
		if (!TLS_HAS_ERROR(err) && tls->writebuf.size == 0 && !SSL_in_init(tls->ssl)) {
			ERR_clear_error();
			ret = SSL_shutdown(tls->ssl);
			/* Zero means our close_notify was sent; do not wait for the reply. */
			if (ret < 0) {
				sslerr = SSL_get_error(tls->ssl, ret);
				if (!TLS_WANT_IO(sslerr)) {
					err = sslerr;
					log_error(tls, err);
				}
			}
		}
		sslerr = write_flush(tls);
		if (sslerr != SSL_ERROR_NONE && !TLS_HAS_ERROR(err)) {
			err = sslerr;
			log_error(tls, err);
		}
		SSL_free(tls->ssl);
		tls->ssl = NULL;
	}
	lua_pushnil(L);
	lua_setiuservalue(L, 1, 1);
	tls->readwaiting = 0;
	buf_destroy(&tls->readbuf);
	buf_destroy(&tls->writebuf);
	tls->writelen = 0;
	if (!TLS_HAS_ERROR(err) || err == TLS_ERROR_CLOSED) {
		tls->err = TLS_ERROR_CLOSED;
		lua_pushnil(L);
	} else {
		tls->err = err;
		silly_push_error(L, tls_error(err));
	}
	return 1;
}

static int ltls_write(lua_State *L)
{
	size_t sz;
	struct tls *tls;
	const char *str;
	int type, sslerr;
	int err = SSL_ERROR_NONE;
	tls = check_tls(L, 1);
	type = lua_type(L, 2);
	if (type != LUA_TSTRING && type != LUA_TTABLE)
		return luaL_error(L, "invalid data type");
	if (TLS_HAS_ERROR(tls->err)) {
		lua_pushboolean(L, 0);
		silly_push_error(L, tls_error(tls->err));
		return 2;
	}
	switch (type) {
	case LUA_TSTRING:
		str = luaL_checklstring(L, 2, &sz);
		if (sz > 0)
			err = write_data(tls, str, sz);
		break;
	case LUA_TTABLE: {
		lua_Integer i, n;
		n = luaL_len(L, 2);
		luaL_argcheck(L, n > 0, 2, "table must not be empty");
		for (i = 1; i <= n; i++) {
			lua_geti(L, 2, i);
			str = luaL_checklstring(L, -1, &sz);
			if (sz > 0)
				err = write_data(tls, str, sz);
			lua_pop(L, 1);
			if (err != SSL_ERROR_NONE)
				break;
		}
		break;
	}
	}
	if (err != SSL_ERROR_NONE)
		log_error(tls, err);
	sslerr = write_flush(tls);
	if (sslerr != SSL_ERROR_NONE && !TLS_HAS_ERROR(err)) {
		err = sslerr;
		log_error(tls, err);
	}
	if (err != SSL_ERROR_NONE)
		tls->err = err;
	read_update(tls);
	lua_pushboolean(L, err == SSL_ERROR_NONE);
	if (err != SSL_ERROR_NONE) {
		write_clear(tls);
		silly_push_error(L, tls_error(tls->err));
	} else {
		lua_pushnil(L);
	}
	return 2;
}

static int ltls_handshake(lua_State *L)
{
	int ret, sslerr;
	int err = SSL_ERROR_NONE;
	struct tls *tls = check_tls(L, 1);
	if (TLS_HAS_ERROR(tls->err)) {
		lua_pushinteger(L, 0);
		silly_push_error(L, tls_error(tls->err));
		return 2;
	}
	ERR_clear_error();
	ret = SSL_do_handshake(tls->ssl);
	if (ret <= 0) {
		sslerr = SSL_get_error(tls->ssl, ret);
		if (!TLS_WANT_IO(sslerr))
			err = sslerr;
	}
	if (err != SSL_ERROR_NONE)
		log_error(tls, err);
	sslerr = write_flush(tls);
	if (sslerr != SSL_ERROR_NONE && !TLS_HAS_ERROR(err)) {
		err = sslerr;
		log_error(tls, err);
	}
	if (err != SSL_ERROR_NONE)
		tls->err = err;
	if (TLS_HAS_ERROR(tls->err) || (ret != 1 && tls->err != SSL_ERROR_NONE))
		ret = 0;
	else if (ret != 1)
		ret = -1;
	if (ret == 1)
		tls->readwaiting = 0;
	read_update(tls);
	lua_pushinteger(L, ret);
	if (ret == 0) {
		silly_push_error(L, tls_error(tls->err));
	} else if (ret == 1) {
		unsigned int len;
		const unsigned char *data;
		SSL_get0_alpn_selected(tls->ssl, &data, &len);
		lua_pushlstring(L, (const char *)data, len);
	} else {
		lua_pushnil(L);
	}
	return 2;
}

static int ltls_push(lua_State *L)
{
	struct tls *tls;
	struct buf *buf;
	char *str;
	lua_Integer input_size;
	int size, n, sslerr;
	int err = SSL_ERROR_NONE;
	tls = check_tls(L, 1);
	luaL_checktype(L, 2, LUA_TLIGHTUSERDATA);
	input_size = luaL_checkinteger(L, 3);
	luaL_argcheck(L, input_size >= 0 && input_size <= INT_MAX, 3, "invalid input size");
	buf = &tls->readbuf;
	str = lua_touserdata(L, 2);
	size = (int)input_size;
	luaL_argcheck(L, str != NULL || size == 0, 2, "null data pointer");
	if (tls->err != SSL_ERROR_NONE) {
		silly_free(str);
		silly_push_error(L, tls_error(tls->err));
		return 1;
	}
	/* Feed peer input before retrying writes blocked on SSL_ERROR_WANT_READ. */
	ERR_clear_error();
	n = BIO_write(tls->in_bio, str, size);
	silly_free(str);
	if (n != size) {
		err = SSL_ERROR_SSL;
		goto end;
	}
	err = write_drain(tls);
	if (err != SSL_ERROR_NONE)
		goto end;
	for (;;) {
		uint8_t *s;
		size_t available;
		s = buf_prepsize(buf, BUF_SIZE);
		available = buf->cap - buf->offset - buf->size;
		ERR_clear_error();
		n = SSL_read(tls->ssl, s, (int)min(available, (size_t)INT_MAX));
		if (n <= 0) {
			sslerr = SSL_get_error(tls->ssl, n);
			break;
		}
		buf->size += n;
	}
	if (sslerr == SSL_ERROR_ZERO_RETURN) {
		err = sslerr;
		/* Reading may have completed the handshake that blocked this write. */
		sslerr = write_drain(tls);
		if (sslerr != SSL_ERROR_NONE)
			err = sslerr;
	} else if (!TLS_WANT_IO(sslerr)) {
		err = sslerr;
	}
end:
	/* Reads may generate handshake messages, alerts or KeyUpdate responses. */
	if (err != SSL_ERROR_NONE)
		log_error(tls, err);
	sslerr = write_flush(tls);
	if (sslerr != SSL_ERROR_NONE && !TLS_HAS_ERROR(err)) {
		err = sslerr;
		log_error(tls, err);
	}
	if (err != SSL_ERROR_NONE)
		tls->err = err;
	if (tls->err != SSL_ERROR_NONE) {
		write_clear(tls);
		silly_push_error(L, tls_error(tls->err));
	} else {
		lua_pushnil(L);
	}
	read_update(tls);
	return 1;
}

static int ltls_limit(lua_State *L)
{
	lua_Integer limit = -1;
	struct tls *tls = check_tls(L, 1);
	if (!lua_isnoneornil(L, 2)) {
		limit = luaL_checkinteger(L, 2);
		luaL_argcheck(L, limit >= 0 && limit <= INT_MAX, 2, "invalid receive limit");
	}
	tls->readlimit = (int)limit;
	lua_pushboolean(L, read_update(tls));
	return 1;
}

static int ltls_readwait(lua_State *L)
{
	struct tls *tls = check_tls(L, 1);
	if (tls->err != SSL_ERROR_NONE) {
		silly_push_error(L, tls_error(tls->err));
		return 1;
	}
	tls->readwaiting = 1;
	read_update(tls);
	lua_pushnil(L);
	return 1;
}

static int ltls_readcancel(lua_State *L)
{
	struct tls *tls = check_tls(L, 1);
	tls->readwaiting = 0;
	read_update(tls);
	return 0;
}

static int ltls_size(lua_State *L)
{
	struct tls *tls = check_tls(L, 1);
	lua_pushinteger(L, tls->readbuf.size);
	return 1;
}

static int ltls_sendsize(lua_State *L)
{
	lua_Integer size = 0;
	struct tls *tls = check_tls(L, 1);
	if (tls->ssl != NULL)
		size = (lua_Integer)tls->writebuf.size + silly_socket_sendsize(tls->fd);
	lua_pushinteger(L, size);
	return 1;
}

#ifdef SILLY_TEST
static int dbg_error(lua_State *L)
{
	struct tls *tls = check_tls(L, 1);
	silly_push_error(L, tls_error(tls->err));
	return 1;
}

static int dbg_ininit(lua_State *L)
{
	struct tls *tls = check_tls(L, 1);
	lua_pushboolean(L, tls->ssl != NULL && SSL_in_init(tls->ssl));
	return 1;
}

static int dbg_readenabled(lua_State *L)
{
	struct tls *tls = check_tls(L, 1);
	lua_pushboolean(L, tls->readenabled);
	return 1;
}

static int dbg_writecap(lua_State *L)
{
	struct tls *tls = check_tls(L, 1);
	lua_pushinteger(L, tls->writebuf.cap);
	return 1;
}

static int dbg_writebuf(lua_State *L)
{
	size_t size;
	const char *data;
	struct tls *tls = check_tls(L, 1);
	data = luaL_checklstring(L, 2, &size);
	luaL_argcheck(L, size > 0, 2, "invalid queued write size");
	luaL_argcheck(L, tls->writebuf.size == 0, 1, "write buffer is not empty");
	write_append(tls, data, size);
	tls->writelen = (int)min(size, (size_t)WRITE_FLUSH_SIZE);
	return 0;
}

static int dbg_readsize(lua_State *L)
{
	struct tls *tls;
	lua_Integer size;
	tls = check_tls(L, 1);
	size = luaL_checkinteger(L, 2);
	luaL_argcheck(L, size >= 0 && (lua_Unsigned)size <= SIZE_MAX, 2, "invalid buffer size");
	lua_pushinteger(L, tls->readbuf.size);
	tls->readbuf.size = size;
	return 1;
}

static int dbg_readcap(lua_State *L)
{
	struct tls *tls = check_tls(L, 1);
	lua_pushinteger(L, tls->readbuf.cap);
	return 1;
}
#endif

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
	luaL_newlib(L, tbl);

#ifdef USE_OPENSSL
	luaL_newmetatable(L, META_CTX);
	lua_pushvalue(L, -2);
	lua_setfield(L, -2, "__index");
	lua_pushcfunction(L, lctx_free);
	lua_setfield(L, -2, "__gc");
	lua_pop(L, 1);
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
		{ "open",            ltls_open       },
		{ "close",           ltls_close      },
		{ "read",            ltls_read       },
		{ "write",           ltls_write      },
		{ "handshake",       ltls_handshake  },
		{ "push",            ltls_push       },
		{ "size",            ltls_size       },
		{ "sendsize",        ltls_sendsize   },
		{ "limit",           ltls_limit      },
		{ "readwait",        ltls_readwait   },
		{ "readcancel",      ltls_readcancel },
#ifdef SILLY_TEST
		{ "dbg_error",       dbg_error       },
		{ "dbg_ininit",      dbg_ininit      },
		{ "dbg_readenabled", dbg_readenabled },
		{ "dbg_writecap",    dbg_writecap    },
		{ "dbg_writebuf",    dbg_writebuf    },
		{ "dbg_readsize",    dbg_readsize    },
		{ "dbg_readcap",     dbg_readcap     },
#endif
#endif
		{ NULL,              NULL            },
	};

	luaL_newlib(L, tbl);
#ifdef USE_OPENSSL
	luaL_newmetatable(L, META_TLS);
	lua_pushvalue(L, -2);
	lua_setfield(L, -2, "__index");
	lua_pushcfunction(L, ltls_free);
	lua_setfield(L, -2, "__gc");
	lua_pop(L, 1);
#endif
	return 1;
}
