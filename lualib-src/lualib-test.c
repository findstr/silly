#define _XOPEN_SOURCE 600
#include <stdlib.h>
#include <string.h>
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>
#include <stdio.h>
#include <errno.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <limits.h>


#include "silly.h"

static int lmsggc(lua_State *L)
{
	struct silly_message_socket *sm;
	sm = tosocket(luaL_checkudata(L, 1, "sillymessage"));
	int type = sm->type;
	if (type == SILLY_SDATA || type == SILLY_SUDP)
		silly_free(tosocket(sm)->data);
	return 0;
}

static struct silly_message *newmsg(lua_State *L, size_t sz)
{
	struct silly_message *sm = lua_newuserdatauv(L, sz, 0);
	if (luaL_newmetatable(L, "sillymessage")) {
		lua_pushcfunction(L, lmsggc);
		lua_setfield(L, -2, "__gc");
	}
	lua_setmetatable(L, -2);
	return sm;
}

static int lnewdatamsg(lua_State *L)
{
	size_t sz;
	struct silly_message_socket *sm;
	int64_t sid = luaL_checkinteger(L, 1);
	const char *buff = luaL_checklstring(L, 2, &sz);
	sm = tosocket(newmsg(L, sizeof(*sm)));
	sm->type = SILLY_SDATA;
	sm->sid = sid;
	sm->ud = sz;
	sm->data = silly_malloc(sz);
	memcpy(sm->data, buff, sz);
	return 1;
};

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

	int fd = socket(AF_INET, SOCK_STREAM, 0);
	if (fd < 0) {
		return luaL_error(L, "socket error:%s", strerror(errno));
	}
	int reuse = 1;
	if (setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(int)) < 0) {
		close(fd);
		return luaL_error(L, "setsockopt reuseaddr error:%s", strerror(errno));
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
			close(fd);
			return luaL_error(L, "getaddrinfo error for host %s: %s", host, gai_strerror(errno));
		}
		addr.sin_addr = ((struct sockaddr_in *)result->ai_addr)->sin_addr;
		freeaddrinfo(result);
	}
	if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
		close(fd);
		return luaL_error(L, "bind error:%s", strerror(errno));
	}
	if (listen(fd, backlog) < 0) {
		close(fd);
		return luaL_error(L, "listen error:%s", strerror(errno));
	}
	lua_pushinteger(L, fd);
	return 1;
}

static int
lconnect(lua_State *L)
{
	struct sockaddr_in addr;
	const char *host = luaL_checkstring(L, 1);
	uint16_t port = (uint16_t)luaL_checkinteger(L, 2);
	int fd = socket(AF_INET, SOCK_STREAM, 0);
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
			close(fd);
			return luaL_error(L, "getaddrinfo error for host %s: %s", host, gai_strerror(errno));
		}
		addr.sin_addr = ((struct sockaddr_in *)result->ai_addr)->sin_addr;
		freeaddrinfo(result);
	}
	addr.sin_family = AF_INET;
	addr.sin_port = htons(port);
	if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
		close(fd);
		return luaL_error(L, "connect error:%s", strerror(errno));
	}
	lua_pushinteger(L, fd);
	return 1;
}

static int
lgetsockname(lua_State *L)
{
	int fd = (int)luaL_checkinteger(L, 1);
	struct sockaddr_in addr;
	socklen_t len = sizeof(addr);
	if (getsockname(fd, (struct sockaddr *)&addr, &len) < 0) {
		return luaL_error(L, "getsockname error:%s", strerror(errno));
	}
	char ip_str[INET_ADDRSTRLEN];
	if (inet_ntop(addr.sin_family, &addr.sin_addr, ip_str, sizeof(ip_str)) == NULL) {
		return luaL_error(L, "inet_ntop error:%s", strerror(errno));
	}
	lua_pushfstring(L, "%s:%d", ip_str, ntohs(addr.sin_port));
	return 1;
}

static int
lsetrecvbuf(lua_State *L)
{
	int fd = (int)luaL_checkinteger(L, 1);
	int size = (int)luaL_checkinteger(L, 2);
	if (setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, sizeof(int)) < 0) {
		return luaL_error(L, "setsockopt rcvbuf error:%s", strerror(errno));
	}
	return 0;
}

static int
lsetsendbuf(lua_State *L)
{
	int fd = (int)luaL_checkinteger(L, 1);
	int size = (int)luaL_checkinteger(L, 2);
	if (setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, sizeof(int)) < 0) {
		return luaL_error(L, "setsockopt sndbuf error:%s", strerror(errno));
	}
	return 0;
}


static int
lrecv(lua_State *L)
{
	int fd = (int)luaL_checkinteger(L, 1);
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
	luaL_pushresultsize(&b, len);
	return 1;
}

static int
lsend(lua_State *L)
{
	size_t len;
	int fd = (int)luaL_checkinteger(L, 1);
	const char *data = luaL_checklstring(L, 2, &len);
	ssize_t sent = send(fd, data, len, 0);
	if (sent < 0) {
		return luaL_error(L, "send error:%s", strerror(errno));
	}
	lua_pushinteger(L, sent);
	return 1;
}

static int
lclose(lua_State *L)
{
	int fd = (int)luaL_checkinteger(L, 1);
	close(fd);
	return 0;
}

int luaopen_test_aux_c(lua_State *L)
{
	luaL_Reg tbl[] = {
		{ "newdatamsg", lnewdatamsg },
		{ "listen", llisten },
		{ "connect", lconnect },
		{ "getsockname", lgetsockname},
		{ "setrecvbuf", lsetrecvbuf },
		{ "setsendbuf", lsetsendbuf },
		{ "send", lsend},
		{ "recv", lrecv},
		{ "close", lclose },
		{ NULL,         NULL        },
	};

	luaL_checkversion(L);
	luaL_newlibtable(L, tbl);
	luaL_setfuncs(L, tbl, 0);
	return 1;
}
