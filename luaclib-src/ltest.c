#include <unistd.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>
#include "silly.h"
#include "platform.h" // Include platform.h only for typedef definitions
#ifdef USE_OPENSSL
#include <openssl/ssl.h>
#include <openssl/pem.h>
#include <openssl/err.h>
#endif

static int lnew(lua_State *L)
{
	size_t sz;
	const char *src = luaL_checklstring(L, 1, &sz);
	void *dat = silly_malloc(sz);
	memcpy(dat, src, sz);
	lua_pushlightuserdata(L, dat);
	lua_pushinteger(L, sz);
	return 2;
}

static int llisten(lua_State *L)
{
	const char *host = luaL_checkstring(L, 1);
	lua_Integer portnum = luaL_checkinteger(L, 2);
	if (portnum < 0 || portnum > 65535)
		return luaL_error(L, "port number out of range");
	int port = (int)portnum;
	lua_Integer backlognum = luaL_checkinteger(L, 3);
	if (backlognum < 0 || backlognum > INT_MAX)
		return luaL_error(L, "backlog number out of range");
	int backlog = (int)backlognum;

	fd_t fd = socket(AF_INET, SOCK_STREAM, 0);
	if (fd < 0) {
		return luaL_error(L, "socket error:%s", strerror(errno));
	}
	int reuse = 1;
	if (setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, (const char *)&reuse,
		       sizeof(int)) < 0) {
		closesocket(fd);
		return luaL_error(L, "setsockopt reuseaddr error:%s",
				  strerror(errno));
	}
	struct sockaddr_in addr;
	memset(&addr, 0, sizeof(addr));
	addr.sin_family = AF_INET;
	addr.sin_port = htons((uint16_t)port);
	addr.sin_addr.s_addr = inet_addr(host);
	if (addr.sin_addr.s_addr == INADDR_NONE) {
		struct addrinfo hints, *result;
		memset(&hints, 0, sizeof(hints));
		hints.ai_family = AF_INET;
		hints.ai_socktype = SOCK_STREAM;
		if (getaddrinfo(host, NULL, &hints, &result) != 0) {
			closesocket(fd);
			return luaL_error(L,
					  "getaddrinfo error for host %s: %s",
					  host, gai_strerror(errno));
		}
		addr.sin_addr =
			((struct sockaddr_in *)result->ai_addr)->sin_addr;
		freeaddrinfo(result);
	}
	if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
		closesocket(fd);
		return luaL_error(L, "bind error:%s", strerror(errno));
	}
	if (listen(fd, backlog) < 0) {
		closesocket(fd);
		return luaL_error(L, "listen error:%s", strerror(errno));
	}
	lua_pushinteger(L, fd);
	return 1;
}

static int lconnect(lua_State *L)
{
	struct sockaddr_in addr;
	const char *host = luaL_checkstring(L, 1);
	uint16_t port = (uint16_t)luaL_checkinteger(L, 2);
	fd_t fd = socket(AF_INET, SOCK_STREAM, 0);
	if (fd < 0) {
		return luaL_error(L, "socket error:%s", strerror(errno));
	}
	memset(&addr, 0, sizeof(addr));
	addr.sin_addr.s_addr = inet_addr(host);
	if (addr.sin_addr.s_addr == INADDR_NONE) {
		struct addrinfo hints, *result;
		memset(&hints, 0, sizeof(hints));
		hints.ai_family = AF_INET;
		hints.ai_socktype = SOCK_STREAM;
		if (getaddrinfo(host, NULL, &hints, &result) != 0) {
			closesocket(fd);
			return luaL_error(L,
					  "getaddrinfo error for host %s: %s",
					  host, gai_strerror(errno));
		}
		addr.sin_addr =
			((struct sockaddr_in *)result->ai_addr)->sin_addr;
		freeaddrinfo(result);
	}
	addr.sin_family = AF_INET;
	addr.sin_port = htons(port);
	if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
		closesocket(fd);
		return luaL_error(L, "connect error:%s", strerror(errno));
	}
	lua_pushinteger(L, fd);
	return 1;
}

