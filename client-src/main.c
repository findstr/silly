/**
=========================================================================
 Author: findstr
 Email: findstr@sina.com
 File Name: select/cli01.c
 Description: (C)  2015-01  findstr
   
 Edit History: 
   2015-01-05    File created.
=========================================================================
**/
#include <stdlib.h>
#include <stdio.h>

#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>

int main()
{
        lua_State *L;

        L = luaL_newstate();
        luaL_openlibs(L);

        if (luaL_loadfile(L, "main.lua") || lua_pcall(L, 0, 0, 0)) {
                fprintf(stderr, "call main.lua fail,%s\n", lua_tostring(L, -1));
                lua_close(L);
                return -1;
        }

        return 0;
}

/*

int main(int argc, char *argv[])
{
        int err;
        int sockfd;
        struct sockaddr_in addr;
        char buff[1024];
        char sbuff[1024];

        if (argc == 1) {
                printf("USAGE <client> <ip>\n");
                return 0;
        }

        sockfd = socket(AF_INET, SOCK_STREAM, 0);

        bzero(&addr, sizeof(addr));

        addr.sin_family = AF_INET;
        addr.sin_port = htons(8989);
        inet_pton(AF_INET, argv[1], &addr.sin_addr);

        err = connect(sockfd, (struct sockaddr *)&addr, sizeof(addr));
        if (err < 0) {
                printf("connect error:%d\n", errno);
                exit(0);
        }
 
        for (;;) {
                int i;
                fgets(buff, 1024, stdin);
                *(unsigned short*)sbuff = htons(strlen(buff));
                memcpy(sbuff + 2, buff, strlen(buff));
                printf("send:%d\n", (int)strlen(buff) + 2);
                socket_write(sockfd, sbuff, strlen(buff) + 2); 
                memset(sbuff, 0, sizeof(sbuff));
#if 0
                unsigned short len;
                socket_read(sockfd, (char *)&len, sizeof(len));
                len = ntohs(len);
                printf("client:get data:%d...\n", len);
                socket_read(sockfd, sbuff, len);
                printf("client:...\n");
                for (i = 0; i < len; i++) {
                        printf("%c", sbuff[i]);
                }
                printf("\n");
#endif
        }

        close(sockfd);

        return 0;
}
*/
