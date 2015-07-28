#include "silly_daemon.h"

extern int daemon(int, int);

int silly_daemon()
{
        return daemon(1, 0);
}