static int lgetsockname(lua_State *L)
{
	fd_t fd = (fd_t)luaL_checkinteger(L, 1);
	struct sockaddr_in addr;
	socklen_t len = sizeof(addr);
	if (getsockname(fd, (struct sockaddr *)&addr, &len) < 0) {
		return luaL_error(L, "getsockname error:%s", strerror(errno));
	}
	char ip_str[INET_ADDRSTRLEN];
	if (inet_ntop(addr.sin_family, &addr.sin_addr, ip_str,
		      sizeof(ip_str)) == NULL) {
		return luaL_error(L, "inet_ntop error:%s", strerror(errno));
	}
	lua_pushfstring(L, "%s:%d", ip_str, ntohs(addr.sin_port));
	return 1;
}

static int lsetrecvbuf(lua_State *L)
{
	fd_t fd = (fd_t)luaL_checkinteger(L, 1);
	int size = (int)luaL_checkinteger(L, 2);
	if (setsockopt(fd, SOL_SOCKET, SO_RCVBUF, (const char *)&size,
		       sizeof(int)) < 0) {
		return luaL_error(L, "setsockopt rcvbuf error:%s",
				  strerror(errno));
	}
	return 0;
}

static int lsetsendbuf(lua_State *L)
{
	fd_t fd = (fd_t)luaL_checkinteger(L, 1);
	int size = (int)luaL_checkinteger(L, 2);
	if (setsockopt(fd, SOL_SOCKET, SO_SNDBUF, (const char *)&size,
		       sizeof(int)) < 0) {
		return luaL_error(L, "setsockopt sndbuf error:%s",
				  strerror(errno));
	}
	return 0;
}

static int lrecv(lua_State *L)
{
	fd_t fd = (fd_t)luaL_checkinteger(L, 1);
	size_t len = luaL_checkinteger(L, 2);
	luaL_Buffer b;
	char *buf = luaL_buffinitsize(L, &b, len);
	if (len > SSIZE_MAX) {
		return luaL_error(L, "length too large");
	}
	size_t left = len;
	while (left > 0) {
		ssize_t received = recv(fd, buf, left, 0);
		if (received < 0) {
			if (errno == EINTR) {
				continue; // Retry on interrupt
			}
			return luaL_error(L, "recv error:%s", strerror(errno));
		} else if (received == 0) {
			break; // Connection closed
		}
		buf += received;
		left -= received;
	}
	luaL_pushresultsize(&b, len - left);
	return 1;
}

static int lsend(lua_State *L)
{
	size_t len, left;
	fd_t fd = (fd_t)luaL_checkinteger(L, 1);
	const char *data = luaL_checklstring(L, 2, &len);
	left = len;
	while (left > 0) {
		ssize_t sent = send(fd, data, left, 0);
		if (sent < 0) {
			return luaL_error(L, "send error:%s", strerror(errno));
		}
		data += sent;
		left -= sent;
	}
	lua_pushinteger(L, len - left);
	return 1;
}

static int laccept(lua_State *L)
{
	int listenfd = (int)luaL_checkinteger(L, 1);
	struct sockaddr_in client_addr;
	socklen_t addr_len = sizeof(client_addr);
	int clientfd =
		accept(listenfd, (struct sockaddr *)&client_addr, &addr_len);
	if (clientfd < 0) {
		return luaL_error(L, "accept error:%s", strerror(errno));
	}
	lua_pushinteger(L, clientfd);
	return 1;
}

static int lshutdown(lua_State *L)
{
	fd_t fd = (fd_t)luaL_checkinteger(L, 1);
	int how = (int)luaL_checkinteger(
		L, 2); // 0 for SHUT_RD, 1 for SHUT_WR, 2 for SHUT_RDWR
	if (shutdown(fd, how) < 0) {
		return luaL_error(L, "shutdown error:%s", strerror(errno));
	}
	return 0;
}

static int lclose(lua_State *L)
{
	fd_t fd = (fd_t)luaL_checkinteger(L, 1);
	closesocket(fd);
	return 0;
}

static int lpointer(lua_State *L)
{
	const void *ptr = lua_topointer(L, 1);
	lua_pushlightuserdata(L, (void *)ptr);
	return 1;
}

