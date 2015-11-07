#ifndef _SILLY_CONFIG_H
#define _SILLY_CONFIG_H

struct silly_listen {
        char name[32];
        char addr[64];
};

struct silly_config {
        int debug;
        int daemon;
        int listen_count;
        //please forgive my shortsighted, i think listen max to 16 ports is very many
        struct silly_listen listen[16];
        int listen_port;
        int worker_count;
        char bootstrap[128];
        char lualib_path[256];
        char lualib_cpath[256];
};

#endif

