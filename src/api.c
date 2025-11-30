#include <string.h>
#include "silly.h"
#include "platform.h"
#include "message.h"
#include "mem.h"
#include "socket.h"
#include "log.h"
#include "sig.h"
#include "worker.h"
#include "timer.h"
#include "trace.h"
#include "engine.h"

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
SILLY_API size_t silly_allocated_bytes()
{
	return mem_used();
}
SILLY_API size_t silly_rss_bytes()
{
	return mem_rss();
}
SILLY_API int silly_mallctl(const char *name, void *oldp, size_t *oldlenp,
			    void *newp, size_t newlen)
{
	return mem_mallctl(name, oldp, oldlenp, newp, newlen);
}

SILLY_API void silly_log_open_file(const char *path)
{
	log_open_file(path);
}
SILLY_API void silly_log_set_level(enum silly_log_level level)
{
	log_set_level(level);
}
SILLY_API enum silly_log_level silly_log_get_level()
{
	return log_get_level();
}
SILLY_API void silly_log_head(enum silly_log_level level)
{
	log_head(level);
}
SILLY_API void silly_log_fmt(const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	log_vfmt(fmt, ap);
	va_end(ap);
}
SILLY_API void silly_log_append(const char *str, size_t sz)
{
	log_append(str, sz);
}
SILLY_API int silly_signal_watch(int signum)
{
	return sig_watch(signum);
}
SILLY_API silly_socket_id_t silly_tcp_listen(const char *ip, const char *port,
					     int backlog)
{
	return socket_tcp_listen(ip, port, backlog);
}
SILLY_API silly_socket_id_t silly_udp_bind(const char *ip, const char *port)
{
	return socket_udp_bind(ip, port);
}
SILLY_API silly_socket_id_t silly_tcp_connect(const char *ip, const char *port,
					      const char *bindip,
					      const char *bindport)
{
	return socket_tcp_connect(ip, port, bindip, bindport);
}
SILLY_API silly_socket_id_t silly_udp_connect(const char *ip, const char *port,
					      const char *bindip,
					      const char *bindport)
{
	return socket_udp_connect(ip, port, bindip, bindport);
}
SILLY_API int silly_ntop(const void *data, char name[SILLY_SOCKET_NAMELEN])
{
	return socket_ntop(data, name);
}
SILLY_API void silly_socket_readenable(silly_socket_id_t sid, int enable)
{
	socket_read_enable(sid, enable);
}
SILLY_API int silly_socket_sendsize(silly_socket_id_t sid)
{
	return socket_send_size(sid);
}
SILLY_API int silly_tcp_send(silly_socket_id_t sid, uint8_t *buff, size_t sz,
			     void (*freex)(void *))
{
	return socket_tcp_send(sid, buff, sz, freex);
}
SILLY_API int silly_udp_send(silly_socket_id_t sid, uint8_t *buff, size_t sz,
			     const uint8_t *addr, size_t addrlen,
			     void (*freex)(void *))
{
	return socket_udp_send(sid, buff, sz, addr, addrlen, freex);
}
SILLY_API int silly_socket_close(silly_socket_id_t sid)
{
	return socket_close(sid);
}
SILLY_API const char *silly_socket_pollapi()
{
	return socket_pollapi();
}
SILLY_API void silly_netstat(struct silly_netstat *stat)
{
	socket_netstat(stat);
}
SILLY_API void silly_sockstat(silly_socket_id_t sid,
			      struct silly_sockstat *info)
{
	socket_stat(sid, info);
}
SILLY_API void silly_timerstat(struct silly_timerstat *stat)
{
	timer_stat(stat);
}
SILLY_API uint64_t silly_timer_after(uint32_t expire)
{
	return timer_after(expire);
}
SILLY_API int silly_timer_cancel(uint64_t session)
{
	return timer_cancel(session);
}
SILLY_API uint64_t silly_now()
{
	return timer_now();
}
SILLY_API uint64_t silly_monotonic()
{
	return timer_monotonic();
}
SILLY_API void silly_trace_set_node(silly_tracenode_t id)
{
	trace_set_node(id);
}
SILLY_API silly_traceid_t silly_trace_exchange(silly_traceid_t id)
{
	return trace_exchange(id);
}
SILLY_API silly_traceid_t silly_trace_new()
{
	return trace_new();
}
SILLY_API void silly_push(struct silly_message *msg)
{
	worker_push(msg);
}
SILLY_API uint32_t silly_genid()
{
	return worker_alloc_id();
}
SILLY_API size_t silly_worker_backlog()
{
	return worker_backlog();
}
SILLY_API void silly_resume(lua_State *L)
{
	worker_resume(L);
}
SILLY_API char **silly_args(int *argc)
{
	return worker_args(argc);
}
SILLY_API void silly_callback_table(lua_State *L)
{
	worker_callback_table(L);
}
SILLY_API void silly_error_table(lua_State *L)
{
	worker_error_table(L);
}
SILLY_API void silly_push_error(lua_State *L, int stk, int code)
{
	worker_push_error(L, stk, code);
}
SILLY_API int silly_register_message(const char *name)
{
	return message_register(name);
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
	worker_reset();
	return engine_shutdown(status);
}
SILLY_API const struct silly_message_id *silly_messages()
{
	static const struct silly_message_id p = {
		.timer_expire = MESSAGE_TIMER_EXPIRE,
		.signal_fire = MESSAGE_SIGNAL_FIRE,
		.tcp_accept = MESSAGE_TCP_ACCEPT,
		.tcp_data = MESSAGE_TCP_DATA,
		.udp_data = MESSAGE_UDP_DATA,
		.socket_listen = MESSAGE_SOCKET_LISTEN,
		.socket_connect = MESSAGE_SOCKET_CONNECT,
		.socket_close = MESSAGE_SOCKET_CLOSE,
	};
	return &p;
}