#ifdef USE_OPENSSL
/* Blocking TLS 1.2 peer, run in a Hive worker while the client uses the event loop. */
static int ltlsreneg(lua_State *L)
{
	int fd, control, n, left, sslerr, prefix;
	char command;
	size_t cert_size, key_size;
	const char *cert_data, *key_data;
	const char *error = NULL;
	SSL_CTX *ctx = NULL;
	SSL *ssl = NULL;
	BIO *bio = NULL;
	X509 *cert = NULL;
	EVP_PKEY *key = NULL;
	luaL_Buffer buffer;
	char *data;
#ifdef _WIN32
	int timeout = 5000;
#else
	struct timeval timeout = {5, 0};
#endif
	fd = luaL_checkinteger(L, 1);
	control = luaL_checkinteger(L, 2);
	cert_data = luaL_checklstring(L, 3, &cert_size);
	key_data = luaL_checklstring(L, 4, &key_size);
	left = luaL_checkinteger(L, 5);
	prefix = lua_toboolean(L, 6);
	luaL_argcheck(L, left > 0, 5, "expected data must not be empty");
	data = luaL_buffinitsize(L, &buffer, left);
	if (setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, (const char *)&timeout, sizeof(timeout)) != 0 ||
	    setsockopt(control, SOL_SOCKET, SO_RCVTIMEO, (const char *)&timeout, sizeof(timeout)) != 0) {
		error = "TLS peer receive deadline setup failed";
		goto done;
	}
	ctx = SSL_CTX_new(TLS_method());
	if (ctx == NULL) {
		error = "SSL_CTX_new failed";
		goto done;
	}
	SSL_CTX_set_min_proto_version(ctx, TLS1_2_VERSION);
	SSL_CTX_set_max_proto_version(ctx, TLS1_2_VERSION);
	bio = BIO_new_mem_buf(cert_data, cert_size);
	cert = PEM_read_bio_X509(bio, NULL, NULL, NULL);
	BIO_free(bio);
	bio = BIO_new_mem_buf(key_data, key_size);
	key = PEM_read_bio_PrivateKey(bio, NULL, NULL, NULL);
	BIO_free(bio);
	if (cert == NULL || key == NULL || SSL_CTX_use_certificate(ctx, cert) != 1 ||
	    SSL_CTX_use_PrivateKey(ctx, key) != 1) {
		error = "TLS peer certificate setup failed";
		goto done;
	}
	ssl = SSL_new(ctx);
	if (ssl == NULL || SSL_set_fd(ssl, fd) != 1 || SSL_accept(ssl) != 1) {
		error = "TLS peer handshake failed";
		goto done;
	}
	if (prefix) {
		if (SSL_read(ssl, &command, 1) != 1 || command != 'p' || SSL_write(ssl, "p", 1) != 1) {
			error = "TLS peer initial application data exchange failed";
			goto done;
		}
	}
	/* The client installs its observer after the initial handshake. */
	if (recv(control, &command, 1, 0) != 1 || command != 'r') {
		error = "TLS peer start barrier failed";
		goto done;
	}
	if (SSL_renegotiate(ssl) != 1 || SSL_do_handshake(ssl) != 1) {
		error = "TLS peer renegotiation failed";
		goto done;
	}
	/* Hold the server flight until all client writes have been attempted. */
	if (recv(control, &command, 1, 0) != 1) {
		error = "TLS peer write barrier failed";
		goto done;
	}
	if (command == 'a') {
		goto done;
	}
	if (command == 'f') {
		const char bad[] = {0x17, 0x03, 0x03, 0x00, 0x01, (char)0xff};
		if (send(fd, bad, sizeof(bad), 0) != sizeof(bad))
			error = "TLS peer corrupt record send failed";
		goto done;
	}
	if (command == 'e') {
		if (SSL_shutdown(ssl) < 0)
			error = "TLS peer close_notify failed";
		goto done;
	}
	if (command == 't') {
		char raw[4096];
		while ((n = recv(fd, raw, sizeof(raw), 0)) > 0) {
		}
		if (n < 0 || send(control, "d", 1, 0) != 1)
			error = "TLS peer did not observe connection close";
		goto done;
	}
	while (left > 0) {
		n = SSL_read(ssl, data, left);
		if (n <= 0) {
			error = "TLS peer read failed";
			goto done;
		}
		data += n;
		left -= n;
	}
	if (command == 'w' && SSL_write(ssl, "ok", 2) != 2) {
		error = "TLS peer response failed";
		goto done;
	}
	if (send(control, "d", 1, 0) != 1) {
		error = "TLS peer completion barrier failed";
		goto done;
	}
	ERR_clear_error();
	errno = 0;
	n = SSL_read(ssl, &command, 1);
	sslerr = SSL_get_error(ssl, n);
	if (n > 0) {
		error = "TLS peer received unexpected trailing data";
	} else if (sslerr == SSL_ERROR_WANT_READ || sslerr == SSL_ERROR_WANT_WRITE ||
		   (sslerr == SSL_ERROR_SYSCALL && errno == ETIMEDOUT)) {
		error = "TLS peer did not observe connection close";
	}
