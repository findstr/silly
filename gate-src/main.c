#include <assert.h>
#include <stdio.h>
#include <sys/socket.h>
#include <errno.h>
#include <unistd.h>
#include "ppoll.h"
#include "server.h"

static struct server *svr_tbl[1];

int main()
{
        int fd;
        const char *buff;
        
        ppoll_init();
        printf("listen:%d\n", ppoll_listen(8989));
        
        svr_tbl[0] = server_create();

        for (;;) {
                int i;
                buff = server_read(svr_tbl[0], &fd);
                if (buff) {
                        unsigned short psize = *((unsigned short*)buff);
                        printf("---gate, fd:%d,send:%d\n", fd, psize);
                        for (i = 0; i < psize; i++)
                                printf("%c", buff[i + 2]);
                        printf("\r\n");
                                
                        ppoll_send(fd, buff);
                }
                buff = ppoll_pull(&fd);
                if (buff == NULL && fd != -1) {
                        printf("gate:new connect:%d\n", fd);
                } else if (buff) {
                        server_send(svr_tbl[0], fd, buff);
                        ppoll_push();
                }
                
                printf("gate:hello, fd:%d\n", fd);

                sleep(1);
        }

        return 0;
}
