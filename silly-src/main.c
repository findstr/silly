#include <stdio.h>
#include <stdlib.h>
#include <pthread.h>
#include <unistd.h>

#include "silly_server.h"
#include "silly_socket.h"

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

                usleep(1000);
        }

        return NULL;
}

static void *
_server(void *arg)
{
        int workid = *((int *)arg);

        for (;;) {
                silly_server_dispatch(workid);
                usleep(1000);
        }

        return NULL;
}

int main()
{
        silly_socket_init();
        silly_server_init();

        silly_socket_listen(8989, -1);
        
        srand(time(NULL));

        //start
        int handle = silly_server_open();
        
        silly_server_start(handle);

        pthread_t       pid[3];

        pthread_create(&pid[0], NULL, _socket, NULL);
        pthread_create(&pid[1], NULL, _timer, NULL);
        pthread_create(&pid[2], NULL, _server, &handle);


        pthread_join(pid[0], NULL);
        pthread_join(pid[1], NULL);
        pthread_join(pid[2], NULL);

        printf("----end-----\n");
        silly_socket_exit();
        silly_server_exit();

        return 0;
}
