#include <assert.h>
#include <stdio.h>
#include <string.h>

#include "silly_queue.h"
#include "silly_malloc.h"
#include "silly_worker.h"

#include "silly_server.h"

struct silly_server {
        int workcnt;
        struct silly_worker   **worklist;
};


struct silly_server     *SILLY_SERVER;

int silly_server_init()
{
        SILLY_SERVER = (struct silly_server *)silly_malloc(sizeof(struct silly_server));
        assert(SILLY_SERVER);
        SILLY_SERVER->workcnt = 0;
        SILLY_SERVER->worklist = NULL;

        return 0;
}
int silly_server_exit()
{
        int i;
        for (i = 0; i < SILLY_SERVER->workcnt; i++)
                silly_worker_free(SILLY_SERVER->worklist[i]);

        silly_free(SILLY_SERVER);

        return 0;
}


int silly_server_open()
{
        struct silly_server *s = SILLY_SERVER;

        s->worklist = silly_realloc(s->worklist, (s->workcnt + 1) * sizeof(s->worklist[0]));
        s->worklist[s->workcnt] = silly_worker_create(s->workcnt);

        return s->workcnt++;
}

int silly_server_push(int handle, struct silly_message *msg)
{
        assert(handle < SILLY_SERVER->workcnt);
        return silly_worker_push(SILLY_SERVER->worklist[handle], msg);
}

int silly_server_balance(int workid, int sid)
{
        if (workid == -1)
                return sid % SILLY_SERVER->workcnt;

        assert(workid < SILLY_SERVER->workcnt);

        return workid;
}

int silly_server_start(int handle, const char *bootstrap, const char *libpath, const char *clibpath)
{
        return silly_worker_start(SILLY_SERVER->worklist[handle], bootstrap, libpath, clibpath);
}

void silly_server_stop(int handle)
{
        return silly_worker_stop(SILLY_SERVER->worklist[handle]);
}

int silly_server_dispatch(int handle)
{
        assert(handle < SILLY_SERVER->workcnt);
        return silly_worker_dispatch(SILLY_SERVER->worklist[handle]);
}


