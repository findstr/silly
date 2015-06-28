#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>

#include "socket.h"

struct socket {
        int fd;
        int packet_len;
        char *packet_buff;
};

#define PACKET_SIZE     (64 * 1024 + 4)    //sizeof(int) == 4,  is for the socket fd

static struct socket *S;

int socket_init(int fd)
{
        S = (struct socket *)malloc(sizeof(*S));
        S->fd = fd;
        S->packet_len = 0;
        S->packet_buff = (char *)malloc(PACKET_SIZE * sizeof(char));
        return 0;
}

void socket_exit()
{
        close(S->fd);
        free(S->packet_buff);
        free(S);
        return ;
}

static int 
_align_socket()
{
        if (S->packet_len <= 6)
                return 0;

        int psize = *((unsigned short*)(S->packet_buff + sizeof(int)));

        psize = ntohs(psize);
        if (S->packet_len >= psize + 6) {
                int more = S->packet_len - psize - sizeof(int) - sizeof(unsigned short);
                if (more > 0)
                        memmove(S->packet_buff, S->packet_buff + psize + sizeof(int) + sizeof(unsigned short), more);

                S->packet_len = more;
        }

        return 0;
}


const char *socket_pull(int *fd, int *size)
{
        int read_len;
        int psize;
        

        _align_socket();

        read_len = recv(S->fd, S->packet_buff + S->packet_len, PACKET_SIZE - S->packet_len, MSG_DONTWAIT);
        //read_len = recv(S->fd, S->packet_buff + S->packet_len, PACKET_SIZE - S->packet_len, 0);

        if (read_len < 0)
                return NULL;
        printf("socket-pull, socket data:%d\n", read_len);

        S->packet_len += read_len;
        if (S->packet_len < sizeof(unsigned short) + sizeof(int))
                return NULL;

        psize = *((unsigned short*)(S->packet_buff + sizeof(int)));
        printf("socket-pull, socket data2:%d, psize:%d, packet_size:%d\n", read_len, psize, S->packet_len);
        if (S->packet_len < psize + sizeof(unsigned short))
                return NULL;

        printf("socket pull**:%d, psize:%d\n", S->packet_len, psize);

        *fd = *((int *)S->packet_buff);
        *size = psize;

        return (S->packet_buff + sizeof(int));
}

int socket_send(int fd, unsigned char *buff, int size)
{
        char *b = (char *)malloc(size + sizeof(int) + sizeof(unsigned short));
        *((int *)b) = fd;
        *((unsigned short *)(b + sizeof(int))) = (unsigned short)size;

        memcpy(b + 6, buff, size);

        //TODO:need repeat send, becuase this can be interrupt
        send(S->fd, b, size + 6, 0);

        return 0;
}




