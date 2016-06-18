#ifndef _SILLY_H
#define _SILLY_H
#include <assert.h>
#include <stdint.h>
#include "silly_malloc.h"

struct silly_listen {
        char name[64];
        char addr[64];
};

struct silly_config {
        int daemon;
        //please forgive my shortsighted, i think listen max to 16 ports is very many
        char bootstrap[128];
        char lualib_path[256];
        char lualib_cpath[256];
};

enum silly_message_type {
        SILLY_TEXPIRE           = 1,
        SILLY_SACCEPT           = 2,    //new connetiong
        SILLY_SCLOSE,                   //close from client
        SILLY_SCONNECTED,               //async connect result
        SILLY_SDATA,                    //data packet(raw) from client
};

#define MSGCOMMONFIELD       \
        enum silly_message_type type;\
        struct silly_message    *next;


struct silly_message {
        MSGCOMMONFIELD
};

struct silly_message_texpire {  //timer expire
        MSGCOMMONFIELD
        uint64_t session;
};

struct silly_message_socket {  //socket accept
        MSGCOMMONFIELD
        int sid;
        //SACCEPT, it used as portid,
        //SCLOSE used as errorcode
        //SDATA  used by length
        int ud;
        uint8_t *data;          
};

#define tocommon(msg)     ((struct silly_message *)(msg))
#define tosocket(msg)    ((struct silly_message_socket *)(msg))
#define texpire(msg)     (assert((msg)->type == SILLY_TEXPIRE), ((struct silly_message_texpire *)(msg)))
#define saccept(msg)    (assert((msg)->type == SILLY_SACCEPT), ((struct silly_message_socket *)(msg)))
#define sclose(msg)     (assert((msg)->type == SILLY_SCLOSE), ((struct silly_message_socket *)(msg)))
#define sconnected(msg) (assert((msg)->type == SILLY_SCONNECTED), ((struct silly_message_socket *)(msg)))
#define sdata(msg)      (assert((msg)->type == SILLY_SDATA), ((struct silly_message_socket *)(msg)))

static void __inline silly_message_free(struct silly_message *msg)
{
        if (msg->type == SILLY_SDATA)
                silly_free(sdata(msg)->data);
        silly_free(msg);
}

#endif

