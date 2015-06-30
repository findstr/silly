#include <assert.h>
#include <stdio.h>
#include <sys/socket.h>
#include <arpa/inet.h>
#include <errno.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>
#include "ppoll.h"
#include "server.h"

static struct server *svr_tbl[1];

int main()
{
        int fd;
        const char *buff;
        char *pbuff = (char *)malloc(64 * 1024);
        
        ppoll_init();
        printf("listen:%d\n", ppoll_listen(8989));
        
        svr_tbl[0] = server_create();
        ppoll_addsocket(server_getfd(svr_tbl[0]));
        for (;;) {
                buff = ppoll_pull(&fd);
                if (buff == NULL && fd != -1) {
                        printf("gate:new connect:%d\n", fd);
                } else if (buff) {
                        if (fd == server_getfd(svr_tbl[0])) {
                                unsigned short psize = *(unsigned short *)buff;
                                int fd = *((int *)(buff + 2));
                                *((unsigned short *)(buff + 4)) = htons(ntohs(psize) - 4);
                                ppoll_send(fd, buff + 4);
                        } else {
                                *((unsigned short *)pbuff) = htons(ntohs(*((unsigned short *)buff)) + 4);
                                *((int *)(pbuff + 2)) = fd;
                                memcpy(pbuff + 6, buff + 2, *((unsigned short *)buff));
                                ppoll_send(server_getfd(svr_tbl[0]), pbuff);
                        }
                        
                        ppoll_push();
                }
                
                printf("gate:hello, fd:%d\n", fd);
        }

        return 0;
}
