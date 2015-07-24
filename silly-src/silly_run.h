#ifndef _SILLY_RUN_H
#define _SILLY_RUN_H

struct silly_config {
        int debug;
        int deamon;
        int listen_port;
        int worker_count;
        char bootstrap[128];
        char lualib_path[256];
        char lualib_cpath[256];
};

int silly_run(struct silly_config *config);


#endif

