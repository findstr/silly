#include <pthread.h>
#include <unistd.h>
#include <stdlib.h>

#include "silly_timer.h"
#include "silly_socket.h"
#include "silly_server.h"

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



int silly_run(struct silly_config *config)
{
        int i;
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
        
        pthread_t pid[2 + config->worker_count];
        pthread_create(&pid[0], NULL, _socket, NULL);
        pthread_create(&pid[1], NULL, _timer, NULL);
        for (i = 0; i < config->worker_count; i++)
                pthread_create(&pid[i + 2], NULL, _worker, &workid[i]);


        pthread_join(pid[0], NULL);
        pthread_join(pid[1], NULL);
        for (i = 0; i < config->worker_count; i++)
                pthread_join(pid[i + 2], NULL);

        silly_server_exit();
        silly_socket_exit();
        timer_exit();
        return 0;
}
