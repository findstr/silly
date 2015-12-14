#include <pthread.h>
#include <unistd.h>
#include <signal.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>

#include "silly_config.h"
#include "silly_env.h"
#include "silly_message.h"
#include "silly_malloc.h"
#include "silly_timer.h"
#include "silly_socket.h"
#include "silly_server.h"
#include "silly_daemon.h"

#include "silly_run.h"

static int run = 1;

static void *
_socket(void *arg)
{
        while (run) {
                silly_socket_poll();
        }

        return NULL;
}

static void *
_timer(void *arg)
{
        while (run) {
                timer_dispatch();
                usleep(1000);
        }

        return NULL;
}

static void *
_worker(void *arg)
{
        int workid = *((int *)arg);

        while (run) {
                silly_server_dispatch(workid);
                usleep(1000);
        }

        silly_server_stop(workid);

        return NULL;
}

static void *
_debug(void *arg)
{
        char buff[1024];
        while (run) {
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

static void
_sig_term(int signum)
{
        run = 0;
        silly_socket_terminate();

        return ;
}

int silly_run(struct silly_config *config)
{
        int i, j;
        int err;
        int tcnt;

        if (config->daemon && silly_daemon(1, 0) == -1) {
                fprintf(stderr, "daemon error:%d\n", errno);
                exit(0);
        }

        signal(SIGPIPE, SIG_IGN);
        signal(SIGHUP, _sig_term);
        signal(SIGINT, _sig_term);
        signal(SIGTERM, _sig_term);

        timer_init();
        silly_socket_init();
        silly_server_init();

        for (i = 0; i < config->listen_count; i++) {
                int n;
                char ip[32];
                char port[32];
                char backlog[32];
                
                uint16_t        nport;
                int             nbacklog;

                backlog[0] = '\0';
                n = sscanf(config->listen[i].addr, "%[0-9.]:%[0-9]:%[0-9]", ip, port, backlog);
                if (n < 2) {
                        fprintf(stderr, "Invalid listen of %s\n", config->listen[i].name);
                        return -1;
                }
                nport = (uint16_t)strtoul(port, NULL, 0);
                nbacklog = (int)strtol(backlog, NULL, 0);
                if (nbacklog == 0)
                        nbacklog = 10;

                err = silly_socket_listen(ip, nport, nbacklog, -1);
                if (err == -1) {
                        fprintf(stderr, "listen :%s(%s) error\n", config->listen[i].addr, config->listen[i].name);
                        return -1;
                }

                snprintf(port, sizeof(port) / sizeof(port[0]), "%d", err);
                silly_env_set(config->listen[i].name, port);
        }
        
        srand(time(NULL));

        //start
        int     workid[config->worker_count];
        for (i = 0; i < config->worker_count; i++) {
                workid[i] = silly_server_open();
                silly_server_start(workid[i], config);
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

        for (j = 0; j < config->worker_count; i++, j++)
                pthread_create(&pid[i], NULL, _worker, &workid[j]);

        fprintf(stderr, "Silly is running...\n");

        for (i = 0; i < tcnt; i++)
                pthread_join(pid[i], NULL);

        silly_server_exit();
        silly_socket_exit();
        timer_exit();

        fprintf(stderr, "silly has already exit...\n");

        return 0;
}
