#ifndef _MESSAGE_H_
#define _MESSAGE_H_

#include <string.h>
#include "silly_worker.h"

#define tocommon(msg) ((struct silly_message *)(msg))
#define totexpire(msg) ((struct silly_message_texpire *)(msg))
#define tosocket(msg) ((struct silly_message_socket *)(msg))
#define tosignal(msg) ((struct silly_message_signal *)(msg))
#define tostdin(msg) ((struct silly_message_stdin *)(msg))

#define COMMONFIELD                 \
	struct silly_message *next; \
	enum silly_message_type type;

struct silly_message {
	COMMONFIELD
};

struct silly_message_texpire { //timer expire
	COMMONFIELD
	uint64_t session;
	uint64_t userdata;
};

struct silly_message_socket { //socket accept
	COMMONFIELD
	int64_t sid;
	//SACCEPT, it used as portid,
	//SCLOSE used as errorcode
	//SDATA/SUDP  used by length
	int64_t ud;
	uint8_t *data;
};

struct silly_message_signal { //signal
	COMMONFIELD
	int signum;
};

struct silly_message_stdin { //stdin
	COMMONFIELD
	int size;
	uint8_t data[1];
};

static inline void silly_message_free(struct silly_message *msg)
{
	int type = msg->type;
	if (type == SILLY_SDATA || type == SILLY_SUDP)
		silly_free(tosocket(msg)->data);
	silly_free(msg);
}

static inline void silly_message_accept(int64_t sid, int64_t listen_sid, const char *name, int namelen)
{
	struct silly_message_socket *sa;
	sa = silly_malloc(sizeof(*sa) + namelen + 1);
	sa->type = SILLY_SACCEPT;
	sa->sid = sid;
	sa->ud = listen_sid;
	sa->data = (uint8_t *)(sa + 1);
	*sa->data = namelen;
	memcpy(sa->data + 1, name, namelen);
	silly_worker_push(tocommon(sa));
}

static inline void silly_message_close(int64_t sid, int error)
{
	struct silly_message_socket *sc;
	sc = silly_malloc(sizeof(*sc));
	sc->type = SILLY_SCLOSE;
	sc->sid = sid;
	sc->ud = error;
	silly_worker_push(tocommon(sc));
}

static inline void silly_message_data(int64_t sid, int type, uint8_t *data, size_t sz)
{
	struct silly_message_socket *sd;
	sd = silly_malloc(sizeof(*sd));
	sd->type = type;
	sd->sid = sid;
	sd->ud = sz;
	sd->data = data;
	silly_worker_push(tocommon(sd));
}

static inline void silly_message_connected(int64_t sid)
{
	struct silly_message_socket *sc;
	sc = silly_malloc(sizeof(*sc));
	sc->type = SILLY_SCONNECTED;
	sc->sid = sid;
	silly_worker_push(tocommon(sc));
}

#endif