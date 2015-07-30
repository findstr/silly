#include <stdio.h>
#include <assert.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <string.h>
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>

static int
_connect(lua_State *L)
{
        int s;
        int err;
        const char *ip;
        int port;
        struct sockaddr_in      addr;

        ip = luaL_checkstring(L, 1);
        port = luaL_checkinteger(L, 2);

        addr.sin_family = AF_INET;
        addr.sin_port = htons(port);
        inet_pton(AF_INET, ip, &addr.sin_addr);

        s = socket(AF_INET, SOCK_STREAM, 0);

        err = connect(s, (struct sockaddr *)&addr, sizeof(addr));

        lua_pushinteger(L, s);

        return 1;
}

static int
_send(lua_State *L)
{
        int fd;
        size_t size;
        int err;
        const char *buff = luaL_checklstring(L, 2, &size);
        char packet[size + 2];
        *((unsigned short *)packet) = htons(size);
        memcpy(packet + 2, buff, size);

        fd = luaL_checkinteger(L, 1);

        err = send(fd, packet, size + 2, 0);

        lua_pushinteger(L, err);

        return 1;
}

static int
_read(int fd, char *buff, int size)
{
        int oring = size;
        int len;
        while (size) {
                len = recv(fd, buff, size, 0);
                size -= len;
                buff += len;
        }
        return 0;
}

static int
_recv(lua_State *L)
{
        int fd;
        unsigned short size;

        fd = luaL_checkinteger(L, 1);
        
        size = 0;
        _read(fd, (char *)&size, 2);
        
        size = ntohs(size);

        char buff[size + 1];
        _read(fd, buff, size);

        lua_pushlstring(L, buff, size);

        return 1;
}

static int
_close(lua_State *L)
{
        int fd;
        
        fd = luaL_checkinteger(L, 1);

        close(fd);
        
        return 0;
}


int luaopen_socket(lua_State *L)
{
        luaL_Reg tbl[] = {
                "connect", _connect,
                "send", _send,
                "recv", _recv,
                "close", _close,
                NULL, NULL,
        };

        luaL_newlib(L, tbl);

        return 1;
}

