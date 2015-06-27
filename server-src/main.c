#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>

static int fd;

int main(int argc, char *argv[])
{
        char *buff = malloc(64 * 1024 * sizeof(char));
        printf("argc:%d, %s\n", argc, argv[0]);
        if (argc != 2) {
                printf("USAGE <server> <fd>\n");
                return 0;
        }

        printf("server:hello server, socketfd:%s\n", argv[1]);

        //receive the data
        fd = strtoul(argv[1], NULL, 0);

        int size = 0;
        for (;;) {
                int psize = 0;
                int more = 0;
                size += recv(fd, buff, 64 * 1024, 0);
                if (size >2)
                        psize = *((unsigned short *)buff);

                if (size >= psize) {
                        int i;
                        int fd = *(int *)buff;
                        unsigned short len = *((unsigned short*)buff + 2);
                        buff += 6;
                        assert(fd >= 0);

                        printf("server:data,fd:%d, len:%d\n", fd, len);
                        for (i = 0; i < len; i++) {
                                printf("%c", buff[i]);
                        }

                        printf("\r\n");

                        more = size - psize - 2;
                        if (more > 0)
                                memmove(buff, buff + psize, more); 
                }
                
        }

        return 0;
}
