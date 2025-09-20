#include <string.h>
#include "silly.h"
#include "platform.h"
#include "message.h"
#include "silly_malloc.h"
#include "silly_socket.h"
#include "silly_log.h"
#include "silly_signal.h"
#include "silly_worker.h"
#include "silly_timer.h"
#include "silly_trace.h"
#include "silly_run.h"

SILLY_API void *silly_malloc(size_t sz)
{
	return mem_alloc(sz);
}
SILLY_API void *silly_realloc(void *ptr, size_t sz)
{
	return mem_realloc(ptr, sz);
}
SILLY_API void silly_free(void *ptr)
{
	mem_free(ptr);
}
SILLY_API const char *silly_allocator()
{
	return mem_allocator();
}
SILLY_API size_t silly_memused()
{
	return mem_used();
}
SILLY_API size_t silly_memrss()
{
	return mem_rss();
}
SILLY_API int silly_mallctl(const char *name, void *oldp, size_t *oldlenp,
			    void *newp, size_t newlen)
{
	return mem_mallctl(name, oldp, oldlenp, newp, newlen);
}

SILLY_API void silly_log_openfile(const char *path)
{
	log_open_file(path);
}
SILLY_API void silly_log_setlevel(enum silly_log_level level)
{
	log_set_level(level);
}
SILLY_API enum silly_log_level silly_log_getlevel()
{
	return log_get_level();
}
SILLY_API void silly_log_head(enum silly_log_level level)
{
	log_head(level);
}
SILLY_API void silly_log_fmt(const char *fmt, ...)
{
	log_fmt(fmt);
}
SILLY_API void silly_log_append(const char *str, size_t sz)
{
	log_append(str, sz);
}
SILLY_API int silly_signal_msgtype()
{
	return signal_msg_type();
}
SILLY_API int silly_signal_watch(int signum)
{
	return signal_watch(signum);
}
SILLY_API const struct silly_socket_msgtype *silly_socket_msgtypes()
{
	return socket_msg_types();
}
SILLY_API socket_id_t silly_socket_listen(const char *ip, const char *port,
					  int backlog)
{
	return socket_tcp_listen(ip, port, backlog);
}
SILLY_API socket_id_t silly_socket_udpbind(const char *ip, const char *port)
{
	return socket_udp_bind(ip, port);
}
SILLY_API socket_id_t silly_socket_connect(const char *ip, const char *port,
					   const char *bindip,
					   const char *bindport)
{
	return socket_tcp_connect(ip, port, bindip, bindport);
}
SILLY_API socket_id_t silly_socket_udpconnect(const char *ip, const char *port,
					      const char *bindip,
					      const char *bindport)
{
	return socket_udp_connect(ip, port, bindip, bindport);
}
SILLY_API int silly_socket_ntop(const void *data,
				char name[SILLY_SOCKET_NAMELEN])
{
	return socket_ntop(data, name);
}
SILLY_API void silly_socket_readenable(socket_id_t sid, int enable)
{
	return socket_read_enable(sid, enable);
}
SILLY_API int silly_socket_sendsize(socket_id_t sid)
{
	return socket_send_size(sid);
}
SILLY_API int silly_socket_send(socket_id_t sid, uint8_t *buff, size_t sz,
				void (*freex)(void *))
{
	return socket_tcp_send(sid, buff, sz, freex);
}
SILLY_API int silly_socket_udpsend(socket_id_t sid, uint8_t *buff, size_t sz,
				   const uint8_t *addr, size_t addrlen,
				   void (*freex)(void *))
{
	return socket_udp_send(sid, buff, sz, addr, addrlen, freex);
}
SILLY_API int silly_socket_close(socket_id_t sid)
{
	return socket_close(sid);
}
SILLY_API const char *silly_socket_pollapi()
{
	return socket_pollapi();
}
SILLY_API void silly_socket_netstat(struct silly_netstat *stat)
{
	socket_netstat(stat);
}
SILLY_API void silly_socket_socketstat(socket_id_t sid,
				       struct silly_socketstat *info)
{
	socket_stat(sid, info);
}
SILLY_API int silly_timer_msgtype()
{
	return timer_msg_type();
}
SILLY_API uint64_t silly_timer_timeout(uint32_t expire, uint32_t ud)
{
	return timer_timeout(expire, ud);
}

SILLY_API int silly_timer_cancel(uint64_t session, uint32_t *ud)
{
	return timer_cancel(session, ud);
}

SILLY_API uint64_t silly_timer_now()
{
	return timer_now();
}

SILLY_API uint64_t silly_timer_monotonic()
{
	return timer_monotonic();
}

SILLY_API uint32_t silly_timer_info(uint32_t *expired)
{
	return timer_info(expired);
}

SILLY_API void silly_trace_span(silly_tracespan_t id)
{
	return trace_span(id);
}

SILLY_API silly_traceid_t silly_trace_set(silly_traceid_t id)
{
	return trace_set(id);
}

SILLY_API silly_traceid_t silly_trace_get()
{
	return trace_get();
}

SILLY_API silly_traceid_t silly_trace_new()
{
	return trace_new();
}

SILLY_API void silly_worker_push(struct silly_message *msg)
{
	worker_push(msg);
}
SILLY_API uint32_t silly_worker_genid()
{
	return worker_alloc_id();
}
SILLY_API size_t silly_worker_msgsize()
{
	return worker_msg_size();
}
SILLY_API void silly_worker_resume(lua_State *L)
{
	worker_resume(L);
}
SILLY_API char **silly_worker_args(int *argc)
{
	return worker_args(argc);
}
SILLY_API void silly_worker_callbacktable(lua_State *L)
{
	worker_callback_table(L);
}
SILLY_API void silly_worker_errortable(lua_State *L)
{
	worker_error_table(L);
}
SILLY_API void silly_worker_pusherror(lua_State *L, int stk, int code)
{
	worker_push_error(L, stk, code);
}
SILLY_API void silly_worker_reset()
{
	worker_reset();
}

SILLY_API int silly_new_message_type()
{
	return message_new_type();
}

SILLY_API void silly_cpu_usage(float *stime, float *utime)
{
	cpu_usage(stime, utime);
}

SILLY_API void silly_fd_open_limit(int *soft, int *hard)
{
	fd_open_limit(soft, hard);
}

SILLY_API int silly_open_fd_count(void)
{
	return open_fd_count();
}

SILLY_API int silly_cpu_count(void)
{
	return cpu_count();
}

SILLY_API void silly_exit(int status)
{
	return silly_shutdown(status);
}
