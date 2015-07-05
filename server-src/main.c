#include <assert.h>
#include <stdio.h>
#include <time.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>
#include <sys/socket.h>

#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>

#include "event.h"
#include "timer.h"

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

static void *
_timer(void *arg)
{
        for (;;) {
                timer_dispatch();
                usleep(1000);
        }

        return NULL;

}

int main(int argc, char *argv[])
{
        int fd;
        int err;
        pthread_t ntid;

        lua_State *L = luaL_newstate();
        luaL_openlibs(L);

        srand(time(NULL));

        if (_check_arg(argc, argv) < 0)
                return -1;

        fd = strtoul(argv[1], NULL, 0);

        err = event_init();
        if (err < 0)
                return err;

        err = timer_init();
        if (err < 0)
                return err;

        event_add_gatefd(fd);

        err = pthread_create(&ntid, NULL, _timer, NULL);

        if (luaL_loadfile(L, "main.lua") || lua_pcall(L, 0, 0, 0)) {
                fprintf(stderr, "call main.lua fail,%s\n", lua_tostring(L, -1));

                return -1;
        }
        
        for (;;) {
                event_dispatch();
        }


#if 0

        socket_init(fd);
        
#if 1

        
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
#endif
        event_exit();

        return 0;
}
