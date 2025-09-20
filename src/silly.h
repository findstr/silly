#ifndef _SILLY_H
#define _SILLY_H
#include <assert.h>
#include <stdatomic.h>
#include <stdint.h>
#include <limits.h>
#include <lua.h>

#include "silly_conf.h"
#include "compiler.h"

#ifndef SILLY_GIT_SHA1
#define SILLY_GIT_SHA1 0
#endif

#define SILLY_VERSION_MAJOR 0
#define SILLY_VERSION_MINOR 6
#define SILLY_VERSION_RELEASE 0
#define SILLY_VERSION_NUM ((SILLY_VERSION_MAJOR * 100) + SILLY_VERSION_MINOR)
#define SILLY_VERSION STR(SILLY_VERSION_MAJOR) "." STR(SILLY_VERSION_MINOR)
#define SILLY_RELEASE SILLY_VERSION "." STR(SILLY_VERSION_RELEASE)

struct silly_message {
	int type;
	struct silly_message *next;
	int (*unpack)(lua_State *L, struct silly_message *msg);
	/* parameter is void* (not silly_message*) to match allocator's free
	 * signature, allowing direct assignment like msg->free = free */
	void (*free)(void *ptr);
};

enum silly_log_level {
	SILLY_LOG_DEBUG = 0,
	SILLY_LOG_INFO = 1,
	SILLY_LOG_WARN = 2,
	SILLY_LOG_ERROR = 3,
};

// from silly_socket.h
typedef int64_t socket_id_t;
//sid == socket number, it will be remap in silly_socket, not a real socket fd

struct silly_socket_msgtype {
	int listen;
	int connect;
	int accept;
	int tcpdata;
	int udpdata;
	int close;
};

struct silly_netstat {
	atomic_uint_least16_t connecting;
	atomic_uint_least16_t tcpclient;
	atomic_uint_least32_t recvsize;
	atomic_uint_least32_t sendsize;
	atomic_uint_least32_t oprequest;
	atomic_uint_least32_t opprocessed;
};

struct silly_socketstat {
	socket_id_t sid;
	int fd;
	const char *type;
	const char *protocol;
	size_t sendsize;
	char localaddr[SILLY_SOCKET_NAMELEN];
	char remoteaddr[SILLY_SOCKET_NAMELEN];
};

typedef uint16_t silly_tracespan_t;
typedef uint64_t silly_traceid_t;

SILLY_API void silly_exit(int status);

SILLY_API void *silly_malloc(size_t sz);
SILLY_API void *silly_realloc(void *ptr, size_t sz);
SILLY_API void silly_free(void *ptr);
SILLY_API const char *silly_allocator();
SILLY_API size_t silly_memused();
SILLY_API size_t silly_memrss();
SILLY_API int silly_mallctl(const char *name, void *oldp, size_t *oldlenp,
			    void *newp, size_t newlen);

SILLY_API void silly_log_openfile(const char *path);
SILLY_API void silly_log_setlevel(enum silly_log_level level);
SILLY_API enum silly_log_level silly_log_getlevel();
SILLY_API void silly_log_head(enum silly_log_level level);
SILLY_API void silly_log_fmt(const char *fmt, ...);
SILLY_API void silly_log_append(const char *str, size_t sz);
#define silly_log_visible(level) (level >= silly_log_getlevel())
#define silly_log_(level, ...)                   \
	do {                                     \
		if (!silly_log_visible(level)) { \
			break;                   \
		}                                \
		silly_log_head(level);           \
		silly_log_fmt(__VA_ARGS__);      \
	} while (0)

#define silly_log_debug(...) silly_log_(SILLY_LOG_DEBUG, __VA_ARGS__)
#define silly_log_info(...) silly_log_(SILLY_LOG_INFO, __VA_ARGS__)
#define silly_log_warn(...) silly_log_(SILLY_LOG_WARN, __VA_ARGS__)
#define silly_log_error(...) silly_log_(SILLY_LOG_ERROR, __VA_ARGS__)

SILLY_API int silly_signal_msgtype();
SILLY_API int silly_signal_watch(int signum);

SILLY_API const struct silly_socket_msgtype *silly_socket_msgtypes();
SILLY_API socket_id_t silly_socket_listen(const char *ip, const char *port,
					  int backlog);
SILLY_API socket_id_t silly_socket_udpbind(const char *ip, const char *port);
SILLY_API socket_id_t silly_socket_connect(const char *ip, const char *port,
					   const char *bindip,
					   const char *bindport);
SILLY_API socket_id_t silly_socket_udpconnect(const char *ip, const char *port,
					      const char *bindip,
					      const char *bindport);
SILLY_API int silly_socket_ntop(const void *data,
				char name[SILLY_SOCKET_NAMELEN]);
SILLY_API void silly_socket_readenable(socket_id_t sid, int enable);
SILLY_API int silly_socket_sendsize(socket_id_t sid);
SILLY_API int silly_socket_send(socket_id_t sid, uint8_t *buff, size_t sz,
				void (*freex)(void *));
SILLY_API int silly_socket_udpsend(socket_id_t sid, uint8_t *buff, size_t sz,
				   const uint8_t *addr, size_t addrlen,
				   void (*freex)(void *));
SILLY_API int silly_socket_close(socket_id_t sid);
SILLY_API const char *silly_socket_pollapi();
SILLY_API void silly_socket_netstat(struct silly_netstat *stat);
SILLY_API void silly_socket_socketstat(socket_id_t sid,
				       struct silly_socketstat *info);

SILLY_API int silly_timer_msgtype();
SILLY_API uint64_t silly_timer_timeout(uint32_t expire, uint32_t ud);
SILLY_API int silly_timer_cancel(uint64_t session, uint32_t *ud);
SILLY_API uint64_t silly_timer_now();
SILLY_API uint64_t silly_timer_monotonic();
SILLY_API uint32_t silly_timer_info(uint32_t *expired);

SILLY_API void silly_trace_span(silly_tracespan_t id);
SILLY_API silly_traceid_t silly_trace_set(silly_traceid_t id);
SILLY_API silly_traceid_t silly_trace_get();
SILLY_API silly_traceid_t silly_trace_new();

SILLY_API void silly_worker_push(struct silly_message *msg);
SILLY_API uint32_t silly_worker_genid();
SILLY_API size_t silly_worker_msgsize();
SILLY_API void silly_worker_resume(lua_State *L);
SILLY_API char **silly_worker_args(int *argc);
SILLY_API void silly_worker_callbacktable(lua_State *L);
SILLY_API void silly_worker_errortable(lua_State *L);
SILLY_API void silly_worker_pusherror(lua_State *L, int stk, int code);
SILLY_API void silly_worker_reset();

SILLY_API int silly_new_message_type();
SILLY_API void silly_cpu_usage(float *stime, float *utime);
SILLY_API void silly_fd_open_limit(int *soft, int *hard);
SILLY_API int silly_open_fd_count(void);
SILLY_API int silly_cpu_count(void);
#endif
