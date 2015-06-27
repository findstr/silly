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
                buff = ppoll_pull(&fd);
                if (buff == NULL && fd != -1) {
                        printf("gate:new connect:%d\n", fd);
                } else if (buff) {
                        server_send(svr_tbl[0], fd, buff);
                        ppoll_push();
                }
                printf("gate:pull:%d\n", fd);
                sleep(1);
        }

        return 0;
}
