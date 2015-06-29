#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>

#include "socket.h"

int success = 0;

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
        if (success == 0)
                return 0;

        success = 0;

        int psize = ntohs(*((unsigned short*)(S->packet_buff)));

        printf("server:align_socket:%d, %d\n", psize, S->packet_len);

        if (S->packet_len <= 2)
                return 0;

        if (S->packet_len >= psize + 2) {
                int more = S->packet_len - psize - sizeof(unsigned short);
                if (more > 0)
                        memmove(S->packet_buff, S->packet_buff + psize + sizeof(unsigned short), more);
                S->packet_len = more;
        }
        //printf("server:align_socket:%x, %d\n", psize, S->packet_len);

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

        S->packet_len += read_len;
        printf("server:socket-pull, socket data:%d, packet_len:%d\n", read_len, S->packet_len);
        if (S->packet_len < sizeof(unsigned short) + sizeof(int))
                return NULL;

        psize = ntohs(*((unsigned short*)S->packet_buff));
        printf("server:socket-pull, socket len:%d, %x %x %x %x %x %x\n", psize, S->packet_buff[0], S->packet_buff[1], S->packet_buff[2] , S->packet_buff[3], S->packet_buff[4], S->packet_buff[5]);
        if (S->packet_len < psize + 2)
                return NULL;

        printf("socket pull:%d, %d\n", S->packet_len, psize);

        *fd = *((int *)(S->packet_buff + 2));
        *size = psize - 4;

        success = 1;

        return (S->packet_buff + sizeof(int) + sizeof(unsigned short));
}

int socket_send(int fd, unsigned char *buff, int size)
{
        char *b = (char *)malloc(size + sizeof(int) + sizeof(unsigned short));
        *((int *)(b + 2)) = fd;
        *((unsigned short *)b) = ntohs((unsigned short)size + 4);

        memcpy(b + 6, buff, size);

        printf("***server send:%d*****\n", size + 6);

        //TODO:need repeat send, becuase this can be interrupt
        send(S->fd, b, size + 6, 0);

        return 0;
}




