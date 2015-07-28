#include <pthread.h>
#include <unistd.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>

#include "silly_message.h"
#include "silly_malloc.h"
#include "silly_timer.h"
#include "silly_socket.h"
#include "silly_server.h"
#include "silly_daemon.h"

#include "silly_run.h"

static void *
_socket(void *arg)
{
        for (;;) {
                silly_socket_run();
        }

        return NULL;
}

static void *
_timer(void *arg)
{
        for (;;) {
                timer_dispatch();
                usleep(1000);
        }

        return NULL;
}

static void *
_worker(void *arg)
{
        int workid = *((int *)arg);

        for (;;) {
                silly_server_dispatch(workid);
                usleep(1000);
        }

        return NULL;
}

static void *
_debug(void *arg)
{
        char buff[1024];
        for (;;) {
                int n;
                struct silly_message *msg;
                char *sz;

                fgets(buff, 1024, stdin);
                n = strlen(buff);
                msg = (struct silly_message *)silly_malloc(sizeof(*msg) + n + 1);
                sz = (char *)(msg + 1);
                msg->type = SILLY_DEBUG;
                strcpy(sz, buff);

                silly_server_push(0, msg);
        }

        return NULL;
}

int silly_run(struct silly_config *config)
{
        int i, j;
        int tcnt;

        if (config->daemon && silly_daemon(1, 0) == -1) {
                fprintf(stderr, "daemon error:%d\n", errno);
                exit(0);
        }

        timer_init();
        silly_socket_init();
        silly_server_init();

        silly_socket_listen(config->listen_port, -1);
        
        srand(time(NULL));

        //start
        int     workid[config->worker_count];
        for (i = 0; i < config->worker_count; i++) {
                workid[i] = silly_server_open();
                silly_server_start(workid[i], config->bootstrap, config->lualib_path, config->lualib_cpath);
        }
        
        tcnt = 2;
        if (config->debug > 0)
                ++tcnt;

        tcnt += config->worker_count;
        pthread_t pid[tcnt];

        i = 0;
        pthread_create(&pid[i++], NULL, _socket, NULL);
        pthread_create(&pid[i++], NULL, _timer, NULL);

        if (config->debug > 0)
                pthread_create(&pid[i++], NULL, _debug, NULL);

        for (j = 0; i < tcnt; i++, j++)
                pthread_create(&pid[i], NULL, _worker, &workid[j]);

        for (i = 0; i < tcnt; i++)
                pthread_join(pid[i + 2], NULL);

        silly_server_exit();
        silly_socket_exit();
        timer_exit();
        return 0;
}
