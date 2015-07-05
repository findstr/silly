#ifndef _EVENT_H
#define _EVENT_H

struct event;

enum event_ptype {
        EVENT_GDATA,    //data from gate
        EVENT_CDATA,    //data from connection
        EVENT_HANDLE,   //event has no data
};

struct event_handler {
        void *ud;
        void (*cb)(void *ud);
};

int event_init();
void event_exit();

int event_connect(const char *addr, int port);
int event_add_gatefd(int fd);

int event_set_datahandler(int (*cb)(void *ud, enum event_ptype type, int fd, const char *buff, int size), void *ud);
int event_add_handler(const struct event_handler *handler);

int event_socketsend(enum event_ptype type, int fd, const char *buff, int size);

int event_dispatch();



#endif


