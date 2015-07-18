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

char sbuff[1024];
int sockfd;

static void
_send_cmd(const char *cmd)
{
        *(unsigned short*)sbuff = htons(strlen(cmd));
        memcpy(sbuff + 2, cmd, strlen(cmd));
        printf("send:%d\n", (int)strlen(cmd) + 2);
        socket_write(sockfd, sbuff, strlen(cmd) + 2); 
}

static void
_recv_cmd()
{
        unsigned short len;
        socket_read(sockfd, (char *)&len, sizeof(len));
        len = ntohs(len);
        printf("client:get data:%d...\n", len);
        socket_read(sockfd, sbuff, len);
        sbuff[len] = 0;
        printf("cmd->response:%s\n", sbuff);
}

static void
_login()
{
        const char *cmd = "{\"cmd\":\"auth\", \"name\":\"findstr\"}\r\n\r";

        _send_cmd(cmd);
        _recv_cmd();
}

static void
_room_create()
{
        const char *cmd = "{\"cmd\":\"room_create\", \"uid\":\"1\"}\r\n\r";

        _send_cmd(cmd);
        _recv_cmd();
}


static void
_room_list()
{
        const char *cmd = "{\"cmd\":\"room_list\", \"page_index\":\"1\"}\r\n\r";

        _send_cmd(cmd);
        _recv_cmd();
}

int main(int argc, char *argv[])
{
        int err;
        struct sockaddr_in addr;
        char buff[1024];

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
                fgets(buff, 1024, stdin);
                if (strncmp(buff, "login", 5) == 0)
                        _login();
                else if (strncmp(buff, "roomcreate", 10) == 0)
                        _room_create();
                else if (strncmp(buff, "roomlist", 8) == 0)
                        _room_list();
        }
        close(sockfd);

        return 0;
}
*/
