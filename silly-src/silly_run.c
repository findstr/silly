#include "silly_conf.h"
#include <unistd.h>
#include <signal.h>
#include <pthread.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>

#include "silly.h"
#include "compiler.h"
#include "silly_trace.h"
#include "silly_log.h"
#include "silly_malloc.h"
#include "silly_timer.h"
#include "silly_socket.h"
#include "silly_worker.h"
#include "silly_monitor.h"
#include "silly_signal.h"

#include "silly_run.h"

struct {
	volatile int running;
	int exitstatus;
	int workerstatus; /* 0:sleep 1:running -1:dead */
	const struct silly_config *conf;
	pthread_mutex_t mutex;
	pthread_cond_t cond;
} R;

static void *thread_timer(void *arg)
{
	(void)arg;
	struct timespec req;
	req.tv_sec = TIMER_ACCURACY / 1000;
	req.tv_nsec = (TIMER_ACCURACY % 1000) * 1000000;
	silly_trace_set(TRACE_TIMER_ID);
	silly_log_info("[timer] start\n");
	for (;;) {
		silly_timer_update();
		if (R.workerstatus == -1)
			break;
		nanosleep(&req, NULL);
		if (R.workerstatus == 0)
			pthread_cond_signal(&R.cond);
	}
	silly_log_info("[timer] stop\n");
	silly_socket_terminate();
	return NULL;
}

static void *thread_socket(void *arg)
{
	(void)arg;
	silly_trace_set(TRACE_SOCKET_ID);
	silly_log_info("[socket] start\n");
	for (;;) {
		int err = silly_socket_poll();
		if (err < 0)
			break;
		if (R.workerstatus == 0)
			pthread_cond_signal(&R.cond);
	}
	silly_log_info("[socket] stop\n");
	return NULL;
}

static void *thread_worker(void *arg)
{
	const struct silly_config *c;
	c = (struct silly_config *)arg;
	silly_log_info("[worker] start\n");
	silly_worker_start(c);
	pthread_mutex_lock(&R.mutex);
	silly_trace_set(TRACE_WORKER_ID);
	while (R.running) {
		silly_worker_dispatch();
		//allow spurious wakeup, it's harmless
		R.workerstatus = 0;
		if (silly_worker_msgsize() == 0) //double check
			pthread_cond_wait(&R.cond, &R.mutex);
		R.workerstatus = 1;
		silly_log_flush();
	}
	silly_log_info("[worker] stop\n");
	pthread_mutex_unlock(&R.mutex);
	R.workerstatus = -1;
	return NULL;
}

struct stdin_data {
	char line[1024];
	size_t pos;
};

static void stdin_cleanup(void *arg) {
	if (!R.running) {
		return;
	}
	struct stdin_data *data = (struct stdin_data *)arg;
	if (data->pos > 0) {
		silly_worker_stdin(data->line, data->pos);
	}
	silly_worker_stdin("", 0);
}

static void *thread_stdin(void *arg)
{
	(void)arg;
	int c;
	struct stdin_data data;
	data.pos = 0;

#ifdef _WIN32
	HANDLE hStdin = GetStdHandle(STD_INPUT_HANDLE);
	if (hStdin == INVALID_HANDLE_VALUE) {
		return NULL;
 	}
	// check input type
	DWORD fileType = GetFileType(hStdin);
	BOOL isPipe = (fileType == FILE_TYPE_PIPE);
#endif
	pthread_cleanup_push(stdin_cleanup, &data);
	silly_log_info("[stdin] start\n");
	while (R.running) {
#ifdef _WIN32
		DWORD bytesRead;
		char buffer = 0;
		if (!ReadFile(hStdin, &buffer, 1, &bytesRead, NULL)) {
			DWORD error = GetLastError();
			if (error == ERROR_OPERATION_ABORTED) {
				break;
			}
			if (error == ERROR_BROKEN_PIPE ||
				(isPipe && error == ERROR_HANDLE_EOF)) {
				// pipe closed or EOF
				break;
			}
			Sleep(300);
			continue;
		}
		if (bytesRead == 0 || buffer == 0x1A) {
			// pipe closed or EOF
			break;
		}
		c = (unsigned char)buffer;
#else
		c = fgetc(stdin);
		if (c == EOF) {
			if (errno != EINTR) {
				break;
			}
			continue;
		}
#endif
		data.line[data.pos++] = c;
		if (data.pos >= sizeof(data.line) - 1 || c == '\n') {
			silly_worker_stdin(data.line, data.pos);
			data.pos = 0;
		}
	}
	pthread_cleanup_pop(1);
	silly_log_info("[stdin] stop\n");
	return NULL;
}

static void monitor_check()
{
	struct timespec req;
	req.tv_sec = MONITOR_MSG_SLOW_TIME / 1000;
	req.tv_nsec = (MONITOR_MSG_SLOW_TIME % 1000) * 1000000;
	silly_trace_set(TRACE_MONITOR_ID);
	silly_log_info("[monitor] start\n");
	for (;;) {
		if (R.workerstatus == -1)
			break;
		nanosleep(&req, NULL);
		silly_monitor_check();
	}
	silly_log_info("[monitor] stop\n");
	return;
}

static void thread_create(pthread_t *tid, void *(*start)(void *), void *arg,
			  int cpuid)
{
	int err;
	err = pthread_create(tid, NULL, start, arg);
	if (unlikely(err < 0)) {
		silly_log_error("thread create fail:%d\n", err);
		exit(-1);
	}
#ifdef USE_CPU_AFFINITY
	if (cpuid < 0)
		return;
	cpu_set_t cpuset;
	CPU_ZERO(&cpuset);
	CPU_SET(cpuid, &cpuset);
	pthread_setaffinity_np(*tid, sizeof(cpuset), &cpuset);
#else
	(void)cpuid;
#endif
	return;
}

int silly_run(const struct silly_config *config)
{
	int i;
	int err;
	pthread_t pid[4];
	R.running = 1;
	R.conf = config;
	R.exitstatus = 0;
	pthread_mutex_init(&R.mutex, NULL);
	pthread_cond_init(&R.cond, NULL);
	silly_signal_init();
	err = silly_socket_init();
	if (unlikely(err < 0)) {
		silly_log_error("%s socket init fail:%d\n", config->selfname,
				err);
		return -err;
	}
	silly_worker_init();
	silly_monitor_init();
	srand(time(NULL));
	silly_log_info("%s %s is running ...\n", config->selfname,
		       SILLY_RELEASE);
	silly_log_info("cpu affinity setting, timer:%d, socket:%d, worker:%d\n",
		       config->timeraffinity, config->socketaffinity,
		       config->workeraffinity);
	thread_create(&pid[0], thread_socket, NULL, config->socketaffinity);
	thread_create(&pid[1], thread_timer, NULL, config->timeraffinity);
	thread_create(&pid[2], thread_worker, (void *)config,
		      config->workeraffinity);
	thread_create(&pid[3], thread_stdin, NULL, -1);
	monitor_check();
	for (i = 0; i < 3; i++)
		pthread_join(pid[i], NULL);
#ifdef _WIN32
	CancelIoEx(GetStdHandle(STD_INPUT_HANDLE), NULL);
#else
	pthread_cancel(pid[3]);
#endif
	pthread_join(pid[3], NULL);
	silly_log_flush();
	pthread_mutex_destroy(&R.mutex);
	pthread_cond_destroy(&R.cond);
	silly_worker_exit();
	silly_socket_exit();
	silly_log_info("%s has already exit...\n", config->selfname);
	return R.exitstatus;
}

void silly_exit(int status)
{
	R.running = 0;
	R.exitstatus = status;
}
