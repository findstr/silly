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

struct silly_message_id {
	int timer_expire;
	int signal_fire;
	int tcp_accept;
	int tcp_data;
	int udp_data;
	int socket_listen;
	int socket_connect;
	int socket_close;
};

enum silly_log_level {
	SILLY_LOG_DEBUG = 0,
	SILLY_LOG_INFO = 1,
	SILLY_LOG_WARN = 2,
	SILLY_LOG_ERROR = 3,
};

struct silly_timerstat {
	atomic_uint_least64_t pending;
	atomic_uint_least64_t scheduled;
	atomic_uint_least64_t fired;
	atomic_uint_least64_t canceled;
};

struct silly_netstat {
	atomic_uint_least16_t tcp_connections;
	atomic_uint_least64_t received_bytes;
	atomic_uint_least64_t sent_bytes;
	atomic_uint_least64_t operate_request;
	atomic_uint_least64_t operate_processed;
};

struct silly_socketstat {
	silly_socket_id_t sid;
	int fd;
	const char *type;
	const char *protocol;
	uint64_t sent_bytes;
	uint64_t received_bytes;
	char localaddr[SILLY_SOCKET_NAMELEN];
	char remoteaddr[SILLY_SOCKET_NAMELEN];
};

typedef uint16_t silly_tracenode_t;
typedef uint64_t silly_traceid_t;

SILLY_API void silly_exit(int status);

SILLY_API void *silly_malloc(size_t sz);
SILLY_API void *silly_realloc(void *ptr, size_t sz);
SILLY_API void silly_free(void *ptr);
SILLY_API const char *silly_allocator();
SILLY_API size_t silly_allocated_bytes();
SILLY_API size_t silly_rss_bytes();
SILLY_API int silly_mallctl(const char *name, void *oldp, size_t *oldlenp,
			    void *newp, size_t newlen);

SILLY_API void silly_log_open_file(const char *path);
SILLY_API void silly_log_set_level(enum silly_log_level level);
SILLY_API enum silly_log_level silly_log_get_level();
SILLY_API void silly_log_head(enum silly_log_level level);
SILLY_API void silly_log_fmt(const char *fmt, ...);
SILLY_API void silly_log_append(const char *str, size_t sz);
#define silly_log_visible(level) (level >= silly_log_get_level())
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

SILLY_API int silly_signal_watch(int signum);
SILLY_API silly_socket_id_t silly_tcp_listen(const char *ip, const char *port,
					     int backlog);
SILLY_API silly_socket_id_t silly_udp_bind(const char *ip, const char *port);
SILLY_API silly_socket_id_t silly_tcp_connect(const char *ip, const char *port,
					      const char *bindip,
					      const char *bindport);
SILLY_API silly_socket_id_t silly_udp_connect(const char *ip, const char *port,
					      const char *bindip,
					      const char *bindport);
SILLY_API int silly_ntop(const void *data, char name[SILLY_SOCKET_NAMELEN]);
SILLY_API int silly_tcp_send(silly_socket_id_t sid, uint8_t *buff, size_t sz,
			     void (*freex)(void *));
SILLY_API int silly_udp_send(silly_socket_id_t sid, uint8_t *buff, size_t sz,
			     const uint8_t *addr, size_t addrlen,
			     void (*freex)(void *));
SILLY_API void silly_socket_readenable(silly_socket_id_t sid, int enable);
SILLY_API int silly_socket_sendsize(silly_socket_id_t sid);
SILLY_API int silly_socket_close(silly_socket_id_t sid);
SILLY_API const char *silly_socket_multiplexer();
SILLY_API void silly_netstat(struct silly_netstat *stat);
SILLY_API void silly_socketstat(silly_socket_id_t sid,
			      struct silly_socketstat *info);

SILLY_API uint64_t silly_now();
SILLY_API uint64_t silly_monotonic();
SILLY_API uint64_t silly_timer_after(uint32_t timeout);
SILLY_API int silly_timer_cancel(uint64_t session);
SILLY_API void silly_timerstat(struct silly_timerstat *stat);

SILLY_API void silly_trace_set_node(silly_tracenode_t id);
SILLY_API silly_traceid_t silly_trace_exchange(silly_traceid_t id);
SILLY_API silly_traceid_t silly_trace_current();
SILLY_API silly_traceid_t silly_trace_new();

SILLY_API void silly_push(struct silly_message *msg);
SILLY_API uint32_t silly_genid();
SILLY_API size_t silly_worker_backlog();
SILLY_API void silly_resume(lua_State *L);
SILLY_API char **silly_args(int *argc);
SILLY_API void silly_callback_table(lua_State *L);
SILLY_API void silly_error_table(lua_State *L);
SILLY_API void silly_push_error(lua_State *L, int stk, int code);

SILLY_API int silly_register_message(const char *name);
SILLY_API const struct silly_message_id *silly_messages();
SILLY_API void silly_cpu_usage(float *stime, float *utime);
SILLY_API void silly_fd_open_limit(int *soft, int *hard);
SILLY_API int silly_open_fd_count(void);
SILLY_API int silly_cpu_count(void);
#endif