#ifdef _WIN32
	if (sslerr == SSL_ERROR_SYSCALL && WSAGetLastError() == WSAETIMEDOUT)
		error = "TLS peer did not observe connection close";
#endif
done:
	SSL_free(ssl);
	SSL_CTX_free(ctx);
	X509_free(cert);
	EVP_PKEY_free(key);
	luaL_pushresultsize(&buffer, luaL_checkinteger(L, 5) - left);
	if (error != NULL) {
		lua_pop(L, 1);
		lua_pushnil(L);
		lua_pushstring(L, error);
		return 2;
	}
	return 1;
}
#endif

#ifdef SILLY_TEST
static int writev_lua_ref = LUA_NOREF;
static lua_State *hook_lua_state = NULL;
static THREAD_LOCAL int is_worker_thread = 0;

static struct {
	int error_nth;
	int error_errno;
	int partial_bytes;
	int hook_disabled;
} log_test_state = {0};

static ssize_t hook_writev_impl(int fd, const struct iovec *iov, int iovcnt) {
	if (log_test_state.hook_disabled)
		return writev(fd, iov, iovcnt);

	if (!iov || iovcnt < 0)
		return writev(fd, iov, iovcnt);

	if (writev_lua_ref == LUA_NOREF || !hook_lua_state)
		return writev(fd, iov, iovcnt);

	// All test behavior below is worker-thread only.
	// Non-worker threads pass through to avoid consuming error_nth,
	// corrupting Lua state, or deadlocking on LB->lock.
	if (!is_worker_thread) {
		fprintf(stderr, "[ltest] warning: log.hook called from non-worker thread, bypassing Lua callback\n");
		return writev(fd, iov, iovcnt);
	}

	if (log_test_state.error_nth > 0) {
		if (--log_test_state.error_nth == 0) {
			errno = log_test_state.error_errno;
			return -1;
		}
	}

	if (!lua_checkstack(hook_lua_state, 4))
		return writev(fd, iov, iovcnt);

	size_t total = 0;
	for (int i = 0; i < iovcnt; i++) {
		if (iov[i].iov_len > SIZE_MAX - total) {
			errno = EINVAL;
			return -1;
		}
		total += iov[i].iov_len;
	}

	char *merged = silly_malloc(total);
	size_t pos = 0;
	for (int i = 0; i < iovcnt; i++) {
		memcpy(merged + pos, iov[i].iov_base, iov[i].iov_len);
		pos += iov[i].iov_len;
	}

	ssize_t write_bytes;
	if (log_test_state.partial_bytes > 0) {
		write_bytes = min((size_t)log_test_state.partial_bytes, total);
	} else {
		write_bytes = (ssize_t)total;
	}

	lua_rawgeti(hook_lua_state, LUA_REGISTRYINDEX, writev_lua_ref);
	lua_pushinteger(hook_lua_state, fd);
	lua_pushlstring(hook_lua_state, merged, total);
	lua_pushinteger(hook_lua_state, write_bytes);

	if (lua_pcall(hook_lua_state, 3, 1, 0) == LUA_OK) {
		int result = lua_tointeger(hook_lua_state, -1);
		lua_pop(hook_lua_state, 1);
		silly_free(merged);
		return result;
	}
	lua_pop(hook_lua_state, 1);
	silly_free(merged);
	log_test_state.hook_disabled = 1;

	return writev(fd, iov, iovcnt);
}

