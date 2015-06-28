/**
=========================================================================
 Author: findstr
 Email: findstr@sina.com
 File Name: ../lib/sock.c
 Description: (C)  2014-12  findstr
   
 Edit History: 
   2014-12-30    File created.
=========================================================================
**/
#include <errno.h>
#include <stdio.h>
#include <unistd.h>
#include <sys/socket.h>

int socket_write(int s, char *buff, int len)
{
        int left;
        int tmp;

        left = len;

        while (left) {
                tmp = write(s, buff, left);
 //               printf("write0 :left:%d, once:%d\n", left, tmp);
                if (tmp < 0 && errno == EINTR)
                        tmp = 0;
                else if (tmp <= 0)
                        return -1;

  //              printf("write1 :left:%d, once:%d\n", left, tmp);
                left -= tmp;
   //             printf("write2 :left:%d, once:%d\n", left, tmp);
                buff += tmp;
        }

        return len;
}

int socket_read(int s, char *buff, int len)
{
        int left;
        int tmp;

        left = len;

        while (left) {
                tmp = read(s, buff, left);
                if (tmp < 0 && errno == EINTR)
                        tmp = 0;
                else if (tmp <= 0)
                        return -1;

                left -= tmp;
                buff += tmp;
        }

        return len;
}

int socket_read_line(int s, char *buff, int len)
{
        int err;
        int left;

        left = len;

        while (left) {
                err = read(s, buff, 1);
                if ((err < 0 && errno != EINTR) || err == 0) {
//                        printf("read error:%d, errno=%d\n", err, errno);
                        return 0;
                }
                if (err < 0)
                        continue;

                left--;
                
                if (*buff == '\n')
                        break;
                buff++;
        }

//        printf("read line end\n");

        return len - left;
}
