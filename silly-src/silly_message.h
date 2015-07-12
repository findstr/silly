#ifndef _SILLY_MESSAGE_H
#define _SILLY_MESSAGE_H

enum silly_message_type {
        SILLY_MESSAGE_TIMER     = 1,
        SILLY_MESSAGE_SOCKET    = 2,
};

enum silly_socket_ptype {
        SILLY_SOCKET_ACCEPT,            //a new connetiong
        SILLY_SOCKET_CLOSE,             //a close from client
        SILLY_SOCKET_CONNECT,           //a async connect result
        SILLY_SOCKET_DATA,              //a data packet(raw) from client
};


struct silly_message_socket {
        enum silly_socket_ptype type;
        int                     sid;
        int                     data_size;
        char                    *data;
};

struct silly_message_timer {
        int id;
};

struct silly_message {
        enum silly_message_type type;
        union {
                struct silly_message_socket     *socket;
                struct silly_message_timer      *timer;
                void                            *ptr;
        } msg;
        struct silly_message    *next;
};

#endif

