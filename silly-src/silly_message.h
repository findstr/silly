#ifndef _SILLY_MESSAGE_H
#define _SILLY_MESSAGE_H

#include <stdint.h>

enum silly_message_type {
        SILLY_TIMER_EXECUTE     = 1,
        SILLY_SOCKET_ACCEPT     = 2,            //a new connetiong
        SILLY_SOCKET_CLOSE,                     //a close from client
        SILLY_SOCKET_CONNECT,                   //a async connect result
        SILLY_SOCKET_DATA,                      //a data packet(raw) from client
        SILLY_DEBUG             = 0xffff,       // debug message
};

struct silly_message {
        enum silly_message_type type;
        struct silly_message    *next;
};

struct silly_message_socket {
        int                     sid;
        int                     data_size;
        uint8_t                 *data;
};

struct silly_message_timer {
        uintptr_t sig;
};

struct silly_message_debug {
        //char *string; the silly_message_debug structure will be a string, so it need no define the structure
};


#endif

