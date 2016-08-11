#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <errno.h>

#include "silly_daemon.h"

extern int daemon(int, int);

int silly_daemon()
{
        int fd;
        int err;
        char path[128];
        err = daemon(1, 0);
        if (err < 0) {
                perror("DAEMON");
                exit(0);
        }
        snprintf(path, 128, "/tmp/silly-%d.log", getpid());
        fd = open(path, O_CREAT | O_RDWR | O_TRUNC, 00666);
        if (fd >= 0) {
                dup2(fd, 1);
                dup2(fd, 2);
                close(fd);
                setvbuf(stdout, NULL, _IOLBF, 0);
                setvbuf(stderr, NULL, _IOLBF, 0);
        }
        return 0;
}
