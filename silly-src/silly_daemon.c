#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <errno.h>

#include "silly_daemon.h"

extern int daemon(int, int);

int silly_daemon()
{
        int err;
        int fd;
        err = daemon(1, 0);
        if (err < 0) {
                perror("DAMEON:");
                exit(0);
        }
        fd = open("/tmp/silly.log", O_CREAT | O_RDWR | O_TRUNC, 00666);
        if (fd >= 0) {
                dup2(fd, 1);
                dup2(fd, 2);
                close(1);
                close(2);
        }

        return 0;
}
