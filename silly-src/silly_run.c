#include <pthread.h>
#include <unistd.h>
#include <signal.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>

#include "silly.h"
#include "silly_env.h"
#include "silly_malloc.h"
#include "silly_timer.h"
#include "silly_socket.h"
#include "silly_worker.h"
#include "silly_daemon.h"

#include "silly_run.h"

#define CHECKQUIT       \
        if (silly_worker_checkquit())\
                break;

static void *
thread_socket(void *arg)
{
        int err;
        (void)arg;
        for (;;) {
                err = silly_socket_poll();
                if (err < 0) {
                        fprintf(stderr, "silly_socket_pool terminated\n");
                        break;
                }
        }
        return NULL;
}

static void *
thread_timer(void *arg)
{
        (void)arg;
        for (;;) {
                silly_timer_update();
                CHECKQUIT
                usleep(1000);
        }
        silly_socket_terminate();
        return NULL;
}

static void *
thread_worker(void *arg)
{
        struct silly_config *c;
        c = (struct silly_config *)arg;
        silly_worker_init(c);
        for (;;) {
                silly_worker_dispatch();
                CHECKQUIT
                usleep(1000);
        }
        return NULL;
}

static int
signal_init()
{
        signal(SIGPIPE, SIG_IGN);
        return 0;
}

static void
thread_create(pthread_t *tid, void *(*start)(void *), void *arg)
{
        int err;
        err = pthread_create(tid, NULL, start, arg);
        if (err < 0) {
                fprintf(stderr, "thread create fail:%d\n", err);
                exit(-1);
        }
        return ;
}

void
silly_run(struct silly_config *config)
{
        int i;
        int err;
        pthread_t pid[3];
        if (config->daemon && silly_daemon(1, 0) == -1) {
                fprintf(stderr, "daemon error:%d\n", errno);
                exit(-1);
        }
        signal_init();
        silly_timer_init();
        err = silly_socket_init();
        if (err < 0) {
                fprintf(stderr, "silly socket init fail:%d\n", err);
                exit(-1);
        }
        srand(time(NULL));
        thread_create(&pid[0], thread_socket, NULL);
        thread_create(&pid[1], thread_timer, NULL);
        thread_create(&pid[2], thread_worker, config);
        fprintf(stdout, "silly is running ...\n");
        for (i = 0; i < 3; i++)
                pthread_join(pid[i], NULL);

        silly_worker_exit();
        silly_timer_exit();
        silly_socket_exit();
        fprintf(stdout, "silly has already exit...\n");
        return ;
}