static int ldebugctrl(lua_State *L)
{
	const char *cmd = luaL_checkstring(L, 1);
	if (strcmp(cmd, "socket.conf") == 0) {
		luaL_checktype(L, 2, LUA_TTABLE);
		lua_pushnil(L);
		while (lua_next(L, 2) != 0) {
			const char *key = lua_tostring(L, -2);
			int val;
			if (lua_isboolean(L, -1))
				val = lua_toboolean(L, -1);
			else
				val = (int)lua_tointeger(L, -1);
			silly_debug_ctrl("socket.conf", key, val);
			lua_pop(L, 1);
		}
		silly_debug_ctrl("socket.apply");
	} else if (strcmp(cmd, "socket.reset") == 0) {
		silly_debug_ctrl("socket.reset");
	} else if (strcmp(cmd, "socket.kick") == 0) {
		silly_debug_ctrl("socket.kick");
	} else if (strcmp(cmd, "log.capture") == 0) {
		luaL_checktype(L, 2, LUA_TFUNCTION);
		if (!hook_lua_state)
			hook_lua_state = L;
		is_worker_thread = 1;
		if (writev_lua_ref != LUA_NOREF)
			luaL_unref(L, LUA_REGISTRYINDEX, writev_lua_ref);
		lua_pushvalue(L, 2);
		writev_lua_ref = luaL_ref(L, LUA_REGISTRYINDEX);
		silly_debug_ctrl("log.hook", hook_writev_impl);
	} else if (strcmp(cmd, "log.unhook") == 0) {
		silly_debug_ctrl("log.unhook");
		if (writev_lua_ref != LUA_NOREF) {
			luaL_unref(L, LUA_REGISTRYINDEX, writev_lua_ref);
			writev_lua_ref = LUA_NOREF;
		}
	} else if (strcmp(cmd, "log.exception") == 0) {
		int nth = (int)luaL_checkinteger(L, 2);
		int error = (int)luaL_optinteger(L, 3, 5);
		log_test_state.error_nth = nth;
		log_test_state.error_errno = error;
	} else if (strcmp(cmd, "log.partial") == 0) {
		log_test_state.partial_bytes = (int)luaL_checkinteger(L, 2);
	} else if (strcmp(cmd, "log.reset") == 0) {
		log_test_state.error_nth = 0;
		log_test_state.error_errno = 0;
		log_test_state.partial_bytes = 0;
		silly_debug_ctrl("log.reset");
	} else if (strcmp(cmd, "log.flush") == 0) {
		silly_debug_ctrl("log.flush");
	} else if (strcmp(cmd, "log.flushoff") == 0) {
		silly_debug_ctrl("log.flushoff");
	} else if (strcmp(cmd, "log.flushon") == 0) {
		silly_debug_ctrl("log.flushon");
	} else {
		return luaL_error(L, "unknown debugctrl command: %s", cmd);
	}
	return 0;
}
#endif

SILLY_MOD_API int luaopen_test_aux_c(lua_State *L)
{
	luaL_Reg tbl[] = {
		{ "new",         lnew         },
		{ "listen",      llisten      },
		{ "accept",      laccept      },
		{ "shutdown",    lshutdown    },
		{ "connect",     lconnect     },
		{ "getsockname", lgetsockname },
		{ "setrecvbuf",  lsetrecvbuf  },
		{ "setsendbuf",  lsetsendbuf  },
		{ "send",        lsend        },
		{ "recv",        lrecv        },
		{ "close",       lclose       },
		{ "pointer",     lpointer     },
	#ifdef USE_OPENSSL
		{ "tlsreneg",    ltlsreneg    },
	#endif
	#ifdef SILLY_TEST
		{ "debugctrl",   ldebugctrl   },
	#endif
		{ NULL,          NULL         },
	};

	luaL_checkversion(L);
	luaL_newlibtable(L, tbl);
	luaL_setfuncs(L, tbl, 0);
	return 1;
}
