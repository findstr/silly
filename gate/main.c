#include <assert.h>
#include <stdio.h>
#include <unistd.h>
#include "ppoll.h"

int main()
{
        int i;
        int fd;
        const char *buff;
        ppoll_init();
        printf("listen:%d\n", ppoll_listen(8989));
        for (;;) {
                buff = ppoll_pull(&fd);
                if (buff == NULL && fd != -1) {
                        printf("new connect:%d\n", fd);
                } else if (buff) {
                        unsigned short len = *(unsigned short*)buff;
                        buff += 2;
                        assert(fd >= 0);

                        printf("--------data-----------\n");
                        for (i = 0; i < len; i++) {
                                printf("%c ", buff[i]);
                                if (i % 8 == 0 && i)
                                        printf("\r\n");
                        }
                }
                printf("hello:%d\n", fd);
                sleep(1);
        }

        return 0;
}
