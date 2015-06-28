#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>

#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>

#include "socket.h"

static int fd;

static int
_check_arg(int argc, char *argv[])
{
        printf("argc:%d, %s\n", argc, argv[0]);
        if (argc != 2) {
                printf("USAGE <server> <fd>\n");
                return -1;
        }

        printf("server:hello server, socketfd:%s\n", argv[1]);

        return 0;
}

int main(int argc, char *argv[])
{
        int fd;
        const char *buff;
        int size;
        lua_State *L = luaL_newstate();
        luaL_openlibs(L);

        if (_check_arg(argc, argv) < 0)
                return -1;

        fd = strtoul(argv[1], NULL, 0);
        socket_init(fd);
        
#if 1

        if (luaL_loadfile(L, "main.lua") || lua_pcall(L, 0, 0, 0)) {
                fprintf(stderr, "call main.lua fail,%s\n", lua_tostring(L, -1));

                return -1;
        }
#else   
        for (;;) {
                int i;
                buff = socket_pull(&fd, &size);
                if (buff) {
                        printf("server:fd>%d, size>%d\n", fd, size);
                        for (i = 0; i < size; i++)
                                printf("%c", buff[i]);
                        printf("\r\n");
                }
        }
#endif
        return 0;
}
