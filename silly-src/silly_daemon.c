#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>

#include "silly_daemon.h"

extern int daemon(int, int);

int silly_daemon()
{
        int err;
        int fd;

        err = daemon(1, 0);
        fd = open("/tmp/silly.log", O_CREAT | O_RDWR | O_TRUNC, 00666);
        if (fd >= 0)
                dup2(fd, 2);

        return err;
}
